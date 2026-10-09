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

// The interface URL a listener puts in its served card: `https` when the
// listener really serves TLS (it used to say `http` regardless, so a client
// following the card could not connect), and `publicUrl` when the deployment
// says where clients reach it (a TLS-terminating proxy, a gateway).

import ballerina/http;
import ballerina/test;

const int TLS_URL_TEST_PORT = 19263;
const int PUBLIC_URL_TEST_PORT = 19264;

// A throwaway self-signed certificate for localhost; see tests/resources/README.md.
const string TEST_CERT = "tests/resources/localhost.crt";
const string TEST_KEY = "tests/resources/localhost.key";

final DefaultHandler tlsUrlHandler = new (authTestCard);

listener HttpListener tlsUrlListener = new (TLS_URL_TEST_PORT, tlsUrlHandler,
    secureSocket = {key: {certFile: TEST_CERT, keyFile: TEST_KEY}}
);

final DefaultHandler publicUrlHandler = new (authTestCard);

listener HttpListener publicUrlListener = new (PUBLIC_URL_TEST_PORT, publicUrlHandler,
    publicUrl = "https://agents.example.com/travel/"
);

@test:BeforeSuite
function startUrlTestServers() returns error? {
    check tlsUrlListener.attach(new CountingAgent());
    check publicUrlListener.attach(new CountingAgent());
}

isolated function servedInterfaceUrl(http:Client c) returns string|error {
    http:Response r = check c->get("/.well-known/agent-card.json", {"A2A-Version": "1.0"});
    json card = check r.getJsonPayload();
    json[] interfaces = <json[]>check card.supportedInterfaces;
    return (check interfaces[0].url).toString();
}

// ---- the choice, without certificates ---------------------------------------

@test:Config {}
function testInterfaceUrlPublicUrlWins() {
    test:assertEquals(interfaceUrlFor("https://agents.example.com/travel", "http", "10.0.0.5:9090"),
            "https://agents.example.com/travel");
}

@test:Config {}
function testInterfaceUrlUsesTheSchemeItIsGiven() {
    test:assertEquals(interfaceUrlFor((), "https", "localhost:9090"), "https://localhost:9090");
    test:assertEquals(interfaceUrlFor((), "http", "localhost:9090"), "http://localhost:9090");
}

@test:Config {}
function testPublicUrlIsNormalisedAndValidated() returns error? {
    test:assertEquals(check normalisePublicUrl("https://agents.example.com/travel/"), "https://agents.example.com/travel");
    test:assertEquals(check normalisePublicUrl("http://localhost:9090"), "http://localhost:9090");
    foreach string bad in ["ftp://agents.example.com", "agents.example.com", "https://", "https:///path",
            "https://agents.example.com/a?x=1", "https://agents.example.com/a#frag", ""] {
        string|Error r = normalisePublicUrl(bad);
        test:assertTrue(r is InternalError, string `"${bad}" must be refused`);
    }
}

@test:Config {}
function testListenerRefusesAnUnusablePublicUrl() {
    HttpListener|Error created = new (19265, new DefaultHandler(authTestCard), publicUrl = "ftp://agents.example.com");
    test:assertTrue(created is InternalError);
    if created is Error {
        test:assertTrue(created.message().includes("ListenerConfiguration.publicUrl"), created.message());
    }
}

// ---- a listener that really serves it -----------------------------------------

@test:Config {}
function testPublicUrlIsServedWhateverTheHostHeaderSays() returns error? {
    http:Client c = check new (string `http://localhost:${PUBLIC_URL_TEST_PORT}`, httpVersion = http:HTTP_1_1);
    http:Response r = check c->get("/.well-known/agent-card.json", {"A2A-Version": "1.0", "Host": "internal-host:8080"});
    json card = check r.getJsonPayload();
    json[] interfaces = <json[]>check card.supportedInterfaces;
    test:assertEquals((check interfaces[0].url).toString(), "https://agents.example.com/travel",
            "the configured public URL, without its trailing slash, not the Host header");
}

@test:Config {}
function testTlsListenerAdvertisesHttps() returns error? {
    http:Client c = check new (string `https://localhost:${TLS_URL_TEST_PORT}`,
        secureSocket = {cert: TEST_CERT}
    );
    test:assertEquals(check servedInterfaceUrl(c), string `https://localhost:${TLS_URL_TEST_PORT}`,
            "a card served over TLS must not send clients to plain http");
}

@test:Config {}
function testClientFollowsATlsCardToACompletedTask() returns error? {
    // The interop failure: a client built from the https URL follows the card
    // and used to fail on an http URL for a TLS port.
    HttpClient c = check new (string `https://localhost:${TLS_URL_TEST_PORT}`, clientConfig = {
        secureSocket: {cert: TEST_CERT}
    });
    Task|Message result = check c->sendMessage({
        message: {messageId: "tls-1", role: ROLE_USER, parts: [{text: "hello over tls"}]}
    });
    test:assertTrue(result is Task && result.status.state == TASK_STATE_COMPLETED,
            "the client reached the agent over the URL the card advertised");
}
