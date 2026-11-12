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

import ballerina/http;
import ballerina/test;

const int INPUT_MODES_STRICT_PORT = 19290;
const int INPUT_MODES_LENIENT_PORT = 19291;
const int INPUT_MODES_RPC_STRICT_PORT = 19292;
const int INPUT_MODES_RPC_LENIENT_PORT = 19293;

isolated class InputModesAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.complete();
        return;
    }
}

function inputModesCard(string[] defaultModes, string[]? skillModes = ()) returns AgentCard {
    AgentSkill skill = {id: "echo", name: "Echo", description: "Echoes", tags: ["echo"]};
    if skillModes is string[] {
        skill.inputModes = skillModes;
    }
    return {
        name: "Input Modes Agent",
        description: "Declares what it accepts",
        version: "1.0.0",
        skills: [skill],
        defaultInputModes: defaultModes,
        defaultOutputModes: ["text/plain"],
        capabilities: {},
        supportedInterfaces: []
    };
}

listener RestListener inputModesStrictListener = new (INPUT_MODES_STRICT_PORT, validateInputModes = true);
listener RestListener inputModesLenientListener = new (INPUT_MODES_LENIENT_PORT);
listener JsonRpcListener inputModesRpcStrictListener = new (INPUT_MODES_RPC_STRICT_PORT, validateInputModes = true);
listener JsonRpcListener inputModesRpcLenientListener = new (INPUT_MODES_RPC_LENIENT_PORT);

@test:BeforeSuite
function startInputModesServers() returns error? {
    AgentCard card = inputModesCard(["text/plain"], ["application/json"]);
    check inputModesStrictListener.attach(new FullService(new DefaultHandler(new InputModesAgent()), card));
    check inputModesLenientListener.attach(new FullService(new DefaultHandler(new InputModesAgent()), card));
    check inputModesRpcStrictListener.attach(new RpcService(new DefaultHandler(new InputModesAgent()), card));
    check inputModesRpcLenientListener.attach(new RpcService(new DefaultHandler(new InputModesAgent()), card));
}

function sendWithMediaType(int port, string path, string? mediaType) returns http:Response|error {
    http:Client rest = check new (string `http://localhost:${port}/rest`, httpVersion = http:HTTP_1_1);
    map<json> part = {text: "hello"};
    if mediaType is string {
        part["mediaType"] = mediaType;
    }
    json body = {message: {messageId: "modes-1", role: "ROLE_USER", parts: [part]}};
    return rest->post(path, body, {"A2A-Version": "1.0"});
}

@test:Config {}
function testAnUndeclaredMediaTypeIsRejectedOverRest() returns error? {
    http:Response res = check sendWithMediaType(INPUT_MODES_STRICT_PORT, "/message:send", "image/png");
    test:assertEquals(res.statusCode, 400);
    string text = check res.getTextPayload();
    test:assertTrue(text.includes("image/png"), text);
    test:assertTrue(text.includes("CONTENT_TYPE_NOT_SUPPORTED"), text);
}

@test:Config {}
function testAnUndeclaredMediaTypeIsRejectedOnTheStreamOverRest() returns error? {
    http:Response res = check sendWithMediaType(INPUT_MODES_STRICT_PORT, "/message:stream", "image/png");
    test:assertEquals(res.statusCode, 400);
    test:assertTrue((check res.getTextPayload()).includes("image/png"));
}

@test:Config {}
function testADeclaredMediaTypeIsAcceptedOverRest() returns error? {
    http:Response res = check sendWithMediaType(INPUT_MODES_STRICT_PORT, "/message:send", "text/plain; charset=UTF-8");
    test:assertEquals(res.statusCode, 200);
}

@test:Config {}
function testASkillsInputModeWidensTheAcceptedSetOverRest() returns error? {
    http:Response res = check sendWithMediaType(INPUT_MODES_STRICT_PORT, "/message:send", "application/json");
    test:assertEquals(res.statusCode, 200);
}

@test:Config {}
function testAPartWithoutAMediaTypeIsNotCheckedOverRest() returns error? {
    http:Response res = check sendWithMediaType(INPUT_MODES_STRICT_PORT, "/message:send", ());
    test:assertEquals(res.statusCode, 200);
}

