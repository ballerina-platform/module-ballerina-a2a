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

// Direct unit tests of the live-streaming machinery in task_execution.bal,
// below the level server_roundtrip_test.bal exercises it at. These cover
// the mechanics precisely -- ordering, closing, error completion, fan-out,
// the registry's driver interlock -- that a full round trip through the
// wire would only prove indirectly. Gate itself (testutil.bal) gets no
// standalone test here: its correctness is what the gated multi-subscriber
// round-trip test in server_roundtrip_test.bal actually depends on and
// proves in anger.

import ballerina/test;

isolated function sampleTaskWithId(string id) returns Task => {
    id,
    contextId: "ctx-1",
    status: {state: TASK_STATE_WORKING, timestamp: "2026-01-01T00:00:00Z"}
};

@test:Config {}
function testEventTapDeliversPushedEventsInOrder() returns error? {
    EventTap tap = new;
    tap.push(sampleTaskWithId("t1"));
    tap.push(sampleTaskWithId("t2"));

    StreamResponse first = check expectValue(tap.next());
    test:assertEquals((<Task>first).id, "t1");
    StreamResponse second = check expectValue(tap.next());
    test:assertEquals((<Task>second).id, "t2");
}

@test:Config {}
function testEventTapPrependSnapshotGoesFirst() returns error? {
    EventTap tap = new;
    tap.push(sampleTaskWithId("later"));
    tap.prependSnapshot(sampleTaskWithId("snapshot"));

    StreamResponse first = check expectValue(tap.next());
    test:assertEquals((<Task>first).id, "snapshot");
    StreamResponse second = check expectValue(tap.next());
    test:assertEquals((<Task>second).id, "later");
}

@test:Config {}
function testEventTapCloseEndsAfterDrainingQueuedEvents() returns error? {
    EventTap tap = new;
    tap.push(sampleTaskWithId("queued"));
    tap.signalDone();

    StreamResponse queued = check expectValue(tap.next());
    test:assertEquals((<Task>queued).id, "queued",
            "an already-queued event must still be delivered after signalDone");

    record {| StreamResponse value; |}|Error? ended = tap.next();
    test:assertTrue(ended is (), "next must end cleanly once the queue drains");
}

@test:Config {}
function testEventTapEndWithErrorYieldsErrorThenEnds() returns error? {
    EventTap tap = new;
    tap.push(sampleTaskWithId("before-failure"));
    tap.endWithError(error InternalError("driver crashed"));

    StreamResponse queued = check expectValue(tap.next());
    test:assertEquals((<Task>queued).id, "before-failure",
            "an already-queued event must still be delivered before the error completion");

    record {| StreamResponse value; |}|Error? completion = tap.next();
    test:assertTrue(completion is Error, "the completion error must surface exactly once, after the queue drains");

    record {| StreamResponse value; |}|Error? afterward = tap.next();
    test:assertTrue(afterward is (), "next must end cleanly once the error completion has been consumed");
}

@test:Config {}
function testEventTapIdleTimeoutEndsStreamWithNoEvents() returns error? {
    EventTap tap = new (0.05);
    record {| StreamResponse value; |}|Error? result = tap.next();
    test:assertTrue(result is (), "next must end once idleTimeout elapses with nothing pushed");
}

@test:Config {}
function testEventBroadcasterFansOutToEveryOpenTap() returns error? {
    InMemoryEventBroadcaster broadcaster = new;
    EventTap tapA = broadcaster.newTap();
    EventTap tapB = broadcaster.newTap();

    broadcaster.push(sampleTaskWithId("fan-out"));

    StreamResponse fromA = check expectValue(tapA.next());
    StreamResponse fromB = check expectValue(tapB.next());
    test:assertEquals((<Task>fromA).id, "fan-out");
    test:assertEquals((<Task>fromB).id, "fan-out");
}

@test:Config {}
function testEventBroadcasterCloseEndsEveryTap() returns error? {
    InMemoryEventBroadcaster broadcaster = new;
    EventTap tapA = broadcaster.newTap();
    EventTap tapB = broadcaster.newTap();

    broadcaster.close();

    record {| StreamResponse value; |}|Error? fromA = tapA.next();
    record {| StreamResponse value; |}|Error? fromB = tapB.next();
    test:assertTrue(fromA is (), "closing the broadcaster must end every open tap");
    test:assertTrue(fromB is (), "closing the broadcaster must end every open tap");
}

