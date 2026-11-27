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

// The A2A client contract, shared across transport bindings.

# The client-side A2A operation set (specification section 9.4), declared once
# as the contract every binding's client implements, rather than repeating
# eleven signatures per client type. `a2a:RestClient` and `a2a:JsonRpcClient`
# include it via `*ClientOperations;`, and the public `a2a:Client` delegates
# to whichever of them the card calls for.
#
# Not public: Ballerina object types are structurally typed, so a caller
# writes against `a2a:Client`, or declares their own local object type
# covering the methods they use, with no dependency on this one.
#
# Every method returns a narrowed `a2a:Error`, never a bare `error`. The
# `+ return` doc on each names the subtype a protocol failure produces;
# transport and decode failures are wrapped into `a2a:InternalError` at the
# binding boundary, so the fallback case is still matchable.
type ClientOperations isolated client object {

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

# The bindings `a2a:Client` can speak. A card that offers only another one (gRPC) cannot be called by it.
public type ClientBinding "JSONRPC"|"HTTP+JSON";

# An A2A protocol client for a remote agent, over whichever binding its Agent
# Card offers.
#
# Give it the agent's base URL, or an `a2a:AgentCard` already resolved via
# `a2a:resolveAgentCard`. The binding is chosen from the card's
# `supportedInterfaces`: the first interface, in the card's order, that is
# JSON-RPC or HTTP+JSON and declares A2A v1.0 (the specification lists the
# preferred interface first). Pass `preferredBinding` to take a binding the
# card also offers ahead of that order. A card with no such interface is
# rejected at construction, naming the bindings it does offer.
#
# ```ballerina
# a2a:Client agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage({
#     message: {messageId: "m1", role: a2a:ROLE_USER, parts: [{text: "Plan a trip to Kandy"}]}
# });
# ```
#
# Every operation behaves the same whichever binding was chosen, and a failure
# is the same `a2a:Error` subtype. Use `a2a:RestClient` or `a2a:JsonRpcClient`
# directly to insist on one binding.
public isolated client class Client {
    *ClientOperations;

    private final ClientOperations delegate;
    private final ClientBinding binding;

    # Creates a client for a remote A2A agent.
    #
    # + agent - The agent's base URL, or an AgentCard already resolved via
    #           `a2a:resolveAgentCard`
    # + preferredBinding - A binding to use when the card offers it, ahead of
    #                      the card's own order
    # + config - Client configuration, passed as named arguments; see
    #            `a2a:ClientConfiguration`
    # + return - A typed Error: from resolveAgentCard, when the card offers no
    #            binding this client speaks, or from the chosen binding's own
    #            construction
    public isolated function init(AgentCard|string agent, ClientBinding? preferredBinding = (),
            *ClientConfiguration config) returns Error? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, config.headers, clientConfig = config.clientConfig)
            : agent;
        ClientBinding chosen = check selectClientBinding(card, preferredBinding);
        self.binding = chosen;
        if chosen == JSONRPC {
            self.delegate = check new JsonRpcClient(card, clientConfig = config.clientConfig,
                    headers = config.headers, tenant = config.tenant, requestedExtensions = config.requestedExtensions,
                    maxReconnectAttempts = config.maxReconnectAttempts, credentials = config.credentials);
        } else {
            self.delegate = check new RestClient(card, clientConfig = config.clientConfig,
                    headers = config.headers, tenant = config.tenant, requestedExtensions = config.requestedExtensions,
                    maxReconnectAttempts = config.maxReconnectAttempts, credentials = config.credentials);
        }
    }

    # The binding this client speaks, as chosen from the card.
    #
    # + return - `JSONRPC` or `HTTP+JSON`
    public isolated function getBinding() returns ClientBinding => self.binding;

    # Sends a message to the remote agent.
    #
    # + request - The message and its send options
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error {
        return self.delegate->sendMessage(request);
    }

    # Sends a message and receives updates as they happen.
    #
    # + request - The message and its send options
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendStreamingMessage(SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.delegate->sendStreamingMessage(request);
    }

    # Retrieves the current state of a task.
    #
    # + request - The task identifier, and optionally how much history to include
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(GetTaskRequest request) returns Task|Error {
        return self.delegate->getTask(request);
    }

    # Requests cancellation of an in-progress task.
    #
    # + request - The task identifier, and any additional context for the agent
    # + return - The updated Task, or an error
    isolated remote function cancelTask(CancelTaskRequest request) returns Task|Error {
        return self.delegate->cancelTask(request);
    }

    # Opens a stream on an existing task.
    #
    # + request - The task identifier
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.delegate->subscribeToTask(request);
    }

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + request - Optional filter and pagination parameters; every field is
    #             optional, so this defaults to listing with the server's
    #             own defaults
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(ListTasksRequest request = {}) returns ListTasksResponse|Error {
        return self.delegate->listTasks(request);
    }

    # Registers a webhook to receive updates for a task.
    #
    # Takes the configuration itself rather than a request wrapper: the
    # specification's CreateTaskPushNotificationConfig RPC is the one
    # operation with no dedicated request message.
    #
    # + request - The webhook configuration; its taskId identifies the task
    # + return - The created config as the server persisted it, or an error
    isolated remote function createTaskPushNotificationConfig(TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        return self.delegate->createTaskPushNotificationConfig(request);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + request - The parent task id and the config's own id
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request)
            returns TaskPushNotificationConfig|Error {
        return self.delegate->getTaskPushNotificationConfig(request);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + request - The parent task id, and optional pagination parameters
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request)
            returns ListTaskPushNotificationConfigsResponse|Error {
        return self.delegate->listTaskPushNotificationConfigs(request);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # + request - The parent task id and the config's own id
    # + return - Nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request)
            returns Error? {
        return self.delegate->deleteTaskPushNotificationConfig(request);
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + request - Optional routing parameters; every field is optional, so
    #             this defaults to an empty request
    # + return - The extended AgentCard, or an error
    isolated remote function getExtendedAgentCard(GetExtendedAgentCardRequest request = {}) returns AgentCard|Error {
        return self.delegate->getExtendedAgentCard(request);
    }
}

# Picks the binding a client speaks from the card.
#
# + card - The agent's card
# + preferred - A binding to take if the card offers it
# + return - The binding, or an Error naming what the card does offer
isolated function selectClientBinding(AgentCard card, ClientBinding? preferred) returns ClientBinding|Error {
    ClientBinding? first = ();
    string[] offered = [];
    foreach AgentInterface iface in card.supportedInterfaces {
        offered.push(iface.protocolBinding);
        ClientBinding? binding = iface.protocolBinding == JSONRPC ? JSONRPC
            : iface.protocolBinding == HTTP_JSON ? HTTP_JSON : ();
        string? version = iface?.protocolVersion;
        // An interface that declares another protocol version is not one this client can speak.
        if binding is () || (version is string && version != "1.0") {
            continue;
        }
        if preferred is () || preferred == binding {
            return binding;
        }
        first = first ?: binding;
    }
    if first is ClientBinding {
        return first;
    }
    string msg = string `the AgentCard offers no JSON-RPC or HTTP+JSON interface for A2A 1.0 (it offers: `
        + string `${offered.length() == 0 ? "none" : string:'join(", ", ...offered)}), and those are the only `
        + "bindings this client speaks";
    return error InternalError(msg, message = msg);
}
