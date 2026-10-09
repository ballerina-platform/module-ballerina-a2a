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

// The server's strongest single check: this library's own Client driving
// this library's own Listener, in one process. If the two halves disagree on
// any part of the wire, this fails.
//
// One listener for the whole suite (a port cannot host two), started in
// @test:BeforeSuite and stopped in @test:AfterSuite.

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;
import ballerina/uuid;

const int SERVER_TEST_PORT = 19234;
final string serverUrl = string `http://localhost:${SERVER_TEST_PORT}`;

final DefaultHandler echoHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    // Placeholders: the listener derives both from what it serves.
    capabilities: {},
    supportedInterfaces: []
});

listener HttpListener echoListener = new (SERVER_TEST_PORT, echoHandler);

// A second listener, on its own port, configured with an extended card --
// separate from echoListener so that one's own extendedAgentCard:false
// round trip (the common case: no extended card configured) stays
// unambiguous. Both listeners are attached to instances of the same
// EchoAgent; only the configuration differs.
const int EXTENDED_CARD_TEST_PORT = 19235;
final string extendedCardServerUrl = string `http://localhost:${EXTENDED_CARD_TEST_PORT}`;

final DefaultHandler extendedCardHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
},
    extendedAgentCard = {
    name: "Echo Agent (extended)",
    description: "Echoes its input -- extended card reveals an internal-only skill",
    version: "1.0.0",
    skills: [
        {id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]},
        {id: "debug", name: "Debug", description: "Internal-only diagnostics", tags: ["internal"]}
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
}
);

listener HttpListener extendedCardListener = new (EXTENDED_CARD_TEST_PORT, extendedCardHandler,
    auth = [{jwtValidatorConfig: authTestJwtValidator}]
);

// A minimal agent: echoes the inbound text back as a completed task's
// artifact, with a handful of trigger texts for the checkpoints live
// streaming and error handling need to test deterministically:
// - a message with a file part (Part.raw): echoes the bytes it received back
//   as text, "raw: <bytes>".
// - "ping": a direct Message reply, no task at all.
// - "ask": pauses at TASK_STATE_INPUT_REQUIRED, for continuation tests.
// - "boom": onMessage returns an a2a:Error directly.
// - "panic": onMessage panics, for driveTask's own `trap` to catch.
// - "paced:<key>": blocks at each of three checkpoints on the Gate
//   registered under <key> (see testutil.bal's registerGate), for
//   deterministic live-streaming and multi-subscriber fan-out tests.
isolated service class EchoAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        string text = "";
        foreach Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }
        // A message carrying file bytes: echo them back as text, so a test can
        // see exactly which bytes onMessage received.
        foreach Part part in context.message.parts {
            byte[]? raw = part?.raw;
            if raw is byte[] {
                string|error asText = string:fromBytes(raw);
                check updater->working();
                check updater->addArtifact([{text: string `raw: ${asText is string ? asText : "not utf-8"}`}]);
                check updater->complete();
                return;
            }
        }
        if text == "ping" {
            return {messageId: "reply-1", role: ROLE_AGENT, parts: [{text: "pong"}]};
        }
        if text == "ask" {
            check updater->working();
            check updater->requireInput({
                messageId: "ask-1",
                role: ROLE_AGENT,
                parts: [{text: "need more information"}]
            });
            return;
        }
        if text == "boom" {
            string msg = "agent exploded";
            return error InternalError(msg, message = msg);
        }
        if text == "panic" {
            panic error("agent panicked");
        }
        if text.startsWith("paced:") {
            Gate? gate = gateFor(text.substring(6));
            if gate is Gate {
                gate.awaitStep(1);
                check updater->working();
                gate.awaitStep(2);
                check updater->addArtifact([{text: "paced artifact"}]);
                gate.awaitStep(3);
                check updater->complete();
            }
            return;
        }
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}]);
        check updater->complete();
        return;
    }
}

@test:BeforeSuite
function startEchoServer() returns error? {
    check echoListener.attach(new EchoAgent());
    check extendedCardListener.attach(new EchoAgent());
}

isolated function echoClient() returns HttpClient|error => new (serverUrl);

@test:Config {}
function testServerServesAgentCardForClientDiscovery() returns error? {
    AgentCard card = check resolveAgentCard(serverUrl);
    test:assertEquals(card.name, "Echo Agent");
    test:assertEquals(card.supportedInterfaces.length(), 1);
    test:assertEquals(card.supportedInterfaces[0].protocolBinding, "HTTP+JSON",
            "the served card must declare the HTTP+JSON interface");
    test:assertEquals(card.supportedInterfaces[0].protocolVersion, "1.0");
    test:assertTrue(card.capabilities.streaming,
            "streaming is wired, so the derived card must claim it");
}

@test:Config {}
function testServerServesAgentCardWithCachingHeaders() returns error? {
    // Specification 8.6.1: Agent Card endpoints SHOULD carry Cache-Control
    // and ETag response headers.
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/.well-known/agent-card.json");
    string cacheControl = check resp.getHeader("Cache-Control");
    test:assertTrue(cacheControl.includes("max-age="), "the Agent Card response must declare a max-age");
    string etag = check resp.getHeader("ETag");
    test:assertTrue(etag.length() > 0, "the Agent Card response must carry an ETag");
}

@test:Config {}
function testServerResponsesUseA2AJsonContentType() returns error? {
    // Specification 11.1: application/a2a+json SHOULD be used for
    // requests and responses. Checked on both a plain JSON response and
    // an error response, since they're built through different code
    // paths (jsonResponse/cardHttpResponse vs. toRestErrorResponse).
    http:Client raw = check new (serverUrl);
    http:Response cardResp = check raw->get("/.well-known/agent-card.json");
    test:assertEquals(cardResp.getContentType(), "application/a2a+json");

    http:Response errorResp = check raw->get("/tasks/does-not-exist", {"A2A-Version": "1.0"});
    test:assertEquals(errorResp.getContentType(), "application/a2a+json");
}

// Finding 26: a patch-qualified A2A-Version used to be an exact-string
// match against "1.0", so "1.0.5" was refused. Specification 3.6:
// "Agents MUST process requests using the semantics of the requested
// A2A-Version (matching Major.Minor)", and separately, patch numbers "do
// not affect protocol compatibility". Confirmed live against real Python
// (a2a-sdk) and Java (a2a-java) servers, both of which already accept it.
@test:Config {}
function testServerAcceptsAPatchQualifiedVersion() returns error? {
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/tasks/does-not-exist", {"A2A-Version": "1.0.5"});
    // 404 (task not found) proves the request was actually processed as
    // v1.0, not refused as an unsupported version.
    test:assertEquals(resp.statusCode, 404);
    test:assertEquals(check reasonOf(resp), "TASK_NOT_FOUND");
}

// A different Major.Minor must still be refused -- this is not "accept any
// 1.x", which is where the two reference SDKs are laxer than the spec text
// itself (see checkVersion's own doc comment).
@test:Config {}
function testServerStillRejectsADifferentMinorVersion() returns error? {
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/tasks/does-not-exist", {"A2A-Version": "1.1"});
    test:assertEquals(resp.statusCode, 400);
    test:assertEquals(check reasonOf(resp), "VERSION_NOT_SUPPORTED");
}

// ---- inbound request bodies ----------------------------------------------

// File bytes go over the wire as base64 in Part.raw. The server must decode
// them, so onMessage receives the bytes, not a string that fails conversion
// to byte[] (which used to be a 500 on every file part).
@test:Config {}
function testServerRoundTripFileBytesReachTheAgentAsBytes() returns error? {
    // Through the typed client, which base64-encodes on the way out.
    Client c = check echoClient();
    Task viaClient = <Task>check c->sendMessage({
        message: {messageId: "raw-1", role: ROLE_USER, parts: [{raw: "tck".toBytes(), mediaType: "text/plain"}]}
    });
    test:assertEquals(firstArtifactText(viaClient), "raw: tck");

    // And the literal wire form, "dGNr" being base64 for "tck".
    http:Client raw = check new (serverUrl);
    json body = {"message": {"messageId": "raw-2", "role": "ROLE_USER",
        "parts": [{"raw": "dGNr", "mediaType": "application/x-unsupported-tck-type"}]}};
    http:Response resp = check raw->post("/message:send", body,
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(resp.statusCode, 200);
    json payload = check resp.getJsonPayload();
    map<json> envelope = check payload.ensureType();
    // The wire form's history now legitimately holds "raw-2"'s own message
    // (seeded on creation, same as any fresh task's), whose Part.raw is
    // base64 on the wire -- decodeRawBytesFromWire is what a real client
    // runs before typing a response for exactly this reason; a bare
    // cloneWithType, as a shortcut, is not a substitute for it.
    json decoded = check decodeRawBytesFromWire(envelope["task"]);
    Task viaWire = check decoded.cloneWithType(Task);
    test:assertEquals(firstArtifactText(viaWire), "raw: tck");
}

isolated function firstArtifactText(Task task) returns string? {
    Artifact[] artifacts = task.artifacts ?: [];
    if artifacts.length() == 0 {
        return;
    }
    return artifacts[0].parts[0]?.text;
}

// A request the caller got wrong is a 400 with reason INVALID_REQUEST, never a
// 500: a body that is not JSON, one that does not match the request type, and
// one carrying a malformed part, on both send operations.
@test:Config {}
function testServerRejectsMalformedRequestBodiesWith400() returns error? {
    http:Client raw = check new (serverUrl);
    map<string> headers = {"A2A-Version": "1.0", "Content-Type": "application/json"};
    string[] badBodies = [
        "{not json",
        "{\"nope\": 1}",
        "{\"message\": {\"messageId\": \"m\", \"role\": \"ROLE_USER\", \"parts\": [{\"raw\": \"@@not base64@@\"}]}}",
        "{\"message\": {\"messageId\": \"m\", \"role\": \"ROLE_USER\", \"parts\": [{\"text\": \"a\", \"url\": \"http://x\"}]}}",
        "{\"message\": {\"messageId\": \"m\", \"role\": \"ROLE_USER\", \"parts\": []}}"
    ];
    foreach string path in ["/message:send", "/message:stream"] {
        foreach string body in badBodies {
            http:Response resp = check raw->post(path, body, headers);
            test:assertEquals(resp.statusCode, 400, string `${path} with ${body}`);
            json payload = check resp.getJsonPayload();
            map<json> envelope = check payload.ensureType();
            map<json> err = check envelope["error"].ensureType();
            json[] details = check err["details"].ensureType();
            map<json> info = check details[0].ensureType();
            test:assertEquals(info["reason"], "INVALID_REQUEST", string `${path} with ${body}`);
        }
    }

    // The push-config body too: not an object, and no url.
    Task created = <Task>check (check echoClient())->sendMessage({
        message: {messageId: "m-bad-cfg", role: ROLE_USER, parts: [{text: "x"}]}
    });
    foreach string body in ["[1, 2]", "{\"token\": \"t\"}"] {
        http:Response resp = check raw->post(string `/tasks/${created.id}/pushNotificationConfigs`, body, headers);
        test:assertEquals(resp.statusCode, 400, string `push config with ${body}`);
    }
}

@test:Config {}
function testServerRoundTripSendMessageReturnsTask() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(reply is Task, "a non-ping message must come back as a completed task");
    Task task = <Task>reply;
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    Artifact[] artifacts = task.artifacts ?: [];
    test:assertEquals(artifacts.length(), 1);
    test:assertEquals(artifacts[0].parts[0]?.text, "echo: hello");
}

@test:Config {}
function testServerRoundTripDirectMessageReply() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]}
    });
    test:assertTrue(reply is Message, "\"ping\" must come back as a direct Message, not a Task");
    test:assertEquals((<Message>reply).parts[0]?.text, "pong");
}

