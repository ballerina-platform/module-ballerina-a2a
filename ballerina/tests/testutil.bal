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

// Base URL for the scripted mock A2A server used by Client tests.
//
public isolated function getServerBaseUrl() returns string {
    return "http://localhost:19199";
}

// ---- Scriptable mock A2A server -------------------------------------
//
// One listener, two resources: a static (optionally overridable) Agent
// Card at the well-known endpoint, and a single JSON-RPC endpoint at the
// root path (every Client operation POSTs to "" — the method name lives
// in the request body, not the URL) that replays whatever the current
// test last scripted via setNextJsonResponse/setNextSseResponse.
//
// Each script is bundled into a single record behind a single isolated
// variable, since Ballerina's `lock` statement rejects touching more than
// one isolated variable in one block.

listener http:Listener mockListener = check new (19199);

// ETag value for the default mock Agent Card
final string DEFAULT_MOCK_CARD_ETAG = "\"default-card-v1\"";

type MockRpcScript record {|
    json jsonBody = {};
    int statusCode = 200;
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    decimal delaySeconds = 0;
    // When true, the SSE response ends the scripted events with a genuine
    // stream error instead of a clean end-of-stream — simulating a dropped
    // connection (as opposed to sseEvents simply running out, which the
    // underlying HTTP response framing surfaces as a normal, error-free
    // stream end). Used to exercise ReconnectingStreamGenerator's
    // reconnect-on-error path, which must NOT trigger on a clean close.
    boolean simulateDropError = false;
|};

type MockWellKnownScript record {|
    boolean hasOverride = false;
    json overrideBody = {};
    int overrideStatus = 200;
    string? etag = ();
    int? conditionalStatus = ();
|};

isolated MockRpcScript rpcScript = {};
isolated MockWellKnownScript wellKnownScript = {};
isolated json lastRequestBody = {};
isolated map<string> lastRequestHeaders = {};

type MockRestScript record {|
    json jsonBody = {};
    int statusCode = 200;
    boolean hasResponseBody = true;
    map<string> lastQueryParams = {};
    string lastPath = "";
    string lastMethod = "";
    json lastBody = {};
    map<string> lastHeaders = {};
    http:SseEvent[] sseEvents = [];
    boolean isSse = false;
    boolean simulateDropError = false;
    // Task 6's SubscribeToTask GET-vs-POST fallback support: when set,
    // the mock rejects exactly one request of this method with this
    // status, then clears itself so the retry (a different method)
    // succeeds normally. () means no rejection scripted.
    string? rejectMethod = ();
    int rejectStatusCode = 0;
    // Content-type negotiation support (rest_client.bal's
    // performRestCallWithNegotiation): when set, the mock rejects exactly
    // one request carrying this Content-Type with this status, then
    // clears itself so the retry (a different Content-Type) succeeds
    // normally. () means no rejection scripted.
    string? rejectContentType = ();
    int rejectContentTypeStatusCode = 0;
    // How long the mock waits before responding, for exercising
    // http:ClientConfiguration.timeout passthrough.
    decimal delaySeconds = 0;
|};

isolated MockRestScript restScript = {};

// Scripts the next REST request to receive a plain JSON response.
//
public isolated function setNextRestResponse(json body, int statusCode = 200, boolean hasResponseBody = true) {
    lock {
        restScript = {jsonBody: body.clone(), statusCode, hasResponseBody};
    }
}

// Scripts the next REST request to receive an SSE stream response, with
// bare StreamResponse JSON event data (no JSON-RPC envelope) — the REST
// binding's actual wire shape.
//
public isolated function setNextRestSseResponse(http:SseEvent[] events) {
    lock {
        restScript.sseEvents = events.clone();
        restScript.isSse = true;
        restScript.simulateDropError = false;
    }
}

