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

// `AuthenticationError` (401) and `AuthorizationError` (403): what the client
// makes of a rejected request, and how the server answers with the same two
// types (specification section 5.x).

import ballerina/http;
import ballerina/test;

const int PROTECTED_CARD_STUB_PORT = 19256;
const int STATUS_STUB_PORT = 19257;
const int RESOLVER_ERROR_TEST_PORT = 19258;

// A card served behind authentication.
listener http:Listener protectedCardStub = new (PROTECTED_CARD_STUB_PORT);

service /  on protectedCardStub {
    resource function 'default [string... path]() returns http:Response {
        http:Response res = new;
        res.statusCode = 401;
        res.setHeader("WWW-Authenticate", "Bearer realm=\"stub\"");
        return res;
    }
}

// What a gateway, a proxy, or a framework's security layer does: answers 401 or
// 403 with no A2A body at all, or with one.
listener http:Listener statusStub = new (STATUS_STUB_PORT);

service / on statusStub {
    resource function 'default tasks/[string id]() returns http:Response {
        http:Response res = new;
        match id {
            "plain-401" => {
                res.statusCode = 401;
            }
            "plain-403" => {
                res.statusCode = 403;
            }
            "challenged" => {
                res.statusCode = 401;
                res.addHeader("WWW-Authenticate", "Bearer");
                res.addHeader("WWW-Authenticate", "Basic realm=\"stub\"");
            }
            "reason-401" => {
                res.statusCode = 401;
                res.setJsonPayload(rpcStatusBody(401, "token expired at 10:00", "UNAUTHENTICATED"));
            }
            "reason-403" => {
                res.statusCode = 403;
                res.setJsonPayload(rpcStatusBody(403, "missing scope a2a:write", "PERMISSION_DENIED"));
            }
            _ => {
                res.statusCode = 500;
            }
        }
        return res;
    }
}

// A resolver that fails the way a real one does when a token cannot be verified.
isolated class FailingOwnerResolver {
    *TaskOwnerResolver;

    public isolated function resolveOwner(CallerContext context) returns string?|Error {
        string[]? modes = context.headers["x-test-fail"];
        string? mode = modes is string[] && modes.length() > 0 ? modes[0] : ();
        if mode == "401" {
            return error AuthenticationError("token could not be verified", message = "token could not be verified");
        }
        if mode == "403" {
            return error AuthorizationError("caller may not use this agent", message = "caller may not use this agent");
        }
        return "anyone";
    }
}

final DefaultHandler resolverErrorHandler = new (authTestCard, ownerResolver = new FailingOwnerResolver());

listener HttpListener resolverErrorListener = new (RESOLVER_ERROR_TEST_PORT, resolverErrorHandler);

@test:BeforeSuite
function startAuthErrorServers() returns error? {
    check resolverErrorListener.attach(new CountingAgent());
}

isolated function stubClient(int port) returns HttpClient|error {
    AgentCard card = {
        name: "Stub",
        description: "A stand-in for a protected agent",
        version: "1.0.0",
        skills: [],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: [{url: string `http://localhost:${port}`, protocolBinding: HTTP_JSON, protocolVersion: "1.0"}]
    };
    return new (card);
}

// ---- the mapping, without a network -------------------------------------

@test:Config {}
function testToA2AErrorFromRestTypesTheBareStatuses() {
    Error unauthenticated = toA2AErrorFromRest(401, ());
    test:assertTrue(unauthenticated is AuthenticationError);
    test:assertEquals(unauthenticated.detail().code, 401);
    test:assertFalse(unauthenticated is InternalError, "a rejected credential is not an internal failure");

    Error forbidden = toA2AErrorFromRest(403, ());
    test:assertTrue(forbidden is AuthorizationError);
    test:assertEquals(forbidden.detail().code, 403);
}

@test:Config {}
function testToA2AErrorFromRestTypesTheReasons() {
    Error a = toA2AErrorFromRest(401, rpcStatusBody(401, "expired", "UNAUTHENTICATED"));
    test:assertTrue(a is AuthenticationError);
    test:assertEquals(a.message(), "expired");
    Error z = toA2AErrorFromRest(403, rpcStatusBody(403, "no scope", "PERMISSION_DENIED"));
    test:assertTrue(z is AuthorizationError);
    test:assertEquals(z.message(), "no scope");
}

