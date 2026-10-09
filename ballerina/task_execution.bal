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

// The machinery behind live task streaming: a task driven detached from
// the request that started it, a broadcaster fanning its events out to
// however many subscribers attach, and a registry so a later, separate
// request can find the task still being driven.
//
// `EventBroadcaster` and `EventBroadcasterRegistry` are public interfaces, the
// same kind of seam `TaskStore` is: a deployment can replace where events
// travel without touching how the protocol drives a task. The in-process
// defaults, `InMemoryEventBroadcasterRegistry` and the broadcasters it hands
// out, are what every deployment gets unless it supplies its own. `EventTap`,
// the queue one subscriber reads, stays a single concrete class: it is what a
// stream is built from, so any broadcaster hands out the same kind.
//
// A replacement must keep the registry's driver interlock (see
// `EventBroadcasterRegistry.acquire`) and the broadcaster's ordering -- every
// subscriber gets every event in the same order, per [specification section 3.5.2](https://a2a-protocol.org/latest/specification/#352-streaming-event-delivery).
// A deployment that only needs to follow a task across instances can already
// do that with push notifications, without replacing either.
//
// Verified against real, empirically-run scratch packages this session,
// not just read: `start` on an isolated method genuinely detaches an HTTP
// request from the work it starts; a blocking, poll-based next delivers
// values live as a separate detached producer pushes them, not pre-computed;
// multiple taps on one broadcaster each receive the identical sequence.
// Two isolation rules surfaced by that spike, both applied throughout this
// file: a value transferred out of a `lock` block must be `.clone()`d, and
// so must a value passed into a nested isolated object's method call from
// inside a `lock` block, even a plain parameter.

import ballerina/lang.runtime;

# How often a tap's blocking `next` polls for a new event. Short enough
# that live delivery feels immediate, long enough that many idle
# subscribers cost negligible CPU.
const decimal EVENT_POLL_INTERVAL = 0.05;

# What a tap's `next` returns, in place of an event, once `keepAliveInterval`
# has passed with nothing to deliver: "still here, nothing to report".
#
# Not a failure. It travels in the error position of the tap's stream only
# because that is the one channel the stream type leaves free, and is never
# visible outside this package: the tap's only consumer is
# `SseFramingGenerator`, which turns it into an SSE comment frame. A distinct
# subtype so nothing can mistake it for a real `Error`.
type KeepAliveTick distinct Error;

