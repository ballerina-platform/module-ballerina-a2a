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

// ---- the two bindings answer the same request the same way -------------------------------------------------

const int JSON_RPC_CARD_RULES_PORT = 19329;

@test:Config {}
function testListTasksRefusesATimestampThatIsNotRfc3339OverJsonRpc() returns error? {
    json bad = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {statusTimestampAfter: "yesterday"});
    test:assertEquals(check bad.'error.code, -32602, "REST gives InvalidParams for the same value");
    test:assertTrue(bad.toJsonString().includes("statusTimestampAfter"), "the error names the field");

    json good = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {statusTimestampAfter: "2026-01-01T00:00:00Z"});
    test:assertFalse((<map<json>>good).hasKey("error"), good.toJsonString());
}

@test:Config {}
function testValidateListTasksRequestChecksOnlyWhatTheTypeCannot() {
    test:assertTrue(validateListTasksRequest({statusTimestampAfter: "not a time"}) is InternalError);
    test:assertTrue(validateListTasksRequest({statusTimestampAfter: "2026-11-26T09:30:00+05:30"}) is ());
    test:assertTrue(validateListTasksRequest({}) is ());
}

@test:Config {}
function testAMalformedPushConfigIsAnInvalidRequestOverBothBindings() returns error? {
    // HTTP+JSON, which 0.8.0 serves, reports a body that does not match the config as an invalid request, so
    // JSON-RPC does too.
    json reply = check rpcCall(JSON_RPC_TEST_PORT, "CreateTaskPushNotificationConfig", {taskId: "t", url: 5});
    test:assertEquals(check reply.'error.code, -32600);
    TaskPushNotificationConfig|Error fromRest = decodePushConfigRequest({url: 5}, "t");
    test:assertTrue(fromRest is InternalError && fromRest.detail().code == -32600);
    TaskPushNotificationConfig|Error fromRpc = decodePushConfigRequest({url: 5, taskId: "t"});
    test:assertTrue(fromRpc is InternalError && fromRpc.detail().code == -32600);
    TaskPushNotificationConfig ok = check decodePushConfigRequest({url: "https://example.com/hook", taskId: "t"});
    test:assertEquals(ok.taskId, "t", "JSON-RPC carries the task in the params");
}

@test:Config {}
function testDisabledPushNotificationsReadTheSameOverBothBindings() returns error? {
    string expected = "push-notification-config operations: this agent's capabilities.pushNotifications is false";
    test:assertEquals(serverPushNotificationsUnsupportedError("push-notification-config operations").message(),
            expected);
    foreach [string, json] [method, params] in [
        ["CreateTaskPushNotificationConfig", {taskId: "t", url: "https://example.com/hook"}],
        ["GetTaskPushNotificationConfig", {taskId: "t", id: "c"}],
        ["ListTaskPushNotificationConfigs", {taskId: "t"}],
        ["DeleteTaskPushNotificationConfig", {taskId: "t", id: "c"}]
    ] {
        json reply = check rpcCallTo(RPC_SEND_ONLY_TEST_PORT, method, params);
        test:assertEquals(check reply.'error.code, -32003, method);
        test:assertEquals(check reply.'error.message, expected, method);
    }
}

@test:Config {}
function testAFieldGivenInTwoSpellingsIsRefusedWhenTheyDisagree() returns error? {
    json disagree = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {page_size: 1, pageSize: 2});
    test:assertEquals(check disagree.'error.code, -32602);
    json agree = check rpcCall(JSON_RPC_TEST_PORT, "ListTasks", {page_size: 1, pageSize: 1});
    test:assertFalse((<map<json>>agree).hasKey("error"), "the same value twice is harmless");

    json|Error nested = camelCaseKeys({message: {message_id: "a", messageId: "b"}});
    test:assertTrue(nested is InternalError, "the check applies at every level");
    json|Error kept = camelCaseKeys({message: {message_id: "a"}, metadata: {some_key: 1, someKey: 2}});
    test:assertEquals(kept, {message: {messageId: "a"}, metadata: {some_key: 1, someKey: 2}},
            "a metadata map is the caller's own structure");
}

@test:Config {}
function testTheExtendedCardOverJsonRpcCarriesTheCachingHeadersOfHttpJson() returns error? {
    string authorization = "Bearer " + check bearerToken("alice");
    http:Response response = check rawRpcPost(RPC_EXTENDED_CARD_TEST_PORT,
            {jsonrpc: "2.0", id: "e-1", method: "GetExtendedAgentCard", params: {}},
            {"A2A-Version": "1.0", "Authorization": authorization});
    test:assertEquals(response.statusCode, 200);
    json body = check response.getJsonPayload();
    string version = (check body.result.version).toString();
    test:assertEquals(check response.getHeader("ETag"), string `"${version}"`);
    test:assertEquals(check response.getHeader("Cache-Control"),
            string `private, max-age=${AGENT_CARD_CACHE_MAX_AGE_SECONDS}`);

    // Other results are not cards and carry neither.
    http:Response tasks = check rawRpcPost(JSON_RPC_TEST_PORT,
            {jsonrpc: "2.0", id: "e-2", method: "ListTasks", params: {}}, {"A2A-Version": "1.0"});
    test:assertTrue(tasks.getHeaders("ETag") is http:HeaderNotFoundError);
}

@test:Config {}
function testABadPublicUrlNamesTheConfigurationOfTheListenerThatGotIt() {
    JsonRpcListener|Error rpc = new (19330, publicUrl = "ftp://agents.example.com");
    test:assertTrue(rpc is InternalError);
    if rpc is Error {
        test:assertTrue(rpc.message().includes("JsonRpcListenerConfiguration.publicUrl"), rpc.message());
    }
    RestListener|Error rest = new (19331, publicUrl = "ftp://agents.example.com");
    if rest is Error {
        test:assertTrue(rest.message().includes("RestListenerConfiguration.publicUrl"), rest.message());
    }
}

// ---- the messages name what a JSON-RPC user writes ---------------------------------------------------------------

isolated service class JsonRpcNoCardService {
    *Service;

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return error InternalError("not used");
    }
}

@ServiceConfig {
    agentCard: {
        name: "Twice Declared",
        description: "Has the annotation and the function",
        version: "1.0.0",
        skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service class JsonRpcTwoCardsService {
    *Service;

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return error InternalError("not used");
    }

    isolated remote function getAgentCard() returns AgentCard|Error => rpcTestCard;
}

@test:Config {}
function testTheCardSourceErrorsNameGetAgentCardForAJsonRpcService() returns error? {
    JsonRpcListener agentListener = check new (JSON_RPC_CARD_RULES_PORT);
    Error? none = agentListener.attach(new JsonRpcNoCardService());
    test:assertTrue(none is InternalError);
    string noneMessage = (<Error>none).message();
    test:assertTrue(noneMessage.includes("or define getAgentCard"), noneMessage);
    test:assertFalse(noneMessage.includes("get agentCard"), "that is the HTTP+JSON resource: " + noneMessage);

    Error? both = agentListener.attach(new JsonRpcTwoCardsService());
    test:assertTrue(both is InternalError);
    string bothMessage = (<Error>both).message();
    test:assertTrue(bothMessage.includes("@a2a:ServiceConfig or getAgentCard, not both"), bothMessage);

    // HTTP+JSON still names its resource.
    RestListener restListener = check new (19332);
    Error? restNone = restListener.attach(new NoCardService(), "rest");
    test:assertTrue((<Error>restNone).message().includes("or define get agentCard"), (<Error>restNone).message());
}

@test:Config {}
function testTheListenerLifecycleMethodsReturnTypedErrors() {
    JsonRpcListener|Error created = new (19333);
    if created is Error {
        test:assertFail("could not create the listener: " + created.message());
    }
    // `Error?` and not `error?`: the caller can match the type without a cast.
    Error? detached = created.detach(new JsonRpcNoCardService());
    test:assertTrue(detached is () || detached is Error);
}

@test:Config {}
function testParamsAreRenamedAfterTheVersionCheckAndOnlyWhenTheyNeedIt() returns error? {
    // A request the version check refuses is refused for that, not for what its params would have been renamed to.
    http:Response refused = check rawRpcPost(JSON_RPC_TEST_PORT,
            {jsonrpc: "2.0", id: "o-1", method: "ListTasks", params: {page_size: 1, pageSize: 2}},
            {"A2A-Version": "0.3"});
    json reply = check refused.getJsonPayload();
    test:assertEquals(check reply.'error.code, -32009);

    // A request that already uses lowerCamelCase is left as it is, at every level.
    json camel = {message: {messageId: "m", parts: [{text: "x"}], metadata: {some_key: 1}}, tenant: "t"};
    test:assertEquals(camelCaseKeys(camel), camel);
    test:assertFalse(hasSnakeCaseKey(camel), "a metadata map is the caller's own structure");
    test:assertTrue(hasSnakeCaseKey({message: {message_id: "m"}}));
    test:assertTrue(hasSnakeCaseKey([{task_id: "t"}]));
}
