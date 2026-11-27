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

// The JSON-RPC transport: a listener that serves an `a2a:Service` over the
// JSON-RPC binding. It owns the wire the same way `a2a:RestListener` does --
// the port, TLS, authentication, the address the card advertises -- and the
// agent is the service attached to it, whose operations are `remote` functions
// named for the JSON-RPC methods.

import ballerina/http;

# The path the JSON-RPC binding is served at when a service is declared without one.
const string JSON_RPC_MOUNT_PATH = "rpc";

# Configuration for an `a2a:JsonRpcListener`: how requests reach the agent. Every field is in
# `a2a:ListenerConfiguration`, which `a2a:RestListenerConfiguration` includes as well.
public type JsonRpcListenerConfiguration record {|
    *ListenerConfiguration;
|};

# Serves `a2a:Service`s over JSON-RPC 2.0: the JSON-RPC binding, at `/rpc` unless the
# service is declared at another path, or at `/`.
#
# ```ballerina
# listener a2a:JsonRpcListener agent = new (9090);
#
# @a2a:ServiceConfig {agentCard: {name: "Weather Agent", ..., capabilities: {}, supportedInterfaces: []}}
# isolated service on agent {
#     private final a2a:DefaultHandler handler = new (new WeatherExecutor());
#
#     isolated remote function sendMessage(a2a:Context context, a2a:SendMessageRequest request)
#             returns a2a:Task|a2a:Message|a2a:Error {
#         return self.handler.handleSendMessage(context, request);
#     }
#     // ...the other operations the agent supports
# }
# ```
#
# The operations are the remote functions `sendMessage`, `sendStreamingMessage`,
# `subscribeToTask`, `getTask`, `listTasks`, `cancelTask`,
# `createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`,
# `listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig` and
# `getExtendedAgentCard`, each taking its request record and, optionally, an
# `a2a:Context`. A `getAgentCard` function gives a card built from configuration;
# it takes no parameters, since it runs once, when the service is attached, and
# there is no caller then. A
# JSON-RPC client names them in PascalCase (`SendMessage`), as the specification
# does, and the listener maps them.
#
# Two listeners built on the same `http:Listener`, one `a2a:RestListener` and one
# `a2a:JsonRpcListener`, publish one card at `/.well-known/agent-card.json` that
# lists both interfaces.
public isolated class JsonRpcListener {
    private final ListenerTransport transport;

    # Creates a JsonRpcListener.
    #
    # + listenTo - A port, or an existing `http:Listener` to mount on
    # + config - How requests reach the agent; see `a2a:RestListener`
    # + return - An `a2a:Error` if a stream timing is negative, `publicUrl` is
    #            unusable, the HTTP listener cannot be created, or an `auth`
    #            entry cannot be initialised
    public isolated function init(int|http:Listener listenTo, *JsonRpcListenerConfiguration config) returns Error? {
        self.transport = check new (listenTo, config, "JsonRpcListenerConfiguration", JSONRPC, JSON_RPC_MOUNT_PATH, true,
                newJsonRpcService);
    }

    # Attaches an agent's `a2a:Service`.
    #
    # One agent per listener.
    #
    # + a2aService - The service to serve
    # + name - Unset for a service declared without a path; `rpc` is also
    #          accepted. Any other path is refused
    # + return - An `a2a:Error` if the path is not one this listener serves,
    #            the service has no agent card or two, defines an incomplete
    #            group of operations, defines `getExtendedAgentCard` without
    #            `auth`, or attachment fails
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns Error? =>
        self.transport.attach(a2aService, name);

    # Detaches the attached service; any other service is left alone.
    #
    # + a2aService - The service to detach
    # + return - An `a2a:Error` if detachment fails
    public isolated function detach(Service a2aService) returns Error? => self.transport.detach(a2aService);

    # Starts the listener.
    #
    # + return - An `a2a:Error` if the listener could not start
    public isolated function 'start() returns Error? => self.transport.'start();

    # Stops the listener, letting in-flight requests finish.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function gracefulStop() returns Error? => self.transport.gracefulStop();

    # Stops the listener immediately, dropping in-flight requests.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function immediateStop() returns Error? => self.transport.immediateStop();
}

# Builds the dispatcher that serves a service over JSON-RPC.
#
# + served - The agent card the service serves
# + binding - The operations the service implements
# + cards - The cards served by the listener
# + authenticator - Authenticates requests, or `()` when the listener is open
# + interfaceScheme - The scheme the card advertises for this interface
# + publicUrl - The public base URL the card advertises, or `()` to derive it from the request
# + streamTiming - How long a stream stays open and how often it is kept alive
# + mountPath - The path the dispatcher is served at
# + validateInputModes - Whether an incoming message is checked against the card's accepted input modes
# + return - The dispatcher
isolated function newJsonRpcService(AgentCard served, OperationBinding binding, ServedCards cards,
        ListenerAuthenticator? authenticator, string interfaceScheme, string? publicUrl, StreamTiming streamTiming,
        string mountPath, boolean validateInputModes) returns http:Service =>
    new JsonRpcDispatcherService(served, binding, cards, authenticator, interfaceScheme, publicUrl,
            streamTiming, mountPath, validateInputModes);
