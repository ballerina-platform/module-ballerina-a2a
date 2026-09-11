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

// The operation set every A2A client type implements.

# The client-side A2A operation set (specification section 9.4), declared once
# and mixed into each client type via `*ClientMethods;` rather than repeating
# eleven signatures per type.
#
# Not public: Ballerina object types are structurally typed, so a caller
# writing code across both client types declares their own local object type
# covering the methods they use, and `a2a:Client` and `a2a:RestClient` satisfy
# it with no dependency on this one.
#
# Every method returns a narrowed `a2a:Error`, never a bare `error`. The
# `+ return` doc on each names the subtype a protocol failure produces;
# transport and decode failures are wrapped into `a2a:InternalError` at the
# binding boundary, so the fallback case is still matchable.
type ClientMethods isolated client object {

    # Sends a message to the remote agent.
    #
    # + request - The message and its send options
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error;

    # Sends a message and receives updates as they happen.
    #
    # + request - The message and its send options
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendStreamingMessage(SendMessageRequest request)
        returns stream<StreamResponse, Error?>|Error;

    # Retrieves the current state of a task.
    #
    # + request - The task identifier, and optionally how much history to include
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(GetTaskRequest request) returns Task|Error;

    # Requests cancellation of an in-progress task.
    #
    # + request - The task identifier, and any additional context for the agent
    # + return - The updated Task, or an error
    isolated remote function cancelTask(CancelTaskRequest request) returns Task|Error;

    # Opens a stream on an existing task.
    #
    # + request - The task identifier
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(SubscribeToTaskRequest request)
        returns stream<StreamResponse, Error?>|Error;

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + request - Optional filter and pagination parameters; every field is
    #             optional, so this defaults to listing with the server's
    #             own defaults
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(ListTasksRequest request = {}) returns ListTasksResponse|Error;

    # Registers a webhook to receive updates for a task.
    #
    # Takes the configuration itself rather than a request wrapper: the
    # specification's CreateTaskPushNotificationConfig RPC is the one
    # operation with no dedicated request message.
    #
    # + request - The webhook configuration; its taskId identifies the task
    # + return - The created config as the server persisted it, or an error
    isolated remote function createTaskPushNotificationConfig(TaskPushNotificationConfig request)
        returns TaskPushNotificationConfig|Error;

    # Retrieves a previously registered push-notification webhook config.
    #
    # + request - The parent task id and the config's own id
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request)
        returns TaskPushNotificationConfig|Error;

    # Lists all push-notification webhook configs registered for a task.
    #
    # + request - The parent task id, and optional pagination parameters
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request)
        returns ListTaskPushNotificationConfigsResponse|Error;

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # + request - The parent task id and the config's own id
    # + return - Nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request)
        returns Error?;

    # Retrieves the agent's extended AgentCard.
    #
    # + request - Optional routing parameters; every field is optional, so
    #             this defaults to an empty request
    # + return - The extended AgentCard, or an error
    isolated remote function getExtendedAgentCard(GetExtendedAgentCardRequest request = {})
        returns AgentCard|Error;
};
