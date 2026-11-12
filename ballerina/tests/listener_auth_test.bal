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
const int TWO_PROVIDER_AUTH_TEST_PORT = 19266;
const int ROTATED_KEY_AUTH_TEST_PORT = 19267;
const int LINKED_ACCOUNTS_AUTH_TEST_PORT = 19269;
const int OWNER_RECORDING_AUTH_TEST_PORT = 19280;

const string AUTH_TEST_SECRET = "a2a-auth-test-shared-secret-0123456789";
const string SECOND_PROVIDER_SECRET = "a2a-auth-test-second-provider-secret-01";

final AgentCard & readonly authTestCard = {
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

isolated class CountingAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        lock {
            authAgentCalls += 1;
        }
        check updater.working();
        check updater.addArtifact([{text: "handled"}]);
        check updater.complete();
        return;
    }
}

isolated function agentCalls() returns int {
    lock {
        return authAgentCalls;
    }
}

final DefaultHandler jwtAuthHandler = new (new CountingAgent(), extendedAgentCard = authTestExtendedCard);

listener RestListener jwtAuthListener = new (JWT_AUTH_TEST_PORT, auth = [{jwtValidatorConfig: authTestJwtValidator}]);

final DefaultHandler scopedAuthHandler = new (new CountingAgent());

listener RestListener scopedAuthListener = new (SCOPED_AUTH_TEST_PORT, auth = [{jwtValidatorConfig: authTestJwtValidator, scopes: "a2a:write"}]);

// Two alternatives: a JWT, or Basic against the file user store.
final DefaultHandler multiAuthHandler = new (new CountingAgent());

listener RestListener multiAuthListener = new (MULTI_AUTH_TEST_PORT, auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {fileUserStoreConfig: {}}
    ]);

// Authenticated *and* an owner resolver: the resolver must win.
final DefaultHandler resolverAuthHandler = new (new CountingAgent(), ownerResolver = new HeaderOwnerResolver());

listener RestListener resolverAuthListener = new (RESOLVER_AUTH_TEST_PORT, auth = [{jwtValidatorConfig: authTestJwtValidator}]);

final DefaultHandler oauth2AuthHandler = new (new CountingAgent());

final http:OAuth2IntrospectionConfig authTestIntrospection = {
    url: string `http://localhost:${INTROSPECTION_STUB_PORT}/introspect`
};

listener RestListener oauth2AuthListener = new (OAUTH2_AUTH_TEST_PORT,
        auth = [{oauth2IntrospectionConfig: authTestIntrospection}]);

// Two independent providers: one pins its issuer, the other is named by its
// certificate and accepts any `iss`, so it can claim the first one's.
final DefaultHandler twoProviderHandler = new (new CountingAgent());

final http:JwtValidatorConfig certProviderValidator = {audience: "a2a", signatureConfig: {certFile: TEST_CERT}};

listener RestListener twoProviderListener = new (TWO_PROVIDER_AUTH_TEST_PORT, auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {jwtValidatorConfig: certProviderValidator}
    ]);

// One provider whose signing key was rotated: both entries pin its issuer.
final DefaultHandler rotatedKeyHandler = new (new CountingAgent());

listener RestListener rotatedKeyListener = new (ROTATED_KEY_AUTH_TEST_PORT, auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {
            jwtValidatorConfig: {
                issuer: "a2a-auth-test",
                audience: "a2a",
                signatureConfig: {secret: SECOND_PROVIDER_SECRET}
            }
        }
    ]);

// Links same-named accounts from different providers on purpose.
isolated class IdentityOwnerResolver {
    *TaskOwnerResolver;

    public isolated function resolveOwner(Context context) returns string?|Error => context?.identity;
}

final DefaultHandler linkedAccountsHandler = new (new CountingAgent(), ownerResolver = new IdentityOwnerResolver());

listener RestListener linkedAccountsListener = new (LINKED_ACCOUNTS_AUTH_TEST_PORT, auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {fileUserStoreConfig: {}}
    ]);

isolated string? lastRecordedOwner = ();

isolated class OwnerRecordingAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        lock {
            lastRecordedOwner = context?.owner;
        }
        check updater.complete();
        return;
    }
}

