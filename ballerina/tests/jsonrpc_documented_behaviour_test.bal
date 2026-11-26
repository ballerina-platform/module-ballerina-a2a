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


// Behaviour the README documents for the JSON-RPC listener: what a notification's 204 does not say, and the
// authentication failures that are answered outside the JSON-RPC envelope.

import ballerina/http;
import ballerina/test;

const int JSON_RPC_SCOPED_AUTH_TEST_PORT = 19328;

listener JsonRpcListener rpcScopedAuthListener = new (JSON_RPC_SCOPED_AUTH_TEST_PORT,
        auth = [{jwtValidatorConfig: authTestJwtValidator, scopes: "a2a:write"}]);

@test:BeforeSuite
function startJsonRpcScopedAuthServer() returns error? {
    check rpcScopedAuthListener.attach(new RpcCallerService(new DefaultHandler(new CountingAgent())));
}

isolated function rawRpcPost(int port, json body, map<string> headers) returns http:Response|error {
    http:Client rpcClient = check new (string `http://localhost:${port}`, httpVersion = http:HTTP_1_1);
    return rpcClient->post("/rpc", body, headers);
}

// A 204 is the answer to every notification, so it says nothing about whether the operation ran: one that fails the
// version check is dropped the same way, while the same request with an id gets the error.
@test:Config {}
function testANotificationThatFailsTheVersionCheckStillGetsA204() returns error? {
    map<string> oldVersion = {"A2A-Version": "0.3"};
    http:Response dropped = check rawRpcPost(JSON_RPC_TEST_PORT,
            {jsonrpc: "2.0", method: "GetTask", params: {id: "any"}}, oldVersion);
    test:assertEquals(dropped.statusCode, 204);

    http:Response answered = check rawRpcPost(JSON_RPC_TEST_PORT,
            {jsonrpc: "2.0", id: "v-1", method: "GetTask", params: {id: "any"}}, oldVersion);
    test:assertEquals(answered.statusCode, 200);
    json reply = check answered.getJsonPayload();
    test:assertEquals(check reply.'error.code, -32009, "the request with an id is told the version is not supported");
}

@test:Config {}
function testAMissingScopeIsAnHttp403NotAJsonRpcError() returns error? {
    string readOnly = check bearerToken("alice", scope = "a2a:read");
    http:Response refused = check rawRpcPost(JSON_RPC_SCOPED_AUTH_TEST_PORT,
            {jsonrpc: "2.0", id: "s-1", method: "ListTasks", params: {}},
            {"A2A-Version": "1.0", "Authorization": "Bearer " + readOnly});
    test:assertEquals(refused.statusCode, 403);
    test:assertTrue(refused.getHeaders("WWW-Authenticate") is http:HeaderNotFoundError, "a 403 is not a challenge");

    string writer = check bearerToken("alice", scope = "a2a:write");
    http:Response ok = check rawRpcPost(JSON_RPC_SCOPED_AUTH_TEST_PORT,
            {jsonrpc: "2.0", id: "s-2", method: "ListTasks", params: {}},
            {"A2A-Version": "1.0", "Authorization": "Bearer " + writer});
    test:assertEquals(ok.statusCode, 200);
}

@test:Config {}
function testMissingCredentialsAreAnHttp401WithAChallenge() returns error? {
    http:Response refused = check rawRpcPost(JSON_RPC_SCOPED_AUTH_TEST_PORT,
            {jsonrpc: "2.0", id: "s-3", method: "ListTasks", params: {}}, {"A2A-Version": "1.0"});
    test:assertEquals(refused.statusCode, 401);
    test:assertTrue(refused.hasHeader("WWW-Authenticate"), "a 401 says how to authenticate");
}
