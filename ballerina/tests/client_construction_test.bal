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

// A refused or unreachable OAuth2 token endpoint must reach the caller of
// `RestClient` and `resolveAgentCard` as a typed `a2a:Error`, never as a panic.
//
// `ballerina/oauth2` fetches the first token while the `http:Client` is being
// built and panics on failure; without the trap in `newHttpClient` a mistyped
// client secret would crash the caller instead of being handled. If the panic
// escaped, it would abort the test run, so a plain type check is enough.

import ballerina/http;
import ballerina/test;

const int TOKEN_STUB_PORT = 19259;
final string tokenStubUrl = string `http://localhost:${TOKEN_STUB_PORT}`;

// The Authorization header `ballerina/oauth2` sends for the right client.
final string expectedClientAuth = "Basic " + "client-1:right-secret".toBytes().toBase64();

// A token endpoint that issues a token to one client and refuses everyone else.
listener http:Listener tokenStub = new (TOKEN_STUB_PORT);

service / on tokenStub {
    resource function post token(http:Request req) returns http:Response {
        http:Response res = new;
        string|http:HeaderNotFoundError auth = req.getHeader("Authorization");
        if auth is string && auth == expectedClientAuth {
            res.setJsonPayload({access_token: "issued-token", token_type: "Bearer", expires_in: 300});
        } else {
            res.statusCode = 401;
            res.setJsonPayload({"error": "invalid_client"});
        }
        return res;
    }

    // Serves the card the URL-based tests resolve, whatever path is asked for.
    resource function get [string... path]() returns json {
        return {
            name: "n", description: "d", version: "1.0.0",
            supportedInterfaces: [{url: tokenStubUrl, protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}],
            capabilities: {}, skills: [], defaultInputModes: ["text"], defaultOutputModes: ["text"]
        };
    }
}

isolated function oauthConfig(string tokenUrl, string secret) returns http:ClientConfiguration => {
    auth: {tokenUrl, clientId: "client-1", clientSecret: secret}
};

function cardAt(string url) returns AgentCard => {
    name: "n", description: "d", version: "1.0.0", capabilities: {},
    supportedInterfaces: [{url, protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}],
    skills: [], defaultInputModes: ["text"], defaultOutputModes: ["text"]
};

@test:Config {}
function testRestClientRefusedTokenIsATypedError() returns error? {
    RestClient|Error c = new (cardAt(tokenStubUrl), clientConfig = oauthConfig(tokenStubUrl + "/token", "wrong-secret"));
    test:assertTrue(c is InternalError, "a refused token request must be a returned error, not a panic");
    if c is Error {
        test:assertTrue(c.message().includes("could not create the HTTP client"), c.message());
        test:assertTrue(c.message().includes(tokenStubUrl), "the message names the agent it was for: " + c.message());
    }
}

@test:Config {}
function testRestClientUnreachableTokenEndpointIsATypedError() returns error? {
    RestClient|Error c = new (cardAt(tokenStubUrl), clientConfig = oauthConfig("http://localhost:1/token", "right-secret"));
    test:assertTrue(c is InternalError, "an unreachable token endpoint must be a returned error, not a panic");
}

@test:Config {}
function testRestClientFromUrlRefusedTokenIsATypedError() returns error? {
    // Given a URL rather than a card, the card is resolved first, through a
    // second http:Client built from the same configuration.
    RestClient|Error c = new (tokenStubUrl, clientConfig = oauthConfig(tokenStubUrl + "/token", "wrong-secret"));
    test:assertTrue(c is InternalError, "the discovery client's failure must be typed too");
}

@test:Config {}
function testResolveAgentCardRefusedTokenIsATypedError() returns error? {
    AgentCard|Error card = resolveAgentCard(tokenStubUrl,
            clientConfig = oauthConfig(tokenStubUrl + "/token", "wrong-secret"));
    test:assertTrue(card is InternalError, "resolveAgentCard promises a typed error");
}

@test:Config {}
function testRestClientRightSecretStillConstructs() returns error? {
    // The happy path, so the trap is not swallowing a working configuration.
    RestClient c = check new (cardAt(tokenStubUrl), clientConfig = oauthConfig(tokenStubUrl + "/token", "right-secret"));
    test:assertTrue(c is RestClient);
    AgentCard card = check resolveAgentCard(tokenStubUrl,
            clientConfig = oauthConfig(tokenStubUrl + "/token", "right-secret"));
    test:assertEquals(card.name, "n");
}

// A card lists its interfaces in the server's order of preference, and an older interface of a binding may come
// ahead of its 1.0 one. The client speaks 1.0, so it builds against the 1.0 entry rather than refusing the card.
function cardListing(TransportBinding binding, string[] versions) returns AgentCard {
    AgentInterface[] interfaces = versions.map(version => <AgentInterface>{
        url: string `http://localhost:19399/v${version}`, protocolBinding: binding, protocolVersion: version,
        tenant: string `tenant-${version}`
    });
    return {
        name: "n", description: "d", version: "1.0.0", capabilities: {}, supportedInterfaces: interfaces,
        skills: [], defaultInputModes: ["text"], defaultOutputModes: ["text"]
    };
}

@test:Config {}
function testClientsBuildAgainstTheV1InterfaceListedAfterAnOlderOne() returns error? {
    AgentCard rpc = cardListing(JSONRPC, ["0.3", "1.0"]);
    test:assertEquals(check primaryUrl(rpc, JSONRPC), "http://localhost:19399/v1.0");
    test:assertEquals((check selectV1Interface(rpc, JSONRPC))?.tenant, "tenant-1.0");
    test:assertEquals(requireV1Interface(rpc, JSONRPC), ());
    JsonRpcClient rpcClient = check new (rpc);

    AgentCard rest = cardListing(HTTP_JSON, ["0.3", "1.0"]);
    test:assertEquals(check primaryUrl(rest, HTTP_JSON), "http://localhost:19399/v1.0");
    test:assertEquals((check selectV1Interface(rest, HTTP_JSON))?.tenant, "tenant-1.0");
    test:assertEquals(requireV1Interface(rest, HTTP_JSON), ());
    RestClient restClient = check new (rest);
    test:assertTrue(rpcClient is JsonRpcClient && restClient is RestClient);
}

@test:Config {}
function testClientsStillRefuseACardWhoseOnlyInterfaceIsAnotherVersion() {
    JsonRpcClient|Error rpc = new (cardListing(JSONRPC, ["0.3"]));
    test:assertTrue(rpc is VersionNotSupportedError, "a 0.3-only JSON-RPC card must still be refused");
    RestClient|Error rest = new (cardListing(HTTP_JSON, ["0.3", "1.1"]));
    test:assertTrue(rest is VersionNotSupportedError, "a card with no 1.0 interface must still be refused");
}
