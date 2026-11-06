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

// The server's outbound error serialization: the inverse of the client's
// `toA2AErrorFromRest`. An `a2a:Error` becomes an HTTP status plus a
// `google.rpc.Status` body carrying an `ErrorInfo.reason`, which is exactly
// the shape the client decodes -- so a client of this library and this
// library's server agree on the wire by construction.

import ballerina/http;

# The HTTP status and google.rpc reason for one A2A error type.
type ErrorBinding record {|
    # The HTTP status code to respond with
    int status;
    # The google.rpc ErrorInfo reason string
    string reason;
|};

# Maps each Error subtype to its HTTP status and ErrorInfo.reason, per
# [specification section 11.6](https://a2a-protocol.org/latest/specification/#116-error-handling). The reasons are the same strings
# `toA2AErrorFromRest` decodes; keeping the two in one module is what makes
# the round trip symmetrical.
#
# + err - The error to classify
# + return - The status and reason to serialise it as
isolated function errorBindingFor(Error err) returns ErrorBinding {
    if err is TaskNotFoundError {
        return {status: http:STATUS_NOT_FOUND, reason: "TASK_NOT_FOUND"};
    }
    if err is TaskNotCancelableError {
        return {status: http:STATUS_BAD_REQUEST, reason: "TASK_NOT_CANCELABLE"};
    }
    if err is PushNotificationNotSupportedError {
        return {status: http:STATUS_BAD_REQUEST, reason: "PUSH_NOTIFICATION_NOT_SUPPORTED"};
    }
    if err is UnsupportedOperationError {
        return {status: http:STATUS_BAD_REQUEST, reason: "UNSUPPORTED_OPERATION"};
    }
    if err is ContentTypeNotSupportedError {
        return {status: http:STATUS_BAD_REQUEST, reason: "CONTENT_TYPE_NOT_SUPPORTED"};
    }
    if err is InvalidAgentResponseError {
        // Specification section 5.4's own table actually gives this,
        // TaskNotCancelableError and ContentTypeNotSupportedError each
        // their own non-400 status -- 502, 409 and 415 respectively --
        // alongside TaskNotFoundError's 404. This deliberately returns 400
        // for all three instead (see those errors' own bindings, above):
        // every reference SDK checked (`a2a-sdk` 1.1.2's own
        // A2A_ERROR_MAPPING, `a2a-go`'s internal/rest/rest.go, and
        // `@a2a-js/sdk`'s REST_ERROR_HTTP_STATUS) does the same, so this
        // follows the ecosystem's actual practice over the spec's own text
        // here, not an oversight -- confirmed directly against all three
        // sources, not assumed. a2a-java's REST mapping has not been
        // checked.
        return {status: http:STATUS_INTERNAL_SERVER_ERROR, reason: "INVALID_AGENT_RESPONSE"};
    }
    if err is ExtendedAgentCardNotConfiguredError {
        // Per the same table: this is the server's own configuration --
        // no extended card was set up -- not the absence of a resource
        // named by the request.
        return {status: http:STATUS_BAD_REQUEST, reason: "EXTENDED_AGENT_CARD_NOT_CONFIGURED"};
    }
    if err is ExtensionSupportRequiredError {
        return {status: http:STATUS_BAD_REQUEST, reason: "EXTENSION_SUPPORT_REQUIRED"};
    }
    if err is VersionNotSupportedError {
        return {status: http:STATUS_BAD_REQUEST, reason: "VERSION_NOT_SUPPORTED"};
    }
    // Not among the nine of section 5.4, but section 5.x gives 401 and 403 as the
    // binding-specific forms of an authentication and an authorization error.
    if err is AuthenticationError {
        return {status: http:STATUS_UNAUTHORIZED, reason: "UNAUTHENTICATED"};
    }
    if err is AuthorizationError {
        return {status: http:STATUS_FORBIDDEN, reason: "PERMISSION_DENIED"};
    }
    // InternalError is also how this library carries the standard JSON-RPC
    // "the request itself was bad" codes (see `invalidRequest`, `invalidParams`,
    // `methodNotFound`); those are the caller's fault, so they are a 4xx with
    // their own reason, not a 500.
    int? code = err.detail()?.code;
    if code == -32600 {
        return {status: http:STATUS_BAD_REQUEST, reason: "INVALID_REQUEST"};
    }
    if code == -32602 {
        return {status: http:STATUS_BAD_REQUEST, reason: "INVALID_PARAMS"};
    }
    if code == -32601 {
        return {status: http:STATUS_NOT_FOUND, reason: "METHOD_NOT_FOUND"};
    }
    // Anything else the protocol does not name.
    return {status: http:STATUS_INTERNAL_SERVER_ERROR, reason: "INTERNAL_ERROR"};
}

