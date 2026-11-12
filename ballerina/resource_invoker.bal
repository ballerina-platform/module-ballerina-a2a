// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Reaching the resource functions of a user's service. A resource function is
// not callable through a service-typed value, so this goes through a native
// that reads the service's resource table and calls the method by name.

import ballerina/jballerina.java;

# Lists the resources a service defines.
#
# + service - The user's service
# + return - One entry per resource, `"<accessor> <path>"` with `*` for a path
#            parameter, and a trailing ` +context` when it takes a `Context`
isolated function describeResources(service object {} 'service) returns string[] = @java:Method {
    'class: "io.ballerina.lib.a2a.nativeimpl.ResourceInvoker",
    name: "describe"
} external;

# Calls one of a service's resources.
#
# + service - The user's service
# + accessor - The resource's accessor, lower case
# + path - The resource's path, with `*` for a path parameter
# + pathParams - The path parameters' values, in order
# + context - Passed when the resource declares a `Context`
# + request - The request record, or `()` when the resource takes none
# + return - What the resource returned
isolated function invokeResource(service object {} 'service, string accessor, string path,
        string[] pathParams, Context context, anydata request) returns anydata|stream<StreamResponse, Error?>|error = @java:Method {
    'class: "io.ballerina.lib.a2a.nativeimpl.ResourceInvoker",
    name: "invoke"
} external;

# Lists the remote functions a service defines.
#
# + service - The user's service
# + return - One entry per remote function, its name, with a trailing
#            ` +context` when it takes a `Context`
isolated function describeRemoteFunctions(service object {} 'service) returns string[] = @java:Method {
    'class: "io.ballerina.lib.a2a.nativeimpl.ResourceInvoker",
    name: "describeRemote"
} external;

# Calls one of a service's remote functions.
#
# + service - The user's service
# + name - The remote function's name
# + context - Passed when the function declares a `Context`
# + request - The request record, or `()` when the function takes none
# + return - What the function returned
isolated function invokeRemoteFunction(service object {} 'service, string name, Context context,
        anydata request) returns anydata|stream<StreamResponse, Error?>|error = @java:Method {
    'class: "io.ballerina.lib.a2a.nativeimpl.ResourceInvoker",
    name: "invokeRemote"
} external;
