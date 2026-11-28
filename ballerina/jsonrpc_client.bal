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


// The JSON-RPC transport binding of the client.
//
// Every operation is one POST of a JSON-RPC 2.0 envelope to the card's JSONRPC interface, naming the operation in
// `method`; the operation's own parameters travel in `params` as the JSON the specification's proto3 mapping gives
// them. Those are the same JSON values the HTTP+JSON binding puts in a body or a query string, so the request
// builders and result decoders in rest_client.bal are shared; only the envelope, the error object, and the framing of
// the two streaming operations are specific to this binding. The HTTP-level rules (the version header, credentials,
// extensions, authentication challenges) are the same as for HTTP+JSON.

import ballerina/http;
import ballerina/uuid;

# The JSON-RPC protocol version every envelope carries.
const JSON_RPC_ENVELOPE_VERSION = "2.0";

# The media type of a JSON-RPC request and of a unary response to it.
const CONTENT_TYPE_JSON_RPC = "application/json";

# Checks what every JSON-RPC 2.0 response shares: the version marker, and that the response answers with a `result`
# or an `error` but not both.
#
# + envelope - The response, or one event of a stream of them
# + what - What the envelope is, for the error message
# + return - An InvalidAgentResponseError when the envelope is not a well-formed JSON-RPC 2.0 response
isolated function checkEnvelope(map<json> envelope, string what) returns Error? {
    if envelope["jsonrpc"] != JSON_RPC_ENVELOPE_VERSION {
        return invalidAgentResponse(string `${what} does not declare jsonrpc "${JSON_RPC_ENVELOPE_VERSION}"`);
    }
    if envelope["error"] is map<json> && envelope.hasKey("result") {
        return invalidAgentResponse(string `${what} carries both a result and an error`);
    }
}

# Reads the `result` of a JSON-RPC response, or maps its `error` to a typed
# Error.
#
# + payload - The response body, parsed
# + id - The id the request carried, which a result must echo
# + return - The `result`, or the typed Error the response carried or that its shape warrants
isolated function readJsonRpcResponse(json payload, string id) returns json|Error {
    if payload !is map<json> {
        return invalidAgentResponse("JSON-RPC response is not an object");
    }
    check checkEnvelope(payload, "JSON-RPC response");
    json errorMember = payload["error"];
    if errorMember is map<json> {
        return jsonRpcErrorOf(errorMember);
    }
    if !payload.hasKey("result") {
        return invalidAgentResponse("JSON-RPC response carries neither a result nor an error");
    }
    json echoed = payload["id"];
    if echoed != id {
        return invalidAgentResponse(string `JSON-RPC response answers request ${echoed.toString()}, not ${id}`);
    }
    return payload["result"];
}

# The typed Error an `error` object stands for.
#
# + errorObject - The `error` member of a JSON-RPC response
# + return - The Error, an InvalidAgentResponseError when the object has no integer `code`
isolated function jsonRpcErrorOf(map<json> errorObject) returns Error {
    json code = errorObject["code"];
    json message = errorObject["message"];
    if code !is int {
        return invalidAgentResponse("JSON-RPC error object has no integer `code`");
    }
    return toA2AErrorFromJsonRpc(code, message is string ? message : string `JSON-RPC error ${code}`,
            errorObject["data"]);
}

# Unwraps one event of a JSON-RPC stream: the `result` that holds the
# StreamResponse, or the Error an `error` member stands for.
#
# A result must echo the id of the request that opened the stream, as a unary result does. An `error` is not held to
# it, because a server that could not tell which request failed answers with a null id.
#
# + envelope - The event's `data`, parsed
# + id - The id the request that opened the stream carried
# + return - The StreamResponse JSON, or the typed Error that ends the stream
isolated function unwrapJsonRpcEvent(json envelope, string id) returns json|Error {
    if envelope !is map<json> {
        return invalidAgentResponse("JSON-RPC stream event is not an object");
    }
    check checkEnvelope(envelope, "JSON-RPC stream event");
    json errorMember = envelope["error"];
    if errorMember is map<json> {
        return jsonRpcErrorOf(errorMember);
    }
    if !envelope.hasKey("result") {
        return invalidAgentResponse("JSON-RPC stream event carries neither a result nor an error");
    }
    json echoed = envelope["id"];
    if echoed != id {
        return invalidAgentResponse(string `JSON-RPC stream event answers request ${echoed.toString()}, not ${id}`);
    }
    return envelope["result"];
}

