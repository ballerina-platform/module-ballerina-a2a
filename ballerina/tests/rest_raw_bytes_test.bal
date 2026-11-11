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

const int REST_RAW_BYTES_TEST_PORT = 19284;

isolated class RestRawArtifactAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.addArtifact([{raw: "tck".toBytes(), mediaType: "text/plain", filename: "out.txt"}]);
        check updater.complete();
        return;
    }
}

final AgentCard & readonly restRawBytesCard = {
    name: "Raw Bytes Agent",
    description: "Returns a raw artifact",
    version: "1.0.0",
    skills: [{id: "raw", name: "Raw", description: "Returns bytes", tags: ["raw"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

listener RestListener restRawBytesListener = new (REST_RAW_BYTES_TEST_PORT);

@test:BeforeSuite
function startRestRawBytesServer() returns error? {
    check restRawBytesListener.attach(new FullService(new DefaultHandler(new RestRawArtifactAgent()), restRawBytesCard));
}

// "tck" is `dGNr` in base64. A task fetched later must carry the same string a
// task returned by the send did, not an array of byte values.
@test:Config {}
function testARawPartIsBase64InAFetchedTaskOverRest() returns error? {
    http:Client rest = check new (string `http://localhost:${REST_RAW_BYTES_TEST_PORT}/rest`,
            httpVersion = http:HTTP_1_1);
    json message = {message: {messageId: "raw-rest-1", role: "ROLE_USER", parts: [{text: "give me bytes"}]}};
    json sent = check rest->post("/message:send", message, {"A2A-Version": "1.0"});
    string taskId = check (check sent.task.id).ensureType();

    json fetched = check rest->get(string `/tasks/${taskId}`, {"A2A-Version": "1.0"});
    json[] artifacts = <json[]>check fetched.artifacts;
    json[] parts = <json[]>check artifacts[0].parts;
    test:assertEquals(check parts[0].raw, "dGNr");

    json listed = check rest->get("/tasks?includeArtifacts=true", {"A2A-Version": "1.0"});
    test:assertTrue(listed.toJsonString().includes("\"raw\":\"dGNr\""), listed.toJsonString());
}

// A caller's extra field is dropped on the way in, so a strict protobuf client
// is never served a message with a field it has no name for.
@test:Config {}
function testAnUnknownFieldInASentMessageIsNotServedBack() returns error? {
    http:Client rest = check new (string `http://localhost:${REST_RAW_BYTES_TEST_PORT}/rest`,
            httpVersion = http:HTTP_1_1);
    json message = {message: {messageId: "unknown-field-1", role: "ROLE_USER",
        parts: [{text: "hi", extra: 1}], tckUnknownField: "x"}, unknownTop: true};
    json sent = check rest->post("/message:send", message, {"A2A-Version": "1.0"});
    string text = sent.toJsonString();
    test:assertFalse(text.includes("tckUnknownField"), text);
    test:assertFalse(text.includes("unknownTop"), text);
    test:assertTrue(text.includes("unknown-field-1"), text);
}

// A client that serialises protobuf defaults sends an unset id as "".
@test:Config {}
function testAnEmptyTaskIdAndContextIdMeanUnset() returns error? {
    http:Client rest = check new (string `http://localhost:${REST_RAW_BYTES_TEST_PORT}/rest`,
            httpVersion = http:HTTP_1_1);
    json message = {message: {messageId: "empty-ids-1", taskId: "", contextId: "", role: "ROLE_USER",
        parts: [{text: "hi"}]}};
    json sent = check rest->post("/message:send", message, {"A2A-Version": "1.0"});
    test:assertTrue(sent.toJsonString().includes("empty-ids-1"), sent.toJsonString());
}
