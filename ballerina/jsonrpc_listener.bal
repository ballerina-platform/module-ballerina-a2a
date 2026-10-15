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
import ballerina/log;

# The path the JSON-RPC binding is served at.
const string JSON_RPC_MOUNT_PATH = "rpc";

# Configuration for an `a2a:JsonRpcListener`: the same as for an
# `a2a:RestListener`, since both put an HTTP listener in front of the agent.
public type JsonRpcListenerConfiguration record {|
    *RestListenerConfiguration;
|};

# Serves `a2a:Service`s over JSON-RPC 2.0: the JSON-RPC binding at `/rpc`.
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
# `a2a:Context`; a `getAgentCard` function gives a card built from configuration. A
# JSON-RPC client names them in PascalCase (`SendMessage`), as the specification
# does, and the listener maps them.
#
# Two listeners built on the same `http:Listener`, one `a2a:RestListener` and one
# `a2a:JsonRpcListener`, publish one card at `/.well-known/agent-card.json` that
# lists both interfaces.
public isolated class JsonRpcListener {
    private final http:Listener httpListener;
    private final (http:ListenerAuthConfig[] & readonly)? authConfig;
    private final ListenerAuthenticator? authenticator;
    private final StreamTiming & readonly streamTiming;
    private final string interfaceScheme;
    private final string? publicUrl;
    private JsonRpcDispatcherService? dispatcher = ();

    # Creates a JsonRpcListener.
    #
    # + listenTo - A port, or an existing `http:Listener` to mount on
    # + config - How requests reach the agent; see `a2a:RestListener`
    # + return - An `a2a:Error` if `publicUrl` is unusable, the HTTP listener
    #            cannot be created, or an `auth` entry cannot be initialised
    public isolated function init(int|http:Listener listenTo, *JsonRpcListenerConfiguration config) returns Error? {
        string? publicUrl = config.publicUrl;
        if publicUrl is string {
            self.publicUrl = check normalisePublicUrl(publicUrl);
        } else {
            self.publicUrl = ();
        }
        http:ListenerAuthConfig[]? auth = config.auth;
        if auth is http:ListenerAuthConfig[] {
            if auth.length() == 0 {
                string msg = "JsonRpcListenerConfiguration.auth must contain at least one entry; "
                    + "leave it unset for no authentication";
                return error InternalError(msg, message = msg);
            }
            self.authConfig = auth.cloneReadOnly();
            self.authenticator = check new (auth.cloneReadOnly());
        } else {
            self.authConfig = ();
            self.authenticator = ();
        }
        if listenTo is http:Listener {
            self.httpListener = listenTo;
        } else {
            http:Listener|error created = new (listenTo, httpListenerConfigurationOf(config));
            if created is error {
                return wrapTransportError(created);
            }
            self.httpListener = created;
        }
        self.interfaceScheme = self.httpListener.getConfig().secureSocket is () ? "http" : "https";
        self.streamTiming = {idleTimeout: config.streamIdleTimeout, keepAliveInterval: config.keepAliveInterval};
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
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns error? {
        check checkMountPath(name);
        OperationBinding binding = new (a2aService, byMethodName = true);
        Capabilities capabilities = check capabilitiesOf(binding);
        AgentCard supplied = check agentCardOf(a2aService, binding);
        if capabilities.extendedAgentCard && self.authenticator is () {
            string msg = "a service that defines getExtendedAgentCard requires JsonRpcListenerConfiguration.auth: "
                + "the extended agent card is for authenticated callers (specification section 13.3)";
            return error InternalError(msg, message = msg);
        }
        ServedCards cards = new (self.authConfig, capabilities, JSONRPC);
        AgentCard & readonly served = cards.publicCard(supplied).cloneReadOnly();
        JsonRpcDispatcherService dispatcherService = new (served, binding, cards, self.authenticator,
                self.interfaceScheme, self.publicUrl, self.streamTiming);
        [CardRegistry, CardService, boolean] [registry, cardService, cardServiceIsNew] =
            cardStateFor(self.httpListener, self.interfaceScheme, self.publicUrl);
        check registry.add(served, JSONRPC, JSON_RPC_MOUNT_PATH);
        lock {
            self.dispatcher = dispatcherService;
        }
        if cardServiceIsNew {
            error? cardResult = self.httpListener.attach(cardService);
            if cardResult is error {
                return wrapTransportError(cardResult);
            }
        }
        error? result = self.httpListener.attach(dispatcherService, JSON_RPC_MOUNT_PATH);
        if result is error {
            return wrapTransportError(result);
        }
        log:printInfo("A2A service attached", path = "/" + JSON_RPC_MOUNT_PATH,
                operations = binding.defined.toString());
    }

    # Detaches the attached service.
    #
    # + a2aService - The service to detach
    # + return - An `a2a:Error` if detachment fails
    public isolated function detach(Service a2aService) returns error? {
        JsonRpcDispatcherService? dispatcherService;
        lock {
            dispatcherService = self.dispatcher;
            self.dispatcher = ();
        }
        if dispatcherService is JsonRpcDispatcherService {
            error? result = self.httpListener.detach(dispatcherService);
            if result is error {
                return wrapTransportError(result);
            }
        }
    }

    # Starts the listener.
    #
    # + return - An `a2a:Error` if the listener could not start
    public isolated function 'start() returns error? {
        error? result = self.httpListener.'start();
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Stops the listener, letting in-flight requests finish.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function gracefulStop() returns error? {
        error? result = self.httpListener.gracefulStop();
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Stops the listener immediately, dropping in-flight requests.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function immediateStop() returns error? {
        error? result = self.httpListener.immediateStop();
        if result is error {
            return wrapTransportError(result);
        }
    }
}

# Checks the path a service was declared at.
#
# + name - The `name` the runtime passed to `attach`
# + return - An `a2a:Error` for any path but none or `rpc`
isolated function checkMountPath(string[]|string? name) returns Error? {
    string path;
    if name is string {
        path = name;
    } else if name is string[] {
        path = string:'join("/", ...name);
    } else {
        path = "";
    }
    while path.startsWith("/") {
        path = path.substring(1);
    }
    if path == "" || path == JSON_RPC_MOUNT_PATH {
        return;
    }
    string msg = string `an a2a:JsonRpcListener serves its service at /${JSON_RPC_MOUNT_PATH}: declare it without `
        + string `a path, not at "/${path}"`;
    return error InternalError(msg, message = msg);
}