@test:Config {}
function testEventBroadcasterNewTapAfterCloseComesPreClosed() returns error? {
    InMemoryEventBroadcaster broadcaster = new;
    broadcaster.close();

    // A subscriber attaching just as the task finishes must not spin on
    // next() forever -- see newTap's own doc.
    EventTap tap = broadcaster.newTap();
    record {| StreamResponse value; |}|Error? result = tap.next();
    test:assertTrue(result is (), "a tap attached to an already-closed broadcaster must end immediately");
}

@test:Config {}
function testInMemoryEventBroadcasterRegistryAcquireRejectsSecondConcurrentDriver() returns error? {
    InMemoryEventBroadcasterRegistry registry = new;
    EventBroadcaster? first = registry.acquire("t1");
    test:assertTrue(first is EventBroadcaster, "the first acquire for a task must succeed");

    EventBroadcaster? second = registry.acquire("t1");
    test:assertTrue(second is (), "a second concurrent acquire for the same task must be rejected");
}

@test:Config {}
function testInMemoryEventBroadcasterRegistryReleaseFreesTheDriverSlot() returns error? {
    InMemoryEventBroadcasterRegistry registry = new;
    EventBroadcaster? first = registry.acquire("t1");
    test:assertTrue(first is EventBroadcaster);

    registry.release("t1", false);

    EventBroadcaster? reacquired = registry.acquire("t1");
    test:assertTrue(reacquired is EventBroadcaster,
            "release must free the driver slot so a later message can acquire it again");
}

@test:Config {}
function testInMemoryEventBroadcasterRegistryNonTerminalReleaseKeepsBroadcaster() returns error? {
    InMemoryEventBroadcasterRegistry registry = new;
    EventBroadcaster? acquired = registry.acquire("t1");
    test:assertTrue(acquired is EventBroadcaster);
    EventBroadcaster broadcaster = <EventBroadcaster>acquired;

    registry.release("t1", false);

    // A paused (non-terminal) task keeps its broadcaster, so a subscriber
    // finds the very same one a later message resumes.
    EventBroadcaster subscribed = registry.subscribe("t1");
    EventTap tap = subscribed.newTap();
    broadcaster.push(sampleTaskWithId("resumed"));

    StreamResponse result = check expectValue(tap.next());
    test:assertEquals((<Task>result).id, "resumed",
            "the broadcaster acquired before release must be the same one subscribe finds after it");
}

@test:Config {}
function testInMemoryEventBroadcasterRegistryTerminalReleaseDropsBroadcaster() returns error? {
    InMemoryEventBroadcasterRegistry registry = new;
    EventBroadcaster? acquired = registry.acquire("t1");
    test:assertTrue(acquired is EventBroadcaster);

    registry.release("t1", true);

    EventBroadcaster? peeked = registry.peekBroadcaster("t1");
    test:assertTrue(peeked is (), "a terminal release must drop the broadcaster from the registry");
}

@test:Config {}
function testInMemoryEventBroadcasterRegistryPeekBroadcasterFindsNoneForAnUntouchedTask() returns error? {
    InMemoryEventBroadcasterRegistry registry = new;
    EventBroadcaster? peeked = registry.peekBroadcaster("never-touched");
    test:assertTrue(peeked is (), "a task nobody has driven or subscribed to has no broadcaster yet");
}

@test:Config {}
function testInMemoryEventBroadcasterRegistrySubscribeDoesNotClaimDriverSlot() returns error? {
    InMemoryEventBroadcasterRegistry registry = new;
    EventBroadcaster _ = registry.subscribe("t1");

    // subscribe must never block a driver from claiming the task later --
    // a subscriber may legitimately attach to a paused, not-yet-resumed
    // task.
    EventBroadcaster? acquired = registry.acquire("t1");
    test:assertTrue(acquired is EventBroadcaster, "subscribe must not claim the driver slot");
}

@test:Config {}
function testSseFramingGeneratorCloseForwardsToItsUnderlyingTap() returns error? {
    // A client disconnect surfaces as ballerina/mime's EventStreamWriter
    // calling close() on the outer SSE stream, which only propagates to a
    // wrapped generator that defines close() itself (dispatcher.bal's own
    // SseFramingGenerator, and its own doc comment). Tested directly here,
    // not through an actual HTTP disconnect -- there is no reliable,
    // non-flaky way to force one from a well-behaved http:Client -- against
    // the same EventBroadcaster/EventTap pair a live stream really wraps.
    InMemoryEventBroadcaster broadcaster = new;
    EventTap tap = broadcaster.newTap();
    stream<StreamResponse, Error?> tapStream = new (tap);
    SseFramingGenerator framing = new (tapStream);

    error? result = framing.close();
    test:assertTrue(result is (), "close must not itself fail");
    test:assertTrue(tap.isClosed(), "the wrapped EventTap must be closed too, not left listening");
}
