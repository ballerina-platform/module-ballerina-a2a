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


// Two A2A listeners on one `http:Listener` publish one card, so they must agree on `auth` and `publicUrl`. The one built
// later takes both from the one built earlier when it sets neither, so they are written once.

import ballerina/http;
import ballerina/test;

function sharedAuth() returns http:ListenerAuthConfig[] => [{jwtValidatorConfig: authTestJwtValidator}];

isolated function rpcSendAt(int port, string path, string? authorization) returns http:Response|error {
    http:Client rpcClient = check new (string `http://localhost:${port}`, httpVersion = http:HTTP_1_1);
    map<string> headers = {"A2A-Version": "1.0"};
    if authorization is string {
        headers["Authorization"] = authorization;
    }
    return rpcClient->post(path, {jsonrpc: "2.0", id: "i-1", method: "SendMessage", params: sendParams("m-inherit")},
            headers);
}

@test:Config {}
function testASecondListenerOnASharedHttpListenerInheritsAuthAndPublicUrl() returns error? {
    http:Listener shared = check new (19346);
    RestListener rest = check new (shared, auth = sharedAuth(), publicUrl = "https://agents.example.com/travel");
    JsonRpcListener rpc = check new (shared);
    DefaultHandler handler = new (new CountingAgent());
    check rest.attach(new FullService(handler, rpcTestCard));
    check rpc.attach(new RpcService(handler, rpcTestCard));
    check shared.'start();

    map<string> urls = check interfaceUrls(check fetchCard(19346));
    test:assertEquals(urls["HTTP+JSON"], "https://agents.example.com/travel/rest");
    test:assertEquals(urls["JSONRPC"], "https://agents.example.com/travel/rpc", "the public URL is inherited");

    http:Response refused = check rpcSendAt(19346, "/rpc", ());
    test:assertEquals(refused.statusCode, 401, "the inherited auth is enforced, not just compared");
    http:Response admitted = check rpcSendAt(19346, "/rpc", "Bearer " + check bearerToken("alice"));
    test:assertEquals(admitted.statusCode, 200);
    check shared.gracefulStop();
}

@test:Config {}
function testTwoExplicitPublicUrlsThatDifferAreStillAConflict() returns error? {
    http:Listener shared = check new (19348);
    RestListener rest = check new (shared, publicUrl = "https://one.example.com");
    JsonRpcListener rpc = check new (shared, publicUrl = "https://two.example.com");
    DefaultHandler handler = new (new CountingAgent());
    check rest.attach(new FullService(handler, rpcTestCard));
    Error? rejected = rpc.attach(new RpcService(handler, rpcTestCard));
    test:assertTrue(rejected is InternalError);
    test:assertTrue((<Error>rejected).message().includes("the same `publicUrl`"), (<Error>rejected).message());
}

@test:Config {}
function testWhatAListenerLeavesUnsetIsItsOwnOnceNothingIsPublishedOnTheHttpListener() returns error? {
    http:Listener shared = check new (19349);
    RestListener first = check new (shared, auth = sharedAuth());
    FullService agent = new (new DefaultHandler(new CountingAgent()), rpcTestCard);
    check first.attach(agent);
    check first.detach(agent);

    // The listener that had `auth` published nothing any more, so a listener built now does not inherit it.
    JsonRpcListener later = check new (shared);
    check later.attach(new RpcService(new DefaultHandler(new CountingAgent()), rpcTestCard));
    check shared.'start();
    http:Response response = check rpcSendAt(19349, "/rpc", ());
    test:assertEquals(response.statusCode, 200, "no authentication was inherited from a listener that is gone");
    check shared.gracefulStop();
}
