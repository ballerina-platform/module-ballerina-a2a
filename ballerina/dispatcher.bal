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

// The internal HTTP service the Listener attaches.
//
// It owns the A2A wire: it serves the Agent Card at the well-known path,
// routes the operation endpoints (both the bare and the /{tenant}-prefixed
// forms the proto's additional_bindings define), runs the capability and
// version gates, and turns an `a2a:Error` into the google.rpc.Status body the
// client decodes. The task lifecycle itself lives in `default_handler.bal`;
// this file is transport.
//
// A single catch-all resource matches every request and dispatches on the raw
// path. The A2A paths use literal colons (`/message:send`, `/tasks/{id}:cancel`)
// which are not ordinary path segments, so matching the raw path is simpler
// and more faithful than trying to express them as typed resource paths.
//
// This is also why operation handlers build `http:Response` directly instead
// of returning the `http:Ok|http:BadRequest|...` status-typed unions other
// listeners in this ecosystem use: that pattern relies on a typed resource
// signature per operation, which the colon-paths rule out here. `jsonResponse`
// and `toRestErrorResponse` are the substitute -- one place each that builds
// the response, rather than one return type per operation.

import ballerina/http;
import ballerina/log;
import ballerina/time;

# The A2A protocol version this server implements.
const A2A_PROTOCOL_VERSION = "1.0";

# The task-scoped path prefix every task operation's path starts with.
const TASKS_PATH_PREFIX = "/tasks/";

# The push-notification-config collection segment under a task's path.
const PUSH_NOTIFICATION_CONFIGS_SEGMENT = "/pushNotificationConfigs";