# A single subscriber's queue of a task's events.
#
# `next` blocks (polling, since `ballerina/lang.runtime` has no condition
# variable or semaphore) until an event is pushed, the tap is closed and
# drained, `idleTimeout` elapses with nothing happening -- the backstop for a
# client that disconnects without the HTTP layer surfacing it as a clean
# stream close -- or, when `keepAliveInterval` is set, that long passes with
# nothing to deliver, in which case it returns a `KeepAliveTick`.
#
# The idle time is counted across ticks, not restarted by them: a keep-alive
# is not activity, so a stream that produces nothing but keep-alives still
# reaches `idleTimeout`.
#
# A custom `a2a:EventBroadcaster` hands these out from `newTap`, and feeds
# each one through `push`, `signalDone`, and `endWithError`.
public isolated class EventTap {
    private StreamResponse[] queue = [];
    private boolean closed = false;
    // Set by `endWithError`, consumed by the first `next` call that reaches an
    // empty queue after -- matches `stream<T, E>`'s completion semantics,
    // where the generator's `next` yields the completion error exactly
    // once, after every already-queued value.
    private Error? pendingError = ();
    private final decimal idleTimeout;
    private final decimal keepAliveInterval;
    // Seconds since an event last reached a consumer; survives across `next`
    // calls so a keep-alive tick does not reset it.
    private decimal silentFor = 0d;

    # Creates a tap.
    #
    # + idleTimeout - Seconds of no events before `next` gives up and
    #                 ends the stream; `0` disables the timeout
    # + keepAliveInterval - Seconds of no events before the stream sends a
    #                       keep-alive; `0` disables keep-alives
    public isolated function init(decimal idleTimeout = 0, decimal keepAliveInterval = 0) {
        self.idleTimeout = idleTimeout;
        self.keepAliveInterval = keepAliveInterval;
    }

    # Queues an event for this subscriber.
    #
    # + event - The event to deliver
    public isolated function push(StreamResponse event) {
        lock {
            self.queue.push(event.clone());
        }
    }

    # Queues an event at the *front* of the queue, ahead of anything
    # already pushed -- used to prepend a task's current snapshot after a
    # subscriber has already attached (see `InMemoryEventBroadcasterRegistry.subscribe`'s
    # doc comment for why attach must happen before the snapshot read).
    #
    # + event - The event to prepend
    isolated function prependSnapshot(StreamResponse event) {
        lock {
            self.queue = [event.clone(), ...self.queue];
        }
    }

    # No more events will ever be pushed; `next` drains what remains,
    # then ends. Called by the producer side (an `EventBroadcaster`) -- see
    # `close` for the consumer-side equivalent a stream's own caller uses.
    public isolated function signalDone() {
        lock {
            self.closed = true;
        }
    }

    # Ends the stream with an error completion instead of a clean close --
    # once the queue drains, `next` returns `err` exactly once instead of
    # `()`. Used when a task's driving turn itself failed in a way no
    # `TaskStatusUpdateEvent` already communicates (see
    # `DefaultHandler.finishDrivenTask`).
    #
    # + err - The error to complete the stream with
    public isolated function endWithError(Error err) {
        lock {
            self.pendingError = err;
            self.closed = true;
        }
    }

    # Whether this tap has been closed, by either side -- a broadcaster stops
    # pushing to a closed tap, so a subscriber that went away is not fed forever.
    #
    # + return - `true` once closed
    public isolated function isClosed() returns boolean {
        lock {
            return self.closed;
        }
    }

    # + return - The next event, a `KeepAliveTick` once `keepAliveInterval` has
    #            passed with nothing to deliver, `()` once closed and drained
    #            (or idle past `idleTimeout`), or an error
    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        decimal sinceLastTick = 0;
        while true {
            decimal silent;
            lock {
                if self.queue.length() > 0 {
                    StreamResponse v = self.queue.shift();
                    self.silentFor = 0d;
                    return {value: v.clone()};
                }
                Error? pending = self.pendingError;
                if pending is Error {
                    self.pendingError = ();
                    return pending;
                }
                if self.closed {
                    return;
                }
                silent = self.silentFor;
            }
            if self.idleTimeout > 0d && silent >= self.idleTimeout {
                return;
            }
            if self.keepAliveInterval > 0d && sinceLastTick >= self.keepAliveInterval {
                return error KeepAliveTick("keep-alive");
            }
            runtime:sleep(EVENT_POLL_INTERVAL);
            lock {
                self.silentFor += EVENT_POLL_INTERVAL;
            }
            sinceLastTick += EVENT_POLL_INTERVAL;
        }
    }

    # Consumer-side close: the stream's own caller is done reading (e.g.
    # the HTTP connection dropped) -- required so `EventTap` satisfies
    # `stream<T,E>`'s generator interface. Functionally identical to
    # `signalDone`; kept as a separate, `public` method because that
    # interface requires `close` specifically, and reusing the name would
    # blur which side (producer vs. consumer) is signalling.
    #
    # + return - Always `()`; there is nothing that can fail here
    public isolated function close() returns error? {
        lock {
            self.closed = true;
        }
    }
}

# Fans one task's events out to every subscriber currently following it.
#
# Per [specification section 3.5.2](https://a2a-protocol.org/latest/specification/#352-streaming-event-delivery): every active stream for a task receives
# the same events in the same order, and closing one stream must not
# affect another. An implementation must keep both guarantees.
public type EventBroadcaster isolated object {

    # Delivers an event to every subscriber currently attached.
    #
    # + event - The event to broadcast
    public isolated function push(StreamResponse event);

    # No more events will ever be broadcast; ends every subscriber's stream
    # once it has drained.
    public isolated function close();

    # Ends every subscriber's stream with `err` once it has drained, instead of
    # a clean close.
    #
    # + err - The error to complete every stream with
    public isolated function endWithError(Error err);

    # Attaches a new subscriber.
    #
    # + idleTimeout - Seconds of no events before the subscriber's stream ends;
    #                 `0` disables the timeout
    # + keepAliveInterval - Seconds of no events before the stream sends a
    #                       keep-alive; `0` disables keep-alives
    # + return - A tap receiving every event broadcast from here on; already
    #            closed if the broadcaster has closed
    public isolated function newTap(decimal idleTimeout = 0, decimal keepAliveInterval = 0) returns EventTap;
};

