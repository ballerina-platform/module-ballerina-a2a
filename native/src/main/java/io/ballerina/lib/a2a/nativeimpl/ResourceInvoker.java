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
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.Parameter;
import io.ballerina.runtime.api.types.ResourceMethodType;
import io.ballerina.runtime.api.types.ServiceType;
import io.ballerina.runtime.api.types.Type;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.utils.TypeUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;

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
            return io.ballerina.runtime.api.creators.ErrorCreator.createError(StringUtils.fromString(
                    "no '" + accessor.getValue() + " " + path.getValue() + "' resource in the attached service"));
        }
        // The runtime lists a resource's path parameters first, then the rest in declaration order, so each
        // declared parameter is filled by its kind rather than by a fixed position.
        List<Object> arguments = new ArrayList<>();
        Parameter[] declared = method.getParameters();
        for (int i = 0; i < declared.length; i++) {
            if (isContext(declared[i])) {
                arguments.add(context);
            } else if (i < pathParams.size()) {
                arguments.add(pathParams.get(i));
            } else {
                arguments.add(request);
            }
        }
        String methodName = method.getName();
        return env.yieldAndRun(() -> {
            CompletableFuture<Object> future = new CompletableFuture<>();
            try {
                Object result = env.getRuntime().callMethod(service, methodName, null, arguments.toArray());
                future.complete(result);
                return future.get();
            } catch (io.ballerina.runtime.api.values.BError error) {
                return error;
            } catch (InterruptedException | java.util.concurrent.ExecutionException e) {
                Thread.currentThread().interrupt();
                return io.ballerina.runtime.api.creators.ErrorCreator.createError(
                        StringUtils.fromString(String.valueOf(e.getMessage())));
            }
        });
    }

    private static ResourceMethodType find(BObject service, String accessor, String path) {
        for (ResourceMethodType method : resourceMethods(service)) {
            if (method.getAccessor().equalsIgnoreCase(accessor) && pathOf(method).equals(path)) {
                return method;
            }
        }
        return null;
    }

    private static ResourceMethodType[] resourceMethods(BObject service) {
        ServiceType type = (ServiceType) TypeUtils.getReferredType(TypeUtils.getType(service));
        return type.getResourceMethods();
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
        return CONTEXT_TYPE_NAME.equals(type.getName());
    }
}
