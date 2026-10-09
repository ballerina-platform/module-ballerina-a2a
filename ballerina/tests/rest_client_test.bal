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

// HttpClient: the transport-specific client for the HTTP+JSON binding.
//
// As with jsonrpc_client_test.bal, these exercise the class directly.
// What is distinctive about this binding is the marshaling — an operation
// becomes a method plus a templated path rather than an envelope — so the
// path/method assertions carry most of the weight here.

import ballerina/test;

@test:Config {}
function testRestClientConstructsFromUrl() returns error? {
    setNextRestResponse({task: defaultTaskJson()});
    HttpClient c = check new (getServerBaseUrl());
    Task|Message result = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task, "a HttpClient built from a URL should resolve the card and reach the mock");
}

@test:Config {}
function testRestClientConnectionFailureWrapsAsA2AInternalError() {
    // Constructing from a bare URL resolves the AgentCard first (see
    // resolveAgentCard/fetchAgentCardBody, discovery.bal), so an unreachable
    // host fails right here rather than at a later remote call.
    HttpClient|error result = new ("http://localhost:1");
    test:assertTrue(result is InternalError,
            "a real connection failure should surface as a typed InternalError, not a bare error");
}

@test:Config {}
function testRestClientConstructsFromAgentCard() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    setNextRestResponse({task: defaultTaskJson()});
    HttpClient c = check new (card);
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
    HttpClient|error result = new (card);
    test:assertTrue(result is error,
            "a card declaring no HTTP+JSON interface must fail construction");
}

// Finding 21: a card whose interface url ends in "/" (a real @a2a-js/sdk
// agent advertises exactly this for a root-mounted deployment) used to
// make the client build "//message:send" -- primaryUrl's own trailing
// slash, joined with http:Client's leading one on every path.
@test:Config {}
function testRestClientStripsTrailingSlashFromInterfaceUrl() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: getServerBaseUrl() + "/", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    setNextRestResponse({task: defaultTaskJson()});
    HttpClient c = check new (card);
    Task|Message result = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task);
    test:assertEquals(getLastRestRequest().path, "/message:send",
            "a trailing slash on the card's interface url must not double up with the path's own leading slash");
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
    HttpClient|error result = new (card);
    test:assertTrue(result is VersionNotSupportedError,
            "a card resolving to v0.3 must be rejected with a typed error, since this library implements v0.3 over JSON-RPC only");
}

// The defining behaviour of this binding: each operation maps onto an HTTP
// method and a templated path, rather than a method name in a body.
@test:Config {}
function testRestClientMapsOperationsToMethodAndPath() returns error? {
    HttpClient c = check new (getServerBaseUrl());

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

// Finding 24: a server whose `tasks` field defaults to a nil slice sends
// "tasks": null for an empty page -- confirmed against a real a2a-go
// server. `tasks` is a required, non-nullable Task[], so this used to fail
// with "ListTasks response did not match the expected shape".
@test:Config {}
function testRestClientTreatsNullTasksAsEmpty() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    setNextRestResponse({tasks: null, nextPageToken: "", pageSize: 0, totalSize: 0});
    ListTasksResponse result = check c->listTasks();
    test:assertEquals(result.tasks, []);
}

// Finding 33: ProtoJSON omits a field left at its default value
// (specification 5.7), so a real a2a-rs server's last page arrives with
// nextPageToken/pageSize/totalSize all absent -- confirmed against
// a2a-sdk 1.2.0 (next_page_token='') and @a2a-js/sdk (nextPageToken="").
// These were required, non-nullable fields, so this used to fail with
// "ListTasks response did not match the expected shape".
@test:Config {}
function testRestClientDefaultsOmittedListTasksFieldsToZeroValue() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    setNextRestResponse({tasks: [defaultTaskJson()]});
    ListTasksResponse result = check c->listTasks();
    test:assertEquals(result.nextPageToken, "");
    test:assertEquals(result.pageSize, 0);
    test:assertEquals(result.totalSize, 0);
    test:assertEquals(result.tasks.length(), 1);
}

