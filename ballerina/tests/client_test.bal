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

import ballerina/http;
import ballerina/test;
import ballerina/time;

@test:Config {}
function testResolveAgentCardSuccess() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());

    test:assertEquals(card.name, "Mock Weather Agent");
    test:assertEquals(card.capabilities.streaming, true);
    test:assertEquals(card.skills.length(), 1);
    test:assertEquals(card.skills[0].id, "weather-lookup");
}

@test:Config {}
function testResolveAgentCardSuccessWithTrailingSlash() returns error? {
    // A card's own `url` field commonly carries a trailing slash (the spec
    // doesn't forbid it), and callers are expected to feed that value back
    // in as agentBaseUrl on a follow-up resolve (Client.init does exactly
    // this). Regression test for the double-slash join this used to
    // produce against the well-known endpoint, confirmed against a real
    // running agent whose card declared url: "http://host:port/".
    AgentCard card = check resolveAgentCard(getServerBaseUrl() + "/");

    test:assertEquals(card.name, "Mock Weather Agent");
}

@test:Config {}
function testResolveAgentCardUnreachableEndpoint() returns error? {
    AgentCard|error result = resolveAgentCard("http://localhost:1");

    test:assertTrue(result is error, "unreachable endpoint should surface as an error, not panic");
}

@test:Config {}
function testResolveAgentCardNon200Status() returns error? {
    setWellKnownOverride({message: "not found"}, 404);

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    test:assertTrue(result is error, "a non-200 well-known response should surface as an error");
    test:assertTrue(result is InternalError, "non-200 well-known response should map to InternalError");
}

@test:Config {}
function testResolveAgentCardMalformedJson() returns error? {
    setWellKnownOverride({"totally": "not an agent card"});

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    test:assertTrue(result is error, "a well-known body that doesn't decode as AgentCard should surface as an error");
}

@test:Config {}
function testPrimaryUrlPrefersSupportedInterfaces() returns error? {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "https://primary.example.com", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "https://secondary.example.com", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };

    test:assertEquals(check primaryUrl(card, JSONRPC), "https://primary.example.com");
}

// Confirms primaryUrl filters by protocolBinding rather than blindly
// taking supportedInterfaces[0] — a card listing a binding this Client
// doesn't speak (e.g. GRPC) before its JSONRPC entry must still resolve
// to the JSONRPC one, not fail non-obviously on the first real request.
//
@test:Config {}
function testPrimaryUrlSkipsNonJsonRpcInterfaces() returns error? {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "https://grpc.example.com", protocolBinding: "GRPC", protocolVersion: "1.0"},
            {url: "https://jsonrpc.example.com", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };

    test:assertEquals(check primaryUrl(card, JSONRPC), "https://jsonrpc.example.com");
}

@test:Config {}
function testPrimaryUrlErrorsWhenNeitherIsSet() {
    AgentCard card = {
        name: "x",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        supportedInterfaces: []
    };

    string|error result = primaryUrl(card, JSONRPC);

    test:assertTrue(result is error, "primaryUrl should error when the card declares no matching interface");
}

@test:Config {}
function testSelectInterfaceFindsHttpJsonWhenPreferred() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "http://rest.example", protocolBinding: "HTTP+JSON", tenant: "acme-rest", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    AgentInterface iface = check selectInterface(card, "HTTP+JSON");
    test:assertEquals(iface.url, "http://rest.example");
    test:assertEquals(iface?.tenant, "acme-rest");
}

@test:Config {}
function testSelectInterfaceErrorsWhenNoMatchAndNoLegacyUrl() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://jsonrpc.example", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    AgentInterface|error result = selectInterface(card, "HTTP+JSON");
    test:assertTrue(result is error, "no HTTP+JSON interface and no legacy url should error, not silently fall back to a JSONRPC endpoint");
}

@test:Config {groups: ["grpc"]}
function testSelectInterfaceGrpcOnlyCard() returns error? {
    AgentCard card = {
        name: "grpc-agent", description: "d", version: "1.0",
        capabilities: {},
        supportedInterfaces: [{url: "http://localhost:9090", protocolBinding: "GRPC", protocolVersion: "1.0"}],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    AgentInterface iface = check selectInterface(card, "GRPC");
    test:assertEquals(iface.url, "http://localhost:9090");
}

@test:Config {groups: ["grpc"]}
function testSelectInterfaceMixedCardOrdering() returns error? {
    AgentCard card = {
        name: "mixed-agent", description: "d", version: "1.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:9090", protocolBinding: "GRPC", protocolVersion: "1.0"},
            {url: "http://localhost:8080", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "http://localhost:8081", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    test:assertEquals(check primaryUrl(card, "GRPC"), "http://localhost:9090");
    test:assertEquals(check primaryUrl(card, "JSONRPC"), "http://localhost:8080");
    test:assertEquals(check primaryUrl(card, "HTTP+JSON"), "http://localhost:8081");
}

// Spec 8.3.2: supportedInterfaces is ordered by the server's own
// preference, so among entries sharing a protocolBinding the earliest wins.
// The entry's protocolVersion plays no part in the choice — the server
// ordered the list deliberately, and the reference Java SDK reads it the
// same way (it keeps only the first entry per binding).
@test:Config {}
function testSelectInterfaceTakesFirstEntryForBinding() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://first.example", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "http://second.example", protocolBinding: "JSONRPC", protocolVersion: "0.3"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    AgentInterface iface = check selectInterface(card, JSONRPC);
    test:assertEquals(iface.url, "http://first.example");
}

// The discriminating case: the card lists its 0.3 interface first. A client
// must still honour that ordering rather than hunting for a higher
// protocolVersion further down the list.
@test:Config {}
function testSelectInterfaceHonoursCardOrderOverProtocolVersion() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://v03.example", protocolBinding: "JSONRPC", protocolVersion: "0.3"},
            {url: "http://v1.example", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    AgentInterface iface = check selectInterface(card, JSONRPC);
    test:assertEquals(iface.url, "http://v03.example",
            "the server's declared order wins; selection must not rank by protocolVersion");
}

// A card declaring a tenant on its JSONRPC interface. The shared default
// mock card deliberately declares none, so tenant auto-wiring gets its own
// fixture rather than silently colouring every other test's request params.
isolated function cardWithTenant(string tenant) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0",
    capabilities: {streaming: true},
    supportedInterfaces: [
        {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", tenant, protocolVersion: "1.0"}
    ],
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"]
};

@test:Config {}
function testClientInitFromUrl() returns error? {
    setNextRestResponse({task: {id: "t1", status: {state: "TASK_STATE_COMPLETED"}}});
    Client agentClient = check new (getServerBaseUrl());
    Task|Message result = check agentClient->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task || result is Message);
}

@test:Config {}
function testClientInitFromAgentCard() returns error? {
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    setNextRestResponse({task: {id: "t1", status: {state: "TASK_STATE_COMPLETED"}}});
    Client agentClient = check new (card);
    Task|Message result = check agentClient->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(result is Task || result is Message);
}

// When the selected AgentInterface declares a tenant, init must read it
// automatically and send it on every request without the caller repeating it.
@test:Config {}
function testClientInitAutoWiresTenantFromCard() returns error? {
    setNextRestResponse({task: {id: "t1", status: {state: "TASK_STATE_COMPLETED"}}});
    Client agentClient = check new (cardWithTenant("acme-corp"));
    Task|Message _ = check agentClient->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    json params = getLastRestBody();
    test:assertEquals(check params.tenant, "acme-corp");
}

// An explicitly-passed tenant must win over the card's own declared value.
@test:Config {}
function testClientInitExplicitTenantOverridesCard() returns error? {
    setNextRestResponse({task: {id: "t1", status: {state: "TASK_STATE_COMPLETED"}}});
    Client agentClient = check new (cardWithTenant("acme-corp"), tenant = "explicit-tenant");
    Task|Message _ = check agentClient->sendMessage({message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]}});
    json params = getLastRestBody();
    test:assertEquals(check params.tenant, "explicit-tenant");
}

// A card offering only HTTP+JSON is perfectly usable: Client takes its
// binding from the card, so it builds a RestClient.
//
// This previously failed. Client defaulted to JSONRPC and never consulted
// the card ordering, which made a valid REST-only agent unreachable through
// the common client - the behaviour spec section 8.3.2 rules out, and the
// defect this delegator fixes.
@test:Config {}
function testClientInitUsesTheOnlyBindingTheCardOffers() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    Client c = check new (card);

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1",
            "a REST-only card must produce a client that actually speaks REST");
}

// The card's ordering is its preference, so the first entry wins even when
// a later one names a binding the caller might have preferred.
@test:Config {}
function testClientInitFollowsCardOrderNotLibraryPreference() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"},
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    Client c = check new (card);

    setNextRestResponse(defaultTaskJson());
    Task _ = check c->getTask({id: "task-1"});
    test:assertEquals(getLastRestRequest().path, "/tasks/task-1",
            "HTTP+JSON is listed first, so it must be chosen over the JSONRPC entry behind it");
}

// Nothing this library can speak, and no legacy url to fall back on.
@test:Config {}
function testClientInitErrorsWhenCardOffersNoSupportedBinding() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://exotic.example", protocolBinding: "SOMETHING-ELSE", protocolVersion: "1.0"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    Client|error result = new (card);
    test:assertTrue(result is error,
            "a card declaring only a binding this library cannot speak must fail construction");
}

// An unreachable discovery URL must surface resolveAgentCard's error, not panic.
@test:Config {}
function testClientInitFromUrlUnreachableEndpoint() {
    Client|error result = new ("http://localhost:1");
    test:assertTrue(result is error, "unreachable discovery endpoint should surface as an error, not panic");
}

@test:Config {}
function testSendMessageHappyPath() returns error? {
    setNextRestResponse({
        task: {
            id: "task-1",
            contextId: "ctx-1",
            status: {state: "TASK_STATE_COMPLETED"},
            artifacts: [
                {artifactId: "art-1", parts: [{text: "29 degrees Celsius and partly cloudy."}]}
            ]
        }
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-1",
        role: ROLE_USER,
        parts: [{text: "What is the weather in Colombo?"}]
    };

    Task|Message result = check c->sendMessage({message: msg});

    test:assertTrue(result is Task, "mock returned a Task, so sendMessage should decode it as one");
    Task task = <Task>result;
    assertValidTask(task);
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(extractArtifactText((task.artifacts ?: [])[0]), "29 degrees Celsius and partly cloudy.");
}

// SendMessageRequest.metadata (specification section 3.2.1) is a
// request-level field, distinct from Message.metadata — confirms it's
// actually placed at the top level of params, not nested under "message".
//
@test:Config {}
function testSendMessageIncludesRequestLevelMetadataWhenSet() returns error? {
    setNextRestResponse({task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}});

    Client c = check new (getServerBaseUrl());
    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage({message: msg, metadata: {"traceId": "abc-123"}});

    json requestMetadata = check getLastRestBody().metadata;
    test:assertEquals(requestMetadata, {"traceId": "abc-123"});
}