// Scripts the next REST request to receive an SSE stream that plays the
// given events and then ends with a genuine stream error, simulating a
// dropped connection — distinct from setNextRestSseResponse, whose events
// simply running out produces a normal, error-free stream end. Used to
// exercise the reconnect-on-error path of automatic SSE reconnection.
//
public isolated function setNextRestSseResponseThenDrop(http:SseEvent[] events) {
    lock {
        restScript.sseEvents = events.clone();
        restScript.isSse = true;
        restScript.simulateDropError = true;
    }
}

// Scripts the mock to reject exactly the next request of the given HTTP
// method with the given status code (e.g. simulating a server that only
// routes POST for an operation the proto annotates as GET), then clear
// the rejection so a subsequent request — the client's retry with a
// different method — succeeds normally against whatever else is scripted.
//
public isolated function setRestRejectMethod(string httpMethod, int statusCode) {
    lock {
        restScript.rejectMethod = httpMethod;
        restScript.rejectStatusCode = statusCode;
    }
}

// Scripts the mock to reject exactly the next REST request carrying the
// given Content-Type with the given status code (e.g. simulating a real
// server, like a2a-java-sdk-reference-rest, that rejects the spec-mandated
// application/a2a+json with a 415), then clear the rejection so a
// subsequent request — the client's retry with a different Content-Type —
// succeeds normally against whatever else is scripted.
//
public isolated function setRestRejectContentType(string contentType, int statusCode) {
    lock {
        restScript.rejectContentType = contentType;
        restScript.rejectContentTypeStatusCode = statusCode;
    }
}

// Returns the headers of the last REST request the mock received, so tests
// can assert on outbound headers (e.g. Content-Type). Keys are lowercased —
// see getLastRequestHeaders' doc comment for why.
//
public isolated function getLastRestHeaders() returns map<string> {
    lock {
        return restScript.lastHeaders.clone();
    }
}

// Returns the method, path, and query params of the last REST request the
// mock received, so tests can assert on exactly what the Client sent.
//
public isolated function getLastRestRequest() returns record {| string method; string path; map<string> queryParams; |} {
    lock {
        return {method: restScript.lastMethod, path: restScript.lastPath, queryParams: restScript.lastQueryParams.clone()};
    }
}

// Returns the JSON body of the last REST request the mock received, so
// tests can assert on what the Client actually sent on the wire (e.g. the
// M3/M4 tenant/path-param body duplication for hasBody operations). `{}`
// for a bodiless request (e.g. a GET or DELETE, which never carries a
// request body to parse).
//
public isolated function getLastRestBody() returns json {
    lock {
        return restScript.lastBody.clone();
    }
}

// Returns the JSON body of the last request the mock JSON-RPC endpoint
// received, so tests can assert on what the Client actually sent on the
// wire (e.g. tenant propagation).
//
public isolated function getLastRequestBody() returns json {
    lock {
        return lastRequestBody.clone();
    }
}

// Returns the headers of the last request the mock JSON-RPC endpoint
// received, so tests can assert on outbound headers (e.g. A2A-Extensions).
// Keys are lowercased, since the wire casing of header names varies with
// HTTP protocol negotiation on this connection (see the capture site for
// details) -- callers should look up headers by their lowercase name.
//
public isolated function getLastRequestHeaders() returns map<string> {
    lock {
        return lastRequestHeaders.clone();
    }
}

// Scripts the next JSON-RPC request to receive a plain JSON response.
//
public isolated function setNextJsonResponse(json body, int statusCode = 200) {
    lock {
        rpcScript = {jsonBody: body.clone(), statusCode, isSse: false, delaySeconds: 0};
    }
}

// Scripts the next JSON-RPC request to receive an SSE stream response.
//
public isolated function setNextSseResponse(http:SseEvent[] events) {
    lock {
        rpcScript = {sseEvents: events.clone(), isSse: true, delaySeconds: 0};
    }
}

