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
import ballerina/time;

// Specification 11.7: a stream stays open "until the task reaches a terminal or
// interrupted state, at which point the stream closes". INPUT_REQUIRED ends the
// stream; AUTH_REQUIRED is the exception section 7.6.1 carves out (the agent
// SHOULD keep it open while the client authorizes out of band).
//
// No keep-alives and a short idle timeout, so a stream left open shows up as a
// multi-second wait rather than a test that runs for the 300-second default.

const int INTERRUPTED_STREAM_PORT = 19272;
const decimal INTERRUPTED_STREAM_IDLE_TIMEOUT = 4;

final DefaultHandler interruptedStreamHandler = new ({
    name: "Interrupting Agent",
    description: "Pauses for input or for authorization",
    version: "1.0.0",
    skills: [{id: "pause", name: "Pause", description: "Pauses", tags: ["test"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

listener HttpListener interruptedStreamListener = new (INTERRUPTED_STREAM_PORT, interruptedStreamHandler,
    keepAliveInterval = 0,
    streamIdleTimeout = INTERRUPTED_STREAM_IDLE_TIMEOUT
);

// "ask" pauses on INPUT_REQUIRED, "authorize" on AUTH_REQUIRED, anything else
// completes.
isolated service class InterruptingAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater) returns Message|Error? {
        string? text = context.message.parts[0]?.text;
        check updater->working();
        if text == "ask" {
            check updater->requireInput({messageId: "ask-1", role: ROLE_AGENT, parts: [{text: "which one?"}]});
            return;
        }
        if text == "authorize" {
            check updater->requireAuth({messageId: "auth-1", role: ROLE_AGENT, parts: [{text: "sign in first"}]});
            return;
        }
        check updater->complete();
        return;
    }
}

@test:BeforeSuite
function startInterruptingAgent() returns error? {
    check interruptedStreamListener.attach(new InterruptingAgent());
}

// Streams one message and reads the SSE stream until the server ends it.
//
// + body - The SendMessageRequest body
// + return - Every `data` payload received, and how many seconds the stream stayed open
isolated function streamToEnd(json body) returns [string[], decimal]|error {
    http:Client raw = check new (string `http://localhost:${INTERRUPTED_STREAM_PORT}`,
        timeout = INTERRUPTED_STREAM_IDLE_TIMEOUT * 3
    );
    time:Seconds started = time:monotonicNow();
    http:Response response = check raw->post("/message:stream", body,
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    stream<http:SseEvent, error?> events = check response.getSseEventStream();
    string[] payloads = [];
    while true {
        record {|http:SseEvent value;|}|error? next = events.next();
        if next is () || next is error {
            break;
        }
        string? data = next.value.data;
        if data is string {
            payloads.push(data);
        }
    }
    return [payloads, time:monotonicNow() - started];
}

@test:Config {}
function testStreamClosesAtInputRequired() returns error? {
    [string[], decimal] [payloads, openFor] = check streamToEnd({
        "message": {"messageId": "ir-1", "role": "ROLE_USER", "parts": [{"text": "ask"}]}
    });
    test:assertTrue(payloads.length() > 0 && payloads[payloads.length() - 1].includes("TASK_STATE_INPUT_REQUIRED"),
            string `the stream must end on the INPUT_REQUIRED update, got ${payloads.toString()}`);
    test:assertTrue(openFor < INTERRUPTED_STREAM_IDLE_TIMEOUT / 2,
            string `the stream must close at INPUT_REQUIRED, not wait for the idle timeout (open ${openFor}s)`);
}

@test:Config {}
function testContinuationAfterInputRequiredStreamsAgain() returns error? {
    [string[], decimal] [first, _] = check streamToEnd({
        "message": {"messageId": "ir-2", "role": "ROLE_USER", "parts": [{"text": "ask"}]}
    });
    json paused = check first[first.length() - 1].fromJsonString();
    string taskId = check paused.statusUpdate.taskId;
    string contextId = check paused.statusUpdate.contextId;

    // The first turn's broadcaster was closed and dropped; the continuation
    // must get a fresh, open one rather than a stream that ends immediately.
    [string[], decimal] [second, openFor] = check streamToEnd({
        "message": {
            "messageId": "ir-3",
            "role": "ROLE_USER",
            "taskId": taskId,
            "contextId": contextId,
            "parts": [{"text": "the second one"}]
        }
    });
    test:assertTrue(second.length() > 0 && second[second.length() - 1].includes("TASK_STATE_COMPLETED"),
            string `the continuation must stream through to COMPLETED, got ${second.toString()}`);
    test:assertTrue(openFor < INTERRUPTED_STREAM_IDLE_TIMEOUT / 2);
}

@test:Config {}
function testStreamStaysOpenAtAuthRequired() returns error? {
    [string[], decimal] [payloads, openFor] = check streamToEnd({
        "message": {"messageId": "ar-1", "role": "ROLE_USER", "parts": [{"text": "authorize"}]}
    });
    test:assertTrue(payloads.length() > 0 && payloads[payloads.length() - 1].includes("TASK_STATE_AUTH_REQUIRED"),
            string `the AUTH_REQUIRED update must arrive, got ${payloads.toString()}`);
    test:assertTrue(openFor >= INTERRUPTED_STREAM_IDLE_TIMEOUT - 1d,
            string `an AUTH_REQUIRED stream must stay open until the idle timeout (closed after ${openFor}s)`);
}
