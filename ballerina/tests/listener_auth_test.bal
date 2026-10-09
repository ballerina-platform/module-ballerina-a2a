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

// Inbound authentication (specification sections 7.4, 13.1, 13.3), over the
// real HTTP wire. Tokens are minted in-test with `ballerina/jwt`, so nothing
// here depends on an external identity provider.

import ballerina/http;
import ballerina/jwt;
import ballerina/lang.runtime;
import ballerina/test;

const int JWT_AUTH_TEST_PORT = 19246;
const int SCOPED_AUTH_TEST_PORT = 19247;
const int MULTI_AUTH_TEST_PORT = 19248;
const int RESOLVER_AUTH_TEST_PORT = 19249;
const int INTROSPECTION_STUB_PORT = 19250;
const int OAUTH2_AUTH_TEST_PORT = 19251;
const int EMPTY_AUTH_TEST_PORT = 19252;
const int EXTENDED_WITHOUT_AUTH_TEST_PORT = 19260;
const int EXTENDED_WITH_AUTH_TEST_PORT = 19261;

const string AUTH_TEST_SECRET = "a2a-auth-test-shared-secret-0123456789";

final AgentCard authTestCard = {
    name: "Guarded Agent",
    description: "Runs only for callers that authenticate",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

final AgentCard authTestExtendedCard = {
    name: "Guarded Agent (extended)",
    description: "Reveals an internal-only skill to authenticated callers",
    version: "1.0.0",
    skills: [{id: "debug", name: "Debug", description: "Internal-only", tags: ["internal"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

final http:JwtValidatorConfig authTestJwtValidator = {
    issuer: "a2a-auth-test",
    audience: "a2a",
    signatureConfig: {secret: AUTH_TEST_SECRET}
};

// Counts how many times the agent's own code ran, so a test can prove a
// rejected request never reached it.
isolated int authAgentCalls = 0;

isolated service class CountingAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        lock {
            authAgentCalls += 1;
        }
        check updater->working();
        check updater->addArtifact([{text: "handled"}]);
        check updater->complete();
    }
}

isolated function agentCalls() returns int {
    lock {
        return authAgentCalls;
    }
}

final DefaultHandler jwtAuthHandler = new (authTestCard, extendedAgentCard = authTestExtendedCard);

listener HttpListener jwtAuthListener = new (JWT_AUTH_TEST_PORT, jwtAuthHandler,
    auth = [{jwtValidatorConfig: authTestJwtValidator}]
);

final DefaultHandler scopedAuthHandler = new (authTestCard);

listener HttpListener scopedAuthListener = new (SCOPED_AUTH_TEST_PORT, scopedAuthHandler,
    auth = [{jwtValidatorConfig: authTestJwtValidator, scopes: "a2a:write"}]
);

// Two alternatives: a JWT, or Basic against the file user store.
final DefaultHandler multiAuthHandler = new (authTestCard);

listener HttpListener multiAuthListener = new (MULTI_AUTH_TEST_PORT, multiAuthHandler,
    auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {fileUserStoreConfig: {}}
    ]
);

// Authenticated *and* an owner resolver: the resolver must win.
final DefaultHandler resolverAuthHandler = new (authTestCard, ownerResolver = new HeaderOwnerResolver());

listener HttpListener resolverAuthListener = new (RESOLVER_AUTH_TEST_PORT, resolverAuthHandler,
    auth = [{jwtValidatorConfig: authTestJwtValidator}]
);

final DefaultHandler oauth2AuthHandler = new (authTestCard);

listener HttpListener oauth2AuthListener = new (OAUTH2_AUTH_TEST_PORT, oauth2AuthHandler,
    auth = [{oauth2IntrospectionConfig: {url: string `http://localhost:${INTROSPECTION_STUB_PORT}/introspect`}}]
);

// A stand-in for an OAuth2 authorization server's RFC 7662 introspection
// endpoint: "opaque-good" is an active token for carol, "opaque-inactive" is
// a token the server knows but has revoked, anything else is unknown.
listener http:Listener introspectionStub = new (INTROSPECTION_STUB_PORT);

service /introspect on introspectionStub {
    resource function post .(http:Request req) returns json|error {
        map<string> form = check req.getFormParams();
        string token = form["token"] ?: "";
        if token == "opaque-good" {
            return {active: true, sub: "carol", scope: "a2a:read"};
        }
        return {active: false};
    }
}

@test:BeforeSuite
function startAuthTestServers() returns error? {
    check jwtAuthListener.attach(new CountingAgent());
    check scopedAuthListener.attach(new CountingAgent());
    check multiAuthListener.attach(new CountingAgent());
    check resolverAuthListener.attach(new CountingAgent());
    check oauth2AuthListener.attach(new CountingAgent());
}

// ---- helpers -------------------------------------------------------------

isolated function bearerToken(string subject, string scope = "a2a:read", decimal expiry = 300,
        string secret = AUTH_TEST_SECRET) returns string|error {
    return jwt:issue({
        issuer: "a2a-auth-test",
        username: subject,
        audience: "a2a",
        expTime: expiry,
        customClaims: {"scope": scope},
        signatureConfig: {algorithm: jwt:HS256, config: secret}
    });
}

isolated function basicCredential(string user, string password) returns string =>
    string `Basic ${(user + ":" + password).toBytes().toBase64()}`;

// One raw request. `authorization` is the whole header value, or () to send
// none.
isolated function authCall(int port, string method, string path, string? authorization,
        json? body = (), map<string> extraHeaders = {}) returns http:Response|error {
    http:Client c = check new (string `http://localhost:${port}`);
    map<string|string[]> headers = {"A2A-Version": "1.0", "Content-Type": "application/json"};
    if authorization is string {
        headers["Authorization"] = authorization;
    }
    foreach [string, string] [k, v] in extraHeaders.entries() {
        headers[k] = v;
    }
    match method {
        "GET" => {
            return c->get(path, headers);
        }
        "DELETE" => {
            return c->delete(path, headers = headers);
        }
        _ => {
            return c->post(path, body ?: {}, headers);
        }
    }
}

type AuthErrorBody record {
    record {
        int code;
        string message;
        record {string reason?;}[] details;
    } 'error;
};

isolated function errorReasonOf(http:Response response) returns string?|error {
    json payload = check response.getJsonPayload();
    AuthErrorBody body = check payload.cloneWithType();
    return body.'error.details[0].reason;
}

isolated function sendGuardedMessage(int port, string authorization, string text,
        map<string> extraHeaders = {}) returns Task|error {
    http:Response r = check authCall(port, "POST", "/message:send", authorization, {
        "message": {"messageId": "m-" + text, "role": "ROLE_USER", "parts": [{"text": text}]}
    }, extraHeaders);
    test:assertEquals(r.statusCode, 200, "an authenticated send must succeed");
    json payload = check r.getJsonPayload();
    map<json> envelope = check payload.ensureType();
    json? taskJson = envelope["task"];
    if taskJson is () {
        return error("expected a task in the response envelope");
    }
    return taskJson.cloneWithType(Task);
}

isolated function guardedClient(int port, string authorization) returns HttpClient|error =>
    new (string `http://localhost:${port}`, headers = {"Authorization": authorization});

// ---- the card, and rejection --------------------------------------------

@test:Config {}
function testAuthPublicCardNeedsNoCredentials() returns error? {
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/.well-known/agent-card.json", ());
    test:assertEquals(r.statusCode, 200, "discovery must stay open: a client cannot learn how to authenticate otherwise");
}

@test:Config {}
function testAuthMissingCredentialsIs401WithChallenge() returns error? {
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/extendedAgentCard", ());
    test:assertEquals(r.statusCode, 401);
    test:assertEquals(check r.getHeader("WWW-Authenticate"), "Bearer",
            "a 401 must say which scheme to use (specification section 7.4)");
    test:assertEquals(check errorReasonOf(r), "UNAUTHENTICATED");
    test:assertTrue(r.getContentType().startsWith("application/a2a+json"));
}

@test:Config {}
function testAuthBadTokensAre401() returns error? {
    string wrongSecret = check bearerToken("alice", secret = "another-secret-another-secret-0123456");
    foreach string credential in ["Bearer not.a.jwt", "Bearer " + wrongSecret, "Basic dXNlcjpwYXNz", "Bearer"] {
        http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/extendedAgentCard", credential);
        test:assertEquals(r.statusCode, 401, string `credential "${credential}" must be rejected`);
    }
}

@test:Config {}
function testAuthExpiredTokenIs401() returns error? {
    string shortLived = check bearerToken("alice", expiry = 1);
    runtime:sleep(3);
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/extendedAgentCard", "Bearer " + shortLived);
    test:assertEquals(r.statusCode, 401);
}

@test:Config {}
function testAuthValidTokenReachesTheExtendedCard() returns error? {
    string token = check bearerToken("alice");
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/extendedAgentCard", "Bearer " + token);
    test:assertEquals(r.statusCode, 200);
    json payload = check r.getJsonPayload();
    test:assertEquals(check payload.name, "Guarded Agent (extended)");
}

@test:Config {}
function testAuthRejectedRequestNeverReachesTheAgent() returns error? {
    int before = agentCalls();
    json body = {"message": {"messageId": "m-blocked", "role": "ROLE_USER", "parts": [{"text": "hi"}]}};
    http:Response unauth = check authCall(JWT_AUTH_TEST_PORT, "POST", "/message:send", (), body);
    test:assertEquals(unauth.statusCode, 401);
    test:assertEquals(agentCalls(), before, "the agent's code must not run for an unauthenticated request");

    // Streaming: rejected as a plain 401 before any SSE stream opens.
    http:Response streamed = check authCall(JWT_AUTH_TEST_PORT, "POST", "/message:stream", (), body);
    test:assertEquals(streamed.statusCode, 401);
    test:assertFalse(streamed.getContentType().startsWith("text/event-stream"),
            "a rejected streaming request must be a JSON error, not an event stream");
    test:assertEquals(agentCalls(), before);

    string token = check bearerToken("alice");
    Task _ = check sendGuardedMessage(JWT_AUTH_TEST_PORT, "Bearer " + token, "now-authenticated");
    test:assertEquals(agentCalls(), before + 1, "the same request with a credential must run the agent once");
}

@test:Config {}
function testAuthEveryRouteRequiresCredentials() returns error? {
    // Each operation, and paths that do not exist: an unauthenticated caller
    // must learn nothing, not even which routes there are.
    [string, string][] routes = [
        ["GET", "/tasks"], ["GET", "/tasks/t1"], ["POST", "/tasks/t1:cancel"], ["POST", "/tasks/t1:subscribe"],
        ["POST", "/message:send"], ["POST", "/message:stream"],
        ["GET", "/tasks/t1/pushNotificationConfigs"], ["POST", "/tasks/t1/pushNotificationConfigs"],
        ["GET", "/tasks/t1/pushNotificationConfigs/c1"], ["DELETE", "/tasks/t1/pushNotificationConfigs/c1"],
        ["GET", "/extendedAgentCard"], ["GET", "/no/such/route"], ["GET", "/unknown-tenant/tasks"]
    ];
    foreach [string, string] [method, path] in routes {
        http:Response r = check authCall(JWT_AUTH_TEST_PORT, method, path, ());
        test:assertEquals(r.statusCode, 401, string `${method} ${path} must require authentication`);
    }
}

// ---- scopes --------------------------------------------------------------

@test:Config {}
function testAuthMissingScopeIs403() returns error? {
    string readOnly = check bearerToken("alice", scope = "a2a:read");
    http:Response r = check authCall(SCOPED_AUTH_TEST_PORT, "GET", "/tasks", "Bearer " + readOnly);
    test:assertEquals(r.statusCode, 403);
    test:assertEquals(check errorReasonOf(r), "PERMISSION_DENIED");
    test:assertTrue(r.getHeaders("WWW-Authenticate") is http:HeaderNotFoundError, "a 403 is not a challenge");

    string writer = check bearerToken("alice", scope = "a2a:write");
    http:Response ok = check authCall(SCOPED_AUTH_TEST_PORT, "GET", "/tasks", "Bearer " + writer);
    test:assertEquals(ok.statusCode, 200);
}

// ---- identity scoping (section 13.1) ------------------------------------

@test:Config {}
function testAuthScopesTasksToTheAuthenticatedIdentity() returns error? {
    string alice = "Bearer " + check bearerToken("alice-scoped");
    string bob = "Bearer " + check bearerToken("bob-scoped");

    Task created = check sendGuardedMessage(JWT_AUTH_TEST_PORT, alice, "alice's task");

    HttpClient aliceClient = check guardedClient(JWT_AUTH_TEST_PORT, alice);
    Task fetched = check aliceClient->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "the owner must see their own task");

    HttpClient bobClient = check guardedClient(JWT_AUTH_TEST_PORT, bob);
    Task|Error bobGet = bobClient->getTask({id: created.id});
    test:assertTrue(bobGet is TaskNotFoundError,
            "another caller must get TaskNotFound, which does not reveal the task exists");
    Task|Error bobCancel = bobClient->cancelTask({id: created.id});
    test:assertTrue(bobCancel is TaskNotFoundError);
    stream<StreamResponse, error?>|Error bobSubscribe = bobClient->subscribeToTask({id: created.id});
    test:assertTrue(bobSubscribe is TaskNotFoundError);
    TaskPushNotificationConfig|Error bobPush = bobClient->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/hook"});
    test:assertTrue(bobPush is TaskNotFoundError);

    ListTasksResponse bobsTasks = check bobClient->listTasks({});
    foreach Task t in bobsTasks.tasks {
        test:assertNotEquals(t.id, created.id, "another caller's list must not include the task");
    }
}

@test:Config {}
function testAuthOwnerResolverOverridesTheIdentity() returns error? {
    string alice = "Bearer " + check bearerToken("alice-resolver");
    string bob = "Bearer " + check bearerToken("bob-resolver");

    // Different identities, the same resolver-assigned owner: they share.
    Task created = check sendGuardedMessage(RESOLVER_AUTH_TEST_PORT, alice, "shared task",
            {"X-Test-Owner": "team-a"});
    http:Response sameOwner = check authCall(RESOLVER_AUTH_TEST_PORT, "GET", "/tasks/" + created.id, bob,
            extraHeaders = {"X-Test-Owner": "team-a"});
    test:assertEquals(sameOwner.statusCode, 200, "the resolver, not the token subject, decides the owner");

    http:Response otherOwner = check authCall(RESOLVER_AUTH_TEST_PORT, "GET", "/tasks/" + created.id, alice,
            extraHeaders = {"X-Test-Owner": "team-b"});
    test:assertEquals(otherOwner.statusCode, 404);
}

// ---- alternatives, and other mechanisms ---------------------------------

@test:Config {}
function testAuthEitherAlternativeIsAccepted() returns error? {
    string token = check bearerToken("alice");
    http:Response viaJwt = check authCall(MULTI_AUTH_TEST_PORT, "GET", "/tasks", "Bearer " + token);
    test:assertEquals(viaJwt.statusCode, 200);

    http:Response viaBasic = check authCall(MULTI_AUTH_TEST_PORT, "GET", "/tasks",
            basicCredential("dave", "dave-password"));
    test:assertEquals(viaBasic.statusCode, 200, "Basic against the file user store must be accepted");
}

@test:Config {}
function testAuthWrongBasicPasswordIs401WithBothChallenges() returns error? {
    http:Response r = check authCall(MULTI_AUTH_TEST_PORT, "GET", "/tasks", basicCredential("dave", "wrong"));
    test:assertEquals(r.statusCode, 401);
    string[] challenges = check r.getHeaders("WWW-Authenticate");
    test:assertEquals(challenges.length(), 2, "one challenge per accepted scheme");
    test:assertTrue(challenges.indexOf("Bearer") is int);
}

@test:Config {}
function testAuthOAuth2IntrospectionActiveTokenIsAccepted() returns error? {
    http:Response r = check authCall(OAUTH2_AUTH_TEST_PORT, "GET", "/tasks", "Bearer opaque-good");
    test:assertEquals(r.statusCode, 200);

    // The identity comes from the introspection response's `sub`.
    Task created = check sendGuardedMessage(OAUTH2_AUTH_TEST_PORT, "Bearer opaque-good", "carol's task");
    HttpClient carol = check guardedClient(OAUTH2_AUTH_TEST_PORT, "Bearer opaque-good");
    Task fetched = check carol->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id);
}

