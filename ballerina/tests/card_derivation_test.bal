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

// The card's security declaration derived from `ListenerConfiguration.auth`
// (specification sections 7.3 and 13.3), checked on the wire with a raw HTTP
// client and end to end with this package's own client.

import ballerina/http;
import ballerina/test;

const int TWO_JWT_AUTH_TEST_PORT = 19254;
const int DECLARED_SECURITY_TEST_PORT = 19255;

// Two entries of the same kind, with different scopes.
final DefaultHandler twoJwtAuthHandler = new (authTestCard);

listener HttpListener twoJwtAuthListener = new (TWO_JWT_AUTH_TEST_PORT, twoJwtAuthHandler,
    auth = [
        {jwtValidatorConfig: authTestJwtValidator, scopes: "a2a:read"},
        {jwtValidatorConfig: authTestJwtValidator, scopes: ["a2a:write", "a2a:admin"]}
    ]
);

// The developer declares their own security: nothing is derived over it.
final DefaultHandler declaredSecurityHandler = new ({
    name: "Declared Security Agent",
    description: "Declares an OpenID Connect scheme itself",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: [],
    securitySchemes: {
        "oidc": <OpenIdConnectSecurityScheme>{openIdConnectUrl: "https://idp.example.com/.well-known/openid-configuration"}
    },
    securityRequirements: [{"oidc": ["openid"]}]
});

listener HttpListener declaredSecurityListener = new (DECLARED_SECURITY_TEST_PORT, declaredSecurityHandler,
    auth = [{jwtValidatorConfig: authTestJwtValidator}]
);

@test:BeforeSuite
function startCardDerivationServers() returns error? {
    check twoJwtAuthListener.attach(new CountingAgent());
    check declaredSecurityListener.attach(new CountingAgent());
}

isolated function servedCardOf(int port) returns map<json>|error {
    http:Client raw = check new (string `http://localhost:${port}`);
    json card = check raw->get("/.well-known/agent-card.json");
    return card.ensureType();
}

isolated function requirementsOf(map<json> card) returns json => card["securityRequirements"];

isolated function schemesOf(map<json> card) returns map<json>|error => card["securitySchemes"].ensureType();

@test:Config {}
function testDerivedCardDeclaresBearerForJwt() returns error? {
    map<json> card = check servedCardOf(JWT_AUTH_TEST_PORT);
    map<json> schemes = check schemesOf(card);
    test:assertEquals(schemes.keys(), ["bearerAuth"]);
    map<json> bearer = check armOf(schemes, "bearerAuth", "httpAuthSecurityScheme");
    test:assertEquals(bearer["scheme"], "Bearer");
    test:assertEquals(bearer["bearerFormat"], "JWT");
    test:assertEquals(requirementsOf(card), <json>[{"schemes": {"bearerAuth": {"list": []}}}]);
}

@test:Config {}
function testDerivedCardDeclaresBearerWithoutFormatForOAuth2Introspection() returns error? {
    map<json> card = check servedCardOf(OAUTH2_AUTH_TEST_PORT);
    map<json> bearer = check armOf(check schemesOf(card), "bearerAuth", "httpAuthSecurityScheme");
    test:assertEquals(bearer["scheme"], "Bearer");
    test:assertFalse(bearer.hasKey("bearerFormat"), "an opaque OAuth2 token is not a JWT, so no format is claimed");
}

@test:Config {}
function testDerivedCardHasOneRequirementPerEntryInOrder() returns error? {
    map<json> card = check servedCardOf(MULTI_AUTH_TEST_PORT);
    map<json> schemes = check schemesOf(card);
    test:assertEquals(schemes.keys().sort(), ["basicAuth", "bearerAuth"]);
    map<json> basic = check armOf(schemes, "basicAuth", "httpAuthSecurityScheme");
    test:assertEquals(basic["scheme"], "Basic");
    test:assertEquals(requirementsOf(card), <json>[
        {"schemes": {"bearerAuth": {"list": []}}},
        {"schemes": {"basicAuth": {"list": []}}}
    ], "the entries are alternatives, so each is its own requirement, in the order configured");
}