@test:Config {}
function testServerRoundTripContinueUnknownTaskIsTyped() returns error? {
    // Per specification 3.4.2, a client cannot name a task into existence --
    // message.taskId naming an id the server has never seen is
    // TaskNotFoundError, not "create a new task with this id".
    Client c = check echoClient();
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, taskId: "does-not-exist", parts: [{text: "hello"}]}
    });
    test:assertTrue(result is TaskNotFoundError,
            "an unrecognized message.taskId must be TaskNotFoundError");
}

@test:Config {}
function testServerRoundTripContinueTerminalTaskIsRejected() returns error? {
    // The echo agent always finishes synchronously, so by the time this
    // test's own continuation attempt reaches the server, the task it
    // names is already TASK_STATE_COMPLETED -- specification 3.1.1
    // forbids sending it a further message.
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    Task|Message|Error result = c->sendMessage({
        message: {
            messageId: "m2",
            role: ROLE_USER,
            taskId: created.id,
            contextId: created.contextId,
            parts: [{text: "again"}]
        }
    });
    test:assertTrue(result is UnsupportedOperationError,
            "a message continuing an already-terminal task must be UnsupportedOperationError");
}

@test:Config {}
function testServerRoundTripContinueMismatchedContextIdIsRejected() returns error? {
    // Per specification 3.4.3, a message whose contextId disagrees with
    // the task it names by taskId must be rejected outright, not silently
    // reconciled either way.
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    Task|Message|Error result = c->sendMessage({
        message: {
            messageId: "m2",
            role: ROLE_USER,
            taskId: created.id,
            contextId: "a-different-context-entirely",
            parts: [{text: "again"}]
        }
    });
    test:assertTrue(result is InternalError && result.detail()?.code == -32600,
            "a message.contextId that disagrees with the continued task's own is the caller's mistake: "
            + "rejected as an invalid request (a 400), not as a bad agent response");
}

@test:Config {}
function testServerRoundTripReturnImmediatelyHandsBackBeforeCompletion() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]},
        configuration: {returnImmediately: true}
    });
    test:assertTrue(reply is Task, "returnImmediately must still hand back the task, not wait for a reply");
    Task submitted = <Task>reply;
    test:assertEquals(submitted.status.state, TASK_STATE_SUBMITTED,
            "the caller must see the task before the (fast, detached) echo agent has driven it further");

    // driveTask keeps running detached; poll until it lands where a
    // blocking sendMessage would have returned it synchronously.
    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_COMPLETED);
    Artifact[] artifacts = finished.artifacts ?: [];
    test:assertEquals(artifacts.length(), 1);
    test:assertEquals(artifacts[0].parts[0]?.text, "echo: hello");
}

@test:Config {}
function testServerRoundTripReturnImmediatelyCompletesDirectMessageReply() returns error? {
    // Per this server's resolution of a gap the specification leaves
    // open: once the caller already holds a task id from the
    // immediate-return snapshot, a direct Message reply can no longer
    // make the task disappear as if it never existed -- it completes the
    // task with the Message as its final status.message instead.
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]},
        configuration: {returnImmediately: true}
    });
    test:assertTrue(reply is Task, "returnImmediately always hands back a Task, even for a direct-reply agent");
    Task submitted = <Task>reply;

    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_COMPLETED);
    Message? statusMessage = finished.status?.message;
    test:assertTrue(statusMessage is Message, "the direct Message reply must land as status.message");
    test:assertEquals((<Message>statusMessage).parts[0]?.text, "pong");
}

# Polls getTask until the task reaches a terminal state, or fails the test
# after a generous bound -- the echo agent's own work is near-instant, so a
# real hang here means driveTask never ran at all, not a slow agent.
#
# + c - The client to poll through
# + taskId - The task to poll
# + return - The task, once terminal
isolated function pollUntilTerminal(Client c, string taskId) returns Task|error {
    foreach int _ in 0 ..< 100 {
        Task task = check c->getTask({id: taskId});
        if isTerminalState(task.status.state) {
            return task;
        }
        runtime:sleep(0.05);
    }
    return error("task did not reach a terminal state in time");
}

@test:Config {}
function testServerRoundTripContinuePausedTaskSucceeds() returns error? {
    // The happy path: "ask" pauses at TASK_STATE_INPUT_REQUIRED with no
    // driver left running (onMessage already returned), so continuing it
    // is a clean, non-racing acquire.
    Client c = check echoClient();
    Task paused = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ask"}]}
    });
    test:assertEquals(paused.status.state, TASK_STATE_INPUT_REQUIRED);

    Task|Message reply = check c->sendMessage({
        message: {
            messageId: "m2",
            role: ROLE_USER,
            taskId: paused.id,
            contextId: paused.contextId,
            parts: [{text: "here is more information"}]
        }
    });
    test:assertTrue(reply is Task, "continuing the paused task must drive it, not reply directly");
    Task completed = <Task>reply;
    test:assertEquals(completed.id, paused.id, "continuation must drive the SAME task, not mint a new one");
    test:assertEquals(completed.status.state, TASK_STATE_COMPLETED,
            "the continuation text isn't a trigger, so the echo agent completes it normally");

    // The fresh task's own triggering message ("m1") is now seeded into
    // history too, matching the reference a2a-sdk's own
    // new_task_from_user_message default -- so a continuation's history
    // holds both, not just the continuation's own message.
    Message[] history = completed?.history ?: [];
    test:assertEquals(history.length(), 2, "the triggering message and the continuation message must both be in history");
    test:assertEquals(history[0].messageId, "m1");
    test:assertEquals(history[1].messageId, "m2");
}

@test:Config {}
function testServerRoundTripAgentErrorFailsTask() returns error? {
    Client c = check echoClient();
    Task submitted = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "boom"}]},
        configuration: {returnImmediately: true}
    });
    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_FAILED,
            "an agent-returned Error must transition the task to FAILED");
    Message? statusMessage = finished.status?.message;
    test:assertTrue(statusMessage is Message, "the failure must be recorded as the task's status message");
    test:assertEquals((<Message>statusMessage).parts[0]?.text, "agent exploded");
}

@test:Config {}
function testServerRoundTripAgentPanicFailsTask() returns error? {
    Client c = check echoClient();
    Task submitted = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "panic"}]},
        configuration: {returnImmediately: true}
    });
    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_FAILED,
            "a panic in agent code must be trapped and transition the task to FAILED, not crash the server");
}

@test:Config {}
function testServerRoundTripGetTask() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "remember me"}]}
    });
    Task fetched = check c->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "getTask must return the task sendMessage created");
    test:assertEquals(fetched.status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testServerRoundTripGetUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    Task|Error result = c->getTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

@test:Config {}
function testServerRoundTripCancelTask() returns error? {
    Client c = check echoClient();
    // The echo agent completes synchronously, so the task is already terminal;
    // canceling it must be refused as TaskNotCancelableError.
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "done fast"}]}
    });
    Task|Error canceled = c->cancelTask({id: created.id});
    test:assertTrue(canceled is TaskNotCancelableError,
            "a completed task cannot be canceled; the server must say so");
}

@test:Config {}
function testServerRoundTripErrorStatusCodesMatchSpecTable() returns error? {
    // The typed Client decodes purely by ErrorInfo.reason, so it cannot
    // catch a wrong HTTP status on its own -- these go around it with a
    // raw http:Client to check the wire status directly, per
    // specification section 5.4's error-code mapping table.
    map<string> headers = {"A2A-Version": "1.0"};
    http:Client raw = check new (serverUrl);

    Task created = <Task>check (check echoClient())->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "already done"}]}
    });
    http:Response cancelResponse = check raw->post(string `/tasks/${created.id}:cancel`, (), headers);
    test:assertEquals(cancelResponse.statusCode, http:STATUS_BAD_REQUEST,
            "TaskNotCancelableError must be 400 Bad Request per the spec's error table");

    // echoListener never configures an extended card, so
    // capabilities.extendedAgentCard reads false and this is
    // UnsupportedOperationError (see getExtendedAgentCard's own doc) --
    // still 400, not 404, either way.
    http:Response cardResponse = check raw->get("/extendedAgentCard", headers);
    test:assertEquals(cardResponse.statusCode, http:STATUS_BAD_REQUEST,
            "an unconfigured extended card's rejection must be 400, not 404 -- it's the server's own " +
            "configuration, not a missing resource the request named");
}

@test:Config {}
function testServerRoundTripSendStreamingMessage() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "stream me"}]}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "the first event must be the newly created task");
    test:assertEquals((<Task>first).status.state, TASK_STATE_SUBMITTED);
    string taskId = (<Task>first).id;

    StreamResponse second = check expectStreamValue(events);
    test:assertTrue(second is TaskStatusUpdateEvent, "the second event must be the WORKING status");
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);
    test:assertEquals((<TaskStatusUpdateEvent>second).taskId, taskId);

    StreamResponse third = check expectStreamValue(events);
    test:assertTrue(third is TaskArtifactUpdateEvent, "the third event must be the echoed artifact");
    test:assertEquals((<TaskArtifactUpdateEvent>third).artifact.parts[0]?.text, "echo: stream me");
    test:assertTrue((<TaskArtifactUpdateEvent>third).lastChunk,
            "a whole-artifact addArtifact call is its own last chunk");

    StreamResponse fourth = check expectStreamValue(events);
    test:assertTrue(fourth is TaskStatusUpdateEvent, "the fourth event must be the COMPLETED status");
    test:assertEquals((<TaskStatusUpdateEvent>fourth).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? fifth = events.next();
    test:assertTrue(fifth is (), "the stream must close after the terminal status");
}

@test:Config {}
function testServerRoundTripSendStreamingMessageDirectReply() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Message, "a direct reply must be the stream's one and only event");
    test:assertEquals((<Message>first).parts[0]?.text, "pong");

    record {| StreamResponse value; |}|error? second = events.next();
    test:assertTrue(second is (), "the stream must close immediately after the one Message event");
}

// Finding 22: configuration.historyLength was read by getTask and
// listTasks (via projectTask) but never by sendMessage/sendStreamingMessage
// -- confirmed live against a real Node client and TCK CORE-HIST-003.
// Specification 3.2.2 ("A value of zero is a request to not include any
// history"), 3.2.4 ("0: No history should be returned"), 3.1.3's MUST for
// getTask (the same guarantee this extends to send/stream).
@test:Config {}
function testServerRoundTripSendMessageHistoryLengthZeroOmitsHistory() returns error? {
    Client c = check echoClient();
    Task|Message result = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "echo hi"}]},
        configuration: {historyLength: 0}
    });
    test:assertTrue(result is Task);
    test:assertTrue((<Task>result)?.history is (),
            "historyLength: 0 must omit history from a blocking sendMessage response (section 3.2.4)");
}

@test:Config {}
function testServerRoundTripSendMessageReturnImmediatelyHistoryLengthZero() returns error? {
    Client c = check echoClient();
    // returnImmediately hands back the pre-created snapshot through a
    // separate return statement from the driven-synchronously case above --
    // a distinct code path, so it gets its own test rather than assuming
    // the same fix covers it.
    Task|Message result = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "echo hi"}]},
        configuration: {historyLength: 0, returnImmediately: true}
    });
    test:assertTrue(result is Task);
    test:assertTrue((<Task>result)?.history is (), "the returnImmediately snapshot must also respect historyLength");
}