// Scripts the next JSON-RPC request to receive an SSE stream that plays the
// given events and then ends with a genuine stream error, simulating a
// dropped connection — distinct from setNextSseResponse, whose events
// simply running out produces a normal, error-free stream end (proven by
// testSendMessageStreamPausesAtInputRequiredThenResumes). Used to exercise
// the reconnect-on-error path of automatic SSE reconnection.
//
public isolated function setNextSseResponseThenDrop(http:SseEvent[] events) {
    lock {
        rpcScript = {sseEvents: events.clone(), isSse: true, delaySeconds: 0, simulateDropError: true};
    }
}

// A synthetic SSE source that replays a fixed list of events, then yields a
// stream error instead of ending cleanly — used by
// setNextSseResponseThenDrop to simulate a dropped connection at the wire
// level, since a plain array-backed stream (events.toStream()) has no way
// to end with anything but a clean, error-free close.
isolated class DropAfterEventsGenerator {
    private final http:SseEvent[] & readonly events;
    private int idx = 0;

    isolated function init(http:SseEvent[] events) {
        self.events = events.cloneReadOnly();
    }

    public isolated function next() returns record {| http:SseEvent value; |}|error? {
        int i;
        lock {
            i = self.idx;
            self.idx += 1;
        }
        if i >= self.events.length() {
            return error("simulated connection drop");
        }
        return {value: self.events[i]};
    }
}

// Delays the next JSON-RPC response by the given number of seconds, to
// exercise http:ClientConfiguration.timeout passthrough.
//
public isolated function setNextDelay(decimal seconds) {
    lock {
        rpcScript.delaySeconds = seconds;
    }
    lock {
        restScript.delaySeconds = seconds;
    }
}

// Overrides the well-known endpoint's response for one test (e.g. a
// malformed-card or non-200 scenario). Pass `()` to restore the default
// static card.
//
public isolated function setWellKnownOverride(json? body, int statusCode = 200) {
    lock {
        if body is () {
            wellKnownScript = {};
        } else {
            // Preserve existing ETag and conditionalStatus when setting override
            string? existingEtag = wellKnownScript.etag;
            int? existingConditional = wellKnownScript.conditionalStatus;
            wellKnownScript = {hasOverride: true, overrideBody: body.clone(), overrideStatus: statusCode, etag: existingEtag, conditionalStatus: existingConditional};
        }
    }
}

// Sets the ETag value for well-known endpoint responses, enabling conditional
// request testing.
//
public isolated function setWellKnownETag(string etagValue) {
    lock {
        wellKnownScript.etag = etagValue;
    }
}

// Sets the HTTP status code for a conditional well-known response when an
// If-None-Match header is present and matches the scripted ETag.
//
public isolated function setWellKnownConditionalOverride(int statusCode) {
    lock {
        wellKnownScript.conditionalStatus = statusCode;
    }
}

// A minimal, valid Task JSON body, for tests that don't care about the
// task's contents and just need something that decodes successfully.
//
public isolated function defaultTaskJson() returns json {
    return {id: "task-1", status: {state: "TASK_STATE_COMPLETED"}};
}

// Builds a Task JSON body with the specified task ID and state, wrapped in a
// JSON-RPC response envelope for use with setNextJsonResponse().
//
public isolated function taskJsonWithState(string taskId, string state) returns json {
    return {id: taskId, status: {state: state}};
}

// Builds a JSON-RPC-enveloped {"task": {...}} SSE data payload — the shape
// a real sendStreamingMessage response opens with per specification section
// 3.1.1 (the stream opens with a Task or a Message, then delivers zero or
// more status/artifact update events).
//
public isolated function taskJson(string taskId, string state = "TASK_STATE_SUBMITTED") returns string {
    return string `{"task":{"id":"${taskId}","status":{"state":"${state}"}}}`;
}

// Builds a bare {"message": {...}} SSE data payload — the
// other valid shape sendStreamingMessage can open with per specification
// section 3.1.1: a plain conversational reply with no task. Used to
// exercise the no-op reconnect-wrapping path, since a bare Message carries
// no taskId to resubscribe with.
//
public isolated function messageJson(string messageId) returns string {
    return string `{"message":{"messageId":"${messageId}","role":"ROLE_AGENT","parts":[{"text":"a direct reply"}]}}`;
}