# Builds the `google.rpc.Status` body for an `a2a:Error`: the shape both
# `toRestErrorResponse` (a plain HTTP error response) and the SSE
# framing layer's `event: error` frame (a mid-stream failure, framed as
# data rather than an HTTP status) carry identically -- the client's
# `extractRestErrorReason`/`extractRestErrorMessage` read either the same
# way.
#
# + err - The error to serialise
# + return - The body, keyed the same regardless of transport
isolated function restErrorBody(Error err) returns json {
    ErrorBinding binding = errorBindingFor(err);
    return rpcStatusBody(binding.status, err.message(), binding.reason, err.detail()?.data, fieldViolationsOf(err));
}

# Builds the `google.rpc.Status` body from its parts. The one place the
# shape is written down, so an `a2a:Error` and an authentication rejection
# (which is not an `a2a:Error`) cannot drift apart.
#
# A validation error that names its field also gets a `google.rpc.BadRequest`
# entry, which [specification section 11.6](https://a2a-protocol.org/latest/specification/#116-error-handling)
# says implementations SHOULD use "to attach structured data to validation
# errors". It goes after the `ErrorInfo` entry; clients find each by its
# `@type`, never by position.
#
# + status - The HTTP status the response carries
# + message - The human-readable message
# + reason - The `ErrorInfo.reason` string
# + data - Optional structured detail, carried as `ErrorInfo.metadata`
# + fieldViolations - Optional `{field, description}` entries for a `BadRequest` detail
# + return - The body
isolated function rpcStatusBody(int status, string message, string reason, json? data = (),
        json[]? fieldViolations = ()) returns json {
    map<json> errorInfo = {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": reason,
        "domain": "a2a-protocol.org"
    };
    if data != () {
        errorInfo["metadata"] = data;
    }
    json[] details = [errorInfo];
    if fieldViolations is json[] && fieldViolations.length() > 0 {
        details.push({
            "@type": "type.googleapis.com/google.rpc.BadRequest",
            "fieldViolations": fieldViolations
        });
    }
    return {
        "error": {
            "code": status,
            "message": message,
            "details": details
        }
    };
}

# Serialises an `a2a:Error` into an `http:Response`: the mapped status and a
# `google.rpc.Status` body with an `ErrorInfo` entry in `details`.
#
# The body shape matches what `extractRestErrorReason`/`extractRestErrorMessage`
# on the client side read, so a round trip preserves the error type.
#
# + err - The error to serialise
# + return - The HTTP response carrying it
isolated function toRestErrorResponse(Error err) returns http:Response {
    http:Response response = new;
    response.statusCode = errorBindingFor(err).status;
    response.setJsonPayload(restErrorBody(err), CONTENT_TYPE_A2A_JSON);
    return response;
}

# Builds the response for a request that was not admitted.
#
# Not an `a2a:Error`: the specification has no A2A error type for it. Section
# 5.4 names HTTP 401 and gRPC `UNAUTHENTICATED` for a missing or invalid
# credential, and requires an authorization error when the caller lacks a
# permission -- so the body is the same `google.rpc.Status` shape every other
# error uses, with those reasons. The message is deliberately generic: it must
# not reveal whether a resource exists ("MUST NOT reveal the existence of
# resources the client is not authorized to access").
#
# A 403 names the scopes that would have admitted the caller, in the message
# and as `ErrorInfo.metadata.requiredScopes`: section 3.3.2 says servers SHOULD
# "indicate what permission or scope is missing". They are the listener's own
# configured scopes, the same for every request, so they reveal nothing about
# any resource.
#
# + failure - Why the request was not admitted
# + challenges - The `WWW-Authenticate` values a 401 carries
# + return - The response
isolated function toAuthErrorResponse(AuthFailure failure, string[] challenges) returns http:Response {
    http:Response response = new;
    if failure.forbidden {
        string[] scopes = failure.requiredScopes;
        string message = "The authenticated caller is not permitted to perform this operation";
        json? metadata = ();
        if scopes.length() > 0 {
            message = string `The authenticated caller lacks a required scope: `
                + string `this operation requires one of: ${", ".'join(...scopes)}`;
            metadata = {"requiredScopes": ", ".'join(...scopes)};
        }
        response.statusCode = http:STATUS_FORBIDDEN;
        response.setJsonPayload(rpcStatusBody(http:STATUS_FORBIDDEN, message, "PERMISSION_DENIED", metadata),
                CONTENT_TYPE_A2A_JSON);
        return response;
    }
    response.statusCode = http:STATUS_UNAUTHORIZED;
    foreach string challenge in challenges {
        response.addHeader("WWW-Authenticate", challenge);
    }
    response.setJsonPayload(rpcStatusBody(http:STATUS_UNAUTHORIZED,
            "Missing or invalid credentials", "UNAUTHENTICATED"), CONTENT_TYPE_A2A_JSON);
    return response;
}
