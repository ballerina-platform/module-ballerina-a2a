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

// The operations and failures of the JSON-RPC binding that the other JSON-RPC
// tests do not reach: push-notification configs, subscribe, the extended
// card, operations outside the card's capabilities, and malformed envelopes.

const int RPC_SEND_ONLY_TEST_PORT = 19320;
const int RPC_EXTENDED_CARD_TEST_PORT = 19321;

listener JsonRpcListener rpcSendOnlyListener = new (RPC_SEND_ONLY_TEST_PORT);

listener JsonRpcListener rpcExtendedCardListener = new (RPC_EXTENDED_CARD_TEST_PORT,
        auth = [{jwtValidatorConfig: authTestJwtValidator}]);

@test:BeforeSuite
function startJsonRpcOperationServers() returns error? {
    check rpcSendOnlyListener.attach(new SendOnlyRpcService());
    DefaultHandler handler = new (new CountingAgent(), extendedAgentCard = rpcTestCard);
    check rpcExtendedCardListener.attach(new RpcExtendedCardService(handler));
}

isolated function rpcCallTo(int port, string method, json params, string? authorization = ()) returns json|error {
    http:Client rpcClient = check new (string `http://localhost:${port}`, httpVersion = http:HTTP_1_1);
    map<string> headers = {"A2A-Version": "1.0"};
    if authorization is string {
        headers["Authorization"] = authorization;
    }
    http:Response response = check rpcClient->post("/rpc", {jsonrpc: "2.0", id: "op-1", method, params}, headers);
    return response.getJsonPayload();
}

@test:Config {}
function testPushNotificationConfigsOverJsonRpc() returns error? {
    json sent = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", rpcSendParams("rpc-push-1"));
    string taskId = check (check sent.result.task.id).ensureType();

    json created = check rpcCall(JSON_RPC_TEST_PORT, "CreateTaskPushNotificationConfig",
            {taskId, url: "https://example.com/hook"});
    string configId = check (check created.result.id).ensureType();

    json fetched = check rpcCall(JSON_RPC_TEST_PORT, "GetTaskPushNotificationConfig", {taskId, id: configId});
    test:assertEquals(check fetched.result.url, "https://example.com/hook");

    json listed = check rpcCall(JSON_RPC_TEST_PORT, "ListTaskPushNotificationConfigs", {taskId});
    json[] configs = <json[]>check listed.result.configs;
    test:assertEquals(configs.length(), 1);

    json deleted = check rpcCall(JSON_RPC_TEST_PORT, "DeleteTaskPushNotificationConfig", {taskId, id: configId});
    test:assertEquals(check deleted.result, {});

    json gone = check rpcCall(JSON_RPC_TEST_PORT, "GetTaskPushNotificationConfig", {taskId, id: configId});
    test:assertEquals(check gone.'error.code, -32001, "a deleted config is not found");
}

@test:Config {}
function testSubscribingToAnUnknownTaskOverJsonRpcIsNotFound() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "SubscribeToTask", {id: "no-such-task"});
    test:assertEquals(check reply.'error.code, -32001);
}

