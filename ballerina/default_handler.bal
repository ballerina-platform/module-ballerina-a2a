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

// The template behind an `a2a:Service`'s operations.
//
// This is the `DefaultRequestHandler` equivalent: the developer's
// `a2a:AgentExecutor` is the only business logic, and this turns its result
// into the operations a client can call. sendMessage creates a task and drives
// it (or passes a direct Message straight back); getTask/cancelTask/listTasks
// read and mutate through the `TaskStore`.
//
// It knows nothing of any transport and nothing of the agent card. A developer
// builds one per agent, holds it in the service, and has each operation the
// service defines hand its request here; the listener owns the wire --
// authentication, the served card, stream keep-alives -- and builds the
// `Context` every operation receives.

import ballerina/lang.runtime;
import ballerina/log;
import ballerina/uuid;

# What `DefaultHandler.resolveTaskForSend` hands `handleSendMessage`/
# `handleSendStreamingMessage`: the task id and context id to drive, its
# current stored state to seed the `TaskUpdater` with, and whether this
# is a fresh task (as opposed to a continuation of one that already
# existed before this call).
type ResolvedSendTarget record {|
    # The task id to drive
    string taskId;
    # The task's context id
    string contextId;
    # The task to seed the `TaskUpdater` with: the fresh task, or, for a
    # continued one, the copy read before the driver claim, which
    # `commitSendTarget` reads again under the claim
    Task seed;
    # Whether `taskId` was freshly seeded for this call
    boolean isNewTask;
|};

# Configuration for an `a2a:DefaultHandler`: everything about the agent that
# does not depend on how requests reach it.
public type DefaultHandlerConfiguration record {|
    # The store the server keeps its tasks in. Defaults to an in-memory store
    # that does not survive a restart; supply an `a2a:TaskStore` of your own
    # for durable storage.
    TaskStore taskStore = new InMemoryTaskStore();
    # The richer card `handleGetExtendedAgentCard` returns to callers who request
    # it. Unset, the operation fails with `a2a:ExtendedAgentCardNotConfiguredError`.
    # The listener derives the capabilities and interfaces of what is served.
    #
    # A service that defines `get extendedAgentCard` requires authentication:
    # the operation is for authenticated callers, so its listener refuses to
    # start without `auth` ([specification section 13.3](https://a2a-protocol.org/latest/specification/#133-extended-agent-card-access-control)).
    AgentCard? extendedAgentCard = ();
    # Resolves each request's caller to an owner scope, for task-visibility
    # scoping per [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping). Unset, the identity the
    # listener's `auth` established is the owner, and with no `auth` either,
    # every task is visible to every caller. See `a2a:TaskOwnerResolver`.
    TaskOwnerResolver? ownerResolver = ();
    # Delivers task updates to registered push-notification webhooks.
    # Defaults to `a2a:HttpPushNotificationSender`, a real HTTP POST — unlike
    # `ownerResolver`, delivery needs no identity this library cannot
    # invent, so it has a working default rather than an optional hook.
    PushNotificationSender pushSender = new HttpPushNotificationSender();
|};

# How one live stream behaves while nothing is happening: the listener's
# policy, which the handler applies to each stream it hands out. Carried to the
# handler in `a2a:Context.streamTiming`.
public type StreamTiming record {|
    # Seconds of no events before the stream ends; `0` disables the timeout
    decimal idleTimeout = 0;
    # Seconds of no events before the stream sends a keep-alive; `0` sends none
    decimal keepAliveInterval = 0;
|};

