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

// ---- URL validation, table-driven --------------------------------------

isolated function urlValidationCases() returns [string, boolean][] => [
    // Allowed.
    ["https://example.com/webhook", true],
    ["http://webhook.example.org:8080/x", true],
    ["https://8.8.8.8/hook", true],
    ["http://172.10.0.5/hook", true], // outside the 172.16-31/12 private block
    ["http://100.63.0.5/hook", true], // outside the 100.64.0.0/10 CGNAT block
    ["http://[2001:4860:4860::8888]/hook", true], // public IPv6
    ["http://user:pass@example.com:8080/hook", true], // userinfo stripped before the host check
    // A hostname that happens to start with "fc"/"fd" is not an IPv6 literal and must not be
    // caught by the IPv6 unique-local check -- it has no ':' at all.
    ["http://fdic.gov/hook", true],
    ["http://fcbarcelona.com/hook", true],
    // A legitimate address in one of the short numbers-and-dots forms must still be allowed --
    // the parser isn't a blanket rejection of anything short. 16909060 is 1.2.3.4.
    ["http://16909060/hook", true],
    // Rejected: scheme.
    ["ftp://example.com/", false],
    ["example.com/webhook", false],
    // Rejected: loopback, metadata, private, CGNAT, unspecified.
    ["http://127.0.0.1:9000/", false],
    ["http://169.254.169.254/latest/meta-data", false],
    ["http://10.0.0.5/hook", false],
    ["http://172.20.0.5/hook", false],
    ["http://192.168.1.5/hook", false],
    ["http://100.64.0.5/hook", false],
    ["http://0.0.0.0/hook", false],
    // Rejected: by name.
    ["http://localhost:8080/hook", false],
    ["http://sub.localhost/hook", false],
    ["http://myservice.local/hook", false],
    ["http://metadata.google.internal/x", false],
    ["http://localhost./hook", false], // trailing dot -- still "localhost", the root label is just empty
    // Rejected: IPv4 written in a short numbers-and-dots form a real resolver still accepts
    // (confirmed against java.net.InetAddress.getByName, what a JVM-based client resolves a
    // host through) -- a strict four-octet-only check lets every one of these connect.
    ["http://127.1/hook", false], // 127.0.0.1
    ["http://10.1/hook", false], // 10.0.0.1
    ["http://2130706433/hook", false], // 127.0.0.1, as one 32-bit decimal
    ["http://169.254.43518/hook", false], // 169.254.169.254, the cloud metadata address
    // Rejected: IPv6, compressed and full forms.
    ["http://[::1]:8080/hook", false],
    ["http://[0:0:0:0:0:0:0:1]/hook", false], // ::1, written out in full
    ["http://[::]/hook", false],
    ["http://[fc00::1]/hook", false],
    ["http://[fd12:3456::1]/hook", false],
    ["http://[fe80::1]/hook", false], // IPv6 link-local
    ["http://[::ffff:127.0.0.1]/hook", false], // IPv4-mapped loopback
    ["http://[::ffff:a9fe:a9fe]/hook", false] // IPv4-mapped 169.254.169.254 (cloud metadata)
];

@test:Config {dataProvider: urlValidationCases}
function testValidateWebhookUrl(string url, boolean allowed) returns error? {
    Error? result = validateWebhookUrl(url);
    if allowed {
        test:assertTrue(result is (),
                string `expected "${url}" to be allowed, got: ${result is Error ? result.message() : ""}`);
    } else {
        test:assertTrue(result is Error, string `expected "${url}" to be rejected`);
    }
}

// ---- HttpPushNotificationSender, against a real local receiver --------

const int PUSH_SENDER_TEST_PORT = 19237;

type CapturedWebhookCall record {|
    map<string> headers;
    json body;
    string rawPath;
|};

isolated CapturedWebhookCall? lastWebhookCall = ();

// Every call, in arrival order -- for tests that must prove a webhook was
// called exactly once, or not again, rather than only look at the last one.
isolated CapturedWebhookCall[] webhookHistory = [];

