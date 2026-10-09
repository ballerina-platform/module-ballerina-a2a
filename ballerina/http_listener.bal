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

// The HTTP-family transport: a listener that serves an `a2a:DefaultHandler`
// over the HTTP+JSON (REST) binding. It owns everything about the wire -- the
// port, TLS, authentication, the address the card advertises, stream
// keep-alives -- and nothing about the agent itself, which the handler owns.

import ballerina/http;

# Configuration for an `a2a:HttpListener`: how requests reach the agent.
public type HttpListenerConfiguration record {|
    *http:ListenerConfiguration;
    # How callers authenticate, as the same `http:ListenerAuthConfig` entries a
    # service's `@http:ServiceConfig` takes: JWT validation, OAuth2 token
    # introspection, or Basic against a file or LDAP user store, each
    # optionally requiring `scopes`. The entries are alternatives; a request
    # that any one accepts is admitted.
    #
    # When set, every request except the public card
    # (`/.well-known/agent-card.json`) must authenticate, per [specification
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
    # open) with a subscriber still attached.
    decimal streamIdleTimeout = 300;
    # Seconds a live `sendStreamingMessage`/`subscribeToTask` stream may go
    # without an event before the server sends an SSE comment frame
    # (`: keep-alive`), so a task that is simply taking a while does not lose
    # its stream to an idle timeout. HTTP stacks close a connection that has
    # been silent for too long -- Ballerina's defaults are 60 seconds for a
    # listener and 30 for a client -- and a long-running agent can easily be
    # quiet that long between updates. Keep this below the smallest idle
    # timeout in play. `0` sends no keep-alives. Keep-alives are not activity:
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
|};

# The `http:ListenerConfiguration` half of an `HttpListenerConfiguration`:
# everything left once this package's own fields are taken out.
#
# `HttpListenerConfiguration` includes `http:ListenerConfiguration`, so a
# caller can write `new a2a:HttpListener(9090, handler, timeout = 120)`. The
# listener built for a port used to be created from an empty configuration,
# silently dropping every one of those fields -- a `timeout`, or a
# `secureSocket`, had no effect at all.
#
# + config - The full configuration
# + return - The HTTP listener's own settings
isolated function httpListenerConfigurationOf(HttpListenerConfiguration config) returns http:ListenerConfiguration {
    HttpListenerConfiguration {
        auth: _, streamIdleTimeout: _, keepAliveInterval: _, publicUrl: _, ...httpConfig
    } = config;
    return {...httpConfig};
}