// Same, for the canonical ProtoJSON rendering of an empty page: every
// field but `tasks` (itself normalized separately, finding 24) absent.
@test:Config {}
function testRestClientDecodesEmptyListTasksObject() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    setNextRestResponse({});
    ListTasksResponse result = check c->listTasks();
    test:assertEquals(result.tasks, []);
    test:assertEquals(result.nextPageToken, "");
    test:assertEquals(result.pageSize, 0);
    test:assertEquals(result.totalSize, 0);
}

// Finding 34: a 2xx whose body cannot be parsed as JSON at all (a
// truncated stream, an HTML error page) used to be silently read as
// "{}" -- for listTaskPushNotificationConfigs, whose response type is
// all-optional, that decoded as a successful *empty page*, hiding the
// failure entirely. It must now be a typed error, since the operation
// expects real content and the body has none it could parse.
@test:Config {}
function testRestClientRejectsUnparseableTwoxxBody() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    setNextRestResponseRaw("<html><body>Bad Gateway</body></html>", contentType = "text/html");
    ListTaskPushNotificationConfigsResponse|Error result = c->listTaskPushNotificationConfigs({taskId: "task-1"});
    test:assertTrue(result is InvalidAgentResponseError,
            "an unparseable 2xx body must not be silently read as an empty success");
}

// DeleteTaskPushNotificationConfig returns google.protobuf.Empty over the
// wire, so it alone tolerates an absent/unparseable body on a 2xx.
@test:Config {}
function testRestClientDeleteToleratesUnparseableEmptyBody() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    setNextRestResponseRaw("", contentType = "text/plain");
    Error? result = c->deleteTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    test:assertTrue(result is (), "DELETE's empty-body success must still be tolerated");
}

// Finding 35: ProtoJSON treats an explicit `null` on an optional field
// the same as the field being absent, and accepts an enum's integer
// ordinal as well as its name (specification 5.5). Both reference
// clients already read a conforming server this leniently.
@test:Config {}
function testRestClientAcceptsNullHistoryAndMetadataOnATask() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    json taskJson = defaultTaskJson();
    map<json> withNulls = <map<json>>taskJson.clone();
    withNulls["history"] = null;
    withNulls["metadata"] = null;
    setNextRestResponse(withNulls);
    Task result = check c->getTask({id: "task-123"});
    test:assertEquals(result.history, ());
    test:assertEquals(result.metadata, ());
}

@test:Config {}
function testRestClientAcceptsIntegerTaskState() returns error? {
    HttpClient c = check new (getServerBaseUrl());
    map<json> taskWithIntState = <map<json>>defaultTaskJson().clone();
    map<json> status = <map<json>>(<map<json>>taskWithIntState["status"]).clone();
    status["state"] = 3; // TASK_STATE_COMPLETED's ordinal
    taskWithIntState["status"] = status;
    setNextRestResponse(taskWithIntState);
    Task result = check c->getTask({id: "task-123"});
    test:assertEquals(result.status.state, TASK_STATE_COMPLETED);
}

// A tenant becomes a path prefix on this binding, not just a body field.
@test:Config {}
function testRestClientPrefixesPathWithTenant() returns error? {
    HttpClient c = check new (getServerBaseUrl(), tenant = "acme-corp");
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/acme-corp/tasks/task-1");
}

// The A2A spec's REST binding requires application/a2a+json, not plain
// application/json (spec §11) — this is what the Client must send by
// default, before any server has ever rejected it.
@test:Config {}
function testRestClientSendsSpecContentTypeByDefault() returns error? {
    HttpClient c = check new (getServerBaseUrl());
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
    HttpClient c = check new (getServerBaseUrl());
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
    HttpClient c = check new (getServerBaseUrl());
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
    HttpClient c = check new (getServerBaseUrl());
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
    HttpClient c = check new (getServerBaseUrl());
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
    Client c = check new HttpClient(getServerBaseUrl());
    Task|Message result = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task, "a HttpClient must be usable through the Client shape");
}