// Builds a TaskStatusUpdateEvent SSE data payload, for tests scripting a
// status-update SSE event without repeating the shape inline. The HTTP+JSON
// binding sends a bare StreamResponse with no enclosing envelope.
//
public isolated function statusUpdateJson(string taskId, string state) returns string {
    return string `{"statusUpdate":{"taskId":"${taskId}","contextId":"ctx-1","status":{"state":"${state}"}}}`;
}

isolated function defaultMockAgentCard() returns json {
    AgentCard card = {
        name: "Mock Weather Agent",
        description: "A scripted mock agent used by Client tests",
        version: "1.0.0",
        // The mock answers GetExtendedAgentCard, so the card declares the
        // capability. This matters now that every Client holds a card:
        // getExtendedAgentCard short-circuits on a card declaring
        // extendedAgentCard=false, so a neutral fixture would silently stop
        // every extended-card test from ever reaching the wire. Same
        // reasoning extends pushNotifications=true (issue #11): every
        // client-side capability gate short-circuits on a card declaring
        // the capability false, so a neutral fixture would silently stop
        // every push-notification-config test from ever reaching the wire.
        capabilities: {streaming: true, pushNotifications: true, extendedAgentCard: true},
        // The client resolves this card over HTTP from the 19199 mock,
        // then dials the HTTP+JSON interface it declares — the same mock.
        //
        // No tenant is declared here on purpose: tenant auto-wiring is
        // exercised by tests that override the well-known card with one
        // that does declare it, so the common fixture stays neutral and
        // every other test's request params are unaffected.
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "HTTP+JSON", protocolVersion: "1.0"}
        ],
        skills: [
            {
                id: "weather-lookup",
                name: "Weather Lookup",
                description: "Reports current weather for a city",
                tags: []
            }
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    return card.toJson();
}

// Sends a response via the given caller, discarding any error instead of
// letting it propagate as the resource function's return value.
//
// Used for delayed responses (setNextDelay): when a test's client-side
// timeout fires first, the client has already closed the connection by
// the time this delayed respond() runs, so the write fails. Propagating
// that failure via `check` would make the resource function return an
// error, which the HTTP engine then tries to convert into its own error
// response on the same (already-attempted) exchange — logging a spurious
// "illegal return: response has already been sent" that reads like a
// real failure in test output. The client-side timeout is what the test
// actually asserts on; the server-side write failing afterward is
// expected and not actionable, so it's swallowed here rather than logged.
//
isolated function respondIgnoringClientGoneAway(http:Caller caller, http:Response res) {
    error? result = caller->respond(res);
    if result is error {
        // Deliberately ignored — see function doc above.
    }
}