# Serves an `a2a:DefaultHandler` over the HTTP+JSON (REST) binding.
#
# Build the agent's handler, give it to the listener, and attach the agent's
# `a2a:Service`:
#
# ```ballerina
# final a2a:DefaultHandler handler = new ({
#     name: "Weather Agent",
#     description: "Answers weather questions",
#     version: "1.0.0",
#     skills: [],
#     defaultInputModes: ["text"],
#     defaultOutputModes: ["text"],
#     capabilities: {},         // derived by the listener
#     supportedInterfaces: []   // derived by the listener
# });
#
# listener a2a:HttpListener agent = new (9090, handler);
#
# service a2a:Service on agent {
#     isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
#             returns a2a:Message|a2a:Error? {
#         // the agent's logic
#     }
# }
# ```
#
# The listener serves the card at `/.well-known/agent-card.json`, fills in its
# `supportedInterfaces` with the HTTP+JSON entry at its own address, and
# overrides the capability flags to what is implemented and enabled — so a
# card cannot advertise a capability the server does not provide, or does not
# accept (see `DefaultHandlerConfiguration.streamingCapability`/
# `pushNotificationsCapability` for deliberately withholding one this listener
# does implement). Pass `capabilities: {}` and `supportedInterfaces: []` as
# placeholders; they are replaced.
#
# A service chooses its binding with `@a2a:ServiceConfig`; this listener serves
# `a2a:REST`, the default.
public isolated class HttpListener {
    private final http:Listener httpListener;
    private final DefaultHandler handler;
    private final AgentCard & readonly card;
    private final (AgentCard? & readonly) extendedCard;
    private final ListenerAuthenticator? authenticator;
    private final StreamTiming & readonly streamTiming;
    // What the served card's interface URL is built from: the scheme this
    // listener really serves, and the explicit public URL if one was configured.
    private final string interfaceScheme;
    private final string? publicUrl;
    private DispatcherService? dispatcher = ();

    # Creates an HttpListener.
    #
    # + listenTo - A port, or an existing `http:Listener` to mount on
    # + handler - The agent's handler, which this listener serves
    # + config - How requests reach the agent. Given a port, its
    #            `http:ListenerConfiguration` fields (`timeout`, `secureSocket`,
    #            `host`, ...) configure the listener that is created; given an
    #            existing `http:Listener`, that listener was configured when it
    #            was built, so they have nothing to apply to and are ignored.
    # + return - An `a2a:Error` if the handler has an extended card but no
    #            `auth` is configured, `publicUrl` is unusable, the HTTP listener
    #            cannot be created, or an `auth` entry cannot be initialised (for
    #            example a JWKS that cannot be preloaded, or an LDAP server that
    #            cannot be reached)
    public isolated function init(int|http:Listener listenTo, DefaultHandler handler,
            *HttpListenerConfiguration config) returns Error? {
        // Refused before anything is bound: [specification section 13.3](https://a2a-protocol.org/latest/specification/#133-extended-agent-card-access-control)
        // says `GetExtendedAgentCard` MUST require authentication, so a
        // listener that would serve it to anyone must not start.
        if handler.extendedAgentCard is AgentCard && config.auth is () {
            string msg = "DefaultHandlerConfiguration.extendedAgentCard requires HttpListenerConfiguration.auth: "
                + "the extended agent card is for authenticated callers (specification section 13.3)";
            return error InternalError(msg, message = msg);
        }
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
                string msg = "HttpListenerConfiguration.auth must contain at least one entry; "
                    + "leave it unset for no authentication";
                return error InternalError(msg, message = msg);
            }
            self.authenticator = check new (auth.cloneReadOnly());
        } else {
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
        self.handler = handler;
        // The extended card goes through deriveServedCard too, not just
        // withDerivedSecurity, for the same reason the public card does: it
        // must not advertise a capability the server does not provide. Left
        // undone, a developer who followed this README's own placeholder
        // example (`capabilities: {}, supportedInterfaces: []`) would get an
        // extended card that says streaming and push notifications are off
        // -- and specification 13.3 has clients replace their held card
        // with exactly this one ("SHOULD replace their cached public Agent
        // Card... for the duration of their authenticated session"), so a
        // spec-conformant client would then refuse operations the server
        // actually supports. `extendedCardConfigured: true` here (not
        // `self.extendedCard is AgentCard`, which is what the public card
        // uses): the extended card, being itself, has one configured.
        //
        // Derived here, per listener, rather than once on the handler: the
        // security schemes come from this listener's `auth`.
        AgentCard? extended = handler.extendedAgentCard;
        self.extendedCard = extended is AgentCard
            ? deriveServedCard(withDerivedSecurity(extended, auth), true,
                    handler.streamingCapability, handler.pushNotificationsCapability).cloneReadOnly()
            : ();
        self.card = deriveServedCard(withDerivedSecurity(handler.agentCard, auth), self.extendedCard is AgentCard,
                handler.streamingCapability, handler.pushNotificationsCapability).cloneReadOnly();
        self.streamTiming = {idleTimeout: config.streamIdleTimeout, keepAliveInterval: config.keepAliveInterval};
    }

    # Attaches the agent's `a2a:Service`.
    #
    # One service per listener in this release. The service's `onMessage` is
    # the agent's logic; the listener's `a2a:DefaultHandler` runs the rest of
    # the protocol around it. The service is bound to that handler, so every
    # listener given the same handler must attach this same service.
    #
    # + a2aService - The service to serve; `@a2a:ServiceConfig` chooses its
    #                binding
    # + name - Ignored; the A2A paths are fixed by the specification
    # + return - An `a2a:Error` if the service asks for a binding this listener
    #            does not serve, the handler already serves a different
    #            service, or attachment fails
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns error? {
        Protocol protocol = serviceConfigurationOf(a2aService).protocol;
        if protocol != REST {
            string msg = string `@a2a:ServiceConfig protocol ${protocol} is not supported yet: `
                + "a2a:HttpListener serves only a2a:REST (HTTP+JSON)";
            return error InternalError(msg, message = msg);
        }
        check self.handler.bindService(a2aService);
        DispatcherService dispatcherService = new (self.card, self.extendedCard, self.handler, self.authenticator,
                self.interfaceScheme, self.publicUrl, self.streamTiming);
        lock {
            self.dispatcher = dispatcherService;
        }
        error? result = self.httpListener.attach(dispatcherService);
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Detaches the attached service.
    #
    # + a2aService - The service to detach
    # + return - An `a2a:Error` if detachment fails
    public isolated function detach(Service a2aService) returns error? {
        DispatcherService? dispatcherService;
        lock {
            dispatcherService = self.dispatcher;
        }
        if dispatcherService is DispatcherService {
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

# Derives the card the server actually publishes from the one the developer
# supplied.
#
# The developer gives identity, skills, and I/O modes. This forces the
# `supportedInterfaces` to a single HTTP+JSON v1.0 entry — the only binding and
# version this server speaks — and sets the capability flags to what is
# implemented and enabled. In this release that is: streaming
# (sendStreamingMessage/subscribeToTask) and push notifications (the config
# CRUD operations plus real webhook delivery via the configured
# `a2a:PushNotificationSender`, `a2a:HttpPushNotificationSender` by default)
# are always *implemented*, but each is only *advertised* -- and, correspondingly,
# only accepted server-side -- when its `DefaultHandlerConfiguration` flag is left at
# its `true` default; a deployment that sets one `false` gets that capability
# rejected server-side exactly as if this listener had never implemented it,
# never a card that quietly claims something the server then refuses. Extended
# card is on only when the developer configured one, which is itself already a
# deliberate opt-in with nothing further to withhold.
#
# `extensions` is left exactly as the developer declared it, not derived --
# unlike the other three flags, this server has no way to know which
# extensions the developer's `onMessage` actually implements, so it cannot
# second-guess (or silently drop) that declaration the way it can for
# capabilities it fully owns.
#
# + supplied - The card the developer passed
# + extendedCardConfigured - Whether `DefaultHandlerConfiguration.extendedAgentCard`
#                            was set
# + streamingCapability - `DefaultHandlerConfiguration.streamingCapability`
# + pushNotificationsCapability - `DefaultHandlerConfiguration.pushNotificationsCapability`
# + return - The card to serve
isolated function deriveServedCard(AgentCard supplied, boolean extendedCardConfigured,
        boolean streamingCapability, boolean pushNotificationsCapability) returns AgentCard {
    // A mutable top level even when `supplied` is readonly, as a handler's card is:
    // `clone()` alone returns an immutable value unchanged.
    AgentCard card = {...supplied.clone()};
    card.supportedInterfaces = [
        {url: "", protocolBinding: HTTP_JSON, protocolVersion: A2A_PROTOCOL_VERSION}
    ];
    card.capabilities = {
        streaming: streamingCapability,
        pushNotifications: pushNotificationsCapability,
        extensions: supplied.capabilities.extensions,
        extendedAgentCard: extendedCardConfigured
    };
    return card;
}

# Checks a configured public URL and puts it in the form the card serves.
#
# + url - `HttpListenerConfiguration.publicUrl`
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

isolated function invalidPublicUrl(string url, string reason) returns Error {
    string msg = string `HttpListenerConfiguration.publicUrl "${url}" is not usable: ${reason}`;
    return error InternalError(msg, message = msg);
}