isolated function takeWebhookHistory() returns CapturedWebhookCall[] {
    lock {
        CapturedWebhookCall[] all = webhookHistory.clone();
        webhookHistory.removeAll();
        return all.clone();
    }
}

isolated function recordWebhookCall(CapturedWebhookCall call) {
    lock {
        lastWebhookCall = call.clone();
    }
    lock {
        webhookHistory.push(call.clone());
    }
}

isolated function takeLastWebhookCall() returns CapturedWebhookCall? {
    lock {
        CapturedWebhookCall? call = lastWebhookCall;
        lastWebhookCall = ();
        return call.clone();
    }
}

// Delivery from sendMessage/cancelTask now runs detached (a fix for finding
// #3: it used to block the response on every registered webhook's own
// timeout), so a test asserting on it can no longer assume the call has
// already landed the instant sendMessage/cancelTask returns. Nor can it use
// the single-slot takeLastWebhookCall: with delivery detached, one test's
// call can still be in flight when the next one starts (nothing awaits that
// future), and a shared, destructive "last call" slot lets that straggler
// overwrite -- or a filtering read steal -- another test's own call. Every
// call is also recorded into webhookHistory, never overwritten; this reads
// that non-destructively and waits for the one matching the task this test
// itself is asserting on, leaving every other entry (this test's own
// earlier calls, or another test's) exactly where it was for whoever is
// looking for it. A direct, synchronous PushNotificationSender.send call
// (most of this file's own tests) needs no such wait.
isolated function peekWebhookHistory() returns CapturedWebhookCall[] {
    lock {
        return webhookHistory.clone();
    }
}

isolated function awaitWebhookCallForTask(string taskId) returns CapturedWebhookCall? {
    // 400 * 0.02s = 8s -- longer than the slowest deliberately-slow test
    // receiver this file has (SLOW_WEBHOOK_DELAY, 1.5s), with headroom.
    foreach int _ in 0 ..< 400 {
        foreach CapturedWebhookCall call in peekWebhookHistory() {
            map<json>|error task = webhookTask(call);
            if task is map<json> && task["id"] == taskId {
                return call;
            }
        }
        runtime:sleep(0.02);
    }
    return;
}

// For the one caller that has no task id to look up by at all -- a failed
// blocking sendMessage call's own Error return carries none, matching what
// a real caller sees too -- found instead by the triggering message's own
// id, which last session's fix seeds into a fresh task's history.
isolated function awaitWebhookCallWithHistoryMessageId(string messageId) returns CapturedWebhookCall? {
    foreach int _ in 0 ..< 400 {
        foreach CapturedWebhookCall call in peekWebhookHistory() {
            map<json>|error task = webhookTask(call);
            if task is map<json> {
                json|error history = task["history"];
                if history is json[] {
                    foreach json m in history {
                        map<json>|error message = m.ensureType();
                        if message is map<json> && message["messageId"] == messageId {
                            return call;
                        }
                    }
                }
            }
        }
        runtime:sleep(0.02);
    }
    return;
}

// Unwraps the `task` arm of a captured webhook body: the body is a
// StreamResponse (specification 4.3.3), never a bare task.
isolated function webhookTask(CapturedWebhookCall call) returns map<json>|error {
    map<json> envelope = check call.body.ensureType();
    return envelope["task"].ensureType();
}

listener http:Listener webhookReceiver = new (PUSH_SENDER_TEST_PORT);

service /webhook/receiver on webhookReceiver {
    resource function post .(http:Request req) returns json {
        map<string> headers = {};
        foreach string name in req.getHeaderNames() {
            string|http:HeaderNotFoundError value = req.getHeader(name);
            if value is string {
                headers[name.toLowerAscii()] = value;
            }
        }
        json body = {};
        json|error payload = req.getJsonPayload();
        if payload is json {
            body = payload;
        }
        recordWebhookCall({headers, body, rawPath: req.rawPath});
        return {received: true};
    }
}