@test:Config {}
function testServerRoundTripSendStreamingMessageHistoryLengthZeroOmitsHistoryFromSeed() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "stream me"}]},
        configuration: {historyLength: 0}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "the first event must be the newly created task");
    test:assertTrue((<Task>first)?.history is (),
            "the seed Task event sendStreamingMessage broadcasts live must also respect historyLength");

    // Drain the rest so this task's driver finishes cleanly before the
    // next test runs.
    StreamResponse second = check expectStreamValue(events);
    test:assertTrue(second is TaskStatusUpdateEvent && (<TaskStatusUpdateEvent>second).status.state == TASK_STATE_WORKING);
    StreamResponse third = check expectStreamValue(events);
    test:assertTrue(third is TaskArtifactUpdateEvent);
    StreamResponse fourth = check expectStreamValue(events);
    test:assertTrue(fourth is TaskStatusUpdateEvent
            && (<TaskStatusUpdateEvent>fourth).status.state == TASK_STATE_COMPLETED);
}

@test:Config {}
function testServerRoundTripSubscribeToTask() returns error? {
    // Per specification 3.1.6, a task already in a terminal state cannot
    // be subscribed to. The echo agent always finishes inside its own
    // sendMessage call, so by the time this test's own subscribeToTask
    // request reaches the server, the task it names is already
    // TASK_STATE_COMPLETED -- exactly the case this rejects.
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "subscribe me"}]}
    });

    stream<StreamResponse, error?>|Error result = c->subscribeToTask({id: created.id});
    test:assertTrue(result is UnsupportedOperationError,
            "subscribeToTask on an already-terminal task must be a2a:UnsupportedOperationError, " +
            "not a one-event snapshot");
}

@test:Config {}
function testServerRoundTripSubscribeToUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?>|Error result = c->subscribeToTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

@test:Config {}
function testServerRoundTripMultiSubscriberFanOut() returns error? {
    // The real proof of specification 3.5.2: two concurrent streams
    // following one in-flight task must see the same further events, in
    // the same order, deterministically -- not by runtime:sleep timing
    // luck. EchoAgent's "paced:<key>" trigger blocks at each of its three
    // checkpoints on the Gate registered under <key>, so this test decides
    // exactly when each event broadcasts.
    Client c = check echoClient();
    Gate gate = new;
    string key = "fanout-1";
    registerGate(key, gate);

    // sendStreamingMessage's own client call blocks until the server's
    // response begins, which here means until the agent's first
    // checkpoint releases -- so step 1 is opened concurrently, on its own
    // strand, rather than after the call returns.
    future<()> _ = start gate.advanceTo(1);
    stream<StreamResponse, error?> primary = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "paced:" + key}]}
    });

    StreamResponse primarySeed = check expectStreamValue(primary);
    test:assertTrue(primarySeed is Task, "the first event must be the lazily-emitted seed Task");
    string taskId = (<Task>primarySeed).id;
    StreamResponse primaryWorking = check expectStreamValue(primary);
    test:assertTrue(primaryWorking is TaskStatusUpdateEvent);
    test:assertEquals((<TaskStatusUpdateEvent>primaryWorking).status.state, TASK_STATE_WORKING);

    // A second subscriber attaches only now -- after the task already
    // exists and is WORKING, mid-drive -- and must still see every
    // further event the first subscriber does, identically and in the
    // same order.
    stream<StreamResponse, error?> secondary = check c->subscribeToTask({id: taskId});
    StreamResponse secondarySnapshot = check expectStreamValue(secondary);
    test:assertTrue(secondarySnapshot is Task, "a late subscriber's first event is the task's current snapshot");
    test:assertEquals((<Task>secondarySnapshot).status.state, TASK_STATE_WORKING);

    gate.advanceTo(2);
    StreamResponse primaryArtifact = check expectStreamValue(primary);
    StreamResponse secondaryArtifact = check expectStreamValue(secondary);
    test:assertTrue(primaryArtifact is TaskArtifactUpdateEvent);
    test:assertTrue(secondaryArtifact is TaskArtifactUpdateEvent);
    test:assertEquals((<TaskArtifactUpdateEvent>primaryArtifact).artifact.artifactId,
            (<TaskArtifactUpdateEvent>secondaryArtifact).artifact.artifactId,
            "both subscribers must see the identical artifact event");

    gate.advanceTo(3);
    StreamResponse primaryDone = check expectStreamValue(primary);
    StreamResponse secondaryDone = check expectStreamValue(secondary);
    test:assertTrue(primaryDone is TaskStatusUpdateEvent);
    test:assertTrue(secondaryDone is TaskStatusUpdateEvent);
    test:assertEquals((<TaskStatusUpdateEvent>primaryDone).status.state, TASK_STATE_COMPLETED);
    test:assertEquals((<TaskStatusUpdateEvent>secondaryDone).status.state, TASK_STATE_COMPLETED);

    // Both streams must end now: the task is terminal, so the broadcaster
    // closed -- closing one stream must not affect the other.
    record {| StreamResponse value; |}|error? primaryEnd = primary.next();
    record {| StreamResponse value; |}|error? secondaryEnd = secondary.next();
    test:assertTrue(primaryEnd is (), "the primary stream must close once the task completes");
    test:assertTrue(secondaryEnd is (), "the secondary stream must close once the task completes");
}

@test:Config {}
function testServerRoundTripConcurrentMessageToRunningTaskLeavesNoTrace() returns error? {
    // A second message naming a task that is already being driven must be
    // rejected -- and, unlike before this fix, without first writing its
    // text into the task's history or registering its inline push config.
    // Deterministic: the first message's "paced:<key>" trigger blocks it at
    // WORKING (checkpoint 1) on the gate below, so the rejection is raced
    // against a driver genuinely still running, not a runtime:sleep guess.
    Client c = check echoClient();
    Gate gate = new;
    string key = "concurrent-1";
    registerGate(key, gate);

    future<()> _ = start gate.advanceTo(1);
    stream<StreamResponse, error?> primary = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "paced:" + key}]}
    });
    StreamResponse seed = check expectStreamValue(primary);
    test:assertTrue(seed is Task);
    string taskId = (<Task>seed).id;
    string contextId = (<Task>seed).contextId ?: "";
    StreamResponse working = check expectStreamValue(primary);
    test:assertTrue(working is TaskStatusUpdateEvent
            && (<TaskStatusUpdateEvent>working).status.state == TASK_STATE_WORKING);

    // A caller-chosen id, so its absence can be checked directly by id
    // afterward -- getTaskPushNotificationConfig on an id that was never
    // registered is TaskNotFoundError, the plain, direct way to ask "did
    // this get registered", with no dependency on webhook delivery
    // actually reaching anywhere.
    Task|Message|Error rejected = c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, taskId, contextId, parts: [{text: "must not land"}]},
        configuration: {taskPushNotificationConfig: {url: "https://example.com/never-reached", id: "rejected-cfg"}}
    });
    test:assertTrue(rejected is UnsupportedOperationError,
            "a second concurrent message to a task already being driven must be rejected");

    // Read the store's state now, while m1 is still gated at WORKING and has
    // not yet run its own later transitions -- not after m1 finishes. m1's
    // own updater always overwrites the whole task record from its own
    // internal state on every transition (working/addArtifact/complete),
    // which would silently clobber a leaked m2 history entry right back out
    // regardless of whether the fix is in place, masking exactly the bug
    // this test exists to catch.
    Task midFlight = <Task>check c->getTask({id: taskId});
    Message[] historyDuring = midFlight?.history ?: [];
    foreach Message m in historyDuring {
        test:assertNotEquals(m.messageId, "m2", "the rejected message must never have reached the store");
    }
    test:assertEquals(historyDuring.length(), 1, "only m1's own seeded history entry -- nothing from the rejected m2");

    gate.advanceTo(2);
    gate.advanceTo(3);
    Task done = check pollUntilTerminal(c, taskId);
    test:assertEquals(done.status.state, TASK_STATE_COMPLETED, "m1 itself must still complete normally");

    TaskPushNotificationConfig|Error leaked = c->getTaskPushNotificationConfig({taskId, id: "rejected-cfg"});
    test:assertTrue(leaked is TaskNotFoundError,
            "the rejected message's inline push config must never have been registered");
}

@test:Config {}
function testServerRoundTripSubscribeRacingCompletionEndsCleanly() returns error? {
    // Between subscribeToTask's existence/terminal-state check and the tap
    // actually attaching, the task can finish -- its driver has by then
    // already closed and released the broadcaster that existed for it, so
    // registry.subscribe, finding none, creates a fresh one nothing will
    // ever push to. Specification 3.1.6 still requires the stream to open
    // with the task's current (now terminal) snapshot and then end; before
    // this fix, it opened but never ended (a leaked broadcaster, an idle
    // tap).
    //
    // Deterministic, not timing-based -- subscribeToTask's own two internal
    // store reads happen back to back with no yield point a real concurrent
    // write could land in between via wall-clock racing; a store that
    // answers WORKING the first time and COMPLETED every time after
    // reproduces the exact race window directly, whichever read lands
    // where. No driver ever ran here (registry starts with nothing for this
    // task id), matching the state a real one leaves behind after
    // completing and releasing. A direct unit test against DefaultHandler,
    // not a wire round trip -- same pattern as
    // testServedExtendedCardFailsWhenNoneConfigured above.
    TaskStore store = new BecomesTerminalAfterFirstGet("race-1");
    DefaultHandler handler = new (authTestCard, taskStore = store);

    stream<StreamResponse, Error?>|Error result = handler.subscribeToTask({id: "race-1"}, (), {idleTimeout: 300});
    if result is Error {
        test:assertFail(result.message());
    }
    stream<StreamResponse, Error?> events = result;

    record {| StreamResponse value; |}|Error? first = events.next();
    if first !is record {| StreamResponse value; |} {
        test:assertFail("subscribeToTask must return the task's current state as its first event");
    }
    StreamResponse snapshot = first.value;
    test:assertTrue(snapshot is Task);
    test:assertEquals((<Task>snapshot).status.state, TASK_STATE_COMPLETED,
            "the second internal read is what this test controls, and it always answers COMPLETED");

    record {| StreamResponse value; |}|Error? next = events.next();
    test:assertTrue(next is (), "the stream must end here -- specification 3.1.6's terminal-state MUST -- "
            + "not sit open on a broadcaster nothing will ever close");
}

# A `TaskStore` whose `get` answers `TASK_STATE_WORKING` the first time it is
# asked about one specific task id, and `TASK_STATE_COMPLETED` every time
# after -- for
# `testServerRoundTripSubscribeRacingCompletionEndsCleanly`, which needs
# `subscribeToTask`'s own two internal reads to see different states without
# racing a real concurrent write against them. `put`/`list`/`remove` are
# unused by that test and are simple, uninteresting stubs.
isolated class BecomesTerminalAfterFirstGet {
    *TaskStore;
    private final string targetId;
    private int getCount = 0;

    isolated function init(string targetId) {
        self.targetId = targetId;
    }

    public isolated function put(Task task, string? owner) returns Error? {
        return;
    }

    public isolated function get(string id, string? owner) returns Task?|Error {
        if id != self.targetId {
            return;
        }
        int count;
        lock {
            self.getCount += 1;
            count = self.getCount;
        }
        TaskState state = count == 1 ? TASK_STATE_WORKING : TASK_STATE_COMPLETED;
        return {id, contextId: "c1", status: {state, timestamp: "2026-01-01T00:00:00Z"}};
    }

    public isolated function list(ListTasksRequest filter, string? owner) returns ListTasksResponse|Error {
        return {tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0};
    }

    public isolated function remove(string id, string? owner) returns Error? {
        return;
    }
}