@test:Config {}
function testAuthenticationErrorKeepsTheChallenges() {
    Error err = toA2AErrorFromRest(401, (), ["Bearer", "Basic realm=\"x\""]);
    test:assertEquals(err.detail()?.data, {"wwwAuthenticate": ["Bearer", "Basic realm=\"x\""]});
    Error none = toA2AErrorFromRest(401, ());
    test:assertEquals(none.detail()?.data, (), "no challenge, nothing to carry");
}

@test:Config {}
function testOtherStatusesAreUnchangedByTheAuthMapping() {
    test:assertTrue(toA2AErrorFromRest(404, ()) is InternalError);
    test:assertTrue(toA2AErrorFromRest(500, ()) is InternalError);
    test:assertTrue(toA2AErrorFromRest(404, rpcStatusBody(404, "gone", "TASK_NOT_FOUND")) is TaskNotFoundError);
}

// ---- over the wire, against status-only servers -------------------------

@test:Config {}
function testClientTypesAPlainProxyStyle401And403() returns error? {
    HttpClient c = check stubClient(STATUS_STUB_PORT);
    Task|Error plain401 = c->getTask({id: "plain-401"});
    test:assertTrue(plain401 is AuthenticationError, "a bare 401, as a gateway sends it, must be typed");
    Task|Error plain403 = c->getTask({id: "plain-403"});
    test:assertTrue(plain403 is AuthorizationError);
    Task|Error unrelated = c->getTask({id: "anything-else"});
    test:assertTrue(unrelated is InternalError, "a 500 is still an internal failure");
}

@test:Config {}
function testClientKeepsTheChallengesOnA401() returns error? {
    HttpClient c = check stubClient(STATUS_STUB_PORT);
    Task|Error result = c->getTask({id: "challenged"});
    test:assertTrue(result is AuthenticationError);
    if result is Error {
        test:assertEquals(result.detail()?.data, {"wwwAuthenticate": ["Bearer", "Basic realm=\"stub\""]},
                "the client needs to see which schemes the agent accepts");
    }
}

@test:Config {}
function testClientTypesAnA2aBodyedRejectionAndKeepsItsMessage() returns error? {
    HttpClient c = check stubClient(STATUS_STUB_PORT);
    Task|Error expired = c->getTask({id: "reason-401"});
    test:assertTrue(expired is AuthenticationError);
    test:assertEquals((<Error>expired).message(), "token expired at 10:00");
    Task|Error scope = c->getTask({id: "reason-403"});
    test:assertTrue(scope is AuthorizationError);
    test:assertEquals((<Error>scope).message(), "missing scope a2a:write");
}

@test:Config {}
function testAProtectedCardIsAnAuthenticationError() returns error? {
    AgentCard|Error card = resolveAgentCard(string `http://localhost:${PROTECTED_CARD_STUB_PORT}`);
    test:assertTrue(card is AuthenticationError, "a card behind authentication is a credential problem, not a generic failure");
    test:assertEquals((<Error>card).detail()?.data, {"wwwAuthenticate": ["Bearer realm=\"stub\""]});
}

// ---- over the wire, against this package's own listener -----------------

@test:Config {}
function testEveryOperationTypesAMissingCredential() returns error? {
    HttpClient c = check new (string `http://localhost:${JWT_AUTH_TEST_PORT}`);
    SendMessageRequest request = {message: {messageId: "m-typed", role: ROLE_USER, parts: [{text: "hi"}]}};

    Task|Message|Error sent = c->sendMessage(request);
    test:assertTrue(sent is AuthenticationError);
    Task|Error got = c->getTask({id: "t1"});
    test:assertTrue(got is AuthenticationError);
    Task|Error canceled = c->cancelTask({id: "t1"});
    test:assertTrue(canceled is AuthenticationError);
    ListTasksResponse|Error listed = c->listTasks({});
    test:assertTrue(listed is AuthenticationError);
    stream<StreamResponse, Error?>|Error streamed = c->sendStreamingMessage(request);
    test:assertTrue(streamed is AuthenticationError,
            "a stream request that is rejected before any event is an error, not an empty stream");
    stream<StreamResponse, Error?>|Error subscribed = c->subscribeToTask({id: "t1"});
    test:assertTrue(subscribed is AuthenticationError);

    if sent is Error {
        test:assertEquals(sent.detail()?.data, {"wwwAuthenticate": ["Bearer"]},
                "this package's own listener names the scheme it wants");
    }
}