service / on mockListener {
    resource function get \.well\-known/agent\-card\.json(http:Caller caller, http:Request req) returns error? {
        MockWellKnownScript wk;
        lock {
            wk = wellKnownScript.clone();
        }

        // Ensure default card has an ETag for conditional requests
        string etag;
        if wk.etag is string {
            etag = <string>wk.etag;
        } else if !wk.hasOverride {
            etag = DEFAULT_MOCK_CARD_ETAG;
        } else {
            etag = "";
        }

        // Check for conditional request (If-None-Match header)
        string|http:HeaderNotFoundError ifNoneMatch = req.getHeader("If-None-Match");
        if ifNoneMatch is string && wk.conditionalStatus is int && etag.length() > 0 && ifNoneMatch == etag {
            // Send conditional response (typically 304 Not Modified)
            http:Response res = new;
            res.statusCode = <int>wk.conditionalStatus;
            check caller->respond(res);
            return;
        }

        http:Response res = new;
        if wk.hasOverride {
            res.statusCode = wk.overrideStatus;
            res.setJsonPayload(wk.overrideBody);
        } else {
            res.statusCode = 200;
            res.setJsonPayload(defaultMockAgentCard());
        }
        if etag.length() > 0 {
            res.setHeader("ETag", etag);
        }
        check caller->respond(res);
    }

    // A minimal OAuth2 client_credentials token endpoint (RFC 6749 §4.4.3
    // shape), so tests exercising a real OAuth2ClientCredentialsGrantConfig
    // (e.g. testGrpcClientConstructsWithOAuth2ClientCredentialsAuth) have
    // somewhere genuine to fetch a token from — ballerina/oauth2's
    // ClientOAuth2Provider fetches eagerly at construction, not lazily, so
    // a fake/unreachable tokenUrl breaks client construction outright
    // rather than only a later call.
    resource function post oauth2\-token(http:Caller caller, http:Request req) returns error? {
        http:Response res = new;
        res.statusCode = 200;
        res.setJsonPayload({access_token: "mock-access-token", token_type: "Bearer", expires_in: 3600});
        check caller->respond(res);
    }

    resource function post .(http:Caller caller, http:Request req) returns error? {
        json body = check req.getJsonPayload();
        lock {
            lastRequestBody = body.clone();
        }

        // Header names are case-insensitive per HTTP semantics, but this
        // connection's actual wire casing varies with protocol negotiation.
        // Confirmed by logging req.getHeaderNames() directly: the client's
        // http:ClientConfiguration defaults httpVersion to "2.0" with
        // http2PriorKnowledge false (ballerina/http's own defaults -- not
        // anything this repo configures), so the first request on a fresh
        // connection is a plaintext HTTP/1.1 request carrying `Upgrade:
        // h2c`/`HTTP2-Settings` and preserves the sender's original header
        // casing (e.g. "A2A-Extensions"), while every subsequent request
        // reusing that same pooled, now-upgraded connection is real HTTP/2
        // framing, which came through with all-lowercase header names
        // (e.g. "a2a-extensions") -- consistent with HTTP/2 requiring
        // lowercase header field names on the wire. Normalizing to
        // lowercase here makes header assertions stable regardless of
        // which of those two cases a given test's request happens to hit.
        map<string> headers = {};
        foreach string headerName in req.getHeaderNames() {
            string|http:HeaderNotFoundError headerValue = req.getHeader(headerName);
            if headerValue is string {
                headers[headerName.toLowerAscii()] = headerValue;
            }
        }
        lock {
            lastRequestHeaders = headers.clone();
        }

        MockRpcScript script;
        lock {
            script = rpcScript.clone();
        }

        if script.delaySeconds > 0d {
            runtime:sleep(script.delaySeconds);
        }

        if script.isSse {
            // caller->respond() with a raw stream defaults POST responses
            // to 201; the Client checks for exactly 200, so set it explicitly.
            http:Response res = new;
            res.statusCode = 200;
            if script.simulateDropError {
                stream<http:SseEvent, error?> dropStream = new (new DropAfterEventsGenerator(script.sseEvents));
                res.setPayload(dropStream);
            } else {
                res.setPayload(script.sseEvents.toStream());
            }
            respondIgnoringClientGoneAway(caller, res);
        } else {
            http:Response res = new;
            res.statusCode = script.statusCode;
            res.setJsonPayload(script.jsonBody);
            respondIgnoringClientGoneAway(caller, res);
        }
    }

    // Method-agnostic catch-all for the REST/HTTP+JSON binding's
    // resources (e.g. /tasks/{id}, /tasks/{id}:cancel,
    // /tasks/{taskId}/pushNotificationConfigs). Confirmed empirically to
    // be the only mechanism that can express a `/tasks/{id}:cancel`-shaped
    // path: a resource path segment cannot combine a bracketed path-param
    // with an adjacent literal suffix like `:cancel`, so per-operation
    // resource routing isn't possible here. This 'default resource
    // matches any HTTP method not already matched by a more specific
    // resource above (e.g. the well-known card GET or the JSON-RPC root
    // POST), and yields the full raw path via the [string... path] rest
    // parameter.
    resource function 'default [string... path](http:Caller caller, http:Request req) returns error? {
        MockRestScript script;
        lock {
            script = restScript.clone();
        }
        map<string> queryParams = {};
        foreach string k in req.getQueryParams().keys() {
            string? v = req.getQueryParamValue(k);
            if v is string {
                queryParams[k] = v;
            }
        }
        // req.rawPath is the actual wire path (percent-encoding intact),
        // plus the query string; the [string... path] rest param, by
        // contrast, gives each segment already percent-decoded by the
        // routing layer, which would hide a real encoding bug (e.g. "/"
        // in a path param must arrive as "%2F", not a literal "/"). Strip
        // just the query string, keep everything else as sent.
        string rawPath = req.rawPath;
        int? qIdx = rawPath.indexOf("?");
        string fullPath = qIdx is int ? rawPath.substring(0, qIdx) : rawPath;
        // GET/DELETE requests never carry a body -- getJsonPayload() on a
        // bodiless request is an error, not a useful {} value, so this is
        // guarded rather than `check`ed; a genuinely malformed body on a
        // POST is likewise tolerated here (recorded as {}) since body
        // well-formedness isn't this mock's concern -- it exists to let
        // tests assert on what the Client sent, not to validate it.
        json|error parsedBody = req.getJsonPayload();
        json capturedBody = parsedBody is json ? parsedBody : {};
        // Same lowercasing rationale as the JSON-RPC handler above.
        map<string> headers = {};
        foreach string headerName in req.getHeaderNames() {
            string|http:HeaderNotFoundError headerValue = req.getHeader(headerName);
            if headerValue is string {
                headers[headerName.toLowerAscii()] = headerValue;
            }
        }
        lock {
            restScript.lastMethod = req.method;
            restScript.lastPath = fullPath;
            restScript.lastQueryParams = queryParams.clone();
            restScript.lastBody = capturedBody.clone();
            restScript.lastHeaders = headers.clone();
        }

        if script.rejectMethod is string && req.method == script.rejectMethod {
            http:Response rejectRes = new;
            rejectRes.statusCode = script.rejectStatusCode;
            lock {
                restScript.rejectMethod = ();
            }
            check caller->respond(rejectRes);
            return;
        }

        if script.rejectContentType is string && headers["content-type"] == script.rejectContentType {
            http:Response rejectRes = new;
            rejectRes.statusCode = script.rejectContentTypeStatusCode;
            lock {
                restScript.rejectContentType = ();
            }
            check caller->respond(rejectRes);
            return;
        }

        if script.delaySeconds > 0d {
            runtime:sleep(script.delaySeconds);
        }

        http:Response res = new;
        if script.isSse {
            // caller->respond() with a raw stream defaults POST responses
            // to 201; the Client checks for exactly 200, so set it explicitly.
            res.statusCode = 200;
            if script.simulateDropError {
                stream<http:SseEvent, error?> dropStream = new (new DropAfterEventsGenerator(script.sseEvents));
                res.setPayload(dropStream);
            } else {
                res.setPayload(script.sseEvents.toStream());
            }
            respondIgnoringClientGoneAway(caller, res);
        } else {
            res.statusCode = script.statusCode;
            if script.hasResponseBody {
                res.setJsonPayload(script.jsonBody);
            }
            check caller->respond(res);
        }
    }
}

// ---- Shared assertion helpers -----------------------------------------

// Unwraps a stream.next() result, failing the test immediately if the stream
// ended or returned an error where a value was expected.
public isolated function expectValue(record {| StreamResponse value; |}|error? result) returns StreamResponse|error {
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
}

public isolated function assertValidTask(Task task) {
    test:assertTrue(task.id.length() > 0, "Task.id should be non-empty");
}

public isolated function extractArtifactText(Artifact artifact) returns string? {
    foreach Part part in artifact.parts {
        string? text = part?.text;
        if text is string {
            return text;
        }
    }
    return ();
}