// A service that defines only sendMessage advertises neither streaming nor push
// notifications, and refuses both with their own codes.
@test:Config {}
function testOperationsOutsideTheCardsCapabilitiesAreRefusedOverJsonRpc() returns error? {
    foreach string method in ["SendStreamingMessage", "SubscribeToTask"] {
        json params = method == "SubscribeToTask" ? {id: "any"} : rpcSendParams("rpc-no-stream");
        json reply = check rpcCallTo(RPC_SEND_ONLY_TEST_PORT, method, params);
        test:assertEquals(check reply.'error.code, -32004, method);
    }
    foreach string method in ["CreateTaskPushNotificationConfig", "GetTaskPushNotificationConfig",
            "ListTaskPushNotificationConfigs", "DeleteTaskPushNotificationConfig"] {
        json reply = check rpcCallTo(RPC_SEND_ONLY_TEST_PORT, method,
                {taskId: "any", id: "any", url: "https://example.com/hook"});
        test:assertEquals(check reply.'error.code, -32003, method);
    }
    map<json> inlinePush = <map<json>>rpcSendParams("rpc-inline-push");
    inlinePush["configuration"] = {taskPushNotificationConfig: {url: "https://example.com/hook"}};
    json reply = check rpcCallTo(RPC_SEND_ONLY_TEST_PORT, "SendMessage", inlinePush);
    test:assertEquals(check reply.'error.code, -32003, "an inline push config needs push notifications");
}

// The extended card names the JSON-RPC interface at the address it was fetched from.
@test:Config {}
function testTheExtendedCardOverJsonRpc() returns error? {
    string authorization = "Bearer " + check bearerToken("alice");
    json reply = check rpcCallTo(RPC_EXTENDED_CARD_TEST_PORT, "GetExtendedAgentCard", {}, authorization);
    json[] interfaces = <json[]>check reply.result.supportedInterfaces;
    test:assertEquals(check interfaces[0].protocolBinding, "JSONRPC");
    test:assertEquals(check interfaces[0].url, string `http://localhost:${RPC_EXTENDED_CARD_TEST_PORT}/rpc`);
    test:assertEquals(check reply.result.capabilities.extendedAgentCard, true);
}

@test:Config {}
function testAnEnvelopeThatIsNotJsonRpc2IsAnInvalidRequest() returns error? {
    http:Response wrongVersion = check rpcPost({jsonrpc: "1.0", id: "v1", method: "GetTask", params: {id: "x"}});
    json reply = check wrongVersion.getJsonPayload();
    test:assertEquals(check reply.'error.code, -32600);
    test:assertEquals(check reply.id, "v1");

    http:Client rpcClient = check new (string `http://localhost:${JSON_RPC_TEST_PORT}`, httpVersion = http:HTTP_1_1);
    http:Response batch = check rpcClient->post("/rpc", [{jsonrpc: "2.0", id: 1, method: "ListTasks"}],
            {"A2A-Version": "1.0"});
    json batchReply = check batch.getJsonPayload();
    test:assertEquals(check batchReply.'error.code, -32600, "a batch is not served");
    test:assertEquals(check batchReply.id, ());
}

@test:Config {}
function testParamsThatDoNotMatchTheMethodAreInvalidParams() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "GetTask", {id: 5});
    test:assertEquals(check reply.'error.code, -32602);
}

@test:Config {}
function testATenantTheAgentDoesNotServeIsInvalidParamsOverJsonRpc() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {tenant: "acme"});
    test:assertEquals(check reply.'error.code, -32602);
}

// An error that carries no code of its own is mapped by its type.
@test:Config {}
function testEveryA2aErrorTypeHasItsJsonRpcCode() {
    [Error, int][] cases = [
        [error TaskNotFoundError("e"), -32001],
        [error TaskNotCancelableError("e"), -32002],
        [error PushNotificationNotSupportedError("e"), -32003],
        [error UnsupportedOperationError("e"), -32004],
        [error ContentTypeNotSupportedError("e"), -32005],
        [error InvalidAgentResponseError("e"), -32006],
        [error ExtendedAgentCardNotConfiguredError("e"), -32007],
        [error ExtensionSupportRequiredError("e"), -32008],
        [error VersionNotSupportedError("e"), -32009],
        [error InternalError("e"), -32603],
        [error InternalError("e", code = -32050), -32050]
    ];
    foreach [Error, int] [err, code] in cases {
        test:assertEquals(jsonRpcCodeOf(err), code, err.message());
    }
}

@test:Config {}
function testAJsonRpcListenerAcceptsItsPathInEveryForm() {
    test:assertEquals(checkMountPath(()), ());
    test:assertEquals(checkMountPath("/rpc"), ());
    test:assertEquals(checkMountPath(["rpc"]), ());
    test:assertTrue(checkMountPath(["rpc", "v2"]) is Error, "only /rpc is served");
}

// A stream that replays a fixed list of items, to drive the SSE framing
// without a live task behind it.
isolated class ScriptedStreamEvents {
    private final (record {| StreamResponse value; |}|Error)[] items;
    private int position = 0;

    isolated function init((record {| StreamResponse value; |}|Error)[] items) {
        self.items = items.clone();
    }

    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        lock {
            if self.position >= self.items.length() {
                return;
            }
            self.position += 1;
            return self.items[self.position - 1].clone();
        }
    }
}

isolated function framedBy(json id, (record {| StreamResponse value; |}|Error)[] items)
        returns JsonRpcSseFramingGenerator {
    stream<StreamResponse, Error?> events = new (new ScriptedStreamEvents(items));
    return new (events, id);
}

isolated function framedData(record {| http:SseEvent value; |}|error? frame) returns json|error {
    if frame is record {| http:SseEvent value; |} {
        string data = frame.value.data ?: "";
        return data.fromJsonString();
    }
    return error("expected a frame");
}

@test:Config {}
function testAKeepAliveTickIsAnSseComment() returns error? {
    JsonRpcSseFramingGenerator generator = framedBy("tick-1", [error KeepAliveTick("tick")]);
    record {| http:SseEvent value; |}|error? frame = generator.next();
    test:assertTrue(frame is record {| http:SseEvent value; |}, "a tick is framed");
    if frame is record {| http:SseEvent value; |} {
        test:assertEquals(frame.value.comment, "keep-alive");
        test:assertEquals(frame.value.data, (), "a comment carries no data");
    }
}

// A failure is the stream's last frame, an error object carrying the request's id.
@test:Config {}
function testAStreamFailureIsTheLastFrameAsAJsonRpcError() returns error? {
    JsonRpcSseFramingGenerator generator = framedBy("fail-1", [error InternalError("the agent failed")]);
    json failure = check framedData(generator.next());
    test:assertEquals(check failure.id, "fail-1");
    test:assertEquals(check failure.'error.code, -32603);
    test:assertEquals(check failure.'error.message, "the agent failed");
    test:assertEquals(generator.next(), (), "nothing follows a failure");
}

@test:Config {}
function testAnEmptyStreamEndsAndStaysEnded() {
    JsonRpcSseFramingGenerator generator = framedBy("end-1", []);
    test:assertEquals(generator.next(), (), "an empty stream ends");
    test:assertEquals(generator.next(), (), "and stays ended");
}

// Two listeners on one http:Listener publish one card, so a second service
// declaring a different card is refused.
@test:Config {}
function testListenersSharingACardMustDeclareTheSameCard() returns error? {
    http:Listener shared = check new (19323);
    RestListener restListener = check new (shared);
    JsonRpcListener rpcListener = check new (shared);
    DefaultHandler handler = new (new CountingAgent());
    check restListener.attach(new FullService(handler, rpcTestCard));
    AgentCard another = {...rpcTestCard};
    another.name = "Another Agent";
    error? rejected = rpcListener.attach(new RpcService(handler, another));
    test:assertTrue(rejected is InternalError, "a different card cannot share the listener");
    test:assertTrue((<error>rejected).message().includes("declare the same agent card"), (<error>rejected).message());
}

@test:Config {}
function testAJsonRpcListenerWithAnUnusableCertificateIsNotCreated() {
    JsonRpcListener|Error created = new (19325,
            secureSocket = {key: {certFile: "/no/such/server.crt", keyFile: "/no/such/server.key"}});
    test:assertTrue(created is Error, "a certificate that does not exist cannot secure a listener");
}
