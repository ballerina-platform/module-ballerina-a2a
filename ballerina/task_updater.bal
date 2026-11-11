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

import ballerina/time;
import ballerina/uuid;

# What a `TaskUpdater` reports each stored update of its task to: the
# `DefaultHandler`, which delivers it to the task's webhooks.
type TaskUpdateListener isolated object {
    # Queues an update the store has taken, in the order updates are stored.
    #
    # + taskId - The task that changed
    # + task - The task as stored
    # + return - `true` if `deliverUpdates` must be called once outside the lock
    isolated function queueUpdate(string taskId, Task task) returns boolean;

    # Starts delivering the task's queued updates.
    #
    # + taskId - The task whose updates to deliver
    isolated function deliverUpdates(string taskId);
};

# Drives one task through its lifecycle from inside `a2a:AgentExecutor.execute`.
#
# The library hands the developer a `TaskUpdater` already bound to a freshly
# created task, or to the existing task a message continues. Each method advances the task's state and persists it through
# the store, so a client polling `getTask` sees the progression. `addArtifact`
# accumulates output; the terminal calls — `complete`, `failed`, `reject` —
# and the interrupted calls — `requireInput`, `requireAuth` — set the final or
# paused state.
#
# The task id and context id are read-only, so the developer can echo them
# back to the client without reaching into the store.
public isolated class TaskUpdater {
    private final string taskId;
    private final string contextId;
    private final TaskStore store;
    private final string? owner;
    private final EventBroadcaster broadcaster;
    private Artifact[] artifacts = [];
    // The task's last-written state -- empty artifacts/history for a new
    // task, or a continuation's already-accumulated state. Updated after
    // every successful write, so the next one carries the same
    // history/metadata forward instead of silently dropping them, and so
    // the final value is available without a separate store read.
    private Task base;
    // Whether execute has driven the task through this updater at least
    // once. `false` when execute returns a direct Message without
    // touching the updater -- exactly what distinguishes "one Message
    // event, nothing else" from "the agent never drove this task at all."
    private boolean touchedFlag = false;
    // Whether the task's current (pre-transition) state has been broadcast
    // yet. Emitted lazily, on the agent's first real touch of the updater
    // -- not eagerly at construction -- so a direct-Message reply's stream
    // is exactly the one Message event [specification section 3.1.2](https://a2a-protocol.org/latest/specification/#312-send-streaming-message)
    // requires, never a spurious Task first.
    private boolean seedEmitted = false;
    // Set once a client's cancellation is written through `cancel`; every
    // later update from the agent is refused.
    private boolean canceled = false;
    // The requesting call's `configuration.historyLength` (sendMessage/
    // sendStreamingMessage), applied only to the lazily-broadcast seed
    // event below -- never to `self.base`, which must keep the task's full
    // history so later writes and `currentTask()` carry it forward intact.
    // A plain `int?`, so reading it needs no `lock`: unlike a mutable
    // reference type, a value type read from a `final` field is always
    // isolated-safe.
    private final int? historyLength;
    // Told of every update the store takes, or `()`.
    private final TaskUpdateListener? updateListener;

    # Binds an updater to a task. Called by the library, not by agent code.
    #
    # + taskId - The task's server-generated id
    # + contextId - The task's context id
    # + store - The store the task lives in
    # + owner - The resolved owner scope every write is stamped and checked
    #           against, or `()`
    # + base - The task's current state -- empty artifacts/history for a new
    #          task, or a continuation's already-accumulated state
    # + broadcaster - Where every transition and artifact is pushed live, for
    #                 `sendStreamingMessage`/`subscribeToTask` subscribers
    # + historyLength - The triggering request's `configuration.historyLength`,
    #                    applied to the one Task snapshot this updater ever
    #                    broadcasts live (specification 3.2.2/3.2.4). `()`
    #                    imposes no limit.
    # + updateListener - Told of every update the store takes, in order, so
    #                    the task's webhooks are notified of each one
    isolated function init(string taskId, string contextId, TaskStore store, string? owner, Task base,
            EventBroadcaster broadcaster, int? historyLength = (), TaskUpdateListener? updateListener = ()) {
        self.taskId = taskId;
        self.contextId = contextId;
        self.store = store;
        self.owner = owner;
        self.base = base.clone();
        // A continuation's already-accumulated artifacts compose with
        // whatever this invocation adds, rather than being silently
        // replaced by them.
        self.artifacts = base?.artifacts is Artifact[] ? (<Artifact[]>base?.artifacts).clone() : [];
        self.broadcaster = broadcaster;
        self.historyLength = historyLength;
        self.updateListener = updateListener;
    }

    # The task's server-generated id.
    #
    # + return - The id
    public isolated function getTaskId() returns string => self.taskId;

    # The task's context id.
    #
    # + return - The context id
    public isolated function getContextId() returns string => self.contextId;

    # Moves the task to `TASK_STATE_WORKING`.
    #
    # + message - An optional status message to attach
    # + return - An `a2a:Error` if the update could not be stored
    public isolated function working(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_WORKING, message);
    }

    # Appends an artifact to the task's output.
    #
    # The task is stored with the artifact before the artifact is announced,
    # so `getTask` shows it as soon as a subscriber does.
    #
    # + parts - The parts of the artifact; at least one is required
    # + name - An optional human-readable label
    # + return - An `a2a:Error` if `parts` is empty or the store refused the
    #            update (for example, because the task was canceled)
    public isolated function addArtifact(Part[] parts, string? name = ()) returns Error? {
        check requireNonEmpty("Artifact.parts", parts.length(), false);
        Artifact artifact = {artifactId: uuid:createType4AsString(), parts};
        if name is string {
            artifact.name = name;
        }
        // Delivered whole, not chunked -- this API takes the complete parts
        // array in one call, so every artifact is its own first-and-last
        // chunk. A future incremental-append API would set append/lastChunk
        // per call instead.
        TaskArtifactUpdateEvent event = {
            taskId: self.taskId,
            contextId: self.contextId,
            artifact: artifact.clone(),
            append: false,
            lastChunk: true
        };
        return self.write((), artifact, event);
    }

    # Completes the task successfully: `TASK_STATE_COMPLETED`.
    #
    # + message - An optional final status message
    # + return - An `a2a:Error` if the update could not be stored
    public isolated function complete(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_COMPLETED, message);
    }

    # Fails the task: `TASK_STATE_FAILED`.
    #
    # + message - An optional status message describing the failure
    # + return - An `a2a:Error` if the update could not be stored
    public isolated function failed(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_FAILED, message);
    }

    # Rejects the task: `TASK_STATE_REJECTED`. The agent declined to perform it.
    #
    # + message - An optional status message describing the rejection
    # + return - An `a2a:Error` if the update could not be stored
    public isolated function reject(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_REJECTED, message);
    }

    # Pauses the task awaiting client input: `TASK_STATE_INPUT_REQUIRED`.
    #
    # + message - The prompt describing what input is needed
    # + return - An `a2a:Error` if the update could not be stored
    public isolated function requireInput(Message message) returns Error? {
        return self.transition(TASK_STATE_INPUT_REQUIRED, message);
    }

    # Pauses the task awaiting authorization: `TASK_STATE_AUTH_REQUIRED`.
    #
    # + message - The prompt describing what authorization is needed
    # + return - An `a2a:Error` if the update could not be stored
    public isolated function requireAuth(Message message) returns Error? {
        return self.transition(TASK_STATE_AUTH_REQUIRED, message);
    }

    # Cancels the task: `TASK_STATE_CANCELED`. Called by the library for a
    # client's `cancelTask` while this updater is driving the task, so the
    # cancellation is written in turn with the agent's own updates and builds
    # on the latest of them. Every later update from the agent is refused.
    #
    # + return - The canceled task, a `TaskNotCancelableError` if the task has
    #            already ended, or an `a2a:Error` if the store refused it
    isolated function cancel() returns Task|Error {
        TaskStatus status = {state: TASK_STATE_CANCELED, timestamp: currentTimestamp()};
        TaskStatusUpdateEvent event = {taskId: self.taskId, contextId: self.contextId, status};
        check self.write(status, (), event, cancelling = true);
        return self.currentTask();
    }

    # Writes the task at the given state, carrying the artifacts
    # accumulated so far and the task's `history`/`metadata` forward, and
    # stamps the status timestamp.
    #
    # + state - The state to move to
    # + message - An optional status message
    # + return - An `a2a:Error` if the store rejected the transition
    private isolated function transition(TaskState state, Message? message) returns Error? {
        TaskStatus status = {state, timestamp: currentTimestamp()};
        if message is Message {
            status.message = message;
        }
        TaskStatusUpdateEvent event = {taskId: self.taskId, contextId: self.contextId, status};
        return self.write(status, (), event);
    }

    # Stores the task with a new status or one more artifact, then announces it.
    #
    # Everything happens under one lock: reading the last-written task,
    # storing the update, broadcasting it, and queuing it for the task's
    # webhooks. Two writers, such as the agent and a client's cancel,
    # therefore each build on the other's update rather than on a copy read
    # before it, and subscribers and webhooks see the updates in the order the
    # store took them. Nothing is announced until the store has taken the
    # update, so no one is told of a change the store refused.
    #
    # + status - The new status, or `()` to keep the current one
    # + artifact - The artifact to append, or `()`
    # + event - The event announcing the change
    # + cancelling - Whether this write is a client's cancellation
    # + return - An `a2a:Error` if the task was canceled, can no longer be
    #            canceled, or the store refused the update
    private isolated function write(TaskStatus? status, Artifact? artifact, StreamResponse event,
            boolean cancelling = false) returns Error? {
        boolean startDelivery = false;
        lock {
            TaskState current = self.base.status.state;
            if self.canceled {
                string msg = string `task ${self.taskId} was canceled and can no longer be updated`;
                return error InternalError(msg, message = msg);
            }
            if cancelling && isTerminalState(current) {
                string msg = string `task ${self.taskId} is in terminal state ${current} and cannot be canceled`;
                return error TaskNotCancelableError(msg, message = msg, code = -32002);
            }
            Task task = self.base.clone();
            Artifact[] accumulated = self.artifacts.clone();
            if artifact is Artifact {
                accumulated.push(artifact.clone());
            }
            if status is TaskStatus {
                task.status = status.clone();
            }
            if accumulated.length() > 0 {
                task.artifacts = accumulated.clone();
            }
            Error? putResult = self.store.put(task.clone(), self.owner);
            if putResult is Error {
                return putResult;
            }

            if !self.seedEmitted {
                self.seedEmitted = true;
                // The task as it was before the agent's first update. Only
                // the seed carries history, so this is the one place per
                // stream the request's historyLength applies.
                self.broadcaster.push(projectTask(self.base.clone(), true, self.historyLength));
            }
            self.touchedFlag = true;
            self.canceled = cancelling;
            self.artifacts = accumulated;
            self.base = task;
            self.broadcaster.push(event.clone());
            TaskUpdateListener? updateListener = self.updateListener;
            if updateListener is TaskUpdateListener {
                startDelivery = updateListener.queueUpdate(self.taskId, task.clone());
            }
        }
        TaskUpdateListener? updateListener = self.updateListener;
        if startDelivery && updateListener is TaskUpdateListener {
            updateListener.deliverUpdates(self.taskId);
        }
    }

    # Whether a client's cancellation went through this updater.
    #
    # + return - `true` once `cancel` has succeeded
    isolated function wasCanceled() returns boolean {
        lock {
            return self.canceled;
        }
    }

    # Whether `execute` has driven this task through the updater at
    # least once -- `false` only when `execute` returns a direct
    # `Message` without ever calling a state-changing method on this updater.
    #
    # Package-private -- `sendMessage`/`sendStreamingMessage` use this to
    # tell "the agent never drove the task" apart from "the agent drove it
    # to a state that happens to look unfinished."
    #
    # + return - Whether the updater was used
    isolated function touched() returns boolean {
        lock {
            return self.touchedFlag;
        }
    }

    # The task's current state -- the last value written via `transition`,
    # or the original `base` if `execute` never touched the updater.
    #
    # Package-private -- read after `execute` returns, when a caller
    # needs the final task without a separate store read (e.g. after a
    # direct `Message` reply, when the store copy was already removed).
    #
    # + return - The current task state
    isolated function currentTask() returns Task {
        lock {
            return self.base.clone();
        }
    }

}


# The current time as a status timestamp: ISO 8601 in UTC, at millisecond
# precision, which [specification section 5.6.1](https://a2a-protocol.org/latest/specification/#561-timestamps)
# says SHOULD be used. `time:utcNow()` alone carries microseconds.
#
# + return - The timestamp, e.g. `2026-10-08T09:23:05.617Z`
isolated function currentTimestamp() returns string => time:utcToString(time:utcNow(3));
