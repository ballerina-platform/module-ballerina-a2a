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

// The REST (HTTP+JSON) transport binding.
//
// An operation becomes an HTTP method, a path built directly from that
// operation's own parameters, and optionally a body. Each operation builds
// its own request directly (see prefixTenant/buildQueryString, below)
// rather than going through a shared method-name-keyed table — per review
// feedback that the table added indirection without buying much. The two
// pieces of logic every operation still needs in common (the
// tenant-in-path rule, 415-retry-and-remember) stay centralized, just as
// plain functions instead of a data table.
//
// Request building and response decoding live here rather than in a
// transport-agnostic operations layer. With one binding there is nothing to
// share them with, and most of what such a layer held — the parameter-map
// builders — was JSON-RPC/gRPC shaped anyway: REST puts those values in the
// path and query string instead. Reintroduce the shared layer alongside the
// second binding, not before it.

import ballerina/http;
import ballerina/url;

# The protocol-version header every A2A request carries (specification
# section 3.6.2). Also read by discovery.bal's card-fetch request.
const A2A_VERSION_HEADER = "A2A-Version";

# The A2A protocol version this library speaks. Also read by discovery.bal's
# card-fetch request.
const A2A_VERSION = "1.0";

# The content-type header name.
const CONTENT_TYPE_HEADER = "Content-Type";

# The A2A v1.0 JSON media type.
const CONTENT_TYPE_A2A_JSON = "application/a2a+json";

# The plain JSON media type, used for the v0.3 content-type fallback and for
# error bodies.
const CONTENT_TYPE_JSON = "application/json";

# Whether the held Agent Card rules out streaming, per issue #11.
#
# "Denied" rather than "allowed" is the load-bearing framing: this answers
# true only when a card exists AND explicitly says streaming is
# unsupported. `AgentCapabilities.streaming` defaults to `false`
# (types.bal), so a card that omits the field is treated as not supporting
# streaming.
#
# + card - The client's held AgentCard, or () if it has none
# + return - True if streaming should be short-circuited client-side
isolated function cardDeniesStreaming(AgentCard? card) returns boolean {
    return card is AgentCard && !card.capabilities.streaming;
}

# Whether the held Agent Card rules out push notifications, per issue #11.
# Same "denied" framing as cardDeniesStreaming.
#
# + card - The client's held AgentCard, or () if it has none
# + return - True if the push-notification-config operations should be
#            short-circuited client-side
isolated function cardDeniesPushNotifications(AgentCard? card) returns boolean {
    return card is AgentCard && !card.capabilities.pushNotifications;
}

# Adds the tenant routing parameter to a request body.
#
# The REST binding carries the tenant twice for an operation that has a
# body: once as the path prefix (prefixTenant) and again as a body field.
# That is deliberate, not redundant — a bodiless operation has only the
# path to carry it, so dropping the body copy would make the two kinds of
# operation disagree about where tenant lives.
#
# + body - The body to add to, mutated in place
# + effectiveTenant - The per-call override, or the client's default
# + return - The same map, for call-site chaining
isolated function applyTenant(map<json> body, string? effectiveTenant) returns map<json> {
    if effectiveTenant is string {
        body["tenant"] = effectiveTenant;
    }
    return body;
}

# Builds the request body for sendMessage/sendStreamingMessage.
#
# + message - The message to send
# + config - Optional send configuration
# + metadata - Optional additional context
# + effectiveTenant - The per-call override, or the client's default
# + return - The body, or an error if the message can't be encoded
isolated function buildSendMessageBody(
        Message message,
        SendMessageConfiguration? config,
        map<json>? metadata,
        string? effectiveTenant) returns map<json>|Error {
    check validateOutboundMessage(message);
    json|error messageJsonResult = encodeRawBytesForWire(message.toJson());
    if messageJsonResult is error {
        return wrapTransportError(messageJsonResult);
    }
    map<json> body = {"message": messageJsonResult};
    if config is SendMessageConfiguration {
        body["configuration"] = config.toJson();
    }
    if metadata is map<json> {
        body["metadata"] = metadata;
    }
    return applyTenant(body, effectiveTenant);
}

# Unwraps a unary sendMessage response.
#
# The wire response wraps the payload -- {"task": {...}} or
# {"message": {...}} -- rather than returning either one flat.
#
# + result - The raw result payload
# + return - The Task or Message the agent replied with, or an
#            InvalidAgentResponseError if it doesn't match the expected shape
isolated function decodeSendMessageResult(json result) returns Task|Message|Error {
    json|error rewired = decodeRawBytesFromWire(result);
    if rewired is error {
        return invalidAgentResponse(string `sendMessage response could not be decoded: ${rewired.message()}`);
    }
    [string, json]? arm = check oneofArm(rewired, ["task", "message"]);
    if arm is () {
        return invalidAgentResponse("Response contained neither a task nor a message");
    }
    [string, json] [name, payload] = arm;
    if name == "task" {
        Task|error task = normalizeTaskStateJson(payload).cloneWithType(Task);
        if task is error {
            return invalidAgentResponse(
                    string `sendMessage response did not match the expected shape: ${task.message()}`);
        }
        check validateInboundTask(task);
        return task;
    }
    Message|error message = payload.cloneWithType(Message);
    return message is error
        ? invalidAgentResponse(string `sendMessage response did not match the expected shape: ${message.message()}`)
        : message;
}