@test:Config {}
function testServerRoundTripCancelRacingCompletionIsNotCancelable() returns error? {
    // cancelTask deliberately does not hold registry.acquire (a live
    // subscriber must be able to race a cancel against a driver still
    // running), so it can lose that race: the driver reaches a different
    // terminal state first, and the store's own terminal-transition guard
    // refuses cancelTask's write. That must surface as
    // TaskNotCancelableError, the same as reading an already-terminal task
    // up front does -- not the store's own internal error verbatim.
    //
    // Deterministic, not timing-based, for the same reason as the subscribe
    // race above: cancelTask's own read, build, and put happen back to back
    // with nothing for a real concurrent write to land between via
    // wall-clock racing. This store answers WORKING to the first read (so
    // cancelTask proceeds past its own up-front terminal check) and refuses
    // every put with the same shape InMemoryTaskStore's terminal-transition
    // guard does -- then answers COMPLETED to the re-read that follows,
    // reproducing exactly what a driver that reached COMPLETED first, in
    // between, would leave behind.
    TaskStore store = new RefusesWriteAfterFirstGet("race-2");
    DefaultHandler handler = new (authTestCard, taskStore = store);

    Task|Error canceled = handler.cancelTask({id: "race-2"}, ());
    test:assertTrue(canceled is TaskNotCancelableError,
            "a cancel that loses the race to the task's own completion must be TaskNotCancelableError, not a bare 500");
}

# A `TaskStore` whose `get` answers `TASK_STATE_WORKING` the first time it is
# asked about one specific task id and `TASK_STATE_COMPLETED` every time
# after (same idea as `BecomesTerminalAfterFirstGet` above), and whose `put`
# always refuses -- the same shape `InMemoryTaskStore`'s own
# terminal-transition guard does -- for
# `testServerRoundTripCancelRacingCompletionIsNotCancelable`.
isolated class RefusesWriteAfterFirstGet {
    *TaskStore;
    private final string targetId;
    private int getCount = 0;

    isolated function init(string targetId) {
        self.targetId = targetId;
    }

    public isolated function put(Task task, string? owner) returns Error? {
        string msg = "simulated terminal-transition conflict";
        return error InternalError(msg, message = msg);
    }

    public isolated function get(string id, string? owner) returns Task?|Error {
        if id != self.targetId {
            return;
        }
        int count;
        lock {
            self.getCount += 1;
            count = self.getCount;
        }
        TaskState state = count == 1 ? TASK_STATE_WORKING : TASK_STATE_COMPLETED;
        return {id, contextId: "c1", status: {state, timestamp: "2026-01-01T00:00:00Z"}};
    }

    public isolated function list(ListTasksRequest filter, string? owner) returns ListTasksResponse|Error {
        return {tasks: [], nextPageToken: "", pageSize: 0, totalSize: 0};
    }

    public isolated function remove(string id, string? owner) returns Error? {
        return;
    }
}

@test:Config {}
function testServerRoundTripMessageReplyOnContinuedTaskDoesNotCloseOtherSubscribers() returns error? {
    // A direct Message reply on a CONTINUED task -- as opposed to a fresh
    // one, where a direct reply removes the never-otherwise-observed seed
    // entirely -- leaves the task itself untouched: still open, still
    // whatever non-terminal state it was in. Closing every live
    // subscriber's stream for that unrelated event would violate
    // specification 3.5.2 ("closing one stream MUST NOT affect other
    // active streams for the same task").
    Client c = check echoClient();
    Task paused = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ask"}]}
    });
    test:assertEquals(paused.status.state, TASK_STATE_INPUT_REQUIRED);

    stream<StreamResponse, error?> subscriber = check c->subscribeToTask({id: paused.id});
    StreamResponse subscriberSnapshot = check expectStreamValue(subscriber);
    test:assertTrue(subscriberSnapshot is Task);
    test:assertEquals((<Task>subscriberSnapshot).status.state, TASK_STATE_INPUT_REQUIRED);

    // "ping" is EchoAgent's direct-Message-reply trigger (see its own
    // definition above) -- sent as the continuation of the paused task.
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, taskId: paused.id, contextId: paused.contextId,
            parts: [{text: "ping"}]}
    });
    test:assertTrue(reply is Message, "the trigger must produce a direct reply, not drive the task through updater");

    // driveTask's continuation branch broadcasts a direct Message reply in
    // its own right (see its own doc comment) before returning it, so the
    // live subscriber sees it too -- consume that here, distinctly from the
    // stream simply ending, which is the whole point of this test.
    StreamResponse pingEvent = check expectStreamValue(subscriber);
    test:assertTrue(pingEvent is Message && (<Message>pingEvent).messageId == (<Message>reply).messageId,
            "the subscriber must see the same direct reply the caller got, not the stream ending instead");

    // The subscriber's stream must still be open and the task still there,
    // unchanged by a reply the task itself was never touched by.
    Task stillOpen = <Task>check c->getTask({id: paused.id});
    test:assertEquals(stillOpen.status.state, TASK_STATE_INPUT_REQUIRED,
            "the continuation's direct reply must not have transitioned the task");

    // Prove the stream is still live, not merely "hasn't happened to close
    // yet": release a real event on it and confirm the subscriber sees it.
    Task|Message finalReply = check c->sendMessage({
        message: {messageId: "m3", role: ROLE_USER, taskId: paused.id, contextId: paused.contextId,
            parts: [{text: "here is more information"}]}
    });
    test:assertTrue(finalReply is Task && (<Task>finalReply).status.state == TASK_STATE_COMPLETED);
    // m3's TaskUpdater is a fresh instance, so its first transition also
    // lazily emits the task's pre-transition snapshot (still INPUT_REQUIRED,
    // now with m3's own message in history) before the WORKING event itself
    // -- the same "just-seeded Task, emitted lazily" driveTask/TaskUpdater
    // already document elsewhere in this module.
    StreamResponse lazySeed = check expectStreamValue(subscriber);
    test:assertTrue(lazySeed is Task && (<Task>lazySeed).status.state == TASK_STATE_INPUT_REQUIRED);
    StreamResponse sawWorking = check expectStreamValue(subscriber);
    test:assertTrue(sawWorking is TaskStatusUpdateEvent
            && (<TaskStatusUpdateEvent>sawWorking).status.state == TASK_STATE_WORKING,
            "the subscriber must still be receiving this task's real events");
}

isolated function expectStreamValue(stream<StreamResponse, error?> events) returns StreamResponse|error {
    record {| StreamResponse value; |}|error? result = events.next();
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
}

@test:Config {}
function testServerRoundTripListTasks() returns error? {
    Client c = check echoClient();
    Task|Message _ = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "one"}]}
    });
    Task|Message _ = check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "two"}]}
    });
    // 100 is the maximum specification 3.1.4 allows; not "however many
    // tasks exist" (finding 28 -- a request for more than the max used to
    // be silently honoured in full instead of refused). Not asserting an
    // empty nextPageToken either: this server is shared with every other
    // test in this file, so once their combined task count passes 100,
    // this genuinely is no longer the last page.
    ListTasksResponse page = check c->listTasks({pageSize: 100});
    test:assertTrue(page.totalSize >= 2, "listTasks must see the tasks that were created");
    test:assertTrue(page.tasks.length() <= 100, "a page must never exceed the specification's own maximum");
}

// Finding 28: with no pageSize, listTasks used to return every matching
// task (unbounded); specification 3.1.4: "If unspecified, at most 50 tasks
// will be returned." A dedicated contextId isolates this from every other
// task the shared echoListener accumulates across the rest of this suite.
@test:Config {}
function testServerRoundTripListTasksDefaultsPageSizeTo50() returns error? {
    Client c = check echoClient();
    string contextId = uuid:createType4AsString();
    foreach int i in 0 ..< 55 {
        Task|Message _ = check c->sendMessage({
            message: {messageId: string `default-page-${i}`, contextId, role: ROLE_USER, parts: [{text: "hi"}]}
        });
    }
    ListTasksResponse page = check c->listTasks({contextId});
    test:assertEquals(page.totalSize, 55);
    test:assertEquals(page.tasks.length(), 50, "an unspecified pageSize must default to 50, not every match");
    test:assertNotEquals(page.nextPageToken, "", "55 matches over a 50-task page must not look like the last page");
}

// Finding 28: an explicit pageSize outside 1..100 used to be silently
// honoured in full (too large) or clamped to an empty page (zero or
// negative) -- either way, not the caller error specification 6.5's own
// validation example makes it ("Must be between 1 and 100 inclusive").
@test:Config {}
function testServerRoundTripListTasksRejectsPageSizeOutOfRange() returns error? {
    Client c = check echoClient();
    foreach int badPageSize in [0, -3, 101, 100000] {
        ListTasksResponse|Error result = c->listTasks({pageSize: badPageSize});
        test:assertTrue(result is InternalError, string `pageSize ${badPageSize} must be refused, not honoured`);
        test:assertEquals((<InternalError>result).detail()?.code, -32602);
    }
}

// Finding 29: a pageToken naming no task in the result set used to be
// treated as "start from the end" -- an empty page, indistinguishable from
// a caller who legitimately paged to the end. The reference a2a-sdk
// raises InvalidParams "Invalid page token" for exactly this.
@test:Config {}
function testServerRoundTripListTasksRejectsBogusPageToken() returns error? {
    Client c = check echoClient();
    ListTasksResponse|Error result = c->listTasks({pageToken: "not-a-real-cursor-" + uuid:createType4AsString()});
    test:assertTrue(result is InternalError, "a page token naming no known task must be refused");
    test:assertEquals((<InternalError>result).detail()?.code, -32602);
}

// Finding 29: an unrecognized status, or a pageSize/historyLength/
// statusTimestampAfter that doesn't parse as its wire type, used to be
// silently dropped (status: every task returned instead of none matching;
// the numeric fields: ignored; the timestamp: every task excluded) rather
// than refused. Specification 6.5's own validation example is exactly
// this shape: a 400 naming the bad field.
@test:Config {}
function testServerRoundTripListTasksRejectsInvalidQueryValues() returns error? {
    http:Client raw = check new (serverUrl);
    string[] badQueries = [
        "status=nonsense",
        "pageSize=abc",
        "historyLength=abc",
        "statusTimestampAfter=not-a-timestamp",
        "includeArtifacts=maybe"
    ];
    foreach string query in badQueries {
        http:Response resp = check raw->get(string `/tasks?${query}`, {"A2A-Version": "1.0"});
        test:assertEquals(resp.statusCode, 400, query);
        test:assertEquals(check reasonOf(resp), "INVALID_PARAMS", query);
    }
}

// The same rule on the other two GET operations that take numeric query
// values: getTask's historyLength and the push-config list's pageSize used to
// be dropped when they didn't parse, answering as if they were never sent.
@test:Config {}
function testServerRoundTripGetTaskAndPushConfigListRejectInvalidQueryValues() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "query me"}]}
    });
    http:Client raw = check new (serverUrl);
    string[] badPaths = [
        string `/tasks/${created.id}?historyLength=abc`,
        string `/tasks/${created.id}/pushNotificationConfigs?pageSize=abc`
    ];
    foreach string path in badPaths {
        http:Response resp = check raw->get(path, {"A2A-Version": "1.0"});
        test:assertEquals(resp.statusCode, 400, path);
        test:assertEquals(check reasonOf(resp), "INVALID_PARAMS", path);
    }
    // includeArtifacts=false still parses: the strict check refuses garbage only.
    http:Response ok = check raw->get("/tasks?includeArtifacts=false", {"A2A-Version": "1.0"});
    test:assertEquals(ok.statusCode, 200);
}