@test:Config {}
function testValidationIsOffByDefaultOverRest() returns error? {
    http:Response res = check sendWithMediaType(INPUT_MODES_LENIENT_PORT, "/message:send", "image/png");
    test:assertEquals(res.statusCode, 200);
}

function messageWithMediaTypes(string?... mediaTypes) returns Message {
    Part[] parts = [];
    foreach string? mediaType in mediaTypes {
        Part part = {text: "x"};
        if mediaType is string {
            part.mediaType = mediaType;
        }
        parts.push(part);
    }
    return {messageId: "m", role: ROLE_USER, parts};
}

@test:Config {}
function testABareDeclaredTypeMatchesItsSubtypes() returns error? {
    AgentCard card = inputModesCard(["text"]);
    check checkInputModes(card, messageWithMediaTypes("text/markdown", "TEXT/Plain"));
    Error? rejected = checkInputModes(card, messageWithMediaTypes("image/png"));
    test:assertTrue(rejected is ContentTypeNotSupportedError);
}

@test:Config {}
function testWildcardsAreHonoured() returns error? {
    check checkInputModes(inputModesCard(["image/*"]), messageWithMediaTypes("image/png"));
    check checkInputModes(inputModesCard(["*/*"]), messageWithMediaTypes("video/mp4"));
    Error? rejected = checkInputModes(inputModesCard(["image/*"]), messageWithMediaTypes("text/plain"));
    test:assertTrue(rejected is ContentTypeNotSupportedError);
}

@test:Config {}
function testACardDeclaringNoInputModesAcceptsEverything() returns error? {
    check checkInputModes(inputModesCard([]), messageWithMediaTypes("video/mp4"));
}

@test:Config {}
function testTheFirstUnsupportedPartIsNamed() {
    Error? rejected = checkInputModes(inputModesCard(["text/plain"]),
            messageWithMediaTypes("text/plain", (), "audio/ogg", "image/png"));
    test:assertTrue(rejected is ContentTypeNotSupportedError);
    test:assertTrue((<Error>rejected).message().includes("audio/ogg"));
}

function rpcSendWithMediaType(int port, string method, string? mediaType) returns json|error {
    map<json> part = {text: "hello"};
    if mediaType is string {
        part["mediaType"] = mediaType;
    }
    return rpcCall(port, method, {message: {messageId: "modes-rpc", role: "ROLE_USER", parts: [part]}});
}

@test:Config {}
function testAnUndeclaredMediaTypeIsRejectedOverJsonRpc() returns error? {
    json reply = check rpcSendWithMediaType(INPUT_MODES_RPC_STRICT_PORT, "SendMessage", "image/png");
    test:assertEquals(check reply.'error.code, -32005, reply.toJsonString());
    test:assertTrue(reply.toJsonString().includes("image/png"), reply.toJsonString());
}

@test:Config {}
function testAnUndeclaredMediaTypeIsRejectedOnTheStreamOverJsonRpc() returns error? {
    json reply = check rpcSendWithMediaType(INPUT_MODES_RPC_STRICT_PORT, "SendStreamingMessage", "image/png");
    test:assertEquals(check reply.'error.code, -32005, reply.toJsonString());
}

@test:Config {}
function testDeclaredAndUnstatedMediaTypesAreAcceptedOverJsonRpc() returns error? {
    foreach string? mediaType in ["text/plain; charset=UTF-8", "application/json", ()] {
        json reply = check rpcSendWithMediaType(INPUT_MODES_RPC_STRICT_PORT, "SendMessage", mediaType);
        test:assertTrue(reply.toJsonString().includes("result"), reply.toJsonString());
        test:assertFalse(reply.toJsonString().includes("\"error\""), reply.toJsonString());
    }
}

@test:Config {}
function testValidationIsOffByDefaultOverJsonRpc() returns error? {
    json reply = check rpcSendWithMediaType(INPUT_MODES_RPC_LENIENT_PORT, "SendMessage", "image/png");
    test:assertFalse(reply.toJsonString().includes("\"error\""), reply.toJsonString());
}