# Decodes a response whose payload is a bare Task. Shared by getTask and
# cancelTask, which differ only in the request they send.
#
# + result - The raw result payload
# + return - The decoded Task, or an InvalidAgentResponseError if it
#            doesn't match the expected shape
isolated function decodeTaskResult(json result) returns Task|Error {
    json|error rewired = decodeRawBytesFromWire(result);
    if rewired is error {
        return invalidAgentResponse(string `Task response could not be decoded: ${rewired.message()}`);
    }
    Task|error decoded = normalizeTaskStateJson(rewired).cloneWithType(Task);
    if decoded is error {
        return invalidAgentResponse(string `Task response did not match the expected shape: ${decoded.message()}`);
    }
    check validateInboundTask(decoded);
    return decoded;
}

# ProtoJSON parsers accept an enum's integer ordinal as well as its name,
# and treat an explicit `null` on an optional field the same as the field
# being absent (specification 5.5, 5.7). `cloneWithType` accepts neither:
# `TaskState` clones only from its exact string names, and a `null` on
# `history`/`metadata` doesn't satisfy their optional, non-nullable field
# types. Both reference clients (`a2a-sdk`, `@a2a-js/sdk`) already read a
# conforming server this leniently; this normalizes a raw Task payload
# (or a Task-shaped `status` sibling, e.g. TaskStatusUpdateEvent) to
# match before decoding. Spec 5.5 also requires senders to emit names,
# not numbers, so this only matters against a non-conforming server --
# no reference server has been seen doing either, but ProtoJSON allows
# it, so a compliant one may start.
#
# + raw - A Task- or TaskStatusUpdateEvent-shaped JSON value, returned
#         unchanged if it isn't a map
# + return - The same value with a `status.state` ordinal remapped to its
#            name, and a `null` `history`/`metadata` removed
isolated function normalizeTaskStateJson(json raw) returns json {
    if raw !is map<json> {
        return raw;
    }
    map<json> obj = raw;
    if obj.hasKey("history") && obj["history"] is () {
        _ = obj.remove("history");
    }
    if obj.hasKey("metadata") && obj["metadata"] is () {
        _ = obj.remove("metadata");
    }
    json status = obj["status"];
    if status is map<json> {
        json state = status["state"];
        if state is int {
            string? name = taskStateOrdinalName(state);
            if name is string {
                status["state"] = name;
            }
        }
    }
    return obj;
}

# Declaration order here matches specification 5.2's `TaskState` enum,
# which is also protobuf field-number order (`TASK_STATE_UNSPECIFIED = 0`
# first, per proto3 convention) -- the ordinal a non-conforming sender
# may emit in place of the name.
final string[] & readonly TASK_STATE_BY_ORDINAL = [
    TASK_STATE_UNSPECIFIED, TASK_STATE_SUBMITTED, TASK_STATE_WORKING,
    TASK_STATE_COMPLETED, TASK_STATE_FAILED, TASK_STATE_CANCELED,
    TASK_STATE_INPUT_REQUIRED, TASK_STATE_REJECTED, TASK_STATE_AUTH_REQUIRED
];

isolated function taskStateOrdinalName(int ordinal) returns string? =>
    ordinal >= 0 && ordinal < TASK_STATE_BY_ORDINAL.length() ? TASK_STATE_BY_ORDINAL[ordinal] : ();

