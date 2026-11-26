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


// A service attached to a `JsonRpcListener` is checked when it is attached: a remote function that is not an A2A method,
// or that takes or returns the wrong types, is refused with what is wrong, and not left to fail on its first request.

import ballerina/test;

isolated function noOp() returns Error => error InternalError("not used");

isolated function noOpInternal() returns InternalError => error InternalError("not used");

isolated service class TypoService {
    *Service;

    isolated remote function sendMesage(Context context, SendMessageRequest request) returns Task|Message|Error => noOp();

    isolated remote function getTasks(GetTaskRequest request) returns Task|Error => noOp();
}

isolated service class WrongRequestService {
    *Service;

    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error => noOp();

    isolated remote function getTask(SendMessageRequest request) returns Task|Error => noOp();
}

isolated service class WrongReturnService {
    *Service;

    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error => noOp();

    isolated remote function getTask(GetTaskRequest request) returns string => "not a task";
}

isolated service class PlainErrorService {
    *Service;

    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|error => noOp();
}

isolated service class ExtraParameterService {
    *Service;

    isolated remote function sendMessage(SendMessageRequest request, string extra) returns Task|Message|Error => noOp();
}

// Narrower returns and any order of the parameters are fine.
isolated service class NarrowerService {
    *Service;

    isolated remote function sendMessage(SendMessageRequest request, Context context) returns Task|TaskNotFoundError {
        return error TaskNotFoundError("none", message = "none");
    }

    isolated remote function getTask(Context context, GetTaskRequest request) returns Task|InternalError => noOpInternal();

    isolated remote function getAgentCard() returns AgentCard => rpcTestCard;
}

function attachError(Service agent, int port) returns string|error {
    JsonRpcListener rpcListener = check new (port);
    Error? rejected = rpcListener.attach(agent);
    return rejected is Error ? rejected.message() : "attached";
}

@test:Config {}
function testATypoedRemoteFunctionIsNamedWithWhatItWasMeantToBe() returns error? {
    string message = check attachError(new TypoService(), 19351);
    test:assertTrue(message.includes("\"sendMesage\" is not an A2A method; did you mean \"sendMessage\"?"), message);
    test:assertTrue(message.includes("\"getTasks\" is not an A2A method; did you mean \"getTask\"?"), message);
    test:assertFalse(message.includes("must define"), "the typo is the cause, not the missing method: " + message);
}

@test:Config {}
function testARemoteFunctionThatTakesTheWrongRequestIsRefusedWhenAttached() returns error? {
    string message = check attachError(new WrongRequestService(), 19352);
    test:assertTrue(message.includes("getTask: parameter 'request' has type"), message);
    test:assertTrue(message.includes("SendMessageRequest"), message);
}

@test:Config {}
function testARemoteFunctionThatReturnsTheWrongTypeIsRefusedWhenAttached() returns error? {
    string message = check attachError(new WrongReturnService(), 19353);
    test:assertTrue(message.includes("getTask: returns string"), message);
}

@test:Config {}
function testAPlainErrorReturnIsRefusedBecauseItIsNotAnA2aError() returns error? {
    string message = check attachError(new PlainErrorService(), 19354);
    test:assertTrue(message.includes("sendMessage: returns"), message);
}

@test:Config {}
function testAnExtraParameterIsRefused() returns error? {
    string message = check attachError(new ExtraParameterService(), 19355);
    test:assertTrue(message.includes("sendMessage: parameter 'extra' has type string"), message);
}

@test:Config {}
function testNarrowerReturnsAndAnyParameterOrderAreAccepted() returns error? {
    test:assertEquals(check attachError(new NarrowerService(), 19357), "attached");
}

@test:Config {}
function testTheClosestMethodNameIsOnlyOfferedForARealTypo() {
    string[] known = OPERATION_REMOTE_NAMES.toArray();
    test:assertEquals(closestName("sendMesage", known), "sendMessage");
    test:assertEquals(closestName("getTasks", known), "getTask");
    test:assertEquals(closestName("helperThatIsNotAMethod", known), ());
    test:assertEquals(editDistance("kitten", "sitting"), 3);
    test:assertEquals(editDistance("", "abc"), 3);
    test:assertEquals(editDistance("same", "same"), 0);
}
