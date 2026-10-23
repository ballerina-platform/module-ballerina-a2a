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

// The JSON-RPC wire: one POST endpoint that takes a JSON-RPC 2.0 envelope,
// names the operation in `method`, and answers with an envelope of its own.
// Authentication, the version header and the required-extension check are the
// same HTTP-level rules the REST wire applies; everything past them is
// JSON-RPC. A protocol failure is a JSON-RPC error object on a 200, since the
// transport itself worked; only a refusal to authenticate is an HTTP status.

import ballerina/http;

# The JSON-RPC protocol version the envelope carries.
const JSON_RPC_VERSION = "2.0";

# JSON-RPC's own error codes, for failures that precede the A2A operation.
const int JSON_RPC_PARSE_ERROR = -32700;
const int JSON_RPC_INVALID_REQUEST = -32600;

isolated service class JsonRpcDispatcherService {
    *http:Service;

    private final AgentCard & readonly card;
    private final OperationBinding binding;
    private final ServedCards cards;
    private final ListenerAuthenticator? authenticator;
    private final string interfaceScheme;
    private final string? publicUrl;
    private final StreamTiming & readonly streamTiming;
    private final boolean validateInputModes;

    isolated function init(AgentCard card, OperationBinding binding, ServedCards cards,
            ListenerAuthenticator? authenticator, string interfaceScheme, string? publicUrl,
            StreamTiming streamTiming, boolean validateInputModes) {
        self.card = card.cloneReadOnly();
        self.binding = binding;
        self.cards = cards;
        self.authenticator = authenticator;
        self.interfaceScheme = interfaceScheme;
        self.publicUrl = publicUrl;
        self.streamTiming = streamTiming.cloneReadOnly();
        self.validateInputModes = validateInputModes;
    }

    isolated resource function post .(http:Request req) returns http:Response|stream<http:SseEvent, error?> {
        string? identity = ();
        ListenerAuthenticator? authenticator = self.authenticator;
        if authenticator is ListenerAuthenticator {
            string|http:HeaderNotFoundError authorization = req.getHeader(AUTHORIZATION_HEADER);
            string|AuthFailure authenticated = authenticator.authenticate(authorization is string ? authorization : ());
            if authenticated is AuthFailure {
                logAuthFailure(authenticated, "POST", "/rpc", authorization is string ? schemeOf(authorization) : ());
                return toAuthErrorResponse(authenticated, authenticator.challengeHeaders());
            }
            identity = authenticated;
        }

        json|error payload = req.getJsonPayload();
        if payload is error {
            return rpcErrorResponse((), JSON_RPC_PARSE_ERROR, "Parse error: " + payload.message());
        }
        if payload !is map<json> || payload["jsonrpc"] != JSON_RPC_VERSION || payload["method"] !is string {
            return rpcErrorResponse(requestIdOf(payload), JSON_RPC_INVALID_REQUEST,
                    "Invalid Request: expected a JSON-RPC 2.0 request object with a string `method`");
        }
        json id = requestIdOf(payload);
        string method = <string>payload["method"];
        json params = camelCaseKeys(payload["params"] ?: {});

        Error? gate = checkVersionHeader(req);
        if gate is () {
            gate = checkRequiredExtensions(self.card, req);
        }
        if gate is Error {
            return rpcFailure(id, gate);
        }

        // An empty tenant is the protobuf default a client serialises when it names none.
        string? tenant = params is map<json> && params["tenant"] is string && params["tenant"] != ""
            ? <string>params["tenant"] : ();
        string? declared = declaredTenant(self.card, JSONRPC);
        if tenant is string && (declared is () || declared != tenant) {
            return rpcFailure(id, invalidParams(
                    string `request routed under tenant "${tenant}", which the agent does not serve`, "tenant"));
        }
        Context context = callerContextOf(req, identity, tenant);
        context.streamTiming = self.streamTiming;

        json|stream<StreamResponse, Error?>|Error result = self.route(method, params, context, req);
        if result is Error {
            return rpcFailure(id, result);
        }
        if result is stream<StreamResponse, Error?> {
            stream<http:SseEvent, error?> framed = new (new JsonRpcSseFramingGenerator(result, id));
            return framed;
        }
        http:Response response = new;
        response.setJsonPayload({jsonrpc: JSON_RPC_VERSION, id, result});
        return response;
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

    # Runs the operation a method names.
    #
    # + method - The JSON-RPC method, e.g. `SendMessage`
    # + params - The request's `params`
    # + context - Who is calling
    # + req - The HTTP request, for the host the extended card is served under
    # + return - The `result`, a live event stream, or the error to report
    private isolated function route(string method, json params, Context context, http:Request req)
            returns json|stream<StreamResponse, Error?>|Error {
        match method {
            "SendMessage" => {
                SendMessageRequest request = check decodeSendMessageRequest(params);
                check self.checkInputModes(request);
                check self.checkInlinePushConfig(request, "sendMessage");
                Task|Message sent = check self.binding.sendMessage(context, request);
                string arm = sent is Task ? "task" : "message";
                json|error wired = encodeRawBytesForWire(sent.toJson());
                if wired is error {
                    return wrapTransportError(wired);
                }
                return {[arm]: wired};
            }
            "SendStreamingMessage" => {
                if !self.card.capabilities.streaming {
                    return serverStreamingUnsupportedError("sendStreamingMessage");
                }
                SendMessageRequest request = check decodeSendMessageRequest(params);
                check self.checkInputModes(request);
                check self.checkInlinePushConfig(request, "sendStreamingMessage");
                return self.binding.sendStreamingMessage(context, request);
            }
            "SubscribeToTask" => {
                if !self.card.capabilities.streaming {
                    return serverStreamingUnsupportedError("subscribeToTask");
                }
                SubscribeToTaskRequest request = <SubscribeToTaskRequest>check decodeParams(params, SubscribeToTaskRequest);
                return self.binding.subscribeToTask(context, request);
            }
            "GetTask" => {
                GetTaskRequest request = <GetTaskRequest>check decodeParams(params, GetTaskRequest);
                return resultJson(check self.binding.getTask(context, request));
            }
            "ListTasks" => {
                ListTasksRequest request = <ListTasksRequest>check decodeParams(withoutUnsetStatus(params),
                        ListTasksRequest);
                return resultJson(check self.binding.listTasks(context, request));
            }
            "CancelTask" => {
                CancelTaskRequest request = <CancelTaskRequest>check decodeParams(params, CancelTaskRequest);
                return resultJson(check self.binding.cancelTask(context, request));
            }
            "GetExtendedAgentCard" => {
                GetExtendedAgentCardRequest request =
                    <GetExtendedAgentCardRequest>check decodeParams(params, GetExtendedAgentCardRequest);
                AgentCard supplied = check self.binding.getExtendedAgentCard(context, request);
                return encodeAgentCardForWire(self.withInterfaceUrl(self.cards.extendedCard(supplied), req));
            }
            "CreateTaskPushNotificationConfig" => {
                check self.requirePushNotifications("createTaskPushNotificationConfig");
                TaskPushNotificationConfig request =
                    <TaskPushNotificationConfig>check decodeParams(params, TaskPushNotificationConfig);
                return (check self.binding.createTaskPushNotificationConfig(context, request)).toJson();
            }
            "GetTaskPushNotificationConfig" => {
                check self.requirePushNotifications("getTaskPushNotificationConfig");
                GetTaskPushNotificationConfigRequest request = <GetTaskPushNotificationConfigRequest>check
                    decodeParams(params, GetTaskPushNotificationConfigRequest);
                return (check self.binding.getTaskPushNotificationConfig(context, request)).toJson();
            }
            "ListTaskPushNotificationConfigs" => {
                check self.requirePushNotifications("listTaskPushNotificationConfigs");
                ListTaskPushNotificationConfigsRequest request = <ListTaskPushNotificationConfigsRequest>check
                    decodeParams(params, ListTaskPushNotificationConfigsRequest);
                return (check self.binding.listTaskPushNotificationConfigs(context, request)).toJson();
            }
            "DeleteTaskPushNotificationConfig" => {
                check self.requirePushNotifications("deleteTaskPushNotificationConfig");
                DeleteTaskPushNotificationConfigRequest request = <DeleteTaskPushNotificationConfigRequest>check
                    decodeParams(params, DeleteTaskPushNotificationConfigRequest);
                check self.binding.deleteTaskPushNotificationConfig(context, request);
                return {};
            }
        }
        return methodNotFound(string `no A2A method ${method}`);
    }

    private isolated function requirePushNotifications(string operation) returns Error? {
        if !self.card.capabilities.pushNotifications {
            return serverPushNotificationsUnsupportedError(operation);
        }
    }

    private isolated function checkInlinePushConfig(SendMessageRequest request, string operation) returns Error? {
        if request?.configuration?.taskPushNotificationConfig is TaskPushNotificationConfig
                && !self.binding.isDefined("handleCreateTaskPushNotificationConfig") {
            return serverPushNotificationsUnsupportedError(operation);
        }
    }

    # A card with its JSON-RPC interface URL filled in, as for the REST wire.
    #
    # + card - The card, as derived
    # + req - The request it is served in response to
    # + return - A copy with a usable interface URL
    private isolated function withInterfaceUrl(AgentCard card, http:Request req) returns AgentCard {
        string|http:HeaderNotFoundError host = req.getHeader("Host");
        string? publicUrl = self.publicUrl;
        if host !is string && publicUrl is () {
            return card;
        }
        string url = interfaceUrlFor(publicUrl, self.interfaceScheme, host is string ? host : "")
            + "/" + JSON_RPC_MOUNT_PATH;
        AgentCard|error served = card.toJson().cloneWithType(AgentCard);
        if served is error {
            return card;
        }
        foreach int i in 0 ..< served.supportedInterfaces.length() {
            if served.supportedInterfaces[i].protocolBinding == JSONRPC {
                served.supportedInterfaces[i].url = url;
            }
        }
        return served;
    }
}

# The `id` of a request object, or `null` when it has none or is not an object.
#
# + payload - The parsed request body
# + return - The id, as sent
isolated function requestIdOf(json payload) returns json {
    if payload is map<json> {
        json id = payload["id"];
        if id is string|int|decimal {
            return id;
        }
    }
    return ();
}

# Accepts the protobuf JSON field names (`task_id`, `history_length`) next to
# the lowerCamelCase ones, as the proto3 JSON mapping the specification uses
# does: some clients send the original names. Only the top level of `params`
# is renamed, so nothing inside a `metadata` map or a data part is touched.
#
# + params - The request's `params`
# + return - `params` with its top-level keys in lowerCamelCase
isolated function camelCaseKeys(json params) returns json {
    if params !is map<json> {
        return params;
    }
    map<json> renamed = {};
    foreach [string, json] [key, value] in params.entries() {
        renamed[camelCaseOf(key)] = value;
    }
    return renamed;
}

# A `status` filter naming no state is no filter. The @a2a-js/sdk sends
# `"status": "UNRECOGNIZED"` (the placeholder its generated enum uses for a
# value it was not given) with every ListTasks call, and the protobuf default
# is TASK_STATE_UNSPECIFIED; neither selects tasks.
#
# + params - The request's `params`
# + return - `params` without such a `status`
isolated function withoutUnsetStatus(json params) returns json {
    if params is map<json> {
        json status = params["status"];
        if status == "UNRECOGNIZED" || status == "TASK_STATE_UNSPECIFIED" || status == 0 {
            map<json> kept = {...params};
            _ = kept.remove("status");
            return kept;
        }
    }
    return params;
}

isolated function camelCaseOf(string name) returns string {
    string[] words = re `_`.split(name);
    if words.length() == 1 {
        return name;
    }
    string camel = words[0];
    foreach string word in words.slice(1) {
        camel += word.length() == 0 ? "" : word.substring(0, 1).toUpperAscii() + word.substring(1);
    }
    return camel;
}

# Wire-encodes a result that may carry raw bytes (a message part in a task's
# history or an artifact), as base64, the way the other bindings send it.
#
# + value - The result record
# + return - The JSON to send, or a transport error if encoding failed
isolated function resultJson(anydata value) returns json|Error {
    json|error wired = encodeRawBytesForWire(value.toJson());
    if wired is error {
        return wrapTransportError(wired);
    }
    return wired;
}

# Decodes a request's `params` into its record, reporting a mismatch as the
# caller's mistake.
#
# + params - The `params` value
# + targetType - The request record's type
# + return - The decoded record, or an `invalidParams` error
isolated function decodeParams(json params, typedesc<anydata> targetType) returns anydata|Error {
    anydata|error decoded = params.fromJsonWithType(targetType);
    if decoded is error {
        return invalidParams(string `params did not match the operation's request: ${decoded.message()}`);
    }
    return decoded;
}

# The JSON-RPC error code for an A2A error: the code the error carries when it
# has one, otherwise the code its type has in specification section 5.4.
#
# + err - The error
# + return - The code
isolated function jsonRpcCodeOf(Error err) returns int {
    int? code = err.detail()?.code;
    if code is int {
        return code;
    }
    if err is TaskNotFoundError {
        return -32001;
    }
    if err is TaskNotCancelableError {
        return -32002;
    }
    if err is PushNotificationNotSupportedError {
        return -32003;
    }
    if err is UnsupportedOperationError {
        return -32004;
    }
    if err is ContentTypeNotSupportedError {
        return -32005;
    }
    if err is InvalidAgentResponseError {
        return -32006;
    }
    if err is ExtendedAgentCardNotConfiguredError {
        return -32007;
    }
    if err is ExtensionSupportRequiredError {
        return -32008;
    }
    if err is VersionNotSupportedError {
        return -32009;
    }
    return -32603;
}

# The `error` member of a JSON-RPC response for an A2A error.
#
# + err - The error
# + return - The error object: code, message, and the google.rpc details
isolated function rpcErrorObject(Error err) returns json {
    map<json> errorObject = {code: jsonRpcCodeOf(err), message: err.message()};
    json body = restErrorBody(err);
    if body is map<json> {
        json inner = body["error"];
        if inner is map<json> && inner["details"] is json[] {
            errorObject["data"] = inner["details"];
        }
    }
    return errorObject;
}

# A JSON-RPC error response for an A2A error, on a 200.
#
# + id - The request's id, or `null`
# + err - The error
# + return - The response
isolated function rpcFailure(json id, Error err) returns http:Response {
    http:Response response = new;
    response.setJsonPayload({jsonrpc: JSON_RPC_VERSION, id, 'error: rpcErrorObject(err)});
    return response;
}

# A JSON-RPC error response for a failure that has no A2A error type.
#
# + id - The request's id, or `null`
# + code - The JSON-RPC code
# + message - The message
# + return - The response
isolated function rpcErrorResponse(json id, int code, string message) returns http:Response {
    http:Response response = new;
    response.setJsonPayload({jsonrpc: JSON_RPC_VERSION, id, 'error: {code, message}});
    return response;
}

# Frames a live event stream as SSE for the JSON-RPC wire: every event is a
# complete JSON-RPC response whose `result` is the event, and a failure is one
# whose `error` is the failure, after which the stream ends.
class JsonRpcSseFramingGenerator {
    private stream<StreamResponse, Error?> events;
    private final json id;
    private boolean closed = false;

    isolated function init(stream<StreamResponse, Error?> events, json id) {
        self.events = events;
        self.id = id;
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
            return {value: {comment: "keep-alive"}};
        }
        if chunk is Error {
            self.closed = true;
            return {value: {data: self.failure(chunk).toJsonString()}};
        }
        json|error envelope = wireEnvelopeFor(chunk.value);
        if envelope is error {
            self.closed = true;
            return {value: {data: self.failure(wrapTransportError(envelope)).toJsonString()}};
        }
        return {value: {data: {jsonrpc: JSON_RPC_VERSION, id: self.id, result: envelope}.toJsonString()}};
    }

    private isolated function failure(Error err) returns json => {
        jsonrpc: JSON_RPC_VERSION,
        id: self.id,
        'error: rpcErrorObject(err)
    };

    # Consumer-side close, forwarded to the event source so a disconnected
    # client does not leave its subscription registered.
    #
    # + return - Always `()`
    public isolated function close() returns error? {
        return self.events.close();
    }
}
