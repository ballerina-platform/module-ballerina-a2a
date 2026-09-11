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

// A2A error types.


# Detail attached to every Error.
public type ErrorDetail record {|
    # Originating JSON-RPC code, preserved for diagnostics
    int code?;
    # Human-readable error message
    string message?;
    # Structured error details from the server
    json data?;
    json...;
|};

# Base type for every A2A protocol error.
#
# Distinct, so `is a2a:Error` matches any subtype and each subtype is
# distinguishable from its siblings the same way. The nine below are the
# canonical types of specification section 5.4.
public type Error distinct error<ErrorDetail>;

# The agent does not know the task the request named.
public type TaskNotFoundError distinct Error;

# The task exists but has reached a state it cannot be canceled from.
public type TaskNotCancelableError distinct Error;

# The agent does not support the operation, or its Agent Card declares the
# capability the operation needs as false.
public type UnsupportedOperationError distinct Error;

# The agent cannot produce or accept the media types the request asked for.
public type ContentTypeNotSupportedError distinct Error;

# The agent's response did not match the shape the operation expects.
public type InvalidAgentResponseError distinct Error;

# The agent does not speak the A2A protocol version this request used.
public type VersionNotSupportedError distinct Error;

# The agent does not support push notifications, so its webhook configuration
# operations are unavailable.
public type PushNotificationNotSupportedError distinct Error;

# The agent supports extended Agent Cards but has none configured to return.
public type ExtendedAgentCardNotConfiguredError distinct Error;

# The agent requires an A2A extension the request did not declare.
public type ExtensionSupportRequiredError distinct Error;

# This library's catch-all, for failures the A2A error taxonomy does not name.
#
# Specification section 5.4 lists nine canonical error types, and the nine
# above are exactly those. This one covers what is left:
#
# - a transport failure carrying no A2A error code
# - a malformed response that never reached an operation
# - a client-side precondition failure, caught before any request is sent
#
# Match one of the nine for a specific protocol condition; this one means
# something failed that the protocol does not describe.
public type InternalError distinct Error;

# Builds a client-side InvalidAgentResponseError with the same JSON-RPC
# code (-32006) `toA2AErrorFromRest` already uses for this case. Every
# "the agent's response doesn't parse into what this call expects" site in
# this library goes through this, rather than letting the underlying
# `cloneWithType`/`ensureType` failure propagate as a bare, untyped error.
#
# + message - What specifically failed to parse
# + return - A typed InvalidAgentResponseError
isolated function invalidAgentResponse(string message) returns InvalidAgentResponseError {
    return error InvalidAgentResponseError(message, message = message, code = -32006);
}

# Wraps a raw, untyped error (a connection failure from `ballerina/http`/
# `ballerina/grpc`, a mime-parsing failure, an unencodable parameter
# value, ...) into an InternalError, so no public method returns a
# bare `error` a caller cannot pattern-match against.
#
# Idempotent: an already-typed `a2a:Error` passes through unchanged, so this
# is safe to call at every boundary without knowing whether the error was
# already wrapped.
#
# The original message is folded into the new one rather than attached as a
# `cause`, which Ballerina does not accept once an error's detail type has
# named fields of its own.
#
# + e - The raw error to wrap, or an already-typed `a2a:Error` to pass through
# + return - `e` unchanged if it was already an `a2a:Error`, otherwise a new
#            `a2a:InternalError` carrying its message
isolated function wrapTransportError(error e) returns Error {
    if e is Error {
        return e;
    }
    string msg = string `Transport-level failure: ${e.message()}`;
    return error InternalError(msg, message = msg);
}

