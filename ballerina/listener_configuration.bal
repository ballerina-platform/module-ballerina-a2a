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

// The configuration both A2A listeners take. The two bindings differ in how an operation looks on the wire, not in how
// requests reach the agent, so the port, TLS, authentication, the public address, stream timing and input-mode checks
// are one record.

import ballerina/http;

# What every A2A listener is configured with, whichever binding it serves: how requests reach the agent.
#
# `a2a:RestListenerConfiguration` and `a2a:JsonRpcListenerConfiguration` both include it, so a field set here
# means the same for either listener. Everything that depends on the binding, such as an operation's wire format, is
# in the listener's own documentation.
public type ListenerConfiguration record {|
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
    # challenge, and a valid one that lacks a required scope is a 403. Both are
    # HTTP statuses, answered before a JSON-RPC envelope is read. Unset
    # means the listener authenticates nothing, so put it behind something that
    # does.
    #
    # The authenticated identity (a JWT's `sub`, the introspected `sub` or
    # `username`, or the Basic username), qualified by the provider the
    # entry trusts (`a2a:Context.authority`), becomes the task owner scope, so
    # a caller sees only its own tasks, and same-named accounts from different
    # providers stay apart ([section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping));
    # a `DefaultHandlerConfiguration.ownerResolver`, if configured, takes
    # precedence. A JWT entry that verifies with an HMAC secret or an in-memory
    # key must set `issuer`, since nothing else in it names its provider. Keep
    # the card's `securitySchemes` in agreement with what is configured here.
    # A card that declares neither `securitySchemes` nor `securityRequirements`
    # gets both derived from `auth`: `Bearer` for JWT and OAuth2 entries,
    # `Basic` for file and LDAP ones, one requirement per entry.
    # Declare them yourself -- for example an `openIdConnect` scheme with your
    # provider's discovery URL -- and nothing is derived.
    #
    # Applies whether `listenTo` is a port or an existing `http:Listener`. A
    # listener built on an `http:Listener` that another A2A listener was built
    # on, and that sets no `auth`, takes that listener's: the two publish one
    # card. Unset on the one built first and set on the one built after is an
    # error when the second attaches.
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
    # The base URL clients reach this agent at, e.g.
    # `https://agents.example.com/travel`. The card's interface URL for this
    # listener is this URL plus the path the service is served at (`/rest` or
    # `/rpc` unless the service is declared elsewhere, and nothing for the root).
    # Unset, the URL is
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
    #
    # A listener built on an `http:Listener` that another A2A listener was built
    # on, and that sets no `publicUrl`, takes that listener's: the two publish one
    # card. Two that set different ones are an error when the second attaches.
    string? publicUrl = ();
    # Whether `sendMessage` and `sendStreamingMessage` answer
    # `ContentTypeNotSupportedError` (an HTTP 400 over HTTP+JSON, a JSON-RPC
    # error with code -32005 over JSON-RPC) for a message part whose
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
    # Off by default, as in the reference SDKs: turning it on refuses content
    # the agent would otherwise accept, and the A2A TCK's `CORE-SEND-003` sends
    # an undeclared media type and expects the send to succeed.
    boolean validateInputModes = false;
|};

# The `http:ListenerConfiguration` half of a `ListenerConfiguration`:
# everything left once this package's own fields are taken out.
#
# `ListenerConfiguration` includes `http:ListenerConfiguration`, so a
# caller can write `new a2a:RestListener(9090, timeout = 120)`; the listener
# built for a port takes those settings, such as a `timeout` or a
# `secureSocket`, from here.
#
# + config - The full configuration
# + return - The HTTP listener's own settings
isolated function httpListenerConfigurationOf(ListenerConfiguration config) returns http:ListenerConfiguration {
    ListenerConfiguration {
        auth: _, streamIdleTimeout: _, keepAliveInterval: _, publicUrl: _, validateInputModes: _, ...httpConfig
    } = config;
    return {...httpConfig};
}
