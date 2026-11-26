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
    private final http:Listener httpListener;
    private final (http:ListenerAuthConfig[] & readonly)? authConfig;
    private final ListenerAuthenticator? authenticator;
    private final StreamTiming & readonly streamTiming;
    private final string interfaceScheme;
    private final string? publicUrl;
    private final boolean validateInputModes;
    private Service? agentService = ();
    private JsonRpcDispatcherService? dispatcher = ();
    // The path the attached service is served at, empty for the root.
    private string mountPath = JSON_RPC_MOUNT_PATH;

    # Creates a JsonRpcListener.
    #
    # + listenTo - A port, or an existing `http:Listener` to mount on
    # + config - How requests reach the agent; see `a2a:RestListener`
    # + return - An `a2a:Error` if a stream timing is negative, `publicUrl` is
    #            unusable, the HTTP listener cannot be created, or an `auth`
    #            entry cannot be initialised
    public isolated function init(int|http:Listener listenTo, *JsonRpcListenerConfiguration config) returns Error? {
        check checkStreamTiming("JsonRpcListenerConfiguration", config.streamIdleTimeout, config.keepAliveInterval);
        // A listener built on an `http:Listener` that an earlier A2A listener was built on takes that one's `auth`
        // and `publicUrl` when it sets none, so only a real conflict is an error.
        var inherited = inheritedSettings(listenTo, config.auth, config.publicUrl);
        http:ListenerAuthConfig[]? inheritedAuth = inherited[0];
        string? publicUrl = inherited[1];
        if publicUrl is string {
            self.publicUrl = check normalisePublicUrl("JsonRpcListenerConfiguration", publicUrl);
        } else {
            self.publicUrl = ();
        }
        http:ListenerAuthConfig[]? auth = inheritedAuth;
        if auth is http:ListenerAuthConfig[] {
            if auth.length() == 0 {
                string msg = "JsonRpcListenerConfiguration.auth must contain at least one entry; "
                    + "leave it unset for no authentication";
                return error InternalError(msg, message = msg);
            }
            self.authConfig = auth.cloneReadOnly();
            self.authenticator = check new ("JsonRpcListenerConfiguration", auth.cloneReadOnly());
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
        self.validateInputModes = config.validateInputModes;
        if listenTo is http:Listener {
            rememberSharedSettings(listenTo, self.authConfig, self.publicUrl);
        }
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
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns Error? {
        string mountPath = check mountPathOf(name, JSON_RPC_MOUNT_PATH);
        OperationBinding binding = new (a2aService, byMethodName = true);
        // Before anything that would say a method is missing: a typo is why it is missing, and that is the useful
        // thing to report.
        if binding.problems.length() > 0 {
            string msg = "an a2a:Service attached to a JsonRpcListener has remote functions that cannot serve an A2A "
                + string `method: ${string:'join("; ", ...binding.problems)}`;
            return error InternalError(msg, message = msg);
        }
        Capabilities capabilities = check capabilitiesOf(binding);
        AgentCard supplied = check agentCardOf(a2aService, binding);
        // Specification section 13.3: `GetExtendedAgentCard` MUST require
        // authentication, so a service that would serve it to anyone must not start.
        if capabilities.extendedAgentCard && self.authenticator is () {
            string msg = "a service that defines getExtendedAgentCard requires JsonRpcListenerConfiguration.auth: "
                + "the extended agent card is for authenticated callers";
            return error InternalError(msg, message = msg);
        }
        ServedCards cards = new (self.authConfig, capabilities, JSONRPC);
        AgentCard & readonly served = cards.publicCard(supplied).cloneReadOnly();
        JsonRpcDispatcherService dispatcherService = new (served, binding, cards, self.authenticator,
                self.interfaceScheme, self.publicUrl, self.streamTiming, mountPath, self.validateInputModes);
        check addCardBinding(self.httpListener, self.interfaceScheme, served, JSONRPC, mountPath,
                self.authConfig, self.publicUrl, self.validateInputModes);
        lock {
            self.agentService = a2aService;
            self.dispatcher = dispatcherService;
            self.mountPath = mountPath;
        }
        error? result = attachAt(self.httpListener, dispatcherService, mountPath);
        if result is error {
            self.forget();
            return wrapTransportError(result);
        }
        log:printInfo("A2A service attached", path = "/" + mountPath,
                operations = binding.defined.toString());
    }

    # Detaches the attached service; any other service is left alone.
    #
    # + a2aService - The service to detach
    # + return - An `a2a:Error` if detachment fails
    public isolated function detach(Service a2aService) returns Error? {
        JsonRpcDispatcherService? dispatcherService = ();
        string mountPath = JSON_RPC_MOUNT_PATH;
        lock {
            if self.agentService === a2aService {
                dispatcherService = self.dispatcher;
                mountPath = self.mountPath;
                self.agentService = ();
                self.dispatcher = ();
            }
        }
        if dispatcherService is JsonRpcDispatcherService {
            removeCardBinding(self.httpListener, mountPath);
            error? result = self.httpListener.detach(dispatcherService);
            if result is error {
                return wrapTransportError(result);
            }
        }
    }

    # Undoes the bookkeeping of an attach that failed partway, so the card does
    # not advertise an interface that serves nothing and its path can be used
    # again.
    private isolated function forget() {
        string mountPath;
        lock {
            mountPath = self.mountPath;
        }
        removeCardBinding(self.httpListener, mountPath);
        lock {
            self.agentService = ();
            self.dispatcher = ();
        }
    }

    # Starts the listener.
    #
    # + return - An `a2a:Error` if the listener could not start
    public isolated function 'start() returns Error? {
        error? result = self.httpListener.'start();
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Stops the listener, letting in-flight requests finish.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function gracefulStop() returns Error? {
        error? result = self.httpListener.gracefulStop();
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Stops the listener immediately, dropping in-flight requests.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function immediateStop() returns Error? {
        error? result = self.httpListener.immediateStop();
        if result is error {
            return wrapTransportError(result);
        }
    }
}
