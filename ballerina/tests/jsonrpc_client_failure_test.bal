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


// How the JSON-RPC client reads what a real agent does not send: HTTP failures, malformed responses, errors in an
// envelope and in the middle of a stream. A stub endpoint misbehaves on request, and the client is checked for the typed
// error it must give. What the request carried is read back from the stub too.

import ballerina/http;
import ballerina/test;

const int JSON_RPC_STUB_PORT = 19342;

listener http:Listener jsonRpcStubListener = new (JSON_RPC_STUB_PORT);

isolated function stubTask(string id, string state = "TASK_STATE_COMPLETED", json metadata = ()) returns json {
    map<json> task = {id, contextId: "stub-context", status: {state}};
    if metadata is map<json> {
        task["metadata"] = metadata;
    }
    return task;
}

isolated function stubEnvelope(json id, json result) returns json => {jsonrpc: "2.0", id, result};

isolated function stubErrorEnvelope(json id, json errorObject) returns json => {jsonrpc: "2.0", id, 'error: errorObject};

isolated function stubJson(json payload, int statusCode = 200) returns http:Response {
    http:Response response = new;
    response.statusCode = statusCode;
    response.setJsonPayload(payload);
    return response;
}

isolated function stubEvent(json id, json event) returns http:SseEvent => {data: stubEnvelope(id, event).toJsonString()};

service / on jsonRpcStubListener {
    resource function get \.well\-known/agent\-card\.json() returns json => stubCard().toJson();
}

service /rpc on jsonRpcStubListener {
    resource function post .(http:Request req) returns http:Response|stream<http:SseEvent, error?>|error {
        json body = check req.getJsonPayload();
        string method = (check body.method).toString();
        json id = check body.id;
        json params = check body.params;
        if method == "ListTasks" {
            return stubJson(stubEnvelope(id, {tasks: [stubTask("listed", metadata = params)], nextPageToken: "",
                pageSize: 1, totalSize: 1}));
        }
        if method == "CancelTask" {
            return stubJson(stubEnvelope(id, stubTask("cancelled", "TASK_STATE_CANCELED", metadata = params)));
        }
        if method == "CreateTaskPushNotificationConfig" {
            map<json> created = {taskId: check params.taskId, id: "cfg-1", url: check params.url};
            return stubJson(stubEnvelope(id, created));
        }
        if method == "GetTaskPushNotificationConfig" {
            return stubJson(stubEnvelope(id, {taskId: check params.taskId, id: check params.id,
                url: "https://example.com/hook"}));
        }
        if method == "DeleteTaskPushNotificationConfig" {
            return stubJson(stubEnvelope(id, ()));
        }
        if method == "ListTaskPushNotificationConfigs" {
            return stubJson(stubEnvelope(id, {configs: [], nextPageToken: ""}));
        }
        if method == "GetExtendedAgentCard" {
            AgentCard extended = stubCard();
            extended.name = "Extended Stub Agent";
            extended.capabilities.extendedAgentCard = true;
            return stubJson(stubEnvelope(id, extended.toJson()));
        }
        if method == "SubscribeToTask" {
            json done = {statusUpdate: {taskId: "s1", contextId: "stub-context", status: {state: "TASK_STATE_COMPLETED"}}};
            return [stubEvent(id, done)].toStream();
        }
        if method == "SendMessage" {
            return stubJson(stubEnvelope(id, {task: stubTask("blocking")}));
        }
        if method == "SendStreamingMessage" {
            string text = (check (<json[]>check params.message.parts)[0].text).toString();
            return stubStream(id, text);
        }
        string key = params is map<json> && params["id"] is string ? <string>params["id"] : "";
        match key {
            "unauthorized" => {
                http:Response denied = stubJson({"error": {"code": 401, "status": "UNAUTHENTICATED", "message": "no"}},
                        401);
                denied.setHeader("WWW-Authenticate", "Bearer realm=\"stub\"");
                return denied;
            }
            "forbidden" => {
                return stubJson({"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "no"}}, 403);
            }
            "http-rpc-error" => {
                return stubJson(stubErrorEnvelope(id, {code: -32001, message: "gone"}), 500);
            }
            "server-error" => {
                return stubJson({"oops": true}, 500);
            }
            "wrong-id" => {
                return stubJson(stubEnvelope("someone-else", stubTask("t")));
            }
            "no-result" => {
                return stubJson({jsonrpc: "2.0", id});
            }
            "not-json" => {
                http:Response page = new;
                page.setTextPayload("<html>gateway</html>", "text/html");
                return page;
            }
            "rpc-error" => {
                return stubJson(stubErrorEnvelope(id, {code: -32001, message: "no such task", data: [{
                    "@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "TASK_NOT_FOUND"}]}));
            }
            "rpc-internal" => {
                return stubJson(stubErrorEnvelope(id, {code: -32603, message: "internal"}));
            }
            "rpc-no-code" => {
                return stubJson(stubErrorEnvelope(id, {message: "no code"}));
            }
            "echo-request" => {
                map<json> seen = {
                    jsonrpc: check body.jsonrpc,
                    method,
                    params,
                    version: req.getHeader("A2A-Version") is string ? check req.getHeader("A2A-Version") : "",
                    contentType: req.getContentType(),
                    apiKey: req.getHeader("X-Api-Key") is string ? check req.getHeader("X-Api-Key") : "",
                    extensions: req.getHeader("A2A-Extensions") is string ? check req.getHeader("A2A-Extensions") : ""
                };
                return stubJson(stubEnvelope(id, stubTask("echo", metadata = seen)));
            }
        }
        return stubJson(stubEnvelope(id, stubTask(key)));
    }
}

isolated function stubStream(json id, string text) returns http:Response|stream<http:SseEvent, error?> {
    json working = {task: stubTask("s1", "TASK_STATE_WORKING")};
    json done = {statusUpdate: {taskId: "s1", contextId: "stub-context", status: {state: "TASK_STATE_COMPLETED"}}};
    match text {
        "stream-ok" => {
            return [stubEvent(id, working), stubEvent(id, done)].toStream();
        }
        "stream-error" => {
            return [stubEvent(id, working),
                {data: stubErrorEnvelope(id, {code: -32006, message: "the agent broke"}).toJsonString()}].toStream();
        }
        "stream-bad-json" => {
            return [stubEvent(id, working), {data: "this is not json"}].toStream();
        }
        "stream-no-result" => {
            return [stubEvent(id, working), {data: {jsonrpc: "2.0", id}.toJsonString()}].toStream();
        }
        "stream-wrong-id" => {
            return [stubEvent(id, working), stubEvent("someone-else", done)].toStream();
        }
        "stream-rejected" => {
            return stubJson(stubErrorEnvelope(id, {code: -32004, message: "no streaming here"}));
        }
        "stream-http-failure" => {
            return stubJson({"error": {"code": 401, "status": "UNAUTHENTICATED", "message": "no"}}, 401);
        }
        "stream-not-json" => {
            http:Response page = new;
            page.setTextPayload("<html>gateway</html>", "text/html");
            return page;
        }
        "stream-single" => {
            return stubJson(stubEnvelope(id, {task: stubTask("s1")}));
        }
    }
    return stubJson(stubErrorEnvelope(id, {code: -32603, message: "unscripted"}));
}

isolated function stubCard(AgentInterface[]? interfaces = ()) returns AgentCard => {
    name: "Stub Agent",
    description: "Misbehaves on request",
    version: "1.0.0",
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {streaming: true},
    supportedInterfaces: interfaces ?: [{
        url: string `http://localhost:${JSON_RPC_STUB_PORT}/rpc`,
        protocolBinding: "JSONRPC",
        protocolVersion: "1.0"
    }]
};

isolated function stubRpcClient(*ClientConfiguration config) returns JsonRpcClient|error =>
    new (stubCard(), clientConfig = config.clientConfig, headers = config.headers, tenant = config.tenant,
            requestedExtensions = config.requestedExtensions);

isolated function stubGet(string id, *ClientConfiguration config) returns Task|Error|error {
    JsonRpcClient c = check stubRpcClient(config);
    return c->getTask({id});
}

@test:Config {}
function testJsonRpcClientReadsAResult() returns error? {
    Task task = check stubGet("plain");
    test:assertEquals(task.id, "plain");
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testJsonRpcClientSendsTheEnvelopeAndTheHeaders() returns error? {
    JsonRpcClient c = check stubRpcClient(headers = {"X-Api-Key": "k-1"}, tenant = "acme",
            requestedExtensions = ["https://example.com/ext/a", "https://example.com/ext/b"]);
    Task task = check c->getTask({id: "echo-request", historyLength: 2});
    map<json> seen = <map<json>>task?.metadata;
    test:assertEquals(seen["jsonrpc"], "2.0");
    test:assertEquals(seen["method"], "GetTask");
    test:assertEquals(seen["params"], {id: "echo-request", historyLength: 2, tenant: "acme"});
    test:assertEquals(seen["version"], "1.0");
    test:assertEquals(seen["contentType"], "application/json");
    test:assertEquals(seen["apiKey"], "k-1");
    test:assertEquals(seen["extensions"], "https://example.com/ext/a,https://example.com/ext/b");
}

@test:Config {}
function testJsonRpcClientSendsTheCredentialTheCardCallsFor() returns error? {
    AgentCard card = stubCard();
    ApiKeySecurityScheme scheme = {name: "X-Api-Key", 'in: "header"};
    card.securitySchemes = {"key": scheme};
    card.securityRequirements = [{"key": []}];
    InMemoryCredentialStore store = new ({"key": "from-the-store"});
    JsonRpcClient c = check new (card, credentials = store);
    Task task = check c->getTask({id: "echo-request"});
    test:assertEquals((<map<json>>task?.metadata)["apiKey"], "from-the-store");
}

@test:Config {}
function testJsonRpcClientMapsAnAuthenticationFailure() returns error? {
    Task|Error|error result = stubGet("unauthorized");
    if result is AuthenticationError {
        test:assertEquals(result.detail().code, 401);
    } else {
        test:assertFail("a 401 must be a2a:AuthenticationError");
    }
}

@test:Config {}
function testJsonRpcClientMapsAnAuthorizationFailure() returns error? {
    test:assertTrue(stubGet("forbidden") is AuthorizationError);
}

@test:Config {}
function testJsonRpcClientMapsAnHttpFailureToInternalError() returns error? {
    Task|Error|error result = stubGet("server-error");
    test:assertTrue(result is InternalError, "a 500 with no A2A error is an internal error");
}

@test:Config {}
function testJsonRpcClientRejectsAResponseToAnotherRequest() returns error? {
    test:assertTrue(stubGet("wrong-id") is InvalidAgentResponseError);
}

@test:Config {}
function testJsonRpcClientRejectsAResponseWithNoResultAndNoError() returns error? {
    test:assertTrue(stubGet("no-result") is InvalidAgentResponseError);
}

@test:Config {}
function testJsonRpcClientRejectsABodyThatIsNotJson() returns error? {
    test:assertTrue(stubGet("not-json") is InvalidAgentResponseError);
}

@test:Config {}
function testJsonRpcClientMapsTheErrorObjectByItsCode() returns error? {
    Task|Error|error result = stubGet("rpc-error");
    if result is TaskNotFoundError {
        test:assertEquals(result.detail().code, -32001);
        test:assertEquals(result.message(), "no such task");
        test:assertTrue(result.detail()?.data is json[], "the agent's details are kept");
    } else {
        test:assertFail("-32001 must be a2a:TaskNotFoundError");
    }
    Task|Error|error internal = stubGet("rpc-internal");
    test:assertTrue(internal is InternalError && internal.detail().code == -32603);
    test:assertTrue(stubGet("rpc-no-code") is InvalidAgentResponseError, "an error object needs a code");
}

isolated function stubStreamOf(string text) returns stream<StreamResponse, Error?>|Error|error {
    JsonRpcClient c = check stubRpcClient();
    return c->sendStreamingMessage({message: {messageId: "m", role: ROLE_USER, parts: [{text}]}});
}

@test:Config {}
function testJsonRpcClientReadsTheEventsOfAStream() returns error? {
    stream<StreamResponse, Error?> events = check stubStreamOf("stream-ok");
    record {|StreamResponse value;|}? first = check events.next();
    test:assertTrue(first?.value is Task);
    record {|StreamResponse value;|}? second = check events.next();
    test:assertTrue(second?.value is TaskStatusUpdateEvent);
    test:assertTrue(check events.next() is (), "a completed task ends the stream");
}

@test:Config {}
function testJsonRpcClientEndsAStreamWithTheErrorItCarries() returns error? {
    stream<StreamResponse, Error?> events = check stubStreamOf("stream-error");
    test:assertTrue(check events.next() is record {|StreamResponse value;|});
    record {|StreamResponse value;|}|Error? failed = events.next();
    if failed is InvalidAgentResponseError {
        test:assertEquals(failed.message(), "the agent broke");
    } else {
        test:assertFail("an error object in a stream must end it with the typed error");
    }
    test:assertTrue(events.next() is (), "nothing follows the error");
}

// A result must answer the request that opened the stream, as a unary result must; an intermediary can splice in
// the event of another request.
@test:Config {}
function testJsonRpcClientRejectsAStreamEventThatAnswersAnotherRequest() returns error? {
    stream<StreamResponse, Error?> events = check stubStreamOf("stream-wrong-id");
    test:assertTrue(check events.next() is record {|StreamResponse value;|});
    record {|StreamResponse value;|}|Error? failed = events.next();
    test:assertTrue(failed is InvalidAgentResponseError, "an event for someone else's request must not be delivered");
    test:assertTrue(events.next() is (), "nothing follows the error");
}

// A response must declare JSON-RPC 2.0 and answer with a result or an error, not both; parsing as JSON does not
// make it one.
@test:Config {}
function testJsonRpcResponsesMustBeWellFormedEnvelopes() {
    json oldVersion = {jsonrpc: "1.0", id: "1", result: {a: 1}};
    json noVersion = {id: "1", result: {a: 1}};
    json both = {jsonrpc: "2.0", id: "1", result: {a: 1}, 'error: {code: -32603, message: "x"}};
    test:assertTrue(readJsonRpcResponse(oldVersion, "1") is InvalidAgentResponseError);
    test:assertTrue(readJsonRpcResponse(noVersion, "1") is InvalidAgentResponseError);
    test:assertTrue(readJsonRpcResponse(both, "1") is InvalidAgentResponseError);
    test:assertTrue(unwrapJsonRpcEvent(oldVersion, "1") is InvalidAgentResponseError);
    test:assertTrue(unwrapJsonRpcEvent(both, "1") is InvalidAgentResponseError);
    // A well-formed result, and an error with a null id, still read.
    test:assertEquals(readJsonRpcResponse({jsonrpc: "2.0", id: "1", result: {a: 1}}, "1"), {a: 1});
    test:assertTrue(readJsonRpcResponse({jsonrpc: "2.0", id: (), 'error: {code: -32700, message: "parse"}}, "1")
            is InternalError);
}

@test:Config {}
function testUnwrapJsonRpcEventChecksTheIdOfAResultButNotOfAnError() {
    test:assertTrue(unwrapJsonRpcEvent({jsonrpc: "2.0", id: "2", result: {}}, "1") is InvalidAgentResponseError);
    test:assertTrue(unwrapJsonRpcEvent({jsonrpc: "2.0", id: (), result: {}}, "1") is InvalidAgentResponseError);
    // A server that could not tell which request failed answers an error with a null id.
    test:assertTrue(unwrapJsonRpcEvent({jsonrpc: "2.0", id: (), 'error: {code: -32603, message: "x"}}, "1")
            is InternalError);
}

@test:Config {}
function testJsonRpcClientRejectsAStreamEventThatIsNotJson() returns error? {
    stream<StreamResponse, Error?> events = check stubStreamOf("stream-bad-json");
    test:assertTrue(check events.next() is record {|StreamResponse value;|});
    record {|StreamResponse value;|}|Error? failed = events.next();
    test:assertTrue(failed is InvalidAgentResponseError);
}

@test:Config {}
function testJsonRpcClientTypesAStreamTheAgentRefusedToOpen() returns error? {
    test:assertTrue(stubStreamOf("stream-rejected") is UnsupportedOperationError);
}

@test:Config {}
function testJsonRpcClientRejectsASingleResultWhereAStreamIsExpected() returns error? {
    test:assertTrue(stubStreamOf("stream-single") is InvalidAgentResponseError);
}

@test:Config {}
function testJsonRpcClientSendsOneBlockingCallWhenTheCardDeniesStreaming() returns error? {
    AgentCard card = stubCard();
    card.capabilities.streaming = false;
    JsonRpcClient c = check new (card);
    stream<StreamResponse, Error?> events = check c->sendStreamingMessage({
        message: {messageId: "m", role: ROLE_USER, parts: [{text: "echo-request"}]}
    });
    record {|StreamResponse value;|}? only = check events.next();
    test:assertTrue(only?.value is Task || only?.value is Message);
    test:assertTrue(check events.next() is (), "the reply is one event");
    stream<StreamResponse, Error?>|Error subscribed = c->subscribeToTask({id: "s1"});
    test:assertTrue(subscribed is UnsupportedOperationError, "a subscription has no blocking equivalent");
}

@test:Config {}
function testToA2AErrorFromJsonRpcGivesEveryCodeItsType() {
    test:assertTrue(toA2AErrorFromJsonRpc(-32001, "m") is TaskNotFoundError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32002, "m") is TaskNotCancelableError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32003, "m") is PushNotificationNotSupportedError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32004, "m") is UnsupportedOperationError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32005, "m") is ContentTypeNotSupportedError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32006, "m") is InvalidAgentResponseError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32007, "m") is ExtendedAgentCardNotConfiguredError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32008, "m") is ExtensionSupportRequiredError);
    test:assertTrue(toA2AErrorFromJsonRpc(-32009, "m") is VersionNotSupportedError);
    foreach int code in [-32700, -32600, -32601, -32602, -32603, 12345] {
        Error err = toA2AErrorFromJsonRpc(code, "m", {"detail": 1});
        test:assertTrue(err is InternalError, string `${code} is an internal error`);
        test:assertEquals(err.detail().code, code);
        test:assertEquals(err.detail()?.data, {"detail": 1});
    }
}

@test:Config {}
function testReadJsonRpcResponseHandlesEachShape() {
    test:assertEquals(readJsonRpcResponse({jsonrpc: "2.0", id: "1", result: {a: 1}}, "1"), {a: 1});
    test:assertTrue(readJsonRpcResponse({jsonrpc: "2.0", id: "2", result: {}}, "1") is InvalidAgentResponseError);
    test:assertTrue(readJsonRpcResponse([1], "1") is InvalidAgentResponseError);
    test:assertTrue(readJsonRpcResponse({jsonrpc: "2.0", id: "1"}, "1") is InvalidAgentResponseError);
    // An error object is read whatever the id says: a server that could not parse the request answers with a null id.
    test:assertTrue(readJsonRpcResponse({jsonrpc: "2.0", id: (), 'error: {code: -32700, message: "parse"}}, "1")
            is InternalError);
    test:assertEquals(unwrapJsonRpcEvent({jsonrpc: "2.0", id: "1", result: {task: {}}}, "1"), {task: {}});
    test:assertTrue(unwrapJsonRpcEvent("text", "1") is InvalidAgentResponseError);
}

@test:Config {}
function testJsonRpcClientReadsAnErrorEnvelopeOnAnHttpFailure() returns error? {
    Task|Error|error result = stubGet("http-rpc-error");
    test:assertTrue(result is TaskNotFoundError, "an error envelope wins over the status that carried it");
}

@test:Config {}
function testJsonRpcClientReportsAnAgentItCannotReach() returns error? {
    AgentCard card = stubCard([{url: "http://localhost:1/rpc", protocolBinding: "JSONRPC", protocolVersion: "1.0"}]);
    JsonRpcClient c = check new (card);
    Task|Error result = c->getTask({id: "t"});
    test:assertTrue(result is InternalError, "a connection failure is a typed transport error");
}

@test:Config {}
function testJsonRpcClientTypesAStreamTheAgentRefusedWithAnHttpStatus() returns error? {
    test:assertTrue(stubStreamOf("stream-http-failure") is AuthenticationError);
    test:assertTrue(stubStreamOf("stream-not-json") is InvalidAgentResponseError,
            "a 200 that is neither an event stream nor JSON");
}

@test:Config {}
function testJsonRpcClientSendsEveryListTasksFilter() returns error? {
    JsonRpcClient c = check stubRpcClient();
    ListTasksResponse page = check c->listTasks({
        contextId: "ctx",
        status: TASK_STATE_WORKING,
        pageSize: 5,
        pageToken: "next",
        historyLength: 3,
        statusTimestampAfter: "2026-01-01T00:00:00Z",
        includeArtifacts: true,
        tenant: "acme"
    });
    test:assertEquals(page.tasks.length(), 1);
    test:assertEquals(page.tasks[0]?.metadata, {
        contextId: "ctx",
        status: "TASK_STATE_WORKING",
        pageSize: 5,
        pageToken: "next",
        historyLength: 3,
        statusTimestampAfter: "2026-01-01T00:00:00Z",
        includeArtifacts: true,
        tenant: "acme"
    });
}

@test:Config {}
function testJsonRpcClientCancelsATaskWithItsMetadata() returns error? {
    JsonRpcClient c = check stubRpcClient();
    Task task = check c->cancelTask({id: "t-1", metadata: {"reason": "no longer needed"}});
    test:assertEquals(task.status.state, TASK_STATE_CANCELED);
    test:assertEquals(task?.metadata, {id: "t-1", metadata: {"reason": "no longer needed"}});
}

@test:Config {}
function testJsonRpcClientListsPushNotificationConfigsPageByPage() returns error? {
    AgentCard card = stubCard();
    card.capabilities.pushNotifications = true;
    JsonRpcClient c = check new (card);
    ListTaskPushNotificationConfigsResponse page = check c->listTaskPushNotificationConfigs({
        taskId: "t", pageSize: 2, pageToken: "next"
    });
    test:assertEquals((page.configs ?: []).length(), 0);
}

@test:Config {}
function testJsonRpcClientRefusesPushNotificationsTheCardDenies() returns error? {
    JsonRpcClient c = check stubRpcClient();
    TaskPushNotificationConfig|Error created = c->createTaskPushNotificationConfig({
        taskId: "t", url: "https://example.com/hook"
    });
    test:assertTrue(created is PushNotificationNotSupportedError);
    TaskPushNotificationConfig|Error fetched = c->getTaskPushNotificationConfig({taskId: "t", id: "c"});
    test:assertTrue(fetched is PushNotificationNotSupportedError);
    ListTaskPushNotificationConfigsResponse|Error listed = c->listTaskPushNotificationConfigs({taskId: "t"});
    test:assertTrue(listed is PushNotificationNotSupportedError);
    Error? deleted = c->deleteTaskPushNotificationConfig({taskId: "t", id: "c"});
    test:assertTrue(deleted is PushNotificationNotSupportedError);
}

@test:Config {}
function testJsonRpcClientReadsTheExtendedCard() returns error? {
    AgentCard card = stubCard();
    card.capabilities.extendedAgentCard = true;
    JsonRpcClient c = check new (card);
    AgentCard extended = check c->getExtendedAgentCard();
    test:assertEquals(extended.name, "Extended Stub Agent");
    AgentCard again = check c->getExtendedAgentCard({tenant: "acme"});
    test:assertEquals(again.name, "Extended Stub Agent");
}

@test:Config {}
function testJsonRpcClientReconnectsAreOnlyWrappedWhenAsked() returns error? {
    AgentCard card = stubCard();
    JsonRpcClient withReconnect = check new (card, maxReconnectAttempts = 2);
    stream<StreamResponse, Error?> opened = check withReconnect->sendStreamingMessage({
        message: {messageId: "m", role: ROLE_USER, parts: [{text: "stream-ok"}]}
    });
    record {|StreamResponse value;|}? firstEvent = check opened.next();
    record {|StreamResponse value;|}? secondEvent = check opened.next();
    record {|StreamResponse value;|}? afterEnd = check opened.next();
    test:assertTrue(firstEvent is record {|StreamResponse value;|} && secondEvent is record {|StreamResponse value;|}
            && afterEnd is ());

    stream<StreamResponse, Error?> subscribed = check withReconnect->subscribeToTask({id: "s1", tenant: "acme"});
    record {|StreamResponse value;|}? subscribedEvent = check subscribed.next();
    record {|StreamResponse value;|}? subscribedEnd = check subscribed.next();
    test:assertTrue(subscribedEvent is record {|StreamResponse value;|} && subscribedEnd is ());

    JsonRpcClient plain = check new (card);
    stream<StreamResponse, Error?> direct = check plain->subscribeToTask({id: "s1"});
    record {|StreamResponse value;|}? directEvent = check direct.next();
    test:assertTrue(directEvent is record {|StreamResponse value;|});
}

@test:Config {}
function testJsonRpcClientUsesItsDefaultsWhenTheCallerNamesNone() returns error? {
    JsonRpcClient c = check stubRpcClient();
    ListTasksResponse everything = check c->listTasks();
    test:assertEquals(everything.tasks[0]?.metadata, {}, "an empty filter sends no parameters");
    stream<StreamResponse, Error?> events = check c.openTaskSubscriptionStream("s1");
    record {|StreamResponse value;|}? first = check events.next();
    test:assertTrue(first is record {|StreamResponse value;|});
}