@test:Config {}
function testAMissingScopeIsAnAuthorizationError() returns error? {
    string readOnly = check bearerToken("alice-typed", scope = "a2a:read");
    HttpClient c = check new (string `http://localhost:${SCOPED_AUTH_TEST_PORT}`,
        credentials = new InMemoryCredentialStore({"bearerAuth": readOnly}));
    ListTasksResponse|Error result = c->listTasks({});
    test:assertTrue(result is AuthorizationError, "the credential is valid but the scope is not enough");
    test:assertEquals((<Error>result).detail().code, 403);
    // Specification 3.3.2: the 403 SHOULD say which scope is missing.
    test:assertTrue((<Error>result).message().includes("a2a:write"),
            string `the 403 must name the required scope, got "${(<Error>result).message()}"`);
    test:assertEquals((<Error>result).detail()?.data, {"requiredScopes": "a2a:write"});

    string writer = check bearerToken("alice-typed", scope = "a2a:write");
    HttpClient ok = check new (string `http://localhost:${SCOPED_AUTH_TEST_PORT}`,
        credentials = new InMemoryCredentialStore({"bearerAuth": writer}));
    ListTasksResponse _ = check ok->listTasks({});
}

@test:Config {}
function testAWrongCredentialIsAnAuthenticationErrorNotAnAuthorizationError() returns error? {
    string forged = check bearerToken("mallory", secret = "another-secret-another-secret-0123456");
    HttpClient c = check new (string `http://localhost:${JWT_AUTH_TEST_PORT}`,
        credentials = new InMemoryCredentialStore({"bearerAuth": forged}));
    Task|Error result = c->getTask({id: "t1"});
    test:assertTrue(result is AuthenticationError);
    test:assertFalse(result is AuthorizationError);
}

// ---- the server answers with the same two types -------------------------

@test:Config {}
function testAResolverCanAnswer401And403() returns error? {
    http:Response unauth = check authCall(RESOLVER_ERROR_TEST_PORT, "GET", "/tasks", (),
            extraHeaders = {"X-Test-Fail": "401"});
    test:assertEquals(unauth.statusCode, 401);
    test:assertEquals(check errorReasonOf(unauth), "UNAUTHENTICATED");

    http:Response forbidden = check authCall(RESOLVER_ERROR_TEST_PORT, "GET", "/tasks", (),
            extraHeaders = {"X-Test-Fail": "403"});
    test:assertEquals(forbidden.statusCode, 403);
    test:assertEquals(check errorReasonOf(forbidden), "PERMISSION_DENIED");

    http:Response fine = check authCall(RESOLVER_ERROR_TEST_PORT, "GET", "/tasks", ());
    test:assertEquals(fine.statusCode, 200);
}

@test:Config {}
function testTheTwoTypesRoundTripThroughClientAndServer() returns error? {
    HttpClient unauth = check new (string `http://localhost:${RESOLVER_ERROR_TEST_PORT}`,
        headers = {"X-Test-Fail": "401"});
    ListTasksResponse|Error a = unauth->listTasks({});
    test:assertTrue(a is AuthenticationError, "what the server sends as 401 the client types as AuthenticationError");
    test:assertEquals((<Error>a).message(), "token could not be verified");

    HttpClient forbidden = check new (string `http://localhost:${RESOLVER_ERROR_TEST_PORT}`,
        headers = {"X-Test-Fail": "403"});
    ListTasksResponse|Error z = forbidden->listTasks({});
    test:assertTrue(z is AuthorizationError);
}
