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

const int RAW_BYTES_TEST_PORT = 19283;

isolated class RawArtifactAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.addArtifact([{raw: "tck".toBytes(), mediaType: "text/plain", filename: "out.txt"}]);
        check updater.complete();
        return;
    }
}

final http:Listener rawBytesRpcHttp = check new (RAW_BYTES_TEST_PORT);
listener JsonRpcListener rawBytesRpcListener = new (rawBytesRpcHttp);

@test:BeforeSuite
function startRawBytesServers() returns error? {
    DefaultHandler handler = new (new RawArtifactAgent());
    check rawBytesRpcListener.attach(new RpcService(handler, rpcTestCard));
}

// "tck" is `dGNr` in base64: a task fetched over JSON-RPC carries it as a
// string, whichever spelling of the field names the client used.
@test:Config {}
function testARawPartIsBase64InAFetchedTaskOverJsonRpc() returns error? {
    json sent = check rpcCall(RAW_BYTES_TEST_PORT, "SendMessage", rpcSendParams("raw-rpc-1"));
    string taskId = check (check sent.result.task.id).ensureType();

    json fetched = check rpcCall(RAW_BYTES_TEST_PORT, "GetTask", {task_id: taskId, id: taskId});
    json[] artifacts = <json[]>check fetched.result.artifacts;
    json[] parts = <json[]>check artifacts[0].parts;
    test:assertEquals(check parts[0].raw, "dGNr");
}

// A caller's extra field is dropped on the way in, so a strict protobuf client
// is never served a message with a field it has no name for.
@test:Config {}
function testAnUnknownFieldInAMessageSentOverJsonRpcIsNotServedBack() returns error? {
    json params = {message: {messageId: "unknown-field-1", role: "ROLE_USER", parts: [{text: "hi", extra: 1}],
        tckUnknownField: "x"}, unknownTop: true};
    json sent = check rpcCall(RAW_BYTES_TEST_PORT, "SendMessage", params);
    string text = sent.toJsonString();
    test:assertFalse(text.includes("tckUnknownField"), text);
    test:assertFalse(text.includes("unknownTop"), text);
    test:assertTrue(text.includes("unknown-field-1"), text);
}