# + result - The raw result payload
# + return - The decoded page of tasks, or an InvalidAgentResponseError if
#            it doesn't match the expected shape
isolated function decodeListTasksResponse(json result) returns ListTasksResponse|Error {
    json|error rewired = decodeRawBytesFromWire(result);
    if rewired is error {
        return invalidAgentResponse(string `ListTasks response could not be decoded: ${rewired.message()}`);
    }
    // A server whose `tasks` field defaults to a nil slice can send
    // `"tasks": null` for an empty page -- confirmed directly against a
    // real a2a-go server, whose Go zero value does exactly this.
    // `cloneWithType` otherwise rejects it outright: `tasks` is a
    // required, non-nullable `Task[]`, and ProtoJSON (specification 5.5,
    // ADR-001) treats a missing/null repeated field as empty either way,
    // so normalizing null to `[]` before decoding is what the wire format
    // itself already means, not a workaround for one server's quirk.
    //
    // The same is true of `nextPageToken`, `pageSize` and `totalSize`:
    // ProtoJSON omits a field left at its default value (specification
    // 5.7), so a real a2a-rs server's last page, or `{}` for an empty
    // page, arrives with all three absent. Both reference clients
    // (`a2a-sdk` 1.2.0, `@a2a-js/sdk`) already read a missing value here
    // as the type's zero value; normalizing missing/null the same way
    // before decoding matches what the wire format means, not a
    // workaround for one server. This must run after the `tasks`
    // normalization above and before decoding into the required,
    // non-optional `ListTasksResponse` fields -- an unparseable body is
    // caught earlier, by `restCall`'s own check, so this never turns a
    // malformed response into a silent empty page.
    if rewired is map<json> && rewired["tasks"] is () {
        rewired["tasks"] = [];
    }
    if rewired is map<json> {
        if rewired["nextPageToken"] is () {
            rewired["nextPageToken"] = "";
        }
        if rewired["pageSize"] is () {
            rewired["pageSize"] = 0;
        }
        if rewired["totalSize"] is () {
            rewired["totalSize"] = 0;
        }
        json tasks = rewired["tasks"];
        if tasks is json[] {
            rewired["tasks"] = tasks.map(normalizeTaskStateJson);
        }
    }
    ListTasksResponse|error decoded = rewired.cloneWithType(ListTasksResponse);
    if decoded is error {
        return invalidAgentResponse(string `ListTasks response did not match the expected shape: ${decoded.message()}`);
    }
    // No non-empty check on `tasks`: an empty page is a legitimate "no
    // results matched". See requireNonEmpty for why section 5.7's blanket
    // sentence is not read literally.
    foreach Task task in decoded.tasks {
        check validateInboundTask(task);
    }
    return decoded;
}

# + result - The raw result payload
# + return - The decoded config, or an InvalidAgentResponseError if it
#            doesn't match the expected shape
isolated function decodeTaskPushNotificationConfig(json result) returns TaskPushNotificationConfig|Error {
    TaskPushNotificationConfig|error decoded = result.cloneWithType(TaskPushNotificationConfig);
    if decoded is error {
        return invalidAgentResponse(string `TaskPushNotificationConfig response did not `
                + string `match the expected shape: ${decoded.message()}`);
    }
    return decoded;
}

# + result - The raw result payload
# + return - The decoded page of configs, or an InvalidAgentResponseError
#            if it doesn't match the expected shape
isolated function decodeListTaskPushNotificationConfigsResponse(json result)
        returns ListTaskPushNotificationConfigsResponse|Error {
    ListTaskPushNotificationConfigsResponse|error decoded =
        result.cloneWithType(ListTaskPushNotificationConfigsResponse);
    if decoded is error {
        return invalidAgentResponse(
            string `ListTaskPushNotificationConfigs response did not match the expected shape: ${decoded.message()}`);
    }
    return decoded;
}

# Percent-encodes a value for use in a REST request path or query string,
# wrapping any encoding failure into this library's own error type.
#
# + value - The raw value to encode
# + return - The percent-encoded value, or a typed Error if it can't be
#            encoded
isolated function urlEncodeOrWrap(string value) returns string|Error {
    string|error encoded = url:encode(value, "UTF-8");
    if encoded is error {
        return wrapTransportError(encoded);
    }
    return encoded;
}

# Prepends the tenant routing segment to a request path, per the REST
# binding's path-prefix convention (`/{tenant}{path}`). A no-op when no
# tenant applies.
#
# + path - The request path, before any tenant prefix
# + tenant - The effective tenant for this call, or () if none applies
# + return - The path with the tenant segment prepended, or unchanged if
#            tenant is (), or a typed Error if tenant can't be encoded
isolated function prefixTenant(string path, string? tenant) returns string|Error {
    if tenant is () {
        return path;
    }
    string encodedTenant = check urlEncodeOrWrap(tenant);
    return string `/${encodedTenant}${path}`;
}

# Builds a URL query string from a set of already-stringified parameters —
# every value is percent-encoded, joined with `&`, and prefixed with `?`.
# Only called with parameters an operation actually has set; there's no
# generic "whatever's left over" set to iterate here, unlike the old
# table-driven version.
#
# + queryParams - The query parameters to include, already as strings
# + return - The query string including its leading `?`, or `""` if
#            queryParams is empty, or a typed Error if a value can't be
#            encoded
isolated function buildQueryString(map<string> queryParams) returns string|Error {
    string[] queryParts = [];
    foreach [string, string] [k, v] in queryParams.entries() {
        string encoded = check urlEncodeOrWrap(v);
        queryParts.push(string `${k}=${encoded}`);
    }
    if queryParts.length() == 0 {
        return "";
    }
    return "?" + string:'join("&", ...queryParts);
}

