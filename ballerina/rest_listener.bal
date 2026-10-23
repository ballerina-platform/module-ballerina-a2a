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
import ballerina/log;

# Configuration for an `a2a:RestListener`: how requests reach the agent.
public type RestListenerConfiguration record {|
    *http:ListenerConfiguration;
    # How callers authenticate, as the same `http:ListenerAuthConfig` entries a
    # service's `@http:ServiceConfig` takes: JWT validation, OAuth2 token
    # introspection, or Basic against a file or LDAP user store, each
    # optionally requiring `scopes`. The entries are alternatives; a request
    # that any one accepts is admitted.
    #
    # When set, every A2A operation must authenticate (the public card at
    # `/.well-known/agent-card.json` stays open, and a path the listener does
    # not serve is a plain 404), per [specification
    # section 7.4](https://a2a-protocol.org/latest/specification/#74-server-authentication-responsibilities):
    # a missing or invalid credential is a 401 with a `WWW-Authenticate`
    # challenge, and a valid one that lacks a required scope is a 403. Unset
    # means the listener authenticates nothing, so put it behind something that
    # does.
    #
    # The authenticated identity (a JWT's `sub`, the introspected `sub` or
    # `username`, or the Basic username) becomes the task owner scope, so a
    # caller sees only its own tasks ([section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping));
    # a `DefaultHandlerConfiguration.ownerResolver`, if configured, takes
    # precedence. Keep the card's `securitySchemes` in agreement with what is
    # configured here. A card that declares neither `securitySchemes` nor
    # `securityRequirements` gets both derived from `auth`: `Bearer` for JWT and
    # OAuth2 entries, `Basic` for file and LDAP ones, one requirement per entry.
    # Declare them yourself -- for example an `openIdConnect` scheme with your
    # provider's discovery URL -- and nothing is derived.
    #
    # Applies whether `listenTo` is a port or an existing `http:Listener`.
    http:ListenerAuthConfig[]? auth = ();
    # Seconds a live `sendStreamingMessage`/`subscribeToTask` stream may sit
    # idle — no event, from a task still being driven — before the server
    # ends it. The backstop for a client that disconnects without the HTTP
    # layer surfacing it as a clean stream close; a healthy long-running
    # task's own events reset this on every one they produce, so raising it
    # only matters for a task that can legitimately sit silent for a long
    # stretch (e.g. paused on `TASK_STATE_AUTH_REQUIRED`, whose stream stays
    # open) with a subscriber still attached. `0` turns the backstop off; a
    # negative value is refused when the listener is created.
    decimal streamIdleTimeout = 300;
    # Seconds a live `sendStreamingMessage`/`subscribeToTask` stream may go
    # without an event before the server sends an SSE comment frame
    # (`: keep-alive`), so a task that is simply taking a while does not lose
    # its stream to an idle timeout. HTTP stacks close a connection that has
    # been silent for too long -- Ballerina's defaults are 60 seconds for a
    # listener and 30 for a client -- and a long-running agent can easily be
    # quiet that long between updates. Keep this below the smallest idle
    # timeout in play. `0` sends no keep-alives; a negative value is refused
    # when the listener is created. Keep-alives are not activity:
    # `streamIdleTimeout` still ends a stream nothing is being produced on.
    decimal keepAliveInterval = 15;
    # The base URL clients reach this agent at, served as the card's HTTP+JSON
    # interface URL, e.g. `https://agents.example.com/travel`. Unset, the URL is
    # built from the request's `Host` header and the scheme this listener really
    # serves (`https` when `secureSocket` is configured, otherwise `http`), which
    # is right when clients reach the listener directly.
    #
    # Set it when they do not: behind a proxy or gateway that terminates TLS or
    # rewrites the host or path, or when `listenTo` is an existing
    # `http:Listener` whose public address this package cannot know. It must
    # start with `http://` or `https://`, and have no query or fragment. A
    # trailing `/` is dropped. `X-Forwarded-*` headers are deliberately not
    # consulted: any caller can send them, and this setting is the explicit
    # answer.
    string? publicUrl = ();
    # Whether `sendMessage` and `sendStreamingMessage` answer
    # `ContentTypeNotSupportedError` (HTTP 400) for a message part whose
    # `mediaType` the agent card does not declare, per [specification section
    # 3.1.1](https://a2a-protocol.org/latest/specification/#311-a2a-specific-errors)
    # and the "SHOULD reject unexpected media types" of section 13.
    #
    # The media types accepted are the card's `defaultInputModes` together with
    # every skill's `inputModes`. A card that declares none accepts everything,
    # and a part that states no `mediaType` is never rejected. A mode matches
    # ignoring case and parameters (`text/plain; charset=utf-8`), a bare type
    # such as `text` matches all its subtypes, and `type/*` and `*/*` are
    # wildcards.
    #
    # Off by default, as in the reference SDKs: turning it on starts refusing
    # content an agent used to accept, and the A2A TCK's `CORE-SEND-003` sends an
    # undeclared media type and expects the send to succeed.
    boolean validateInputModes = false;
|};

