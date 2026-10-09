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

// How the served Agent Card declares its security (specification section 4.5
// and the a2a.proto `SecurityScheme` oneof), checked with a raw HTTP client:
// this module's own client parses both the wrapped v1.0 shape and the flat
// one, so only a raw fetch can catch a server that encodes the wrong one.

import ballerina/http;
import ballerina/test;

const int CARD_SECURITY_TEST_PORT = 19253;

// One scheme of each of the five kinds.
final map<SecurityScheme> allSchemeKinds = {
    "key": <ApiKeySecurityScheme>{'in: "header", name: "X-API-Key", description: "an API key"},
    "bearer": <HttpAuthSecurityScheme>{scheme: "Bearer", bearerFormat: "JWT"},
    "oauth": <OAuth2SecurityScheme>{
        flows: {clientCredentials: {tokenUrl: "https://idp.example.com/token", scopes: {"a2a:invoke": "Call the agent"}}},
        oauth2MetadataUrl: "https://idp.example.com/.well-known/oauth-authorization-server"
    },
    "oidc": <OpenIdConnectSecurityScheme>{openIdConnectUrl: "https://idp.example.com/.well-known/openid-configuration"},
    "mtls": <MutualTlsSecurityScheme>{}
};

final DefaultHandler cardSecurityHandler = new ({
    name: "Card Security Agent",
    description: "Declares one scheme of each kind",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: [],
    securitySchemes: allSchemeKinds,
    securityRequirements: [{"key": []}]
});

listener HttpListener cardSecurityListener = new (CARD_SECURITY_TEST_PORT, cardSecurityHandler);

@test:BeforeSuite
function startCardSecurityServer() returns error? {
    check cardSecurityListener.attach(new EchoAgent());
}

isolated function servedSchemes(int port) returns map<json>|error {
    http:Client raw = check new (string `http://localhost:${port}`);
    json card = check raw->get("/.well-known/agent-card.json");
    map<json> cardMap = check card.ensureType();
    return check cardMap["securitySchemes"].ensureType();
}

isolated function armOf(map<json> schemes, string name, string arm) returns map<json>|error {
    map<json> entry = check schemes[name].ensureType();
    test:assertEquals(entry.keys(), [arm],
            string `scheme "${name}" must be exactly one oneof arm, "${arm}", with no flat "type" beside it`);
    return check entry[arm].ensureType();
}

@test:Config {}
function testServedSecuritySchemesAreWrappedInTheirOneofArm() returns error? {
    map<json> schemes = check servedSchemes(CARD_SECURITY_TEST_PORT);
    test:assertEquals(schemes.keys().sort(), ["bearer", "key", "mtls", "oauth", "oidc"]);

    map<json> bearer = check armOf(schemes, "bearer", "httpAuthSecurityScheme");
    test:assertEquals(bearer["scheme"], "Bearer");
    test:assertEquals(bearer["bearerFormat"], "JWT");
    test:assertFalse(bearer.hasKey("type"), "the flat `type` discriminator is not part of the v1.0 shape");

    map<json> oidc = check armOf(schemes, "oidc", "openIdConnectSecurityScheme");
    test:assertEquals(oidc["openIdConnectUrl"], "https://idp.example.com/.well-known/openid-configuration");

    map<json> mtls = check armOf(schemes, "mtls", "mtlsSecurityScheme");
    test:assertEquals(mtls.length(), 0, "mutual TLS has no fields");
}

@test:Config {}
function testServedApiKeySchemeUsesLocationNotIn() returns error? {
    map<json> schemes = check servedSchemes(CARD_SECURITY_TEST_PORT);
    map<json> key = check armOf(schemes, "key", "apiKeySecurityScheme");
    test:assertEquals(key["location"], "header", "the proto field is `location`; `in` is OpenAPI's spelling");
    test:assertFalse(key.hasKey("in"));
    test:assertEquals(key["name"], "X-API-Key");
    test:assertEquals(key["description"], "an API key");
}

@test:Config {}
function testServedOAuth2SchemeKeepsItsFlows() returns error? {
    map<json> schemes = check servedSchemes(CARD_SECURITY_TEST_PORT);
    map<json> oauth = check armOf(schemes, "oauth", "oauth2SecurityScheme");
    test:assertEquals(oauth["oauth2MetadataUrl"], "https://idp.example.com/.well-known/oauth-authorization-server");
    map<json> flows = check oauth["flows"].ensureType();
    test:assertEquals(flows.keys(), ["clientCredentials"], "the flow is itself a oneof, keyed by its name");
    map<json> clientCredentials = check flows["clientCredentials"].ensureType();
    test:assertEquals(clientCredentials["tokenUrl"], "https://idp.example.com/token");
}

@test:Config {}
function testServedSecuritySchemesRoundTripThroughTheClient() returns error? {
    AgentCard card = check resolveAgentCard(string `http://localhost:${CARD_SECURITY_TEST_PORT}`);
    map<SecurityScheme>? parsed = card.securitySchemes;
    test:assertTrue(parsed is map<SecurityScheme>);
    test:assertEquals(<map<SecurityScheme>>parsed, allSchemeKinds,
            "what the server serves must parse back into what the developer declared");
}

@test:Config {}
function testCardWithoutSecuritySchemesServesNone() returns error? {
    http:Client raw = check new (string `http://localhost:${SERVER_TEST_PORT}`);
    json card = check raw->get("/.well-known/agent-card.json");
    map<json> cardMap = check card.ensureType();
    test:assertFalse(cardMap.hasKey("securitySchemes"), "nothing declared, nothing served");
}