@test:Config {}
function testSendMessageOmitsRequestLevelMetadataWhenUnset() returns error? {
    setNextRestResponse({task: {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}});

    Client c = check new (getServerBaseUrl());
    Message msg = {messageId: "msg-1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage({message: msg});

    json params = getLastRestBody();
    map<json> paramsMap = check params.ensureType();
    test:assertFalse(paramsMap.hasKey("metadata"), "request-level metadata should be absent when the caller didn't set it");
}

@test:Config {}
function testSendMessageSendsRequestedExtensionsHeader() returns error? {
    setNextRestResponse({task: defaultTaskJson()});
    Client c = check new (getServerBaseUrl(), requestedExtensions = ["urn:example:ext-a", "urn:example:ext-b"]);
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage({message: msg});

    map<string> headers = getLastRestHeaders();
    test:assertEquals(headers["a2a-extensions"], "urn:example:ext-a,urn:example:ext-b");
}

@test:Config {}
function testClientInitDoesNotMutateCallerSuppliedConfigOrHeaders() returns error? {
    // Regression test: Client.init must not mutate the caller's own
    // clientConfig/headers in place. Constructing several agent clients in
    // a loop from one shared base config must not let the first client's
    // settings leak into the second. init defends against this with a
    // mapping-constructor spread and a headers clone; this pins that down.
    http:ClientConfiguration sharedConfig = {};
    map<string> sharedHeaders = {};
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};

    map<string> headers1 = sharedHeaders.clone();
    headers1["X-Trace"] = "one";
    setNextRestResponse({task: defaultTaskJson()});
    Client c1 = check new (getServerBaseUrl(), clientConfig = sharedConfig, headers = headers1);
    Task|Message _ = check c1->sendMessage({message: msg});
    test:assertEquals(getLastRestHeaders()["x-trace"], "one");

    map<string> headers2 = sharedHeaders.clone();
    headers2["X-Trace"] = "two";
    setNextRestResponse({task: defaultTaskJson()});
    Client c2 = check new (getServerBaseUrl(), clientConfig = sharedConfig, headers = headers2);
    Task|Message _ = check c2->sendMessage({message: msg});
    test:assertEquals(getLastRestHeaders()["x-trace"], "two",
            "a second Client sharing the same base clientConfig must not inherit the first Client's headers");

    test:assertTrue(sharedConfig.auth is (), "Client.init must not mutate the caller's own clientConfig in place");
    test:assertEquals(sharedHeaders.length(), 0, "Client.init must not mutate the caller's own headers map in place");
}

@test:Config {}
function testClientInitAppliesCallerSuppliedAuthAndHeaders() returns error? {
    // Auth is configured through clientConfig.auth and headers directly —
    // this library does not derive it from the AgentCard's security
    // schemes (see issue #13). Both must reach the wire.
    setNextRestResponse({task: defaultTaskJson()});
    Client c = check new (getServerBaseUrl(),
            clientConfig = {auth: {token: "explicit-tok"}},
            headers = {"X-Api-Key": "explicit-key"});
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage({message: msg});

    map<string> headers = getLastRestHeaders();
    test:assertEquals(headers["authorization"], "Bearer explicit-tok",
            "an explicit clientConfig.auth must be sent");
    test:assertEquals(headers["x-api-key"], "explicit-key",
            "an explicit headers entry must be sent");
}

// The real reference server's SendMessage response wraps the payload —
// {"result": {"task": {...}}} or {"result": {"message": {...}}} — never a
// flat Task/Message. The happy-path test above only ever exercised the
// task branch; this covers the message branch of that same wrapper.
//
@test:Config {}
function testSendMessageHappyPathMessageVariant() returns error? {
    setNextRestResponse({
        message: {
            messageId: "reply-msg-1",
            role: "ROLE_AGENT",
            parts: [{text: "Hi there!"}]
        }
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-1a",
        role: ROLE_USER,
        parts: [{text: "hi"}]
    };

    Task|Message result = check c->sendMessage({message: msg});

    test:assertTrue(result is Message, "mock returned a Message, so sendMessage should decode it as one");
    Message reply = <Message>result;
    test:assertEquals(reply.messageId, "reply-msg-1");
    test:assertEquals(reply.parts[0]?.text, "Hi there!");
}

// A conforming server can't produce this (task/message form a real
// protobuf oneof upstream), but SendMessageResult is a plain open record on
// our side with no such enforcement — a non-conforming server sending both
// should be treated as a malformed response, not silently resolved by
// preferring one field over the other.
//
@test:Config {}
function testSendMessageRejectsResponseWithBothTaskAndMessage() returns error? {
    setNextRestResponse({
        task: {id: "task-ambiguous", status: {state: "TASK_STATE_COMPLETED"}},
        message: {messageId: "reply-ambiguous", role: "ROLE_AGENT", parts: [{text: "Hi there!"}]}
    });

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-ambiguous",
        role: ROLE_USER,
        parts: [{text: "hi"}]
    };

    Task|Message|error result = c->sendMessage({message: msg});

    test:assertTrue(result is error, "a response with both task and message set should surface as an error");
    test:assertTrue(result is InvalidAgentResponseError, "should map to InvalidAgentResponseError, not silently prefer task");
}

@test:Config {}
function testSendMessageStreamHappyPath() returns error? {
    setNextRestSseResponse([
        {data: string `{"statusUpdate":{"taskId":"task-2","contextId":"ctx-2","status":{"state":"TASK_STATE_WORKING"}}}`},
        {data: string `{"artifactUpdate":{"taskId":"task-2","contextId":"ctx-2","artifact":{"artifactId":"art-2","parts":[{"text":"29 degrees Celsius and partly cloudy."}]}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-2","contextId":"ctx-2","status":{"state":"TASK_STATE_COMPLETED"}}}`}
    ]);

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-2",
        role: ROLE_USER,
        parts: [{text: "What is the weather in Colombo?"}]
    };

    stream<StreamResponse, error?> events = check c->sendStreamingMessage({message: msg});

    StreamResponse first = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(events.next());
    TaskArtifactUpdateEvent artifactEvent = <TaskArtifactUpdateEvent>second;
    test:assertEquals(extractArtifactText(artifactEvent.artifact), "29 degrees Celsius and partly cloudy.");

    StreamResponse third = check expectValue(events.next());
    test:assertEquals((<TaskStatusUpdateEvent>third).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? fourth = events.next();
    test:assertTrue(fourth is (), "stream should close after the terminal status");
}

@test:Config {}
function testSendMessageStreamPausesAtInputRequiredThenResumes() returns error? {
    setNextRestSseResponse([
        {data: string `{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_WORKING"}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_INPUT_REQUIRED"}}}`}
    ]);

    Client c = check new (getServerBaseUrl());
    Message turn1 = {
        messageId: "msg-3",
        role: ROLE_USER,
        parts: [{text: "Research quantum error correction advances in 2024"}]
    };

    stream<StreamResponse, error?> firstStream = check c->sendStreamingMessage({message: turn1});

    StreamResponse working = check expectValue(firstStream.next());
    test:assertEquals((<TaskStatusUpdateEvent>working).status.state, TASK_STATE_WORKING);

    StreamResponse inputRequired = check expectValue(firstStream.next());
    TaskStatusUpdateEvent inputRequiredEvent = <TaskStatusUpdateEvent>inputRequired;
    test:assertEquals(inputRequiredEvent.status.state, TASK_STATE_INPUT_REQUIRED);

    record {| StreamResponse value; |}|error? afterPause = firstStream.next();
    test:assertTrue(afterPause is (), "no more events scripted after INPUT_REQUIRED for the first turn");

    // Resume with the same taskId/contextId, as design §9.3 shows.
    setNextRestSseResponse([
        {data: string `{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_WORKING"}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-3","contextId":"ctx-3","status":{"state":"TASK_STATE_COMPLETED"}}}`}
    ]);

    Message turn2 = {
        messageId: "msg-4",
        role: ROLE_USER,
        contextId: inputRequiredEvent.contextId,
        taskId: inputRequiredEvent.taskId,
        parts: [{text: "Focus on surface codes and topological qubits"}]
    };

    stream<StreamResponse, error?> secondStream = check c->sendStreamingMessage({message: turn2});

    StreamResponse resumedWorking = check expectValue(secondStream.next());
    test:assertEquals((<TaskStatusUpdateEvent>resumedWorking).status.state, TASK_STATE_WORKING);

    StreamResponse completed = check expectValue(secondStream.next());
    TaskStatusUpdateEvent completedEvent = <TaskStatusUpdateEvent>completed;
    test:assertEquals(completedEvent.status.state, TASK_STATE_COMPLETED);
    test:assertEquals(completedEvent.taskId, "task-3");
    test:assertEquals(completedEvent.contextId, "ctx-3");
}

@test:Config {}
function testGetTaskNotFoundErrorMapping() returns error? {
    setNextRestResponse({"error": {"message": "Task not found", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "metadata": {taskId: "task-unknown"}}]}}, 404);

    Client c = check new (getServerBaseUrl());
    Task|error result = c->getTask({id: "task-unknown"});

    test:assertTrue(result is error, "an unknown task should surface as an error");
    test:assertTrue(result is TaskNotFoundError, "code -32001 should map to TaskNotFoundError");
}

@test:Config {}
function testGetTaskReturnsFailedState() returns error? {
    setNextRestResponse(taskJsonWithState("task-x", "TASK_STATE_FAILED"));
    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask({id: "task-x"});
    test:assertEquals(task.status.state, TASK_STATE_FAILED);
}

@test:Config {}
function testGetTaskReturnsRejectedState() returns error? {
    setNextRestResponse(taskJsonWithState("task-y", "TASK_STATE_REJECTED"));
    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask({id: "task-y"});
    test:assertEquals(task.status.state, TASK_STATE_REJECTED);
}

@test:Config {}
function testGetTaskReturnsAuthRequiredState() returns error? {
    setNextRestResponse(taskJsonWithState("task-z", "TASK_STATE_AUTH_REQUIRED"));
    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask({id: "task-z"});
    test:assertEquals(task.status.state, TASK_STATE_AUTH_REQUIRED);
}