// Specification 11.6: implementations SHOULD use google.rpc.BadRequest "to
// attach structured data to validation errors", naming the field at fault
// (section 3.3.2). The ErrorInfo entry stays, and stays first.
@test:Config {}
function testServerRoundTripValidationErrorsCarryBadRequestDetails() returns error? {
    http:Client raw = check new (serverUrl);

    http:Response queryResp = check raw->get("/tasks?pageSize=abc", {"A2A-Version": "1.0"});
    json[] queryDetails = check errorDetailsOf(queryResp);
    test:assertEquals(queryDetails[0].'\@type, "type.googleapis.com/google.rpc.ErrorInfo");
    test:assertEquals(check badRequestFieldOf(queryDetails), "pageSize");

    json emptyParts = {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": []}};
    http:Response bodyResp = check raw->post("/message:send", emptyParts,
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(bodyResp.statusCode, 400);
    test:assertEquals(check badRequestFieldOf(check errorDetailsOf(bodyResp)), "message.parts");

    json twoVariants = {"message": {"messageId": "m2", "role": "ROLE_USER",
        "parts": [{"text": "fine"}, {"text": "both", "url": "https://example.com/a"}]}};
    http:Response partResp = check raw->post("/message:send", twoVariants,
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(check badRequestFieldOf(check errorDetailsOf(partResp)), "message.parts[1]");

    // A 404 is no validation error: no BadRequest entry.
    http:Response missing = check raw->get("/tasks/does-not-exist", {"A2A-Version": "1.0"});
    test:assertTrue(badRequestFieldOf(check errorDetailsOf(missing)) is error);

    // The client still decodes the same error type, and sees the field too.
    Client c = check echoClient();
    ListTasksResponse|Error result = c->listTasks({pageSize: 500});
    test:assertTrue(result is InternalError);
    InternalError rejected = <InternalError>result;
    test:assertEquals(rejected.detail()?.code, -32602);
    test:assertEquals(rejected.detail()?.data, {"field": "pageSize"});
}

isolated function errorDetailsOf(http:Response resp) returns json[]|error {
    json body = check resp.getJsonPayload();
    return <json[]>check body.'error.details;
}

isolated function badRequestFieldOf(json[] details) returns string|error {
    foreach json detail in details {
        map<json> entry = check detail.ensureType();
        if entry["@type"] == "type.googleapis.com/google.rpc.BadRequest" {
            json[] violations = check entry["fieldViolations"].ensureType();
            return violations[0].'field.ensureType();
        }
    }
    return error("no google.rpc.BadRequest entry");
}

// Specification 5.6.1: timestamps are ISO 8601 in UTC, and millisecond
// precision SHOULD be used (a whole second MAY omit the fraction).
@test:Config {}
function testServerRoundTripStatusTimestampsUseMillisecondPrecision() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "what time is it"}]}
    });
    Task canceledTarget = <Task>check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "ask"}]}
    });
    Task canceled = check c->cancelTask({id: canceledTarget.id});
    foreach Task task in [created, canceled] {
        string timestamp = task.status?.timestamp ?: "";
        test:assertTrue(re `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$`.isFullMatch(timestamp),
                string `"${timestamp}" must be UTC with millisecond precision`);
    }
}

// Specification 3.2.4: at historyLength 0 the `history` field SHOULD be
// omitted, not sent as an empty array -- on getTask and listTasks alike.
@test:Config {}
function testServerRoundTripHistoryLengthZeroOmitsTheHistoryField() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "remember me"}]}
    });
    http:Client raw = check new (serverUrl);

    http:Response fetchedResp = check raw->get(string `/tasks/${created.id}?historyLength=0`, {"A2A-Version": "1.0"});
    json fetched = check fetchedResp.getJsonPayload();
    test:assertFalse((<map<json>>fetched).hasKey("history"), "getTask must omit history at historyLength=0");

    string contextId = created.contextId ?: "";
    http:Response listedResp = check raw->get(string `/tasks?contextId=${contextId}&historyLength=0`,
            {"A2A-Version": "1.0"});
    json listed = check listedResp.getJsonPayload();
    json[] tasks = <json[]>check listed.tasks;
    test:assertEquals(tasks.length(), 1);
    test:assertFalse((<map<json>>tasks[0]).hasKey("history"), "listTasks must omit history at historyLength=0");
}

// ---- extended Agent Card ------------------------------------------------

@test:Config {}
function testServerRoundTripGetExtendedAgentCardWhenNotConfigured() returns error? {
    // echoListener has no extendedAgentCard configured, so its served card
    // declares capabilities.extendedAgentCard: false, and the Client refuses
    // client-side rather than sending a request the server would also
    // refuse -- specification section 3.3.4's MUST-fail is honoured on both
    // sides of the wire, just at different points.
    Client c = check echoClient();
    AgentCard|Error result = c->getExtendedAgentCard();
    test:assertTrue(result is UnsupportedOperationError,
            "a card declaring no extended-card support must refuse client-side, not send a doomed request");
}

@test:Config {}
function testServerRoundTripGetExtendedAgentCardWhenConfigured() returns error? {
    // The extended card is for authenticated callers (section 13.3), so the
    // listener carrying it is configured with `auth` and the client presents a token.
    string token = check bearerToken("alice");
    HttpClient c = check new (extendedCardServerUrl, headers = {"Authorization": "Bearer " + token});
    AgentCard extended = check c->getExtendedAgentCard();
    test:assertEquals(extended.name, "Echo Agent (extended)");
    test:assertEquals(extended.skills.length(), 2, "the extended card reveals the internal-only skill too");

    // The extended card literal above, like this file's other cards, follows the
    // README's own placeholder pattern (capabilities: {}, supportedInterfaces: []) --
    // both must be derived from what the listener actually serves, the same as the
    // public card's own capabilities.streaming/pushNotifications are, not left at
    // that placeholder. Left undone, a client that follows specification 13.3's own
    // "replace your held card with the extended one" and then checks capabilities
    // locally (as this library's own HttpClient does) would refuse operations the
    // server actually supports.
    test:assertEquals(extended.capabilities.streaming, true,
            "the extended card's capabilities must be derived, not left at the developer's placeholder");
    test:assertEquals(extended.capabilities.pushNotifications, true);
    test:assertEquals(extended.capabilities.extendedAgentCard, true,
            "the extended card, being itself, has one configured");
    test:assertEquals(extended.supportedInterfaces.length(), 1);
    test:assertEquals(extended.supportedInterfaces[0].url, extendedCardServerUrl,
            "the extended card's own interface URL must be filled in from the request, same as the public card's");
}

@test:Config {}
function testServedExtendedCardFailsWhenNoneConfigured() {
    // Direct unit test, not a wire round trip: deriveServedCard ties
    // capabilities.extendedAgentCard to whether a card was configured, so
    // this request never actually reaches a Client through echoListener's
    // own wiring -- the Client already refuses client-side with the same
    // UnsupportedOperationError this asserts, per the test above. The
    // branch is still real code for a future binding that serves the
    // extended card without that same coupling, so it is exercised
    // directly here rather than left untested.
    AgentCard|Error result = servedExtendedCard(());
    test:assertTrue(result is UnsupportedOperationError,
            "capabilities.extendedAgentCard false must be UnsupportedOperationError per specification 3.3.4, " +
            "not ExtendedAgentCardNotConfiguredError -- that's reserved for capability true but still unconfigured, " +
            "a state this listener's own deriveServedCard never lets happen");
}

// ---- push-notification config CRUD --------------------------------------
//
// capabilities.pushNotifications is true since delivery landed, so the
// library's own Client no longer self-gates these four operations -- unlike
// the extended-card self-gate above, which is exercised on purpose. Using
// the typed Client here, rather than a raw http:Client, is the stronger
// assertion: it proves a real caller of this library, not just a caller
// willing to speak the wire directly, can drive the whole CRUD cycle.

@test:Config {}
function testServerRoundTripPushNotificationConfigCrud() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "needs a webhook"}]}
    });

    // Create.
    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        taskId: created.id,
        url: "https://example.com/webhook",
        token: "corr-1"
    });
    test:assertEquals(config.url, "https://example.com/webhook");
    string? configId = config?.id;
    test:assertTrue(configId is string, "the server must assign a config id on create");
    string id = <string>configId;

    // Get.
    TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig({taskId: created.id, id});
    test:assertEquals(fetched.id, id);
    test:assertEquals(fetched.token, "corr-1");

    // List.
    ListTaskPushNotificationConfigsResponse page =
        check c->listTaskPushNotificationConfigs({taskId: created.id});
    TaskPushNotificationConfig[] configs = page.configs ?: [];
    test:assertEquals(configs.length(), 1, "the config just created must show up in the list");
    test:assertEquals(configs[0].id, id);

    // Delete.
    check c->deleteTaskPushNotificationConfig({taskId: created.id, id});

    // Get after delete: gone.
    TaskPushNotificationConfig|Error afterDelete = c->getTaskPushNotificationConfig({taskId: created.id, id});
    test:assertTrue(afterDelete is TaskNotFoundError, "the config must genuinely be gone after delete");

    // Delete again: idempotent, not an error, per specification 3.1.10.
    check c->deleteTaskPushNotificationConfig({taskId: created.id, id});
}

@test:Config {}
function testServerRoundTripCreatePushNotificationConfigForUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    TaskPushNotificationConfig|Error result =
        c->createTaskPushNotificationConfig({taskId: "does-not-exist", url: "https://example.com/webhook"});
    test:assertTrue(result is TaskNotFoundError,
            "registering a config against an unknown task must be rejected, not silently accepted");
}

// A config's id is the caller's to choose: a webhook registered as "my-cfg"
// must come back, and be fetchable and deletable, as "my-cfg". Only an unset
// (or empty) id is the server's to assign.
@test:Config {}
function testServerRoundTripPushNotificationConfigKeepsTheCallersOwnId() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-cfg-id", role: ROLE_USER, parts: [{text: "needs webhooks"}]}
    });

    TaskPushNotificationConfig mine = check c->createTaskPushNotificationConfig({
        taskId: created.id, url: "https://example.com/a", id: "my-cfg", token: "first"
    });
    test:assertEquals(mine.id, "my-cfg", "the id the caller chose must be kept, not replaced");
    TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    test:assertEquals(fetched.token, "first");

    // Same id again on the same task replaces the earlier config.
    _ = check c->createTaskPushNotificationConfig({
        taskId: created.id, url: "https://example.com/b", id: "my-cfg", token: "second"
    });
    TaskPushNotificationConfig replaced = check c->getTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    test:assertEquals(replaced.token, "second", "registering the same id twice must replace, not duplicate");

    // No id, and an empty id, both mean "server, choose one".
    TaskPushNotificationConfig assigned = check c->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/c"});
    string? assignedId = assigned?.id;
    test:assertTrue(assignedId is string && assignedId != "" && assignedId != "my-cfg");
    TaskPushNotificationConfig fromEmpty = check c->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/d", id: ""});
    string? emptyBecame = fromEmpty?.id;
    test:assertTrue(emptyBecame is string && emptyBecame != "", "an empty id must be treated as unset");

    ListTaskPushNotificationConfigsResponse page = check c->listTaskPushNotificationConfigs({taskId: created.id});
    test:assertEquals((page.configs ?: []).length(), 3, "my-cfg (replaced once), plus the two assigned ones");

    check c->deleteTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    TaskPushNotificationConfig|Error gone = c->getTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    test:assertTrue(gone is TaskNotFoundError, "delete must work under the caller's own id");
}

// The id is a URL path segment, so one containing "/" could never be fetched
// again. It is a bad request (400), rejected before any task is created.
@test:Config {}
function testServerRoundTripPushNotificationConfigIdWithASlashIsRejected() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-cfg-slash", role: ROLE_USER, parts: [{text: "needs a webhook"}]}
    });

    TaskPushNotificationConfig|Error viaCreate = c->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/a", id: "a/b"});
    test:assertTrue(viaCreate is InternalError && viaCreate.detail()?.code == -32600,
            "an unusable id must be an invalid-request error, not accepted");

    ListTasksResponse listedBefore = check c->listTasks();
    int before = listedBefore.totalSize;
    Task|Message|Error viaSend = c->sendMessage({
        message: {messageId: "m-cfg-slash-2", role: ROLE_USER, parts: [{text: "x"}]},
        configuration: {taskPushNotificationConfig: {url: "https://example.com/a", id: "a/b"}}
    });
    test:assertTrue(viaSend is InternalError && viaSend.detail()?.code == -32600);
    ListTasksResponse listedAfter = check c->listTasks();
    test:assertEquals(listedAfter.totalSize, before,
            "the bad id must be rejected before a task is created, not leave an orphan one behind");
}

