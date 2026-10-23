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

const int JSON_RPC_TEST_PORT = 19280;
const int SHARED_HTTP_TEST_PORT = 19281;

final AgentCard & readonly rpcTestCard = {
    name: "Rpc Agent",
    description: "Served over JSON-RPC",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

// The same agent as FullService, but its operations are remote functions named
// for the JSON-RPC methods.
isolated service class RpcService {
    *Service;

    private final DefaultHandler handler;
    private final AgentCard & readonly card;

    isolated function init(DefaultHandler handler, AgentCard card) {
        self.handler = handler;
        self.card = card.cloneReadOnly();
    }

    isolated remote function getAgentCard() returns AgentCard|Error {
        return self.card;
    }

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated remote function sendStreamingMessage(SendMessageRequest request, Context context)
            returns stream<StreamResponse, Error?>|Error {
        return self.handler.handleSendStreamingMessage(context, request);
    }

    isolated remote function subscribeToTask(Context context, SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.handler.handleSubscribeToTask(context, request);
    }

    isolated remote function getTask(GetTaskRequest request) returns Task|Error {
        return self.handler.handleGetTask({headers: {}}, request);
    }

    isolated remote function listTasks(Context context, ListTasksRequest request)
            returns ListTasksResponse|Error {
        return self.handler.handleListTasks(context, request);
    }

    isolated remote function cancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        return self.handler.handleCancelTask(context, request);
    }

    isolated remote function createTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        return self.handler.handleCreateTaskPushNotificationConfig(context, request);
    }

    isolated remote function getTaskPushNotificationConfig(Context context,
            GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error {
        return self.handler.handleGetTaskPushNotificationConfig(context, request);
    }

    isolated remote function listTaskPushNotificationConfigs(Context context,
            ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error {
        return self.handler.handleListTaskPushNotificationConfigs(context, request);
    }

    isolated remote function deleteTaskPushNotificationConfig(Context context,
            DeleteTaskPushNotificationConfigRequest request) returns Error? {
        return self.handler.handleDeleteTaskPushNotificationConfig(context, request);
    }
}

final DefaultHandler rpcHandler = new (new CountingAgent());

listener JsonRpcListener rpcTestListener = new (JSON_RPC_TEST_PORT);

final http:Listener sharedHttpListener = check new (SHARED_HTTP_TEST_PORT);
listener RestListener sharedRestListener = new (sharedHttpListener);
listener JsonRpcListener sharedRpcListener = new (sharedHttpListener);

@test:BeforeSuite
function startJsonRpcServers() returns error? {
    check rpcTestListener.attach(new RpcService(rpcHandler, rpcTestCard));
    DefaultHandler sharedHandler = new (new CountingAgent());
    check sharedRestListener.attach(new FullService(sharedHandler, rpcTestCard));
    check sharedRpcListener.attach(new RpcService(sharedHandler, rpcTestCard));
}

isolated function rpcCall(int port, string method, json params, string? version = "1.0",
        string path = "/rpc") returns json|error {
    http:Client rpcClient = check new (string `http://localhost:${port}`, httpVersion = http:HTTP_1_1);
    map<string> headers = version is string ? {"A2A-Version": version} : {};
    json body = {jsonrpc: "2.0", id: "call-1", method, params};
    http:Response response = check rpcClient->post(path, body, headers);
    test:assertEquals(response.statusCode, 200);
    return response.getJsonPayload();
}

isolated function rpcSendParams(string messageId) returns json =>
    {message: {messageId, role: "ROLE_USER", parts: [{text: "hello over json-rpc"}]}};

@test:Config {}
function testJsonRpcCardListsTheJsonRpcInterface() returns error? {
    http:Client cardClient = check new (string `http://localhost:${JSON_RPC_TEST_PORT}`);
    json card = check cardClient->get("/.well-known/agent-card.json");
    json[] interfaces = <json[]>check card.supportedInterfaces;
    test:assertEquals(interfaces.length(), 1);
    test:assertEquals(check interfaces[0].protocolBinding, "JSONRPC");
    test:assertEquals(check interfaces[0].url, string `http://localhost:${JSON_RPC_TEST_PORT}/rpc`);
}

@test:Config {}
function testSendMessageOverJsonRpcCompletesATask() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", rpcSendParams("rpc-send-1"));
    test:assertEquals(check reply.jsonrpc, "2.0");
    test:assertEquals(check reply.id, "call-1");
    test:assertEquals(check reply.result.task.status.state, "TASK_STATE_COMPLETED");
    json[] artifacts = <json[]>check reply.result.task.artifacts;
    test:assertEquals(artifacts.length(), 1);
    json[] parts = <json[]>check artifacts[0].parts;
    test:assertEquals(check parts[0].text, "handled");
}