@test:Config {}
function testSendMessageMalformedEnvelopeMapping() returns error? {
    // Neither result nor error — a malformed JSON-RPC envelope.
    setNextRestResponse({});

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-5",
        role: ROLE_USER,
        parts: [{text: "hello"}]
    };
    Task|Message|error result = c->sendMessage({message: msg});

    test:assertTrue(result is error, "a malformed envelope should surface as an error");
    test:assertTrue(result is InvalidAgentResponseError, "a malformed envelope should map to InvalidAgentResponseError");
}

@test:Config {}
function testTenantPropagatesOnEveryMethod() returns error? {
    string tenant = "acme-corp";
    Client c = check new (getServerBaseUrl(), tenant = tenant);
    Message msg = {
        messageId: "msg-tenant",
        role: ROLE_USER,
        parts: [{text: "hello"}]
    };
    json validTaskResponse = {id: "task-tenant", status: {state: "TASK_STATE_COMPLETED"}};
    // sendMessage's response wraps the Task, unlike getTask/cancelTask.
    json wrappedTaskResponse = {task: {id: "task-tenant", status: {state: "TASK_STATE_COMPLETED"}}};
    http:SseEvent[] minimalSseResponse = [
        {data: string `{"statusUpdate":{"taskId":"task-tenant","contextId":"ctx-tenant","status":{"state":"TASK_STATE_WORKING"}}}`}
    ];

    setNextRestResponse(wrappedTaskResponse);
    Task|Message _ = check c->sendMessage({message: msg});
    check assertLastRequestTenant(tenant, "sendMessage");

    setNextRestSseResponse(minimalSseResponse);
    stream<StreamResponse, error?>|error sendStreamingMessageResult = c->sendStreamingMessage({message: msg});
    check assertLastRequestTenant(tenant, "sendStreamingMessage");
    check closeIfStream(sendStreamingMessageResult);

    setNextRestResponse(validTaskResponse);
    Task _ = check c->getTask({id: "task-tenant"});
    check assertLastRequestTenant(tenant, "getTask");

    setNextRestResponse(validTaskResponse);
    Task _ = check c->cancelTask({id: "task-tenant"});
    check assertLastRequestTenant(tenant, "cancelTask");

    setNextRestSseResponse(minimalSseResponse);
    stream<StreamResponse, error?>|error subscribeToTaskResult = c->subscribeToTask({id: "task-tenant"});
    check assertLastRequestTenant(tenant, "subscribeToTask");
    check closeIfStream(subscribeToTaskResult);

    // listTasks has no v0.3 equivalent, so it only works in V1_0 mode —
    // same as the other five calls above, c is already a V1_0-mode client
    // (no agentCard was supplied to its constructor).
    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0});
    ListTasksResponse _ = check c->listTasks();
    check assertLastRequestTenant(tenant, "listTasks");

    setNextRestResponse({url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-tenant"});
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-tenant"
    });
    check assertLastRequestTenant(tenant, "createTaskPushNotificationConfig");

    setNextRestResponse({url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-tenant"});
    TaskPushNotificationConfig _ = check c->getTaskPushNotificationConfig({taskId: "task-tenant", id: "webhook-1"});
    check assertLastRequestTenant(tenant, "getTaskPushNotificationConfig");

    setNextRestResponse({
        configs: [{url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}],
        nextPageToken: ""
    });
    ListTaskPushNotificationConfigsResponse _ = check c->listTaskPushNotificationConfigs({taskId: "task-tenant"});
    check assertLastRequestTenant(tenant, "listTaskPushNotificationConfigs");

    setNextRestResponse({});
    check c->deleteTaskPushNotificationConfig({taskId: "task-tenant", id: "webhook-1"});
    check assertLastRequestTenant(tenant, "deleteTaskPushNotificationConfig");

    setNextRestResponse({
        name: "Mock Weather Agent (extended)",
        description: "A scripted mock agent used by Client tests",
        version: "1.0.0",
        capabilities: {extendedAgentCard: true},
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    , supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}]});
    AgentCard _ = check c->getExtendedAgentCard();
    check assertLastRequestTenant(tenant, "getExtendedAgentCard");
}

// Drains and closes a possibly-opened SSE stream so the mock server isn't
// left trying to write to an abandoned connection between tests.
//
isolated function closeIfStream(stream<StreamResponse, error?>|error result) returns error? {
    if result is stream<StreamResponse, error?> {
        record {| StreamResponse value; |}|error? next = result.next();
        while next is record {| StreamResponse value; |} {
            next = result.next();
        }
        check result.close();
    }
}

@test:Config {}
function testPerCallTenantOverridesClientDefault() returns error? {
    setNextRestResponse({task: {id: "task-tenant-2", status: {state: "TASK_STATE_COMPLETED"}}});

    Client c = check new (getServerBaseUrl(), tenant = "default-tenant");
    Message msg = {
        messageId: "msg-tenant-2",
        role: ROLE_USER,
        parts: [{text: "hello"}]
    };

    Task|Message _ = check c->sendMessage({message: msg, tenant: "override-tenant"});

    check assertLastRequestTenant("override-tenant", "sendMessage with a per-call override");
}

// The REST binding routes the tenant as a leading path segment, and
// duplicates it into the body for operations that have one. Asserting on the
// path covers both: every operation carries it there.
isolated function assertLastRequestTenant(string expectedTenant, string label) returns error? {
    string path = getLastRestRequest().path;
    test:assertTrue(path.startsWith(string `/${expectedTenant}/`),
            string `${label} should route the tenant as a path prefix; got "${path}"`);
}

@test:Config {}
function testClientConfigTimeoutPassthrough() returns error? {
    // A generous delay/threshold gap (0.1s timeout vs. a 3s mock delay,
    // asserting well under that at 2s) so this doesn't flake under
    // scheduling jitter when the full suite runs concurrently.
    // Construct from an already-resolved card, not a URL: init resolves the
    // card over HTTP using this same clientConfig, and a 0.1s timeout would
    // trip during construction rather than during the operation under test —
    // the mock's delay is shared state and other tests run concurrently.
    // Resolving separately (on the default config) keeps the tight timeout
    // scoped to the call being measured.
    AgentCard card = check resolveAgentCard(getServerBaseUrl());
    Client c = check new (card, {timeout: 0.1});

    // setNextJsonResponse resets delaySeconds to 0, so the delay has to be
    // scripted after it, not before. The original order set the delay first
    // and had it immediately cleared - that test only passed by borrowing a
    // concurrently-running test's delay from the shared mock script.
    setNextRestResponse({id: "task-slow", status: {state: "TASK_STATE_COMPLETED"}});
    setNextDelay(3);

    decimal before = time:monotonicNow();
    Task|error result = c->getTask({id: "task-slow"});
    decimal elapsed = time:monotonicNow() - before;

    setNextDelay(0);

    test:assertTrue(result is error, "a client configured with a 0.1s timeout should time out against a slow mock response");
    test:assertTrue(elapsed < 2d, string `expected the timeout to fire well under the mock's 3s delay, took ${elapsed}s`);
}

@test:Config {}
function testListTasksHappyPath() returns error? {
    setNextRestResponse({
        tasks: [{id: "task-1", status: {state: "TASK_STATE_COMPLETED"}}],
        nextPageToken: "cursor-abc",
        pageSize: 20,
        totalSize: 1
    });

    Client c = check new (getServerBaseUrl());
    ListTasksResponse result = check c->listTasks();

    test:assertEquals(result.tasks.length(), 1);
    test:assertEquals(result.tasks[0].id, "task-1");
    test:assertEquals(result.nextPageToken, "cursor-abc");
    test:assertEquals(result.totalSize, 1);
}

// Confirms filter fields actually reach the wire. ListTasks is a GET in the
// REST binding, so its filter travels in the query string rather than a
// body — every value therefore arrives as a string.
//
@test:Config {}
function testListTasksSendsFilterFieldsOnWire() returns error? {
    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0});

    Client c = check new (getServerBaseUrl());
    ListTasksResponse _ = check c->listTasks({
        contextId: "ctx-1",
        status: TASK_STATE_COMPLETED,
        pageSize: 20,
        pageToken: "cursor-abc",
        includeArtifacts: true
    });

    map<string> query = getLastRestRequest().queryParams;
    test:assertEquals(query["contextId"], "ctx-1");
    test:assertEquals(query["status"], "TASK_STATE_COMPLETED");
    test:assertEquals(query["pageSize"], "20");
    test:assertEquals(query["pageToken"], "cursor-abc");
    test:assertEquals(query["includeArtifacts"], "true");
}

@test:Config {}
function testListTasksOmitsUnsetFilterFields() returns error? {
    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 20, totalSize: 0});

    Client c = check new (getServerBaseUrl());
    ListTasksResponse _ = check c->listTasks();

    map<string> query = getLastRestRequest().queryParams;
    test:assertFalse(query.hasKey("contextId"), "contextId should be absent when no filter is passed");
    test:assertFalse(query.hasKey("pageSize"), "pageSize should be absent when no filter is passed");
}

@test:Config {}
function testListTasksSendsAllFilterFields() returns error? {
    setNextRestResponse({tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0});
    Client c = check new (getServerBaseUrl());
    ListTasksResponse _ = check c->listTasks({
        contextId: "ctx-1",
        status: TASK_STATE_WORKING,
        pageSize: 10,
        pageToken: "cursor-abc",
        historyLength: 5,
        statusTimestampAfter: "2026-01-01T00:00:00Z",
        includeArtifacts: true
    });
    map<string> query = getLastRestRequest().queryParams;
    test:assertEquals(query["contextId"], "ctx-1");
    test:assertEquals(query["status"], "TASK_STATE_WORKING");
    test:assertEquals(query["pageSize"], "10");
    test:assertEquals(query["pageToken"], "cursor-abc");
    test:assertEquals(query["historyLength"], "5");
    test:assertEquals(query["statusTimestampAfter"], "2026-01-01T00:00:00Z");
    test:assertEquals(query["includeArtifacts"], "true");
}