// The same registration through the send request itself.
@test:Config {}
function testServerRoundTripInlinePushNotificationConfigKeepsTheCallersOwnId() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-inline-id", role: ROLE_USER, parts: [{text: "inline webhook"}]},
        configuration: {taskPushNotificationConfig: {url: "https://example.com/a", id: "inline-cfg"}}
    });
    TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig(
            {taskId: created.id, id: "inline-cfg"});
    test:assertEquals(fetched.url, "https://example.com/a");
}

@test:Config {}
function testServerRoundTripListPushNotificationConfigsOnATaskWithNoneIsAnEmptyPageNotAPanic() returns error? {
    // A task that never registered any push config -- the ordinary case,
    // not the 3-configs-registered case the earlier list test above
    // covers. listTaskPushNotificationConfigs used to build this response
    // as one chained expression, (self.pushConfigs[taskId] ?: {}).toArray()
    // .clone(); with no config ever registered for the task, that elvis
    // operator's {} default is what toArray().clone() runs on, and doing
    // so as one inline chain panicked the handler with a JVM
    // NullPointerException (confirmed by a standalone repro, isolated from
    // the rest of this module, to be specifically about that one shape --
    // binding the map to a local variable first avoids it).
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-no-push-configs", role: ROLE_USER, parts: [{text: "no webhook here"}]}
    });
    ListTaskPushNotificationConfigsResponse page = check c->listTaskPushNotificationConfigs({taskId: created.id});
    test:assertEquals((page.configs ?: []).length(), 0);
}

// ---- task-owner scoping --------------------------------------------------
//
// A third listener, on its own port, configured with a TaskOwnerResolver
// that reads a test-only "X-Test-Owner" header -- separate from echoListener
// so that its own unscoped (no resolver configured) round trip stays
// unambiguous. Proves scoping actually holds over the real HTTP wire, not
// just at the TaskStore unit level.

isolated class HeaderOwnerResolver {
    *TaskOwnerResolver;

    public isolated function resolveOwner(CallerContext context) returns string?|Error {
        string[]? owners = context.headers["x-test-owner"];
        return owners is string[] && owners.length() > 0 ? owners[0] : ();
    }
}

const int OWNER_SCOPED_TEST_PORT = 19236;
final string ownerScopedServerUrl = string `http://localhost:${OWNER_SCOPED_TEST_PORT}`;

final DefaultHandler ownerScopedHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
},
    ownerResolver = new HeaderOwnerResolver()
);

listener HttpListener ownerScopedListener = new (OWNER_SCOPED_TEST_PORT, ownerScopedHandler);

@test:BeforeSuite
function startOwnerScopedServer() returns error? {
    check ownerScopedListener.attach(new EchoAgent());
}

isolated function ownerScopedRawClient() returns http:Client|error => new (ownerScopedServerUrl);

isolated function sendAsOwner(http:Client raw, string owner, string text) returns Task|error {
    map<string> headers = {"A2A-Version": "1.0", "Content-Type": "application/json", "X-Test-Owner": owner};
    json body = {
        "message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": text}]}
    };
    json result = check raw->post("/message:send", body, headers);
    map<json> envelope = check result.ensureType();
    json? taskJson = envelope["task"];
    if taskJson is () {
        return error("expected a task in the response envelope");
    }
    return taskJson.cloneWithType(Task);
}

isolated function httpClientAs(string owner) returns HttpClient|error =>
    new (ownerScopedServerUrl, headers = {"X-Test-Owner": owner});

@test:Config {}
function testOwnerScopedGetTaskHiddenFromDifferentOwner() returns error? {
    http:Client raw = check ownerScopedRawClient();
    Task created = check sendAsOwner(raw, "alice", "alice's task");

    HttpClient aliceClient = check httpClientAs("alice");
    Task fetchedByAlice = check aliceClient->getTask({id: created.id});
    test:assertEquals(fetchedByAlice.id, created.id, "the owner must be able to fetch their own task");

    HttpClient bobClient = check httpClientAs("bob");
    Task|Error fetchedByBob = bobClient->getTask({id: created.id});
    test:assertTrue(fetchedByBob is TaskNotFoundError,
            "a different owner must see TaskNotFoundError, not the task or a distinct 'forbidden' error");
}

@test:Config {}
function testOwnerScopedCancelAndSubscribeHiddenFromDifferentOwner() returns error? {
    http:Client raw = check ownerScopedRawClient();
    Task created = check sendAsOwner(raw, "alice", "cancel and subscribe me");

    HttpClient bobClient = check httpClientAs("bob");

    Task|Error canceled = bobClient->cancelTask({id: created.id});
    test:assertTrue(canceled is TaskNotFoundError,
            "cancelTask on another owner's task must be TaskNotFoundError, same as an unknown id");

    stream<StreamResponse, error?>|Error subscribed = bobClient->subscribeToTask({id: created.id});
    test:assertTrue(subscribed is TaskNotFoundError,
            "subscribeToTask on another owner's task must be TaskNotFoundError, same as an unknown id");
}

@test:Config {}
function testOwnerScopedListTasksShowsOnlyOwnTasks() returns error? {
    http:Client raw = check ownerScopedRawClient();
    Task _ = check sendAsOwner(raw, "alice-list", "alice item one");
    Task _ = check sendAsOwner(raw, "alice-list", "alice item two");
    Task _ = check sendAsOwner(raw, "bob-list", "bob item one");

    HttpClient aliceClient = check httpClientAs("alice-list");
    ListTasksResponse aliceView = check aliceClient->listTasks({pageSize: 10});
    test:assertEquals(aliceView.totalSize, 2, "alice must see exactly her own two tasks, not bob's");
}

@test:Config {}
function testOwnerScopedPushNotificationConfigAsymmetry() returns error? {
    http:Client alice = check ownerScopedRawClient();
    Task created = check sendAsOwner(alice, "push-alice", "needs a webhook, owned");

    map<string> aliceHeaders = {"A2A-Version": "1.0", "Content-Type": "application/json", "X-Test-Owner": "push-alice"};
    map<string> bobHeaders = {"A2A-Version": "1.0", "Content-Type": "application/json", "X-Test-Owner": "push-bob"};

    json createBody = {"url": "https://example.com/webhook"};
    json createResult = check alice->post(
            string `/tasks/${created.id}/pushNotificationConfigs`, createBody, aliceHeaders);
    TaskPushNotificationConfig config = check createResult.cloneWithType(TaskPushNotificationConfig);
    string id = <string>config.id;

    // Bob creating a config against alice's task: TaskNotFoundError, same as
    // an unknown task -- create already checked task existence before this
    // feature, and now it also checks visibility.
    http:Response bobCreate = check alice->post(
            string `/tasks/${created.id}/pushNotificationConfigs`, createBody, bobHeaders);
    test:assertEquals(bobCreate.statusCode, http:STATUS_NOT_FOUND,
            "creating a config against a task not visible to the caller must be rejected");

    // Bob getting alice's config: TaskNotFoundError -- get previously did no
    // task-visibility check at all, so this closes a real gap, not just a
    // consistency nicety.
    http:Response bobGet = check alice->get(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, bobHeaders);
    test:assertEquals(bobGet.statusCode, http:STATUS_NOT_FOUND,
            "getting a config on a task not visible to the caller must be rejected");

    // Bob listing alice's task's configs: empty page, not an error --
    // matches the existing behavior for a genuinely unknown task, so bob
    // cannot distinguish "not yours" from "doesn't exist" by response shape.
    json bobListResult = check alice->get(
            string `/tasks/${created.id}/pushNotificationConfigs`, bobHeaders);
    ListTaskPushNotificationConfigsResponse bobList =
        check bobListResult.cloneWithType(ListTaskPushNotificationConfigsResponse);
    test:assertEquals((bobList.configs ?: []).length(), 0,
            "listing configs on a task not visible to the caller must return an empty page, not an error");

    // Bob deleting alice's config: silent 200 no-op, not an error and not a
    // real deletion -- matches the existing idempotent-delete behavior for
    // an unknown config.
    http:Response bobDelete = check alice->delete(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, headers = bobHeaders);
    test:assertEquals(bobDelete.statusCode, http:STATUS_OK,
            "deleting a config on a task not visible to the caller must silently succeed, not error");

    // The config must genuinely still exist for alice: bob's delete did nothing.
    json aliceGetAfter = check alice->get(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, aliceHeaders);
    TaskPushNotificationConfig stillThere = check aliceGetAfter.cloneWithType(TaskPushNotificationConfig);
    test:assertEquals(stillThere.id, id, "bob's no-op delete must not have actually removed alice's config");
}

// ---- push-notification delivery ------------------------------------------
//
// A fourth listener, on its own port, configured with a pushSender whose
// validateUrl is off -- this test's own webhook receiver (push_sender_test.bal's
// webhookReceiver) is itself on localhost, which HttpPushNotificationSender's
// default SSRF validation correctly rejects; that rejection is proven
// separately in push_sender_test.bal. This section proves delivery actually
// fires end to end, over the real wire, covering both registration channels.