# Configuration for an `a2a:HttpClient`, passed as included record fields:
# `check new ("https://agent.example.com", tenant = "acme", maxReconnectAttempts = 3)`.
public type ClientConfiguration record {|
    # Full `http:ClientConfiguration` — auth, TLS, retry, circuit breaker,
    # proxy, timeouts, and connection pooling. Also used for the card fetch
    # when the client is constructed from a URL.
    http:ClientConfiguration clientConfig = {};
    # Default headers merged into every outbound request.
    map<string> headers = {};
    # Optional multi-tenant routing identifier; the card's HTTP+JSON interface
    # supplies one automatically when it declares it, and an explicit value wins.
    string? tenant = ();
    # Optional A2A extension URIs to request.
    string[] requestedExtensions = [];
    # Opt-in automatic SSE reconnection: how many times a dropped stream is
    # resubscribed. 0 (the default) disables reconnection.
    int maxReconnectAttempts = 0;
    # Optional provider consulted per request for the credentials the card's
    # `securityRequirements` call for, keyed by security-scheme name. Covers the
    # schemes that reduce to a single string (API key in a header, HTTP
    # bearer/basic); OAuth2, OpenID Connect, and mutual TLS belong on
    # `clientConfig.auth`, which handles their token exchange properly.
    CredentialProvider? credentials = ();
|};