# The `http:ListenerConfiguration` half of a `RestListenerConfiguration`:
# everything left once this package's own fields are taken out.
#
# `RestListenerConfiguration` includes `http:ListenerConfiguration`, so a
# caller can write `new a2a:RestListener(9090, timeout = 120)`. The
# listener built for a port used to be created from an empty configuration,
# silently dropping every one of those fields -- a `timeout`, or a
# `secureSocket`, had no effect at all.
#
# + config - The full configuration
# + return - The HTTP listener's own settings
isolated function httpListenerConfigurationOf(RestListenerConfiguration config) returns http:ListenerConfiguration {
    RestListenerConfiguration {
        auth: _, streamIdleTimeout: _, keepAliveInterval: _, publicUrl: _, validateInputModes: _, ...httpConfig
    } = config;
    return {...httpConfig};
}

# Serves `a2a:Service`s over HTTP: the HTTP+JSON (REST) binding at `/rest`.
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
# an HTTP+JSON interface at this listener's address plus `/rest` -- so a card
# cannot advertise a capability the agent does not provide. Pass
# `capabilities: {}` and `supportedInterfaces: []` as placeholders; they are
# replaced. An operation the service does not define answers
# `UnsupportedOperationError`.
public isolated class RestListener {
    private final http:Listener httpListener;
    private final (http:ListenerAuthConfig[] & readonly)? authConfig;
    private final ListenerAuthenticator? authenticator;
    private final StreamTiming & readonly streamTiming;
    // What the served card's interface URL is built from: the scheme this
    // listener really serves, and the explicit public URL if one was configured.
    private final string interfaceScheme;
    private final string? publicUrl;
    private final boolean validateInputModes;
    private AttachedService[] attached = [];

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
        check checkStreamTiming("RestListenerConfiguration", config.streamIdleTimeout, config.keepAliveInterval);
        string? publicUrl = config.publicUrl;
        if publicUrl is string {
            self.publicUrl = check normalisePublicUrl(publicUrl);
        } else {
            self.publicUrl = ();
        }
        // The auth handlers are built first, and their failure returned first: some
        // of them reach the identity provider while being built (a JWKS cache is
        // preloaded, an LDAP server is connected to), so a listener that cannot
        // reach it must fail before anything is bound.
        http:ListenerAuthConfig[]? auth = config.auth;
        if auth is http:ListenerAuthConfig[] {
            if auth.length() == 0 {
                string msg = "RestListenerConfiguration.auth must contain at least one entry; "
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
        // The scheme comes from the HTTP listener itself, so it is right for a
        // port and for an `http:Listener` passed in.
        self.interfaceScheme = self.httpListener.getConfig().secureSocket is () ? "http" : "https";
        self.streamTiming = {idleTimeout: config.streamIdleTimeout, keepAliveInterval: config.keepAliveInterval};
        self.validateInputModes = config.validateInputModes;
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
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns error? {
        string mountPath = check mountPathOf(name);
        OperationBinding binding = new (a2aService);
        Capabilities capabilities = check capabilitiesOf(binding);
        AgentCard supplied = check agentCardOf(a2aService, binding);
        // Refused before anything is bound: [specification section 13.3](https://a2a-protocol.org/latest/specification/#133-extended-agent-card-access-control)
        // says `GetExtendedAgentCard` MUST require authentication, so a
        // service that would serve it to anyone must not start.
        if capabilities.extendedAgentCard && self.authenticator is () {
            string msg = "a service that defines the get extendedAgentCard resource requires RestListenerConfiguration.auth: "
                + "the extended agent card is for authenticated callers";
            return error InternalError(msg, message = msg);
        }
        ServedCards cards = new (self.authConfig, capabilities);
        AgentCard & readonly served = cards.publicCard(supplied).cloneReadOnly();
        RestDispatcherService dispatcherService = new (served, binding, cards, self.authenticator,
                self.interfaceScheme, self.publicUrl, self.streamTiming, mountPath, self.validateInputModes);
        CardRegistry|error registry = cardRegistryFor(self.httpListener, self.interfaceScheme, self.publicUrl);
        if registry is error {
            return wrapTransportError(registry);
        }
        check registry.add(served, HTTP_JSON, mountPath);
        lock {
            self.attached.push({agentService: a2aService, dispatcher: dispatcherService, mountPath});
        }
        error? result = self.httpListener.attach(dispatcherService, mountPath);
        if result is error {
            self.forget(a2aService, mountPath);
            return wrapTransportError(result);
        }
        log:printInfo("A2A service attached", path = "/" + mountPath, operations = binding.defined.toString());
    }

    # Detaches the attached service.
    #
    # + a2aService - The service to detach
    # + return - An `a2a:Error` if detachment fails
    public isolated function detach(Service a2aService) returns error? {
        RestDispatcherService? dispatcherService = ();
        lock {
            foreach int i in 0 ..< self.attached.length() {
                if self.attached[i].agentService === a2aService {
                    dispatcherService = self.attached[i].dispatcher;
                    removeCardBinding(self.httpListener, self.attached[i].mountPath);
                    _ = self.attached.remove(i);
                    break;
                }
            }
        }
        if dispatcherService is RestDispatcherService {
            error? result = self.httpListener.detach(dispatcherService);
            if result is error {
                return wrapTransportError(result);
            }
        }
    }

    # Undoes the bookkeeping of an attach that failed partway, so the card does
    # not advertise an interface that serves nothing and the path can be used
    # again.
    #
    # + a2aService - The service whose attach failed
    # + mountPath - The path it was being attached at
    private isolated function forget(Service a2aService, string mountPath) {
        lock {
            removeCardBinding(self.httpListener, mountPath);
            foreach int i in 0 ..< self.attached.length() {
                if self.attached[i].agentService === a2aService {
                    _ = self.attached.remove(i);
                    break;
                }
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

# Checks a configured public URL and puts it in the form the card serves.
#
# + url - `RestListenerConfiguration.publicUrl`
# + return - The URL without a trailing slash, or an `a2a:InternalError` if it
#            is not an absolute `http://` or `https://` URL with a host and no
#            query or fragment
isolated function normalisePublicUrl(string url) returns string|Error {
    string rest;
    if url.startsWith("https://") {
        rest = url.substring(8);
    } else if url.startsWith("http://") {
        rest = url.substring(7);
    } else {
        return invalidPublicUrl(url, "it must start with http:// or https://");
    }
    if url.includes("?") || url.includes("#") {
        return invalidPublicUrl(url, "it must not have a query or a fragment");
    }
    int? slash = rest.indexOf("/");
    string host = slash is int ? rest.substring(0, slash) : rest;
    if host == "" {
        return invalidPublicUrl(url, "it has no host");
    }
    return stripTrailingSlash(url);
}

# Checks the configured stream timing, which is in seconds and so cannot be
# negative.
#
# + configName - The configuration record's name, for the message
# + idleTimeout - `streamIdleTimeout`
# + keepAliveInterval - `keepAliveInterval`
# + return - An `a2a:InternalError` naming the first negative field
isolated function checkStreamTiming(string configName, decimal idleTimeout, decimal keepAliveInterval) returns Error? {
    string? negative = idleTimeout < 0d ? "streamIdleTimeout" : keepAliveInterval < 0d ? "keepAliveInterval" : ();
    if negative is string {
        string msg = string `${configName}.${negative} must not be negative; use 0 to turn it off`;
        return error InternalError(msg, message = msg);
    }
}

isolated function invalidPublicUrl(string url, string reason) returns Error {
    string msg = string `RestListenerConfiguration.publicUrl "${url}" is not usable: ${reason}`;
    return error InternalError(msg, message = msg);
}

# A service attached to a listener, with the dispatcher built for it.
type AttachedService record {|
    # The service, as the application declared it
    Service agentService;
    # The dispatcher built for it
    RestDispatcherService dispatcher;
    # The path it is mounted at
    string mountPath;
|};

# The path the HTTP+JSON binding is served at.
const string REST_MOUNT_PATH = "rest";

# Checks the path a service was declared at and gives the path it is served at.
#
# The binding is named by the listener, not by the path, so a service is
# declared without one (`service on new a2a:RestListener(9090)`). `/rest` is
# accepted for a service that spells it out.
#
# + name - The `name` the runtime passed to `attach`
# + return - `rest`, or an `a2a:Error` for any other path
isolated function mountPathOf(string[]|string? name) returns string|Error {
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
    if path == "" || path == REST_MOUNT_PATH {
        return REST_MOUNT_PATH;
    }
    string msg = string `an a2a:RestListener serves its service at /${REST_MOUNT_PATH}: declare it without a path, `
        + string `not at "/${path}"`;
    return error InternalError(msg, message = msg);
}
