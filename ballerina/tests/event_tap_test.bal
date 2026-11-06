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

// An EventTap waits on a blocking queue instead of polling: it parks until an
// event, a close, a keep-alive or the idle timeout arrives, and keeps the
// order and completion rules a stream depends on.

import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

isolated function tapEvent(string id) returns StreamResponse => <Message>{messageId: id, role: ROLE_AGENT, parts: [{text: id}]};

isolated function idOf(record {| StreamResponse value; |}|Error? item) returns string? {
    if item is record {| StreamResponse value; |} {
        StreamResponse event = item.value;
        return event is Message ? event.messageId : ();
    }
    return;
}

isolated function pushLater(EventTap tap, decimal delay, StreamResponse event) {
    runtime:sleep(delay);
    tap.push(event);
}

isolated function closeLater(EventTap tap, decimal delay) returns error? {
    runtime:sleep(delay);
    check tap.close();
}

@test:Config {}
function testTapDeliversInOrderWithASnapshotAtTheFront() {
    EventTap tap = new;
    tap.push(tapEvent("a"));
    tap.push(tapEvent("b"));
    tap.prependSnapshot(tapEvent("snapshot"));
    test:assertEquals(idOf(tap.next()), "snapshot");
    test:assertEquals(idOf(tap.next()), "a");
    test:assertEquals(idOf(tap.next()), "b");
}

@test:Config {}
function testTapDrainsQueuedEventsBeforeItEnds() {
    EventTap tap = new;
    tap.push(tapEvent("a"));
    tap.signalDone();
    test:assertTrue(tap.isClosed());
    test:assertEquals(idOf(tap.next()), "a");
    test:assertTrue(tap.next() is (), "closed and drained");
    test:assertTrue(tap.next() is (), "and it stays ended");
}

@test:Config {}
function testTapReturnsItsCompletionErrorOnceAfterTheQueuedEvents() {
    EventTap tap = new;
    tap.push(tapEvent("a"));
    tap.endWithError(error Error("turn failed"));
    test:assertEquals(idOf(tap.next()), "a");
    record {| StreamResponse value; |}|Error? failure = tap.next();
    test:assertTrue(failure is Error && failure.message() == "turn failed");
    test:assertTrue(tap.next() is (), "the error is delivered exactly once");
}

@test:Config {}
function testTapWaitsForAnEventPushedByAnotherStrand() returns error? {
    EventTap tap = new;
    future<()> producer = start pushLater(tap, 0.3d, tapEvent("late"));
    time:Utc begun = time:utcNow();
    record {| StreamResponse value; |}|Error? item = tap.next();
    decimal waited = time:utcDiffSeconds(time:utcNow(), begun);
    test:assertEquals(idOf(item), "late");
    test:assertTrue(waited >= 0.25d, string `returned after ${waited}s, before the event was pushed`);
    check wait producer;
}

@test:Config {}
function testClosingWakesAWaitingReader() returns error? {
    EventTap tap = new;
    future<error?> closer = start closeLater(tap, 0.2d);
    test:assertTrue(tap.next() is (), "a blocked next ends when the tap is closed");
    check wait closer;
}

@test:Config {}
function testTapSendsKeepAliveTicksInSilence() {
    EventTap tap = new (0, 0.1d);
    time:Utc begun = time:utcNow();
    record {| StreamResponse value; |}|Error? tick = tap.next();
    decimal waited = time:utcDiffSeconds(time:utcNow(), begun);
    test:assertTrue(tick is KeepAliveTick);
    test:assertTrue(waited >= 0.09d && waited < 0.5d, string `tick after ${waited}s`);
}

@test:Config {}
function testKeepAliveTicksDoNotResetTheIdleTimeout() {
    EventTap tap = new (0.35d, 0.1d);
    int ticks = 0;
    while true {
        record {| StreamResponse value; |}|Error? item = tap.next();
        if item is KeepAliveTick {
            ticks += 1;
            continue;
        }
        test:assertTrue(item is (), "the idle timeout ends the stream cleanly");
        break;
    }
    test:assertTrue(ticks >= 2 && ticks <= 4, string `${ticks} ticks before the idle timeout`);
}

@test:Config {}
function testAnEventRestartsTheIdleTimeout() returns error? {
    EventTap tap = new (0.5d, 0.2d);
    future<()> producer = start pushLater(tap, 0.45d, tapEvent("mid"));
    // Two keep-alives (0.2s, 0.4s) have counted against the idle time by the
    // time the event arrives; without a restart it would end 0.1s later.
    string? seen = ();
    while seen is () {
        seen = idOf(tap.next());
    }
    test:assertEquals(seen, "mid");
    int ticksAfter = 0;
    while true {
        record {| StreamResponse value; |}|Error? item = tap.next();
        if item is KeepAliveTick {
            ticksAfter += 1;
            continue;
        }
        test:assertTrue(item is (), "idle again after the event");
        break;
    }
    test:assertTrue(ticksAfter >= 2, string `only ${ticksAfter} keep-alives before the idle end`);
    check wait producer;
}
