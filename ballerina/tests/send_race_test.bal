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

// A store that, once armed, holds the next `get` after reading its snapshot,
// so the caller goes on with that snapshot after other writes have landed.
isolated class HoldingTaskStore {
    *TaskStore;

    private final InMemoryTaskStore inner = new;
    private boolean armed = false;
    private final Gate gate = new;

    isolated function arm() {
        lock {
            self.armed = true;
        }
    }

    isolated function awaitHeld() {
        self.gate.awaitStep(1);
    }

    isolated function release() {
        self.gate.advanceTo(2);
    }

    public isolated function put(Task task, string? owner) returns Error? => self.inner.put(task, owner);

    public isolated function get(string id, string? owner) returns Task?|Error {
        Task?|Error snapshot = self.inner.get(id, owner);
        boolean hold = false;
        lock {
            if self.armed {
                self.armed = false;
                hold = true;
            }
        }
        if hold {
            self.gate.advanceTo(1);
            self.gate.awaitStep(2);
        }
        return snapshot;
    }

    public isolated function list(ListTasksRequest filter, string? owner) returns ListTasksResponse|Error =>
        self.inner.list(filter, owner);

    public isolated function remove(string id, string? owner) returns Error? => self.inner.remove(id, owner);
}

// Records each turn's text as an artifact and asks for more input.
isolated class TurnRecordingAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        string text = context.message.parts[0]?.text ?: "";
        check updater.addArtifact([{text}]);
        check updater.requireInput({messageId: "ask-" + text, role: ROLE_AGENT, parts: [{text: "more?"}]});
        return;
    }
}

function turn(string messageId, string? taskId = ()) returns SendMessageRequest {
    Message message = {messageId, role: ROLE_USER, parts: [{text: messageId}]};
    if taskId is string {
        message.taskId = taskId;
    }
    return {message};
}

// A continuation that read the task before another turn finished must not
// write that stale copy over the turn's history and artifacts.
@test:Config {}
function testAContinuationDoesNotOverwriteATurnThatFinishedFirst() returns error? {
    HoldingTaskStore store = new;
    DefaultHandler handler = new (new TurnRecordingAgent(), taskStore = store);
    Context context = {headers: {}};

    Task first = <Task>check handler.handleSendMessage(context, turn("first"));
    test:assertEquals(first.status.state, TASK_STATE_INPUT_REQUIRED);

    store.arm();
    future<Task|Message|Error> late = start handler.handleSendMessage(context, turn("b", first.id));
    store.awaitHeld();
    Task a = <Task>check handler.handleSendMessage(context, turn("a", first.id));
    test:assertEquals(a.status.state, TASK_STATE_INPUT_REQUIRED);
    store.release();
    Task b = <Task>check wait late;

    Task stored = <Task>check store.get(first.id, ());
    string[] artifacts = from Artifact artifact in stored.artifacts ?: [] select artifact.parts[0]?.text ?: "";
    test:assertEquals(artifacts, ["first", "a", "b"], "the late turn must build on the turn that finished first");
    string[] userMessages = from Message m in stored.history ?: [] where m.role == ROLE_USER select m.messageId;
    test:assertEquals(userMessages, ["first", "a", "b"]);
    test:assertEquals(b.status.state, TASK_STATE_INPUT_REQUIRED);
}

final Gate cancelRaceGate = new;

// Starts working, waits to be released, then tries to keep going.
isolated class CancelRaceAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.working();
        cancelRaceGate.advanceTo(1);
        cancelRaceGate.awaitStep(2);
        check updater.addArtifact([{text: "too late"}]);
        check updater.complete();
        return;
    }
}

// A cancel that lands while the agent runs is a success for the canceller; the
// caller blocked on the send gets the canceled task, not the agent's failure.
@test:Config {}
function testABlockingSendCanceledMidwayReturnsTheCanceledTask() returns error? {
    DefaultHandler handler = new (new CancelRaceAgent());
    Context context = {headers: {}};

    future<Task|Message|Error> sent = start handler.handleSendMessage(context, turn("cancel-race"));
    cancelRaceGate.awaitStep(1);
    Task[] listed = (check handler.handleListTasks(context, {})).tasks;
    test:assertEquals(listed.length(), 1);
    Task canceled = check handler.handleCancelTask(context, {id: listed[0].id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);
    cancelRaceGate.advanceTo(2);

    Task|Message|Error result = wait sent;
    if result is Error {
        test:assertFail("the blocked send must get the canceled task, got: " + result.message());
    }
    if result is Task {
        test:assertEquals(result.status.state, TASK_STATE_CANCELED);
    } else {
        test:assertFail("the blocked send must get the canceled task, got a message");
    }
}
