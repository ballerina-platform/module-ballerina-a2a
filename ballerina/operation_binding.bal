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


// Which of the A2A operations a service defines, and a way to call them.
//
// A service defines an operation by declaring the resource function that
// operation is served at. The listener's own dispatcher owns the wire, so it
// reads the service's resources once when the service is attached and calls
// them through the native invoker; an operation the service does not define
// answers `UnsupportedOperationError` (or `PushNotificationNotSupportedError`
// for the push-notification operations), which is what the specification asks
// of a capability the agent does not offer.
//
// The names below, such as `handleGetTask`, are this package's internal names for
// the operations; the service itself declares resources, not functions with
// these names.

# Where each operation lives in a service: the resource's accessor and its
# path, with `*` for a path parameter.
type ResourceRoute record {|
    # The resource's accessor, lower case
    string accessor;
    # The resource's path, with `*` for a path parameter
    string path;
|};

final readonly & map<ResourceRoute> OPERATION_ROUTES = {
    "handleSendMessage": {accessor: "post", path: "message:send"},
    "handleSendStreamingMessage": {accessor: "post", path: "message:stream"},
    "handleSubscribeToTask": {accessor: "get", path: "tasks/*/subscribe"},
    "handleGetTask": {accessor: "get", path: "tasks/*"},
    "handleListTasks": {accessor: "get", path: "tasks"},
    "handleCancelTask": {accessor: "post", path: "tasks/*/cancel"},
    "handleCreateTaskPushNotificationConfig": {accessor: "post", path: "tasks/*/pushNotificationConfigs"},
    "handleGetTaskPushNotificationConfig": {accessor: "get", path: "tasks/*/pushNotificationConfigs/*"},
    "handleListTaskPushNotificationConfigs": {accessor: "get", path: "tasks/*/pushNotificationConfigs"},
    "handleDeleteTaskPushNotificationConfig": {accessor: "delete", path: "tasks/*/pushNotificationConfigs/*"},
    "handleGetExtendedAgentCard": {accessor: "get", path: "extendedAgentCard"},
    "handleGetAgentCard": {accessor: "get", path: "agentCard"}
};

# The error for an operation the service does not define.
#
# + operation - The operation's name
# + return - The error
isolated function operationUndefinedError(string operation) returns UnsupportedOperationError {
    string msg = string `${operation}: this agent does not support the operation`;
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# The error for the extended card when the service does not define it.
#
# + return - The error
isolated function extendedAgentCardUnsupportedError() returns UnsupportedOperationError {
    string msg = "capabilities.extendedAgentCard is false: no extended AgentCard is configured for this agent";
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# An attached service, with every A2A operation callable: the ones it defines
# through its resources, and an error answer for the rest.
isolated class OperationBinding {
    private final Service agentService;
    // The names of the operations the service defines, in table order
    final readonly & string[] defined;

    # + agentService - The service being attached
    isolated function init(Service agentService) {
        self.agentService = agentService;
        string[] declared = describeResources(agentService).'map(entry => entry.endsWith(" +context")
            ? entry.substring(0, entry.length() - " +context".length())
            : entry);
        string[] names = [];
        foreach [string, ResourceRoute] [operation, route] in OPERATION_ROUTES.entries() {
            if declared.indexOf(route.accessor + " " + route.path) is int {
                names.push(operation);
            }
        }
        self.defined = names.cloneReadOnly();
    }

    # + operationName - An operation's internal name such as `handleGetTask`
    # + return - Whether the service defines it
    isolated function isDefined(string operationName) returns boolean => self.defined.indexOf(operationName) is int;

    isolated function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleSendMessage", [], context, request);
        return <Task|Message>result;
    }

    isolated function sendStreamingMessage(Context context, SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleSendStreamingMessage", [], context, request);
        return <stream<StreamResponse, Error?>>result;
    }

    isolated function subscribeToTask(Context context, SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleSubscribeToTask", [request.id], context, request);
        return <stream<StreamResponse, Error?>>result;
    }

    isolated function getTask(Context context, GetTaskRequest request) returns Task|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleGetTask", [request.id], context, request);
        return <Task>result;
    }

    isolated function listTasks(Context context, ListTasksRequest request) returns ListTasksResponse|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleListTasks", [], context, request);
        return <ListTasksResponse>result;
    }

    isolated function cancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleCancelTask", [request.id], context, request);
        return <Task>result;
    }

    isolated function createTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        anydata|stream<StreamResponse, Error?> result =
            check self.run("handleCreateTaskPushNotificationConfig", [request.taskId ?: ""], context, request);
        return <TaskPushNotificationConfig>result;
    }

    isolated function getTaskPushNotificationConfig(Context context, GetTaskPushNotificationConfigRequest request)
            returns TaskPushNotificationConfig|Error {
        anydata|stream<StreamResponse, Error?> result =
            check self.run("handleGetTaskPushNotificationConfig", [request.taskId, request.id], context, request);
        return <TaskPushNotificationConfig>result;
    }

    isolated function listTaskPushNotificationConfigs(Context context, ListTaskPushNotificationConfigsRequest request)
            returns ListTaskPushNotificationConfigsResponse|Error {
        anydata|stream<StreamResponse, Error?> result =
            check self.run("handleListTaskPushNotificationConfigs", [request.taskId], context, request);
        return <ListTaskPushNotificationConfigsResponse>result;
    }

    isolated function deleteTaskPushNotificationConfig(Context context, DeleteTaskPushNotificationConfigRequest request)
            returns Error? {
        _ = check self.run("handleDeleteTaskPushNotificationConfig", [request.taskId, request.id], context, request);
    }

    isolated function getExtendedAgentCard(Context context, GetExtendedAgentCardRequest request)
            returns AgentCard|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleGetExtendedAgentCard", [], context, request);
        return <AgentCard>result;
    }

    isolated function getAgentCard() returns AgentCard|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("handleGetAgentCard", [], {headers: {}}, ());
        return <AgentCard>result;
    }

    # Calls the resource an operation is served at.
    #
    # + operation - The operation's internal name
    # + pathParams - The values of the resource's path parameters, in order
    # + context - The caller's context, passed when the resource declares it
    # + request - The request record, or `()` for a resource that takes none
    # + return - What the resource returned, or the error it returned
    private isolated function run(string operation, string[] pathParams, Context context, anydata request)
            returns anydata|stream<StreamResponse, Error?>|Error {
        if !self.isDefined(operation) {
            return self.undefinedError(operation);
        }
        ResourceRoute route = OPERATION_ROUTES.get(operation);
        anydata|stream<StreamResponse, Error?>|error result =
            invokeResource(self.agentService, route.accessor, route.path, pathParams, context, request);
        if result is Error {
            return result;
        }
        if result is error {
            string msg = string `${operation}: ${result.message()}`;
            return error InternalError(msg, message = msg);
        }
        return result;
    }

    private isolated function undefinedError(string operation) returns Error {
        match operation {
            "handleSendStreamingMessage"|"handleSubscribeToTask" => {
                return serverStreamingUnsupportedError(operation);
            }
            "handleCreateTaskPushNotificationConfig"|"handleGetTaskPushNotificationConfig"|
            "handleListTaskPushNotificationConfigs"|"handleDeleteTaskPushNotificationConfig" => {
                return serverPushNotificationsUnsupportedError(operation);
            }
            "handleGetExtendedAgentCard" => {
                return extendedAgentCardUnsupportedError();
            }
        }
        return operationUndefinedError(operation);
    }
}
