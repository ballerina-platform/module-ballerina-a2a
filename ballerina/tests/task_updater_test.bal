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

import ballerina/lang.runtime;
import ballerina/test;

final Gate artifactGate = new;

// Adds an artifact, then waits to be released before completing.
isolated class ArtifactThenWaitAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.working();
        check updater.addArtifact([{text: "partial"}]);
        artifactGate.advanceTo(1);
        artifactGate.awaitStep(2);
        check updater.complete();
        return;
    }
}

// An artifact a subscriber has been told about must be in the stored task too,
// while the agent is still working.
@test:Config {}
function testAnAddedArtifactIsStoredBeforeTheTaskEnds() returns error? {
    DefaultHandler handler = new (new ArtifactThenWaitAgent());
    Context context = {headers: {}};

    Task|Message|Error sent = handler.handleSendMessage(context,
            {message: {messageId: "artifact-1", role: ROLE_USER, parts: [{text: "go"}]}, configuration: {returnImmediately: true}});
    if sent !is Task {
        test:assertFail("expected the task back immediately");
    }
    artifactGate.awaitStep(1);
    Task working = check handler.handleGetTask(context, {id: sent.id});
    test:assertEquals(working.status.state, TASK_STATE_WORKING);
    string[] texts = from Artifact artifact in working.artifacts ?: [] select artifact.parts[0]?.text ?: "";
    test:assertEquals(texts, ["partial"], "getTask must show the artifact the stream already announced");
    artifactGate.advanceTo(2);
}

final Gate cancelOrderGate = new;

// Works, adds an artifact when released, then tries to complete.
isolated class ArtifactDuringCancelAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.working();
        cancelOrderGate.advanceTo(1);
        cancelOrderGate.awaitStep(2);
        check updater.addArtifact([{text: "kept"}]);
        cancelOrderGate.advanceTo(3);
        cancelOrderGate.awaitStep(4);
        check updater.complete();
        return;
    }
}

// A cancel that read the task before the agent stored an artifact must not
// write that older copy back: the canceled task keeps the artifact.
@test:Config {}
function testACancelDoesNotDropAnUpdateStoredAfterItsRead() returns error? {
    HoldingTaskStore store = new;
    DefaultHandler handler = new (new ArtifactDuringCancelAgent(), taskStore = store);
    Context context = {headers: {}};

    Task|Message|Error sent = handler.handleSendMessage(context,
            {message: {messageId: "cancel-order-1", role: ROLE_USER, parts: [{text: "go"}]}, configuration: {returnImmediately: true}});
    if sent !is Task {
        test:assertFail("expected the task back immediately");
    }
    cancelOrderGate.awaitStep(1);
    store.arm();
    future<Task|Error> cancel = start handler.handleCancelTask(context, {id: sent.id});
    store.awaitHeld();
    cancelOrderGate.advanceTo(2);
    cancelOrderGate.awaitStep(3);
    store.release();
    Task canceled = check wait cancel;
    cancelOrderGate.advanceTo(4);

    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);
    Task stored = <Task>check store.get(sent.id, ());
    test:assertEquals(stored.status.state, TASK_STATE_CANCELED);
    string[] texts = from Artifact artifact in stored.artifacts ?: [] select artifact.parts[0]?.text ?: "";
    test:assertEquals(texts, ["kept"], "the cancel must build on the artifact the agent stored after the cancel's read");
}

// Records what each push delivery carried, in delivery order, and holds the
// first delivery a while so later updates queue up behind it.
isolated client class RecordingPushSender {
    *PushNotificationSender;

    private string[] delivered = [];

    isolated remote function send(TaskPushNotificationConfig config, Task task) returns Error? {
        boolean first;
        lock {
            first = self.delivered.length() == 0;
        }
        if first {
            runtime:sleep(0.3);
        }
        lock {
            self.delivered.push(string `${task.status.state}:${(task.artifacts ?: []).length()}`);
        }
    }

    isolated function awaitDeliveries(int count) returns string[] {
        foreach int _ in 0 ..< 250 {
            lock {
                if self.delivered.length() >= count {
                    return self.delivered.clone();
                }
            }
            runtime:sleep(0.02);
        }
        lock {
            return self.delivered.clone();
        }
    }
}

// Works, adds an artifact, completes.
isolated class ThreeUpdatesAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.working();
        check updater.addArtifact([{text: "result"}]);
        check updater.complete();
        return;
    }
}

// A webhook hears of every update as it is stored, not only the final state,
// and in the order the updates were stored even when a delivery is slow.
@test:Config {}
function testAWebhookHearsEveryUpdateInOrder() returns error? {
    RecordingPushSender sender = new;
    DefaultHandler handler = new (new ThreeUpdatesAgent(), pushSender = sender);
    Context context = {headers: {}};

    Task|Message|Error sent = handler.handleSendMessage(context, {
        message: {messageId: "push-order-1", role: ROLE_USER, parts: [{text: "go"}]},
        configuration: {taskPushNotificationConfig: {url: "https://client.example.com/hook"}}
    });
    test:assertTrue(sent is Task);
    test:assertEquals(sender.awaitDeliveries(3),
            ["TASK_STATE_WORKING:0", "TASK_STATE_WORKING:1", "TASK_STATE_COMPLETED:1"]);
}

final Gate pushCancelGate = new;

// Works, waits to be released, then tries to add an artifact.
isolated class CanceledWhileWorkingAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.working();
        pushCancelGate.advanceTo(1);
        pushCancelGate.awaitStep(2);
        check updater.addArtifact([{text: "too late"}]);
        return;
    }
}

// A cancel reaches the webhook once, after the update before it, and the
// agent's refused write after it adds nothing.
@test:Config {}
function testAWebhookHearsACancelOnceAndInOrder() returns error? {
    RecordingPushSender sender = new;
    DefaultHandler handler = new (new CanceledWhileWorkingAgent(), pushSender = sender);
    Context context = {headers: {}};

    Task|Message|Error sent = handler.handleSendMessage(context, {
        message: {messageId: "push-cancel-1", role: ROLE_USER, parts: [{text: "go"}]},
        configuration: {returnImmediately: true, taskPushNotificationConfig: {url: "https://client.example.com/hook"}}
    });
    if sent !is Task {
        test:assertFail("expected the task back immediately");
    }
    pushCancelGate.awaitStep(1);
    Task canceled = check handler.handleCancelTask(context, {id: sent.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);
    pushCancelGate.advanceTo(2);

    test:assertEquals(sender.awaitDeliveries(2), ["TASK_STATE_WORKING:0", "TASK_STATE_CANCELED:0"]);
    runtime:sleep(0.5);
    test:assertEquals(sender.awaitDeliveries(3), ["TASK_STATE_WORKING:0", "TASK_STATE_CANCELED:0"],
            "nothing after the cancel, and the cancel only once");
}
