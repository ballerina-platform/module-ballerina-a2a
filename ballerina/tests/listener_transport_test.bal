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


// What the two listeners share: one authenticator per `http:Listener`, and one lock over a service going on and off.

import ballerina/http;
import ballerina/test;

const int JWKS_STUB_PORT = 19367;

isolated int jwksFetches = 0;

listener http:Listener jwksStub = new (JWKS_STUB_PORT);

service /jwks on jwksStub {
    isolated resource function get .() returns json {
        lock {
            jwksFetches += 1;
        }
        return {keys: []};
    }
}

isolated function jwksFetchCount() returns int {
    lock {
        return jwksFetches;
    }
}

function jwksAuth() returns http:ListenerAuthConfig[] => [{jwtValidatorConfig: {
    issuer: "https://idp.example.com",
    audience: "a2a",
    // `ballerina/jwt` fetches the key set when the validator is built, because a cache is configured.
    signatureConfig: {jwksConfig: {url: string `http://localhost:${JWKS_STUB_PORT}/jwks`, cacheConfig: {capacity: 10}}}
}}];

@test:Config {}
function testTwoListenersOnOneHttpListenerShareOneAuthenticator() returns error? {
    int before = jwksFetchCount();
    http:Listener shared = check new (19368);
    _ = check new RestListener(shared, auth = jwksAuth());
    _ = check new JsonRpcListener(shared);
    int afterShared = jwksFetchCount();
    test:assertEquals(afterShared - before, 1, "the identity provider is asked once for both bindings");

    // Two listeners that do not share an `http:Listener` have nothing to share, and each asks for itself.
    _ = check new RestListener(19369, auth = jwksAuth());
    _ = check new JsonRpcListener(19370, auth = jwksAuth());
    test:assertEquals(jwksFetchCount() - afterShared, 2);
}

@test:Config {}
function testALaterListenerWithItsOwnDifferentAuthDoesNotShareTheAuthenticator() returns error? {
    http:Listener shared = check new (19371);
    _ = check new RestListener(shared, auth = jwksAuth());
    int afterFirst = jwksFetchCount();
    // The same issuer and audience with a different key set URL is a different `auth`.
    http:ListenerAuthConfig[] different = [{jwtValidatorConfig: {
        issuer: "https://idp.example.com",
        audience: "a2a",
        signatureConfig: {jwksConfig: {url: string `http://localhost:${JWKS_STUB_PORT}/jwks?other=1`,
            cacheConfig: {capacity: 10}}}
    }}];
    _ = check new JsonRpcListener(shared, auth = different);
    test:assertEquals(jwksFetchCount() - afterFirst, 1, "it was built from its own `auth`");
}

// A detach that ran between an attach's card entry and its mount used to leave the path mounted with no card and no
// record, so a later detach found nothing to remove. Whatever order the two take, the card and the mount must agree.
@test:Config {}
function testAttachAndDetachNeverLeaveACardAndAMountThatDisagree() returns error? {
    http:Listener shared = check new (19372);
    JsonRpcListener rpc = check new (shared);
    check shared.'start();
    RpcService agent = new (new DefaultHandler(new CountingAgent()), rpcTestCard);
    http:Client probe = check new ("http://localhost:19372", httpVersion = http:HTTP_1_1, cache = {enabled: false});
    foreach int i in 0 ..< 25 {
        future<Error?> attaching = start rpc.attach(agent);
        future<Error?> detaching = start rpc.detach(agent);
        Error? attached = wait attaching;
        Error? detached = wait detaching;
        test:assertTrue(detached is (), "a detach is never an error here");
        test:assertTrue(attached is () || attached is InternalError, "an attach that lost is a clean refusal");

        http:Response card = check probe->get("/.well-known/agent-card.json");
        http:Response call = check probe->post("/rpc", {jsonrpc: "2.0", id: "x", method: "ListTasks", params: {}},
                {"A2A-Version": "1.0"});
        boolean carded = card.statusCode == 200;
        boolean mounted = call.statusCode != 404;
        test:assertEquals(mounted, carded, string `round ${i}: mounted ${mounted}, card ${carded}`);
        // Reset for the next round.
        check rpc.detach(agent);
    }
    check shared.gracefulStop();
}