@test:Config {}
function testAuthOAuth2InactiveOrUnknownTokenIs401() returns error? {
    foreach string token in ["opaque-inactive", "never-issued"] {
        http:Response r = check authCall(OAUTH2_AUTH_TEST_PORT, "GET", "/tasks", "Bearer " + token);
        test:assertEquals(r.statusCode, 401, string `token "${token}" must be rejected`);
    }
}

// ---- configuration ------------------------------------------------------

@test:Config {}
function testAuthEmptyEntryListIsRejectedAtStartup() {
    HttpListener|error created = new (EMPTY_AUTH_TEST_PORT, new DefaultHandler(authTestCard), auth = []);
    test:assertTrue(created is Error, "an empty auth list would admit nobody, which is a mistake, not a policy");
}

// ---- an identity provider that cannot be reached while the listener starts ----
//
// `ballerina/jwt` preloads the JWKS when `jwksConfig.cacheConfig` is set, and
// `ballerina/auth` connects to the LDAP server; both panic when that fails.
// The listener returns the error instead of ending the process, and names the
// entry. If a panic escaped, it would abort the test run.

const int UNREACHABLE_IDP_TEST_PORT = 19262;

final http:JwtValidatorConfig unreachableJwksValidator = {
    issuer: "https://idp.example.com",
    audience: "a2a",
    signatureConfig: {jwksConfig: {url: "http://localhost:1/jwks", cacheConfig: {capacity: 10}}}
};