isolated function recordedOwner() returns string? {
    lock {
        return lastRecordedOwner;
    }
}

final DefaultHandler ownerRecordingHandler = new (new OwnerRecordingAgent());

listener RestListener ownerRecordingListener = new (OWNER_RECORDING_AUTH_TEST_PORT, auth = [
        {jwtValidatorConfig: authTestJwtValidator},
        {fileUserStoreConfig: {}}
    ]);

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
        if token == "opaque-issued" {
            return {active: true, sub: "carol", iss: "https://as.example.com", scope: "a2a:read"};
        }
        return {active: false};
    }
}

@test:BeforeSuite
function startAuthTestServers() returns error? {
    check jwtAuthListener.attach(new ExtendedService(jwtAuthHandler, authTestCard), "rest");
    check scopedAuthListener.attach(new FullService(scopedAuthHandler, authTestCard), "rest");
    check multiAuthListener.attach(new FullService(multiAuthHandler, authTestCard), "rest");
    check resolverAuthListener.attach(new FullService(resolverAuthHandler, authTestCard), "rest");
    check oauth2AuthListener.attach(new FullService(oauth2AuthHandler, authTestCard), "rest");
    check twoProviderListener.attach(new FullService(twoProviderHandler, authTestCard), "rest");
    check rotatedKeyListener.attach(new FullService(rotatedKeyHandler, authTestCard), "rest");
    check linkedAccountsListener.attach(new FullService(linkedAccountsHandler, authTestCard), "rest");
    check ownerRecordingListener.attach(new FullService(ownerRecordingHandler, authTestCard), "rest");
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

// A token from the certificate-named provider, claiming the same issuer as
// `bearerToken`. Without `subject`, it names the user by `username` alone.
isolated function certSignedToken(string? subject, string? username = ()) returns string|error {
    jwt:IssuerConfig config = {
        issuer: "a2a-auth-test",
        audience: "a2a",
        customClaims: username is string ? {"username": username} : {},
        signatureConfig: {algorithm: jwt:RS256, config: {keyFile: TEST_KEY}}
    };
    if subject is string {
        config.username = subject;
    }
    return jwt:issue(config);
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
    http:Response r = check authCall(port, "POST", "/rest/message:send", authorization, {
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

isolated function guardedClient(int port, string authorization) returns RestClient|error =>
    new (string `http://localhost:${port}`, headers = {"Authorization": authorization});

// ---- the card, and rejection --------------------------------------------

@test:Config {}
function testAuthPublicCardNeedsNoCredentials() returns error? {
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/.well-known/agent-card.json", ());
    test:assertEquals(r.statusCode, 200, "discovery must stay open: a client cannot learn how to authenticate otherwise");
}

@test:Config {}
function testAuthMissingCredentialsIs401WithChallenge() returns error? {
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/rest/extendedAgentCard", ());
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
        http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/rest/extendedAgentCard", credential);
        test:assertEquals(r.statusCode, 401, string `credential "${credential}" must be rejected`);
    }
}

@test:Config {}
function testAuthExpiredTokenIs401() returns error? {
    string shortLived = check bearerToken("alice", expiry = 1);
    runtime:sleep(3);
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/rest/extendedAgentCard", "Bearer " + shortLived);
    test:assertEquals(r.statusCode, 401);
}

@test:Config {}
function testAuthValidTokenReachesTheExtendedCard() returns error? {
    string token = check bearerToken("alice");
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/rest/extendedAgentCard", "Bearer " + token);
    test:assertEquals(r.statusCode, 200);
    json payload = check r.getJsonPayload();
    test:assertEquals(check payload.name, "Guarded Agent (extended)");
}

@test:Config {}
function testAuthRejectedRequestNeverReachesTheAgent() returns error? {
    int before = agentCalls();
    json body = {"message": {"messageId": "m-blocked", "role": "ROLE_USER", "parts": [{"text": "hi"}]}};
    http:Response unauth = check authCall(JWT_AUTH_TEST_PORT, "POST", "/rest/message:send", (), body);
    test:assertEquals(unauth.statusCode, 401);
    test:assertEquals(agentCalls(), before, "the agent's code must not run for an unauthenticated request");

    // Streaming: rejected as a plain 401 before any SSE stream opens.
    http:Response streamed = check authCall(JWT_AUTH_TEST_PORT, "POST", "/rest/message:stream", (), body);
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
    // Each operation, and a tenant the agent does not serve: an unauthenticated
    // caller learns nothing about either.
    [string, string][] routes = [
        ["GET", "/rest/tasks"], ["GET", "/rest/tasks/t1"], ["POST", "/rest/tasks/t1:cancel"], ["POST", "/rest/tasks/t1:subscribe"],
        ["POST", "/rest/message:send"], ["POST", "/rest/message:stream"],
        ["GET", "/rest/tasks/t1/pushNotificationConfigs"], ["POST", "/rest/tasks/t1/pushNotificationConfigs"],
        ["GET", "/rest/tasks/t1/pushNotificationConfigs/c1"], ["DELETE", "/rest/tasks/t1/pushNotificationConfigs/c1"],
        ["GET", "/rest/extendedAgentCard"], ["GET", "/rest/unknown-tenant/tasks"]
    ];
    foreach [string, string] [method, path] in routes {
        http:Response r = check authCall(JWT_AUTH_TEST_PORT, method, path, ());
        test:assertEquals(r.statusCode, 401, string `${method} ${path} must require authentication`);
    }
}

// A path that names no operation has no resource, so the HTTP module answers
// 404 before authentication runs. It reveals only that the path is not one of
// the binding's published routes.
@test:Config {}
function testAuthUnknownPathIs404WithoutCredentials() returns error? {
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/rest/no/such/route", ());
    test:assertEquals(r.statusCode, 404);
}

// ---- scopes --------------------------------------------------------------

@test:Config {}
function testAuthMissingScopeIs403() returns error? {
    string readOnly = check bearerToken("alice", scope = "a2a:read");
    http:Response r = check authCall(SCOPED_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer " + readOnly);
    test:assertEquals(r.statusCode, 403);
    test:assertEquals(check errorReasonOf(r), "PERMISSION_DENIED");
    test:assertTrue(r.getHeaders("WWW-Authenticate") is http:HeaderNotFoundError, "a 403 is not a challenge");

    string writer = check bearerToken("alice", scope = "a2a:write");
    http:Response ok = check authCall(SCOPED_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer " + writer);
    test:assertEquals(ok.statusCode, 200);
}

// The `auth` entries are alternatives: a token one entry identifies but
// denies for scope must still be tried against the entries after it.
@test:Config {}
function testAuthAScopeDenialFallsThroughToTheNextEntry() returns error? {
    string writer = check bearerToken("carol", scope = "a2a:write");
    http:Response ok = check authCall(TWO_JWT_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer " + writer);
    test:assertEquals(ok.statusCode, 200, "the second entry admits a2a:write");

    string other = check bearerToken("carol", scope = "a2a:other");
    http:Response denied = check authCall(TWO_JWT_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer " + other);
    test:assertEquals(denied.statusCode, 403);
    string body = check denied.getTextPayload();
    foreach string scope in ["a2a:read", "a2a:write", "a2a:admin"] {
        test:assertTrue(body.includes(scope), string `the 403 must name ${scope}: ${body}`);
    }
}

// ---- identity scoping (section 13.1) ------------------------------------

@test:Config {}
function testAuthScopesTasksToTheAuthenticatedIdentity() returns error? {
    string alice = "Bearer " + check bearerToken("alice-scoped");
    string bob = "Bearer " + check bearerToken("bob-scoped");

    Task created = check sendGuardedMessage(JWT_AUTH_TEST_PORT, alice, "alice's task");

    RestClient aliceClient = check guardedClient(JWT_AUTH_TEST_PORT, alice);
    Task fetched = check aliceClient->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "the owner must see their own task");

    RestClient bobClient = check guardedClient(JWT_AUTH_TEST_PORT, bob);
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
    http:Response sameOwner = check authCall(RESOLVER_AUTH_TEST_PORT, "GET", "/rest/tasks/" + created.id, bob,
            extraHeaders = {"X-Test-Owner": "team-a"});
    test:assertEquals(sameOwner.statusCode, 200, "the resolver, not the token subject, decides the owner");

    http:Response otherOwner = check authCall(RESOLVER_AUTH_TEST_PORT, "GET", "/rest/tasks/" + created.id, alice,
            extraHeaders = {"X-Test-Owner": "team-b"});
    test:assertEquals(otherOwner.statusCode, 404);
}

// ---- one owner per authority ---------------------------------------------

function assertTaskHiddenFrom(int port, string authorization, string taskId) returns error? {
    RestClient intruder = check guardedClient(port, authorization);
    Task|Error fetched = intruder->getTask({id: taskId});
    test:assertTrue(fetched is TaskNotFoundError, "another owner's task must not be fetched");
    Task|Error canceled = intruder->cancelTask({id: taskId});
    test:assertTrue(canceled is TaskNotFoundError, "another owner's task must not be canceled");
    stream<StreamResponse, error?>|Error subscribed = intruder->subscribeToTask({id: taskId});
    test:assertTrue(subscribed is TaskNotFoundError, "another owner's task must not be subscribed to");
    TaskPushNotificationConfig|Error registered = intruder->createTaskPushNotificationConfig(
            {taskId, url: "https://example.com/hook"});
    test:assertTrue(registered is TaskNotFoundError, "another owner's task must not take a webhook");
    ListTasksResponse listed = check intruder->listTasks({});
    foreach Task task in listed.tasks {
        test:assertNotEquals(task.id, taskId, "another owner's task must not be listed");
    }
}

@test:Config {}
function testAuthSameNameFromAnotherProviderIsAnotherOwner() returns error? {
    string jwtDave = "Bearer " + check bearerToken("dave");
    string basicDave = basicCredential("dave", "dave-password");

    Task jwtTask = check sendGuardedMessage(MULTI_AUTH_TEST_PORT, jwtDave, "jwt dave's task");
    check assertTaskHiddenFrom(MULTI_AUTH_TEST_PORT, basicDave, jwtTask.id);

    Task basicTask = check sendGuardedMessage(MULTI_AUTH_TEST_PORT, basicDave, "basic dave's task");
    check assertTaskHiddenFrom(MULTI_AUTH_TEST_PORT, jwtDave, basicTask.id);

    RestClient owner = check guardedClient(MULTI_AUTH_TEST_PORT, jwtDave);
    Task fetched = check owner->getTask({id: jwtTask.id});
    test:assertEquals(fetched.id, jwtTask.id, "the owner must still see its own task");
}

@test:Config {}
function testAuthSameSubjectFromAnotherJwtProviderIsAnotherOwner() returns error? {
    // Both tokens claim the same `iss` and `sub`; only the provider that signed them differs.
    string first = "Bearer " + check bearerToken("dave");
    string second = "Bearer " + check certSignedToken("dave");

    Task firstTask = check sendGuardedMessage(TWO_PROVIDER_AUTH_TEST_PORT, first, "first provider's dave");
    check assertTaskHiddenFrom(TWO_PROVIDER_AUTH_TEST_PORT, second, firstTask.id);

    Task secondTask = check sendGuardedMessage(TWO_PROVIDER_AUTH_TEST_PORT, second, "second provider's dave");
    check assertTaskHiddenFrom(TWO_PROVIDER_AUTH_TEST_PORT, first, secondTask.id);
}

@test:Config {}
function testAuthEntriesPinningOneIssuerShareOwners() returns error? {
    string oldKey = "Bearer " + check bearerToken("dave");
    string newKey = "Bearer " + check bearerToken("dave", secret = SECOND_PROVIDER_SECRET);

    Task created = check sendGuardedMessage(ROTATED_KEY_AUTH_TEST_PORT, oldKey, "before the key rotated");
    RestClient rotated = check guardedClient(ROTATED_KEY_AUTH_TEST_PORT, newKey);
    Task fetched = check rotated->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "a token signed with the issuer's new key must keep its tasks");
}

@test:Config {}
function testAuthOwnerResolverCanLinkAccountsAcrossProviders() returns error? {
    string jwtDave = "Bearer " + check bearerToken("dave");
    Task created = check sendGuardedMessage(LINKED_ACCOUNTS_AUTH_TEST_PORT, jwtDave, "linked dave's task");

    string basicCredentials = basicCredential("dave", "dave-password");
    RestClient basicDave = check guardedClient(LINKED_ACCOUNTS_AUTH_TEST_PORT, basicCredentials);
    Task fetched = check basicDave->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "a resolver returning the identity alone links the accounts");
}

@test:Config {}
function testAuthOwnerIsTheIdentityWithinItsAuthority() returns error? {
    string basicDave = basicCredential("dave", "dave-password");
    Task _ = check sendGuardedMessage(OWNER_RECORDING_AUTH_TEST_PORT, basicDave, "owner-basic");
    test:assertEquals(recordedOwner(), "[\"file\", \"dave\"]");

    string jwtAlice = "Bearer " + check bearerToken("alice");
    Task _ = check sendGuardedMessage(OWNER_RECORDING_AUTH_TEST_PORT, jwtAlice, "owner-jwt");
    test:assertEquals(recordedOwner(), "[\"jwt\", \"issuer=a2a-auth-test\", \"alice\"]");
}

@test:Config {}
function testAuthIdentityWithoutAnAuthorityIsItsOwnScope() returns error? {
    DefaultHandler handler = new (new CountingAgent());
    Context bare = {identity: "dave", headers: {}};
    Context fromFileStore = {identity: "dave", authority: ["file"], headers: {}};
    Task|Message sent = check handler.handleSendMessage(bare,
            {message: {messageId: "m-bare-identity", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(sent is Task, "the agent completes a task");
    string taskId = (<Task>sent).id;

    Task|Error sameCaller = handler.handleGetTask(bare, {id: taskId});
    test:assertTrue(sameCaller is Task, "the same context must see its task");
    Task|Error otherCaller = handler.handleGetTask(fromFileStore, {id: taskId});
    test:assertTrue(otherCaller is TaskNotFoundError, "a bare identity must not match an authority-qualified one");
}

// ---- the authority of each kind of entry ---------------------------------

@test:Config {}
function testAuthorityOfNamesTheProviderAndNoSecret() {
    test:assertEquals(authorityOf({jwtValidatorConfig: authTestJwtValidator}), ["jwt", "issuer=a2a-auth-test"]);
    http:JwtValidatorConfig jwks = {signatureConfig: {jwksConfig: {url: "https://idp.example/jwks"}}};
    test:assertEquals(authorityOf({jwtValidatorConfig: jwks}), ["jwt", "jwks=https://idp.example/jwks"]);
    test:assertEquals(authorityOf({jwtValidatorConfig: {signatureConfig: {certFile: "/certs/idp.crt"}}}),
            ["jwt", "cert=/certs/idp.crt"]);
    test:assertEquals(authorityOf({
        jwtValidatorConfig: {
            signatureConfig: {
                trustStoreConfig: {trustStore: {path: "/certs/trust.p12", password: "store-pass"}, certAlias: "idp"}
            }
        }
    }), ["jwt", "truststore=/certs/trust.p12", "alias=idp"]);
    test:assertEquals(authorityOf({jwtValidatorConfig: {signatureConfig: {secret: AUTH_TEST_SECRET}}}), ());
    test:assertEquals(authorityOf({oauth2IntrospectionConfig: authTestIntrospection}),
            ["oauth2", string `introspection=${authTestIntrospection.url}`]);
    test:assertEquals(authorityOf({fileUserStoreConfig: {}}), ["file"]);
    test:assertEquals(authorityOf({ldapUserStoreConfig: unreachableLdapStore}),
            ["ldap", "url=ldap://localhost:1", "base=ou=Users,dc=example,dc=com"]);
}

@test:Config {}
function testAuthUnpinnedIssuerAndUsernameClaimQualifyTheAuthority() returns error? {
    http:ListenerAuthConfig[] configs = [{jwtValidatorConfig: certProviderValidator}];
    ListenerAuthenticator authenticator = check new ("RestListenerConfiguration", configs.cloneReadOnly());
    string[] authority = ["jwt", string `cert=${TEST_CERT}`, "issuer=a2a-auth-test"];

    AuthenticatedCaller|AuthFailure bySubject = authenticator.authenticate("Bearer " + check certSignedToken("dave"));
    test:assertEquals(bySubject, {identity: "dave", authority});

    string byUsernameToken = check certSignedToken((), username = "dave");
    AuthenticatedCaller|AuthFailure byUsername = authenticator.authenticate("Bearer " + byUsernameToken);
    test:assertEquals(byUsername, {identity: "dave", authority: [...authority, "claim=username"]});
}

@test:Config {}
function testAuthIntrospectedIssuerQualifiesTheAuthority() returns error? {
    http:ListenerAuthConfig[] configs = [{oauth2IntrospectionConfig: authTestIntrospection}];
    ListenerAuthenticator authenticator = check new ("RestListenerConfiguration", configs.cloneReadOnly());
    string endpoint = string `introspection=${authTestIntrospection.url}`;

    test:assertEquals(authenticator.authenticate("Bearer opaque-good"),
            {identity: "carol", authority: ["oauth2", endpoint]});
    test:assertEquals(authenticator.authenticate("Bearer opaque-issued"),
            {identity: "carol", authority: ["oauth2", endpoint, "issuer=https://as.example.com"]});
}

// ---- alternatives, and other mechanisms ---------------------------------

@test:Config {}
function testAuthEitherAlternativeIsAccepted() returns error? {
    string token = check bearerToken("alice");
    http:Response viaJwt = check authCall(MULTI_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer " + token);
    test:assertEquals(viaJwt.statusCode, 200);

    http:Response viaBasic = check authCall(MULTI_AUTH_TEST_PORT, "GET", "/rest/tasks",
            basicCredential("dave", "dave-password"));
    test:assertEquals(viaBasic.statusCode, 200, "Basic against the file user store must be accepted");
}

@test:Config {}
function testAuthWrongBasicPasswordIs401WithBothChallenges() returns error? {
    http:Response r = check authCall(MULTI_AUTH_TEST_PORT, "GET", "/rest/tasks", basicCredential("dave", "wrong"));
    test:assertEquals(r.statusCode, 401);
    string[] challenges = check r.getHeaders("WWW-Authenticate");
    test:assertEquals(challenges.length(), 2, "one challenge per accepted scheme");
    test:assertTrue(challenges.indexOf("Bearer") is int);
}

@test:Config {}
function testAuthOAuth2IntrospectionActiveTokenIsAccepted() returns error? {
    http:Response r = check authCall(OAUTH2_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer opaque-good");
    test:assertEquals(r.statusCode, 200);

    // The identity comes from the introspection response's `sub`.
    Task created = check sendGuardedMessage(OAUTH2_AUTH_TEST_PORT, "Bearer opaque-good", "carol's task");
    RestClient carol = check guardedClient(OAUTH2_AUTH_TEST_PORT, "Bearer opaque-good");
    Task fetched = check carol->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id);
}

@test:Config {}
function testAuthOAuth2InactiveOrUnknownTokenIs401() returns error? {
    foreach string token in ["opaque-inactive", "never-issued"] {
        http:Response r = check authCall(OAUTH2_AUTH_TEST_PORT, "GET", "/rest/tasks", "Bearer " + token);
        test:assertEquals(r.statusCode, 401, string `token "${token}" must be rejected`);
    }
}

// ---- configuration ------------------------------------------------------

@test:Config {}
function testAuthEmptyEntryListIsRejectedAtStartup() {
    RestListener|error created = new (EMPTY_AUTH_TEST_PORT, auth = []);
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

final http:LdapUserStoreConfig unreachableLdapStore = {
    domainName: "example.com", connectionUrl: "ldap://localhost:1", connectionName: "cn=admin",
    connectionPassword: "x", userSearchBase: "ou=Users,dc=example,dc=com", userEntryObjectClass: "person",
    userNameAttribute: "uid", userNameSearchFilter: "(&(objectClass=person)(uid=?))",
    userNameListFilter: "(objectClass=person)", groupSearchBase: ["ou=Groups,dc=example,dc=com"],
    groupEntryObjectClass: "groupOfNames", groupNameAttribute: "cn",
    groupNameSearchFilter: "(&(objectClass=groupOfNames)(cn=?))",
    groupNameListFilter: "(objectClass=groupOfNames)", membershipAttribute: "member",
    connectionTimeout: 1
};

@test:Config {}
function testAuthUnreachableJwksWithACacheIsAnErrorNotAPanic() {
    RestListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, auth = [{jwtValidatorConfig: unreachableJwksValidator}]);
    test:assertTrue(created is InternalError, "an unreachable IdP at startup must be a returned error");
    if created is Error {
        test:assertTrue(created.message().includes("auth[0] (jwtValidatorConfig)"), created.message());
    }
}

@test:Config {}
function testAuthFailingEntryIsNamedByItsPosition() {
    RestListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, auth = [{fileUserStoreConfig: {}}, {jwtValidatorConfig: unreachableJwksValidator}]);
    test:assertTrue(created is InternalError);
    if created is Error {
        test:assertTrue(created.message().includes("auth[1] (jwtValidatorConfig)"),
                "the working first entry must not be blamed: " + created.message());
    }
}

@test:Config {}
function testAuthUnreachableLdapIsAnErrorNotAPanic() {
    RestListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, auth = [{ldapUserStoreConfig: unreachableLdapStore}]);
    test:assertTrue(created is InternalError, "an unreachable LDAP server at startup must be a returned error");
    if created is Error {
        string message = created.message();
        test:assertTrue(message.includes("RestListenerConfiguration.auth[0] (ldapUserStoreConfig)"), message);
    }
}

@test:Config {}
function testAuthJwtEntryNamingNoProviderIsRejectedAtStartup() {
    RestListener|Error created = new (UNREACHABLE_IDP_TEST_PORT,
            auth = [{fileUserStoreConfig: {}}, {jwtValidatorConfig: {signatureConfig: {secret: AUTH_TEST_SECRET}}}]);
    test:assertTrue(created is InternalError, "an entry with only a secret must pin its issuer");
    if created is Error {
        string message = created.message();
        test:assertTrue(message.includes("RestListenerConfiguration.auth[1] (jwtValidatorConfig) must set issuer"),
                message);
    }
}

@test:Config {}
function testAuthJwksWithoutACacheStillConstructsWhenTheIdpIsDown() {
    // No preload without a cache: the keys are only fetched per request, so
    // there is nothing to fail at startup. Guards against the trap turning a
    // working configuration into an error.
    RestListener|Error created = new (UNREACHABLE_IDP_TEST_PORT, auth = [{
        jwtValidatorConfig: {
            issuer: "https://idp.example.com",
            audience: "a2a",
            signatureConfig: {jwksConfig: {url: "http://localhost:1/jwks"}}
        }
    }]);
    test:assertTrue(created is RestListener, created is Error ? created.message() : "");
}

@test:Config {}
function testAuthExtendedCardWithoutAuthIsRejectedAtStartup() returns error? {
    DefaultHandler handler = new (new CountingAgent(), extendedAgentCard = authTestExtendedCard);
    RestListener created = check new (EXTENDED_WITHOUT_AUTH_TEST_PORT);
    error? attached = created.attach(new ExtendedService(handler, authTestCard), "rest");
    test:assertTrue(attached is Error,
            "a listener that would hand the extended card to anyone must not start");
    if attached is error {
        test:assertEquals(attached.message(), "a service that defines the get extendedAgentCard resource requires "
            + "RestListenerConfiguration.auth: the extended agent card is for authenticated callers");
    }
}

@test:Config {}
function testAuthExtendedCardWithAuthStarts() returns error? {
    DefaultHandler handler = new (new CountingAgent(), extendedAgentCard = authTestExtendedCard);
    RestListener created = check new (EXTENDED_WITH_AUTH_TEST_PORT,
            auth = [{jwtValidatorConfig: authTestJwtValidator}]);
    check created.attach(new ExtendedService(handler, authTestCard), "rest");
    check created.gracefulStop();
}