isolated service class DispatcherService {
    *http:Service;

    private final AgentCard & readonly card;
    private final (AgentCard & readonly)? extendedCard;
    private final DefaultHandler handler;
    private final ListenerAuthenticator? authenticator;
    private final string interfaceScheme;
    private final string? publicUrl;
    private final StreamTiming & readonly streamTiming;

    isolated function init(AgentCard card, (AgentCard & readonly)? extendedCard, DefaultHandler handler,
            ListenerAuthenticator? authenticator = (), string interfaceScheme = "http", string? publicUrl = (),
            StreamTiming streamTiming = {}) {
        self.card = card.cloneReadOnly();
        self.extendedCard = extendedCard;
        self.handler = handler;
        self.authenticator = authenticator;
        self.interfaceScheme = interfaceScheme;
        self.publicUrl = publicUrl;
        self.streamTiming = streamTiming.cloneReadOnly();
    }

    isolated resource function get [string... path](http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        return self.dispatch("GET", "/" + string:'join("/", ...path), req);
    }

    isolated resource function post [string... path](http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        return self.dispatch("POST", "/" + string:'join("/", ...path), req);
    }

    isolated resource function delete [string... path](http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        return self.dispatch("DELETE", "/" + string:'join("/", ...path), req);
    }

    # Routes one request to the operation its method and path name, applying
    # the tenant, version, and capability gates first.
    #
    # + method - The HTTP method
    # + rawPath - The request path with a leading slash, tenant prefix intact
    # + req - The HTTP request
    # + return - The response to send
    private isolated function dispatch(string method, string rawPath, http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        // Discovery is unversioned and untenanted. The served card's
        // interface URL is filled from the Host the client reached us on —
        // the server knows its port but not its externally-visible host, so
        // the request that fetches the card is what reveals it. This is how a
        // client that resolves the card then gets a usable URL to call.
        if method == "GET" && rawPath == "/.well-known/agent-card.json" {
            return cardHttpResponse(self.cardWithInterfaceUrl(self.card, req));
        }

        // Authentication comes before everything else, so a caller that has
        // not proved who it is learns nothing about the server -- not even
        // whether a path or a tenant exists (specification section 7.4).
        string? identity = ();
        ListenerAuthenticator? authenticator = self.authenticator;
        if authenticator is ListenerAuthenticator {
            string|http:HeaderNotFoundError authorization = req.getHeader(AUTHORIZATION_HEADER);
            string|AuthFailure authenticated = authenticator.authenticate(authorization is string ? authorization : ());
            if authenticated is AuthFailure {
                logAuthFailure(authenticated, method, rawPath, authorization is string ? schemeOf(authorization) : ());
                return toAuthErrorResponse(authenticated, authenticator.challengeHeaders());
            }
            identity = authenticated;
        }

        Error? versionError = self.checkVersion(req);
        if versionError is Error {
            return toRestErrorResponse(versionError);
        }

        Error? extensionsError = self.checkExtensions(req);
        if extensionsError is Error {
            return toRestErrorResponse(extensionsError);
        }

        // Strip a leading /{tenant} segment. The tenant must match the card's
        // declared one; the untenanted form carries no tenant.
        [string, string?]|Error routed = self.stripTenant(rawPath);
        if routed is Error {
            return toRestErrorResponse(routed);
        }
        [string, string?] [path, tenant] = routed;

        // Resolved once per request, after the tenant is known (a resolver
        // may want it) and before any operation runs. With no resolver
        // configured on the handler, the authenticated identity is the owner
        // (section 13.1); with no `auth` either, the one shared, unscoped pool.
        string?|Error owner = self.handler.resolveOwner(callerContextOf(req, identity, tenant));
        if owner is Error {
            return toRestErrorResponse(owner);
        }

        http:Response|stream<http:SseEvent, error?>|Error result = self.route(method, path, tenant, owner, req);
        if result is Error {
            return toRestErrorResponse(result);
        }
        return result;
    }

    # A card with its HTTP+JSON interface URL filled in: the configured
    # public URL if there is one, otherwise the scheme this listener serves
    # and the request's Host header.
    #
    # Used for both the public discovery card and the extended card -- a
    # client is meant to be able to reach either at the URL its own
    # `supportedInterfaces` names, and specification 13.3 has clients
    # replace their held card with the extended one, so it needs a real URL
    # exactly as much as the public card does; before this was generalized,
    # the extended card route never called this at all and served whatever
    # placeholder URL the developer's own card literal happened to have.
    #
    # + card - The card to fill in, as held (readonly)
    # + req - The request the card is being served in response to
    # + return - A copy of `card` with a usable interface URL
    private isolated function cardWithInterfaceUrl(AgentCard card, http:Request req) returns AgentCard {
        string|http:HeaderNotFoundError host = req.getHeader("Host");
        string? publicUrl = self.publicUrl;
        if host !is string && publicUrl is () {
            return card;
        }
        string url = interfaceUrlFor(publicUrl, self.interfaceScheme, host is string ? host : "");
        // `card` is readonly, so round-trip through JSON for a fresh mutable
        // copy, then fill the HTTP+JSON interface's URL. `deriveServedCard`
        // put a single such entry there, on both the public and extended
        // cards.
        AgentCard|error served = card.toJson().cloneWithType(AgentCard);
        if served is error {
            return card;
        }
        foreach int i in 0 ..< served.supportedInterfaces.length() {
            if served.supportedInterfaces[i].protocolBinding == HTTP_JSON {
                served.supportedInterfaces[i].url = url;
            }
        }
        return served;
    }

    # Rejects a request whose A2A-Version header names anything but 1.0, by
    # Major.Minor. An absent header means 0.3 ([section 3.6.2](https://a2a-protocol.org/latest/specification/#362-server-responsibilities)), which this
    # v1.0-only server does not serve. Section 3.6 requires Major.Minor to
    # match exactly ("Agents MUST process requests using the semantics of
    # the requested A2A-Version (matching Major.Minor)") and separately
    # says patch numbers "do not affect protocol compatibility" -- so a
    # patch-qualified version ("1.0.5") is compared only on its first two
    # components, matched against `majorMinor`, below. "1.1" is still
    # correctly refused: nothing guarantees a later 1.x minor stays
    # wire-compatible with 1.0, and both reference SDKs are laxer than
    # the spec text here (accepting any 1.x) -- this follows the spec, not
    # them. Matches the client-side requireV1Interface check.
    #
    # + req - The HTTP request
    # + return - A VersionNotSupportedError when the version is unsupported
    private isolated function checkVersion(http:Request req) returns Error? {
        string|http:HeaderNotFoundError header = req.getHeader("A2A-Version");
        string version = header is string ? header : "0.3";
        if majorMinor(version) != A2A_PROTOCOL_VERSION {
            string msg = string `A2A protocol version ${version} is not supported; `
                + string `this interface serves v1.0`;
            return error VersionNotSupportedError(msg, message = msg);
        }
        return;
    }

    # Rejects a request that omits a required extension.
    #
    # Per [specification section 3.3.4](https://a2a-protocol.org/latest/specification/#334-capability-validation)/[4.6.3](https://a2a-protocol.org/latest/specification/#463-extension-versioning-and-compatibility): an `AgentExtension` the card
    # declares `required: true` is not optional the way an unrequired one
    # is -- a client that has not declared support for it (via the
    # A2A-Extensions header, [section 14.2.2](https://a2a-protocol.org/latest/specification/#1422-a2a-extensions-header)) must not have its request
    # silently processed as if the extension's requirements did not
    # apply. Extensions with no `uri` set are skipped -- nothing a client
    # could ever declare support for.
    #
    # + req - The HTTP request
    # + return - An ExtensionSupportRequiredError naming the first
    #            undeclared required extension, or `()`
    private isolated function checkExtensions(http:Request req) returns Error? {
        AgentExtension[] extensions = self.card.capabilities.extensions ?: [];
        boolean anyRequired = extensions.some(ext => ext.required);
        if !anyRequired {
            return;
        }

        string|http:HeaderNotFoundError header = req.getHeader("A2A-Extensions");
        string[] declared = [];
        if header is string {
            foreach string uri in re `,`.split(header) {
                declared.push(uri.trim());
            }
        }

        foreach AgentExtension ext in extensions {
            string? uri = ext.uri;
            if ext.required && uri is string && declared.indexOf(uri) is () {
                string msg = string `extension ${uri} is required but was not declared `
                    + "in the A2A-Extensions header";
                return error ExtensionSupportRequiredError(msg, message = msg, code = -32008);
            }
        }
    }

    # Splits an optional leading /{tenant} segment off the path.
    #
    # The proto gives every operation a /{tenant}-prefixed additional binding.
    # A prefixed request must carry the tenant the card declares, or it is
    # rejected; the bare form carries no tenant.
    #
    # + rawPath - The request path
    # + return - The path with any tenant prefix removed, and the tenant (or
    #            `()`); or an error if a tenant prefix does not match the card
    private isolated function stripTenant(string rawPath) returns [string, string?]|Error {
        // The known operation paths all begin with one of these. "/message:"
        // is self-delimited (its own ':' is the boundary), but "/tasks" and
        // "/extendedAgentCard" are not: a bare startsWith check on those two
        // also matches a tenant segment that happens to share the prefix,
        // e.g. "/tasks-eu/message:send" -- so for those, the character right
        // after the prefix must actually end the path or start the next
        // segment ('/' or ':'), not continue the same word.
        foreach string known in ["/message:", "/tasks", "/extendedAgentCard"] {
            if !rawPath.startsWith(known) {
                continue;
            }
            if known.endsWith(":") || rawPath.length() == known.length() {
                return [rawPath, ()];
            }
            string next = rawPath.substring(known.length(), known.length() + 1);
            if next == "/" || next == ":" {
                return [rawPath, ()];
            }
        }
        // Otherwise the first segment is a tenant: /{tenant}/rest...
        int? secondSlash = rawPath.indexOf("/", 1);
        if secondSlash is int {
            string tenant = rawPath.substring(1, secondSlash);
            string rest = rawPath.substring(secondSlash);
            string? declared = declaredTenant(self.card);
            if declared is () || declared != tenant {
                // The caller named a tenant this agent does not serve: its
                // own mistake, so a 400 -- not InvalidAgentResponseError, which
                // is for an *agent's* malformed response and is a 500.
                return invalidParams(string `request routed under tenant "${tenant}", which the agent does not serve`);
            }
            return [rest, tenant];
        }
        return [rawPath, ()];
    }

    # Dispatches a tenant-stripped path to its operation.
    #
    # The unary operations and the two streaming ones are wired in this
    # release; the push-config store and the extended card are added in
    # later changes, and an unmatched path is a 404 (`methodNotFound`).
    #
    # + method - The HTTP method
    # + path - The path with no tenant prefix
    # + tenant - The matched tenant, or `()`
    # + owner - The caller's resolved owner scope, or `()`
    # + req - The HTTP request
    # + return - The response, or an error to serialise
    private isolated function route(string method, string path, string? tenant, string? owner, http:Request req)
            returns http:Response|stream<http:SseEvent, error?>|Error {
        // The exact-match operations dispatch by [method, path] equality; the
        // rest below need startsWith/endsWith/includes on the path, which a
        // match pattern can't express, so they stay as guarded `if`s.
        match [method, path] {
            ["POST", "/message:send"] => {
                return self.onSendMessage(tenant, owner, req);
            }
            ["POST", "/message:stream"] => {
                return self.onSendStreamingMessage(tenant, owner, req);
            }
            ["GET", "/extendedAgentCard"] => {
                AgentCard extended = check servedExtendedCard(self.extendedCard);
                return cardHttpResponse(self.cardWithInterfaceUrl(extended, req), authenticated = true);
            }
            ["GET", "/tasks"] => {
                ListTasksRequest filter = check queryToListFilter(req);
                return jsonResponse((check self.handler.listTasks(filter, owner)).toJson());
            }
        }

        if method == "POST" && path.startsWith(TASKS_PATH_PREFIX) && path.endsWith(":cancel") {
            string id = path.substring(TASKS_PATH_PREFIX.length(), path.length() - ":cancel".length());
            // The proto's `{id=*}` matches exactly one path segment; a
            // slash in what would otherwise be the id means this path
            // names no A2A operation at all, not a lookup for a task
            // literally named "a/b".
            if id.includes("/") {
                return methodNotFound(string `no A2A operation at ${method} ${path}`);
            }
            return jsonResponse((check self.handler.cancelTask({id}, owner)).toJson());
        }
        // The proto's own annotation is GET, but the client falls back to
        // POST on a 404 -- a compat workaround for a non-reference server
        // that only registered POST here (mirroring the reference *client*,
        // which sends POST) -- and 404 is also what a genuinely-unknown
        // task's TaskNotFoundError carries. Accepting POST here too means
        // that fallback still reaches the real handler and surfaces the
        // correct typed error, rather than a second, unrelated 404 for "no
        // such route" masking the first.
        if (method == "GET" || method == "POST") && path.startsWith(TASKS_PATH_PREFIX) && path.endsWith(":subscribe") {
            string id = path.substring(TASKS_PATH_PREFIX.length(), path.length() - ":subscribe".length());
            if id.includes("/") {
                return methodNotFound(string `no A2A operation at ${method} ${path}`);
            }
            return self.onSubscribeToTask(id, owner);
        }
        // onPushNotificationConfigs assumes a "/tasks/{taskId}/pushNotificationConfigs..." shape
        // (the only shape the spec's HTTP+JSON binding defines) and slices the path on that
        // assumption; requiring the /tasks/ prefix here keeps a bare "/pushNotificationConfigs" --
        // never a legal path -- from reaching that slicing at all, and falling through to the
        // 404 below instead.
        if path.startsWith(TASKS_PATH_PREFIX) && path.includes(PUSH_NOTIFICATION_CONFIGS_SEGMENT) {
            return self.onPushNotificationConfigs(method, path, owner, req);
        }
        if method == "GET" && path.startsWith(TASKS_PATH_PREFIX) && !path.includes(":")
                && !path.includes(PUSH_NOTIFICATION_CONFIGS_SEGMENT) {
            string id = path.substring(TASKS_PATH_PREFIX.length());
            if id.includes("/") {
                return methodNotFound(string `no A2A operation at ${method} ${path}`);
            }
            int? historyLength = check queryInt(req, "historyLength");
            return jsonResponse((check self.handler.getTask({id, historyLength}, owner)).toJson());
        }
        return methodNotFound(string `no A2A operation at ${method} ${path}`);
    }

    # Handles POST /message:send: decode the request, run onMessage through
    # the default handler, and serialise the Task or Message it returns.
    #
    # + tenant - The matched tenant, or `()`
    # + owner - The caller's resolved owner scope, or `()`
    # + req - The HTTP request
    # + return - The response, or an error
    private isolated function onSendMessage(string? tenant, string? owner, http:Request req)
            returns http:Response|Error {
        SendMessageRequest request = check decodeSendMessageRequest(req.getJsonPayload());
        Task|Message result = check self.handler.sendMessage(request, tenant, owner);
        // The wire wraps the result in its oneof arm, matching what the client
        // decodes: {"task": ...} or {"message": ...}.
        string arm = result is Task ? "task" : "message";
        json|error wired = encodeRawBytesForWire(result.toJson());
        if wired is error {
            return wrapTransportError(wired);
        }
        return jsonResponse({[arm]: wired});
    }

    # Handles POST /message:stream: decode the request, run onMessage through
    # the default handler, and frame every event it produced as SSE.
    #
    # + tenant - The matched tenant, or `()`
    # + owner - The caller's resolved owner scope, or `()`
    # + req - The HTTP request
    # + return - The SSE stream, or an error
    private isolated function onSendStreamingMessage(string? tenant, string? owner, http:Request req)
            returns stream<http:SseEvent, error?>|Error {
        if !self.card.capabilities.streaming {
            return serverStreamingUnsupportedError("sendStreamingMessage");
        }
        SendMessageRequest request = check decodeSendMessageRequest(req.getJsonPayload());
        stream<StreamResponse, Error?> events =
            check self.handler.sendStreamingMessage(request, tenant, owner, self.streamTiming);
        stream<http:SseEvent, error?> framed = new (new SseFramingGenerator(events));
        return framed;
    }

    # Handles GET /tasks/{id}:subscribe: the task's current state, followed
    # live by every further event a driver still running against it
    # produces. See `DefaultHandler.subscribeToTask` for the terminal-task
    # rejection and the attach-before-snapshot ordering.
    #
    # + id - The task id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The SSE stream, or an error
    private isolated function onSubscribeToTask(string id, string? owner) returns stream<http:SseEvent, error?>|Error {
        if !self.card.capabilities.streaming {
            return serverStreamingUnsupportedError("subscribeToTask");
        }
        stream<StreamResponse, Error?> events = check self.handler.subscribeToTask({id}, owner, self.streamTiming);
        stream<http:SseEvent, error?> framed = new (new SseFramingGenerator(events));
        return framed;
    }

    # Routes one of the four push-notification config operations, all under
    # `/tasks/{taskId}/pushNotificationConfigs[/{id}]`: POST (create) and GET
    # (list) on the collection path; GET (get) and DELETE (delete) on the
    # item path.
    #
    # + method - The HTTP method
    # + path - The path with no tenant prefix, already known to contain
    #          "/pushNotificationConfigs"
    # + owner - The caller's resolved owner scope, or `()`
    # + req - The HTTP request
    # + return - The response, or an error to serialise
    private isolated function onPushNotificationConfigs(string method, string path, string? owner, http:Request req)
            returns http:Response|Error {
        // Per [specification section 3.3.4](https://a2a-protocol.org/latest/specification/#334-capability-validation), capability validation applies
        // to Create/Get/List/Delete explicitly -- all four route through
        // here, so one gate covers all four, the same way
        // cardDeniesPushNotifications gates all four on the client side.
        if !self.card.capabilities.pushNotifications {
            return serverPushNotificationsUnsupportedError("push-notification-config operations");
        }

        int marker = <int>path.indexOf(PUSH_NOTIFICATION_CONFIGS_SEGMENT);
        string taskId = path.substring(TASKS_PATH_PREFIX.length(), marker);
        string rest = path.substring(marker + PUSH_NOTIFICATION_CONFIGS_SEGMENT.length());

        if rest == "" && method == "POST" {
            return self.onCreateTaskPushNotificationConfig(taskId, owner, req);
        }
        if rest == "" && method == "GET" {
            return self.onListTaskPushNotificationConfigs(taskId, owner, req);
        }
        if rest.startsWith("/") && method == "GET" {
            return jsonResponse(
                    (check self.handler.getTaskPushNotificationConfig({taskId, id: rest.substring(1)}, owner))
                        .toJson());
        }
        if rest.startsWith("/") && method == "DELETE" {
            check self.handler.deleteTaskPushNotificationConfig({taskId, id: rest.substring(1)}, owner);
            return jsonResponse({});
        }
        return methodNotFound(string `no A2A operation at ${method} ${path}`);
    }

    # Handles POST /tasks/{taskId}/pushNotificationConfigs: decode the
    # config, stamp its `taskId` from the path, and register it.
    #
    # + taskId - The parent task id, from the path
    # + owner - The caller's resolved owner scope, or `()`
    # + req - The HTTP request
    # + return - The stored config, or an error
    private isolated function onCreateTaskPushNotificationConfig(string taskId, string? owner, http:Request req)
            returns http:Response|Error {
        TaskPushNotificationConfig request = check decodePushConfigRequest(req.getJsonPayload(), taskId);
        return jsonResponse((check self.handler.createTaskPushNotificationConfig(request, owner)).toJson());
    }

    # Handles GET /tasks/{taskId}/pushNotificationConfigs: list every config
    # registered for the task, with optional pagination query params.
    #
    # + taskId - The parent task id, from the path
    # + owner - The caller's resolved owner scope, or `()`
    # + req - The HTTP request
    # + return - The page of configs, or an error
    private isolated function onListTaskPushNotificationConfigs(string taskId, string? owner, http:Request req)
            returns http:Response|Error {
        ListTaskPushNotificationConfigsRequest request = {taskId};
        int? pageSize = check queryInt(req, "pageSize");
        if pageSize is int {
            request.pageSize = pageSize;
        }
        string? pageToken = req.getQueryParamValue("pageToken");
        if pageToken is string {
            request.pageToken = pageToken;
        }
        return jsonResponse((check self.handler.listTaskPushNotificationConfigs(request, owner)).toJson());
    }
}

# Builds the server-side rejection for a streaming operation called against
# a card that does not declare `capabilities.streaming`. Distinct from
# `operations.bal`'s client-side `streamingUnsupportedError`, which rejects
# before a request is even sent; this one is what a client sees on the wire
# when it sends one anyway.
#
# + operation - The operation name, for the message
# + return - The typed error
isolated function serverStreamingUnsupportedError(string operation) returns UnsupportedOperationError {
    string msg = string `${operation}: this agent's capabilities.streaming is false`;
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# Builds the server-side rejection for a push-notification-config
# operation called against a card that does not declare
# `capabilities.pushNotifications`. Distinct from `errors.bal`'s
# client-side `pushNotificationsUnsupportedError`, which rejects before a
# request is even sent; this one is what a client sees on the wire when
# it sends one anyway. Per [specification section 3.3.4](https://a2a-protocol.org/latest/specification/#334-capability-validation), applies to
# Create/Get/List/Delete alike.
#
# + operation - The operation name, for the message
# + return - The typed error
isolated function serverPushNotificationsUnsupportedError(string operation) returns PushNotificationNotSupportedError {
    string msg = string `${operation}: this agent's capabilities.pushNotifications is false`;
    return error PushNotificationNotSupportedError(msg, message = msg, code = -32003);
}

# Wraps one already-computed `StreamResponse` value into the oneof-envelope
# JSON shape the client's `decodeStreamResponseEnvelope` reads:
# `{"task": ...}`, `{"message": ...}`, `{"statusUpdate": ...}`, or
# `{"artifactUpdate": ...}`.
#
# + value - The event to wire-encode
# + return - The enveloped JSON, or an error if `encodeRawBytesForWire` failed
isolated function wireEnvelopeFor(StreamResponse value) returns json|error {
    string arm;
    if value is Task {
        arm = "task";
    } else if value is Message {
        arm = "message";
    } else if value is TaskStatusUpdateEvent {
        arm = "statusUpdate";
    } else {
        arm = "artifactUpdate";
    }
    json wired = check encodeRawBytesForWire(value.toJson());
    return {[arm]: wired};
}

# Frames a live `stream<StreamResponse, Error?>` as SSE, event by event, as
# each one arrives -- the generator underlying both `sendStreamingMessage`'s
# and `subscribeToTask`'s responses.
#
# A value wire-encodes via `wireEnvelopeFor`, the same as a plain HTTP JSON
# response would. A stream ending with an `Error` completion --
# `DefaultHandler.finishDrivenTask`
# ending a live tap this way when a task's driving turn itself failed --
# is framed as a named `event: error` SSE frame carrying the same
# `restErrorBody` shape `toRestErrorResponse` would use for a plain HTTP
# failure, then the stream ends; the client's `A2aStreamGenerator` already
# knows to decode exactly this frame (it has since the client shipped),
# nothing server-side has emitted it until now. A wire-encoding failure on
# an otherwise-good value is framed the same way, rather than dropping the
# connection with a raw transport error.
class SseFramingGenerator {
    private stream<StreamResponse, Error?> events;
    private boolean closed = false;

    isolated function init(stream<StreamResponse, Error?> events) {
        self.events = events;
    }

    # + return - The next SSE event, `()` at end of stream, or an error
    public isolated function next() returns record {| http:SseEvent value; |}|error? {
        if self.closed {
            return;
        }
        record {| StreamResponse value; |}|Error? chunk = self.events.next();
        if chunk is () {
            self.closed = true;
            return;
        }
        if chunk is KeepAliveTick {
            // An SSE comment frame (": keep-alive"): no event for the client
            // to act on, but bytes on the connection, so neither side's idle
            // timeout fires on a task that is simply taking a while. The
            // client already skips a frame that carries no data.
            return {value: {comment: "keep-alive"}};
        }
        if chunk is Error {
            self.closed = true;
            return {value: {'event: "error", data: restErrorBody(chunk).toJsonString()}};
        }
        json|error envelope = wireEnvelopeFor(chunk.value);
        if envelope is error {
            self.closed = true;
            return {value: {'event: "error", data: restErrorBody(wrapTransportError(envelope)).toJsonString()}};
        }
        return {value: {data: envelope.toJsonString()}};
    }

    # Consumer-side close: forwards to `self.events` (an `EventTap` for a
    # live `sendStreamingMessage`/`subscribeToTask`), the same way `EventTap`
    # itself forwards to nothing further because it *is* the source.
    #
    # Required for the same reason `EventTap.close` documents itself as
    # required: a `stream<T,E>` built by wrapping a generator object only
    # calls close on that object if it defines one. `ballerina/mime`'s
    # `EventStreamWriter` (the thing actually writing these bytes to the
    # wire) calls `self.eventStream.close()` when a write fails -- the
    # ordinary way a client disconnect surfaces -- so without this method,
    # that close signal reached exactly as far as this class and stopped:
    # the wrapped `EventTap` was never told, and stayed registered, idle,
    # for up to `streamIdleTimeout` (or, for a task paused on
    # `TASK_STATE_AUTH_REQUIRED`, indefinitely).
    #
    # + return - Always `()`; `EventTap.close` cannot itself fail
    public isolated function close() returns error? {
        return self.events.close();
    }
}

# Logs a request that authentication refused, per
# [specification section 13.4](https://a2a-protocol.org/latest/specification/#134-general-security-best-practices):
# agents SHOULD log authentication failures and authorization denials. Never
# the credential itself -- only the scheme it was presented under.
#
# + failure - Why the request was not admitted
# + method - The HTTP method
# + path - The request path
# + scheme - The credential scheme presented, lower-cased, or `()` if none was
isolated function logAuthFailure(AuthFailure failure, string method, string path, string? scheme) {
    if failure.forbidden {
        log:printWarn("A2A request denied: the caller lacks a required scope", method = method, path = path,
                requiredScopes = ", ".'join(...failure.requiredScopes));
        return;
    }
    log:printWarn("A2A request rejected: missing or invalid credentials", method = method, path = path,
            scheme = scheme ?: "none");
}

# Reads the tenant a card declares on its HTTP+JSON interface, or `()`.
#
# + card - The agent card
# + return - The declared tenant, or `()` if the interface declares none
isolated function declaredTenant(AgentCard card) returns string? {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == HTTP_JSON {
            return iface?.tenant;
        }
    }
    return;
}

# Builds a JSON 200 response.
#
# + body - The JSON body
# + return - The response
isolated function jsonResponse(json body) returns http:Response {
    http:Response response = new;
    response.setJsonPayload(body, CONTENT_TYPE_A2A_JSON);
    return response;
}

# Seconds a client may cache a served Agent Card before revalidating.
# Per [specification section 8.6.1](https://a2a-protocol.org/latest/specification/#861-server-requirements): no particular value is mandated, only
# that it be "appropriate for the agent's expected update frequency" --
# cards changing on redeploy rather than per-request, five minutes is a
# reasonable, conservative default for a card this rarely changes.
const int AGENT_CARD_CACHE_MAX_AGE_SECONDS = 300;

# Serves an `AgentCard` (the well-known discovery card or the extended
# one) with the caching headers [section 8.6.1](https://a2a-protocol.org/latest/specification/#861-server-requirements) asks for.
#
# `ETag` uses the card's own `version` field, the simpler of the two
# options that section names (the other being a hash of the served content) --
# sufficient since a served card's `version` is the developer's own,
# presumed to change whenever the card's definition does.
#
# The extended card is marked `private`: it is served only to an
# authenticated caller, and section 13.3 asks for "appropriate caching
# headers" for it. `private` keeps a shared cache (a proxy or CDN) from
# storing it for other callers, whatever that cache's policy on
# `Authorization`-bearing requests.
#
# + card - The card to serve
# + authenticated - Whether this is the extended card, for authenticated callers only
# + return - The HTTP response carrying it
isolated function cardHttpResponse(AgentCard card, boolean authenticated = false) returns http:Response {
    http:Response response = jsonResponse(encodeAgentCardForWire(card));
    string scope = authenticated ? "private, " : "";
    response.setHeader("Cache-Control", string `${scope}max-age=${AGENT_CARD_CACHE_MAX_AGE_SECONDS}`);
    response.setHeader("ETag", string `"${card.version}"`);
    return response;
}

# Reads an integer query parameter.
#
# A value that is present but not an integer is refused rather than ignored,
# so `historyLength=abc` is a 400 and not a silent "no limit"
# ([specification section 3.3.2](https://a2a-protocol.org/latest/specification/#332-error-handling):
# servers MUST validate all input parameters).
#
# + req - The request
# + name - The parameter name
# + return - The integer value, `()` if absent, or an InvalidParams Error
isolated function queryInt(http:Request req, string name) returns int|Error? {
    string? raw = req.getQueryParamValue(name);
    if raw is () {
        return;
    }
    int|error parsed = int:fromString(raw);
    if parsed is error {
        return invalidParams(string `${name} "${raw}" is not an integer`, name);
    }
    return parsed;
}

# The first two dot-separated components of a version string -- its
# Major.Minor, with any patch component (a third or later segment) dropped.
# A version with fewer than two components is returned as given, so it
# still compares unequal to a real "Major.Minor" value rather than being
# coerced into a false match.
#
# + version - The version string, e.g. "1.0", "1.0.5", or "0.3"
# + return - Just the Major.Minor prefix, e.g. "1.0"
isolated function majorMinor(string version) returns string {
    int? firstDot = version.indexOf(".");
    if firstDot is () {
        return version;
    }
    int? secondDot = version.indexOf(".", firstDot + 1);
    return secondDot is () ? version : version.substring(0, secondDot);
}

# Builds a ListTasksRequest from the query string of a GET /tasks request.
#
# Every value present is validated at the wire level here -- an
# unrecognized `status`, or a `pageSize`/`historyLength` that doesn't parse
# as an integer, is refused with `InvalidParams` (400) rather than silently
# dropped, per specification section 6.5's own validation example. Range
# checks that depend on interpreting an already-well-formed value against
# domain rules -- `pageSize` outside 1..100 (section 3.1.4), and whether a
# `pageToken` names a real cursor -- are the store's job instead
# (`InMemoryTaskStore.list`), since a custom `TaskStore` may have entirely
# different pagination semantics of its own; this function only owns
# translating the HTTP wire format into a `ListTasksRequest`.
#
# + req - The request
# + return - The filter, or an InvalidParams Error
isolated function queryToListFilter(http:Request req) returns ListTasksRequest|Error {
    ListTasksRequest filter = {};
    string? contextId = req.getQueryParamValue("contextId");
    if contextId is string {
        filter.contextId = contextId;
    }
    string? status = req.getQueryParamValue("status");
    if status is string {
        TaskState|error state = status.ensureType();
        if state is error {
            return invalidParams(string `status "${status}" is not a valid task state`, "status");
        }
        filter.status = state;
    }
    int? pageSize = check queryInt(req, "pageSize");
    if pageSize is int {
        filter.pageSize = pageSize;
    }
    string? pageToken = req.getQueryParamValue("pageToken");
    if pageToken is string {
        filter.pageToken = pageToken;
    }
    int? historyLength = check queryInt(req, "historyLength");
    if historyLength is int {
        filter.historyLength = historyLength;
    }
    string? after = req.getQueryParamValue("statusTimestampAfter");
    if after is string {
        time:Utc|error parsed = time:utcFromString(after);
        if parsed is error {
            return invalidParams(string `statusTimestampAfter "${after}" is not a valid RFC 3339 timestamp`,
                "statusTimestampAfter");
        }
        filter.statusTimestampAfter = after;
    }
    string? includeArtifacts = req.getQueryParamValue("includeArtifacts");
    if includeArtifacts is string {
        if includeArtifacts != "true" && includeArtifacts != "false" {
            return invalidParams(string `includeArtifacts "${includeArtifacts}" is not true or false`, "includeArtifacts");
        }
        filter.includeArtifacts = includeArtifacts == "true";
    }
    return filter;
}

# The URL the served card gives clients for this listener.
#
# + publicUrl - `HttpListenerConfiguration.publicUrl`, already normalised, if set
# + scheme - `http` or `https`, from what the HTTP listener really serves
# + host - The request's `Host` header
# + return - The public URL when configured, otherwise `scheme://host`
isolated function interfaceUrlFor(string? publicUrl, string scheme, string host) returns string {
    return publicUrl ?: string `${scheme}://${host}`;
}

# The card `getExtendedAgentCard` serves.
#
# Per [specification section 3.3.4](https://a2a-protocol.org/latest/specification/#334-capability-validation), the two failure reasons are
# distinct: `capabilities.extendedAgentCard` false/absent is
# `UnsupportedOperationError`; declared `true` but no card actually
# configured is `ExtendedAgentCardNotConfiguredError`. `deriveServedCard`
# ties the capability flag 1:1 to whether a card was configured, so the
# second case can never actually happen here -- an unconfigured card always
# means the capability reads `false` too, which is the first case.
#
# + extendedCard - The listener's derived extended card, or `()` if none is
#                  configured
# + return - The extended card, or an UnsupportedOperationError if none was
#            set up
isolated function servedExtendedCard((AgentCard & readonly)? extendedCard) returns AgentCard|Error {
    if extendedCard is AgentCard {
        return extendedCard;
    }
    string msg = "capabilities.extendedAgentCard is false: no extended AgentCard is configured for this agent";
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# Builds the transport-free view of a request's caller that an
# `a2a:TaskOwnerResolver` sees.
#
# Header names are lower-cased: HTTP treats them case-insensitively, and the
# same resolver should read `x-api-key` whichever binding delivered it. The
# client certificate is passed on only when the mutual TLS handshake passed.
#
# + req - The inbound request
# + identity - The identity authentication established, or `()`
# + tenant - The tenant the request was routed under, or `()`
# + return - The caller context
isolated function callerContextOf(http:Request req, string? identity, string? tenant) returns CallerContext {
    map<string[]> headers = {};
    foreach string name in req.getHeaderNames() {
        string key = name.toLowerAscii();
        // `getHeaders` is itself case-insensitive, so a name already taken
        // under another casing has all its values already.
        string[]|http:HeaderNotFoundError values = req.getHeaders(name);
        if !headers.hasKey(key) && values is string[] {
            headers[key] = values;
        }
    }
    http:MutualSslHandshake? handshake = req.mutualSslHandshake;
    string? certificate = handshake is http:MutualSslHandshake && handshake.status == http:PASSED
        ? handshake.base64EncodedCert : ();
    CallerContext context = {headers};
    if identity is string {
        context.identity = identity;
    }
    if tenant is string {
        context.tenant = tenant;
    }
    if certificate is string {
        context.clientCertificateBase64 = certificate;
    }
    return context;
}
