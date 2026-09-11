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

// resolveCredentialHeaders (auth.bal): turning a card's declared
// securityRequirements plus a CredentialProvider into the headers one
// request should carry.
//
// Direct unit tests against the module-private function, not through a
// full client construction - no network I/O, no mock server needed.

import ballerina/test;

// resolveCredentialHeaders / credentialHeadersFor (auth.bal): turning a
// card's declared securityRequirements plus a CredentialProvider into the
// headers a request actually carries.
//
// Direct unit tests against the module-private resolution functions - no
// client construction, no network I/O. Each card below declares only what
// the case under test needs.

// Builds a card declaring the given schemes and card-level requirements.
//
isolated function cardWithSecurity(map<SecurityScheme> schemes, SecurityRequirement[] requirements)
        returns AgentCard {
    return {
        name: "secured",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "https://agent.example.com", protocolBinding: "JSONRPC", protocolVersion: "1.0"}],
        skills: [],
        securitySchemes: schemes,
        securityRequirements: requirements,
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
}

@test:Config {}
function testResolveCredentialHeadersBuildsBearerHeader() {
    AgentCard card = cardWithSecurity(
            {"bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}},
            [{"bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"bearer-admin": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"Authorization": "Bearer tok_abc"});
}

@test:Config {}
function testResolveCredentialHeadersBuildsApiKeyHeaderUnderItsDeclaredName() {
    // The header name comes from the card, not from a fixed convention -
    // this is the whole reason an API-key scheme carries a `name` field.
    AgentCard card = cardWithSecurity(
            {"key": <ApiKeySecurityScheme>{'in: "header", name: "X-Payroll-Key"}},
            [{"key": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"X-Payroll-Key": "k_123"});
}

@test:Config {}
function testResolveCredentialHeadersBase64EncodesBasicCredentialWholesale() {
    // RFC 7617 permits ":" in the password but not the username, so a
    // naive split-on-colon corrupts exactly this credential. Nothing here
    // splits: the whole string is encoded as given.
    AgentCard card = cardWithSecurity(
            {"basic": <HttpAuthSecurityScheme>{scheme: "basic"}},
            [{"basic": []}]);
    InMemoryCredentialStore store = new ({"basic": "alice:pa:ss:word"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"Authorization": string `Basic ${"alice:pa:ss:word".toBytes().toBase64()}`});
}

@test:Config {}
function testResolveCredentialHeadersPicksFirstFullySatisfiableRequirement() {
    // securityRequirements is an OR, each entry an AND. The first entry
    // cannot be met (no credential for "mtls-internal"), so resolution
    // must fall through to the second rather than partially satisfying
    // the first.
    AgentCard card = cardWithSecurity(
            {
                "key": <ApiKeySecurityScheme>{'in: "header", name: "X-Key"},
                "mtls-internal": <MutualTlsSecurityScheme>{},
                "bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}
            },
            [{"key": [], "mtls-internal": []}, {"bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123", "bearer-admin": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"Authorization": "Bearer tok_abc"},
            "a partially satisfiable AND must be skipped entirely, not half-applied");
}

@test:Config {}
function testResolveCredentialHeadersSatisfiesEverySchemeInOneRequirement() {
    AgentCard card = cardWithSecurity(
            {
                "key": <ApiKeySecurityScheme>{'in: "header", name: "X-Key"},
                "bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}
            },
            [{"key": [], "bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123", "bearer-admin": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {"X-Key": "k_123", "Authorization": "Bearer tok_abc"});
}

@test:Config {}
function testResolveCredentialHeadersRefusesToOccupyAReservedHeader() {
    // A card is not necessarily signature-verified, so an agent could
    // declare an API-key scheme whose header name is one this library
    // relies on and silently change every request's protocol version.
    AgentCard card = cardWithSecurity(
            {"sneaky": <ApiKeySecurityScheme>{'in: "header", name: "A2A-Version"}},
            [{"sneaky": []}]);
    InMemoryCredentialStore store = new ({"sneaky": "0.3"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {}, "a credential must never be allowed to occupy A2A-Version");
}

@test:Config {}
function testResolveCredentialHeadersSkipsSchemesNeedingATokenExchange() {
    // OAuth2/OIDC/mTLS do not reduce to one string; they belong on
    // clientConfig.auth. Resolution must decline rather than invent a
    // header for them.
    AgentCard card = cardWithSecurity(
            {"oidc": <OpenIdConnectSecurityScheme>{openIdConnectUrl: "https://idp.example.com/.well-known/openid-configuration"}},
            [{"oidc": []}]);
    InMemoryCredentialStore store = new ({"oidc": "tok_abc"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {}, "OpenID Connect must not be resolved into a bearer header here");
}

@test:Config {}
function testResolveCredentialHeadersSkipsApiKeyCarriedOutsideAHeader() {
    AgentCard card = cardWithSecurity(
            {"key": <ApiKeySecurityScheme>{'in: "query", name: "api_key"}},
            [{"key": []}]);
    InMemoryCredentialStore store = new ({"key": "k_123"});
    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers, {}, "a query-borne API key cannot be satisfied through a header map");
}

@test:Config {}
function testResolveCredentialHeadersWithNoProviderOrNoCredential() {
    AgentCard card = cardWithSecurity(
            {"bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}},
            [{"bearer-admin": []}]);
    test:assertEquals(resolveCredentialHeaders(card, ()), {},
            "no provider must resolve to no headers, not an error");
    InMemoryCredentialStore empty = new ();
    test:assertEquals(resolveCredentialHeaders(card, empty), {},
            "an unsatisfiable requirement must send the request bare and let the agent answer, not fail locally");
}

@test:Config {}
function testResolveCredentialHeadersIgnoresUndeclaredScheme() {
    // A requirement naming a scheme the card never declared is malformed.
    // Resolution declines it rather than guessing at the scheme's kind.
    AgentCard card = cardWithSecurity({}, [{"ghost": []}]);
    InMemoryCredentialStore store = new ({"ghost": "tok_abc"});
    test:assertEquals(resolveCredentialHeaders(card, store), {});
}

@test:Config {}
function testInMemoryCredentialStoreReplacesCredentialAfterConstruction() {
    // The point of a provider over a static header map: a refreshed token
    // must not require building a new client.
    AgentCard card = cardWithSecurity(
            {"bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"}},
            [{"bearer-admin": []}]);
    InMemoryCredentialStore store = new ({"bearer-admin": "tok_old"});
    test:assertEquals(resolveCredentialHeaders(card, store), {"Authorization": "Bearer tok_old"});
    store.setCredential("bearer-admin", "tok_new");
    test:assertEquals(resolveCredentialHeaders(card, store), {"Authorization": "Bearer tok_new"},
            "a replaced credential must be picked up on the next resolution");
}

// Regression: two schemes in one AND requirement that resolve to the same
// header name used to overwrite each other silently, and the requirement was
// still reported satisfied -- one credential sent, both claimed.
@test:Config {}
function testCollidingHeaderNamesFailTheRequirement() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [], defaultInputModes: ["text"], defaultOutputModes: ["text"],
        securitySchemes: {
            "bearerAuth": {'type: "http", scheme: "bearer"},
            "headerKey": {'type: "apiKey", 'in: "header", name: "Authorization"}
        },
        securityRequirements: [{"bearerAuth": [], "headerKey": []}]
    };
    InMemoryCredentialStore store = new ({"bearerAuth": "tok", "headerKey": "key"});

    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers.length(), 0,
            "two schemes resolving to Authorization cannot both be satisfied, so the requirement must fail rather than send one and claim both");
}

// The same, with casing that differs -- header names are case-insensitive.
@test:Config {}
function testCollidingHeaderNamesAreCaseInsensitive() {
    AgentCard card = {
        name: "n", description: "d", version: "1.0.0", capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [], defaultInputModes: ["text"], defaultOutputModes: ["text"],
        securitySchemes: {
            "keyOne": {'type: "apiKey", 'in: "header", name: "X-Api-Key"},
            "keyTwo": {'type: "apiKey", 'in: "header", name: "x-api-key"}
        },
        securityRequirements: [{"keyOne": [], "keyTwo": []}]
    };
    InMemoryCredentialStore store = new ({"keyOne": "a", "keyTwo": "b"});

    map<string> headers = resolveCredentialHeaders(card, store);
    test:assertEquals(headers.length(), 0,
            "X-Api-Key and x-api-key are the same header, so this requirement cannot be satisfied");
}