# Runs the A2A protocol for one agent: its tasks, their lifecycle, live
# streams, and push-notification configuration.
#
# Hold one in the agent's service and have each operation hand its request here:
#
# ```ballerina
# isolated service on agent {
#     private final a2a:DefaultHandler handler = new (new WeatherExecutor());
#
#     isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
#             returns a2a:Task|a2a:Error {
#         return self.handler.handleGetTask(context, request);
#     }
#     // ...
# }
# ```
#
# Every operation resolves the caller's owner scope from the `a2a:Context`
# itself, so it is the only per-call input.
public isolated class DefaultHandler {
    // The extended card, as configured, or `()`
    private final (AgentCard & readonly)? extendedAgentCard;
    private final AgentExecutor executor;
    private final TaskStore store;
    // The registered push-notification configs, keyed by taskId, then by the
    // config's own id. In-memory only, like InMemoryTaskStore.
    private map<map<TaskPushNotificationConfig>> pushConfigs = {};
    private final TaskOwnerResolver? ownerResolver;
    private final PushNotificationSender pushSender;
    private final EventBroadcasterRegistry registry;
    // The updater of each task being driven right now, so `handleCancelTask` can
    // write its cancellation through it.
    private map<TaskUpdater> drivers = {};
    // The stored updates of each task still waiting to reach its webhooks,
    // oldest first. A task has an entry only while a strand is delivering
    // them; see `taskUpdated`.
    private map<Task[]> pendingPushes = {};

    # Creates a handler.
    #
    # + executor - The agent's logic, run for every message the handler accepts
    # + config - Where the agent's tasks are kept, who may see them, and how
    #            their updates are delivered
    public isolated function init(AgentExecutor executor, *DefaultHandlerConfiguration config) {
        self.executor = executor;
        AgentCard? extended = config.extendedAgentCard;
        self.extendedAgentCard = extended is AgentCard ? extended.cloneReadOnly() : ();
        self.store = config.taskStore;
        self.ownerResolver = config.ownerResolver;
        self.pushSender = config.pushSender;
        self.registry = new InMemoryEventBroadcasterRegistry();
    }

    # Resolves a caller's owner scope: the configured `a2a:TaskOwnerResolver`'s
    # answer, or the authenticated identity when none is configured
    # ([specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping)).
    #
    # + context - Who is calling, as the receiving listener established it
    # + return - The owner scope, `()` for the shared unscoped pool, or an
    #            error if the resolver failed
    private isolated function resolveOwner(Context context) returns string?|Error {
        TaskOwnerResolver? resolver = self.ownerResolver;
        if resolver is TaskOwnerResolver {
            return resolver.resolveOwner(context);
        }
        return context?.identity;
    }

    # Handles sendMessage: create a task (or continue an existing one named
    # by `message.taskId`), run the developer's `execute` against it, and
    # return the finished task — or the direct `Message` the agent returned
    # instead.
    #
    # A client-supplied `contextId` is honoured; otherwise one is generated and
    # carried on the task, as [section 3.4.1](https://a2a-protocol.org/latest/specification/#341-context-identifier-semantics) requires.
    #
    # + request - The decoded send request
    # + context - Who is calling, and the tenant the request was routed under
    # + return - The finished Task or a direct Message, or an error
    public isolated function handleSendMessage(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        string? tenant = context?.tenant;
        string? owner = check self.resolveOwner(context);
        check validateReceivedMessage(request.message);
        check validatePushConfigId(request?.configuration?.taskPushNotificationConfig);

        ResolvedSendTarget target = check self.resolveSendTarget(request, owner);
        string taskId = target.taskId;
        string contextId = target.contextId;

        // Claimed before anything about this request is persisted: a
        // second concurrent message to a task already being driven --
        // only reachable via continuation, since a fresh taskId is always
        // unique -- must be rejected with no trace, not after this
        // request's message has already been written into the task's
        // history and its inline push config already registered. See
        // resolveSendTarget's own doc comment.
        EventBroadcaster? broadcaster = self.registry.acquire(taskId);
        if broadcaster is () {
            string msg = string `task ${taskId} is already being processed`;
            return error UnsupportedOperationError(msg, message = msg, code = -32004);
        }
        Task|Error committed = self.commitSendTarget(target, request, owner);
        if committed is Error {
            // The driving slot was claimed on the strength of a store write
            // that then failed -- release it (not as "stopped": nothing was
            // ever driven or broadcast, so there is no terminal event to
            // account for, just a claim to give back) rather than leave the
            // task stuck as permanently "being processed".
            self.registry.release(taskId, false);
            return committed;
        }
        Task seed = committed;

        // A client cannot name a taskId that doesn't exist yet, so the
        // spec's own registration channel for this case is inline on the
        // send request itself -- "leave unset in a sendMessage request"
        // doc-commented on TaskPushNotificationConfig.taskId. The task now
        // exists (either just seeded, or already did as the task
        // continued), so registering it here needs no existence check,
        // unlike createTaskPushNotificationConfig's own.
        TaskPushNotificationConfig? inlineConfig = request?.configuration?.taskPushNotificationConfig;
        if inlineConfig is TaskPushNotificationConfig {
            TaskPushNotificationConfig _ = self.registerPushConfig(taskId, inlineConfig);
        }

        final RequestContext requestContext = requestContextOf(request.message, tenant, owner, request?.configuration);
        // Specification 3.2.2/3.2.4: unset imposes no limit, 0 omits
        // history entirely. Threaded into the updater too, so the one Task
        // snapshot sendStreamingMessage's stream broadcasts respects it as
        // well -- this method's own callers never see that snapshot, but
        // sendStreamingMessage constructs its updater the same way.
        int? historyLength = request?.configuration?.historyLength;
        final TaskUpdater updater = new (taskId, contextId, self.store, owner, seed, broadcaster, historyLength,
            self);
        self.trackDriver(taskId, updater);

        boolean returnImmediately = request?.configuration?.returnImmediately ?: false;
        if returnImmediately {
            // The task already exists (seeded, or continued and
            // persisted, above) -- hand it back now, without waiting for
            // driveTask, which keeps running on its own detached strand
            // exactly like sendStreamingMessage's own driver. projectTask
            // clones rather than mutating `seed` in place: `seed` is also
            // `updater`'s own `base`, which must keep the task's full
            // history for later writes to carry forward.
            future<()> _ = start self.finishDrivenTask(
                    taskId, owner, requestContext.clone(), updater, broadcaster, target.isNewTask, true);
            return projectTask(seed, true, historyLength);
        }

        future<Task|Message|Error> f =
            start self.driveTask(taskId, owner, requestContext.clone(), updater, broadcaster, target.isNewTask, false);
        // Webhooks were notified of each update as the updater stored it.
        Task|Message|Error result = self.settledResult(taskId, owner, self.awaitDriveTask(f));
        boolean stopped = resultStopped(result, target.isNewTask);
        if stopped {
            broadcaster.close();
        }
        self.untrackDriver(taskId);
        self.registry.release(taskId, stopped);
        if result is Task {
            return projectTask(result, true, historyLength);
        }
        return result;
    }

    # Resolves the task a sendMessage/sendStreamingMessage call would drive: a
    # fresh `TASK_STATE_SUBMITTED` task, or, when `message.taskId` names one,
    # that task continued with `request.message` appended to its history.
    # Read-only -- neither branch writes to the store. The caller commits the
    # result with `commitSendTarget`, once it holds `registry.acquire`'s
    # exclusive driving claim for the task, so a request this call resolves
    # but the caller then rejects (a second concurrent message to a task
    # already being driven) leaves no trace: no history entry, no inline push
    # config registered. Before this split, both were written here,
    # unconditionally, ahead of that check.
    #
    # The fresh task's `history` seeds with the triggering message itself --
    # matching the reference `a2a-sdk`'s own `new_task_from_user_message`
    # helper, and this function's own continuation branch, which has always
    # appended the triggering message to an existing task's history.
    # Specification 3.7 leaves this agent-defined ("the agent is responsible
    # to determine which Messages are persisted in the Task History"), so
    # this is a consistency choice, not a spec requirement.
    #
    # Per specification 3.4.2, an unrecognized `taskId` is never treated
    # as "create a new task with this id" -- a client cannot name a task
    # into existence -- so an unknown id is `TaskNotFoundError`. Per
    # 3.4.3, a `contextId` that disagrees with the task's own is rejected
    # outright rather than one silently overriding the other, and the
    # continuation's own `contextId` is what the rest of the call uses
    # either way. Gated on terminal state only, per specification 3.1.1
    # ("messages sent to tasks in a terminal state... cannot accept
    # further messages") -- any non-terminal state may be continued; the
    # actual concurrency guard against two overlapping drivers is
    # `registry.acquire`'s interlock in the caller, not a narrower state
    # restriction here.
    #
    # + request - The decoded send request
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The resolved target, not yet persisted, or an error
    private isolated function resolveSendTarget(SendMessageRequest request, string? owner)
            returns ResolvedSendTarget|Error {
        string? continuedTaskId = request.message?.taskId;
        if continuedTaskId is () {
            string contextId = request.message?.contextId ?: uuid:createType4AsString();
            string taskId = uuid:createType4AsString();
            Task seed = {
                id: taskId,
                contextId,
                status: {state: TASK_STATE_SUBMITTED, timestamp: currentTimestamp()},
                history: [request.message.clone()]
            };
            return {taskId, contextId, seed, isNewTask: true};
        }

        Task seed = check self.continuedSeed(continuedTaskId, request, owner);
        return {taskId: continuedTaskId, contextId: seed.contextId ?: "", seed, isNewTask: false};
    }

    # Reads a task a message continues and appends the message to it, after
    # checking the message may continue it.
    #
    # + taskId - The task the message names
    # + request - The decoded send request
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The task with the message appended, not yet persisted, or an error
    private isolated function continuedSeed(string taskId, SendMessageRequest request, string? owner)
            returns Task|Error {
        Task? existing = check self.store.get(taskId, owner);
        if existing is () {
            return taskNotFound(taskId);
        }
        // Every task this library creates has a contextId -- it is set
        // unconditionally by resolveSendTarget's own fresh-task branch
        // -- so an empty fallback here is unreachable in practice; the
        // field is merely optional in the wire type itself.
        string existingContextId = existing.contextId ?: "";
        string? suppliedContextId = request.message?.contextId;
        if suppliedContextId is string && suppliedContextId != existingContextId {
            string msg = string `message.contextId "${suppliedContextId}" does not match task `
                + string `${taskId}'s own contextId "${existingContextId}"`;
            return invalidRequest(msg);
        }
        if isTerminalState(existing.status.state) {
            string msg = string `task ${taskId} is in terminal state ${existing.status.state} `
                + "and cannot accept further messages";
            return error UnsupportedOperationError(msg, message = msg, code = -32004);
        }

        Message[] history = existing?.history is Message[] ? (<Message[]>existing?.history).clone() : [];
        history.push(request.message.clone());
        existing.history = history;
        return existing;
    }

    # Persists a target `resolveSendTarget` resolved, once the caller holds
    # `registry.acquire`'s exclusive claim on driving it -- so this is the
    # only write to the task between the claim being taken and `execute`
    # starting, and nothing else can be concurrently writing the same task
    # underneath it (a running driver would itself hold that same claim).
    #
    # A continued task is read again here, under the claim. The read in
    # `resolveSendTarget` came before it, so another turn may have finished
    # in between; writing that earlier copy would erase the turn's history,
    # artifacts and status. The checks are repeated on the fresh copy too,
    # since that turn may have ended the task.
    #
    # + target - The resolved target to persist
    # + request - The decoded send request
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The task as persisted, to seed the `TaskUpdater` with, or an error
    private isolated function commitSendTarget(ResolvedSendTarget target, SendMessageRequest request, string? owner)
            returns Task|Error {
        Task seed = target.isNewTask ? target.seed : check self.continuedSeed(target.taskId, request, owner);
        check self.store.put(seed, owner);
        return seed;
    }

    # Runs `execute` for one task, detached from the request that started
    # it -- so a slow agent never blocks the strand a separate
    # `handleSubscribeToTask` call needs to attach to the same task's live events.
    #
    # A panic in agent code is trapped rather than left to propagate: with
    # `returnImmediately: true`, or once a subscriber is watching live,
    # there is no synchronous caller left to receive it if it escapes.
    # Both a trapped panic and `execute` returning an `Error` transition
    # the task to `TASK_STATE_FAILED` via the same `updater-&gt;failed(...)`
    # an agent itself would call, and forward that Error to whoever
    # eventually reads this call's result -- the only way a live or later
    # observer learns anything went wrong once execution is no longer
    # synchronous.
    #
    # + taskId - The task being driven
    # + owner - The caller's resolved owner scope, or `()`
    # + context - The message and request context to hand to `execute`
    # + updater - The bound updater; already carries the broadcaster and base
    # + broadcaster - The task's broadcaster -- `updater` only ever
    #                 broadcasts a `Task`-lifecycle event, so a direct
    #                 `Message` reply (which never touches `updater`) is
    #                 pushed here instead, the one event a live
    #                 `handleSendStreamingMessage` subscriber must still see
    # + isNewTask - Whether `taskId` was freshly seeded for this call
    #               (as opposed to an existing task being continued) --
    #               controls whether a direct `Message` reply removes it
    #               from the store, below
    # + returnImmediately - Whether `handleSendMessage`'s caller already
    #                        received this task's id before `execute`
    #                        even started -- if so, a direct `Message`
    #                        reply can no longer make the task disappear
    #                        as if it never existed (see below). Always
    #                        `false` from `handleSendStreamingMessage`, which
    #                        the specification says this configuration
    #                        field has no effect on: a live subscriber
    #                        only ever learns a taskId once the seed is
    #                        actually broadcast, which a direct reply
    #                        never causes, so there is no early exposure
    #                        to account for there.
    # + return - The direct `Message`, the finished `Task`, or an `Error`
    private isolated function driveTask(string taskId, string? owner, RequestContext context, TaskUpdater updater,
            EventBroadcaster broadcaster, boolean isNewTask, boolean returnImmediately) returns Task|Message|Error {
        Message|Error?|error direct = trap self.executor.execute(context, updater);

        if direct is Message {
            if returnImmediately {
                // The caller already received (and may already be
                // relying on) this task's id, from the immediate-return
                // snapshot sendMessage handed back before execute even
                // started. A direct reply can no longer make the task
                // disappear as if it never existed -- complete it with
                // the Message as its final status.message instead, so a
                // later getTask sees a real, resting task rather than
                // one stuck at SUBMITTED forever. The Message is still
                // broadcast in its own right first, so a live observer
                // sees both the literal reply and the resulting
                // COMPLETED status, same as any other addArtifact-then-
                // complete sequence would produce.
                broadcaster.push(direct);
                Error? completeResult = updater.complete(direct);
                if completeResult is Error {
                    return completeResult;
                }
                return updater.currentTask();
            }
            // A direct reply on a fresh task under the default blocking
            // contract: the seeded task was never part of the
            // conversation, so drop it and hand the Message back. A
            // direct reply on a *continued* task, by contrast, leaves
            // that task's already-real history and state alone -- it
            // existed before this call and the client already holds its
            // id, so a reply this call happens not to route through the
            // updater must not erase it.
            if isNewTask {
                check self.store.remove(taskId, owner);
            }
            broadcaster.push(direct);
            return direct;
        }

        Error? failure = ();
        if direct is Error {
            failure = direct;
        } else if direct is error {
            failure = wrapTransportError(direct);
        } else if !updater.touched() {
            failure = invalidAgentResponse(
                    string `execute returned without driving the task to a state for ${taskId}`);
        }
        if failure is Error && (updater.wasCanceled() || self.endedElsewhere(taskId, owner, updater)) {
            // A client canceled the task while `execute` ran, or another
            // writer ended it, and the agent's next write was refused. That
            // is not the agent failing: hand back the updater's copy and let
            // `settledResult` replace it with the stored task.
            return updater.currentTask();
        }
        if failure is Error {
            // The agent's own failure, which otherwise only reaches the
            // caller: logged so it is visible on the server too.
            log:printError("A2A agent failed to handle a message; the task is marked FAILED", 'error = failure,
                    taskId = taskId);
            Message failMessage = {
                messageId: uuid:createType4AsString(),
                role: ROLE_AGENT,
                parts: [{text: failure.message()}]
            };
            // Best-effort: if even marking the task FAILED fails (e.g. a
            // concurrent cancelTask already moved it to a different
            // terminal state), the original failure is still what's
            // reported -- there is nothing more useful to do with a
            // second error here.
            Error? failTransitionResult = updater.failed(failMessage);
            if failTransitionResult is Error {
                // Deliberately not propagated; see comment above.
            }
            return failure;
        }

        return updater.currentTask();
    }

    # Whether another writer ended the task: it is in a terminal state the
    # updater did not write.
    #
    # + taskId - The task that was driven
    # + owner - The caller's resolved owner scope, or `()`
    # + updater - The drive's updater
    # + return - `true` if the stored task is terminal in a state the updater did not reach
    private isolated function endedElsewhere(string taskId, string? owner, TaskUpdater updater) returns boolean {
        Task|Error? stored = self.store.get(taskId, owner);
        return stored is Task && isTerminalState(stored.status.state)
            && stored.status.state != updater.currentTask().status.state;
    }

    # Normalizes `wait` on a `future&lt;Task|Message|Error&gt;`, which is
    # statically `Task|Message|Error|error` -- the trailing bare `error` arm
    # is the panic channel `wait` itself can surface (distinct from, and in
    # addition to, `driveTask`'s own internal `trap`), wrapped the same way
    # every other unnamed transport failure is.
    #
    # + f - The future to await
    # + return - The driven result, or a wrapped Error
    private isolated function awaitDriveTask(future<Task|Message|Error> f) returns Task|Message|Error {
        Task|Message|Error|error waited = wait f;
        if waited is Task {
            return waited;
        } else if waited is Message {
            return waited;
        } else if waited is Error {
            return waited;
        }
        // `waited` is a plain `error` here -- the panic channel `wait`
        // itself can surface. Every A2A spec type (Task, Message) is an
        // open record, so the compiler cannot narrow it out of the type
        // by elimination the way it would a closed type; the explicit
        // cast is what the module's own README documents for exactly
        // this situation.
        return wrapTransportError(<error>waited);
    }

    # Runs `driveTask` to completion and closes out its driving turn, all
    # on one detached strand -- used both by `handleSendStreamingMessage`
    # (always) and by `handleSendMessage` when `returnImmediately: true`, the
    # two cases where nothing is synchronously waiting on `driveTask`'s
    # own result, so there is nothing to hand it back to directly.
    # `driveTask` runs directly rather than through its own further
    # `start`/`wait` pair -- this whole method is already the detached
    # strand its caller started, so a second layer of detachment
    # underneath it would add nothing except a second future nobody needs
    # (and passing a `future` itself as a `start` argument is not an
    # isolated expression, so it is not even available as an option here).
    #
    # Order matters: the broadcaster only closes (or ends with an error)
    # once every live subscriber has already received whatever
    # `TaskStatusUpdateEvent` the store write produced, so a stream never
    # ends silently one event short of what a concurrent `handleGetTask` would
    # already show.
    #
    # + taskId - The task being driven
    # + owner - The caller's resolved owner scope, or `()`
    # + context - The message and request context to hand to `execute`
    # + updater - The bound updater; already carries the broadcaster and base
    # + broadcaster - The task's broadcaster
    # + isNewTask - Forwarded to `driveTask`
    # + returnImmediately - Forwarded to `driveTask`
    private isolated function finishDrivenTask(string taskId, string? owner, RequestContext context,
            TaskUpdater updater, EventBroadcaster broadcaster, boolean isNewTask, boolean returnImmediately) {
        Task|Message|Error result = self.settledResult(taskId, owner,
            self.driveTask(taskId, owner, context, updater, broadcaster, isNewTask, returnImmediately));
        boolean stopped = resultStopped(result, isNewTask);
        if result is Error {
            // driveTask already best-effort transitioned the task to
            // FAILED (pushing that TaskStatusUpdateEvent through the
            // broadcaster via `updater`) before returning this Error --
            // except when that best-effort transition itself failed (see
            // driveTask's own comment), in which case no event reached
            // the broadcaster at all. Either way, end every live
            // subscriber's stream with this Error as its completion,
            // rather than a silent close that leaves them unable to tell
            // "the task finished" from "the task's driver crashed".
            broadcaster.endWithError(result);
        } else if stopped {
            broadcaster.close();
        }
        self.untrackDriver(taskId);
        self.registry.release(taskId, stopped);
    }

    # What a drive that has just ended actually left behind, read from the
    # store rather than taken from the drive's own report.
    #
    # `driveTask` reports the `TaskUpdater`'s last-written copy of the task,
    # but the store is the truth: another writer may have moved the task
    # since the updater last wrote it, and the store then refuses the
    # updater's later writes -- so its copy stays behind. A task ended that
    # way while its `execute` was still running would otherwise be reported
    # as whatever state the agent last reached (say WORKING).
    #
    # + taskId - The task that was driven
    # + owner - The caller's resolved owner scope, or `()`
    # + result - `driveTask`'s already-`wait`ed result
    # + return - The result to act on, with the stored task in place of a
    #            stale one. A `Message` or `Error` result, or an unreadable
    #            store, passes through unchanged.
    private isolated function settledResult(string taskId, string? owner, Task|Message|Error result)
            returns Task|Message|Error {
        if result !is Task {
            return result;
        }
        Task|Error? stored = self.store.get(taskId, owner);
        return stored is Task ? stored : result;
    }

    # Handles sendStreamingMessage: like `handleSendMessage`, but returns a live
    # stream of every event the task produces, for the caller to frame as
    # SSE.
    #
    # `driveTask` runs detached, exactly as `handleSendMessage`'s does; the
    # difference is this returns as soon as a tap is attached to the
    # task's broadcaster, instead of waiting for `driveTask` to finish.
    # Per specification 3.1.2, what reaches the wire is: the just-seeded
    # Task (emitted lazily by `updater`, only once the agent actually
    # touches it -- see `TaskUpdater`) followed by the status/artifact
    # events `execute` drives the task through, or -- for a direct
    # reply, which never touches `updater` -- exactly one Message event,
    # pushed by `driveTask` itself.
    #
    # + request - The decoded send request
    # + context - Who is calling, the tenant the request was routed under, and
    #             the listener's idle-timeout and keep-alive policy for the stream
    # + return - A live stream of the task's events, or an error
    public isolated function handleSendStreamingMessage(Context context, SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        string? tenant = context?.tenant;
        string? owner = check self.resolveOwner(context);
        StreamTiming timing = context?.streamTiming ?: {};
        check validateReceivedMessage(request.message);
        check validatePushConfigId(request?.configuration?.taskPushNotificationConfig);

        ResolvedSendTarget target = check self.resolveSendTarget(request, owner);
        string taskId = target.taskId;
        string contextId = target.contextId;

        // See sendMessage's identical block: claimed, then committed, before
        // anything about this request is persisted or registered.
        EventBroadcaster? broadcaster = self.registry.acquire(taskId);
        if broadcaster is () {
            string msg = string `task ${taskId} is already being processed`;
            return error UnsupportedOperationError(msg, message = msg, code = -32004);
        }
        Task|Error committed = self.commitSendTarget(target, request, owner);
        if committed is Error {
            self.registry.release(taskId, false);
            return committed;
        }
        Task seed = committed;

        TaskPushNotificationConfig? inlineConfig = request?.configuration?.taskPushNotificationConfig;
        if inlineConfig is TaskPushNotificationConfig {
            TaskPushNotificationConfig _ = self.registerPushConfig(taskId, inlineConfig);
        }

        // Attached before driveTask starts, so nothing it broadcasts can
        // be missed between claiming the driver slot and this tap
        // existing.
        EventTap tap = broadcaster.newTap(timing.idleTimeout, timing.keepAliveInterval);

        final RequestContext requestContext = requestContextOf(request.message, tenant, owner, request?.configuration);
        // Specification 3.2.2/3.2.4: applies to the one Task snapshot this
        // stream ever broadcasts (the seed, on the agent's first touch of
        // updater) -- see task_updater.bal's own handling of it.
        int? historyLength = request?.configuration?.historyLength;
        final TaskUpdater updater = new (taskId, contextId, self.store, owner, seed, broadcaster, historyLength,
            self);
        self.trackDriver(taskId, updater);

        // returnImmediately has no effect on streaming per the
        // specification -- always false here; see driveTask's own doc.
        future<()> _ = start self.finishDrivenTask(
                taskId, owner, requestContext.clone(), updater, broadcaster, target.isNewTask, false);

        stream<StreamResponse, Error?> result = new (tap);
        return result;
    }

    # Handles subscribeToTask: the task's current state, followed by every
    # further event a driver still running against it produces, live.
    #
    # Per specification 3.1.6, a task already in a terminal state cannot be
    # subscribed to -- `UnsupportedOperationError`, the same rejection
    # `handleSendMessage`/`handleSendStreamingMessage` give a message aimed at one.
    # (This corrects this server's previous behavior, which answered a
    # one-event snapshot instead; see the changelog.) Otherwise, the tap
    # attaches to the task's broadcaster *before* the snapshot actually
    # streamed is read -- attach-then-read can duplicate one event if a
    # driver writes between the two (harmless: a client already reconciles
    # on task state), but read-then-attach can lose one in the same window,
    # which is not recoverable once missed.
    #
    # Subscribing to a task paused on `TASK_STATE_INPUT_REQUIRED` returns its
    # snapshot and then waits for the client's next message to drive it; the
    # stream ends when that turn reaches the next interrupted or terminal state.
    #
    # + request - The task identifier
    # + context - Who is calling, and the listener's idle-timeout and keep-alive
    #             policy for the stream
    # + return - The live stream, a TaskNotFoundError, or an
    #            UnsupportedOperationError if the task is already terminal
    public isolated function handleSubscribeToTask(Context context, SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        string? owner = check self.resolveOwner(context);
        StreamTiming timing = context?.streamTiming ?: {};
        Task? task = check self.store.get(request.id, owner);
        if task is () {
            return taskNotFound(request.id);
        }
        if isTerminalState(task.status.state) {
            string msg = string `task ${request.id} is in terminal state ${task.status.state} `
                + "and cannot be subscribed to";
            return error UnsupportedOperationError(msg, message = msg, code = -32004);
        }

        EventBroadcaster broadcaster = self.registry.subscribe(request.id);
        EventTap tap = broadcaster.newTap(timing.idleTimeout, timing.keepAliveInterval);

        // Re-read after attaching, not the copy from the existence check
        // above -- a driver may have written between the two, and the
        // snapshot prepended must be the freshest one available.
        Task? fresh = check self.store.get(request.id, owner);
        if fresh is () {
            // The task existed moments ago and was removed before this
            // tap could attach -- only possible for a direct-Message
            // reply's seed removal, racing implausibly close to this
            // call. Nothing further will ever be broadcast to it either,
            // so report it the same way a subscribe that never found the
            // task at all would.
            return taskNotFound(request.id);
        }
        tap.prependSnapshot(fresh);
        if isTerminalState(fresh.status.state) {
            // Lost the race: the task reached a terminal state, and its
            // driver already closed and released the broadcaster that
            // existed for it -- registry.subscribe above, finding none, just
            // created a fresh one, which nothing will ever push to or close.
            // Specification 3.1.6 is still satisfied on the wire ("MUST
            // return a Task object as the first event... representing the
            // current state at the time of subscription", "the stream MUST
            // terminate when the task reaches a terminal state"): the
            // caller gets exactly that Task, then a clean end. What's fixed
            // here is what happens after: without this, the just-created
            // broadcaster stayed in the registry forever (nothing but
            // `release` ever removes a `broadcasters` entry, and nothing
            // else calls `release` for one `subscribe` alone created), and
            // the tap itself sat idle until `streamIdleTimeout` (5 minutes
            // by default) instead of ending with this call.
            tap.signalDone();
            self.registry.release(request.id, true);
        }

        stream<StreamResponse, Error?> result = new (tap);
        return result;
    }

    # Handles getTask.
    #
    # + request - The task identifier and optional history length
    # + context - Who is calling, as the listener established it
    # + return - The task, or a TaskNotFoundError
    public isolated function handleGetTask(Context context, GetTaskRequest request) returns Task|Error {
        string? owner = check self.resolveOwner(context);
        Task? task = check self.store.get(request.id, owner);
        if task is () {
            return taskNotFound(request.id);
        }
        return projectTask(task, true, request?.historyLength);
    }

    # Handles cancelTask.
    #
    # A task already in a terminal state cannot be canceled ([section 3.1.1](https://a2a-protocol.org/latest/specification/#311-send-message)), so
    # that is a TaskNotCancelableError.
    #
    # + request - The task identifier
    # + context - Who is calling, as the listener established it
    # + return - The canceled task, or an error
    public isolated function handleCancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        string? owner = check self.resolveOwner(context);
        Task? task = check self.store.get(request.id, owner);
        if task is () {
            return taskNotFound(request.id);
        }
        if isTerminalState(task.status.state) {
            return notCancelable(request.id, task.status.state);
        }
        // Every write to a task happens under its driver claim, so the
        // cancellation is written either through the updater driving the task
        // or under the claim itself, and never over a copy another writer has
        // since replaced. Between a send taking the claim and registering its
        // updater there is a short window in which neither is available; the
        // cancel waits it out.
        foreach int _ in 0 ..< CANCEL_CLAIM_ATTEMPTS {
            TaskUpdater? driver;
            lock {
                driver = self.drivers[request.id];
            }
            if driver is TaskUpdater {
                return self.cancelDriven(request.id, driver);
            }
            EventBroadcaster? claimed = self.registry.acquire(request.id);
            if claimed is EventBroadcaster {
                return self.cancelIdle(request.id, owner, claimed);
            }
            runtime:sleep(CANCEL_CLAIM_RETRY_SECONDS);
        }
        string msg = string `task ${request.id} is busy and could not be canceled; try again`;
        return error InternalError(msg, message = msg);
    }

    # Cancels a task through the updater that is driving it.
    #
    # + taskId - The task to cancel
    # + driver - The task's updater
    # + return - The canceled task, or an error
    private isolated function cancelDriven(string taskId, TaskUpdater driver) returns Task|Error {
        Task canceled = check driver.cancel();
        // The updater announced the CANCELED status; the task's streams end
        // here rather than when the agent next tries to write.
        EventBroadcaster? broadcaster = self.registry.peekBroadcaster(taskId);
        if broadcaster is EventBroadcaster {
            broadcaster.close();
        }
        return canceled;
    }

    # Cancels a task no driver is running, under the driver claim the caller
    # took for it, and gives the claim back.
    #
    # + taskId - The task to cancel
    # + owner - The caller's resolved owner scope, or `()`
    # + broadcaster - The task's broadcaster, from taking the claim
    # + return - The canceled task, or an error
    private isolated function cancelIdle(string taskId, string? owner, EventBroadcaster broadcaster)
            returns Task|Error {
        // Read again under the claim: the copy `handleCancelTask` checked may have
        // been replaced by a turn that has since finished.
        Task|Error canceled = self.writeCancellation(taskId, owner);
        if canceled is Error {
            self.registry.release(taskId, false);
            return canceled;
        }
        // Only after the store write lands, so a subscriber never sees a
        // CANCELED the store refused.
        TaskStatusUpdateEvent event = {taskId, contextId: canceled.contextId ?: "", status: canceled.status};
        broadcaster.push(event);
        broadcaster.close();
        if self.queueUpdate(taskId, canceled) {
            self.deliverUpdates(taskId);
        }
        self.registry.release(taskId, true);
        return canceled;
    }

    # Writes a task as canceled, for `cancelIdle`.
    #
    # + taskId - The task to cancel
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The canceled task, or an error
    private isolated function writeCancellation(string taskId, string? owner) returns Task|Error {
        Task? task = check self.store.get(taskId, owner);
        if task is () {
            return taskNotFound(taskId);
        }
        if isTerminalState(task.status.state) {
            return notCancelable(taskId, task.status.state);
        }
        task.status = {state: TASK_STATE_CANCELED, timestamp: currentTimestamp()};
        check self.store.put(task, owner);
        return task;
    }

    # Records the updater driving a task, for `handleCancelTask`.
    #
    # + taskId - The task being driven
    # + updater - Its updater
    private isolated function trackDriver(string taskId, TaskUpdater updater) {
        lock {
            self.drivers[taskId] = updater;
        }
    }

    # Forgets the updater of a task whose drive has ended. Called before the
    # driver claim is released, so a cancel never finds the claim free while
    # the updater is still recorded.
    #
    # + taskId - The task whose drive ended
    private isolated function untrackDriver(string taskId) {
        lock {
            _ = self.drivers.removeIfHasKey(taskId);
        }
    }

    # Handles listTasks.
    #
    # + request - The filter and pagination parameters
    # + context - Who is calling, as the listener established it
    # + return - A page of tasks
    public isolated function handleListTasks(Context context, ListTasksRequest request)
            returns ListTasksResponse|Error {
        string? owner = check self.resolveOwner(context);
        return self.store.list(request, owner);
    }

    # Handles createTaskPushNotificationConfig: registers a webhook config
    # against an existing task. The config's own `id` is kept when the caller
    # chose one; otherwise the server assigns one.
    #
    # + request - The config to register; `taskId` must be set and name an
    #             existing task
    # + context - Who is calling, as the listener established it
    # + return - The stored config, with `id` filled in, or a
    #            TaskNotFoundError if `taskId` names no task visible to
    #            `owner`
    public isolated function handleCreateTaskPushNotificationConfig(Context context,
            TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error {
        string? owner = check self.resolveOwner(context);
        check validatePushConfigId(request, "id");
        string? taskId = request?.taskId;
        if taskId is () {
            string msg = "TaskPushNotificationConfig.taskId is required to register a config";
            return invalidRequest(msg);
        }
        Task? task = check self.store.get(taskId, owner);
        if task is () {
            return taskNotFound(taskId);
        }
        return self.registerPushConfig(taskId, request);
    }

    # Registers a config against a task already known to exist. Shared by
    # `handleCreateTaskPushNotificationConfig` (after its own taskId-existence
    # check) and `handleSendMessage`/`handleSendStreamingMessage`'s inline
    # `SendMessageConfiguration.taskPushNotificationConfig` registration --
    # the seed `store.put` immediately above each call site already
    # establishes the task exists, so neither needs the check again.
    #
    # The caller's own `id` is kept when it chose one (an empty id counts as
    # unset), so the config can later be fetched or deleted under the name
    # the caller gave it; otherwise the server assigns a UUID. Registering the
    # same id twice on one task replaces the earlier config. The id is checked
    # by `validatePushConfigId` before any task is seeded, not here.
    #
    # + taskId - The task's id
    # + config - The config to register
    # + return - The stored config, with `taskId` and `id` filled in
    isolated function registerPushConfig(string taskId, TaskPushNotificationConfig config)
            returns TaskPushNotificationConfig {
        TaskPushNotificationConfig stored = config.clone();
        stored.taskId = taskId;
        string? chosen = config?.id;
        stored.id = chosen is string && chosen != "" ? chosen : uuid:createType4AsString();
        lock {
            map<TaskPushNotificationConfig> forTask = self.pushConfigs[taskId] ?: {};
            forTask[<string>stored.id] = stored.clone();
            self.pushConfigs[taskId] = forTask;
        }
        return stored;
    }

    # Handles getTaskPushNotificationConfig.
    #
    # A task not visible to `owner` is treated identically to an unknown
    # config on a known task -- both are `TaskNotFoundError`, so a caller
    # cannot distinguish "not your task" from "no such config" by response
    # shape, per [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping).
    #
    # + request - The parent task id and the config's own id
    # + context - Who is calling, as the listener established it
    # + return - The config, or a TaskNotFoundError if either id is unknown,
    #            or the task is not visible to `owner`
    public isolated function handleGetTaskPushNotificationConfig(Context context,
            GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error {
        string? owner = check self.resolveOwner(context);
        Task? task = check self.store.get(request.taskId, owner);
        if task is () {
            return taskPushNotificationConfigNotFound(request.taskId, request.id);
        }
        lock {
            map<TaskPushNotificationConfig>? forTask = self.pushConfigs[request.taskId];
            TaskPushNotificationConfig? config = forTask is map<TaskPushNotificationConfig>
                ? forTask[request.id] : ();
            if config is () {
                return taskPushNotificationConfigNotFound(request.taskId, request.id);
            }
            return config.clone();
        }
    }

    # Handles listTaskPushNotificationConfigs. No pagination cursor is
    # actually needed at realistic per-task config counts, so every result
    # is returned as one page.
    #
    # A task not visible to `owner` returns an empty page, matching this
    # operation's existing behavior for a genuinely unknown task -- neither
    # case is an error, and the two must stay indistinguishable per
    # [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping).
    #
    # + request - The parent task id
    # + context - Who is calling, as the listener established it
    # + return - Every config registered for the task, or an empty page if
    #            the task is not visible to `owner`
    public isolated function handleListTaskPushNotificationConfigs(Context context,
            ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error {
        string? owner = check self.resolveOwner(context);
        Task? task = check self.store.get(request.taskId, owner);
        if task is () {
            return {configs: [], nextPageToken: ""};
        }
        TaskPushNotificationConfig[] configs;
        lock {
            // Not `(self.pushConfigs[request.taskId] ?: {}).toArray().clone()`, chained
            // in one expression: confirmed by a standalone repro to panic with a JVM
            // NullPointerException ("this.originalMemberTypes is null") specifically for
            // a task with no registered configs, where the map<T> the elvis operator
            // supplies is an anonymous `{}` immediately chained into `.toArray()` --
            // `ballerina/lang.value:clone`'s native implementation doesn't get that
            // array's member-type metadata in this one shape. Binding the map to an
            // explicitly-typed local first avoids it -- confirmed by the same repro --
            // and matches the pattern already used a few lines up in
            // getTaskPushNotificationConfig.
            map<TaskPushNotificationConfig> forTask = self.pushConfigs[request.taskId] ?: {};
            configs = forTask.toArray().clone();
        }
        return {configs, nextPageToken: ""};
    }

    # Handles deleteTaskPushNotificationConfig. Idempotent per [specification section 3.1.10](https://a2a-protocol.org/latest/specification/#3110-delete-push-notification-config):
    # deleting an unknown config is not an error -- and, for the same
    # [section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping) reasoning as `handleListTaskPushNotificationConfigs`,
    # neither is deleting on a task that exists but is not visible to
    # `owner`; both are a silent no-op, never distinguished from each other.
    #
    # + request - The parent task id and the config's own id
    # + context - Who is calling, as the listener established it
    # + return - Nil; always succeeds
    public isolated function handleDeleteTaskPushNotificationConfig(Context context,
            DeleteTaskPushNotificationConfigRequest request) returns Error? {
        string? owner = check self.resolveOwner(context);
        Task? task = check self.store.get(request.taskId, owner);
        if task is () {
            return;
        }
        lock {
            map<TaskPushNotificationConfig>? forTask = self.pushConfigs[request.taskId];
            if forTask is map<TaskPushNotificationConfig> {
                _ = forTask.removeIfHasKey(request.id);
            }
        }
    }

    # Handles getExtendedAgentCard: the richer card configured as
    # `DefaultHandlerConfiguration.extendedAgentCard`. The listener derives the
    # served capabilities and interfaces from it.
    #
    # + request - The (empty) request
    # + context - Who is calling; the listener has already authenticated them
    # + return - The extended card, or an `a2a:ExtendedAgentCardNotConfiguredError`
    #            if none was configured
    public isolated function handleGetExtendedAgentCard(Context context, GetExtendedAgentCardRequest request)
            returns AgentCard|Error {
        AgentCard? extended = self.extendedAgentCard;
        if extended is () {
            string msg = "no extended AgentCard is configured for this agent";
            return error ExtendedAgentCardNotConfiguredError(msg, message = msg, code = -32007);
        }
        return extended;
    }

    # Queues a stored update of a task for its webhooks. Called for every
    # update the store takes: by the task's `TaskUpdater`, while it still
    # holds its write lock, and by `handleCancelTask` for a task no driver is
    # running. Updates are queued in the order they were stored.
    #
    # One strand per task delivers them, oldest first, so a webhook never
    # receives a task's updates out of order, and the agent never waits on a
    # slow webhook. The strand stops once the queue is empty, and the next
    # update needs another. A strand cannot be started inside a `lock`, so the
    # caller starts it with `deliverUpdates` once it has left its own.
    #
    # + taskId - The task that changed
    # + task - The task as stored
    # + return - `true` if no strand is delivering this task's updates, so the
    #            caller must call `deliverUpdates`
    isolated function queueUpdate(string taskId, Task task) returns boolean {
        lock {
            Task[]? pending = self.pendingPushes[taskId];
            if pending is Task[] {
                pending.push(task.clone());
                return false;
            }
            self.pendingPushes[taskId] = [task.clone()];
            return true;
        }
    }

    # Starts the strand that delivers a task's queued updates.
    #
    # + taskId - The task whose updates to deliver
    isolated function deliverUpdates(string taskId) {
        future<()> _ = start self.deliverPushes(taskId);
    }

    # Delivers a task's queued updates in order until none are left.
    #
    # + taskId - The task whose updates to deliver
    private isolated function deliverPushes(string taskId) {
        while true {
            Task next;
            lock {
                Task[]? pending = self.pendingPushes[taskId];
                if pending is () || pending.length() == 0 {
                    _ = self.pendingPushes.removeIfHasKey(taskId);
                    return;
                }
                next = pending.shift().clone();
            }
            self.notifyPushConfigs(taskId, next);
        }
    }

    # Notifies every push-notification config registered for a task that it
    # changed. Called only by `deliverPushes`.
    #
    # Unconditional on the state reached -- not filtered to terminal states
    # -- matching every reference SDK read this session; a deliberate
    # choice, not an oversight. Unscoped by owner on purpose: dispatch fires
    # every config registered for the task regardless of which caller
    # registered it, the same way `a2a-java`'s dispatch read path is
    # separate from its owner-scoped one. The task itself already passed
    # its own owner check before this is ever called, so this is not a
    # visibility leak -- it is delivery, which was never owner-scoped to
    # begin with.
    #
    # + taskId - The task that changed
    # + task - Its state at the moment of this call
    isolated function notifyPushConfigs(string taskId, Task task) {
        map<TaskPushNotificationConfig> configs;
        lock {
            configs = (self.pushConfigs[taskId] ?: {}).clone();
        }
        foreach TaskPushNotificationConfig config in configs {
            Error? deliveryResult = self.pushSender->send(config, task);
            if deliveryResult is Error {
                // Fire-and-forget: a delivery failure must not fail the
                // operation that triggered it, so it is logged here rather
                // than propagated. The config's token and credentials are
                // never logged (specification section 13.4).
                log:printWarn("A2A push notification delivery failed", 'error = deliveryResult,
                        taskId = taskId, configId = config?.id ?: "", state = task.status.state);
            }
        }
    }
}

# Builds the `RequestContext` handed to `execute`, leaving out whichever of
# `tenant`, `owner` and `configuration` the request did not carry.
#
# + message - The message the client sent
# + tenant - The tenant the request was routed under, or `()`
# + owner - The caller's resolved owner scope, or `()`
# + configuration - The send configuration the client attached, or `()`
# + return - The context
isolated function requestContextOf(Message message, string? tenant, string? owner,
        SendMessageConfiguration? configuration) returns RequestContext {
    RequestContext context = {message};
    if tenant is string {
        context.tenant = tenant;
    }
    if owner is string {
        context.owner = owner;
    }
    if configuration is SendMessageConfiguration {
        context.configuration = configuration;
    }
    return context;
}

# Whether a driven task's result marks a stopping point for its
# broadcaster and its registry driver slot.
#
# A direct `Message` (the task was removed from the store entirely) and an
# `Error` (driveTask already best-effort transitioned the task to the
# terminal FAILED state) always are. A `Task` is one when its
# `status.state` is terminal or `TASK_STATE_INPUT_REQUIRED`:
# [specification section 11.7](https://a2a-protocol.org/latest/specification/#117-streaming)
# closes a stream once the task reaches "a terminal or interrupted state",
# and the reference SDKs (Python's `EventConsumer`, a2a-js's
# `ExecutionEventQueue`) both end it at INPUT_REQUIRED. The client's next
# message is a new turn with a new stream; the continuation's `acquire`
# builds the task a fresh broadcaster. `TASK_STATE_AUTH_REQUIRED` is the
# exception: [section 7.6.1](https://a2a-protocol.org/latest/specification/#761-in-task-authorization-agent-responsibilities)
# says the agent SHOULD keep the stream open while the client authorizes
# out of band, so that task keeps its broadcaster and only frees its driver
# slot for the continuation to reacquire.
#
# A direct `Message` result only stops the task when the task it replied to
# no longer exists: `driveTask`'s own doc comment ties that removal 1:1 to
# `isNewTask && !returnImmediately`, so `isNewTask` here is exactly that
# condition, not an approximation. A `Message` reply on a *continued* task
# leaves the task's own stored state untouched -- still whatever non-terminal
# state it was in -- so closing its broadcaster would end every live
# subscriber's stream for an event unrelated to the task itself reaching a
# terminal state, which specification 3.5.2 forbids ("closing one stream
# MUST NOT affect other active streams for the same task").
#
# + result - `driveTask`'s already-`wait`ed, panic-normalized result
# + isNewTask - Whether the task `result` answers for was freshly seeded for
#               this call, forwarded from the same `ResolvedSendTarget` `result`
#               came from
# + return - Whether the broadcaster should close (or end with an error)
#            and the registry should drop this task's driver-in-progress
#            bookkeeping
isolated function resultStopped(Task|Message|Error result, boolean isNewTask) returns boolean {
    if result is Task {
        return isTerminalState(result.status.state) || result.status.state == TASK_STATE_INPUT_REQUIRED;
    }
    if result is Message {
        return isNewTask;
    }
    return true;
}

// How long `handleCancelTask` waits for a send that has just taken a task's driver
// claim to register its updater: 200 tries, 10 milliseconds apart.
const int CANCEL_CLAIM_ATTEMPTS = 200;
const decimal CANCEL_CLAIM_RETRY_SECONDS = 0.01;

# The error for canceling a task that has already ended.
#
# + id - The task's id
# + state - The terminal state it is in
# + return - The error
isolated function notCancelable(string id, TaskState state) returns TaskNotCancelableError {
    string msg = string `task ${id} is in terminal state ${state} and cannot be canceled`;
    return error TaskNotCancelableError(msg, message = msg, code = -32002);
}

# Builds a TaskNotFoundError for an unknown task id.
#
# + id - The id that was not found
# + return - The typed error
isolated function taskNotFound(string id) returns TaskNotFoundError {
    string msg = string `no task with id ${id}`;
    return error TaskNotFoundError(msg, message = msg, code = -32001);
}

# Builds a TaskNotFoundError for an unknown push-notification config.
#
# The error taxonomy has no dedicated "config not found" type -- this is a
# task-scoped resource, same as the task itself, so TaskNotFoundError is the
# closest honest fit; the message says specifically what wasn't found.
#
# + taskId - The parent task id
# + id - The config id that was not found
# + return - The typed error
isolated function taskPushNotificationConfigNotFound(string taskId, string id) returns TaskNotFoundError {
    string msg = string `no push notification config with id ${id} for task ${taskId}`;
    return error TaskNotFoundError(msg, message = msg, code = -32001);
}
