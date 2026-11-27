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


// A service is served at the path it is declared at, and at the binding's default (`/rest`, `/rpc`) when it is declared
// without one. The Agent Card is served at its own path whatever that is, and gives each interface's real address.

import ballerina/http;
import ballerina/test;

isolated function rpcPostAt(int port, string path, json body) returns http:Response|error {
    http:Client rpcClient = check new (string `http://localhost:${port}`, httpVersion = http:HTTP_1_1);
    return rpcClient->post(path, body, {"A2A-Version": "1.0"});
}

isolated function fetchCard(int port) returns json|error {
    http:Client cardClient = check new (string `http://localhost:${port}`, httpVersion = http:HTTP_1_1,
            cache = {enabled: false});
    return cardClient->get("/.well-known/agent-card.json");
}

isolated function interfaceUrls(json card) returns map<string>|error {
    map<string> urls = {};
    foreach json iface in <json[]>check card.supportedInterfaces {
        urls[(check iface.protocolBinding).toString()] = (check iface.url).toString();
    }
    return urls;
}

isolated function sendParams(string messageId) returns json =>
    {message: {messageId, role: "ROLE_USER", parts: [{text: "hello"}]}};

@test:Config {}
function testJsonRpcIsServedAtThePathItIsDeclaredAt() returns error? {
    http:Listener shared = check new (19334);
    JsonRpcListener rpc = check new (shared);
    check rpc.attach(new RpcService(new DefaultHandler(new CountingAgent()), rpcTestCard), ["agents", "travel"]);
    check shared.'start();

    map<string> urls = check interfaceUrls(check fetchCard(19334));
    test:assertEquals(urls["JSONRPC"], "http://localhost:19334/agents/travel");

    http:Response sent = check rpcPostAt(19334, "/agents/travel",
            {jsonrpc: "2.0", id: "p-1", method: "SendMessage", params: sendParams("m-path")});
    json reply = check sent.getJsonPayload();
    test:assertTrue(reply.result is map<json>, reply.toJsonString());
    http:Response default = check rpcPostAt(19334, "/rpc",
            {jsonrpc: "2.0", id: "p-2", method: "SendMessage", params: sendParams("m-default")});
    test:assertEquals(default.statusCode, 404, "the default path is not served when the service is declared elsewhere");
    check shared.gracefulStop();
}

@test:Config {}
function testJsonRpcAtTheRootLeavesTheCardAtItsOwnPath() returns error? {
    http:Listener shared = check new (19335);
    JsonRpcListener rpc = check new (shared);
    // `service / on listener` reaches `attach` as an empty array.
    check rpc.attach(new RpcService(new DefaultHandler(new CountingAgent()), rpcTestCard), []);
    check shared.'start();

    map<string> urls = check interfaceUrls(check fetchCard(19335));
    test:assertEquals(urls["JSONRPC"], "http://localhost:19335", "the root has no path to add to the address");

    http:Response sent = check rpcPostAt(19335, "/",
            {jsonrpc: "2.0", id: "r-1", method: "SendMessage", params: sendParams("m-root")});
    json reply = check sent.getJsonPayload();
    test:assertTrue(reply.result is map<json>, reply.toJsonString());
    http:Response card = check rpcPostAt(19335, "/.well-known/agent-card.json", {});
    test:assertNotEquals(card.statusCode, 200, "the card path takes GET, not the JSON-RPC post");
    check shared.gracefulStop();
}

