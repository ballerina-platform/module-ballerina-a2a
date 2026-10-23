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

import ballerina/test;

isolated service class ProbeService {
    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return error InternalError("sent by " + (context?.tenant ?: "none"));
    }

    isolated resource function get tasks/[string id](GetTaskRequest request) returns Task|Error {
        return error InternalError("get " + id + " " + request.id);
    }

    isolated resource function post tasks/[string id]/cancel(CancelTaskRequest request) returns Task|Error {
        return error InternalError("cancel " + id);
    }
}

@test:Config {}
function describesAServicesResources() {
    string[] entries = describeResources(new ProbeService());
    test:assertTrue(entries.indexOf("post message:send +context") is int, entries.toString());
    test:assertTrue(entries.indexOf("get tasks/*") is int, entries.toString());
    test:assertTrue(entries.indexOf("post tasks/*/cancel") is int, entries.toString());
}

@test:Config {}
function invokesAResourceWithPathParametersAndContext() {
    ProbeService probe = new;
    anydata|stream<StreamResponse, Error?>|error cancelled =
        invokeResource(probe, "post", "tasks/*/cancel", ["t-9"], {headers: {}, tenant: "acme"}, <CancelTaskRequest>{id: "t-9"});
    test:assertTrue(cancelled is error, "expected the resource's error");
    test:assertEquals((<error>cancelled).message(), "cancel t-9");

    anydata|stream<StreamResponse, Error?>|error sent =
        invokeResource(probe, "post", "message:send", [], {headers: {}, tenant: "acme"}, <SendMessageRequest>{message: {messageId: "m", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(sent is error, "expected the resource's error");
    test:assertEquals((<error>sent).message(), "sent by acme");
}