const int PUSH_NOTIFICATION_TEST_PORT = 19238;
final string pushNotificationServerUrl = string `http://localhost:${PUSH_NOTIFICATION_TEST_PORT}`;
final string testWebhookUrl = string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`;

final DefaultHandler pushNotificationHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
},
    pushSender = new HttpPushNotificationSender({validateUrl: false})
);

listener HttpListener pushNotificationListener = new (PUSH_NOTIFICATION_TEST_PORT, pushNotificationHandler);

// Completes normally, except for:
// - "pause": leaves the task at TASK_STATE_WORKING -- non-terminal, so
//   cancelTask can legally act on it.
// - "hold:<key>": works, then blocks on the Gate registered under <key>, then
//   tries one more write and simply finishes whether or not it was accepted --
//   what an agent does when it does not check the result of every update. A
//   test cancels the task while the agent is held, so that write is refused.
isolated service class PushNotificationAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        string text = "";
        foreach Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }
        check updater->working();
        if text == "pause" {
            return ();
        }
        if text == "boom" {
            string msg = "agent exploded";
            return error InternalError(msg, message = msg);
        }
        if text.startsWith("hold:") {
            Gate? gate = gateFor(text.substring(5));
            if gate is Gate {
                gate.awaitStep(1);
                Error? refused = updater->working();
                gate.advanceTo(refused is Error ? 2 : 3);
            }
            return ();
        }
        check updater->addArtifact([{text: string `echo: ${text}`}]);
        check updater->complete();
        return;
    }
}

@test:BeforeSuite
function startPushNotificationServer() returns error? {
    check pushNotificationListener.attach(new PushNotificationAgent());
}

@test:Config {}
function testServerRoundTripPushNotificationDeliveryOnCompletion() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "notify me"}]},
        configuration: {taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    test:assertEquals(created.status.state, TASK_STATE_COMPLETED);

    CapturedWebhookCall? call = awaitWebhookCallForTask(created.id);
    test:assertTrue(call is CapturedWebhookCall,
            "the webhook registered inline on the sendMessage request must have been called");
    CapturedWebhookCall received = <CapturedWebhookCall>call;
    map<json> task = check webhookTask(received);
    test:assertEquals(task["id"], created.id);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_COMPLETED");
}

@test:Config {}
function testServerRoundTripPushNotificationDeliveryOnFailure() returns error? {
    // notifyPushConfigs's own doc comment says it fires "unconditional on
    // the state reached -- not filtered to terminal states", matching every
    // reference SDK -- confirmed again here against the actual Python
    // a2a-sdk source: its event consumer fires a push notification for a
    // FAILED TaskStatusUpdateEvent the same way it does for any other one
    // (PushNotificationEvent there is a type alias covering
    // TaskStatusUpdateEvent, not a distinct wrapper only some transitions
    // produce). driveTask always returned the original Error, even when its
    // own best-effort failed() transition succeeded, so this library's
    // equivalent silently skipped exactly this one case.
    // returnImmediately, so the caller learns the task's id up front (as any
    // real caller relying on this notification would have to) -- the
    // blocking call, by contrast, only ever returns the bare Error "boom"
    // produces, which carries no task id at all, exactly like a real
    // caller has no way to identify which task to check either.
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-boom", role: ROLE_USER, parts: [{text: "boom"}]},
        configuration: {taskPushNotificationConfig: {url: testWebhookUrl}, returnImmediately: true}
    });
    string taskId = created.id;

    CapturedWebhookCall? call = awaitWebhookCallForTask(taskId);
    test:assertTrue(call is CapturedWebhookCall, "a task that failed must still notify its registered webhook");
    map<json> task = check webhookTask(<CapturedWebhookCall>call);
    test:assertEquals(task["id"], taskId);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_FAILED");
}

@test:Config {}
function testServerRoundTripBlockingSendPushNotificationDeliveryOnFailure() returns error? {
    // The blocking (non-returnImmediately) call's own copy of the same fix,
    // a separate code path in sendMessage itself -- the previous test only
    // exercises finishDrivenTask's. A failed blocking call's Error return
    // carries no task id at all (real callers have the same problem), so
    // this is found by the triggering message's own id in the resulting
    // task's history instead.
    HttpClient c = check new (pushNotificationServerUrl);
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m-boom-blocking", role: ROLE_USER, parts: [{text: "boom"}]},
        configuration: {taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    test:assertTrue(result is Error, "the trigger must fail the call, same as EchoAgent's own \"boom\" does");

    CapturedWebhookCall? call = awaitWebhookCallWithHistoryMessageId("m-boom-blocking");
    test:assertTrue(call is CapturedWebhookCall,
            "a task that failed on the blocking call must still notify its registered webhook");
    map<json> task = check webhookTask(<CapturedWebhookCall>call);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_FAILED");
}

@test:Config {}
function testServerRoundTripSendMessageDoesNotBlockOnPushNotificationDelivery() returns error? {
    // notifyPushConfigs calls itself "fire-and-forget" in its own doc
    // comment, but used to run inline, awaited, before the response
    // returned -- so a slow or unresponsive webhook held up every caller of
    // sendMessage/cancelTask, not just the one that registered it. Proven
    // directly: a receiver that deliberately takes SLOW_WEBHOOK_DELAY
    // (1.5s) to answer must not add anything close to that to how long
    // sendMessage itself takes.
    HttpClient c = check new (pushNotificationServerUrl);
    time:Utc before = time:utcNow();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "slow-webhook-1", role: ROLE_USER, parts: [{text: "notify me"}]},
        configuration: {taskPushNotificationConfig: {url: slowWebhookUrl}}
    });
    decimal elapsed = time:utcDiffSeconds(time:utcNow(), before);
    test:assertEquals(created.status.state, TASK_STATE_COMPLETED);
    test:assertTrue(elapsed < SLOW_WEBHOOK_DELAY / 2,
            string `sendMessage must not wait on webhook delivery -- took ${elapsed}s against a ${SLOW_WEBHOOK_DELAY}s webhook`);

    // The slow delivery does still genuinely happen, just off to the side.
    CapturedWebhookCall? call = awaitWebhookCallForTask(created.id);
    test:assertTrue(call is CapturedWebhookCall, "delivery must still actually happen, just not block the response");
}

// Polls until the task in `contextId` reaches `want`, and returns its id.
isolated function awaitTaskInState(HttpClient c, string contextId, TaskState want) returns string|error {
    foreach int _ in 0 ..< 250 {
        ListTasksResponse page = check c->listTasks({contextId});
        foreach Task t in page.tasks {
            if t.status.state == want {
                return t.id;
            }
        }
        runtime:sleep(0.02);
    }
    return error(string `no task in context ${contextId} reached ${want}`);
}

// A task canceled while its agent code is still running: cancelTask has
// already announced CANCELED, the store refuses the agent's later writes, and
// the agent -- which does not check every update -- simply finishes. Neither
// what a blocking sendMessage reports nor what the webhooks receive may then
// go back to the state the agent last reached (WORKING): the caller must see
// CANCELED, and the webhook must have received exactly one notification, the
// CANCELED one.
@test:Config {}
function testServerRoundTripCancelDuringABlockingSendReportsCanceledAndNotifiesOnce() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Gate gate = new;
    registerGate("hold-blocking", gate);
    _ = takeWebhookHistory();

    string contextId = "ctx-hold-blocking";
    future<Task|Message|Error> sent = start c->sendMessage({
        message: {messageId: "hold-b", contextId, role: ROLE_USER, parts: [{text: "hold:hold-blocking"}]},
        configuration: {taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    string taskId = check awaitTaskInState(c, contextId, TASK_STATE_WORKING);

    Task canceled = check c->cancelTask({id: taskId});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    gate.advanceTo(1);
    gate.awaitStep(2);
    Task|Message reply = check wait sent;
    test:assertTrue(reply is Task, "the blocking send must still return a task");
    Task returned = <Task>reply;
    test:assertEquals(returned.status.state, TASK_STATE_CANCELED,
            "the caller must be told the real state, not the WORKING the agent last reached");

    CapturedWebhookCall[] calls = takeWebhookHistory();
    test:assertEquals(calls.length(), 1, "cancelTask already notified; the agent finishing must not notify again");
    map<json> task = check webhookTask(calls[0]);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_CANCELED");
}

// The same race on the detached path (returnImmediately), where nothing waits
// on the drive: the webhook must still receive one CANCELED and nothing after.
@test:Config {}
function testServerRoundTripCancelDuringADetachedDriveNeverSendsAStaleWebhook() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Gate gate = new;
    registerGate("hold-detached", gate);
    _ = takeWebhookHistory();

    string contextId = "ctx-hold-detached";
    Task seeded = <Task>check c->sendMessage({
        message: {messageId: "hold-d", contextId, role: ROLE_USER, parts: [{text: "hold:hold-detached"}]},
        configuration: {returnImmediately: true, taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    _ = check awaitTaskInState(c, contextId, TASK_STATE_WORKING);

    Task canceled = check c->cancelTask({id: seeded.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    gate.advanceTo(1);
    gate.awaitStep(2);
    // The drive's own follow-up runs just after onMessage returns; a stale
    // notification, if the bug were present, would follow within moments.
    runtime:sleep(0.5);

    CapturedWebhookCall[] calls = takeWebhookHistory();
    test:assertEquals(calls.length(), 1, "exactly the one notification cancelTask sent");
    map<json> task = check webhookTask(calls[0]);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_CANCELED");
    Task stored = check c->getTask({id: seeded.id});
    test:assertEquals(stored.status.state, TASK_STATE_CANCELED, "and the stored state stays canceled");
}

@test:Config {}
function testServerRoundTripCancelClosesLiveSubscriberStream() returns error? {
    // "pause" leaves the task genuinely parked at TASK_STATE_WORKING with
    // no driver left running (onMessage already returned) -- a
    // deterministic, non-racing way to get a non-terminal task a live
    // subscriber can attach to and this test can then cancel out from
    // under it.
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m3", role: ROLE_USER, parts: [{text: "pause"}]}
    });
    test:assertEquals(created.status.state, TASK_STATE_WORKING);

    stream<StreamResponse, error?> events = check c->subscribeToTask({id: created.id});
    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "subscribeToTask's first event must be the task's current state");
    test:assertEquals((<Task>first).status.state, TASK_STATE_WORKING);

    Task canceled = check c->cancelTask({id: created.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    StreamResponse second = check expectStreamValue(events);
    test:assertTrue(second is TaskStatusUpdateEvent,
            "the live subscriber must see the CANCELED transition as its own event");
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_CANCELED);

    record {| StreamResponse value; |}|error? third = events.next();
    test:assertTrue(third is (), "the stream must close once the task is canceled, not hang open");
}

@test:Config {}
function testServerRoundTripPushNotificationDeliveryOnCancel() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "pause"}]}
    });
    test:assertEquals(created.status.state, TASK_STATE_WORKING,
            "the pausing branch must leave the task non-terminal");

    // Registered explicitly, after the task already exists -- the other
    // registration channel from the inline one exercised above.
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({taskId: created.id, url: testWebhookUrl});

    Task canceled = check c->cancelTask({id: created.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    CapturedWebhookCall? call = awaitWebhookCallForTask(created.id);
    test:assertTrue(call is CapturedWebhookCall, "cancelTask must also notify registered webhooks");
    CapturedWebhookCall received = <CapturedWebhookCall>call;
    map<json> canceledTask = check webhookTask(received);
    map<json> canceledStatus = check canceledTask["status"].ensureType();
    test:assertEquals(canceledStatus["state"], "TASK_STATE_CANCELED");
}

// This module's own SecurityRequirement type is internally flat
// (v0.3-shaped, see security_scheme_codec.bal's own doc), but the actual
// A2A v1.0 wire shape wraps each requirement's scheme map under
// "schemes", with each scope list itself wrapped as StringList's
// {"list": [...]}. A separate listener, since none of the others above
// set securityRequirements on their card.

const int SECURITY_REQUIREMENTS_TEST_PORT = 19239;
final string securityRequirementsServerUrl = string `http://localhost:${SECURITY_REQUIREMENTS_TEST_PORT}`;

final DefaultHandler securityRequirementsHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: [],
    securitySchemes: {
        "bearerAuth": <HttpAuthSecurityScheme>{scheme: "bearer", bearerFormat: "JWT"}
    },
    securityRequirements: [{"bearerAuth": ["read", "write"]}, {"bearerAuth": []}]
});

listener HttpListener securityRequirementsListener = new (SECURITY_REQUIREMENTS_TEST_PORT, securityRequirementsHandler);

@test:BeforeSuite
function startSecurityRequirementsServer() returns error? {
    check securityRequirementsListener.attach(new EchoAgent());
}

@test:Config {}
function testServerRoundTripSecurityRequirementsServedInV10WireShape() returns error? {
    // A raw http:Client, not this module's own tolerant Client, is the
    // only way to catch a server that got the encode direction wrong --
    // this module's own Client's parseSecurityRequirements already
    // accepts both the flat and the wrapped shape.
    http:Client raw = check new (securityRequirementsServerUrl);
    json card = check raw->get("/.well-known/agent-card.json");
    map<json> cardMap = check card.ensureType();
    json[] requirements = check cardMap["securityRequirements"].ensureType();
    test:assertEquals(requirements.length(), 2);

    map<json> nonEmpty = check requirements[0].ensureType();
    map<json> nonEmptySchemes = check nonEmpty["schemes"].ensureType();
    map<json> nonEmptyEntry = check nonEmptySchemes["bearerAuth"].ensureType();
    string[] scopes = check nonEmptyEntry["list"].cloneWithType();
    test:assertEquals(scopes, ["read", "write"],
            "a non-empty scope list must be wrapped as {\"list\": [...]}, the v1.0 StringList shape");

    map<json> empty = check requirements[1].ensureType();
    map<json> emptySchemes = check empty["schemes"].ensureType();
    map<json> emptyEntry = check emptySchemes["bearerAuth"].ensureType();
    string[] emptyScopes = check emptyEntry["list"].cloneWithType();
    test:assertEquals(emptyScopes, [],
            "an empty scope list must still be a wrapped, empty StringList, not a bare []");
}

