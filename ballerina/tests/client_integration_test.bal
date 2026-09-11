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

// Whole-client integration: the common Client end to end.
//
// RestClient is tested directly in rest_client_test. What is only testable
// here is the layer above it: that Client requires the binding it can
// speak, and that each of its eleven delegations is wired to the operation
// it claims to be.

import ballerina/test;

// A card declaring exactly one interface, for pinning which binding Client
// selects. Points at whichever mock serves that binding.
//
isolated function cardForBinding(TransportBinding binding) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0",
    capabilities: {streaming: true, pushNotifications: true, extendedAgentCard: true},
    supportedInterfaces: [
        {
            url: getServerBaseUrl(),
            protocolBinding: binding,
            protocolVersion: "1.0"
        }
    ],
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"]
};

// ---- binding selection reaches the right transport --------------------

@test:Config {}
function testClientSelectsRestAndSpeaksIt() returns error? {
    Client c = check new (cardForBinding("HTTP+JSON"));
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1",
            "an HTTP+JSON card must produce a client that uses REST paths");
}

// ---- every delegation is wired to the operation it claims to be -------

// Client has eleven hand-written one-line delegations. A copy-paste slip -
// getTask forwarding to cancelTask, say - would compile, return the right
// type, and pass every per-binding test, because the concrete clients are
// all correct. Only asserting the method name each Client call actually
// puts on the wire catches it.
@test:Config {}
function testClientDelegatesEachOperationToItsOwnMethod() returns error? {
    Client c = check new (cardForBinding("HTTP+JSON"));

    setNextRestResponse({task: defaultTaskJson()});
    Task|Message _ = check c->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertEquals(getLastRestRequest().path, "/message:send");

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1");

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->cancelTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1:cancel");

    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0});
    ListTasksResponse _ = check c->listTasks();
    test:assertEquals(getLastRestRequest().path, "/tasks");

    setNextRestResponse({url: "https://hook.example", taskId: "task-1"});
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig(
            {url: "https://hook.example", taskId: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs");

    setNextRestResponse({url: "https://hook.example", taskId: "task-1"});
    TaskPushNotificationConfig _ = check c->getTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs/cfg-1");

    setNextRestResponse({configs: [], nextPageToken: ""});
    ListTaskPushNotificationConfigsResponse _ = check c->listTaskPushNotificationConfigs({taskId: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs");

    setNextRestResponse({});
    check c->deleteTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs/cfg-1");

    setNextRestResponse({name: "Extended", description: "d", version: "1.0.0", capabilities: {}, skills: [], supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}], defaultInputModes: ["text"], defaultOutputModes: ["text"]});
    AgentCard _ = check c->getExtendedAgentCard();
    test:assertEquals(getLastRestRequest().path, "/extendedAgentCard");
}

// The two streaming operations, which delegate a stream rather than a
// value and so cannot be covered by the unary sweep above.
@test:Config {}
function testClientDelegatesStreamingOperations() returns error? {
    Client c = check new (cardForBinding("HTTP+JSON"));

    setNextRestSseResponse([
        {data: taskJson("task-s1")},
        {data: statusUpdateJson("task-s1", "TASK_STATE_COMPLETED")}
    ]);
    stream<StreamResponse, error?> sent = check c->sendStreamingMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    int sentCount = 0;
    check from StreamResponse _ in sent
        do {
            sentCount += 1;
        };
    test:assertEquals(sentCount, 2);
    test:assertEquals(getLastRestRequest().path, "/message:stream");

    setNextRestSseResponse([
        {data: statusUpdateJson("task-s2", "TASK_STATE_COMPLETED")}
    ]);
    stream<StreamResponse, error?> subscribed = check c->subscribeToTask({id: "task-s2"});
    int subCount = 0;
    check from StreamResponse _ in subscribed
        do {
            subCount += 1;
        };
    test:assertEquals(subCount, 1);
    test:assertEquals(getLastRestRequest().path, "/tasks/task-s2:subscribe");
}

// ---- delegation carries arguments and state faithfully ---------------

// Arguments have to survive the hop. A delegation that dropped or reordered
// a parameter would still compile.
@test:Config {}
function testClientDelegationPassesArgumentsThrough() returns error? {
    Client c = check new (cardForBinding("HTTP+JSON"));

    // The REST binding spends its arguments on the path and query string
    // rather than a parameter object, so that is where a dropped argument
    // would show up.
    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-42", historyLength: 7, tenant: "per-call-tenant"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.path, "/per-call-tenant/tasks/task-42",
            "the task id and a per-call tenant override must both survive the delegation");
    test:assertEquals(req.queryParams["historyLength"], "7");

    setNextRestResponse({configs: [], nextPageToken: ""});
    ListTaskPushNotificationConfigsResponse _ = check c->listTaskPushNotificationConfigs({taskId: "task-1", pageSize: 5, pageToken: "cursor-abc"});
    req = getLastRestRequest();
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs");
    test:assertEquals(req.queryParams["pageSize"], "5");
    test:assertEquals(req.queryParams["pageToken"], "cursor-abc");
}

// The card handed to Client is passed straight to the delegate, so a
// construction from an already-resolved card must not fetch it again.
@test:Config {}
function testClientFromCardDoesNotRefetchIt() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    // Make any further well-known fetch fail loudly. If construction
    // re-resolved the card it would surface this 500 as a construction
    // error rather than succeeding.
    setWellKnownOverride({message: "well-known must not be fetched again"}, 500);
    Client|error c = new (card);
    setWellKnownOverride(());

    test:assertTrue(c is Client,
            "a Client built from a resolved card must hand that card to its delegate rather than fetching a second time");
}

// Confirms all three concrete types still satisfy the shared internal
// ClientMethods shape as the codebase evolves — not a caller-facing
// capability (ClientMethods isn't public; see client_methods.bal).
@test:Config {}
function testClientMethodsAcceptsEveryImplementation() returns error? {
    ClientMethods viaCommon = check new Client(cardForBinding("HTTP+JSON"));
    ClientMethods viaRest = check new RestClient(getServerBaseUrl());

    foreach ClientMethods _ in [viaCommon, viaRest] {
        // Holding them in one array is itself the assertion: it only
        // compiles because both satisfy the shared shape.
    }
    test:assertTrue(true);
}

// This release implements HTTP+JSON only, so a card offering nothing else
// must fail at construction rather than at the first call.
@test:Config {}
function testClientRejectsCardWithNoHttpJsonInterface() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "http://localhost:19199", protocolBinding: "GRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    Client|error result = new (card);
    test:assertTrue(result is InternalError,
            "a card declaring no HTTP+JSON interface must fail construction");
}

// A v1.0-shaped card can still declare a 0.x protocolVersion on its
// interface; requireV1Interface catches that at construction.
@test:Config {}
function testClientRejectsV03ProtocolVersionOnItsInterface() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "0.3"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    Client|error result = new (card);
    test:assertTrue(result is VersionNotSupportedError,
            "a v0.3 interface must be rejected by version, not attempted as v1.0");
}

// ---- selection skips interfaces no client could serve ----------------
