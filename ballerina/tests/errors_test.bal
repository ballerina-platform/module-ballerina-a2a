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

// Regression test: Error's subtypes must be nominally distinct (declared
// with `distinct`), not plain aliases for `error<ErrorDetail>`. Without
// `distinct`, every subtype is structurally identical and `is` checks
// between siblings are always true regardless of which error was actually
// constructed — which would let every mapping test below pass for the
// wrong reason.
@test:Config {}
function testA2AErrorSubtypesAreMutuallyDistinguishable() {
    Error taskNotFound = toA2AErrorFromRest(404, {
        "error": {
            "message": "Task not found",
            "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND"}]
        }
    });

    test:assertTrue(taskNotFound is Error, "every subtype must still satisfy the common base type");
    test:assertTrue(taskNotFound is TaskNotFoundError, "should be its own mapped type");
    test:assertFalse(taskNotFound is PushNotificationNotSupportedError, "must not match an unrelated sibling type");
    test:assertFalse(taskNotFound is InternalError, "must not match an unrelated sibling type");
}

@test:Config {}
function testToA2AErrorFromRestMapsTaskNotCancelableByReason() returns error? {
    json body = {
        "error": {
            "message": "task already completed",
            "details": [
                {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE", "metadata": {}}
            ]
        }
    };
    Error err = toA2AErrorFromRest(400, body);
    test:assertTrue(err is TaskNotCancelableError, "reason TASK_NOT_CANCELABLE must map to the typed TaskNotCancelableError, not fall back to a generic 400 error");
    test:assertEquals(err.detail().code, -32002, "the synthesized JSON-RPC code must match what the same error would carry over the JSON-RPC binding, so callers checking detail.code see identical behavior regardless of binding");
}

@test:Config {}
function testToA2AErrorFromRestDisambiguatesThreeDistinct400s() returns error? {
    json cancelBody = {"error": {"message": "m1", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_CANCELABLE"}]}};
    json unsupportedBody = {"error": {"message": "m2", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "UNSUPPORTED_OPERATION"}]}};
    json versionBody = {"error": {"message": "m3", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "VERSION_NOT_SUPPORTED"}]}};
    test:assertTrue(toA2AErrorFromRest(400, cancelBody) is TaskNotCancelableError);
    test:assertTrue(toA2AErrorFromRest(400, unsupportedBody) is UnsupportedOperationError);
    test:assertTrue(toA2AErrorFromRest(400, versionBody) is VersionNotSupportedError);
}

@test:Config {}
function testToA2AErrorFromRestMapsAllNineReasons() returns error? {
    // Keyed by the numeric JSON-RPC code each reason must map to — the
    // actual signal callers branch on — rather than a type-name string
    // discarded by the loop, so this genuinely fails if any reason falls
    // through to the wrong mapping or the generic fallback.
    map<int> reasonToExpectedCode = {
        "TASK_NOT_FOUND": -32001,
        "TASK_NOT_CANCELABLE": -32002,
        "PUSH_NOTIFICATION_NOT_SUPPORTED": -32003,
        "UNSUPPORTED_OPERATION": -32004,
        "CONTENT_TYPE_NOT_SUPPORTED": -32005,
        "INVALID_AGENT_RESPONSE": -32006,
        "EXTENDED_AGENT_CARD_NOT_CONFIGURED": -32007,
        "EXTENSION_SUPPORT_REQUIRED": -32008,
        "VERSION_NOT_SUPPORTED": -32009
    };
    foreach [string, int] [reason, expectedCode] in reasonToExpectedCode.entries() {
        json body = {"error": {"message": "m", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": reason}]}};
        Error err = toA2AErrorFromRest(400, body);
        test:assertEquals(err.detail().code, expectedCode, "reason " + reason + " should map to code " + expectedCode.toString());
    }
}

@test:Config {}
function testToA2AErrorFromRestFallsBackToStatusWhenNoErrorInfo() returns error? {
    // A reason-less 404 is not evidence that a *task* is missing -- the same
    // status comes back when a push-notification config is. Without an
    // ErrorInfo.reason there is nothing to type it with, so it stays
    // InternalError carrying the status.
    Error notFound = toA2AErrorFromRest(404, ());
    test:assertFalse(notFound is TaskNotFoundError,
            "a reason-less 404 must not claim the task is missing; it could be any resource on the path");
    test:assertTrue(notFound is InternalError);
    test:assertEquals(notFound.detail().code, 404);
    Error serverErr = toA2AErrorFromRest(503, ());
    test:assertTrue(serverErr is InternalError);
    test:assertEquals(serverErr.detail().code, -32603);
    Error otherErr = toA2AErrorFromRest(418, ());
    test:assertTrue(otherErr is InternalError);
    test:assertEquals(otherErr.detail().code, 418, "an unmapped status with no ErrorInfo should preserve the raw HTTP status in detail.code, not synthesize a JSON-RPC code that doesn't apply");
}

@test:Config {}
function testToA2AErrorFromRestAttachesMetadataAsData() returns error? {
    json body = {
        "error": {
            "message": "not found",
            "details": [
                {"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "metadata": {"taskId": "abc-123"}}
            ]
        }
    };
    Error err = toA2AErrorFromRest(404, body);
    test:assertEquals(err.detail()?.data, {"taskId": "abc-123"});
}

// A request the server cannot accept is the caller's fault: a 400 with its own
// reason, and the client reads the same body back as an InternalError carrying
// the same JSON-RPC code. An InternalError with any other code stays a 500.
@test:Config {}
function testInvalidRequestIsA400AndRoundTripsToTheSameCode() {
    ErrorBinding binding = errorBindingFor(invalidRequest("body is not valid JSON"));
    test:assertEquals(binding.status, 400);
    test:assertEquals(binding.reason, "INVALID_REQUEST");

    int? code = toA2AErrorFromRest(400, restErrorBody(invalidRequest("bad"))).detail()?.code;
    test:assertEquals(code, -32600, "the client must decode the server's body back to the same code");

    ErrorBinding invalidParamsBinding = errorBindingFor(error InternalError("x", message = "x", code = -32602));
    test:assertEquals(invalidParamsBinding.status, 400);
    test:assertEquals(invalidParamsBinding.reason, "INVALID_PARAMS");

    // An unknown route is the caller's mistake too: a 404, decoded back by the client.
    ErrorBinding notFound = errorBindingFor(methodNotFound("no A2A operation at GET /nope"));
    test:assertEquals(notFound.status, 404);
    test:assertEquals(notFound.reason, "METHOD_NOT_FOUND");
    int? notFoundCode = toA2AErrorFromRest(404, restErrorBody(methodNotFound("x"))).detail()?.code;
    test:assertEquals(notFoundCode, -32601, "the client must decode the server's body back to the same code");

    ErrorBinding badParams = errorBindingFor(invalidParams("bad tenant"));
    test:assertEquals(badParams.status, 400);
    test:assertEquals(badParams.reason, "INVALID_PARAMS");

    ErrorBinding other = errorBindingFor(error InternalError("boom", message = "boom", code = -32603));
    test:assertEquals(other.status, 500, "an ordinary internal failure must stay a 500");
    ErrorBinding noCode = errorBindingFor(error InternalError("boom", message = "boom"));
    test:assertEquals(noCode.status, 500);
}
