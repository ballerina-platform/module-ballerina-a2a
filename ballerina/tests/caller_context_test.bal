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

// The `a2a:CallerContext` a `TaskOwnerResolver` receives: transport-free, and
// carrying the identity authentication already established, so a resolver
// never re-parses the credential the listener just verified.

import ballerina/http;
import ballerina/test;

const int CALLER_CONTEXT_TEST_PORT = 19265;

isolated CallerContext? lastCallerContext = ();

// Records what it was given, and scopes by the authenticated identity.
isolated class RecordingOwnerResolver {
    *TaskOwnerResolver;

    public isolated function resolveOwner(CallerContext context) returns string?|Error {
        lock {
            lastCallerContext = context.clone();
        }
        return context?.identity;
    }
}

final DefaultHandler callerContextHandler = new (authTestCard, ownerResolver = new RecordingOwnerResolver());

listener HttpListener callerContextListener = new (CALLER_CONTEXT_TEST_PORT, callerContextHandler,
    auth = [{jwtValidatorConfig: authTestJwtValidator}]
);

@test:BeforeSuite
function startCallerContextServer() returns error? {
    check callerContextListener.attach(new CountingAgent());
}

isolated function recordedCallerContext() returns CallerContext? {
    lock {
        return lastCallerContext.clone();
    }
}

@test:Config {}
function testResolverReceivesTheAuthenticatedIdentity() returns error? {
    string token = check bearerToken("alice");
    json body = {"message": {"messageId": "m-caller-context", "role": "ROLE_USER", "parts": [{"text": "hi"}]}};
    http:Response response = check authCall(CALLER_CONTEXT_TEST_PORT, "POST", "/message:send",
            string `Bearer ${token}`, body, {"X-Api-Key": "key-1"});
    test:assertEquals(response.statusCode, 200);

    CallerContext? recorded = recordedCallerContext();
    test:assertTrue(recorded is CallerContext, "the resolver was never called");
    CallerContext seen = <CallerContext>recorded;
    test:assertEquals(seen?.identity, "alice");
    test:assertEquals(seen.headers["x-api-key"], ["key-1"]);
    test:assertEquals(seen?.tenant, ());
    test:assertEquals(seen?.clientCertificateBase64, ());
}

@test:Config {}
function testCallerContextOfLowerCasesHeaderNamesAndKeepsEveryValue() {
    http:Request request = new;
    request.setHeader("X-Api-Key", "k1");
    request.addHeader("Accept", "text/plain");
    request.addHeader("Accept", "application/json");

    CallerContext context = callerContextOf(request, "bob", "acme");
    test:assertEquals(context?.identity, "bob");
    test:assertEquals(context?.tenant, "acme");
    test:assertEquals(context.headers["x-api-key"], ["k1"]);
    test:assertEquals(context.headers["accept"], ["text/plain", "application/json"]);
    test:assertFalse(context.headers.hasKey("X-Api-Key"));
}

@test:Config {}
function testCallerContextOfPassesACertificateOnlyFromAPassedHandshake() {
    http:Request passed = new;
    passed.mutualSslHandshake = {status: http:PASSED, base64EncodedCert: "Y2VydA=="};
    test:assertEquals(callerContextOf(passed, (), ())?.clientCertificateBase64, "Y2VydA==");

    http:Request failed = new;
    failed.mutualSslHandshake = {status: http:FAILED, base64EncodedCert: "Y2VydA=="};
    test:assertEquals(callerContextOf(failed, (), ())?.clientCertificateBase64, ());

    http:Request plain = new;
    test:assertEquals(callerContextOf(plain, (), ())?.clientCertificateBase64, ());
}
