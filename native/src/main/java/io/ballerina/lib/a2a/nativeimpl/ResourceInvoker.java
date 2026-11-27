/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.a2a.nativeimpl;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.Parameter;
import io.ballerina.runtime.api.types.RemoteMethodType;
import io.ballerina.runtime.api.types.ResourceMethodType;
import io.ballerina.runtime.api.types.ServiceType;
import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.utils.TypeUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;
import io.ballerina.runtime.api.values.BTypedesc;
import io.ballerina.runtime.internal.TypeChecker;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Finds and calls the resource functions of a user's service.
 * <p>
 * A resource function cannot be called from Ballerina code through a service-typed value, so the listener's own
 * dispatcher reaches it here. A resource is identified by its accessor and its path, with each path parameter written
 * as {@code *}: {@code post message:send}, {@code get tasks/*}.
 */
public final class ResourceInvoker {

    private static final String PATH_PARAMETER_PREFIX = "^";
    private static final String CONTEXT_TYPE_NAME = "Context";
    // The package the `Context` type belongs to; a type of another package that is also called `Context` is the
    // application's own and does not get the A2A context.
    private static final String PACKAGE_ORG = "ballerina";
    private static final String PACKAGE_NAME = "a2a";
    private static final BString REQUEST_FIELD = StringUtils.fromString("request");
    private static final BString RESULT_FIELD = StringUtils.fromString("result");

    private static final Map<ServiceType, Map<String, RemoteMethodType>> REMOTE_METHODS = new ConcurrentHashMap<>();
    private static final Map<ServiceType, Map<String, ResourceMethodType>> RESOURCE_METHODS =
            new ConcurrentHashMap<>();

    private ResourceInvoker() {
    }

    /**
     * Lists the resources a service defines.
     *
     * @param service the user's service
     * @return one entry per resource, {@code "<accessor> <path>"}, with {@code *} for a path parameter and a
     *         trailing {@code " +context"} when the resource takes an {@code a2a:Context}
     */
    public static BArray describe(BObject service) {
        List<BString> entries = new ArrayList<>();
        for (ResourceMethodType method : resourceMethods(service)) {
            String entry = method.getAccessor().toLowerCase() + " " + pathOf(method);
            if (takesContext(method)) {
                entry += " +context";
            }
            entries.add(StringUtils.fromString(entry));
        }
        return ValueCreator.createArrayValue(entries.toArray(new BString[0]));
    }

    /**
     * Calls the resource with this accessor and path.
     *
     * @param env        the calling strand's environment
     * @param service    the user's service
     * @param accessor   the resource's accessor, lower case
     * @param path       the resource's path, with {@code *} for a path parameter
     * @param pathParams the values of the path parameters, in order
     * @param context    the {@code a2a:Context}, passed when the resource declares it
     * @param request    the request record, or {@code null} when the resource takes none
     * @return what the resource returned, or an error if there is no such resource
     */
    public static Object invoke(Environment env, BObject service, BString accessor, BString path, BArray pathParams,
                                BMap<BString, Object> context, Object request) {
        ResourceMethodType method = find(service, accessor.getValue(), path.getValue());
        if (method == null) {
            return ErrorCreator.createError(StringUtils.fromString(
                    "no '" + accessor.getValue() + " " + path.getValue() + "' resource in the attached service"));
        }
        List<Object> arguments = argumentsFor(method.getParameters(), pathParams, context, request);
        return call(env, service, method.getName(), arguments);
    }

    /**
     * Lists the remote functions a service defines.
     *
     * @param service the user's service
     * @return one entry per remote function, its name, with a trailing {@code " +context"} when it takes an
     *         {@code a2a:Context}
     */
    public static BArray describeRemote(BObject service) {
        List<BString> entries = new ArrayList<>();
        for (RemoteMethodType method : serviceType(service).getRemoteMethods()) {
            String entry = method.getName();
            for (Parameter parameter : method.getParameters()) {
                if (isContext(parameter)) {
                    entry += " +context";
                    break;
                }
            }
            entries.add(StringUtils.fromString(entry));
        }
        return ValueCreator.createArrayValue(entries.toArray(new BString[0]));
    }

    /**
     * Checks the signatures of a service's remote functions against what each A2A method takes and returns, so a
     * function with the wrong parameter or return type is refused when the service is attached and not on its first
     * request.
     *
     * @param service  the user's service
     * @param expected the method name mapped to {@code {typedesc? request, typedesc result}}
     * @return one description per problem, empty when every function that is a known method is well formed
     */
    public static BArray checkRemoteSignatures(BObject service, BMap<BString, Object> expected) {
        List<BString> problems = new ArrayList<>();
        for (RemoteMethodType method : serviceType(service).getRemoteMethods()) {
            Object entry = expected.get(StringUtils.fromString(method.getName()));
            if (!(entry instanceof BMap)) {
                continue;
            }
            @SuppressWarnings("unchecked")
            BMap<BString, Object> signature = (BMap<BString, Object>) entry;
            Object requestType = signature.get(REQUEST_FIELD);
            Type expectedRequest = requestType instanceof BTypedesc typedesc ? typedesc.getDescribingType() : null;
            Type expectedResult = ((BTypedesc) signature.get(RESULT_FIELD)).getDescribingType();
            int requests = 0;
            for (Parameter parameter : method.getParameters()) {
                if (isContext(parameter)) {
                    continue;
                }
                if (expectedRequest != null && TypeUtils.isSameType(
                        TypeUtils.getImpliedType(parameter.type), TypeUtils.getImpliedType(expectedRequest))
                        && requests == 0) {
                    requests++;
                    continue;
                }
                problems.add(StringUtils.fromString(method.getName() + ": parameter '" + parameter.name
                        + "' has type " + parameter.type + (expectedRequest == null
                        ? ", but this method takes no request"
                        : ", but this method takes a " + expectedRequest)));
            }
            Type returned = method.getType().getReturnType();
            if (!TypeChecker.checkIsType(returned, expectedResult)) {
                problems.add(StringUtils.fromString(method.getName() + ": returns " + returned
                        + ", but this method returns " + expectedResult));
            }
        }
        return ValueCreator.createArrayValue(problems.toArray(new BString[0]));
    }

    /**
     * Calls the remote function with this name.
     *
     * @param env     the calling strand's environment
     * @param service the user's service
     * @param name    the remote function's name
     * @param context the {@code a2a:Context}, passed when the function declares it
     * @param request the request record, or {@code null} when the function takes none
     * @return what the function returned, or an error if there is no such function
     */
    public static Object invokeRemote(Environment env, BObject service, BString name, BMap<BString, Object> context,
                                      Object request) {
        RemoteMethodType method = remoteMethodsOf(serviceType(service)).get(name.getValue());
        if (method == null) {
            return ErrorCreator.createError(StringUtils.fromString(
                    "no '" + name.getValue() + "' remote function in the attached service"));
        }
        List<Object> arguments = argumentsFor(method.getParameters(), ValueCreator.createArrayValue(new BString[0]),
                context, request);
        return call(env, service, name.getValue(), arguments);
    }

    // The runtime lists a resource's path parameters first, then the rest in declaration order, so each
    // declared parameter is filled by its kind rather than by a fixed position.
    private static List<Object> argumentsFor(Parameter[] declared, BArray pathParams, Object context,
                                             Object request) {
        List<Object> arguments = new ArrayList<>();
        for (int i = 0; i < declared.length; i++) {
            if (isContext(declared[i])) {
                arguments.add(context);
            } else if (i < pathParams.size()) {
                arguments.add(pathParams.get(i));
            } else {
                arguments.add(request);
            }
        }
        return arguments;
    }

    private static Object call(Environment env, BObject service, String methodName, List<Object> arguments) {
        return env.yieldAndRun(() -> {
            try {
                return env.getRuntime().callMethod(service, methodName, null, arguments.toArray());
            } catch (BError error) {
                return error;
            }
        });
    }

    private static ServiceType serviceType(BObject service) {
        return (ServiceType) TypeUtils.getReferredType(TypeUtils.getType(service));
    }

    private static ResourceMethodType find(BObject service, String accessor, String path) {
        return resourceMethodsOf(serviceType(service)).get(accessor.toLowerCase() + " " + path);
    }

    // The functions of a service type are fixed once the service type exists, so each is looked up once, by name,
    // and a call finds it with one map access instead of scanning the list.
    private static Map<String, RemoteMethodType> remoteMethodsOf(ServiceType type) {
        return REMOTE_METHODS.computeIfAbsent(type, serviceType -> {
            Map<String, RemoteMethodType> methods = new ConcurrentHashMap<>();
            for (RemoteMethodType method : serviceType.getRemoteMethods()) {
                methods.put(method.getName(), method);
            }
            return methods;
        });
    }

    private static Map<String, ResourceMethodType> resourceMethodsOf(ServiceType type) {
        return RESOURCE_METHODS.computeIfAbsent(type, serviceType -> {
            Map<String, ResourceMethodType> methods = new ConcurrentHashMap<>();
            for (ResourceMethodType method : serviceType.getResourceMethods()) {
                methods.put(method.getAccessor().toLowerCase() + " " + pathOf(method), method);
            }
            return methods;
        });
    }

    private static ResourceMethodType[] resourceMethods(BObject service) {
        return serviceType(service).getResourceMethods();
    }

    private static String pathOf(ResourceMethodType method) {
        StringBuilder path = new StringBuilder();
        for (String segment : method.getResourcePath()) {
            if (path.length() > 0) {
                path.append('/');
            }
            path.append(segment.startsWith(PATH_PARAMETER_PREFIX) ? "*" : segment.replace("\\", ""));
        }
        return path.toString();
    }

    private static boolean takesContext(ResourceMethodType method) {
        for (Parameter parameter : method.getParameters()) {
            if (isContext(parameter)) {
                return true;
            }
        }
        return false;
    }

    private static boolean isContext(Parameter parameter) {
        Type type = TypeUtils.getReferredType(parameter.type);
        if (!CONTEXT_TYPE_NAME.equals(type.getName())) {
            return false;
        }
        Module module = type.getPackage();
        return module != null && PACKAGE_ORG.equals(module.getOrg()) && PACKAGE_NAME.equals(module.getName());
    }
}