// Per specification 3.3.4/4.6.3: a client that has not declared support
// (via the A2A-Extensions header) for an extension the card marks
// required: true must be refused, not silently served as if the
// extension didn't apply. A separate listener, since none of the others
// above declare any extensions.

const int EXTENSIONS_TEST_PORT = 19240;
final string extensionsServerUrl = string `http://localhost:${EXTENSIONS_TEST_PORT}`;
const string REQUIRED_EXTENSION_URI = "https://example.com/extensions/geolocation/v1";

final DefaultHandler extensionsHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {
        extensions: [
            {uri: REQUIRED_EXTENSION_URI, description: "Location-based search", required: true},
            {uri: "https://standards.org/extensions/citations/v1", description: "Citations", required: false}
        ]
    },
    supportedInterfaces: []
});

listener HttpListener extensionsListener = new (EXTENSIONS_TEST_PORT, extensionsHandler);

@test:BeforeSuite
function startExtensionsServer() returns error? {
    check extensionsListener.attach(new EchoAgent());
}

@test:Config {}
function testServerRoundTripRequiredExtensionRejectsUndeclaredClient() returns error? {
    HttpClient c = check new (extensionsServerUrl);
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(result is ExtensionSupportRequiredError,
            "a client that never declared the required extension must be refused");
}

@test:Config {}
function testServerRoundTripRequiredExtensionAcceptsDeclaredClient() returns error? {
    // The card also declares a second, non-required extension this
    // client never declares support for -- only required: true is
    // enforced, so that alone must not block the request either.
    HttpClient c = check new (extensionsServerUrl, requestedExtensions = [REQUIRED_EXTENSION_URI]);
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(result is Task, "declaring the required extension must let the request through normally");
}

// A deployment can deliberately withhold a capability this listener
// otherwise always implements -- e.g. no outbound network access for
// webhooks -- via ListenerConfiguration.streamingCapability/
// pushNotificationsCapability. Both false here, on a dedicated listener,
// so the other listeners above (all left at the true default) keep
// proving today's unchanged behavior.

const int WITHHELD_CAPABILITIES_TEST_PORT = 19241;
final string withheldCapabilitiesServerUrl = string `http://localhost:${WITHHELD_CAPABILITIES_TEST_PORT}`;

final DefaultHandler withheldCapabilitiesHandler = new ({
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
},
    streamingCapability = false,
    pushNotificationsCapability = false
);

listener HttpListener withheldCapabilitiesListener = new (WITHHELD_CAPABILITIES_TEST_PORT, withheldCapabilitiesHandler);

@test:BeforeSuite
function startWithheldCapabilitiesServer() returns error? {
    check withheldCapabilitiesListener.attach(new EchoAgent());
}

@test:Config {}
function testServerRoundTripWithheldCapabilitiesReflectedOnCard() returns error? {
    AgentCard card = check resolveAgentCard(withheldCapabilitiesServerUrl);
    test:assertFalse(card.capabilities.streaming,
            "streamingCapability: false must be reflected as capabilities.streaming: false on the served card");
    test:assertFalse(card.capabilities.pushNotifications,
            "pushNotificationsCapability: false must be reflected as capabilities.pushNotifications: false");
}

@test:Config {}
function testServerRoundTripWithheldStreamingIsRejectedServerSide() returns error? {
    // The typed Client would normally short-circuit client-side on a card
    // that declares streaming unsupported -- go around it with a raw
    // http:Client to prove the server itself also refuses, per
    // specification 3.3.4, not just that the client happens not to try.
    http:Client raw = check new (withheldCapabilitiesServerUrl);
    json body = {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "hello"}]}};
    http:Response resp = check raw->post("/message:stream", body, {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, http:STATUS_BAD_REQUEST,
            "sendStreamingMessage on a listener with streamingCapability: false must be rejected server-side");
}

@test:Config {}
function testServerRoundTripWithheldPushNotificationsIsRejectedServerSide() returns error? {
    // The typed Client's createTaskPushNotificationConfig already refuses
    // client-side on a card declaring pushNotifications unsupported (same
    // short-circuit as streaming) -- go around it with a raw http:Client,
    // per this codebase's own testing convention for exactly this case.
    http:Client raw = check new (withheldCapabilitiesServerUrl);
    json body = {"url": "https://example.com/webhook"};
    http:Response resp = check raw->post("/tasks/does-not-matter/pushNotificationConfigs", body,
            {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, http:STATUS_BAD_REQUEST,
            "push-notification-config operations on a listener with pushNotificationsCapability: false " +
            "must be rejected server-side, even before any task-existence check");
}

@test:Config {}
function testServerRoundTripInlinePushConfigOnSendMessageIsRejectedWhenCapabilityWithheld() returns error? {
    // The dedicated push-config routes are gated above; this is the *other*
    // registration channel -- an inline taskPushNotificationConfig on the
    // send request itself, which specification 3.3.4 doesn't name as a
    // fifth case by text, but which this library's own design already
    // treats as functionally a Create ("the spec's own registration
    // channel for this case is inline on the send request itself"). Gone
    // around with a raw http:Client for the same reason the test above
    // does: the typed Client only refuses what the *dedicated* routes
    // would, since it has no client-side knowledge that an inline config
    // needs the same gate.
    http:Client raw = check new (withheldCapabilitiesServerUrl);
    json body = {
        "message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "hello"}]},
        "configuration": {"taskPushNotificationConfig": {"url": "https://example.com/webhook"}}
    };
    http:Response resp = check raw->post("/message:send", body, {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, http:STATUS_BAD_REQUEST,
            "an inline push config must be rejected the same as the dedicated routes are, " +
            "not silently registered against a capability the card says is off");
}

@test:AfterSuite
function stopEchoServer() returns error? {
    check echoListener.gracefulStop();
    check extendedCardListener.gracefulStop();
    check ownerScopedListener.gracefulStop();
    check pushNotificationListener.gracefulStop();
    check securityRequirementsListener.gracefulStop();
    check extensionsListener.gracefulStop();
    check withheldCapabilitiesListener.gracefulStop();
}

// ---- a caller's mistake is a 4xx, never a 5xx ----------------------------
//
// Found by the real-SDK interop pass (a2a-library-testing, I14): a path that
// is no A2A operation, and a tenant the agent does not serve, were both
// answered 500. The specification is silent on both cases; what it fixes is
// the category -- 5xx is for system failures and an agent's own malformed
// response, and neither is what a caller's typo is.

isolated function reasonOf(http:Response resp) returns string?|error {
    json payload = check resp.getJsonPayload();
    map<json> envelope = check payload.ensureType();
    map<json> err = check envelope["error"].ensureType();
    json[] details = check err["details"].ensureType();
    map<json> info = check details[0].ensureType();
    json? reason = info["reason"];
    return reason is string ? reason : ();
}

@test:Config {}
function testUnknownPathIs404NotFound() returns error? {
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/nope", {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, 404, "a path that is no A2A operation is not a server fault");
    test:assertEquals(check reasonOf(resp), "METHOD_NOT_FOUND");
    test:assertTrue(resp.getContentType().startsWith("application/a2a+json"));
}

// Finding 37: the proto's `{id=*}` matches exactly one path segment, so a
// slash in what would otherwise be the id names no A2A operation at all --
// found because a real client's legacy fallback called GET on a `:subscribe`
// path and hit this via a different route. Previously served as a lookup
// for a task literally named "a/b/c" (a 404 either way, since no such task
// exists, but the wrong reason and route).
@test:Config {}
function testTaskIdWithASlashIs404NotACrossSegmentLookup() returns error? {
    http:Client raw = check new (serverUrl);

    http:Response getResp = check raw->get("/tasks/a/b/c", {"A2A-Version": "1.0"});
    test:assertEquals(getResp.statusCode, 404);
    test:assertEquals(check reasonOf(getResp), "METHOD_NOT_FOUND");

    http:Response cancelResp = check raw->post("/tasks/a/b:cancel", (), {"A2A-Version": "1.0"});
    test:assertEquals(cancelResp.statusCode, 404);
    test:assertEquals(check reasonOf(cancelResp), "METHOD_NOT_FOUND");

    http:Response subscribeResp = check raw->get("/tasks/a/b:subscribe", {"A2A-Version": "1.0"});
    test:assertEquals(subscribeResp.statusCode, 404);
    test:assertEquals(check reasonOf(subscribeResp), "METHOD_NOT_FOUND");
}

@test:Config {}
function testUnknownPushConfigSubRouteIs404() returns error? {
    // The second place a path can fall through: under a task's push-config
    // collection, with a method the collection does not offer (it has POST and
    // GET; DELETE is only for an item). Not PUT: the HTTP layer answers that
    // 405 itself, before the dispatcher is reached.
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->delete("/tasks/t1/pushNotificationConfigs",
            headers = {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, 404);
    test:assertEquals(check reasonOf(resp), "METHOD_NOT_FOUND");
}

@test:Config {}
function testBarePushConfigPathWithNoTaskIdIs404NotACrash() returns error? {
    // onPushNotificationConfigs assumes a "/tasks/{taskId}/pushNotificationConfigs..."
    // shape and slices the path on that assumption (TASKS_PATH_PREFIX.length() as the
    // start index); routing a bare "/pushNotificationConfigs" (no task id, no /tasks/
    // prefix at all) into it took that start index past the slice's own end.
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/pushNotificationConfigs", {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, 404, "never a legal path; must fall through cleanly, not crash the handler");
    test:assertEquals(check reasonOf(resp), "METHOD_NOT_FOUND");
}

@test:Config {}
function testTenantLookingPrefixIsNotMistakenForTheBareTasksRoute() returns error? {
    // "/tasks-eu/..." must not be recognized as the tenant-less "/tasks" family just
    // because it happens to start with the same six characters -- it names a tenant,
    // "tasks-eu", same as "/acme-corp/..." does below. This listener declares no
    // tenant, so it is the same "agent does not serve this tenant" 400 either way;
    // what this guards is that it reaches that check at all, instead of 404ing as an
    // unmatched "/tasks..." route (a Listener cannot yet serve any tenant at all --
    // deriveServedCard always replaces supportedInterfaces with a tenant-less entry --
    // so a "declared and matched" positive case is not something to test here).
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->post("/tasks-eu/message:send",
            {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "hi"}]}},
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(resp.statusCode, 400, "a tenant prefix, not an unmatched route");
    test:assertEquals(check reasonOf(resp), "INVALID_PARAMS");
}

@test:Config {}
function testUnservedTenantIs400InvalidParams() returns error? {
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/acme-corp/tasks", {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, 400, "naming a tenant the agent does not serve is the caller's mistake");
    test:assertEquals(check reasonOf(resp), "INVALID_PARAMS");
    test:assertNotEquals(check reasonOf(resp), "INVALID_AGENT_RESPONSE",
            "that reason is for an agent's own malformed response");
}

@test:Config {}
function testUnknownRouteAndUnknownTaskStayDistinguishable() returns error? {
    // Both are 404, but they mean different things and must say so.
    http:Client raw = check new (serverUrl);
    http:Response route = check raw->get("/nope", {"A2A-Version": "1.0"});
    http:Response task = check raw->get("/tasks/does-not-exist", {"A2A-Version": "1.0"});
    test:assertEquals(route.statusCode, 404);
    test:assertEquals(task.statusCode, 404);
    test:assertEquals(check reasonOf(route), "METHOD_NOT_FOUND");
    test:assertEquals(check reasonOf(task), "TASK_NOT_FOUND");
}