# An A2A protocol client for a remote agent, over the JSON-RPC binding.
#
# Give it the agent's base URL, or an `a2a:AgentCard` already resolved via
# `a2a:resolveAgentCard`. It resolves the card, requires it to declare a
# JSON-RPC interface, and speaks A2A v1.0 to it, so a card declaring only
# HTTP+JSON or gRPC, or a 0.x protocol version, is rejected at construction
# rather than at the first call. Use `a2a:Client` to have the binding chosen
# from the card.
#
# ```ballerina
# a2a:JsonRpcClient agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage({
#     message: {messageId: "m1", role: a2a:ROLE_USER, parts: [{text: "Plan a trip to Kandy"}]}
# });
# ```
#
# A client is cheap to construct and needs no teardown; prefer one long-lived
# client per agent. Each method's `+ return` names the `a2a:Error` subtype a
# protocol failure produces; a transport or decode failure comes back as
# `a2a:InternalError`.
public isolated client class JsonRpcClient {
    *ClientOperations;

    private final http:Client httpClient;
    private final map<string> & readonly defaultHeaders;
    # Supplies credentials by security-scheme name, if the caller opted in.
    private final CredentialProvider? credentials;
    # The card as resolved at construction, kept immutable for credential
    # resolution, as in `a2a:RestClient`.
    private final AgentCard & readonly authCard;
    private final string? tenant;
    private final string[] & readonly requestedExtensions;
    private final int maxReconnectAttempts;
    # The most recent AgentCard this client knows about; replaced by the
    # extended card once getExtendedAgentCard fetches one.
    private AgentCard? agentCard;

    # Creates a JSON-RPC client pointed at a remote A2A agent.
    #
    # + agent - The agent's base URL, or an AgentCard already resolved via
    #           `a2a:resolveAgentCard`
    # + config - Client configuration; see `a2a:ClientConfiguration` for the
    #            individual fields, passed as named arguments
    # + return - A typed Error: from resolveAgentCard, when the card declares
    #            no JSON-RPC interface, a VersionNotSupportedError if the card
    #            resolves to A2A v0.3, or an InternalError if the http:Client
    #            cannot be created, including when the initial OAuth2 token
    #            cannot be obtained
    public isolated function init(AgentCard|string agent, *ClientConfiguration config) returns Error? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, config.headers, clientConfig = config.clientConfig)
            : agent;
        string serviceUrl = check primaryUrl(card, JSONRPC);
        string? effectiveTenant = config.tenant;
        if effectiveTenant is () {
            AgentInterface|error iface = selectV1Interface(card, JSONRPC);
            if iface is AgentInterface {
                effectiveTenant = iface?.tenant;
            }
        }
        check requireV1Interface(card, JSONRPC);
        // A mapping-constructor spread copies the configuration, so the caller's own is never changed in place.
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

    # + accept - The media type the response is asked for
    # + return - The headers to send with the request
    private isolated function buildHeaders(string accept) returns map<string> {
        map<string> headers = {
            [A2A_VERSION_HEADER]: A2A_VERSION,
            [CONTENT_TYPE_HEADER]: CONTENT_TYPE_JSON_RPC,
            "Accept": accept
        };
        // Card-resolved credentials first, so an explicit `headers` entry still wins.
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

    # Posts one JSON-RPC request.
    #
    # + method - The operation, such as `SendMessage`
    # + params - The operation's parameters, tenant included
    # + id - The request's id
    # + accept - The media type the response is asked for
    # + return - The raw HTTP response, or a transport-level error
    private isolated function post(string method, map<json> params, string id, string accept)
            returns http:Response|Error {
        json envelope = {jsonrpc: JSON_RPC_ENVELOPE_VERSION, id, method, params};
        http:Response|error response = self.httpClient->post("", envelope, self.buildHeaders(accept));
        if response is error {
            return wrapTransportError(response);
        }
        return response;
    }

    # An HTTP error, mapped as the HTTP+JSON binding maps it: authentication and
    # authorization failures are the only errors the JSON-RPC wire reports
    # outside the envelope.
    #
    # + response - A response whose status is not 2xx
    # + return - The typed Error
    private isolated function httpFailure(http:Response response) returns Error {
        json|error body = response.getJsonPayload();
        if body is map<json> && body["error"] is map<json> && body.hasKey("jsonrpc") {
            // An error envelope is read like any other response, so a malformed one is not mapped to a typed error.
            Error? malformed = checkEnvelope(body, "JSON-RPC error response");
            if malformed is Error {
                return malformed;
            }
            return jsonRpcErrorOf(<map<json>>body["error"]);
        }
        return toA2AErrorFromRest(response.statusCode, body is json ? body : (), challengesOf(response));
    }

    # Performs one unary call and returns its unwrapped `result`.
    #
    # + method - The operation, such as `GetTask`
    # + params - The operation's parameters
    # + return - The `result`, or a typed Error
    private isolated function rpcCall(string method, map<json> params) returns json|Error {
        string id = uuid:createType4AsString();
        http:Response response = check self.post(method, params, id, CONTENT_TYPE_JSON_RPC);
        if response.statusCode < 200 || response.statusCode >= 300 {
            return self.httpFailure(response);
        }
        json|error payload = response.getJsonPayload();
        if payload is error {
            return invalidAgentResponse(
                    string `${method} returned a 2xx response whose body could not be parsed as JSON: `
                        + payload.message());
        }
        return readJsonRpcResponse(payload, id);
    }

    # Opens a streaming call: the response is a stream of JSON-RPC responses
    # when the operation started, or an ordinary JSON-RPC response (an error)
    # when it did not.
    #
    # + method - `SendStreamingMessage` or `SubscribeToTask`
    # + params - The operation's parameters
    # + return - The events, or a typed Error
    private isolated function openEventStream(string method, map<json> params)
            returns stream<StreamResponse, Error?>|Error {
        string id = uuid:createType4AsString();
        http:Response response = check self.post(method, params, id, "text/event-stream");
        if response.statusCode < 200 || response.statusCode >= 300 {
            return self.httpFailure(response);
        }
        if response.getContentType().startsWith("text/event-stream") {
            return readSseStream(response, jsonRpcId = id);
        }
        json|error payload = response.getJsonPayload();
        if payload is error {
            return invalidAgentResponse(
                    string `${method} returned neither an event stream nor JSON: ${payload.message()}`);
        }
        json|Error result = readJsonRpcResponse(payload, id);
        if result is Error {
            return result;
        }
        return invalidAgentResponse(string `${method} returned a single result where an event stream was expected`);
    }

    # Opens the raw, unwrapped subscribeToTask stream, which reconnection
    # resubscribes through, as in `a2a:RestClient`.
    #
    # + taskId - The task to subscribe to
    # + tenant - Optional per-call tenant override
    # + return - A stream of StreamResponse values, or an error
    isolated function openTaskSubscriptionStream(string taskId, string? tenant = ())
            returns stream<StreamResponse, Error?>|Error {
        return self.openEventStream("SubscribeToTask", applyTenant({"id": taskId}, tenant ?: self.tenant));
    }

    private isolated function sendMessageUnary(Message message, SendMessageConfiguration? config, string? tenant,
            map<json>? metadata) returns Task|Message|Error {
        map<json> params = check buildSendMessageBody(message, config, metadata, tenant ?: self.tenant);
        json result = check self.rpcCall("SendMessage", params);
        return decodeSendMessageResult(result);
    }

    # Sends a message to the remote agent.
    #
    # + request - The message and its send options
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error {
        return self.sendMessageUnary(request.message, request?.configuration, request?.tenant, request?.metadata);
    }

    # Sends a message and receives updates as they happen.
    #
    # + request - The message and its send options
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendStreamingMessage(SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        boolean denied;
        lock {
            denied = cardDeniesStreaming(self.agentCard);
        }
        if denied {
            // One unary call instead of a streaming connection the agent would refuse; see singleEventStream.
            Task|Message result = check self.sendMessageUnary(
                    request.message, request?.configuration, request?.tenant, request?.metadata);
            return singleEventStream(result);
        }
        string? effectiveTenant = request?.tenant ?: self.tenant;
        map<json> params = check buildSendMessageBody(
                request.message, request?.configuration, request?.metadata, effectiveTenant);
        stream<StreamResponse, Error?> rawStream = check self.openEventStream("SendStreamingMessage", params);
        return wrapReconnecting(rawStream, self, self.maxReconnectAttempts, effectiveTenant);
    }

    # Retrieves the current state of a task.
    #
    # + request - The task identifier, and optionally how much history to include
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(GetTaskRequest request) returns Task|Error {
        map<json> params = {"id": request.id};
        int? historyLength = request?.historyLength;
        if historyLength is int {
            params["historyLength"] = historyLength;
        }
        json result = check self.rpcCall("GetTask", applyTenant(params, request?.tenant ?: self.tenant));
        return decodeTaskResult(result);
    }

    # Requests cancellation of an in-progress task.
    #
    # + request - The task identifier, and any additional context for the agent
    # + return - The updated Task, or an error
    isolated remote function cancelTask(CancelTaskRequest request) returns Task|Error {
        map<json> params = {"id": request.id};
        map<json>? metadata = request?.metadata;
        if metadata is map<json> {
            params["metadata"] = metadata;
        }
        json result = check self.rpcCall("CancelTask", applyTenant(params, request?.tenant ?: self.tenant));
        return decodeTaskResult(result);
    }

    # Opens a stream on an existing task.
    #
    # + request - The task identifier
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        boolean denied;
        lock {
            denied = cardDeniesStreaming(self.agentCard);
        }
        if denied {
            // Subscribing to a task already in flight has no unary equivalent to fall back to.
            return streamingUnsupportedError("subscribeToTask");
        }
        string? tenant = request?.tenant;
        stream<StreamResponse, Error?> rawStream = check self.openTaskSubscriptionStream(request.id, tenant);
        if self.maxReconnectAttempts <= 0 {
            return rawStream;
        }
        stream<StreamResponse, Error?> wrapped = new (new ReconnectingStreamGenerator(
                rawStream, self, request.id, self.maxReconnectAttempts, tenant = tenant));
        return wrapped;
    }

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + request - Optional filter and pagination parameters; every field is
    #             optional, so this defaults to listing with the server's
    #             own defaults
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(ListTasksRequest request = {}) returns ListTasksResponse|Error {
        map<json> params = {};
        string? contextId = request?.contextId;
        if contextId is string {
            params["contextId"] = contextId;
        }
        TaskState? status = request?.status;
        if status is TaskState {
            params["status"] = status;
        }
        int? pageSize = request?.pageSize;
        if pageSize is int {
            params["pageSize"] = pageSize;
        }
        string? pageToken = request?.pageToken;
        if pageToken is string {
            params["pageToken"] = pageToken;
        }
        int? historyLength = request?.historyLength;
        if historyLength is int {
            params["historyLength"] = historyLength;
        }
        string? statusTimestampAfter = request?.statusTimestampAfter;
        if statusTimestampAfter is string {
            params["statusTimestampAfter"] = statusTimestampAfter;
        }
        boolean? includeArtifacts = request?.includeArtifacts;
        if includeArtifacts is boolean {
            params["includeArtifacts"] = includeArtifacts;
        }
        json result = check self.rpcCall("ListTasks", applyTenant(params, request?.tenant ?: self.tenant));
        return decodeListTasksResponse(result);
    }

    # Registers a webhook to receive updates for a task.
    #
    # Takes the configuration itself rather than a request wrapper: the
    # specification's CreateTaskPushNotificationConfig RPC is the one
    # operation with no dedicated request message.
    #
    # + request - The webhook configuration; its taskId identifies the task
    # + return - The created config as the server persisted it, or an error
    isolated remote function createTaskPushNotificationConfig(TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        check self.requirePushNotifications("createTaskPushNotificationConfig");
        map<json>|error params = request.toJson().ensureType();
        if params is error {
            return wrapTransportError(params);
        }
        json result = check self.rpcCall("CreateTaskPushNotificationConfig",
                applyTenant(params, request?.tenant ?: self.tenant));
        return decodeTaskPushNotificationConfig(result);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + request - The parent task id and the config's own id
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request)
            returns TaskPushNotificationConfig|Error {
        check self.requirePushNotifications("getTaskPushNotificationConfig");
        json result = check self.rpcCall("GetTaskPushNotificationConfig",
                applyTenant({"taskId": request.taskId, "id": request.id}, request?.tenant ?: self.tenant));
        return decodeTaskPushNotificationConfig(result);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + request - The parent task id, and optional pagination parameters
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request)
            returns ListTaskPushNotificationConfigsResponse|Error {
        check self.requirePushNotifications("listTaskPushNotificationConfigs");
        map<json> params = {"taskId": request.taskId};
        int? pageSize = request?.pageSize;
        if pageSize is int {
            params["pageSize"] = pageSize;
        }
        string? pageToken = request?.pageToken;
        if pageToken is string {
            params["pageToken"] = pageToken;
        }
        json result = check self.rpcCall("ListTaskPushNotificationConfigs",
                applyTenant(params, request?.tenant ?: self.tenant));
        return decodeListTaskPushNotificationConfigsResponse(result);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # + request - The parent task id and the config's own id
    # + return - Nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request)
            returns Error? {
        check self.requirePushNotifications("deleteTaskPushNotificationConfig");
        json _ = check self.rpcCall("DeleteTaskPushNotificationConfig",
                applyTenant({"taskId": request.taskId, "id": request.id}, request?.tenant ?: self.tenant));
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + request - Optional routing parameters; every field is optional, so
    #             this defaults to an empty request
    # + return - The extended AgentCard, or an error
    isolated remote function getExtendedAgentCard(GetExtendedAgentCardRequest request = {}) returns AgentCard|Error {
        lock {
            // Specification section 3.3.4: when the held card says the agent does not support extended cards, this
            // MUST fail rather than hand back the public card the caller already had. With no card held the request
            // goes out, and the agent decides.
            AgentCard? held = self.agentCard;
            if held is AgentCard && !held.capabilities.extendedAgentCard {
                return extendedCardUnsupportedError();
            }
        }
        json result = check self.rpcCall("GetExtendedAgentCard", applyTenant({}, request?.tenant ?: self.tenant));
        AgentCard fetched = check parseAgentCardBody(result);
        lock {
            self.agentCard = fetched.clone();
        }
        return fetched;
    }

    private isolated function requirePushNotifications(string operation) returns Error? {
        boolean denied;
        lock {
            denied = cardDeniesPushNotifications(self.agentCard);
        }
        if denied {
            return pushNotificationsUnsupportedError(operation);
        }
    }
}