@test:Config {}
function testDerivedCardCarriesEachEntrysScopes() returns error? {
    map<json> scoped = check servedCardOf(SCOPED_AUTH_TEST_PORT);
    test:assertEquals(requirementsOf(scoped), <json>[{"schemes": {"bearerAuth": {"list": ["a2a:write"]}}}]);

    map<json> twoJwt = check servedCardOf(TWO_JWT_AUTH_TEST_PORT);
    test:assertEquals((check schemesOf(twoJwt)).keys(), ["bearerAuth"], "two Bearer entries are still one scheme");
    test:assertEquals(requirementsOf(twoJwt), <json>[
        {"schemes": {"bearerAuth": {"list": ["a2a:read"]}}},
        {"schemes": {"bearerAuth": {"list": ["a2a:write", "a2a:admin"]}}}
    ]);
}

@test:Config {}
function testDeclaredSecurityIsNeverOverwritten() returns error? {
    map<json> card = check servedCardOf(DECLARED_SECURITY_TEST_PORT);
    map<json> schemes = check schemesOf(card);
    test:assertEquals(schemes.keys(), ["oidc"], "the developer knows the provider's URLs; nothing is added beside them");
    test:assertEquals(requirementsOf(card), <json>[{"schemes": {"oidc": {"list": ["openid"]}}}]);
}

@test:Config {}
function testDerivedSecurityIsOnTheExtendedCardToo() returns error? {
    string token = check bearerToken("alice");
    http:Response r = check authCall(JWT_AUTH_TEST_PORT, "GET", "/extendedAgentCard", "Bearer " + token);
    json payload = check r.getJsonPayload();
    map<json> card = check payload.ensureType();
    test:assertEquals((check schemesOf(card)).keys(), ["bearerAuth"],
            "a client replaces its cached card with the extended one, so it must declare the same scheme");
    test:assertEquals(requirementsOf(card), <json>[{"schemes": {"bearerAuth": {"list": []}}}]);
}

// Specification 13.3: the extended card SHOULD carry appropriate caching
// headers. It is only for authenticated callers, so no shared cache may keep
// it; the public card stays cacheable by anyone.
@test:Config {}
function testTheExtendedCardIsPrivatelyCacheable() returns error? {
    string token = check bearerToken("alice");
    http:Response extended = check authCall(JWT_AUTH_TEST_PORT, "GET", "/extendedAgentCard", "Bearer " + token);
    test:assertEquals(extended.statusCode, 200);
    test:assertEquals(check extended.getHeader("Cache-Control"), "private, max-age=300");

    http:Response publicCard = check authCall(JWT_AUTH_TEST_PORT, "GET", "/.well-known/agent-card.json", ());
    test:assertEquals(check publicCard.getHeader("Cache-Control"), "max-age=300");
}

@test:Config {}
function testNoAuthDerivesNothing() returns error? {
    map<json> card = check servedCardOf(SERVER_TEST_PORT);
    test:assertFalse(card.hasKey("securitySchemes"));
    test:assertFalse(card.hasKey("securityRequirements"));
}

// ---- specification section 7.3, end to end -------------------------------
//
// Discovery -> scheme name -> credential -> header, with nothing written by
// hand: the client is given only the agent's URL and a store keyed by the
// scheme name the card declares.

@test:Config {}
function testClientAuthenticatesFromTheDerivedCard() returns error? {
    string token = check bearerToken("alice-discovery");
    HttpClient c = check new (string `http://localhost:${JWT_AUTH_TEST_PORT}`,
        credentials = new InMemoryCredentialStore({"bearerAuth": token}));

    Task|Message reply = check c->sendMessage({
        message: {messageId: "m-discovery", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(reply is Task, "the agent drives a task");
    Task task = <Task>reply;
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    Task fetched = check c->getTask({id: task.id});
    test:assertEquals(fetched.id, task.id, "every later request carries the credential too");
}

@test:Config {}
function testClientResolvesTheDerivedCardIntoTypedSchemes() returns error? {
    AgentCard card = check resolveAgentCard(string `http://localhost:${MULTI_AUTH_TEST_PORT}`);
    map<SecurityScheme>? schemes = card.securitySchemes;
    test:assertTrue(schemes is map<SecurityScheme>);
    SecurityScheme? bearer = (<map<SecurityScheme>>schemes)["bearerAuth"];
    test:assertTrue(bearer is HttpAuthSecurityScheme && bearer.scheme == "Bearer");
    test:assertEquals(card.securityRequirements, <SecurityRequirement[]>[{"bearerAuth": []}, {"basicAuth": []}]);
}

@test:Config {}
function testClientWithoutTheCredentialIsRejected() returns error? {
    HttpClient c = check new (string `http://localhost:${JWT_AUTH_TEST_PORT}`);
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m-anon", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(result is Error, "no credential in the store, so nothing is sent for the listener to accept");
}
