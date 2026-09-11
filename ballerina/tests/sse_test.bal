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

// A short-lived listener + service, used only by
// testReadSseStreamOverRealHttpResponse to exercise readSseStream against
// a real http:Response rather than a synthetic stream.
listener http:Listener sseTestListener = check new (19099);

service /events on sseTestListener {
    resource function get .() returns stream<http:SseEvent, error?> {
        http:SseEvent[] events = [
            {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}`},
            {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}`}
        ];
        return events.toStream();
    }
}

// Exercises readSseStream(http:Response) end to end over a real HTTP
// connection — a short-lived listener serves a canned SSE response, a real
// http:Client fetches it, and the resulting http:Response (including its
// actual resp.getSseEventStream() call) is fed to readSseStream. Only
// A2aStreamGenerator was covered by the synthetic-stream tests below;
// readSseStream's own wiring had zero coverage before this test.
//
@test:Config {}
function testReadSseStreamOverRealHttpResponse() returns error? {
    http:Client testClient = check new ("http://localhost:19099");
    http:Response resp = check testClient->get("/events");

    stream<StreamResponse, Error?> result = check readSseStream(resp);

    StreamResponse first = check expectValue(result.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(result.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? third = result.next();
    test:assertTrue(third is (), "stream should be closed after the terminal status delivered over real HTTP");
}

// A synthetic SSE source for tests — no real HTTP involved. Feeds a
// pre-built array of http:SseEvent|error values to an A2aStreamGenerator.
class TestSseSource {
    private (http:SseEvent|error)[] events;
    private int idx = 0;

    isolated function init((http:SseEvent|error)[] events) {
        self.events = events;
    }

    public isolated function next() returns record {| http:SseEvent value; |}|error? {
        if self.idx >= self.events.length() {
            return ();
        }
        http:SseEvent|error event = self.events[self.idx];
        self.idx += 1;
        if event is error {
            return event;
        }
        return {value: event};
    }
}

isolated function newGenerator((http:SseEvent|error)[] events) returns A2aStreamGenerator {
    stream<http:SseEvent, error?> sseStream = new (new TestSseSource(events));
    return new A2aStreamGenerator(sseStream);
}

@test:Config {}
function testA2aStreamGeneratorClosesOnTerminalStatus() returns error? {
    A2aStreamGenerator generator = newGenerator([
        {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}`},
        {data: string `{"artifactUpdate":{"taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"text":"partial"}]}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}`}
    ]);

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(generator.next());
    test:assertTrue(second is TaskArtifactUpdateEvent, "artifact event should be delivered");

    StreamResponse third = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>third).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|Error? fourth = generator.next();
    test:assertTrue(fourth is (), "stream should be closed after the terminal event, regardless of remaining source events");
}

// isTerminalEvent is a four-way OR, but only TASK_STATE_COMPLETED was ever
// exercised as a stream terminator — dropping any of the other three arms
// left the suite green. Each terminal state is checked here against a
// generator whose next event must never be delivered, and each interrupted
// state against one whose next event must be.
//
@test:Config {}
function testA2aStreamGeneratorClosesOnEveryTerminalStateAndOnlyThose() returns error? {
    string[] terminal = [
        "TASK_STATE_COMPLETED", "TASK_STATE_FAILED",
        "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"
    ];
    foreach string state in terminal {
        A2aStreamGenerator generator = newGenerator([
            {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"${state}"}}}`},
            {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}`}
        ]);
        StreamResponse first = check expectValue(generator.next());
        test:assertEquals((<TaskStatusUpdateEvent>first).status.state, <TaskState>state);

        record {| StreamResponse value; |}|error? second = generator.next();
        test:assertTrue(second is (),
                string `${state} is a terminal state and must close the stream, leaving the following event undelivered`);
    }

    // The states a task can rest in mid-conversation must NOT close it —
    // otherwise a stream that pauses for input can never be resumed.
    string[] nonTerminal = [
        "TASK_STATE_SUBMITTED", "TASK_STATE_WORKING",
        "TASK_STATE_INPUT_REQUIRED", "TASK_STATE_AUTH_REQUIRED"
    ];
    foreach string state in nonTerminal {
        A2aStreamGenerator generator = newGenerator([
            {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"${state}"}}}`},
            {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}`}
        ]);
        _ = check expectValue(generator.next());
        StreamResponse second = check expectValue(generator.next());
        test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_COMPLETED,
                string `${state} is not terminal and must leave the stream open`);
    }
}

