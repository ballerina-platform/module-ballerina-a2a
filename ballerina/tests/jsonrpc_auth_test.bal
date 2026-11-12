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

const int JSON_RPC_AUTH_TEST_PORT = 19286;

final DefaultHandler rpcAuthHandler = new (new CountingAgent());

// A JWT provider and the file user store, as alternatives: each knows a "dave".
listener JsonRpcListener rpcAuthListener = new (JSON_RPC_AUTH_TEST_PORT, auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {fileUserStoreConfig: {}}
    ]);

@test:BeforeSuite
function startJsonRpcAuthServer() returns error? {
    check rpcAuthListener.attach(new RpcCallerService(rpcAuthHandler));
}

// Every operation takes the caller's context, so each is scoped to its owner.
isolated service class RpcCallerService {
    *Service;

    private final DefaultHandler handler;

    isolated function init(DefaultHandler handler) {
        self.handler = handler;
    }

    isolated remote function getAgentCard() returns AgentCard|Error => rpcTestCard;

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated remote function getTask(Context context, GetTaskRequest request) returns Task|Error {
        return self.handler.handleGetTask(context, request);
    }

    isolated remote function listTasks(Context context, ListTasksRequest request) returns ListTasksResponse|Error {
        return self.handler.handleListTasks(context, request);
    }

    isolated remote function cancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        return self.handler.handleCancelTask(context, request);
    }
}

isolated function rpcCallAs(string? authorization, string method, json params) returns http:Response|error {
    http:Client rpcClient = check new (string `http://localhost:${JSON_RPC_AUTH_TEST_PORT}`,
            httpVersion = http:HTTP_1_1);
    map<string> headers = {"A2A-Version": "1.0"};
    if authorization is string {
        headers["Authorization"] = authorization;
    }
    return rpcClient->post("/rpc", {jsonrpc: "2.0", id: "auth-1", method, params}, headers);
}

isolated function rpcResultAs(string authorization, string method, json params) returns json|error {
    http:Response response = check rpcCallAs(authorization, method, params);
    test:assertEquals(response.statusCode, 200, "an authenticated call must be served");
    return response.getJsonPayload();
}

isolated function rpcErrorCodeOf(json reply) returns json {
    json failure = reply is map<json> ? reply["error"] : ();
    return failure is map<json> ? failure["code"] : ();
}

isolated function rpcTaskHiddenFrom(string authorization, string taskId) returns error? {
    json fetched = check rpcResultAs(authorization, "GetTask", {id: taskId});
    test:assertEquals(rpcErrorCodeOf(fetched), -32001, "another owner's task must not be fetched");
    json canceled = check rpcResultAs(authorization, "CancelTask", {id: taskId});
    test:assertEquals(rpcErrorCodeOf(canceled), -32001, "another owner's task must not be canceled");
    json listed = check rpcResultAs(authorization, "ListTasks", {});
    foreach json task in <json[]>check listed.result.tasks {
        test:assertNotEquals(check task.id, taskId, "another owner's task must not be listed");
    }
}

@test:Config {}
function testJsonRpcCallWithoutACredentialIsChallenged() returns error? {
    http:Response response = check rpcCallAs((), "ListTasks", {});
    test:assertEquals(response.statusCode, 401);
    test:assertTrue(response.hasHeader("WWW-Authenticate"), "a 401 must say how to authenticate");
}

@test:Config {}
function testJsonRpcSameNameFromAnotherProviderIsAnotherOwner() returns error? {
    string jwtDave = "Bearer " + check bearerToken("dave");
    string basicDave = basicCredential("dave", "dave-password");

    json jwtSent = check rpcResultAs(jwtDave, "SendMessage", rpcSendParams("rpc-auth-jwt-dave"));
    string jwtTask = check (check jwtSent.result.task.id).ensureType();
    check rpcTaskHiddenFrom(basicDave, jwtTask);

    json basicSent = check rpcResultAs(basicDave, "SendMessage", rpcSendParams("rpc-auth-basic-dave"));
    string basicTask = check (check basicSent.result.task.id).ensureType();
    check rpcTaskHiddenFrom(jwtDave, basicTask);

    json fetched = check rpcResultAs(jwtDave, "GetTask", {id: jwtTask});
    test:assertEquals(check fetched.result.id, jwtTask, "the owner must still see its own task");
}