@test:Config {}
function testAuthUnreachableJwksWithACacheIsAnErrorNotAPanic() {
    HttpListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, new DefaultHandler(authTestCard),
            auth = [{jwtValidatorConfig: unreachableJwksValidator}]);
    test:assertTrue(created is InternalError, "an unreachable IdP at startup must be a returned error");
    if created is Error {
        test:assertTrue(created.message().includes("auth[0] (jwtValidatorConfig)"), created.message());
    }
}

@test:Config {}
function testAuthFailingEntryIsNamedByItsPosition() {
    HttpListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, new DefaultHandler(authTestCard),
            auth = [{fileUserStoreConfig: {}}, {jwtValidatorConfig: unreachableJwksValidator}]);
    test:assertTrue(created is InternalError);
    if created is Error {
        test:assertTrue(created.message().includes("auth[1] (jwtValidatorConfig)"),
                "the working first entry must not be blamed: " + created.message());
    }
}

@test:Config {}
function testAuthUnreachableLdapIsAnErrorNotAPanic() {
    HttpListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, new DefaultHandler(authTestCard),
            auth = [{
        ldapUserStoreConfig: {
            domainName: "example.com", connectionUrl: "ldap://localhost:1", connectionName: "cn=admin",
            connectionPassword: "x", userSearchBase: "ou=Users,dc=example,dc=com", userEntryObjectClass: "person",
            userNameAttribute: "uid", userNameSearchFilter: "(&(objectClass=person)(uid=?))",
            userNameListFilter: "(objectClass=person)", groupSearchBase: ["ou=Groups,dc=example,dc=com"],
            groupEntryObjectClass: "groupOfNames", groupNameAttribute: "cn",
            groupNameSearchFilter: "(&(objectClass=groupOfNames)(cn=?))",
            groupNameListFilter: "(objectClass=groupOfNames)", membershipAttribute: "member",
            connectionTimeout: 1
        }
    }]);
    test:assertTrue(created is InternalError, "an unreachable LDAP server at startup must be a returned error");
    if created is Error {
        test:assertTrue(created.message().includes("auth[0] (ldapUserStoreConfig)"), created.message());
    }
}

