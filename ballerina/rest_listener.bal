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

// The HTTP-family transport: a listener that serves `a2a:Service`s over the
// HTTP+JSON (REST) binding. It owns everything about the wire -- the port, TLS,
// authentication, the address the card advertises, stream keep-alives -- and
// nothing about the agent itself, which its service owns.

import ballerina/http;

# Configuration for an `a2a:RestListener`: how requests reach the agent. Every field is in
# `a2a:ListenerConfiguration`, which `a2a:JsonRpcListenerConfiguration` includes as well.
public type RestListenerConfiguration record {|
    *ListenerConfiguration;
|};

# Serves `a2a:Service`s over HTTP: the HTTP+JSON (REST) binding, at `/rest` unless the
# service is declared at another path, or at `/`.
#
# The listener carries traffic and nothing else. The agent is a service attached
# to it, at a path that names the binding:
#
# ```ballerina
# listener a2a:RestListener agent = new (9090);
#
# @a2a:ServiceConfig {agentCard: {name: "Weather Agent", ..., capabilities: {}, supportedInterfaces: []}}
# isolated service on agent {
#     private final a2a:DefaultHandler handler = new (new WeatherExecutor());
#
#     isolated resource function post message\:send(a2a:Context context, a2a:SendMessageRequest request)
#             returns a2a:Task|a2a:Message|a2a:Error {
#         return self.handler.handleSendMessage(context, request);
#     }
#     // ...the other operations the agent supports
# }
# ```
#
# When a service is attached the listener reads its agent card, finds which of
# the A2A operations it defines, and serves the card at
# `/.well-known/agent-card.json` with the capabilities those operations imply and
# an HTTP+JSON interface at this listener's address plus its path (`/rest` unless
# the service is declared elsewhere) -- so a card
# cannot advertise a capability the agent does not provide. Pass
# `capabilities: {}` and `supportedInterfaces: []` as placeholders; they are
# replaced. An operation the service does not define answers
# `UnsupportedOperationError`.
public isolated class RestListener {
    private final ListenerTransport transport;

    # Creates a RestListener.
    #
    # + listenTo - A port, or an existing `http:Listener` to mount on
    # + config - How requests reach the agent. Given a port, its
    #            `http:ListenerConfiguration` fields (`timeout`, `secureSocket`,
    #            `host`, ...) configure the listener that is created; given an
    #            existing `http:Listener`, that listener was configured when it
    #            was built, so they have nothing to apply to and are ignored.
    # + return - An `a2a:Error` if a stream timing is negative, `publicUrl` is
    #            unusable, the HTTP listener cannot be created, or an `auth`
    #            entry cannot be initialised (for
    #            example a JWKS that cannot be preloaded, or an LDAP server that
    #            cannot be reached)
    public isolated function init(int|http:Listener listenTo, *RestListenerConfiguration config) returns Error? {
        self.transport = check new (listenTo, config, "RestListenerConfiguration", HTTP_JSON, REST_MOUNT_PATH, false,
                newRestService);
    }

    # Attaches an agent's `a2a:Service`.
    #
    # One agent per listener: a second service must carry the same agent card.
    #
    # + a2aService - The service to serve
    # + name - Unset for a service declared without a path; `rest` is also
    #          accepted. Any other path is refused
    # + return - An `a2a:Error` if the path is not a binding this listener
    #            serves, the service has no agent card or two, defines an
    #            incomplete group of operations, defines
    #            the `get extendedAgentCard` resource without `auth`, or attachment fails
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns Error? =>
        self.transport.attach(a2aService, name);

    # Detaches the attached service.
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

# Builds the dispatcher that serves a service over HTTP+JSON.
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
isolated function newRestService(AgentCard served, OperationBinding binding, ServedCards cards,
        ListenerAuthenticator? authenticator, string interfaceScheme, string? publicUrl, StreamTiming streamTiming,
        string mountPath, boolean validateInputModes) returns http:Service =>
    new RestDispatcherService(served, binding, cards, authenticator, interfaceScheme, publicUrl,
            streamTiming, mountPath, validateInputModes);


# The path the HTTP+JSON binding is served at when a service is declared without one.
const string REST_MOUNT_PATH = "rest";
