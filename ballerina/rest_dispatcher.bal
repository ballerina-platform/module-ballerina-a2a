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
// Each operation is a resource at its HTTP+JSON path, and again under the
// /{tenant} prefix the proto's additional bindings give it, so a path that
// names no operation gets the HTTP module's own 404 (or 405 for a known path
// and a wrong method). Two operations cannot be resource paths:
// `/tasks/{id}:cancel` and `/tasks/{id}:subscribe` put a literal suffix after
// a path parameter, which a resource path cannot express. They arrive at
// `tasks/[string idAndVerb]` and are told apart by that suffix.
//
// Operation handlers build `http:Response` directly instead of returning the
// `http:Ok|http:BadRequest|...` status-typed unions other listeners use: every
// operation shares one error path, `toRestErrorResponse`, which maps an
// `a2a:Error` to its status and google.rpc.Status body.
// the response, rather than one return type per operation.

import ballerina/http;
import ballerina/log;
import ballerina/time;

# The A2A protocol version this server implements.
const A2A_PROTOCOL_VERSION = "1.0";

# The operations a REST route can name. `GET_TASK_SEGMENT` and
# `POST_TASK_SEGMENT` are the routes whose task-id segment may carry a
# `:cancel` or `:subscribe` suffix.
type RestOperation SEND_MESSAGE|SEND_STREAMING_MESSAGE|GET_EXTENDED_AGENT_CARD|LIST_TASKS|GET_TASK_SEGMENT
    |POST_TASK_SEGMENT|CREATE_PUSH_CONFIG|LIST_PUSH_CONFIGS|GET_PUSH_CONFIG|DELETE_PUSH_CONFIG;

# What a route answers with: a response, or a live SSE stream.
type RestResult http:Response|stream<http:SseEvent, error?>;

const SEND_MESSAGE = "SendMessage";
const SEND_STREAMING_MESSAGE = "SendStreamingMessage";
const GET_EXTENDED_AGENT_CARD = "GetExtendedAgentCard";
const LIST_TASKS = "ListTasks";
const GET_TASK_SEGMENT = "GetTaskSegment";
const POST_TASK_SEGMENT = "PostTaskSegment";
const CREATE_PUSH_CONFIG = "CreateTaskPushNotificationConfig";
const LIST_PUSH_CONFIGS = "ListTaskPushNotificationConfigs";
const GET_PUSH_CONFIG = "GetTaskPushNotificationConfig";
const DELETE_PUSH_CONFIG = "DeleteTaskPushNotificationConfig";

