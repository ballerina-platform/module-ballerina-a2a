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
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

// A long-running agent can go quiet for longer than an HTTP idle timeout
// (Ballerina's defaults: 60s for a listener, 30s for a client) and lose its
// stream. The server therefore sends an SSE comment frame every
// `keepAliveInterval` seconds while nothing else is happening.
//
// The tests hold an agent behind a Gate so "silent" is exact, and use a short
// interval so they take seconds rather than a minute.

const int KEEPALIVE_TEST_PORT = 19243;
const int NO_KEEPALIVE_TEST_PORT = 19244;
const int BACKSTOP_TEST_PORT = 19245;

isolated function silentAgentCard(string name) returns AgentCard => {
    name,
    description: "Says one thing, then nothing until told to finish",
    version: "1.0.0",
    skills: [{id: "silent", name: "Silent", description: "Holds", tags: ["test"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
};

final DefaultHandler keepAliveHandler = new (silentAgentCard("Keep-alive Agent"));

listener HttpListener keepAliveListener = new (KEEPALIVE_TEST_PORT, keepAliveHandler, keepAliveInterval = 0.4);
final DefaultHandler noKeepAliveHandler = new (silentAgentCard("No keep-alive Agent"));

listener HttpListener noKeepAliveListener = new (NO_KEEPALIVE_TEST_PORT, noKeepAliveHandler, keepAliveInterval = 0);
final DefaultHandler backstopHandler = new (silentAgentCard("Backstop Agent"));

listener HttpListener backstopListener = new (BACKSTOP_TEST_PORT, backstopHandler,
    keepAliveInterval = 0.4,
    streamIdleTimeout = 2
);

@test:BeforeSuite
function startKeepAliveServers() returns error? {
    check keepAliveListener.attach(new SilentAgent());
    check noKeepAliveListener.attach(new SilentAgent());
    check backstopListener.attach(new SilentAgent());
}

// Opens a message:stream on `port` for an agent held on gate `key`, as a raw
// SSE stream, so comment frames are visible (the typed client skips them).
isolated function openHeldStream(int port, string key) returns stream<http:SseEvent, error?>|error {
    http:Client raw = check new (string `http://localhost:${port}`);
    json body = {"message": {"messageId": "ka-" + key, "role": "ROLE_USER", "parts": [{"text": "hold:" + key}]}};
    http:Response resp = check raw->post("/message:stream", body,
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    return resp.getSseEventStream();
}

isolated function isComment(http:SseEvent event) returns boolean => event.data is () && event.comment is string;

isolated function isCompletedEvent(http:SseEvent event) returns boolean {
    string? data = event.data;
    return data is string && data.includes("TASK_STATE_COMPLETED");
}

@test:Config {}
function testKeepAliveFramesArriveDuringSilenceAndTheStreamStillCompletes() returns error? {
    Gate gate = new;
    registerGate("ka-1", gate);
    stream<http:SseEvent, error?> events = check openHeldStream(KEEPALIVE_TEST_PORT, "ka-1");

    int comments = 0;
    boolean completed = false;
    boolean released = false;
    while true {
        record {|http:SseEvent value;|}|error? next = events.next();
        if next is () || next is error {
            break;
        }
        if isComment(next.value) {
            comments += 1;
            if comments >= 3 && !released {
                released = true;
                gate.advanceTo(1);
            }
        }
        if isCompletedEvent(next.value) {
            completed = true;
        }
    }
    test:assertTrue(comments >= 3, string `expected keep-alive frames while the agent was silent, saw ${comments}`);
    test:assertTrue(completed, "the real events must still arrive after the silence");
}

@test:Config {}
function testNoKeepAliveFramesWhenTheIntervalIsZero() returns error? {
    Gate gate = new;
    registerGate("ka-0", gate);
    stream<http:SseEvent, error?> events = check openHeldStream(NO_KEEPALIVE_TEST_PORT, "ka-0");

    // The seed task and the WORKING update; then the agent goes quiet.
    foreach int _ in 0 ..< 2 {
        record {|http:SseEvent value;|}|error? first = events.next();
        test:assertTrue(first is record {|http:SseEvent value;|}, "the first two events must arrive");
    }
    runtime:sleep(1.5);
    gate.advanceTo(1);

    int comments = 0;
    while true {
        record {|http:SseEvent value;|}|error? next = events.next();
        if next is () || next is error {
            break;
        }
        if isComment(next.value) {
            comments += 1;
        }
    }
    test:assertEquals(comments, 0, "a zero interval must send no keep-alive frames");
}

// A keep-alive is not activity: a stream nothing is being produced on must
// still be ended by streamIdleTimeout, or a stream to a client that has gone
// away would be kept alive forever by its own keep-alives.
@test:Config {}
function testKeepAlivesDoNotDefeatTheIdleBackstop() returns error? {
    Gate gate = new;
    registerGate("ka-backstop", gate);
    stream<http:SseEvent, error?> events = check openHeldStream(BACKSTOP_TEST_PORT, "ka-backstop");

    time:Utc started = time:utcNow();
    int comments = 0;
    boolean completed = false;
    while true {
        record {|http:SseEvent value;|}|error? next = events.next();
        if next is () || next is error {
            break;
        }
        if isComment(next.value) {
            comments += 1;
        }
        if isCompletedEvent(next.value) {
            completed = true;
        }
    }
    decimal seconds = time:utcDiffSeconds(time:utcNow(), started);
    gate.advanceTo(1);

    test:assertTrue(comments >= 1, "keep-alives should have been flowing until the backstop fired");
    test:assertFalse(completed, "the agent was held, so the stream can only have been ended by the backstop");
    test:assertTrue(seconds >= 1.5d && seconds < 8d,
            string `streamIdleTimeout = 2 must end the stream at about 2s; it lasted ${seconds}s`);
}

// The typed client must read straight through the comment frames.
@test:Config {}
function testTheTypedClientReadsThroughKeepAliveFrames() returns error? {
    Gate gate = new;
    registerGate("ka-client", gate);
    HttpClient c = check new (string `http://localhost:${KEEPALIVE_TEST_PORT}`);
    stream<StreamResponse, Error?> events = check c->sendStreamingMessage({
        message: {messageId: "ka-client-1", role: ROLE_USER, parts: [{text: "hold:ka-client"}]}
    });

    // Let several keep-alive intervals pass in silence, then finish the task.
    future<()> releaser = start releaseAfter(gate, 1.5d);
    string[] states = [];
    while true {
        record {|StreamResponse value;|}|Error? next = events.next();
        if next is () {
            break;
        }
        if next is Error {
            test:assertFail(string `the stream must not fail on keep-alives: ${next.message()}`);
        }
        StreamResponse event = next.value;
        if event is TaskStatusUpdateEvent {
            states.push(event.status.state.toString());
        }
    }
    check wait releaser;
    test:assertEquals(states[states.length() - 1], "TASK_STATE_COMPLETED", "the task must still complete");
}

isolated function releaseAfter(Gate gate, decimal seconds) {
    runtime:sleep(seconds);
    gate.advanceTo(1);
}