@test:Config {}
function testAnEmptyTenantMeansNoTenantOverJsonRpc() returns error? {
    map<json> params = <map<json>>rpcSendParams("rpc-empty-tenant-1");
    params["tenant"] = "";
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", params);
    test:assertEquals(check reply.result.task.status.state, "TASK_STATE_COMPLETED");
}

@test:Config {}
function testEmptyIdsMeanUnsetOverJsonRpc() returns error? {
    map<json> params = <map<json>>rpcSendParams("rpc-empty-ids-1");
    map<json> message = <map<json>>params["message"];
    message["taskId"] = "";
    message["contextId"] = "";
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", params);
    test:assertEquals(check reply.result.task.status.state, "TASK_STATE_COMPLETED");
}

@test:Config {}
function testGetTaskAndListTasksOverJsonRpc() returns error? {
    json sent = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", rpcSendParams("rpc-get-1"));
    string taskId = check (check sent.result.task.id).ensureType();

    json fetched = check rpcCall(JSON_RPC_TEST_PORT, "GetTask", {id: taskId});
    test:assertEquals(check fetched.result.id, taskId);

    json listed = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {});
    json[] tasks = <json[]>check listed.result.tasks;
    test:assertTrue(tasks.length() >= 1);
}

@test:Config {}
function testAnUnknownTaskIsAJsonRpcError() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "GetTask", {id: "no-such-task"});
    test:assertEquals(check reply.'error.code, -32001);
    test:assertFalse((<map<json>>reply).hasKey("result"), "an error response carries no result");
}

@test:Config {}
function testCancellingACompletedTaskIsNotCancelable() returns error? {
    json sent = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", rpcSendParams("rpc-cancel-1"));
    string taskId = check (check sent.result.task.id).ensureType();
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "CancelTask", {id: taskId});
    test:assertEquals(check reply.'error.code, -32002);
}

@test:Config {}
function testAnUnknownMethodIsMethodNotFound() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "NoSuchMethod", {});
    test:assertEquals(check reply.'error.code, -32601);
}

@test:Config {}
function testAnUndefinedOperationIsUnsupported() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "GetExtendedAgentCard", {});
    test:assertEquals(check reply.'error.code, -32004, "the service does not define an extended card");
}

@test:Config {}
function testMalformedJsonIsAParseError() returns error? {
    http:Client rpcClient = check new (string `http://localhost:${JSON_RPC_TEST_PORT}`, httpVersion = http:HTTP_1_1);
    http:Request request = new;
    request.setTextPayload("{not json", "application/json");
    request.setHeader("A2A-Version", "1.0");
    http:Response response = check rpcClient->post("/rpc", request);
    json reply = check response.getJsonPayload();
    test:assertEquals(check reply.'error.code, -32700);
}

@test:Config {}
function testARequestWithoutTheVersionHeaderIsRefused() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "SendMessage", rpcSendParams("rpc-version-1"), version = ());
    test:assertEquals(check reply.'error.code, -32009);
}

@test:Config {}
function testStreamingOverJsonRpcFramesEveryEventAsAnEnvelope() returns error? {
    http:Client rpcClient = check new (string `http://localhost:${JSON_RPC_TEST_PORT}`, httpVersion = http:HTTP_1_1);
    json body = {jsonrpc: "2.0", id: "stream-1", method: "SendStreamingMessage",
        params: rpcSendParams("rpc-stream-1")};
    http:Response response = check rpcClient->post("/rpc", body, {"A2A-Version": "1.0"});
    test:assertEquals(response.statusCode, 200);
    string text = check response.getTextPayload();
    string[] dataLines = from string line in re `\n`.split(text)
        where line.startsWith("data: ")
        select line.substring(6);
    test:assertTrue(dataLines.length() >= 3, text);
    foreach string dataLine in dataLines {
        json event = check dataLine.fromJsonString();
        test:assertEquals(check event.jsonrpc, "2.0");
        test:assertEquals(check event.id, "stream-1");
        test:assertTrue(event.result is map<json>, dataLine);
    }
    test:assertTrue(text.includes("TASK_STATE_COMPLETED"), text);
}