isolated service class RestDispatcherService {
    *http:Service;

    private final AgentCard & readonly card;
    private final OperationBinding binding;
    private final ServedCards cards;
    private final ListenerAuthenticator? authenticator;
    private final string interfaceScheme;
    private final string? publicUrl;
    private final StreamTiming & readonly streamTiming;
    // The path the service is mounted at, which the served interface URL ends in
    private final string mountPath;
    private final boolean validateInputModes;

    isolated function init(AgentCard card, OperationBinding binding, ServedCards cards,
            ListenerAuthenticator? authenticator, string interfaceScheme, string? publicUrl,
            StreamTiming streamTiming, string mountPath, boolean validateInputModes) {
        self.card = card.cloneReadOnly();
        self.binding = binding;
        self.cards = cards;
        self.authenticator = authenticator;
        self.interfaceScheme = interfaceScheme;
        self.publicUrl = publicUrl;
        self.streamTiming = streamTiming.cloneReadOnly();
        self.mountPath = mountPath;
        self.validateInputModes = validateInputModes;
    }

    // ---- the operations, each at its path and again under /{tenant} ----

    isolated resource function post message\:send(http:Request req) returns RestResult =>
        self.serve(req, (), SEND_MESSAGE);

    isolated resource function post [string tenant]/message\:send(http:Request req) returns RestResult =>
        self.serve(req, tenant, SEND_MESSAGE);

    isolated resource function post message\:stream(http:Request req) returns RestResult =>
        self.serve(req, (), SEND_STREAMING_MESSAGE);

    isolated resource function post [string tenant]/message\:stream(http:Request req) returns RestResult =>
        self.serve(req, tenant, SEND_STREAMING_MESSAGE);

    isolated resource function get extendedAgentCard(http:Request req) returns RestResult =>
        self.serve(req, (), GET_EXTENDED_AGENT_CARD);

    isolated resource function get [string tenant]/extendedAgentCard(http:Request req) returns RestResult =>
        self.serve(req, tenant, GET_EXTENDED_AGENT_CARD);

    isolated resource function get tasks(http:Request req) returns RestResult =>
        self.serve(req, (), LIST_TASKS);

    isolated resource function get [string tenant]/tasks(http:Request req) returns RestResult =>
        self.serve(req, tenant, LIST_TASKS);

    // GET /tasks/{id}, and GET /tasks/{id}:subscribe, which arrives here too:
    // the proto annotates SubscribeToTask as GET, and a resource path cannot
    // put `:subscribe` after `[string id]`.
    isolated resource function get tasks/[string idAndVerb](http:Request req) returns RestResult =>
        self.serve(req, (), GET_TASK_SEGMENT, idAndVerb);

    isolated resource function get [string tenant]/tasks/[string idAndVerb](http:Request req) returns RestResult =>
        self.serve(req, tenant, GET_TASK_SEGMENT, idAndVerb);

    // POST /tasks/{id}:cancel and POST /tasks/{id}:subscribe.
    isolated resource function post tasks/[string idAndVerb](http:Request req) returns RestResult =>
        self.serve(req, (), POST_TASK_SEGMENT, idAndVerb);

    isolated resource function post [string tenant]/tasks/[string idAndVerb](http:Request req) returns RestResult =>
        self.serve(req, tenant, POST_TASK_SEGMENT, idAndVerb);

    isolated resource function post tasks/[string id]/pushNotificationConfigs(http:Request req) returns RestResult =>
        self.serve(req, (), CREATE_PUSH_CONFIG, id);

    isolated resource function post [string tenant]/tasks/[string id]/pushNotificationConfigs(
            http:Request req) returns RestResult =>
        self.serve(req, tenant, CREATE_PUSH_CONFIG, id);

    isolated resource function get tasks/[string id]/pushNotificationConfigs(http:Request req) returns RestResult =>
        self.serve(req, (), LIST_PUSH_CONFIGS, id);

    isolated resource function get [string tenant]/tasks/[string id]/pushNotificationConfigs(
            http:Request req) returns RestResult =>
        self.serve(req, tenant, LIST_PUSH_CONFIGS, id);

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](
            http:Request req) returns RestResult =>
        self.serve(req, (), GET_PUSH_CONFIG, id, configId);

    isolated resource function get [string tenant]/tasks/[string id]/pushNotificationConfigs/[string configId](
            http:Request req) returns RestResult =>
        self.serve(req, tenant, GET_PUSH_CONFIG, id, configId);

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](
            http:Request req) returns RestResult =>
        self.serve(req, (), DELETE_PUSH_CONFIG, id, configId);

    isolated resource function delete [string tenant]/tasks/[string id]/pushNotificationConfigs/[string configId](
            http:Request req) returns RestResult =>
        self.serve(req, tenant, DELETE_PUSH_CONFIG, id, configId);

    # Admits a request and runs the operation its route names.
    #
    # + req - The HTTP request
    # + tenant - The `/{tenant}` path segment, or `()` for the untenanted path
    # + operation - The operation the route names
    # + id - The task id path segment, with any `:cancel`/`:subscribe` suffix
    # + configId - The push-notification config id path segment
    # + return - The response to send
    private isolated function serve(http:Request req, string? tenant, RestOperation operation, string id = "",
            string configId = "") returns RestResult {
        Context|http:Response context = self.admit(req, tenant);
        if context is http:Response {
            return context;
        }
        http:Response|stream<http:SseEvent, error?>|Error result = self.run(operation, context, req, id, configId);
        if result is Error {
            return toRestErrorResponse(result);
        }
        return result;
    }

    # Applies the checks every operation shares, in order: authentication,
    # the protocol version, required extensions, and the tenant.
    #
    # + req - The HTTP request
    # + tenant - The `/{tenant}` path segment, or `()`
    # + return - The caller's context, or the response refusing the request
    private isolated function admit(http:Request req, string? tenant) returns Context|http:Response {
        // Authentication comes first, so a caller that has not proved who it
        // is learns nothing else about the server -- not even whether a tenant
        // exists.
        string? identity = ();
        ListenerAuthenticator? authenticator = self.authenticator;
        if authenticator is ListenerAuthenticator {
            string|http:HeaderNotFoundError authorization = req.getHeader(AUTHORIZATION_HEADER);
            string|AuthFailure authenticated = authenticator.authenticate(authorization is string ? authorization : ());
            if authenticated is AuthFailure {
                logAuthFailure(authenticated, req.method, pathOf(req),
                        authorization is string ? schemeOf(authorization) : ());
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

        // A tenanted path must name the tenant the card declares. Naming one
        // the agent does not serve is the caller's mistake, so a 400 -- not
        // InvalidAgentResponseError, which is for an agent's own malformed
        // response and is a 500.
        if tenant is string {
            string? declared = declaredTenant(self.card);
            if declared is () || declared != tenant {
                return toRestErrorResponse(invalidParams(
                        string `request routed under tenant "${tenant}", which the agent does not serve`));
            }
        }

        // The caller as the operations see it: who authentication established,
        // the tenant, the headers, and the stream policy. Each operation
        // resolves the owner itself.
        Context context = callerContextOf(req, identity, tenant);
        context.streamTiming = self.streamTiming;
        return context;
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
        string url = interfaceUrlFor(publicUrl, self.interfaceScheme, host is string ? host : "") + "/" + self.mountPath;
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

    # Runs one operation for an admitted request.
    #
    # + operation - The operation the route names
    # + context - Who is calling, as the listener established it
    # + req - The HTTP request
    # + id - The task id path segment, with any `:cancel`/`:subscribe` suffix
    # + configId - The push-notification config id path segment
    # + return - The response, or an error to serialise
    private isolated function run(RestOperation operation, Context context, http:Request req, string id,
            string configId) returns http:Response|stream<http:SseEvent, error?>|Error {
        match operation {
            SEND_MESSAGE => {
                return self.handleSendMessage(context, req);
            }
            SEND_STREAMING_MESSAGE => {
                return self.handleSendStreamingMessage(context, req);
            }
            GET_EXTENDED_AGENT_CARD => {
                AgentCard supplied = check self.binding.getExtendedAgentCard(context, {tenant: context?.tenant});
                return cardHttpResponse(self.cardWithInterfaceUrl(self.cards.extendedCard(supplied), req),
                        authenticated = true);
            }
            LIST_TASKS => {
                ListTasksRequest filter = check queryToListFilter(req);
                return taskResultResponse(check self.binding.listTasks(context, filter));
            }
            GET_TASK_SEGMENT => {
                // The proto's own annotation for SubscribeToTask is GET; the
                // client sends GET first and falls back to POST on a 404, a
                // compat workaround for servers that registered only POST.
                if id.endsWith(":subscribe") {
                    return self.handleSubscribeToTask(id.substring(0, id.length() - ":subscribe".length()), context);
                }
                if id.includes(":") {
                    return methodNotFound(string `no A2A operation at GET /tasks/${id}`);
                }
                int? historyLength = check queryInt(req, "historyLength");
                return taskResultResponse(check self.binding.getTask(context, {id, historyLength}));
            }
            POST_TASK_SEGMENT => {
                if id.endsWith(":cancel") {
                    return taskResultResponse(check self.binding.cancelTask(context,
                            {id: id.substring(0, id.length() - ":cancel".length())}));
                }
                if id.endsWith(":subscribe") {
                    return self.handleSubscribeToTask(id.substring(0, id.length() - ":subscribe".length()), context);
                }
                return methodNotFound(string `no A2A operation at POST /tasks/${id}`);
            }
        }

        // The four push-notification config operations. Per
        // [specification section 3.3.4](https://a2a-protocol.org/latest/specification/#334-capability-validation),
        // capability validation applies to Create/Get/List/Delete alike, so
        // one gate covers all four, the same way cardDeniesPushNotifications
        // gates all four on the client side.
        if !self.card.capabilities.pushNotifications {
            return serverPushNotificationsUnsupportedError("push-notification-config operations");
        }
        match operation {
            CREATE_PUSH_CONFIG => {
                return self.handleCreateTaskPushNotificationConfig(id, context, req);
            }
            LIST_PUSH_CONFIGS => {
                return self.handleListTaskPushNotificationConfigs(id, context, req);
            }
            GET_PUSH_CONFIG => {
                TaskPushNotificationConfig config =
                        check self.binding.getTaskPushNotificationConfig(context, {taskId: id, id: configId});
                return jsonResponse(config.toJson());
            }
            _ => {
                check self.binding.deleteTaskPushNotificationConfig(context, {taskId: id, id: configId});
                return jsonResponse({});
            }
        }
    }

    # Refuses an inline push-notification config when the service defines no
    # push-notification operations, as it would refuse the Create itself
    # ([specification section 3.3.4](https://a2a-protocol.org/latest/specification/#334-capability-validation)).
    #
    # + request - The decoded send request
    # + operation - The operation being served, for the message
    # + return - A `PushNotificationNotSupportedError`, or `()`
    private isolated function checkInlinePushConfig(SendMessageRequest request, string operation) returns Error? {
        if request?.configuration?.taskPushNotificationConfig is TaskPushNotificationConfig
                && !self.binding.isDefined("handleCreateTaskPushNotificationConfig") {
            return serverPushNotificationsUnsupportedError(operation);
        }
    }

    # Rejects a message whose part media types the card does not declare, unless
    # `validateInputModes` is off.
    #
    # + request - The decoded request
    # + return - A ContentTypeNotSupportedError, or `()`
    private isolated function checkInputModes(SendMessageRequest request) returns Error? {
        if self.validateInputModes {
            return checkInputModes(self.card, request.message);
        }
    }

    # Handles POST /message:send: decode the request, run execute through
    # the default handler, and serialise the Task or Message it returns.
    #
    # + context - Who is calling, as the listener established it
    # + req - The HTTP request
    # + return - The response, or an error
    private isolated function handleSendMessage(Context context, http:Request req)
            returns http:Response|Error {
        SendMessageRequest request = check decodeSendMessageRequest(req.getJsonPayload());
        check self.checkInputModes(request);
        check self.checkInlinePushConfig(request, "sendMessage");
        Task|Message result = check self.binding.sendMessage(context, request);
        // The wire wraps the result in its oneof arm, matching what the client
        // decodes: {"task": ...} or {"message": ...}.
        string arm = result is Task ? "task" : "message";
        json|error wired = encodeRawBytesForWire(result.toJson());
        if wired is error {
            return wrapTransportError(wired);
        }
        return jsonResponse({[arm]: wired});
    }

    # Handles POST /message:stream: decode the request, run execute through
    # the default handler, and frame every event it produced as SSE.
    #
    # + context - Who is calling, as the listener established it
    # + req - The HTTP request
    # + return - The SSE stream, or an error
    private isolated function handleSendStreamingMessage(Context context, http:Request req)
            returns stream<http:SseEvent, error?>|Error {
        if !self.card.capabilities.streaming {
            return serverStreamingUnsupportedError("sendStreamingMessage");
        }
        SendMessageRequest request = check decodeSendMessageRequest(req.getJsonPayload());
        check self.checkInputModes(request);
        check self.checkInlinePushConfig(request, "sendStreamingMessage");
        stream<StreamResponse, Error?> events = check self.binding.sendStreamingMessage(context, request);
        stream<http:SseEvent, error?> framed = new (new SseFramingGenerator(events));
        return framed;
    }

    # Handles GET /tasks/{id}:subscribe: the task's current state, followed
    # live by every further event a driver still running against it
    # produces. See `DefaultHandler.handleSubscribeToTask` for the terminal-task
    # rejection and the attach-before-snapshot ordering.
    #
    # + id - The task id
    # + context - Who is calling, as the listener established it
    # + return - The SSE stream, or an error
    private isolated function handleSubscribeToTask(string id, Context context)
            returns stream<http:SseEvent, error?>|Error {
        if !self.card.capabilities.streaming {
            return serverStreamingUnsupportedError("subscribeToTask");
        }
        stream<StreamResponse, Error?> events = check self.binding.subscribeToTask(context, {id});
        stream<http:SseEvent, error?> framed = new (new SseFramingGenerator(events));
        return framed;
    }

    # Handles POST /tasks/{taskId}/pushNotificationConfigs: decode the
    # config, stamp its `taskId` from the path, and register it.
    #
    # + taskId - The parent task id, from the path
    # + context - Who is calling, as the listener established it
    # + req - The HTTP request
    # + return - The stored config, or an error
    private isolated function handleCreateTaskPushNotificationConfig(string taskId, Context context,
            http:Request req)
            returns http:Response|Error {
        TaskPushNotificationConfig request = check decodePushConfigRequest(req.getJsonPayload(), taskId);
        return jsonResponse((check self.binding.createTaskPushNotificationConfig(context, request)).toJson());
    }

    # Handles GET /tasks/{taskId}/pushNotificationConfigs: list every config
    # registered for the task, with optional pagination query params.
    #
    # + taskId - The parent task id, from the path
    # + context - Who is calling, as the listener established it
    # + req - The HTTP request
    # + return - The page of configs, or an error
    private isolated function handleListTaskPushNotificationConfigs(string taskId, Context context,
            http:Request req)
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
        return jsonResponse((check self.binding.listTaskPushNotificationConfigs(context, request)).toJson());
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

# The request's path without its query string, for logging.
#
# + req - The HTTP request
# + return - The path
isolated function pathOf(http:Request req) returns string {
    string raw = req.rawPath;
    int? query = raw.indexOf("?");
    return query is int ? raw.substring(0, query) : raw;
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

# Builds the 200 response for a result that can carry raw bytes (a task, or a
# page of them): a `raw` part is base64 on the wire, not an array of ints.
#
# + value - The task or list of tasks
# + return - The response, or a transport error if encoding failed
isolated function taskResultResponse(Task|ListTasksResponse value) returns http:Response|Error {
    json|error wired = encodeRawBytesForWire(value.toJson());
    if wired is error {
        return wrapTransportError(wired);
    }
    return jsonResponse(wired);
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
# + publicUrl - `RestListenerConfiguration.publicUrl`, already normalised, if set
# + scheme - `http` or `https`, from what the HTTP listener really serves
# + host - The request's `Host` header
# + return - The public URL when configured, otherwise `scheme://host`
isolated function interfaceUrlFor(string? publicUrl, string scheme, string host) returns string {
    return publicUrl ?: string `${scheme}://${host}`;
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
isolated function callerContextOf(http:Request req, string? identity, string? tenant) returns Context {
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
    Context context = {headers};
    if identity is string {
        context.identity = identity;
    }
    if tenant is string {
        context.tenant = tenant;
    }
    return context;
}