@test:Config {}
function testAuthJwksWithoutACacheStillConstructsWhenTheIdpIsDown() {
    // No preload without a cache: the keys are only fetched per request, so
    // there is nothing to fail at startup. Guards against the trap turning a
    // working configuration into an error.
    HttpListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, new DefaultHandler(authTestCard),
            auth = [{
        jwtValidatorConfig: {
            issuer: "https://idp.example.com",
            audience: "a2a",
            signatureConfig: {jwksConfig: {url: "http://localhost:1/jwks"}}
        }
    }]);
    test:assertTrue(created is HttpListener, created is Error ? created.message() : "");
}

@test:Config {}
function testAuthExtendedCardWithoutAuthIsRejectedAtStartup() {
    DefaultHandler handler = new (authTestCard, extendedAgentCard = authTestExtendedCard);
    HttpListener|error created = new (EXTENDED_WITHOUT_AUTH_TEST_PORT, handler);
    test:assertTrue(created is Error,
            "a listener that would hand the extended card to anyone must not start (specification section 13.3)");
    if created is error {
        test:assertTrue(created.message().includes("13.3"), "the message must say why");
    }
}

@test:Config {}
function testAuthExtendedCardWithAuthStarts() returns error? {
    DefaultHandler handler = new (authTestCard, extendedAgentCard = authTestExtendedCard);
    HttpListener created = check new (EXTENDED_WITH_AUTH_TEST_PORT, handler,
            auth = [{jwtValidatorConfig: authTestJwtValidator}]);
    check created.gracefulStop();
}
