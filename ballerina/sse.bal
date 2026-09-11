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

// Stream decoding for the A2A client's SSE transport.
//
// A2aStreamGenerator is the raw decoder for the HTTP+JSON binding's SSE
// wire shape; ReconnectingStreamGenerator and SingleEventStreamGenerator
// wrap it with policy (reconnect-on-drop, single-event fallback) that has
// nothing to say about how the underlying values arrived, and so stay
// binding-agnostic for the transports still to come.

import ballerina/http;

# Wraps the standard library SSE event stream, decoding each event into a
# StreamResponse and closing the stream once a terminal task status is
# reached.
#
# + resp - The HTTP response opened with `Accept: text/event-stream`
# + return - A stream of decoded StreamResponse values
isolated function readSseStream(http:Response resp)
        returns stream<StreamResponse, Error?>|Error {
    stream<http:SseEvent, error?>|error sseStream = resp.getSseEventStream();
    if sseStream is error {
        return wrapTransportError(sseStream);
    }
    A2aStreamGenerator generator = new (sseStream);
    stream<StreamResponse, Error?> result = new (generator);
    return result;
}

# Iterates a raw SSE event stream, decoding each event into a
# StreamResponse. Stops once a terminal task status is reached; per
# design §8.1, a TaskArtifactUpdateEvent never closes the stream, and
# interrupted states (INPUT_REQUIRED, AUTH_REQUIRED) also do not close it.
class A2aStreamGenerator {
    private stream<http:SseEvent, error?> sseStream;
    private boolean closed = false;

    isolated function init(stream<http:SseEvent, error?> sseStream) {
        self.sseStream = sseStream;
    }

    # + return - The next event, `()` at end of stream, or an error
    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        if self.closed {
            return ();
        }

        while true {
            record {| http:SseEvent value; |}|error? chunk = self.sseStream.next();

            if chunk is () {
                self.closed = true;
                return ();
            }
            if chunk is error {
                self.closed = true;
                return wrapTransportError(chunk);
            }

            string? data = chunk.value.data;
            if data is () {
                // Comment / keep-alive frame — no payload, pull the next one
                continue;
            }

            // The HTTP+JSON binding signals a mid-stream error via a named
            // "error" SSE frame, whose data is a REST error payload — not a
            // StreamResponse at all.
            if chunk.value.'event == "error" {
                json|error errBody = data.fromJsonString();
                self.closed = true;
                return toA2AErrorFromRest(200, errBody is json ? errBody : ());
            }

            StreamResponse?|Error result = self.decodeEvent(data);
            if result is error {
                self.closed = true;
                return result;
            }
            if result is () {
                // An event carrying no arm this client recognizes -- a newer
                // specification revision can legitimately send one. Skip it
                // and read on rather than failing the whole stream.
                continue;
            }

            if isTerminalEvent(result) {
                self.closed = true;
            }
            return {value: result};
        }
    }

    # Decodes one StreamResponse arm, or `()` for an event this client does
    # not recognize.
    #
    # `()` is not a failure. StreamResponse is a specification `oneof`, and a
    # later revision may add an arm; a client that rejected the whole stream
    # on the first unrecognized event would break the moment that happened.
    # The caller skips these and reads on, which is what specification 5.7's
    # "SHOULD ignore unrecognized fields" asks for.
    #
    # + data - One raw SSE `data:` payload
    # + return - The decoded event, `()` to skip it, or an error
    private isolated function decodeEvent(string data) returns StreamResponse?|Error {
        // HTTP+JSON events carry a bare StreamResponse, with no enclosing
        // envelope.
        json|error envelope = data.fromJsonString();
        if envelope is error {
            return invalidAgentResponse(
                    string `SSE event payload is not valid JSON: ${envelope.message()}`);
        }
        json|error rewired = decodeRawBytesFromWire(envelope);
        if rewired is error {
            // decodeRawBytesFromWire already types the Part-variant failures;
            // anything else (a malformed base64 Part.raw) is still the agent's.
            return rewired is Error ? rewired
                : invalidAgentResponse(string `SSE event could not be decoded: ${rewired.message()}`);
        }
        return decodeStreamResponseEnvelope(rewired);
    }

    # + return - An error if the underlying stream could not be closed
    public isolated function close() returns error? {
        self.closed = true;
        return self.sseStream.close();
    }
}

# Wraps a unary sendMessage reply as a one-event StreamResponse stream, for
# sendStreamingMessage's capability-gated fallback per issue #11: when the
# held AgentCard says streaming is unsupported, the call degrades to a
# single unary request instead of opening (and having the server reject) an
# SSE connection. sendMessage already blocks until the task reaches a
# terminal state (or returns a Message with no task at all), so the lone
# event this yields is already the finished result - nothing further would
# ever arrive on a real stream either.
#
# + result - The unary sendMessage reply to wrap
# + return - A stream yielding exactly that one event, then closing
isolated function singleEventStream(Task|Message result) returns stream<StreamResponse, Error?> {
    // Task and Message are both arms of the StreamResponse union, so the
    // value needs no wrapping -- it already is a StreamResponse.
    return new (new SingleEventStreamGenerator(result));
}