@test:Config {}
function testARestAndAJsonRpcListenerOnOneHttpListenerShareACard() returns error? {
    http:Client cardClient = check new (string `http://localhost:${SHARED_HTTP_TEST_PORT}`);
    json card = check cardClient->get("/.well-known/agent-card.json");
    json[] interfaces = <json[]>check card.supportedInterfaces;
    string[] bindings = [];
    foreach json iface in interfaces {
        json binding = check iface.protocolBinding;
        bindings.push(<string>binding);
    }
    test:assertEquals(bindings.sort(), ["HTTP+JSON", "JSONRPC"]);

    json viaRpc = check rpcCall(SHARED_HTTP_TEST_PORT, "SendMessage", rpcSendParams("rpc-shared-1"));
    test:assertEquals(check viaRpc.result.task.status.state, "TASK_STATE_COMPLETED");

    http:Client restClient = check new (string `http://localhost:${SHARED_HTTP_TEST_PORT}/rest`,
            httpVersion = http:HTTP_1_1);
    http:Response viaRest = check restClient->post("/message:send", rpcSendParams("rest-shared-1"),
            {"A2A-Version": "1.0"});
    test:assertEquals(viaRest.statusCode, 200);
}

@test:Config {}
function testAJsonRpcListenerServesOnlyItsOwnPath() returns error? {
    JsonRpcListener other = check new (19282);
    error? rejected = other.attach(new RpcService(rpcHandler, rpcTestCard), "rest");
    test:assertTrue(rejected is InternalError, "a JsonRpcListener serves /rpc only");
    test:assertTrue((<error>rejected).message().includes("/rpc"), (<error>rejected).message());
}

// The @a2a-js/sdk sends `"status": "UNRECOGNIZED"` for an unset filter.
@test:Config {}
function testAnUnsetStatusFilterIsNoFilter() returns error? {
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {status: "UNRECOGNIZED", pageSize: 2});
    test:assertFalse((<map<json>>reply).hasKey("error"), reply.toJsonString());
    json[] tasks = <json[]>check reply.result.tasks;
    test:assertTrue(tasks.length() <= 2);
}

// The same stream-timing check as `RestListener`, under this listener's own
// configuration name.
@test:Config {}
function testJsonRpcListenerRefusesANegativeStreamIdleTimeout() {
    JsonRpcListener|Error created = new (19316, streamIdleTimeout = -1);
    if created is JsonRpcListener {
        test:assertFail("a negative streamIdleTimeout must be refused");
    }
    test:assertEquals(created.message(),
            "JsonRpcListenerConfiguration.streamIdleTimeout must not be negative; use 0 to turn it off");
}

@test:Config {}
function testJsonRpcListenerRefusesANegativeKeepAliveInterval() {
    JsonRpcListener|Error created = new (19316, keepAliveInterval = -0.5);
    if created is JsonRpcListener {
        test:assertFail("a negative keepAliveInterval must be refused");
    }
    test:assertEquals(created.message(),
            "JsonRpcListenerConfiguration.keepAliveInterval must not be negative; use 0 to turn it off");
}

// A minimal service that defines getExtendedAgentCard.
isolated service class RpcExtendedCardService {
    *Service;

    private final DefaultHandler handler;

    isolated function init(DefaultHandler handler) {
        self.handler = handler;
    }

    isolated remote function getAgentCard() returns AgentCard|Error {
        return rpcTestCard;
    }

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated remote function getExtendedAgentCard(Context context, GetExtendedAgentCardRequest request)
            returns AgentCard|Error {
        return self.handler.handleGetExtendedAgentCard(context, request);
    }
}

// The extended card is for authenticated callers, so a listener without `auth`
// refuses a service that defines getExtendedAgentCard, before anything is bound.
@test:Config {}
function testJsonRpcExtendedCardWithoutAuthIsRejectedAtStartup() returns error? {
    DefaultHandler handler = new (new CountingAgent(), extendedAgentCard = rpcTestCard);
    JsonRpcListener created = check new (19316);
    error? attached = created.attach(new RpcExtendedCardService(handler));
    if attached is () {
        test:assertFail("a listener that would hand the extended card to anyone must not start");
    }
    test:assertEquals(attached.message(), "a service that defines getExtendedAgentCard requires "
        + "JsonRpcListenerConfiguration.auth: the extended agent card is for authenticated callers");
}
