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

// `a2a:Client` chooses a binding from the Agent Card and hands every operation to it. The binding is chosen by
// `selectClientBinding`, tested on cards alone; delegation is tested against the JSON-RPC stub of
// `jsonrpc_client_failure_test.bal`.

import ballerina/test;

isolated function bindingCard(AgentInterface[] interfaces) returns AgentCard => {
    name: "Binding Agent",
    description: "A card that is never fetched",
    version: "1.0.0",
    skills: [],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: interfaces
};

isolated function interfaceOf(string binding, string version = "1.0") returns AgentInterface =>
    {url: "http://localhost:1", protocolBinding: binding, protocolVersion: version};

@test:Config {}
function testSelectClientBindingFollowsTheCardsOrder() returns error? {
    test:assertEquals(check selectClientBinding(bindingCard([interfaceOf("JSONRPC"), interfaceOf("HTTP+JSON")]), ()),
            "JSONRPC");
    test:assertEquals(check selectClientBinding(bindingCard([interfaceOf("HTTP+JSON"), interfaceOf("JSONRPC")]), ()),
            "HTTP+JSON");
    test:assertEquals(check selectClientBinding(bindingCard([interfaceOf("GRPC"), interfaceOf("JSONRPC")]), ()),
            "JSONRPC");
}

@test:Config {}
function testSelectClientBindingHonoursAPreferenceTheCardOffers() returns error? {
    AgentCard card = bindingCard([interfaceOf("JSONRPC"), interfaceOf("HTTP+JSON")]);
    test:assertEquals(check selectClientBinding(card, "HTTP+JSON"), "HTTP+JSON");
    test:assertEquals(check selectClientBinding(bindingCard([interfaceOf("JSONRPC")]), "HTTP+JSON"), "JSONRPC");
}

@test:Config {}
function testSelectClientBindingSkipsAnInterfaceOfAnotherVersion() returns error? {
    AgentCard card = bindingCard([interfaceOf("JSONRPC", "0.3"), interfaceOf("HTTP+JSON")]);
    test:assertEquals(check selectClientBinding(card, ()), "HTTP+JSON");
}

@test:Config {}
function testSelectClientBindingNamesWhatTheCardOffers() {
    ClientBinding|Error grpc = selectClientBinding(bindingCard([interfaceOf("GRPC")]), ());
    test:assertTrue(grpc is Error && grpc.message().includes("it offers: GRPC"), "gRPC alone is not spoken");
    ClientBinding|Error none = selectClientBinding(bindingCard([]), ());
    test:assertTrue(none is Error && none.message().includes("it offers: none"));
    ClientBinding|Error oldOnly = selectClientBinding(bindingCard([interfaceOf("JSONRPC", "0.3")]), ());
    test:assertTrue(oldOnly is Error, "a 0.3 interface is not spoken");
}

@test:Config {}
function testClientTakesTheBindingTheCardOffers() returns error? {
    Client rpc = check new (stubCard());
    test:assertEquals(rpc.getBinding(), "JSONRPC");
    // A preference the card does not offer is not an error: the card's own binding is used.
    Client fallback = check new (stubCard(), preferredBinding = "HTTP+JSON");
    test:assertEquals(fallback.getBinding(), "JSONRPC");
    // Given only an agent's address, the card is fetched and read the same way.
    Client fetched = check new (string `http://localhost:${JSON_RPC_STUB_PORT}`);
    test:assertEquals(fetched.getBinding(), "JSONRPC");
    Client rest = check new (cardAt(tokenStubUrl));
    test:assertEquals(rest.getBinding(), "HTTP+JSON");
}

@test:Config {}
function testClientRefusesACardOfferingNoBindingItSpeaks() {
    Client|Error refused = new (bindingCard([interfaceOf("GRPC")]));
    test:assertTrue(refused is Error, "a gRPC-only card cannot be used");
}

// Every operation through `a2a:Client`: the stub answers each, and what comes back is what the JSON-RPC client read.
@test:Config {}
function testClientDelegatesEveryOperation() returns error? {
    AgentCard card = stubCard();
    card.capabilities.pushNotifications = true;
    Client c = check new (card);
    SendMessageRequest request = {message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}};

    Task|Message sent = check c->sendMessage(request);
    test:assertTrue(sent is Task);
    Task fetched = check c->getTask({id: "t-1"});
    test:assertEquals(fetched.id, "t-1");
    Task cancelled = check c->cancelTask({id: "t-1"});
    test:assertEquals(cancelled.status.state, TASK_STATE_CANCELED);
    ListTasksResponse listed = check c->listTasks({pageSize: 5});
    test:assertEquals(listed.tasks.length(), 1);
    ListTasksResponse everything = check c->listTasks();
    test:assertEquals(everything.tasks.length(), 1, "listTasks takes no request at all");

    stream<StreamResponse, Error?> subscribed = check c->subscribeToTask({id: "s1"});
    test:assertTrue(check subscribed.next() is record {|StreamResponse value;|});
    test:assertTrue(check subscribed.next() is (), "the completed task ends the subscription");
    stream<StreamResponse, Error?> streamed = check c->sendStreamingMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "stream-ok"}]}
    });
    test:assertTrue(check streamed.next() is record {|StreamResponse value;|});
    test:assertTrue(check streamed.next() is record {|StreamResponse value;|});
    test:assertTrue(check streamed.next() is ());

    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        taskId: "t-1", url: "https://example.com/hook"
    });
    test:assertEquals(config?.id, "cfg-1");
    TaskPushNotificationConfig got = check c->getTaskPushNotificationConfig({taskId: "t-1", id: "cfg-1"});
    test:assertEquals(got.url, "https://example.com/hook");
    ListTaskPushNotificationConfigsResponse configs = check c->listTaskPushNotificationConfigs({taskId: "t-1"});
    test:assertEquals((configs.configs ?: []).length(), 0);
    check c->deleteTaskPushNotificationConfig({taskId: "t-1", id: "cfg-1"});

    AgentCard|Error extended = c->getExtendedAgentCard();
    test:assertTrue(extended is UnsupportedOperationError, "the card says there is no extended card");
}

@test:Config {}
function testJsonRpcClientBuiltFromAnAddressFetchesItsCard() returns error? {
    JsonRpcClient c = check new (string `http://localhost:${JSON_RPC_STUB_PORT}`);
    Task task = check c->getTask({id: "from-address"});
    test:assertEquals(task.id, "from-address");
    Task|Message sent = check c->sendMessage({message: {messageId: "m", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(sent is Task);
}

@test:Config {}
function testJsonRpcClientRejectsAStreamEventWithNeitherResultNorError() returns error? {
    stream<StreamResponse, Error?> events = check stubStreamOf("stream-no-result");
    test:assertTrue(check events.next() is record {|StreamResponse value;|});
    test:assertTrue(events.next() is InvalidAgentResponseError, "an event with no payload ends the stream");
}