# A webhook that takes real, measurable time to answer -- for
# testServerRoundTripSendMessageDoesNotBlockOnPushNotificationDelivery
# (server_roundtrip_test.bal), which proves delivery runs detached by
# checking that sendMessage returns well before this delay elapses.
final string slowWebhookUrl = string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/slow`;
const decimal SLOW_WEBHOOK_DELAY = 1.5;

service /webhook/slow on webhookReceiver {
    resource function post .(http:Request req) returns json {
        runtime:sleep(SLOW_WEBHOOK_DELAY);
        json|error payload = req.getJsonPayload();
        recordWebhookCall({headers: {}, body: payload is json ? payload : {}, rawPath: req.rawPath});
        return {received: true};
    }
}

isolated function sampleTask() returns Task => {
    id: "task-1",
    contextId: "ctx-1",
    status: {state: TASK_STATE_COMPLETED, timestamp: "2026-01-01T00:00:00Z"}
};

@test:Config {}
function testHttpPushNotificationSenderPostsTaskBody() returns error? {
    // validateUrl: false -- this test's receiver is itself on localhost,
    // which the sender's own SSRF validation correctly rejects by default;
    // that rejection is what testHttpPushNotificationSenderRejectsDisallowedUrlBeforeSending
    // covers. This test is about the POST mechanics, not validation.
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`},
            sampleTask());
    test:assertTrue(result is (), "delivery to a real, reachable receiver must succeed");

    CapturedWebhookCall? call = takeLastWebhookCall();
    test:assertTrue(call is CapturedWebhookCall, "the receiver must have been called");
    CapturedWebhookCall received = <CapturedWebhookCall>call;
    test:assertEquals(received.rawPath, "/webhook/receiver", "the config's path must reach the receiver intact");
    // Specification 4.3.3: the body is a StreamResponse, so the task sits under
    // its own key -- not bare at the top level, where a receiver could not
    // tell it from a status or artifact update.
    map<json> envelope = check received.body.ensureType();
    test:assertEquals(envelope.keys(), ["task"], "the body must be a StreamResponse with exactly one arm");
    map<json> task = check envelope["task"].ensureType();
    test:assertEquals(task["id"], "task-1");
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_COMPLETED");
    test:assertEquals(received.headers["content-type"], "application/a2a+json");
}

// File bytes must go out base64-encoded, as everywhere else on the wire; a
// bare toJson() on a byte[] would send an array of integers instead.
@test:Config {}
function testHttpPushNotificationSenderEncodesFileBytesAsBase64() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Task withFile = sampleTask();
    withFile.artifacts = [{
        artifactId: "a1",
        parts: [{raw: "tck".toBytes(), mediaType: "text/plain", filename: "output.txt"}]
    }];
    Error? result = sender.send({url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`}, withFile);
    test:assertTrue(result is (), "delivery to a real, reachable receiver must succeed");

    CapturedWebhookCall received = <CapturedWebhookCall>takeLastWebhookCall();
    map<json> envelope = check received.body.ensureType();
    map<json> task = check envelope["task"].ensureType();
    json[] artifacts = check task["artifacts"].ensureType();
    map<json> artifact = check artifacts[0].ensureType();
    json[] parts = check artifact["parts"].ensureType();
    map<json> part = check parts[0].ensureType();
    test:assertEquals(part["raw"], "dGNr", "\"tck\" must arrive as its base64 form, not as an integer array");
}

@test:Config {}
function testHttpPushNotificationSenderSendsTokenAndAuthHeaders() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({
        url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`,
        token: "corr-42",
        authentication: {scheme: "Bearer", credentials: "secret-token"}
    }, sampleTask());
    test:assertTrue(result is ());

    CapturedWebhookCall received = <CapturedWebhookCall>takeLastWebhookCall();
    test:assertEquals(received.headers["x-a2a-notification-token"], "corr-42",
            "config.token must round-trip as the correlation header");
    test:assertEquals(received.headers["authorization"], "Bearer secret-token",
            "config.authentication must build a standard Authorization header");
}