# An A2A protocol client for a remote agent, over the HTTP+JSON binding.
#
# Give it the agent's base URL, or an `a2a:AgentCard` already resolved via
# `a2a:resolveAgentCard`. It resolves the card, requires it to declare an
# HTTP+JSON interface, and speaks A2A v1.0 to it — so a card declaring only
# JSON-RPC or gRPC, or a 0.x protocol version, is rejected at construction
# rather than at the first call.
#
# ```ballerina
# a2a:HttpClient agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage({message: msg});
# ```
#
# A client is cheap to construct and needs no teardown — there is deliberately
# no `close`, because an `http:Client` routes through a process-wide pool that
# evicts idle connections on its own. Still, prefer one long-lived client per
# agent: construction is wasted work per call. Setting `poolConfig` in
# `clientConfig` opts out of the shared pool into a private one that cannot be
# released, so reuse is required there rather than merely preferred.
#
# Each method's `+ return` names the `a2a:Error` subtype a protocol failure
# produces; a transport or decode failure comes back as `a2a:InternalError`.
public isolated client class HttpClient {
    *Client;

    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    # Supplies credentials by security-scheme name, if the caller opted in.
    private final CredentialProvider? credentials;
    # The card as resolved at construction, kept immutable purely for
    # credential resolution — deliberately not `agentCard` below, which is
    # replaced once an extended card is fetched. Which credential a request
    # carries should not change as a side effect of that fetch.
    private final AgentCard & readonly authCard;
    private final string? tenant;
    private final string[] & readonly requestedExtensions;
    private final int maxReconnectAttempts;
    # The most recent AgentCard this client knows about; replaced by the
    # extended card once getExtendedAgentCard fetches one.
    private AgentCard? agentCard;
    # Learned, not configured: set the first time a server rejects
    # `application/a2a+json` with a 415, so later calls on this instance skip
    # the retry.
    private boolean useLegacyContentType = false;

    # Creates an HTTP+JSON client pointed at a remote A2A agent.
    #
    # + agent - The agent's base URL, or an AgentCard already resolved via
    #           `a2a:resolveAgentCard`
    # + config - Client configuration; see `a2a:ClientConfiguration` for the
    #            individual fields, passed as named arguments
    # + return - A typed Error: from resolveAgentCard, from URL
    #            derivation when the card declares no HTTP+JSON
    #            interface, a VersionNotSupportedError if the card
    #            resolves to A2A v0.3, or an InternalError if the
    #            http:Client cannot be created -- including when the initial
    #            OAuth2 token cannot be obtained (a wrong client secret, an
    #            unreachable token endpoint)
    public isolated function init(AgentCard|string agent, *ClientConfiguration config) returns Error? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, config.headers, clientConfig = config.clientConfig)
            : agent;
        string serviceUrl = check primaryUrl(card, HTTP_JSON);
        string? effectiveTenant = config.tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectInterface(card, HTTP_JSON);
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        check requireV1Interface(card, HTTP_JSON);
        // http:ClientConfiguration isn't Cloneable (some of its fields
        // aren't pure data), so a mapping-constructor spread is used
        // instead of .clone() to shallow-copy it — otherwise this could
        // mutate the caller's own clientConfig in place.
        http:ClientConfiguration effectiveClientConfig = {...config.clientConfig};
        self.httpClient = check newHttpClient(serviceUrl, effectiveClientConfig);
        self.defaultHeaders = config.headers.clone().cloneReadOnly();
        self.credentials = config.credentials;
        self.authCard = card.cloneReadOnly();
        self.tenant = effectiveTenant;
        self.requestedExtensions = config.requestedExtensions.cloneReadOnly();
        self.maxReconnectAttempts = config.maxReconnectAttempts;
        self.agentCard = card.clone();
    }

    # + return - The headers to send with the request
    private isolated function buildHeaders() returns map<string> {
        // The A2A spec's REST/HTTP+JSON binding requires the
        // application/a2a+json media type, not plain application/json
        // (spec §11) -- verified against the real, current spec text --
        // and that's what this client sends by default. Some real,
        // currently-released servers haven't caught up yet: the reference
        // Java server (a2a-java-sdk-reference-rest:1.1.0.Final) rejects
        // application/a2a+json outright with a 415 (confirmed by
        // decompiling its route registration, which hardcodes
        // .consumes("application/json")). performRestCallWithNegotiation
        // retries once with application/json on a real 415 and flips
        // useLegacyContentType so every later call goes straight there --
        // this only reads that already-learned choice.
        boolean legacy;
        lock {
            legacy = self.useLegacyContentType;
        }
        map<string> headers = {
            [A2A_VERSION_HEADER]: A2A_VERSION,
            [CONTENT_TYPE_HEADER]: legacy ? CONTENT_TYPE_JSON : CONTENT_TYPE_A2A_JSON
        };
        // Card-resolved credentials first, so an explicit `headers` entry
        // still wins — a caller who wrote a header literally meant it.
        // resolveCredentialHeaders already refuses to produce a reserved
        // header name, so the two set above cannot be displaced here.
        foreach [string, string] [k, v] in resolveCredentialHeaders(self.authCard, self.credentials).entries() {
            headers[k] = v;
        }
        foreach [string, string] [k, v] in self.defaultHeaders.entries() {
            headers[k] = v;
        }
        if self.requestedExtensions.length() > 0 {
            headers["A2A-Extensions"] = string:'join(",", ...self.requestedExtensions);
        }
        return headers;
    }

    # Issues one raw HTTP call, with no content-type negotiation --
    # callers that need negotiation go through performRestCallWithNegotiation
    # instead.
    #
    # + httpMethod - The HTTP verb to send, e.g. "GET" or "POST"
    # + path - The full request path, tenant prefix and path params already
    #          substituted
    # + body - The request body, or () for a bodiless request
    # + headers - The exact headers to send
    # + return - The raw HTTP response, or a transport-level error
    private isolated function rawRestCall(string httpMethod, string path, json? body,
            map<string> headers) returns http:Response|Error {
        http:Response|error result;
        if httpMethod == "GET" {
            result = self.httpClient->get(path, headers);
        } else if httpMethod == "DELETE" {
            result = self.httpClient->delete(path, headers = headers);
        } else {
            result = self.httpClient->post(path, body ?: {}, headers);
        }
        if result is error {
            return wrapTransportError(result);
        }
        return result;
    }

    # Issues one REST call, transparently retrying once with the legacy
    # application/json content type if the server rejects the spec-mandated
    # application/a2a+json with a 415 -- see buildHeaders' doc comment.
    #
    # + httpMethod - The HTTP verb to send, e.g. "GET" or "POST"
    # + path - The full request path, tenant prefix and path params already
    #          substituted
    # + body - The request body, or () for a bodiless request
    # + extraHeaders - Additional headers merged in on top of buildHeaders'
    #                  defaults (e.g. Accept: text/event-stream)
    # + return - The raw HTTP response (from whichever attempt settled),
    #            or a transport-level error
    private isolated function performRestCallWithNegotiation(
            string httpMethod, string path, json? body, map<string> extraHeaders = {}) returns http:Response|Error {
        map<string> headers = self.buildHeaders();
        foreach [string, string] [k, v] in extraHeaders.entries() {
            headers[k] = v;
        }
        http:Response resp = check self.rawRestCall(httpMethod, path, body, headers);
        if resp.statusCode == 415 && headers[CONTENT_TYPE_HEADER] != CONTENT_TYPE_JSON {
            map<string> legacyHeaders = headers.clone();
            legacyHeaders[CONTENT_TYPE_HEADER] = CONTENT_TYPE_JSON;
            http:Response retryResp = check self.rawRestCall(httpMethod, path, body, legacyHeaders);
            if retryResp.statusCode != 415 {
                lock {
                    self.useLegacyContentType = true;
                }
            }
            return retryResp;
        }
        return resp;
    }

    # Performs one non-streaming REST call and returns the unwrapped
    # result.
    #
    # DeleteTaskPushNotificationConfig returns google.protobuf.Empty over
    # the wire, so for that one operation an absent or unparseable body on
    # a 2xx is an empty success rather than a malformed response. Every
    # other operation expects real content: a truncated body, an HTML
    # error page returned with a 200, or a body with no content type at
    # all must not be silently read as "{}" and decoded into an empty
    # success (e.g. a page with zero results) -- confirmed against a
    # hostile server sending exactly that. `a2a-sdk` raises in both cases
    # (network error, JSON decode error); we now return a typed
    # InvalidAgentResponseError naming the parse failure instead.
    #
    # + httpMethod - The HTTP verb to send, e.g. "GET" or "POST"
    # + path - The full request path, tenant prefix and path params already
    #          substituted
    # + body - The request body, or () for a bodiless request
    # + return - The unwrapped result json, or a typed Error for a non-2xx
    #            response (via toA2AErrorFromRest), an unparseable 2xx body
    #            on an operation that expects content (InvalidAgentResponseError),
    #            or a connection failure (wrapped as InternalError)
    private isolated function restCall(string httpMethod, string path, json? body) returns json|Error {
        http:Response resp = check self.performRestCallWithNegotiation(httpMethod, path, body);
        if resp.statusCode >= 200 && resp.statusCode < 300 {
            json|error payload = resp.getJsonPayload();
            if payload is json {
                return payload;
            }
            if httpMethod == "DELETE" {
                return {};
            }
            return invalidAgentResponse(
                string `${httpMethod} ${path} returned a 2xx response whose body could not be `
                    + string `parsed as JSON: ${payload.message()}`);
        }
        json|error errorBodyResult = resp.getJsonPayload();
        json? errorBody = errorBodyResult is json ? errorBodyResult : ();
        return toA2AErrorFromRest(resp.statusCode, errorBody, challengesOf(resp));
    }

    # Validates that a REST response is a real SSE stream and decodes it,
    # shared by both streaming operations (sendStreamingMessage,
    # subscribeToTask) once each has already issued its own request --
    # any operation-specific retry (e.g. subscribeToTask's GET-then-POST
    # fallback) happens before this is called, not inside it.
    #
    # + resp - The HTTP response to an SSE request
    # + return - A stream of StreamResponse values, or a typed Error for a
    #            non-streaming error response (via toA2AErrorFromRest)
    private isolated function finishSseResponse(http:Response resp) returns stream<StreamResponse, Error?>|Error {
        if !resp.getContentType().startsWith("text/event-stream") {
            json|error errBody = resp.getJsonPayload();
            return toA2AErrorFromRest(resp.statusCode, errBody is json ? errBody : (), challengesOf(resp));
        }
        return readSseStream(resp);
    }

    # Opens the raw, unwrapped subscribeToTask stream.
    #
    # Reconnection resubscribes through this rather than the remote function,
    # which would wrap each reconnected stream in a fresh generator with its
    # own attempt budget and so never give up.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ())
            returns stream<StreamResponse, Error?>|Error {
        string encodedId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedId}:subscribe`, tenant ?: self.tenant);
        map<string> extraHeaders = {"Accept": "text/event-stream"};
        http:Response resp = check self.performRestCallWithNegotiation("GET", path, (), extraHeaders);
        // SubscribeToTask's proto annotation says GET, but a non-reference
        // server that hand-rolled its REST routes following the reference
        // *client* (which sends POST) might only have registered POST.
        // Scoped to exactly this one operation — retrying broadly for
        // every operation would mask genuine method-not-allowed errors
        // elsewhere.
        if resp.statusCode == 404 || resp.statusCode == 405 || resp.statusCode == 501 {
            resp = check self.performRestCallWithNegotiation("POST", path, (), extraHeaders);
        }
        return self.finishSseResponse(resp);
    }

    # The unary sendMessage body, factored out so sendStreamingMessage's
    # capability-gated fallback (issue #11) can call it without going
    # through a remote method on self.
    #
    # + message - The message to send
    # + config - Optional send configuration
    # + tenant - Optional per-call tenant override
    # + metadata - Optional additional context
    # + return - The finished Task or a plain Message reply
    private isolated function sendMessageUnary(
            Message message,
            SendMessageConfiguration? config,
            string? tenant,
            map<json>? metadata) returns Task|Message|Error {
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> body = check buildSendMessageBody(message, config, metadata, effectiveTenant);
        string path = check prefixTenant("/message:send", effectiveTenant);
        json result = check self.restCall("POST", path, body);
        return decodeSendMessageResult(result);
    }

    # Sends a message to the remote agent over REST (HTTP+JSON).
    #
    # + request - The message to send and its send options; `message.messageId`
    #             must be set by the caller. `metadata` here is request-level,
    #             per SendMessageRequest (specification section 3.2.1) —
    #             distinct from `message.metadata`, which is metadata on the
    #             Message itself
    # + return - A Task or a Message on success, or a typed Error on failure
    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error {
        Message message = request.message;
        SendMessageConfiguration? config = request?.configuration;
        string? tenant = request?.tenant;
        map<json>? metadata = request?.metadata;
        return self.sendMessageUnary(message, config, tenant, metadata);
    }

    # Sends a message and receives updates as they happen, over REST SSE.
    #
    # Falls back to a single unary sendMessage call, wrapped as a one-event
    # stream, when the held AgentCard says streaming is unsupported — see
    # issue #11 — instead of opening (and having the server reject) a
    # streaming connection.
    #
    # + request - The message to send and its send options
    # + return - A stream of StreamResponse values, or a typed Error
    isolated remote function sendStreamingMessage(SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        Message message = request.message;
        SendMessageConfiguration? config = request?.configuration;
        string? tenant = request?.tenant;
        map<json>? metadata = request?.metadata;
        boolean denied;
        lock {
            denied = cardDeniesStreaming(self.agentCard);
        }
        if denied {
            // Falls back to a single unary call instead of opening (and
            // having the server reject) a streaming connection - see
            // singleEventStream and issue #11.
            Task|Message result = check self.sendMessageUnary(message, config, tenant, metadata);
            return singleEventStream(result);
        }
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> body = check buildSendMessageBody(message, config, metadata, effectiveTenant);
        string path = check prefixTenant("/message:stream", effectiveTenant);
        map<string> extraHeaders = {"Accept": "text/event-stream"};
        http:Response resp = check self.performRestCallWithNegotiation("POST", path, body, extraHeaders);
        stream<StreamResponse, Error?> rawStream = check self.finishSseResponse(resp);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    # Retrieves the current state of a task.
    #
    # + request - The task identifier, and optionally how much history to include
    # + return - The current Task, or a TaskNotFoundError (or other typed
    #            Error) if unknown
    isolated remote function getTask(GetTaskRequest request) returns Task|Error {
        string taskId = request.id;
        int? historyLength = request?.historyLength;
        string? tenant = request?.tenant;
        string encodedId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedId}`, tenant ?: self.tenant);
        if historyLength is int {
            path = path + check buildQueryString({"historyLength": historyLength.toString()});
        }
        json result = check self.restCall("GET", path, ());
        return decodeTaskResult(result);
    }

    # Requests cancellation of an in-progress task.
    #
    # + request - The task to cancel, and any additional context for the agent
    # + return - The updated Task, or a TaskNotFoundError/TaskNotCancelableError
    #            (or other typed Error)
    isolated remote function cancelTask(CancelTaskRequest request) returns Task|Error {
        string taskId = request.id;
        map<json>? metadata = request?.metadata;
        string? tenant = request?.tenant;
        string? effectiveTenant = tenant ?: self.tenant;
        map<json> body = applyTenant({"id": taskId}, effectiveTenant);
        if metadata is map<json> {
            body["metadata"] = metadata;
        }
        string encodedId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedId}:cancel`, effectiveTenant);
        json result = check self.restCall("POST", path, body);
        return decodeTaskResult(result);
    }

    # Opens a stream on an existing task over REST SSE.
    #
    # Unlike sendStreamingMessage, subscribing to a task already in flight
    # has no unary equivalent to fall back to when the held AgentCard says
    # streaming is unsupported — see issue #11 — so that case is rejected
    # client-side with an UnsupportedOperationError instead.
    #
    # + request - The task to subscribe to
    # + return - A stream of StreamResponse values, or a typed Error
    isolated remote function subscribeToTask(SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        string taskId = request.id;
        string? tenant = request?.tenant;
        boolean denied;
        lock {
            denied = cardDeniesStreaming(self.agentCard);
        }
        if denied {
            // Unlike sendStreamingMessage, subscribing to a task already
            // in flight has no unary equivalent to fall back to - see
            // issue #11.
            return streamingUnsupportedError("subscribeToTask");
        }
        stream<StreamResponse, Error?> rawStream = check self.openTaskSubscriptionStream(taskId, tenant);
        if self.maxReconnectAttempts <= 0 {
            return rawStream;
        }
        stream<StreamResponse, Error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, self, taskId, self.maxReconnectAttempts, tenant = tenant));
        return wrapped;
    }

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + request - Optional filter and pagination parameters; every field is
    #             optional, so this defaults to the server's own defaults
    # + return - A page of matching tasks, or a typed Error
    isolated remote function listTasks(ListTasksRequest request = {}) returns ListTasksResponse|Error {
        string? tenant = request?.tenant;
        map<string> queryParams = {};
        string? contextId = request?.contextId;
        if contextId is string {
            queryParams["contextId"] = contextId;
        }
        TaskState? status = request?.status;
        if status is TaskState {
            queryParams["status"] = status;
        }
        int? pageSize = request?.pageSize;
        if pageSize is int {
            queryParams["pageSize"] = pageSize.toString();
        }
        string? pageToken = request?.pageToken;
        if pageToken is string {
            queryParams["pageToken"] = pageToken;
        }
        int? historyLength = request?.historyLength;
        if historyLength is int {
            queryParams["historyLength"] = historyLength.toString();
        }
        string? statusTimestampAfter = request?.statusTimestampAfter;
        if statusTimestampAfter is string {
            queryParams["statusTimestampAfter"] = statusTimestampAfter;
        }
        boolean? includeArtifacts = request?.includeArtifacts;
        if includeArtifacts is boolean {
            queryParams["includeArtifacts"] = includeArtifacts.toString();
        }
        string path = check prefixTenant("/tasks", tenant ?: self.tenant);
        path = path + check buildQueryString(queryParams);
        json result = check self.restCall("GET", path, ());
        return decodeListTasksResponse(result);
    }

    # Registers a webhook to receive updates for a task.
    #
    # + request - The webhook configuration; its `taskId` identifies the task
    # + return - The created config as the server persisted it, or a
    #            PushNotificationNotSupportedError (or other typed Error)
    isolated remote function createTaskPushNotificationConfig(TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        TaskPushNotificationConfig config = request;
        string? tenant = request?.tenant;
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("createTaskPushNotificationConfig");
        }
        string? effectiveTenant = tenant ?: self.tenant;
        map<json>|error bodyResult = config.toJson().ensureType();
        if bodyResult is error {
            return wrapTransportError(bodyResult);
        }
        map<json> body = applyTenant(bodyResult, effectiveTenant);
        string? taskId = config?.taskId;
        if taskId is () {
            return error InternalError(
                    "REST binding for \"CreateTaskPushNotificationConfig\" requires config.taskId to be set");
        }
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(string `/tasks/${encodedTaskId}/pushNotificationConfigs`, effectiveTenant);
        json result = check self.restCall("POST", path, body);
        return decodeTaskPushNotificationConfig(result);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + request - The parent task id and the config's own id
    # + return - The config, or a PushNotificationNotSupportedError/
    #            TaskNotFoundError (or other typed Error)
    isolated remote function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request)
            returns TaskPushNotificationConfig|Error {
        string taskId = request.taskId;
        string id = request.id;
        string? tenant = request?.tenant;
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("getTaskPushNotificationConfig");
        }
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string encodedId = check urlEncodeOrWrap(id);
        string path = check prefixTenant(
                string `/tasks/${encodedTaskId}/pushNotificationConfigs/${encodedId}`, tenant ?: self.tenant);
        json result = check self.restCall("GET", path, ());
        return decodeTaskPushNotificationConfig(result);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + request - The parent task id, and optional pagination parameters
    # + return - A page of matching configs, or a
    #            PushNotificationNotSupportedError (or other typed Error)
    isolated remote function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request)
            returns ListTaskPushNotificationConfigsResponse|Error {
        string taskId = request.taskId;
        int? pageSize = request?.pageSize;
        string? pageToken = request?.pageToken;
        string? tenant = request?.tenant;
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("listTaskPushNotificationConfigs");
        }
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string path = check prefixTenant(
                string `/tasks/${encodedTaskId}/pushNotificationConfigs`, tenant ?: self.tenant);
        map<string> queryParams = {};
        if pageSize is int {
            queryParams["pageSize"] = pageSize.toString();
        }
        if pageToken is string {
            queryParams["pageToken"] = pageToken;
        }
        path = path + check buildQueryString(queryParams);
        json result = check self.restCall("GET", path, ());
        return decodeListTaskPushNotificationConfigsResponse(result);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # Gated on `capabilities.pushNotifications` like the other three config
    # operations: section 3.3.4 names Create, Get, List, and Delete
    # explicitly. Section 3.1.10's idempotency is about repeated deletes of
    # the same config, not about capability gating.
    #
    # + request - The parent task id and the config's own id
    # + return - Nil on success, or a typed Error
    isolated remote function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request)
            returns Error? {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError("deleteTaskPushNotificationConfig");
        }
        string taskId = request.taskId;
        string id = request.id;
        string? tenant = request?.tenant;
        string encodedTaskId = check urlEncodeOrWrap(taskId);
        string encodedId = check urlEncodeOrWrap(id);
        string path = check prefixTenant(
                string `/tasks/${encodedTaskId}/pushNotificationConfigs/${encodedId}`, tenant ?: self.tenant);
        json _ = check self.restCall("DELETE", path, ());
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + request - Optional routing parameters; every field is optional, so this
    #             defaults to an empty request
    # + return - The extended AgentCard, or a typed Error
    isolated remote function getExtendedAgentCard(GetExtendedAgentCardRequest request = {}) returns AgentCard|Error {
        string? tenant = request?.tenant;
        lock {
            // Specification section 3.3.4: when the held card says the agent
            // does not support extended cards, this MUST fail rather than
            // silently hand back the public card the caller already had.
            // With no card held there is nothing to validate against, so the
            // request goes out and the server -- which owns the MUST --
            // decides; its error maps back through the usual path.
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return extendedCardUnsupportedError();
            }
        }
        string path = check prefixTenant("/extendedAgentCard", tenant ?: self.tenant);
        json result = check self.restCall("GET", path, ());
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }
}

# The `WWW-Authenticate` challenges a response carried, if any.
#
# + resp - The response
# + return - The challenge values, empty when there were none
isolated function challengesOf(http:Response resp) returns string[] {
    string[]|http:HeaderNotFoundError challenges = resp.getHeaders("WWW-Authenticate");
    return challenges is string[] ? challenges : [];
}

# Creates the `http:Client` for one agent URL, returning a typed error where
# `ballerina/http` panics.
#
# `new http:Client` has no error return for a failure inside an auth handler,
# so it panics: `ballerina/oauth2` fetches the first token while the client is
# being built and panics when the token endpoint refuses the client or cannot
# be reached. A caller of `a2a:HttpClient` or `a2a:resolveAgentCard` is
# promised a typed `a2a:Error` for that, so the panic is trapped here, at the
# one place it can occur. The upstream message is folded into the new one,
# which is where the token endpoint's response is reported.
#
# + url - The agent's base URL
# + config - The HTTP client configuration, auth included
# + return - The client, or an `a2a:InternalError` if it could not be created
isolated function newHttpClient(string url, http:ClientConfiguration config) returns http:Client|Error {
    http:Client|error created = trap new (url, config);
    if created is http:Client {
        return created;
    }
    string msg = string `could not create the HTTP client for ${url}: ${created.message()}`;
    return error InternalError(msg, message = msg);
}