@test:Config {}
function testA2aStreamGeneratorDoesNotCloseOnInputRequired() returns error? {
    A2aStreamGenerator generator = newGenerator([
        {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_INPUT_REQUIRED"}}}`},
        {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}`}
    ]);

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_INPUT_REQUIRED);

    // If INPUT_REQUIRED had closed the stream, this would fail instead of returning the next event.
    StreamResponse second = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);
}

// ---- reconnection policy, tested without a server ---------------------

// A StreamResponse source, the StreamResponse-level analogue of
// TestSseSource — needed to hand wrapReconnecting/ReconnectingStreamGenerator
// a stream whose behaviour a test controls exactly.
class TestStreamResponseSource {
    private (StreamResponse|Error)[] events;
    private int idx = 0;

    isolated function init((StreamResponse|Error)[] events) {
        self.events = events;
    }

    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        if self.idx >= self.events.length() {
            return ();
        }
        StreamResponse|Error event = self.events[self.idx];
        self.idx += 1;
        if event is Error {
            return event;
        }
        return {value: event};
    }
}

isolated function responseStream((StreamResponse|Error)[] events) returns stream<StreamResponse, Error?> {
    return new (new TestStreamResponseSource(events));
}

// A stand-in for the owning client, counting resubscribe calls.
//
// Hands back a stream that immediately errors — the case that actually
// drives reconnection — but refuses to do so more than `allowed` times.
// That cap is what makes the attempt-budget assertion terminate: without
// it, a client that never consumes its budget resubscribes forever and the
// test hangs instead of failing, which is exactly what happened when the
// budget accounting was mutated.
isolated class CountingReconnectable {
    private final int allowed;
    private int calls = 0;
    private boolean exceeded = false;

    isolated function init(int allowed) {
        self.allowed = allowed;
    }

    isolated function openTaskSubscriptionStream(string taskId, string? tenant)
            returns stream<StreamResponse, Error?>|Error {
        lock {
            self.calls += 1;
            if self.calls > self.allowed {
                self.exceeded = true;
                return error InternalError("resubscribe cap reached");
            }
        }
        return responseStream([error("dropped again")]);
    }

    isolated function callCount() returns int {
        lock {
            return self.calls;
        }
    }

    isolated function capExceeded() returns boolean {
        lock {
            return self.exceeded;
        }
    }
}

// The reconnect budget must be consumed once per attempt and shared across
// the whole chain. The suite previously asserted this only through the mock
// server, where a budget that never decremented produced an infinite
// resubscribe loop — the suite hung rather than failing. Here the stub caps
// resubscribes one above the budget, so the same bug fails an assertion in
// bounded time.
//
@test:Config {}
function testReconnectBudgetIsConsumedOncePerAttemptAndSharedAcrossTheChain() returns error? {
    CountingReconnectable owner = new (3);
    stream<StreamResponse, Error?> initial = responseStream([error InternalError("first drop")]);
    stream<StreamResponse, Error?> s =
        new (new ReconnectingStreamGenerator(initial, owner, "task-1", 2));

    record {| StreamResponse value; |}|error? result = s.next();

    test:assertTrue(result is error, "with every reconnect failing, the error must surface once the budget is spent");
    test:assertFalse(owner.capExceeded(),
            "reconnection must stop at the configured budget; exceeding the stub's cap means the attempt count is not being consumed and a real client would resubscribe without bound");
    test:assertEquals(owner.callCount(), 2,
            "a budget of 2 must produce exactly 2 resubscribe attempts — not fewer, and not a fresh budget per reconnect");

    record {| StreamResponse value; |}|error? after = s.next();
    test:assertTrue(after is (), "the generator must be done after surfacing the drop error");
}

// A zero budget must hand the stream straight back rather than wrapping it.
// Observable because wrapping peeks the first event: on a stream that opens
// with an error, a peeking implementation surfaces that error from
// wrapReconnecting itself instead of from the caller's first next().
//
@test:Config {}
function testWrapReconnectingHandsBackRawStreamWhenBudgetIsZero() returns error? {
    CountingReconnectable owner = new (0);
    stream<StreamResponse, Error?> raw = responseStream([error InternalError("opens with an error")]);

    stream<StreamResponse, Error?>|Error wrapped = wrapReconnecting(raw, owner, 0, ());

    test:assertTrue(wrapped is stream<StreamResponse, Error?>,
            "a zero budget must return the raw stream untouched — peeking it would surface the first event's error at call time instead of at next(), changing when a default-configured caller sees a failure");
    if wrapped is stream<StreamResponse, Error?> {
        record {| StreamResponse value; |}|error? first = wrapped.next();
        test:assertTrue(first is error, "the error must still arrive, just at next() rather than at construction");
    }
    test:assertEquals(owner.callCount(), 0, "a zero budget must never resubscribe");
}

@test:Config {}
function testA2aStreamGeneratorSkipsCommentFrames() returns error? {
    A2aStreamGenerator generator = newGenerator([
        {comment: "keep-alive"},
        {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}`}
    ]);

    StreamResponse result = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>result).status.state, TASK_STATE_WORKING);
}