# Yields one pre-built StreamResponse, then ends the stream cleanly. See
# singleEventStream.
class SingleEventStreamGenerator {
    private record {| StreamResponse value; |}? pending;

    isolated function init(StreamResponse value) {
        self.pending = {value};
    }

    # + return - The next event, `()` at end of stream, or an error
    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        record {| StreamResponse value; |}? p = self.pending;
        self.pending = ();
        return p;
    }

    # + return - An error if the underlying stream could not be closed
    public isolated function close() returns error? {
        self.pending = ();
    }
}

# The single capability `ReconnectingStreamGenerator` needs from the client
# that owns it: reopening a task subscription raw, without wrapping the result
# in another reconnect layer.
#
# An object type rather than a concrete class, so any transport client can
# hand itself to the generator.
type StreamReconnectable isolated object {
    isolated function openTaskSubscriptionStream(string taskId, string? tenant) returns stream<StreamResponse, Error?>|Error;
};

class ReconnectingStreamGenerator {
    private stream<StreamResponse, Error?> current;
    private final StreamReconnectable a2aClient;
    private final string taskId;
    // The per-call tenant override (if any) from the originating
    // sendStreamingMessage/subscribeToTask call. Must be threaded through to
    // the reconnect's openTaskSubscriptionStream call below — otherwise a
    // reconnect silently falls back to the client-level default tenant
    // (or no tenant), resubscribing under the wrong tenant in a
    // multi-tenant deployment.
    private final string? tenant;
    private final int maxAttempts;
    private int attemptsUsed = 0;
    private boolean done = false;
    // Wiring the taskId to resubscribe to (in sendStreamingMessage) requires
    // peeking the underlying stream's first event before construction —
    // that peeked value is buffered here and replayed as this generator's
    // own first result, so the caller never observes that a peek happened.
    private record {| StreamResponse value; |}? bufferedFirst;

    isolated function init(stream<StreamResponse, Error?> initial, StreamReconnectable a2aClient, string taskId, int maxAttempts, record {| StreamResponse value; |}? bufferedFirst = (), string? tenant = ()) {
        self.current = initial;
        self.a2aClient = a2aClient;
        self.taskId = taskId;
        self.maxAttempts = maxAttempts;
        self.bufferedFirst = bufferedFirst;
        self.tenant = tenant;
    }

    # + return - The next event, `()` at end of stream, or an error
    public isolated function next() returns record {| StreamResponse value; |}|Error? {
        if self.done {
            return ();
        }
        record {| StreamResponse value; |}? buffered = self.bufferedFirst;
        if buffered is record {| StreamResponse value; |} {
            self.bufferedFirst = ();
            return buffered;
        }
        record {| StreamResponse value; |}|error? raw = self.current.next();
        record {| StreamResponse value; |}|Error? result =
            raw is error ? wrapTransportError(raw) : raw;
        if result is error && self.attemptsUsed < self.maxAttempts {
            // Spend the whole budget. A reopen that fails is an attempt, not
            // the end of them -- with maxAttempts = 2 and a first reopen that
            // errors, the caller asked for a second and should get one.
            //
            // Deliberately calls the raw openTaskSubscriptionStream rather
            // than the public subscribeToTask: going through the remote
            // function would wrap each resubscribed stream in a fresh
            // generator with its own budget, so a persistently failing agent
            // would reconnect without bound instead of giving up.
            while self.attemptsUsed < self.maxAttempts {
                self.attemptsUsed += 1;
                stream<StreamResponse, Error?>|Error reconnected =
                    self.a2aClient.openTaskSubscriptionStream(self.taskId, self.tenant);
                if reconnected is stream<StreamResponse, Error?> {
                    // Best-effort close of the dropped stream before swapping
                    // in the reconnected one; failing to close changes nothing
                    // about the reconnect, so it is not surfaced.
                    error? closeResult = self.current.close();
                    if closeResult is error {
                        // ignored
                    }
                    self.current = reconnected;
                    return self.next();
                }
            }
            // Every attempt is spent. `result` still holds the original drop
            // error, which falls through below -- more useful to a caller than
            // the last resubscribe failure.
        }
        if result is () || result is error {
            self.done = true;
        }
        return result;
    }

    # + return - An error if the underlying stream could not be closed
    public isolated function close() returns error? {
        self.done = true;
        return self.current.close();
    }
}