@test:Config {}
function testCreateTaskPushNotificationConfigHappyPath() returns error? {
    setNextRestResponse({url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"});

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(config?.id, "webhook-1");
}

@test:Config {}
function testGetTaskPushNotificationConfigHappyPath() returns error? {
    setNextRestResponse({url: "https://client.example.com/webhooks/a2a", id: "webhook-1", taskId: "task-1"});

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig config = check c->getTaskPushNotificationConfig({taskId: "task-1", id: "webhook-1"});

    test:assertEquals(config.url, "https://client.example.com/webhooks/a2a");

    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs/webhook-1");
}

@test:Config {}
function testCreateTaskPushNotificationConfigNotSupportedErrorMapping() returns error? {
    setNextRestResponse({"error": {"message": "Push notifications not supported", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "PUSH_NOTIFICATION_NOT_SUPPORTED"}]}}, 400);

    Client c = check new (getServerBaseUrl());
    TaskPushNotificationConfig|error result = c->createTaskPushNotificationConfig({
        url: "https://client.example.com/webhooks/a2a",
        taskId: "task-1"
    });

    test:assertTrue(result is PushNotificationNotSupportedError, "code -32003 should map to PushNotificationNotSupportedError");
}

@test:Config {}
function testListTaskPushNotificationConfigsHappyPath() returns error? {
    setNextRestResponse({
        configs: [{url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}],
        nextPageToken: "cursor-abc"
    });

    Client c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResponse result = check c->listTaskPushNotificationConfigs({taskId: "task-1"});

    test:assertEquals((result.configs ?: []).length(), 1);
    test:assertEquals((result.configs ?: [])[0].url, "https://client.example.com/webhooks/a2a");
    test:assertEquals(result.nextPageToken, "cursor-abc");

    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs");
}

@test:Config {}
function testListTaskPushNotificationConfigsSendsPaginationFieldsWhenSet() returns error? {
    setNextRestResponse({configs: [], nextPageToken: ""});

    Client c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResponse _ = check c->listTaskPushNotificationConfigs({taskId: "task-1", pageSize: 10, pageToken: "cursor-abc"});

    map<string> query = getLastRestRequest().queryParams;
    test:assertEquals(query["pageSize"], "10");
    test:assertEquals(query["pageToken"], "cursor-abc");
}

@test:Config {}
function testDeleteTaskPushNotificationConfigHappyPathReturnsNil() returns error? {
    setNextRestResponse({});

    Client c = check new (getServerBaseUrl());
    error? result = c->deleteTaskPushNotificationConfig({taskId: "task-1", id: "webhook-1"});

    test:assertTrue(result is (), "a successful delete should return nil, not an error");

    test:assertEquals(getLastRestRequest().path, "/tasks/task-1/pushNotificationConfigs/webhook-1");
}

@test:Config {}
function testGetExtendedAgentCardHappyPath() returns error? {
    setNextRestResponse({
        name: "Mock Weather Agent (extended)",
        description: "A scripted mock agent used by Client tests",
        version: "1.0.0",
        capabilities: {extendedAgentCard: true},
        skills: [{id: "weather-lookup", name: "Weather Lookup", description: "Reports current weather for a city", tags: []}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    , supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}]});

    Client c = check new (getServerBaseUrl());
    AgentCard card = check c->getExtendedAgentCard();

    test:assertEquals(card.name, "Mock Weather Agent (extended)");
}

@test:Config {}
function testGetExtendedAgentCardNotConfiguredErrorMapping() returns error? {
    setNextRestResponse({"error": {"message": "Extended agent card not configured", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "EXTENDED_AGENT_CARD_NOT_CONFIGURED"}]}}, 400);

    Client c = check new (getServerBaseUrl());
    AgentCard|error result = c->getExtendedAgentCard();

    test:assertTrue(result is ExtendedAgentCardNotConfiguredError, "code -32007 should map to ExtendedAgentCardNotConfiguredError");
}

@test:Config {}
function testResolveAgentCardParsesRichFieldSetWithTypedSecurity() returns error? {
    setWellKnownOverride({
        name: "Rich Agent",
        description: "An agent with a full field set",
        version: "2.0.0",
        provider: {organization: "Acme Corp", url: "https://acme.example.com"},
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        securitySchemes: {
            "bearerAuth": {"type": "http", "scheme": "bearer"},
            "apiKeyAuth": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
        },
        securityRequirements: [{"bearerAuth": []}],
        signatures: [
            {protected: "eyJhbGciOiJSUzI1NiJ9", signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    });

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    AgentCard card = check result;
    test:assertEquals((card.securitySchemes ?: {}).length(), 2);
    test:assertTrue((card.securitySchemes ?: {}).get("bearerAuth") is HttpAuthSecurityScheme);
    test:assertTrue((card.securitySchemes ?: {}).get("apiKeyAuth") is ApiKeySecurityScheme);
    test:assertEquals(card.securityRequirements, [{"bearerAuth": []}]);
    test:assertEquals((card.signatures ?: []).length(), 1);
    test:assertEquals(card?.provider?.organization, "Acme Corp");
}

@test:Config {}
function testResolveAgentCardDropsUnrecognizedSecuritySchemeEntry() returns error? {
    setWellKnownOverride({
        name: "Agent With Unknown Scheme",
        description: "Advertises a scheme type this client doesn't know",
        version: "1.0.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": {"type": "http", "scheme": "bearer"},
            "quantumAuth": {"type": "quantumEntanglement", "someField": "value"}
        },
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    , supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}]});

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    AgentCard card = check result;
    test:assertEquals((card.securitySchemes ?: {}).length(), 1);
    test:assertTrue((card.securitySchemes ?: {}).hasKey("bearerAuth"));
    test:assertFalse((card.securitySchemes ?: {}).hasKey("quantumAuth"));
}

@test:Config {}
function testResolveAgentCardDropsMalformedSignatureAndSecurityRequirementEntries() returns error? {
    setWellKnownOverride({
        name: "Agent With Some Malformed Security Data",
        description: "Has one good and one bad entry in signatures, securityRequirements, and a skill's securityRequirements",
        version: "1.0.0",
        capabilities: {},
        securityRequirements: [
            {"oauth": ["read"]},
            {"apiKey": "not-an-array"}
        ],
        signatures: [
            {"protected": "eyJhbGciOiJSUzI1NiJ9", "signature": "dGhpcyBpcyBhIHNpZ25hdHVyZQ"},
            {"header": {"alg": "RS256"}}
        ],
        skills: [
            {
                id: "skill-1",
                name: "Skill One",
                description: "Has a mix of good and bad securityRequirements entries",
                securityRequirements: [
                    {"oauth": ["write"]},
                    {"broken": "not-an-array"}
                ]
            , tags: []}
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    , supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}]});

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertEquals((card.securityRequirements ?: []).length(), 1);
    test:assertEquals((card.securityRequirements ?: [])[0], {"oauth": ["read"]});
    test:assertEquals((card.signatures ?: []).length(), 1);
    test:assertEquals((card.signatures ?: [])[0].protected, "eyJhbGciOiJSUzI1NiJ9");
    test:assertEquals((card.skills[0].securityRequirements ?: []).length(), 1);
    test:assertEquals((card.skills[0].securityRequirements ?: [])[0], {"oauth": ["write"]});
}

@test:Config {}
function testResolveAgentCardReturnsErrorOn304() returns error? {
    // Regression test: resolveAgentCard (non-cached) should never panic on 304.
    // If a non-compliant server sends 304 to an unconditional GET, it should
    // be treated as a non-200 error and return a typed InternalError, not panic.
    setWellKnownOverride(defaultMockAgentCard(), 304);

    AgentCard|error result = resolveAgentCard(getServerBaseUrl());

    setWellKnownOverride(());

    test:assertTrue(result is error, "resolveAgentCard should return an error on 304, not panic");
    test:assertTrue(result is InternalError, "304 should map to InternalError for unconditional requests");
}

@test:Config {}
function testSendMessageStreamReconnectsOnDrop() returns error? {
    // First script: the opening Task event (sendStreamingMessage's wrapping
    // only kicks in once a task exists to resubscribe to — see Step 4 of
    // the design), then a WORKING status, then an abrupt close — scripted
    // via setNextSseResponseThenDrop, which ends the scripted events with
    // a genuine stream error rather than a clean end-of-stream. A plain
    // setNextRestSseResponse([...]) running out of events is NOT equivalent:
    // that produces a normal, error-free stream close (see
    // testSendMessageStreamPausesAtInputRequiredThenResumes), which must
    // NOT trigger a reconnect — only a real transport error should.
    setNextRestSseResponseThenDrop([
        {'event: "message", data: taskJson("task-1")},
        {'event: "message", data: statusUpdateJson("task-1", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 1);
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});
    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first is Task, "first event should be the initial task/message");

    StreamResponse second = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);

    // Script the reconnect's response (what subscribeToTask will receive)
    // before pulling the next value — the drop happens on this next() call.
    setNextRestSseResponse([
        {'event: "message", data: statusUpdateJson("task-1", "TASK_STATE_COMPLETED")}
    ]);
    StreamResponse third = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>third).status.state, TASK_STATE_COMPLETED);
}

