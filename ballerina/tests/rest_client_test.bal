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

// RestClient: the transport-specific client for the HTTP+JSON binding.
//
// As with jsonrpc_client_test.bal, these exercise the class directly.
// What is distinctive about this binding is the marshaling — an operation
// becomes a method plus a templated path rather than an envelope — so the
// path/method assertions carry most of the weight here.

import ballerina/test;

@test:Config {}
function testRestClientConstructsFromUrl() returns error? {
    setNextRestResponse({task: defaultTaskJson()});
    RestClient c = check new (getServerBaseUrl());
    Task|Message result = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task, "a RestClient built from a URL should resolve the card and reach the mock");
}

@test:Config {}
function testRestClientConnectionFailureWrapsAsA2AInternalError() {
    // Constructing from a bare URL resolves the AgentCard first (see
    // resolveAgentCard/fetchAgentCardBody, client.bal), so an unreachable
    // host fails right here rather than at a later remote call.
    RestClient|error result = new ("http://localhost:1");
    test:assertTrue(result is InternalError,
            "a real connection failure should surface as a typed InternalError, not a bare error");
}

@test:Config {}
function testRestClientConstructsFromAgentCard() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    setNextRestResponse({task: defaultTaskJson()});
    RestClient c = check new (card);
    Task|Message result = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task);
}

@test:Config {}
function testRestClientRejectsCardWithoutRestInterface() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc-only.example", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    RestClient|error result = new (card);
    test:assertTrue(result is error,
            "a card declaring no HTTP+JSON interface must fail construction");
}

// v0.3 defines a REST binding, but this library does not implement it —
// v0.3 method names have no meaning as REST paths — so this must fail at
// construction rather than sending v0.3 method names down REST paths.
@test:Config {}
function testRestClientRejectsV03Card() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "0.3"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    RestClient|error result = new (card);
    test:assertTrue(result is VersionNotSupportedError,
            "a card resolving to v0.3 must be rejected with a typed error, since this library implements v0.3 over JSON-RPC only");
}

// The defining behaviour of this binding: each operation maps onto an HTTP
// method and a templated path, rather than a method name in a body.
@test:Config {}
function testRestClientMapsOperationsToMethodAndPath() returns error? {
    RestClient c = check new (getServerBaseUrl());

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-123"});
    var req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-123");

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->cancelTask({id: "task-123"});
    req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-123:cancel");

    setNextRestResponse({task: defaultTaskJson()});
    Task|Message _ = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/message:send");

    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0});
    ListTasksResponse _ = check c->listTasks();
    req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks");

    setNextRestResponse({url: "https://hook.example", taskId: "task-1"});
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({url: "https://hook.example", taskId: "task-1"});
    req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs");

    setNextRestResponse({url: "https://hook.example", taskId: "task-1"});
    TaskPushNotificationConfig _ = check c->getTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs/cfg-1");

    setNextRestResponse({}, hasResponseBody = false);
    check c->deleteTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    req = getLastRestRequest();
    test:assertEquals(req.method, "DELETE");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs/cfg-1");
}

// A tenant becomes a path prefix on this binding, not just a body field.
@test:Config {}
function testRestClientPrefixesPathWithTenant() returns error? {
    RestClient c = check new (getServerBaseUrl(), tenant = "acme-corp");
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/acme-corp/tasks/task-1");
}

// The A2A spec's REST binding requires application/a2a+json, not plain
// application/json (spec §11) — this is what the Client must send by
// default, before any server has ever rejected it.
@test:Config {}
function testRestClientSendsSpecContentTypeByDefault() returns error? {
    RestClient c = check new (getServerBaseUrl());
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestHeaders()["content-type"], "application/a2a+json");
}

// Some real, currently-released servers haven't caught up to the spec yet
// — e.g. a2a-java-sdk-reference-rest:1.1.0.Final rejects application/a2a+json
// outright with a 415 (confirmed by decompiling its route registration).
// The Client must transparently retry with the legacy application/json
// rather than surfacing the 415 to the caller.
@test:Config {}
function testRestClientNegotiatesLegacyContentTypeOn415() returns error? {
    RestClient c = check new (getServerBaseUrl());
    // setNextRestResponse replaces the whole mock script record, so it
    // must be called before setRestRejectContentType, not after -- same
    // ordering already required by setRestRejectMethod's own callers.
    setNextRestResponse(defaultTaskJson());
    setRestRejectContentType("application/a2a+json", 415);
    Task result = check c->getTask({id: "task-1"});
    test:assertEquals(result.id, "task-1", "the retry with application/json should succeed transparently");
    test:assertEquals(getLastRestHeaders()["content-type"], "application/json",
            "the request that actually succeeded should be the application/json retry");
}

// Once a 415 has taught this Client instance that its server needs the
// legacy content type, every later call should go straight there — not
// pay a 415 round trip on every single request forever.
@test:Config {}
function testRestClientRemembersNegotiatedContentTypeAcrossCalls() returns error? {
    RestClient c = check new (getServerBaseUrl());
    setNextRestResponse(defaultTaskJson());
    setRestRejectContentType("application/a2a+json", 415);
    Task _ = check c->getTask({id: "task-1"});

    // No rejection scripted this time — if the Client still tried
    // application/a2a+json first, this call would still succeed (nothing
    // is rejecting it), so the only way to prove it remembered is to
    // check which Content-Type this second, unscripted request actually
    // carried.
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestHeaders()["content-type"], "application/json",
            "a Client that already learned its server needs application/json should send it immediately, not retry into it again");
}

// REST cannot distinguish A2A errors by HTTP status alone — seven map onto
// 400 — so the ErrorInfo reason field carries the discrimination.
@test:Config {}
function testRestClientMapsErrorInfoReasonToTypedError() returns error? {
    RestClient c = check new (getServerBaseUrl());
    setNextRestResponse({
        'error: {
            code: 404,
            message: "Task not found",
            details: [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "TASK_NOT_FOUND"}]
        }
    }, statusCode = 404);
    Task|error result = c->getTask({id: "missing"});
    test:assertTrue(result is TaskNotFoundError,
            "the REST binding must discriminate A2A errors via ErrorInfo.reason");
}

@test:Config {}
function testRestClientStreams() returns error? {
    RestClient c = check new (getServerBaseUrl());
    setNextRestSseResponse([
        {data: string `{"task":{"id":"task-s1","status":{"state":"TASK_STATE_SUBMITTED"}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-s1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}`}
    ]);
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    int count = 0;
    check from StreamResponse _ in s
        do {
            count += 1;
        };
    test:assertEquals(count, 2, "both scripted events should be delivered");
}

@test:Config {}
function testRestClientSatisfiesClientMethods() returns error? {
    setNextRestResponse({task: defaultTaskJson()});
    ClientMethods c = check new RestClient(getServerBaseUrl());
    Task|Message result = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task, "a RestClient must be usable through the ClientMethods shape");
}