@test:Config {}
function testBothBindingsShareOneListenerWithJsonRpcAtTheRoot() returns error? {
    http:Listener shared = check new (19336);
    RestListener rest = check new (shared);
    JsonRpcListener rpc = check new (shared);
    DefaultHandler handler = new (new CountingAgent());
    check rest.attach(new FullService(handler, rpcTestCard));
    check rpc.attach(new RpcService(handler, rpcTestCard), []);
    check shared.'start();

    map<string> urls = check interfaceUrls(check fetchCard(19336));
    test:assertEquals(urls["HTTP+JSON"], "http://localhost:19336/rest");
    test:assertEquals(urls["JSONRPC"], "http://localhost:19336");

    http:Client c = check new ("http://localhost:19336", httpVersion = http:HTTP_1_1);
    http:Response viaRest = check c->post("/rest/message:send", sendParams("m-rest"),
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(viaRest.statusCode, 200);
    http:Response viaRpc = check rpcPostAt(19336, "/",
            {jsonrpc: "2.0", id: "b-1", method: "SendMessage", params: sendParams("m-rpc")});
    test:assertEquals(viaRpc.statusCode, 200);
    check shared.gracefulStop();
}

@test:Config {}
function testRestIsServedAtThePathItIsDeclaredAt() returns error? {
    http:Listener shared = check new (19337);
    RestListener rest = check new (shared);
    check rest.attach(new FullService(new DefaultHandler(new CountingAgent()), rpcTestCard), ["agents", "weather"]);
    check shared.'start();

    map<string> urls = check interfaceUrls(check fetchCard(19337));
    test:assertEquals(urls["HTTP+JSON"], "http://localhost:19337/agents/weather");

    http:Client c = check new ("http://localhost:19337", httpVersion = http:HTTP_1_1);
    http:Response sent = check c->post("/agents/weather/message:send", sendParams("m-weather"),
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(sent.statusCode, 200);
    // The colon routes are translated whatever the base path is.
    http:Response cancel = check c->post("/agents/weather/tasks/no-such-task:cancel", {},
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(cancel.statusCode, 404, "an unknown task, not an unknown route");
    http:Response old = check c->post("/rest/message:send", sendParams("m-old"),
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(old.statusCode, 404);
    check shared.gracefulStop();
}

@test:Config {}
function testTwoServicesAtOnePathOnOneListenerClash() returns error? {
    http:Listener shared = check new (19338);
    RestListener rest = check new (shared);
    JsonRpcListener rpc = check new (shared);
    DefaultHandler handler = new (new CountingAgent());
    check rest.attach(new FullService(handler, rpcTestCard));

    Error? sameDefault = rpc.attach(new RpcService(handler, rpcTestCard), ["rest"]);
    test:assertTrue(sameDefault is InternalError);
    test:assertTrue((<Error>sameDefault).message().includes("already attached at /rest"),
            (<Error>sameDefault).message());

    check rpc.attach(new RpcService(handler, rpcTestCard), []);
    JsonRpcListener second = check new (shared);
    Error? root = second.attach(new RpcService(handler, rpcTestCard), []);
    test:assertTrue(root is InternalError, "the root is taken");
    test:assertTrue((<Error>root).message().includes("already attached at /"), (<Error>root).message());
}

isolated service class UserWellKnownService {
    *http:Service;

    isolated resource function get openid\-configuration() returns string => "the user's own";
}

@test:Config {}
function testAUsersOwnWellKnownServiceStillWorksBesideTheCard() returns error? {
    http:Listener shared = check new (19339);
    check shared.attach(new UserWellKnownService(), [".well-known"]);
    JsonRpcListener rpc = check new (shared);
    check rpc.attach(new RpcService(new DefaultHandler(new CountingAgent()), rpcTestCard));
    check shared.'start();

    map<string> urls = check interfaceUrls(check fetchCard(19339));
    test:assertEquals(urls["JSONRPC"], "http://localhost:19339/rpc");
    http:Client c = check new ("http://localhost:19339", httpVersion = http:HTTP_1_1);
    string own = check c->get("/.well-known/openid-configuration");
    test:assertEquals(own, "the user's own");
    check shared.gracefulStop();
}

@test:Config {}
function testTheMountPathOfADetachedServiceIsFreeAgain() returns error? {
    http:Listener shared = check new (19345);
    JsonRpcListener rpc = check new (shared);
    RpcService rpcService = new (new DefaultHandler(new CountingAgent()), rpcTestCard);
    check rpc.attach(rpcService, ["a2a"]);
    check rpc.detach(rpcService);
    JsonRpcListener other = check new (shared);
    check other.attach(new RpcService(new DefaultHandler(new CountingAgent()), rpcTestCard), ["a2a"]);
}