// Regression guard: maxReconnectAttempts defaults to 0, which must preserve
// today's exact pre-reconnect behavior — a dropped stream surfaces its
// error immediately to the caller, with no reconnect attempted. Proves the
// feature is truly opt-in, not silently on by default.
@test:Config {}
function testSendMessageStreamDoesNotReconnectByDefault() returns error? {
    setNextRestSseResponseThenDrop([
        {'event: "message", data: taskJson("task-1")},
        {'event: "message", data: statusUpdateJson("task-1", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl());
    Message msg = {messageId: "m2", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});

    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first is Task, "first event should be the initial task/message");

    StreamResponse second = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);

    // Script what a reconnect *would* receive, to prove it is never called:
    // if a reconnect happened despite maxReconnectAttempts being 0, this
    // scripted COMPLETED event would be returned instead of the error.
    setNextRestSseResponse([
        {'event: "message", data: statusUpdateJson("task-1", "TASK_STATE_COMPLETED")}
    ]);
    record {| StreamResponse value; |}|error? third = s.next();
    test:assertTrue(third is error, "with maxReconnectAttempts = 0 (the default), a dropped stream should surface its error immediately, not reconnect");
}

// Edge case called out explicitly in the design: a bare Message (no task)
// as sendStreamingMessage's first event carries nothing to resubscribe with,
// so wrapping must be a no-op even when maxReconnectAttempts > 0 — a
// dropped connection after a Message-only reply surfaces its error
// immediately, exactly like the maxReconnectAttempts = 0 case, rather than
// attempting (and failing) to call subscribeToTask with no taskId.
@test:Config {}
function testSendMessageStreamDoesNotReconnectAfterBareMessage() returns error? {
    setNextRestSseResponseThenDrop([
        {'event: "message", data: messageJson("reply-1")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 1);
    Message msg = {messageId: "m5", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});

    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first is Message, "first event should be the bare Message reply");

    // Script what a reconnect *would* receive, to prove it is never
    // called: if a reconnect were attempted despite there being no taskId
    // to resubscribe with, this scripted event would surface instead of
    // the drop's error.
    setNextRestSseResponse([
        {'event: "message", data: statusUpdateJson("task-should-not-exist", "TASK_STATE_COMPLETED")}
    ]);
    record {| StreamResponse value; |}|error? second = s.next();
    test:assertTrue(second is error, "a bare Message first event has no task to resubscribe to, so a dropped connection should surface its error immediately, not reconnect");
}

// subscribeToTask is the reconnect primitive ReconnectingStreamGenerator
// calls internally, but its own wrapping (simpler than
// sendStreamingMessage's — the taskId is already the input parameter, no
// peeking needed) had no direct coverage; this exercises it in isolation,
// not just as a side effect of sendStreamingMessage's reconnect.
@test:Config {}
function testSubscribeToTaskReconnectsOnDrop() returns error? {
    setNextRestSseResponseThenDrop([
        {'event: "message", data: statusUpdateJson("task-7", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 1);
    stream<StreamResponse, error?> s = check c->subscribeToTask({id: "task-7"});

    StreamResponse first = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_WORKING);

    // Script the reconnect's response — the drop happens on this next() call.
    setNextRestSseResponse([
        {'event: "message", data: statusUpdateJson("task-7", "TASK_STATE_COMPLETED")}
    ]);
    StreamResponse second = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_COMPLETED);
}

// Regression test for a real bug caught during review: on reconnect,
// ReconnectingStreamGenerator used to call
// self.a2aClient.openTaskSubscriptionStream(self.taskId) with no tenant
// argument, so a reconnect always fell back to the client-level default
// tenant (or no tenant at all) — even when the originating
// subscribeToTask(id, tenant = "x") call specified a per-call tenant
// override. In a multi-tenant deployment this silently resubscribes under
// the wrong tenant after a drop. This client is constructed with NO
// client-level default tenant, and the originating call passes a per-call
// tenant override; the mock's captured request body on the reconnect must
// still carry that same per-call tenant, not omit it or substitute a
// different one.
@test:Config {}
function testSubscribeToTaskReconnectPreservesPerCallTenant() returns error? {
    setNextRestSseResponseThenDrop([
        {'event: "message", data: statusUpdateJson("task-10", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 1);
    stream<StreamResponse, error?> s = check c->subscribeToTask({id: "task-10", tenant: "acme-corp"});

    StreamResponse first = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_WORKING);

    // Script the reconnect's response — the drop happens on this next() call.
    setNextRestSseResponse([
        {'event: "message", data: statusUpdateJson("task-10", "TASK_STATE_COMPLETED")}
    ]);
    StreamResponse second = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_COMPLETED);

    test:assertTrue(getLastRestRequest().path.startsWith("/acme-corp/"),
            "reconnect must resubscribe using the originating call's per-call tenant override, not the client-level default (or no tenant)");
}

// Proves attempt exhaustion actually surfaces the final error to the
// caller, rather than retrying indefinitely or swallowing it: with
// maxReconnectAttempts = 1, a second consecutive drop (the resubscribed
// stream itself failing immediately) must exhaust the single allotted
// attempt and return that second drop's error, not silently retry again.
@test:Config {}
function testSendMessageStreamGivesUpAfterExhaustingReconnectAttempts() returns error? {
    setNextRestSseResponseThenDrop([
        {'event: "message", data: taskJson("task-8")},
        {'event: "message", data: statusUpdateJson("task-8", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 1);
    Message msg = {messageId: "m6", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});

    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first is Task, "first event should be the initial task/message");

    StreamResponse second = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);

    // Script the resubscribe's response to fail immediately (no events at
    // all before the drop) — the single reconnect attempt succeeds in
    // opening a new stream, but that stream itself then drops right away,
    // with no attempts left to retry again.
    setNextRestSseResponseThenDrop([]);
    record {| StreamResponse value; |}|error? third = s.next();
    test:assertTrue(third is error, "a second consecutive drop after the single allotted reconnect attempt should surface as an error, not retry again or hang");
}

// Regression test for a real bug caught during review: ReconnectingStreamGenerator
// used to reconnect by calling the *public* subscribeToTask remote function,
// which wraps its own returned stream in a brand-new
// ReconnectingStreamGenerator with a fresh attemptsUsed = 0 and the full
// maxReconnectAttempts budget every time. Since each reconnect attempt
// went through that same public, budget-resetting path, the attempt count
// was silently reset on every single reconnect — against a mock (or
// agent) that fails every single reconnect attempt, not just once,
// reconnection never actually exhausted and recursed effectively without
// bound (confirmed to hang indefinitely before the fix, extracting the raw
// openTaskSubscriptionStream helper in client.bal). This scripts a target
// that keeps failing every reconnect attempt (not just the first) with
// maxReconnectAttempts = 2, so a persistently-unreachable agent must still
// give up after exactly 2 reconnect attempts, quickly, not hang.
@test:Config {}
function testSendMessageStreamGivesUpWhenEveryReconnectAttemptFails() returns error? {
    setNextRestSseResponseThenDrop([
        {'event: "message", data: taskJson("task-9")},
        {'event: "message", data: statusUpdateJson("task-9", "TASK_STATE_WORKING")}
    ]);
    Client c = check new (getServerBaseUrl(), maxReconnectAttempts = 2);
    Message msg = {messageId: "m7", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});

    StreamResponse first = check expectValue(s.next());
    test:assertTrue(first is Task, "first event should be the initial task/message");

    StreamResponse second = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);

    // From here on the mock keeps replaying this same "drop immediately"
    // script for every subsequent request — including both reconnect
    // attempts the generator will make — simulating a target that is
    // persistently failing, not just failing once.
    setNextRestSseResponseThenDrop([]);
    record {| StreamResponse value; |}|error? third = s.next();
    test:assertTrue(third is error, "with every reconnect attempt failing, both allotted attempts should be exhausted and the error surfaced, not recurse indefinitely");
}

@test:Config {}
function testClientInitRejectsV03WithHttpJsonBinding() returns error? {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: getServerBaseUrl(), protocolBinding: "HTTP+JSON", protocolVersion: "0.3"}
        ],
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    RestClient|error result = new (card);
    test:assertTrue(result is VersionNotSupportedError,
            "constructing an HTTP+JSON client against a card that resolves to V0_3 must fail fast with a typed error, not send a v0.3 JSON-RPC method name to a REST path");
}

@test:Config {}
function testClientInitDefaultBindingUnchangedWithNoCard() returns error? {
    // Omitting agentCard entirely must construct exactly as before,
    // regardless of the new binding parameter's value, since self.mode
    // defaults to V1_0 when no card is given.
    RestClient _ = check new (getServerBaseUrl());
}

// ---- REST/HTTP+JSON binding: non-streaming operations -----------------

@test:Config {}
function testRestSendMessageSendsCorrectPathAndBody() returns error? {
    setNextRestResponse({"task": defaultTaskJson()});
    RestClient c = check new (getServerBaseUrl());
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    Task|Message _ = check c->sendMessage({message: msg});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/message:send");
    map<json> body = check getLastRestBody().ensureType();
    test:assertTrue(body.hasKey("message"), "the REST request body must carry the message");
    map<json> messageBody = check body.get("message").ensureType();
    test:assertEquals(messageBody["messageId"], "m1");
}

@test:Config {}
function testRestGetTaskSendsCorrectPathAndQuery() returns error? {
    setNextRestResponse(defaultTaskJson());
    RestClient c = check new (getServerBaseUrl());
    Task _ = check c->getTask({id: "task-123", historyLength: 5});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-123");
    test:assertEquals(req.queryParams["historyLength"], "5");
}

@test:Config {}
function testRestCancelTaskSendsIdInPathAndBody() returns error? {
    setNextRestResponse(defaultTaskJson());
    RestClient c = check new (getServerBaseUrl());
    Task _ = check c->cancelTask({id: "task-123"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-123:cancel");
    // M4: id is duplicated into the body for hasBody operations, matching
    // the reference a2a-python SDK exactly rather than "cleaning up" the
    // path/body duplication.
    map<json> body = check getLastRestBody().ensureType();
    test:assertEquals(body["id"], "task-123", "CancelTask's id must be duplicated into the body per M4, not just substituted into the path");
}

@test:Config {}
function testRestHasBodyOperationDuplicatesTenantIntoBody() returns error? {
    // M3: tenant is duplicated into the body for hasBody operations too,
    // not just removed once it's substituted into the path (as it is for
    // bodiless operations, per testRestOperationWithTenantPrefixesPath).
    setNextRestResponse(defaultTaskJson());
    RestClient c = check new (getServerBaseUrl(), tenant = "acme-corp");
    Task _ = check c->cancelTask({id: "task-123"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.path, "/acme-corp/tasks/task-123:cancel");
    map<json> body = check getLastRestBody().ensureType();
    test:assertEquals(body["tenant"], "acme-corp", "M3: tenant must be duplicated into the body for hasBody operations");
    test:assertEquals(body["id"], "task-123");
}

@test:Config {}
function testRestListTasksEncodesFilterAsQueryString() returns error? {
    setNextRestResponse({"tasks": [], "nextPageToken": "", "pageSize": 10, "totalSize": 0});
    RestClient c = check new (getServerBaseUrl());
    ListTasksResponse _ = check c->listTasks({
        contextId: "ctx-1",
        status: TASK_STATE_WORKING,
        pageSize: 10,
        statusTimestampAfter: "2023-10-27T10:00:00+05:30"
    });
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks");
    test:assertEquals(req.queryParams["status"], "TASK_STATE_WORKING", "TaskState must serialize as its symbolic enum name in the query string, not an ordinal");
    test:assertEquals(req.queryParams["contextId"], "ctx-1");
}

@test:Config {}
function testRestCreateTaskPushNotificationConfigSendsTaskIdInPathAndBody() returns error? {
    setNextRestResponse({"url": "http://webhook.example", "id": "cfg-1", "taskId": "task-1"});
    RestClient c = check new (getServerBaseUrl());
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({url: "http://webhook.example", taskId: "task-1"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs");
    map<json> body = check getLastRestBody().ensureType();
    test:assertEquals(body["taskId"], "task-1", "taskId must be duplicated into the body per M4, not just substituted into the path");
}

@test:Config {}
function testRestDeleteTaskPushNotificationConfigToleratesEmptyBody() returns error? {
    setNextRestResponse({}, statusCode = 204, hasResponseBody = false);
    RestClient c = check new (getServerBaseUrl());
    error? result = c->deleteTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    test:assertTrue(result is (), "a 204 with no body must be treated as success, not InvalidAgentResponseError");
}

@test:Config {}
function testRestGetExtendedAgentCardSendsCorrectPath() returns error? {
    setNextRestResponse(defaultMockAgentCard());
    RestClient c = check new (getServerBaseUrl());
    AgentCard _ = check c->getExtendedAgentCard();
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/extendedAgentCard");
}

@test:Config {}
function testRestGetTaskPushNotificationConfigSendsCorrectPath() returns error? {
    // The only bodiless GET template with TWO path params — the one case
    // where path-param-substitution order and removing substituted
    // params from workingParams (so they don't leak into the query
    // string) could go wrong.
    setNextRestResponse({"url": "http://webhook.example", "id": "cfg-1", "taskId": "task-1"});
    RestClient c = check new (getServerBaseUrl());
    TaskPushNotificationConfig _ = check c->getTaskPushNotificationConfig({taskId: "task-1", id: "cfg-1"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs/cfg-1");
    test:assertEquals(req.queryParams.length(), 0, "both path params must be removed from the working param set so neither taskId nor id leaks into the query string");
}

@test:Config {}
function testRestListTaskPushNotificationConfigsSendsCorrectPathAndQuery() returns error? {
    setNextRestResponse({"configs": [], "nextPageToken": ""});
    RestClient c = check new (getServerBaseUrl());
    ListTaskPushNotificationConfigsResponse _ = check c->listTaskPushNotificationConfigs({taskId: "task-1", pageSize: 10, pageToken: "cursor-abc"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "GET");
    test:assertEquals(req.path, "/tasks/task-1/pushNotificationConfigs");
    test:assertEquals(req.queryParams["pageSize"], "10");
    test:assertEquals(req.queryParams["pageToken"], "cursor-abc");
}

@test:Config {}
function testRestSendStreamingMessageSendsCorrectPath() returns error? {
    setNextRestSseResponse([
        {'event: "message", data: string `{"task": {"id": "task-1", "status": {"state": "TASK_STATE_SUBMITTED"}}}`}
    ]);
    RestClient c = check new (getServerBaseUrl());
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});
    StreamResponse _ = check expectValue(s.next());
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST");
    test:assertEquals(req.path, "/message:stream");
}

@test:Config {}
function testRestOperationWithTenantPrefixesPath() returns error? {
    setNextRestResponse(defaultTaskJson());
    RestClient c = check new (getServerBaseUrl(), tenant = "acme-corp");
    Task _ = check c->getTask({id: "task-1"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.path, "/acme-corp/tasks/task-1");
}

@test:Config {}
function testRestPathParamWithSlashIsPercentEncodedNotLeftRaw() returns error? {
    // A taskId containing "/" must not be spliced into the path raw — it
    // would otherwise restructure the path into extra segments (or, for
    // other characters, into a bogus query string / path-traversal
    // shape). Confirms the value is percent-encoded, not left as-is.
    setNextRestResponse(defaultTaskJson());
    RestClient c = check new (getServerBaseUrl());
    Task _ = check c->getTask({id: "task/with/slashes"});
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.path, "/tasks/task%2Fwith%2Fslashes", "a '/' in a path param must be percent-encoded, not left raw to restructure the path into extra segments");
}

@test:Config {}
function testRestErrorResponseMapsToTypedError() returns error? {
    setNextRestResponse({
        "error": {"message": "no such task", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND"}]}
    }, statusCode = 404);
    RestClient c = check new (getServerBaseUrl());
    Task|error result = c->getTask({id: "nonexistent"});
    test:assertTrue(result is TaskNotFoundError);
}

@test:Config {}
function testRestSendMessageStreamDecodesBareStreamResponseNoEnvelope() returns error? {
    setNextRestSseResponse([
        {'event: "message", data: string `{"task": {"id": "task-1", "status": {"state": "TASK_STATE_SUBMITTED"}}}`}
    ]);
    RestClient c = check new (getServerBaseUrl());
    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> s = check c->sendStreamingMessage({message: msg});
    StreamResponse first = check expectValue(s.next());
    test:assertEquals((<Task>first).id, "task-1");
}

@test:Config {}
function testRestStreamErrorEventMapsToTypedError() returns error? {
    setNextRestSseResponse([
        {'event: "error", data: string `{"error": {"message": "boom", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "INVALID_AGENT_RESPONSE"}]}}`}
    ]);
    RestClient c = check new (getServerBaseUrl());
    stream<StreamResponse, error?> s = check c->subscribeToTask({id: "task-1"});
    record {| StreamResponse value; |}|error? result = s.next();
    test:assertTrue(result is InvalidAgentResponseError, "a named 'error' SSE frame must route through toA2AErrorFromRest and surface as the typed error, not attempt to parse it as a StreamResponse");
}

@test:Config {}
function testRestSubscribeToTaskRetriesWithPostOn405() returns error? {
    // Script the mock to reject GET with 405 for this one operation, then
    // accept POST — assert the client retries and succeeds, not that it
    // surfaces the 405 as an error.
    setNextRestSseResponse([
        {'event: "message", data: string `{"statusUpdate": {"taskId": "task-1", "contextId": "ctx-1", "status": {"state": "TASK_STATE_WORKING"}}}`}
    ]);
    setRestRejectMethod("GET", 405);
    RestClient c = check new (getServerBaseUrl());
    stream<StreamResponse, error?> s = check c->subscribeToTask({id: "task-1"});
    StreamResponse first = check expectValue(s.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).taskId, "task-1");
    record {| string method; string path; map<string> queryParams; |} req = getLastRestRequest();
    test:assertEquals(req.method, "POST", "after the 405, the retry must have actually used POST");
    test:assertEquals(req.path, "/tasks/task-1:subscribe", "the retried request must hit the same SubscribeToTask path, not some other operation's path");
}

@test:Config {}
function testRestFallbackDoesNotFireForOtherOperations() returns error? {
    // A 405 on any operation OTHER than SubscribeToTask must surface as
    // a normal error, not trigger a retry — the fallback is scoped to
    // exactly this one operation.
    setNextRestResponse({}, statusCode = 405);
    RestClient c = check new (getServerBaseUrl());
    Task|error result = c->getTask({id: "task-1"});
    test:assertTrue(result is error, "a 405 on GetTask must surface as an error, not silently retry with a different verb");
}

// Integration-level proof that decodeRawBytesFromWire is actually wired
// into getTask's response handling, not just unit-tested in isolation.
// Scripts the mock server to return a Task whose history contains a Part
// with a base64-encoded raw field — exactly what a real, spec-conformant
// v1.0 server would send on the wire — and confirms getTask correctly
// decodes it back to the original bytes.
//
@test:Config {}
function testGetTaskDecodesBase64EncodedPartRawFromRealisticServerResponse() returns error? {
    byte[] expectedBytes = "hello from a real server".toBytes();
    setNextRestResponse({
        id: "task-raw-1",
        status: {state: "TASK_STATE_COMPLETED"},
        history: [
            {
                messageId: "msg-1",
                role: "ROLE_AGENT",
                parts: [
                    {"raw": "aGVsbG8gZnJvbSBhIHJlYWwgc2VydmVy", mediaType: "application/octet-stream"}
                ]
            }
        ]
    });

    Client c = check new (getServerBaseUrl());
    Task task = check c->getTask({id: "task-raw-1"});

    Message[]? history = task?.history;
    test:assertTrue(history is Message[], "history should decode");
    Message[] hist = <Message[]>history;
    test:assertEquals(hist.length(), 1);
    Part firstPart = hist[0].parts[0];
    test:assertEquals(firstPart?.raw, expectedBytes, "Part.raw nested inside Task.history must be decoded from base64 back into the original bytes");
}

// Integration-level proof that encodeRawBytesForWire is actually wired
// into sendMessage's request encoding, not just unit-tested in isolation.
// Sends a Message containing a Part.raw value and confirms the wire body
// captured by getLastRestBody() carries it as a base64 string — not
// Ballerina's default integer-array shape, which no real server can parse.
//
@test:Config {}
function testSendMessageEncodesPartRawAsBase64OnTheWire() returns error? {
    setNextRestResponse({task: {id: "task-raw-2", status: {state: "TASK_STATE_COMPLETED"}}});

    Client c = check new (getServerBaseUrl());
    Message msg = {
        messageId: "msg-raw-1",
        role: ROLE_USER,
        parts: [
            {raw: "outbound file bytes".toBytes(), mediaType: "application/octet-stream"}
        ]
    };
    Task|Message _ = check c->sendMessage({message: msg});

    json params = getLastRestBody();
    map<json> messageMap = check params.message.ensureType();
    json[] parts = check messageMap["parts"].ensureType();
    map<json> firstPart = check parts[0].ensureType();
    test:assertTrue(firstPart["raw"] is string, "Part.raw in the outbound wire body must be a base64 string, not Ballerina's default integer-array shape");
}

// ---------------------------------------------------------------------------
// v1.0 SecurityScheme oneof parsing.
//
// A2A v1.0 models SecurityScheme as a protobuf oneof, so each scheme arrives
// wrapped in an arm key rather than carrying a `type` discriminator. Every
// pre-existing fixture in this suite uses the v0.3 `type` form, which is why
// the wrapper form went unnoticed: MutualTlsSecurityScheme requires no fields
// and defaults its `type`, so it matched every wrapper object and silently
// mislabelled it. These tests pin the v1.0 form down explicitly.
// ---------------------------------------------------------------------------

// Overrides the well-known card with a body whose securitySchemes are supplied raw.
isolated function setV10SchemeCard(json securitySchemes) {
    setWellKnownOverride({
        "name": "V1.0 Agent",
        "description": "Publishes oneof-wrapped security schemes",
        "version": "1.0.0",
        "capabilities": {},
        "supportedInterfaces": [{"url": "http://localhost:19199", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
        "securitySchemes": securitySchemes,
        "skills": []
    , "defaultInputModes": ["text"], "defaultOutputModes": ["text"]});
}

@test:Config {}
function testResolveAgentCardParsesV10CamelCaseSecuritySchemes() returns error? {
    setV10SchemeCard({
        "apiKeyAuth": {"apiKeySecurityScheme": {"location": "header", "name": "X-API-Key"}},
        "bearerAuth": {"httpAuthSecurityScheme": {"scheme": "bearer", "bearerFormat": "JWT"}},
        "oauth2Auth": {"oauth2SecurityScheme": {"flows": {}, "oauth2MetadataUrl": "https://auth.example.com/.well-known/oauth-authorization-server"}},
        "oidcAuth": {"openIdConnectSecurityScheme": {"openIdConnectUrl": "https://auth.example.com/.well-known/openid-configuration"}},
        "mtlsAuth": {"mtlsSecurityScheme": {}}
    });
    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertEquals((card.securitySchemes ?: {}).length(), 5, "all five oneof arms must parse");

    SecurityScheme apiKey = (card.securitySchemes ?: {}).get("apiKeyAuth");
    test:assertTrue(apiKey is ApiKeySecurityScheme, "apiKeySecurityScheme arm must parse as ApiKeySecurityScheme");
    if apiKey is ApiKeySecurityScheme {
        test:assertEquals(apiKey.'in, "header", "v1.0 `location` must be mapped onto the record's `in` field");
        test:assertEquals(apiKey.name, "X-API-Key");
    }

    SecurityScheme bearer = (card.securitySchemes ?: {}).get("bearerAuth");
    test:assertTrue(bearer is HttpAuthSecurityScheme);
    if bearer is HttpAuthSecurityScheme {
        test:assertEquals(bearer.scheme, "bearer");
        test:assertEquals(bearer?.bearerFormat, "JWT");
    }

    SecurityScheme oidc = (card.securitySchemes ?: {}).get("oidcAuth");
    test:assertTrue(oidc is OpenIdConnectSecurityScheme);
    if oidc is OpenIdConnectSecurityScheme {
        test:assertEquals(oidc.openIdConnectUrl, "https://auth.example.com/.well-known/openid-configuration");
    }

    test:assertTrue((card.securitySchemes ?: {}).get("oauth2Auth") is OAuth2SecurityScheme);
    test:assertTrue((card.securitySchemes ?: {}).get("mtlsAuth") is MutualTlsSecurityScheme);
}

@test:Config {}
function testResolveAgentCardParsesV10SnakeCaseSecuritySchemes() returns error? {
    // The spec schema accepts every arm under a snake_case spelling too, and
    // the multi-word scheme fields likewise.
    setV10SchemeCard({
        "apiKeyAuth": {"api_key_security_scheme": {"location": "header", "name": "X-API-Key"}},
        "bearerAuth": {"http_auth_security_scheme": {"scheme": "bearer", "bearer_format": "JWT"}},
        "oidcAuth": {"open_id_connect_security_scheme": {"open_id_connect_url": "https://auth.example.com/.well-known/openid-configuration"}},
        "mtlsAuth": {"mtls_security_scheme": {}}
    });
    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertEquals((card.securitySchemes ?: {}).length(), 4);

    SecurityScheme apiKey = (card.securitySchemes ?: {}).get("apiKeyAuth");
    test:assertTrue(apiKey is ApiKeySecurityScheme);
    if apiKey is ApiKeySecurityScheme {
        test:assertEquals(apiKey.'in, "header");
    }

    SecurityScheme bearer = (card.securitySchemes ?: {}).get("bearerAuth");
    test:assertTrue(bearer is HttpAuthSecurityScheme);
    if bearer is HttpAuthSecurityScheme {
        test:assertEquals(bearer?.bearerFormat, "JWT", "snake_case bearer_format must be normalized onto bearerFormat");
    }

    SecurityScheme oidc = (card.securitySchemes ?: {}).get("oidcAuth");
    test:assertTrue(oidc is OpenIdConnectSecurityScheme);
    if oidc is OpenIdConnectSecurityScheme {
        test:assertEquals(oidc.openIdConnectUrl, "https://auth.example.com/.well-known/openid-configuration",
                "snake_case open_id_connect_url must be normalized onto openIdConnectUrl");
    }
}

@test:Config {}
function testResolveAgentCardParsesV10MixedSpellingSecuritySchemes() returns error? {
    setV10SchemeCard({
        "apiKeyAuth": {"apiKeySecurityScheme": {"location": "query", "name": "api_key"}},
        "bearerAuth": {"http_auth_security_scheme": {"scheme": "bearer"}}
    });
    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertEquals((card.securitySchemes ?: {}).length(), 2, "a card mixing both spellings must parse both");
    SecurityScheme apiKey = (card.securitySchemes ?: {}).get("apiKeyAuth");
    test:assertTrue(apiKey is ApiKeySecurityScheme);
    if apiKey is ApiKeySecurityScheme {
        test:assertEquals(apiKey.'in, "query");
    }
    test:assertTrue((card.securitySchemes ?: {}).get("bearerAuth") is HttpAuthSecurityScheme);
}

@test:Config {}
function testResolveAgentCardV10ApiKeyLocationIsCaseInsensitive() returns error? {
    // The proto documents lowercase values, but a server rendering the field
    // from a protobuf enum can emit other casing; the reference Python SDK
    // lowercases before comparing, so this client accepts the same range.
    setV10SchemeCard({
        "apiKeyAuth": {"apiKeySecurityScheme": {"location": "HEADER", "name": "X-API-Key"}}
    });
    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    SecurityScheme apiKey = (card.securitySchemes ?: {}).get("apiKeyAuth");
    test:assertTrue(apiKey is ApiKeySecurityScheme, "an uppercase location must still resolve, not be dropped");
    if apiKey is ApiKeySecurityScheme {
        test:assertEquals(apiKey.'in, "header", "location must be normalized to lowercase");
    }
}

@test:Config {}
function testResolveAgentCardDropsV10ApiKeyWithInvalidLocation() returns error? {
    // An out-of-range location is dropped rather than failing the whole card
    // parse — the same tolerant contract every other securitySchemes entry
    // gets — but it must never fall through and be mislabelled instead.
    setV10SchemeCard({
        "apiKeyAuth": {"apiKeySecurityScheme": {"location": "somewhere-else", "name": "X-API-Key"}},
        "bearerAuth": {"httpAuthSecurityScheme": {"scheme": "bearer"}}
    });
    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertFalse((card.securitySchemes ?: {}).hasKey("apiKeyAuth"), "an invalid apiKey location must drop that entry");
    test:assertTrue((card.securitySchemes ?: {}).hasKey("bearerAuth"), "one bad entry must not cost the rest of the card");
}

@test:Config {}
function testResolveAgentCardV10SchemesAreNeverMislabelledAsMutualTls() returns error? {
    // Direct regression guard on the original defect: before the oneof was
    // handled, both of these parsed as MutualTlsSecurityScheme, which made
    // buildAuthFromCard refuse to wire any credential.
    setV10SchemeCard({
        "apiKeyAuth": {"apiKeySecurityScheme": {"location": "header", "name": "X-API-Key"}},
        "bearerAuth": {"httpAuthSecurityScheme": {"scheme": "bearer"}}
    });
    AgentCard|error result = resolveAgentCard(getServerBaseUrl());
    setWellKnownOverride(());
    AgentCard card = check result;

    test:assertFalse((card.securitySchemes ?: {}).get("apiKeyAuth") is MutualTlsSecurityScheme,
            "a v1.0 apiKey scheme must not be mislabelled as mutual TLS");
    test:assertFalse((card.securitySchemes ?: {}).get("bearerAuth") is MutualTlsSecurityScheme,
            "a v1.0 http auth scheme must not be mislabelled as mutual TLS");
}

// ---------------------------------------------------------------------------
// getExtendedAgentCard short-circuiting.
//
// There is no request counter on the mock, so "no request was sent" is
// asserted by making a known call first and then checking that the last
// request the mock saw is still that one.
// ---------------------------------------------------------------------------

// Builds a minimal AgentCard declaring a given extendedAgentCard capability.
// The supportedInterfaces entry is required, not decorative: a card without
// one is treated as a pre-1.0 legacy card by detectProtocolModeForBinding,
// which would put the Client in V0_3 mode and change the wire method names.
isolated function cardWithExtendedSupport(boolean supported, string name = "Held Card") returns AgentCard => {
    name,
    description: "d",
    version: "1.0.0",
    capabilities: {extendedAgentCard: supported},
    supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}],
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"]
};

// Sends one getTask so the mock's last-seen request is a known,
// distinguishable one, then returns the path it recorded. The REST binding
// names its operation in the path, so that is what identifies the request.
isolated function primeLastRequest(Client c) returns string|error {
    setNextRestResponse({id: "t-prime", contextId: "c1", status: {state: "TASK_STATE_COMPLETED"}});
    Task _ = check c->getTask({id: "t-prime"});
    return getLastRestRequest().path;
}

@test:Config {}
function testGetExtendedAgentCardRejectsWhenCapabilityFalse() returns error? {
    // Renamed from ...ShortCircuitsWhenCapabilityFalse, which asserted that
    // the held public card was returned instead. Specification section 3.3.4
    // requires the opposite, and says so again in sections 3.1.11 and 13.3:
    // when capabilities.extendedAgentCard is false or not present, this
    // operation MUST return UnsupportedOperationError. Handing back the
    // public card gave the caller something other than what they asked for,
    // with no way to tell.
    Client c = check new (cardWithExtendedSupport(false, "Public Card"));
    string primedPath = check primeLastRequest(c);
    test:assertEquals(primedPath, "/tasks/t-prime");

    AgentCard|Error card = c->getExtendedAgentCard();

    test:assertTrue(card is UnsupportedOperationError,
            "specification section 3.3.4 requires UnsupportedOperationError, not the public card");
    test:assertEquals(getLastRestRequest().path, "/tasks/t-prime",
            "and the rejection is client-side: no GetExtendedAgentCard request is produced");
}

@test:Config {}
function testGetExtendedAgentCardCallsOutWhenCapabilityTrue() returns error? {
    Client c = check new (cardWithExtendedSupport(true, "Public Card"));
    setNextRestResponse({
        name: "Extended Card",
        description: "d",
        version: "1.0.0",
        capabilities: {extendedAgentCard: true},
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    , supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}]});

    AgentCard card = check c->getExtendedAgentCard();

    test:assertEquals(card.name, "Extended Card");
    test:assertEquals(getLastRestRequest().path, "/extendedAgentCard",
            "a card declaring the capability must still make the call");
}

@test:Config {}
function testGetExtendedAgentCardStoresFetchedCard() returns error? {
    // The fetched card replaces the held one, so a second call reasons about
    // the extended card rather than the public card the Client started with.
    Client c = check new (cardWithExtendedSupport(true, "Public Card"));
    setNextRestResponse({
        name: "Extended Card",
        description: "d",
        version: "1.0.0",
        capabilities: {extendedAgentCard: false},
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    , supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}]});
    AgentCard first = check c->getExtendedAgentCard();
    test:assertEquals(first.name, "Extended Card");

    string primedPath = check primeLastRequest(c);
    test:assertEquals(primedPath, "/tasks/t-prime");

    AgentCard|Error second = c->getExtendedAgentCard();

    // The fetched card was stored, and it declares extendedAgentCard=false,
    // so the second call is now rejected on that stored card rather than
    // returning it. That the rejection happens at all is the proof the
    // fetched card replaced the held one -- the original card declared
    // extendedAgentCard=true and would not have been rejected.
    test:assertTrue(second is UnsupportedOperationError,
            "the stored extended card declares extendedAgentCard=false, so a second call is rejected");
    test:assertEquals(getLastRestRequest().path, "/tasks/t-prime",
            "and the rejection is client-side: no second GetExtendedAgentCard request is produced");
}

// ---- issue #11: client-side capability gating -------------------------
//
// streaming and pushNotifications follow the same "denied only when a card
// exists and explicitly says false" gate as extendedAgentCard above
// (cardDeniesStreaming/cardDeniesPushNotifications in operations.bal),
// with two differences in what "denied" does: sendStreamingMessage falls
// back to a single-event unary call rather than erroring, and
// deleteTaskPushNotificationConfig is deliberately never gated at all
// (deletion is idempotent per specification section 3.1.10).

isolated function cardWithStreamingSupport(boolean supported) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0",
    capabilities: {streaming: supported},
    supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}],
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"]
};

isolated function cardWithPushNotificationsSupport(boolean supported) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0",
    capabilities: {pushNotifications: supported},
    supportedInterfaces: [{url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}],
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"]
};

@test:Config {}
function testSendStreamingMessageFallsBackToUnaryWhenStreamingDenied() returns error? {
    Client c = check new (cardWithStreamingSupport(false));
    setNextRestResponse({task: defaultTaskJson()});

    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({message: msg});

    test:assertEquals(getLastRestRequest().path, "/message:send",
            "a card declaring streaming=false must fall back to a unary call, not open a streaming one");

    StreamResponse first = check expectValue(events.next());
    assertValidTask(<Task>first);

    record {| StreamResponse value; |}|error? second = events.next();
    test:assertTrue(second is (), "the fallback stream must yield exactly one event, then close");
}

@test:Config {}
function testSendStreamingMessageFallbackWrapsMessageReply() returns error? {
    // The fallback's unary call can come back as a Message just as easily
    // as a Task - both SendMessageResult variants per specification
    // section 3.1.1 must wrap correctly.
    Client c = check new (cardWithStreamingSupport(false));
    setNextRestResponse({message: {messageId: "reply-1", role: "ROLE_AGENT", parts: [{text: "a direct reply"}]}});

    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({message: msg});

    StreamResponse first = check expectValue(events.next());
    Message? reply = first is Message ? first : ();
    test:assertTrue(reply is Message, "the wrapped fallback event should carry the Message reply");
    test:assertEquals((<Message>reply).messageId, "reply-1");
}

@test:Config {}
function testSendStreamingMessageOpensRealStreamWhenStreamingSupported() returns error? {
    // Regression guard: a card that supports streaming must be unaffected.
    Client c = check new (cardWithStreamingSupport(true));
    setNextRestSseResponse([{data: taskJson("task-1", "TASK_STATE_COMPLETED")}]);

    Message msg = {messageId: "m1", role: ROLE_USER, parts: [{text: "hi"}]};
    stream<StreamResponse, error?> _ = check c->sendStreamingMessage({message: msg});

    test:assertEquals(getLastRestRequest().path, "/message:stream",
            "a card declaring streaming=true must open the real streaming call, not fall back");
}

@test:Config {}
function testSubscribeToTaskRejectsClientSideWhenStreamingDenied() returns error? {
    // Unlike sendStreamingMessage, subscribing has no unary equivalent to
    // fall back to, so this must hard-error - and without ever reaching
    // the wire, per the issue's "no wasted round trips" requirement.
    Client c = check new (cardWithStreamingSupport(false));
    string primedPath = check primeLastRequest(c);
    test:assertEquals(primedPath, "/tasks/t-prime");

    stream<StreamResponse, error?>|error result = c->subscribeToTask({id: "task-1"});

    test:assertTrue(result is UnsupportedOperationError,
            "a card declaring streaming=false must reject subscribeToTask client-side");
    test:assertEquals(getLastRestRequest().path, "/tasks/t-prime",
            "subscribeToTask must not reach the wire when the card denies streaming");
}

@test:Config {}
function testCreateTaskPushNotificationConfigRejectsClientSideWhenDenied() returns error? {
    Client c = check new (cardWithPushNotificationsSupport(false));
    string primedPath = check primeLastRequest(c);

    TaskPushNotificationConfig|error result = c->createTaskPushNotificationConfig(
            {url: "https://client.example.com/webhooks/a2a", taskId: "task-1"});

    test:assertTrue(result is PushNotificationNotSupportedError,
            "a card declaring pushNotifications=false must reject createTaskPushNotificationConfig client-side");
    test:assertEquals(getLastRestRequest().path, primedPath,
            "createTaskPushNotificationConfig must not reach the wire when the card denies the capability");
}

@test:Config {}
function testGetTaskPushNotificationConfigRejectsClientSideWhenDenied() returns error? {
    Client c = check new (cardWithPushNotificationsSupport(false));
    string primedPath = check primeLastRequest(c);

    TaskPushNotificationConfig|error result = c->getTaskPushNotificationConfig({taskId: "task-1", id: "webhook-1"});

    test:assertTrue(result is PushNotificationNotSupportedError,
            "a card declaring pushNotifications=false must reject getTaskPushNotificationConfig client-side");
    test:assertEquals(getLastRestRequest().path, primedPath,
            "getTaskPushNotificationConfig must not reach the wire when the card denies the capability");
}

@test:Config {}
function testListTaskPushNotificationConfigsRejectsClientSideWhenDenied() returns error? {
    Client c = check new (cardWithPushNotificationsSupport(false));
    string primedPath = check primeLastRequest(c);

    ListTaskPushNotificationConfigsResponse|error result = c->listTaskPushNotificationConfigs({taskId: "task-1"});

    test:assertTrue(result is PushNotificationNotSupportedError,
            "a card declaring pushNotifications=false must reject listTaskPushNotificationConfigs client-side");
    test:assertEquals(getLastRestRequest().path, primedPath,
            "listTaskPushNotificationConfigs must not reach the wire when the card denies the capability");
}

@test:Config {}
function testDeleteTaskPushNotificationConfigIsGatedLikeTheOtherThree() returns error? {
    // Renamed from ...StillSendsWhenDenied, which asserted that delete was
    // deliberately ungated on the grounds that deletion is idempotent per
    // specification section 3.1.10. That conflated two rules: 3.1.10 is
    // about repeated deletes of the same config having the same effect, and
    // says nothing about capability gating. Section 3.3.4 names this
    // operation explicitly among the four that MUST return
    // PushNotificationNotSupportedError when the capability is false or not
    // present.
    Client c = check new (cardWithPushNotificationsSupport(false));

    error? result = c->deleteTaskPushNotificationConfig({taskId: "task-1", id: "webhook-1"});

    test:assertTrue(result is PushNotificationNotSupportedError,
            "specification section 3.3.4 lists Delete among the gated config operations");
}

// ---- v0.3 multi-transport card normalization -------------------------

// ---- v0.3 extended-card-support normalization -------------------------

// A v1.0 card already declares supportedInterfaces and must pass through
// untouched, even on the vanishingly unlikely chance it also carries a
// legacy field.
@test:Config {}
function testV10CardSupportedInterfacesAreNeverRewritten() returns error? {
    AgentCard card = check parseAgentCardBody({
        "name": "modern", "description": "d", "version": "1.0",
        "url": "http://agent.example/legacy",
        "preferredTransport": "GRPC",
        "supportedInterfaces": [
            {"url": "http://agent.example/rpc", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}
        ],
        "capabilities": {}, "skills": []
    , "defaultInputModes": ["text"], "defaultOutputModes": ["text"]});

    test:assertEquals(card.supportedInterfaces.length(), 1,
            "a card that already declares supportedInterfaces is v1.0-native; the legacy fields must not be merged in");
    test:assertEquals(card.supportedInterfaces[0].protocolBinding, "JSONRPC");
}


// ---- specification 8.6.2: Agent Card caching --------------------------

// Regression: parseAgentCardBody must not mutate the body it is given.
// `ensureType` casts without cloning, so the field removals inside the parser
// used to strip signatures/securitySchemes/securityRequirements out of the
// caller's own JSON -- which fetchAgentCardBody hands out specifically so it
// can be kept for signature verification.
@test:Config {}
function testParseAgentCardBodyDoesNotMutateItsInput() returns error? {
    json body = {
        "name": "n",
        "description": "d",
        "version": "1.0.0",
        "capabilities": {},
        "supportedInterfaces": [
            {"url": "http://localhost:19199", "protocolBinding": "HTTP+JSON", "protocolVersion": "1.0"}
        ],
        "skills": [{"id": "s", "name": "S", "description": "d", "tags": []}],
        "defaultInputModes": ["text"],
        "defaultOutputModes": ["text"],
        "securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer"}},
        "securityRequirements": [{"bearerAuth": []}],
        "signatures": [{"protected": "eyJhbGciOiJSUzI1NiJ9", "signature": "sig"}]
    };
    json before = body.clone();

    AgentCard _ = check parseAgentCardBody(body);

    test:assertEquals(body, before,
            "parseAgentCardBody must leave the caller's raw body untouched; it is kept for signature verification");
}

// Regression: requireV1Interface tested only for a "0." prefix, so a card
// declaring "2.0" was accepted and would have been spoken to with v1.0 paths
// and an A2A-Version: 1.0 header.
isolated function cardDeclaringVersion(string version) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0", capabilities: {},
    supportedInterfaces: [
        {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: version}
    ],
    skills: [], defaultInputModes: ["text"], defaultOutputModes: ["text"]
};

@test:Config {}
function testInterfaceProtocolVersionIsBoundedToTheOneLine() {
    test:assertTrue(requireV1Interface(cardDeclaringVersion("1.0"), HTTP_JSON) is (), "1.0 is what this client implements");
    test:assertTrue(requireV1Interface(cardDeclaringVersion("1.1"), HTTP_JSON) is (), "a later 1.x revision stays additive");
    test:assertTrue(requireV1Interface(cardDeclaringVersion("0.3"), HTTP_JSON) is VersionNotSupportedError, "0.x must be rejected");
    test:assertTrue(requireV1Interface(cardDeclaringVersion("2.0"), HTTP_JSON) is VersionNotSupportedError,
            "2.0 must be rejected rather than spoken to with v1.0 paths");
}