@test:Config {}
function testHttpPushNotificationSenderRejectsDisallowedUrlBeforeSending() returns error? {
    HttpPushNotificationSender sender = new ();
    Error? result = sender.send({url: "http://127.0.0.1:9/unreachable"}, sampleTask());
    test:assertTrue(result is Error, "a loopback URL must be rejected before any connection is attempted");
}

@test:Config {}
function testHttpPushNotificationSenderValidationCanBeDisabled() returns error? {
    // Loopback is where the real receiver in this test file actually
    // listens -- proving validateUrl: false genuinely lets a deployment
    // reach an internal host, not just that the flag exists.
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`},
            sampleTask());
    test:assertTrue(result is (), "validateUrl: false must allow a loopback webhook through");
}

@test:Config {}
function testHttpPushNotificationSenderUnreachableHostIsAnError() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false, retryConfig: ()});
    Error? result = sender.send({url: "http://localhost:1/nobody-listens-here"}, sampleTask());
    test:assertTrue(result is Error, "an unreachable webhook must return an Error, not panic or hang");
}

// ---- retry with backoff (specification 13.2) -----------------------------

isolated map<int> flakyWebhookAttempts = {};

// Answers `status` to the first `failures` calls for `key`, then 200.
service /webhook/flaky on webhookReceiver {
    resource function post [string key]/[int failures]/[int status]() returns http:Response {
        int attempt;
        lock {
            attempt = (flakyWebhookAttempts[key] ?: 0) + 1;
            flakyWebhookAttempts[key] = attempt;
        }
        http:Response response = new;
        response.statusCode = attempt <= failures ? status : 200;
        return response;
    }
}

isolated function flakyAttempts(string key) returns int {
    lock {
        return flakyWebhookAttempts[key] ?: 0;
    }
}

isolated function flakyUrl(string key, int failures, int status) returns string =>
    string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/flaky/${key}/${failures}/${status}`;

final http:RetryConfig & readonly quickRetry = {
    count: 3,
    interval: 0.1,
    backOffFactor: 2.0,
    maxWaitInterval: 1,
    statusCodes: [408, 429, 500, 502, 503, 504]
};

@test:Config {}
function testHttpPushNotificationSenderRetriesATransientFailure() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false, retryConfig: quickRetry});
    Error? result = sender.send({url: flakyUrl("transient", 2, 503)}, sampleTask());
    test:assertTrue(result is (), "a webhook that recovers within the retries must count as delivered");
    test:assertEquals(flakyAttempts("transient"), 3, "two 503s, then the 200");
}

@test:Config {}
function testHttpPushNotificationSenderGivesUpAfterTheLastRetry() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false, retryConfig: quickRetry});
    Error? result = sender.send({url: flakyUrl("down", 99, 500)}, sampleTask());
    test:assertTrue(result is Error, "a webhook still failing after every retry is a failed delivery");
    test:assertEquals(flakyAttempts("down"), 4, "the first attempt and three retries");
}

@test:Config {}
function testHttpPushNotificationSenderDoesNotRetryAClientError() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false, retryConfig: quickRetry});
    Error? result = sender.send({url: flakyUrl("refused", 99, 404)}, sampleTask());
    test:assertTrue(result is Error, "a 404 is not an acknowledgement");
    test:assertEquals(flakyAttempts("refused"), 1, "a 4xx other than 408 and 429 will not change on retry");
}

@test:Config {}
function testHttpPushNotificationSenderRetriesByDefault() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({url: flakyUrl("default", 1, 503)}, sampleTask());
    test:assertTrue(result is (), "the default configuration must retry a 503");
    test:assertEquals(flakyAttempts("default"), 2);
}

@test:Config {}
function testHttpPushNotificationSenderRetryCanBeDisabled() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false, retryConfig: ()});
    Error? result = sender.send({url: flakyUrl("once", 1, 503)}, sampleTask());
    test:assertTrue(result is Error);
    test:assertEquals(flakyAttempts("once"), 1, "retryConfig: () must send each update once");
}