# The in-process `EventBroadcaster`: fans events out to taps in this process.
isolated class InMemoryEventBroadcaster {
    *EventBroadcaster;

    private EventTap[] taps = [];
    private boolean closed = false;

    # Delivers an event to every currently-open tap, dropping any that have
    # since closed (a subscriber disconnecting) so a long task with many
    # transient subscribers doesn't accumulate dead queues.
    #
    # + event - The event to broadcast
    public isolated function push(StreamResponse event) {
        lock {
            EventTap[] stillOpen = [];
            foreach EventTap tap in self.taps {
                if !tap.isClosed() {
                    tap.push(event.clone());
                    stillOpen.push(tap);
                }
            }
            self.taps = stillOpen;
        }
    }

    # No more events will ever be broadcast; closes every open tap.
    public isolated function close() {
        lock {
            foreach EventTap tap in self.taps {
                tap.signalDone();
            }
            self.closed = true;
        }
    }

    # Ends every currently-open tap with an error completion instead of a
    # clean close -- see `EventTap.endWithError`.
    #
    # + err - The error to complete every tap with
    public isolated function endWithError(Error err) {
        lock {
            foreach EventTap tap in self.taps {
                tap.endWithError(err);
            }
            self.closed = true;
        }
    }

    # Attaches a new subscriber.
    #
    # If the broadcaster has already closed -- a subscriber arriving just
    # as the task finishes -- the returned tap comes back pre-closed rather
    # than registered into a dead broadcaster, so its `next` ends cleanly
    # instead of polling forever.
    #
    # + idleTimeout - Forwarded to the new tap
    # + keepAliveInterval - Forwarded to the new tap
    # + return - A tap that will receive every event broadcast from here on
    public isolated function newTap(decimal idleTimeout = 0, decimal keepAliveInterval = 0) returns EventTap {
        final EventTap tap = new (idleTimeout, keepAliveInterval);
        lock {
            if self.closed {
                tap.signalDone();
                return tap;
            }
            self.taps.push(tap);
        }
        return tap;
    }
}

# Keeps one `EventBroadcaster` per task, and tracks which tasks are actively
# being driven, so a later, separate request can find and follow one still in
# progress.
#
# Pass an implementation as `DefaultHandlerConfiguration.eventRegistry` to
# replace the in-process default, `a2a:InMemoryEventBroadcasterRegistry`.
public type EventBroadcasterRegistry isolated object {

    # Claims the exclusive right to drive a task, creating its broadcaster if
    # this is the task's first message. While one claim is held, every further
    # `acquire` for the same task must return `()`: a second concurrent message
    # to an in-flight task is rejected, never run alongside the first.
    #
    # + taskId - The task to drive
    # + return - The broadcaster to push events to, or `()` if another driver
    #            already holds this task
    public isolated function acquire(string taskId) returns EventBroadcaster?;

    # Finds or creates a task's broadcaster without claiming the driver slot,
    # for a subscriber attaching to a task that may or may not have a driver.
    #
    # + taskId - The task to follow
    # + return - The broadcaster to attach a tap to
    public isolated function subscribe(string taskId) returns EventBroadcaster;

    # Releases the claim a prior `acquire` took.
    #
    # + taskId - The task that finished this driving turn
    # + closed - Whether the turn closed the task's broadcaster -- the task
    #            reached a terminal state or `TASK_STATE_INPUT_REQUIRED` -- in
    #            which case the broadcaster may be dropped too, and the next
    #            `acquire` starts a fresh one. A task paused on
    #            `TASK_STATE_AUTH_REQUIRED` keeps its broadcaster, so
    #            subscribers already attached see it resume
    public isolated function release(string taskId, boolean closed);

    # Finds a task's broadcaster if one exists, without creating one or
    # touching the driver slot.
    #
    # + taskId - The task to look up
    # + return - The existing broadcaster, or `()`
    public isolated function peekBroadcaster(string taskId) returns EventBroadcaster?;
};