# Wraps a freshly-opened stream so a dropped connection resubscribes
# automatically, when the owning client was configured for it.
#
# Finding the taskId to resubscribe against requires peeking the stream's
# first event, so that peeked value is buffered into the generator and
# replayed as its own first result - the caller never observes that a peek
# happened. A stream that opens with a bare Message carries nothing to
# reconnect against, so it is still wrapped, but with a zero attempt budget
# rather than being handed back raw; that keeps the peeked value spliced
# back on either way.
#
# Reconnection is a client-side policy over a stream of `a2a:StreamResponse`
# values, independent of how those values arrived.
#
# + rawStream - The stream just opened by the transport
# + owner - The client to resubscribe through on a drop
# + maxReconnectAttempts - The caller's configured attempt budget; zero or
#                          less returns rawStream untouched
# + tenant - The originating call's per-call tenant override, which must be
#            threaded through so a reconnect resubscribes under the same
#            tenant rather than falling back to the client-level default
# + return - The stream to hand the caller, or an error if the first event
#            was itself an error
isolated function wrapReconnecting(
        stream<StreamResponse, Error?> rawStream,
        StreamReconnectable owner,
        int maxReconnectAttempts,
        string? tenant) returns stream<StreamResponse, Error?>|Error {
    if maxReconnectAttempts <= 0 {
        return rawStream;
    }
    record {| StreamResponse value; |}|error? peeked = rawStream.next();
    if peeked is error {
        return wrapTransportError(peeked);
    }
    if peeked is () {
        stream<StreamResponse, Error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, owner, "", 0, tenant = tenant));
        return wrapped;
    }
    StreamResponse first = peeked.value;
    if first is Task {
        stream<StreamResponse, Error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, owner, first.id, maxReconnectAttempts, peeked, tenant));
        return wrapped;
    }
    // A stream can also legitimately open with a status update rather than
    // a Task (e.g. resubscribing to an already-created task), and that
    // update still carries a taskId worth reconnecting against.
    if first is TaskStatusUpdateEvent {
        stream<StreamResponse, Error?> wrapped =
            new (new ReconnectingStreamGenerator(rawStream, owner, first.taskId, maxReconnectAttempts, peeked, tenant));
        return wrapped;
    }
    stream<StreamResponse, Error?> wrapped =
        new (new ReconnectingStreamGenerator(rawStream, owner, "", 0, peeked, tenant));
    return wrapped;
}

# A stream terminates only on a status update carrying a terminal state.
#
# + event - The decoded stream event to inspect
# + return - True if this event should close the stream
isolated function isTerminalEvent(StreamResponse event) returns boolean {
    if event !is TaskStatusUpdateEvent {
        return false;
    }
    TaskState state = event.status.state;
    return state == TASK_STATE_COMPLETED
        || state == TASK_STATE_FAILED
        || state == TASK_STATE_CANCELED
        || state == TASK_STATE_REJECTED;
}

# Unwraps a protobuf `oneof` envelope into the single arm it carries.
#
# Several specification messages are `oneof`s whose arms serialize as a
# wrapper object keyed by the arm's own name — `SendMessageResponse` is
# `{"task": {...}}` or `{"message": {...}}`, `StreamResponse` adds
# `statusUpdate` and `artifactUpdate`. Exactly one arm is set in a
# conformant payload.
#
# Presence is decided by member presence, not by a non-nil value, because
# that is what the specification says the discriminator is
# (`specification.md`, "member presence acts as discriminator"). Testing for
# a non-nil value instead would misread a legitimately-null arm as absent.
#
# + envelope - The raw envelope object
# + arms - The arm names this caller understands, in specification order
# + return - The matched arm's name and payload; `()` when the envelope
#            carries no arm this caller recognizes, which a newer
#            specification revision can legitimately produce; or an
#            InvalidAgentResponseError when more than one arm is set
isolated function oneofArm(json envelope, string[] arms) returns [string, json]?|Error {
    map<json>|error asMap = envelope.ensureType();
    if asMap is error {
        return invalidAgentResponse(
                string `expected a oneof envelope object, found ${(typeof envelope).toString()}`);
    }
    string[] present = from string arm in arms
        where asMap.hasKey(arm)
        select arm;
    if present.length() > 1 {
        return invalidAgentResponse(
                string `oneof envelope set more than one arm: ${string:'join(", ", ...present)}`);
    }
    if present.length() == 0 {
        return ();
    }
    return [present[0], asMap.get(present[0])];
}

# Decodes one StreamResponse envelope into its single arm.
#
# + envelope - The raw `{"task": {...}}` / `{"statusUpdate": {...}}` object
# + return - The decoded arm; `()` when the envelope carries no arm this
#            client recognizes, so the caller can skip the event and read
#            on; or an InvalidAgentResponseError if the arm's payload does
#            not match its type
isolated function decodeStreamResponseEnvelope(json envelope) returns StreamResponse?|Error {
    [string, json]? arm = check oneofArm(
            envelope, ["task", "message", "statusUpdate", "artifactUpdate"]);
    if arm is () {
        return ();
    }
    [string, json] [name, payload] = arm;
    anydata|error decoded;
    match name {
        "task" => {
            decoded = payload.cloneWithType(Task);
        }
        "message" => {
            decoded = payload.cloneWithType(Message);
        }
        "statusUpdate" => {
            decoded = payload.cloneWithType(TaskStatusUpdateEvent);
        }
        _ => {
            decoded = payload.cloneWithType(TaskArtifactUpdateEvent);
        }
    }
    if decoded is error {
        return invalidAgentResponse(
                string `stream event "${name}" did not match the expected shape: ${decoded.message()}`);
    }
    // A Task arriving as a stream event gets the same semantic validation as
    // one returned from getTask or listTasks.
    if decoded is Task {
        check validateInboundTask(decoded);
    }
    return <StreamResponse>decoded;
}