@test:Config {}
function testA2aStreamGeneratorPropagatesUnderlyingStreamErrorBeforeTerminal() returns error? {
    A2aStreamGenerator generator = newGenerator([
        {data: string `{"statusUpdate":{"taskId":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_WORKING"}}}`},
        {data: string `{"artifactUpdate":{"taskId":"task-1","contextId":"ctx-1","artifact":{"artifactId":"art-1","parts":[{"text":"partial"}]}}}`},
        error InternalError("connection reset by peer")
    ]);

    StreamResponse first = check expectValue(generator.next());
    test:assertEquals((<TaskStatusUpdateEvent>first).status.state, TASK_STATE_WORKING);

    StreamResponse second = check expectValue(generator.next());
    test:assertTrue(second is TaskArtifactUpdateEvent, "artifact event should be delivered");

    record {| StreamResponse value; |}|Error? third = generator.next();
    test:assertTrue(third is Error,
            "an underlying stream error before a terminal status should propagate to the caller as a typed Error, not be swallowed and not escape untyped");
    if third is Error {
        test:assertTrue(third.message().includes("connection reset by peer"),
                string `the original failure must survive the wrap; got "${third.message()}"`);
    }

    // The generator should have closed itself after surfacing the error.
    record {| StreamResponse value; |}|Error? fourth = generator.next();
    test:assertTrue(fourth is (), "generator should be closed after propagating an underlying stream error");
}

@test:Config {}
function testA2aStreamGeneratorPropagatesMalformedJsonAsError() returns error? {
    A2aStreamGenerator generator = newGenerator([
        {data: "{not valid json"}
    ]);

    record {| StreamResponse value; |}|error? result = generator.next();
    test:assertTrue(result is error, "malformed event data should surface as an error, not a panic");

    // The generator should close after surfacing the error.
    record {| StreamResponse value; |}|error? next = generator.next();
    test:assertTrue(next is (), "generator should be closed after a decode error");
}

// Regression: a malformed base64 Part.raw arriving over SSE must surface as a
// typed InvalidAgentResponseError. It used to escape as a bare error from
// array:fromBase64, because only the REST callers converted that failure.
@test:Config {}
function testSseMalformedBase64PartRawIsTyped() returns error? {
    A2aStreamGenerator generator = newGenerator([
        {data: string `{"task":{"id":"t1","contextId":"c1","status":{"state":"TASK_STATE_WORKING"},` +
               string `"artifacts":[{"artifactId":"a1","parts":[{"raw":"!!!not base64!!!"}]}]}}`}
    ]);

    record {| StreamResponse value; |}|Error? first = generator.next();
    test:assertTrue(first is InvalidAgentResponseError,
            "a malformed base64 Part.raw is the agent's fault and must be typed, not escape as a bare error");
}

// Regression: an SSE payload that is not valid JSON must also be typed.
@test:Config {}
function testSseMalformedJsonIsTyped() returns error? {
    A2aStreamGenerator generator = newGenerator([{data: "{ this is not json"}]);

    record {| StreamResponse value; |}|Error? first = generator.next();
    test:assertTrue(first is InvalidAgentResponseError,
            "a malformed SSE payload must surface as InvalidAgentResponseError");
}

// A reconnectable that refuses the first `failFirst` reopen attempts, then
// succeeds -- the shape that distinguishes "spent the budget" from "gave up
// after the first failed reopen".
isolated class FlakyReconnectable {
    private final int failFirst;
    private int calls = 0;

    isolated function init(int failFirst) {
        self.failFirst = failFirst;
    }

    isolated function openTaskSubscriptionStream(string taskId, string? tenant)
            returns stream<StreamResponse, Error?>|Error {
        lock {
            self.calls += 1;
            if self.calls <= self.failFirst {
                return error InternalError("agent unreachable");
            }
        }
        return responseStream([
            <StreamResponse>{taskId: "task-1", contextId: "ctx-1", status: {state: TASK_STATE_COMPLETED}}
        ]);
    }

    isolated function callCount() returns int {
        lock {
            return self.calls;
        }
    }
}

// Regression: a reopen that itself fails is an attempt, not the end of them.
// With maxAttempts = 2 and a first reopen that errors, the generator used to
// return the original drop error after a single reopen call, so the second
// attempt the caller asked for never happened.
@test:Config {}
function testReconnectSpendsTheWholeBudgetAcrossFailedReopens() returns error? {
    FlakyReconnectable owner = new (1);
    stream<StreamResponse, Error?> initial = responseStream([error InternalError("dropped")]);
    stream<StreamResponse, Error?> s =
        new (new ReconnectingStreamGenerator(initial, owner, "task-1", 2));

    StreamResponse recovered = check expectValue(s.next());
    test:assertTrue(recovered is TaskStatusUpdateEvent,
            "the second reopen should have succeeded and delivered its event");
    test:assertEquals(owner.callCount(), 2,
            "maxAttempts = 2 means two reopen attempts, even when the first one fails");
}