# The in-process `EventBroadcasterRegistry` every `a2a:DefaultHandler` uses
# unless configured otherwise. Events reach only subscribers in this process.
#
# `acquire` and `subscribe` differ in one thing: `acquire` claims the
# exclusive right to drive a task (a second concurrent message to the same
# in-flight task must be rejected, not run a second `TaskUpdater` racing
# the first); `subscribe` only needs to find or create the broadcaster to
# attach a tap to, and never blocks a driver from claiming the task later
# (a subscriber may legitimately attach to a paused, not-yet-resumed task).
public isolated class InMemoryEventBroadcasterRegistry {
    *EventBroadcasterRegistry;

    private map<EventBroadcaster> broadcasters = {};
    // Which task ids currently have a driver running. A task can have a
    // broadcaster (because a subscriber attached to a paused task) without
    // a driver, and a driver without any subscribers -- the two are
    // tracked separately for exactly that reason.
    private map<boolean> driving = {};

    # Claims the exclusive right to drive a task, creating its broadcaster
    # if this is the task's first message.
    #
    # + taskId - The task to drive
    # + return - The broadcaster to push events to, or `()` if another
    #            driver already holds this task
    public isolated function acquire(string taskId) returns EventBroadcaster? {
        lock {
            if self.driving[taskId] == true {
                return;
            }
            self.driving[taskId] = true;
            EventBroadcaster broadcaster = self.broadcasters[taskId] ?: new InMemoryEventBroadcaster();
            self.broadcasters[taskId] = broadcaster;
            return broadcaster;
        }
    }

    # Finds or creates the broadcaster for a task, without claiming the
    # driver slot -- for `subscribeToTask` attaching to a task that may or
    # may not currently have an active driver.
    #
    # + taskId - The task to follow
    # + return - The broadcaster to attach a tap to
    public isolated function subscribe(string taskId) returns EventBroadcaster {
        lock {
            EventBroadcaster broadcaster = self.broadcasters[taskId] ?: new InMemoryEventBroadcaster();
            self.broadcasters[taskId] = broadcaster;
            return broadcaster;
        }
    }

    # Releases the driver slot a prior `acquire` claimed.
    #
    # + taskId - The task that finished this driving turn
    # + closed - Whether the turn closed the task's broadcaster (a terminal
    #            or input-required task) -- if so, the broadcaster itself is
    #            dropped from the registry too, so the next `acquire` builds
    #            an open one; a task paused on `TASK_STATE_AUTH_REQUIRED`
    #            keeps its broadcaster, so a later message resuming it
    #            reaches whatever subscribers already attached
    public isolated function release(string taskId, boolean closed) {
        lock {
            _ = self.driving.removeIfHasKey(taskId);
            if closed {
                _ = self.broadcasters.removeIfHasKey(taskId);
            }
        }
    }

    # Finds a task's broadcaster if one already exists, without creating
    # one -- for `cancelTask`, which has nothing useful to broadcast to a
    # task nobody has ever driven or subscribed to, and must not claim or
    # touch the driver slot: a driver may genuinely still be running (a
    # live `sendStreamingMessage` subscriber can learn a taskId, and race
    # a `cancelTask` against it, before `onMessage` returns), and
    # `release`-ing that slot early here would let a second, concurrent
    # `acquire` for the same task id succeed while the first driver is
    # still actually running -- exactly the two-`TaskUpdater`s-racing
    # situation the interlock exists to prevent. `InMemoryTaskStore`'s own
    # terminal-state guard is what actually stops a still-running
    # `onMessage`'s further writes once `cancelTask`'s own `store.put`
    # below lands; the driver's own eventual `finishDrivenTask` still
    # releases the slot once it returns, whatever it returns.
    #
    # + taskId - The task to look up
    # + return - The existing broadcaster, or `()` if none has been
    #            created yet
    public isolated function peekBroadcaster(string taskId) returns EventBroadcaster? {
        lock {
            return self.broadcasters[taskId];
        }
    }
}