# Maps a REST binding error response onto the same Error hierarchy the
# JSON-RPC binding maps onto, so callers handle errors identically
# regardless of which binding their Client negotiated. HTTP status alone
# is not sufficient to disambiguate — seven distinct A2A errors all return
# 400 — so the discriminator is the `reason` field of a
# google.rpc.ErrorInfo entry inside the error body's `details` array, per
# the reference a2a-python SDK's REST error-parsing shape.
#
# + statusCode - The HTTP status code the response carried
# + body - The parsed JSON error body, if any (absent for e.g. a stream
#          drop with no body available)
# + return - The corresponding typed Error, with detail.code synthesized
#            to the equivalent JSON-RPC code so a caller checking
#            detail.code sees identical values regardless of binding
isolated function toA2AErrorFromRest(int statusCode, json? body) returns Error {
    string? reason = extractRestErrorReason(body);
    string message = extractRestErrorMessage(body) ?: string `REST request failed with HTTP ${statusCode}`;
    json? data = extractRestErrorMetadata(body);

    if reason is string {
        match reason {
            "TASK_NOT_FOUND" => {
                return error TaskNotFoundError(message, message = message, code = -32001, data = data);
            }
            "TASK_NOT_CANCELABLE" => {
                return error TaskNotCancelableError(message, message = message, code = -32002, data = data);
            }
            "PUSH_NOTIFICATION_NOT_SUPPORTED" => {
                return error PushNotificationNotSupportedError(message, message = message, code = -32003, data = data);
            }
            "UNSUPPORTED_OPERATION" => {
                return error UnsupportedOperationError(message, message = message, code = -32004, data = data);
            }
            "CONTENT_TYPE_NOT_SUPPORTED" => {
                return error ContentTypeNotSupportedError(message, message = message, code = -32005, data = data);
            }
            "INVALID_AGENT_RESPONSE" => {
                return error InvalidAgentResponseError(message, message = message, code = -32006, data = data);
            }
            "EXTENDED_AGENT_CARD_NOT_CONFIGURED" => {
                return error ExtendedAgentCardNotConfiguredError(message, message = message, code = -32007, data = data);
            }
            "EXTENSION_SUPPORT_REQUIRED" => {
                return error ExtensionSupportRequiredError(message, message = message, code = -32008, data = data);
            }
            "VERSION_NOT_SUPPORTED" => {
                return error VersionNotSupportedError(message, message = message, code = -32009, data = data);
            }
            "INVALID_PARAMS" => {
                return error InternalError(message, message = message, code = -32602, data = data);
            }
            "INVALID_REQUEST" => {
                return error InternalError(message, message = message, code = -32600, data = data);
            }
            "METHOD_NOT_FOUND" => {
                return error InternalError(message, message = message, code = -32601, data = data);
            }
            "INTERNAL_ERROR" => {
                return error InternalError(message, message = message, code = -32603, data = data);
            }
        }
    }

    // No usable ErrorInfo reason — fall back on status code alone.
    // No 404 shortcut. This point is only reached when the response carried
    // no ErrorInfo.reason, and a 404 from, say, a push-notification-config
    // path means the config is missing, not the task -- typing that as
    // TaskNotFoundError would send a caller down the wrong recovery. Both
    // reference servers do send the reason, so a conformant agent never
    // relies on this fallback.
    if statusCode >= 500 {
        return error InternalError(message, message = message, code = -32603, data = data);
    }
    return error InternalError(message, message = message, code = statusCode, data = data);
}

# Scans a REST error body's error.details array for the first
# google.rpc.ErrorInfo entry and returns its reason string, or () if the
# body has no usable ErrorInfo entry. json field access with an
# "@"-prefixed key ("@type") isn't valid dot-syntax, so this reads through
# a map<json> bracket index instead.
#
# + body - The parsed JSON error body, if any
# + return - The matching ErrorInfo entry as a map, or () if none is found
isolated function extractRestErrorDetail(json? body) returns map<json>? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? detailsJson = errMap["details"];
    if !(detailsJson is json[]) {
        return ();
    }
    foreach json detail in detailsJson {
        map<json>|error detailMap = detail.ensureType();
        if detailMap is map<json> {
            json? typeVal = detailMap["@type"];
            if typeVal is string && typeVal == "type.googleapis.com/google.rpc.ErrorInfo" {
                return detailMap;
            }
        }
    }
    return ();
}

isolated function extractRestErrorReason(json? body) returns string? {
    map<json>? detailMap = extractRestErrorDetail(body);
    if detailMap is () {
        return ();
    }
    json? reasonVal = detailMap["reason"];
    return reasonVal is string ? reasonVal : ();
}

isolated function extractRestErrorMessage(json? body) returns string? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? msg = errMap["message"];
    return msg is string ? msg : ();
}

isolated function extractRestErrorMetadata(json? body) returns json? {
    map<json>? detailMap = extractRestErrorDetail(body);
    return detailMap is () ? () : detailMap["metadata"];
}

# Builds the client-side rejection for a streaming call the held card says
# is unsupported. Carries the same UnsupportedOperationError type and JSON-RPC
# code (-32004) the server's own rejection would, so callers matching on
# `detail().code` see one case either way; the message says explicitly that
# this never reached the network, so a caller inspecting the error text (e.g.
# in logs) can still tell the two apart.
#
# + operation - The operation name, for the error text (e.g. "subscribeToTask")
# + return - A typed, client-side UnsupportedOperationError
isolated function streamingUnsupportedError(string operation) returns UnsupportedOperationError {
    string message = string `${operation}: AgentCard.capabilities.streaming is false - rejected client-side, no request sent`;
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a getExtendedAgentCard call the held
# AgentCard says the agent does not support.
#
# Specification section 3.3.4 requires exactly this: "If
# AgentCard.capabilities.extendedAgentCard is false or not present, attempts
# to call the Get Extended Agent Card operation MUST return
# UnsupportedOperationError." Sections 3.1.11 and 13.3 say the same, and
# nowhere does the specification sanction returning the public card instead
# -- section 3.1.11 defines the output as the extended card *when the
# operation is available*, not a substitute when it is not.
#
# + return - The typed rejection
isolated function extendedCardUnsupportedError() returns UnsupportedOperationError {
    string message = "getExtendedAgentCard: AgentCard.capabilities.extendedAgentCard is false "
        + "or not present - rejected client-side, no request sent";
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a push-notification-config call the
# held card says is unsupported. Same rationale as streamingUnsupportedError.
#
# + operation - The operation name, for the error text
# + return - A typed, client-side PushNotificationNotSupportedError
isolated function pushNotificationsUnsupportedError(string operation) returns PushNotificationNotSupportedError {
    string message = string `${operation}: AgentCard.capabilities.pushNotifications is false - rejected client-side, no request sent`;
    return error PushNotificationNotSupportedError(message, message = message, code = -32003);
}
