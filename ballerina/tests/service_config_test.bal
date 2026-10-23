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


// How a service reaches the wire: the path that names its binding, where its
// agent card comes from, which operations it defines and what the card says as
// a result, an operation it does not define, and a service shared by two
// listeners.

import ballerina/http;
import ballerina/test;

const int RPC_REJECTION_PORT = 19268;
const int DECLARATIVE_PORT_A = 19270;
const int DECLARATIVE_PORT_B = 19271;
const int ATTACH_RULES_PORT = 19273;
const int CAPABILITY_FULL_PORT = 19274;
const int CAPABILITY_MESSAGE_ONLY_PORT = 19275;
const int CAPABILITY_NO_STREAMING_PORT = 19276;
const int CAPABILITY_NO_PUSH_PORT = 19277;
const int CARD_FROM_FUNCTION_PORT = 19278;

// ---- reading the annotation ----------------------------------------------

@ServiceConfig {
    agentCard: {
        name: "Annotated Agent",
        description: "Declares its card with the annotation",
        version: "1.0.0",
        skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service class AnnotatedService {
    *Service;

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return error InternalError("not used");
    }
}

@test:Config {}
function testServiceConfigIsReadFromAServiceClass() {
    ServiceConfiguration? config = serviceConfigurationOf(new AnnotatedService());
    test:assertTrue(config is ServiceConfiguration);
    test:assertEquals((<ServiceConfiguration>config).agentCard.name, "Annotated Agent");
}

@test:Config {}
function testServiceWithoutConfigHasNone() {
    test:assertTrue(serviceConfigurationOf(new MessageOnlyService(new DefaultHandler(new CountingAgent()),
            authTestCard)) is ());
}

// ---- the path names the binding -------------------------------------------

@test:Config {}
function testRestPathNamesTheRestBinding() returns error? {
    test:assertEquals(check mountPathOf(["rest"]), "rest");
    test:assertEquals(check mountPathOf("rest"), "rest");
    test:assertEquals(check mountPathOf("/rest"), "rest");
}

@test:Config {}
function testOnlyTheRestPathIsServedAndTheOthersAreRefused() {
    string|Error rpc = mountPathOf(["rpc"]);
    test:assertTrue(rpc is InternalError);
    test:assertTrue((<Error>rpc).message().includes("/rest"), (<Error>rpc).message());

    string|Error unknown = mountPathOf(["weather"]);
    test:assertTrue(unknown is InternalError);
    test:assertTrue((<Error>unknown).message().includes("/rest"), (<Error>unknown).message());

    test:assertEquals(mountPathOf(()), "rest", "a service is declared without a path");
    test:assertEquals(mountPathOf(["rest"]), "rest");
}

// ---- attach rules ---------------------------------------------------------

isolated function attachRulesListener() returns RestListener|error => new (ATTACH_RULES_PORT);

isolated function attachRulesHandler() returns DefaultHandler => new (new CountingAgent());

@test:Config {}
function testAttachRefusesAPathOtherThanRestWithoutServingAnything() returns error? {
    RestListener agentListener = check attachRulesListener();
    error? rejected = agentListener.attach(new FullService(attachRulesHandler(), authTestCard), "rpc");
    test:assertTrue(rejected is InternalError, "a RestListener serves /rest only: attaching /rpc must fail");
    test:assertTrue((<error>rejected).message().includes("/rest"), (<error>rejected).message());
    // The refused attach must not have used up the path.
    check agentListener.attach(new FullService(attachRulesHandler(), authTestCard), "rest");
}

@test:Config {}
function testAttachRefusesAServiceWithoutSendMessage() returns error? {
    RestListener agentListener = check attachRulesListener();
    error? rejected = agentListener.attach(new GetTaskOnlyService(attachRulesHandler(), authTestCard), "rest");
    test:assertTrue(rejected is InternalError);
    test:assertTrue((<error>rejected).message().includes("message:send"), (<error>rejected).message());
}

@test:Config {}
function testAttachRefusesHalfAGroupOfOperations() returns error? {
    RestListener agentListener = check attachRulesListener();
    error? rejected = agentListener.attach(new HalfStreamingService(attachRulesHandler(), authTestCard), "rest");
    test:assertTrue(rejected is InternalError, "streaming is one capability: both operations or neither");
    test:assertTrue((<error>rejected).message().includes("tasks/*/subscribe"), (<error>rejected).message());
}

@test:Config {}
function testAttachRefusesAServiceWithNoCardOrTwo() returns error? {
    RestListener agentListener = check attachRulesListener();
    error? none = agentListener.attach(new NoCardService(), "rest");
    test:assertTrue(none is InternalError);
    test:assertTrue((<error>none).message().includes("agent card"), (<error>none).message());

    error? both = agentListener.attach(new TwoCardsService(), "rest");
    test:assertTrue(both is InternalError);
    test:assertTrue((<error>both).message().includes("not both"), (<error>both).message());
}

@test:Config {}
function testAttachRefusesAnErroringCardFunction() returns error? {
    RestListener agentListener = check attachRulesListener();
    error? rejected = agentListener.attach(new FailingCardService(), "rest");
    test:assertTrue(rejected is InternalError, "handleGetAgentCard failing must fail the attach, not serve a blank card");
    test:assertTrue((<error>rejected).message().includes("card unavailable"), (<error>rejected).message());
}

@test:Config {}
function testAnAgentTakesThePathOnce() returns error? {
    RestListener agentListener = check attachRulesListener();
    check agentListener.attach(new FullService(attachRulesHandler(), authTestCard), "rest");
    error? second = agentListener.attach(new FullService(attachRulesHandler(), authTestCard), "rest");
    test:assertTrue(second is InternalError, "one agent per listener, one service per path");
    test:assertTrue((<error>second).message().includes("already attached"), (<error>second).message());
}

// ---- the card follows the operations the service defines -----------------------

final DefaultHandler capabilityHandler = new (new CountingAgent());

listener RestListener capabilityFullListener = new (CAPABILITY_FULL_PORT);
listener RestListener capabilityMessageOnlyListener = new (CAPABILITY_MESSAGE_ONLY_PORT);
listener RestListener capabilityNoStreamingListener = new (CAPABILITY_NO_STREAMING_PORT);
listener RestListener capabilityNoPushListener = new (CAPABILITY_NO_PUSH_PORT);
listener RestListener cardFromFunctionListener = new (CARD_FROM_FUNCTION_PORT);

@test:BeforeSuite
function startCapabilityListeners() returns error? {
    check capabilityFullListener.attach(new FullService(capabilityHandler, authTestCard), "rest");
    check capabilityMessageOnlyListener.attach(new MessageOnlyService(capabilityHandler, authTestCard), "rest");
    check capabilityNoStreamingListener.attach(new NoStreamingService(capabilityHandler, authTestCard), "rest");
    check capabilityNoPushListener.attach(new NoPushService(capabilityHandler, authTestCard), "rest");
    check cardFromFunctionListener.attach(new FullService(capabilityHandler, silentAgentCard("Card From Function")),
            "rest");
}

isolated function servedCardAt(int port) returns map<json>|error {
    http:Client raw = check new (string `http://localhost:${port}`);
    json card = check raw->get("/.well-known/agent-card.json");
    return card.ensureType();
}

isolated function capabilitiesAt(int port) returns map<json>|error {
    map<json> card = check servedCardAt(port);
    return card["capabilities"].ensureType();
}

@test:Config {}
function testCapabilitiesComeFromTheOperationsTheServiceDefines() returns error? {
    map<json> full = check capabilitiesAt(CAPABILITY_FULL_PORT);
    test:assertEquals(full["streaming"], true);
    test:assertEquals(full["pushNotifications"], true);
    test:assertEquals(full["extendedAgentCard"], false);

    map<json> messageOnly = check capabilitiesAt(CAPABILITY_MESSAGE_ONLY_PORT);
    test:assertEquals(messageOnly["streaming"], false);
    test:assertEquals(messageOnly["pushNotifications"], false);

    map<json> noStreaming = check capabilitiesAt(CAPABILITY_NO_STREAMING_PORT);
    test:assertEquals(noStreaming["streaming"], false);
    test:assertEquals(noStreaming["pushNotifications"], true);

    map<json> noPush = check capabilitiesAt(CAPABILITY_NO_PUSH_PORT);
    test:assertEquals(noPush["streaming"], true);
    test:assertEquals(noPush["pushNotifications"], false);
}

@test:Config {}
function testTheServedInterfaceUrlEndsInTheBindingPath() returns error? {
    map<json> card = check servedCardAt(CAPABILITY_FULL_PORT);
    json[] interfaces = check card["supportedInterfaces"].ensureType();
    test:assertEquals(interfaces.length(), 1);
    map<json> only = check interfaces[0].ensureType();
    test:assertEquals(only["url"], string `http://localhost:${CAPABILITY_FULL_PORT}/rest`);
    test:assertEquals(only["protocolBinding"], "HTTP+JSON");
}

@test:Config {}
function testCardCanComeFromAFunction() returns error? {
    map<json> card = check servedCardAt(CARD_FROM_FUNCTION_PORT);
    test:assertEquals(card["name"], "Card From Function");
}

@test:Config {}
function testAnOperationTheServiceDoesNotDefineAnswersUnsupported() returns error? {
    http:Client raw = check new (string `http://localhost:${CAPABILITY_MESSAGE_ONLY_PORT}`);
    http:Response getTask = check raw->get("/rest/tasks/anything", {"A2A-Version": "1.0"});
    test:assertEquals(getTask.statusCode, 400);
    test:assertEquals(check reasonOf(getTask), "UNSUPPORTED_OPERATION");

    http:Response streamed = check raw->post("/rest/message:stream",
            {"message": {"messageId": "m", "role": "ROLE_USER", "parts": [{"text": "hi"}]}},
            {"A2A-Version": "1.0", "Content-Type": "application/json"});
    test:assertEquals(streamed.statusCode, 400);
    test:assertEquals(check reasonOf(streamed), "UNSUPPORTED_OPERATION");

    http:Response push = check raw->get("/rest/tasks/anything/pushNotificationConfigs", {"A2A-Version": "1.0"});
    test:assertEquals(push.statusCode, 400);
    test:assertEquals(check reasonOf(push), "PUSH_NOTIFICATION_NOT_SUPPORTED");
}

@test:Config {}
function testTheOperationsLiveUnderTheBindingPathOnly() returns error? {
    http:Client raw = check new (string `http://localhost:${CAPABILITY_FULL_PORT}`);
    http:Response atRoot = check raw->get("/tasks/anything", {"A2A-Version": "1.0"});
    test:assertEquals(atRoot.statusCode, 404, "the operations are served under /rest, not at the root");
}

// ---- the context is optional and comes first --------------------------------

const int PLAIN_FORM_PORT = 19279;

listener RestListener plainFormListener = new (PLAIN_FORM_PORT);

@test:BeforeSuite
function startPlainFormListener() returns error? {
    check plainFormListener.attach(new PlainFormService(), "rest");
}

@test:Config {}
function testAnOperationMayOmitTheContext() returns error? {
    RestClient viaPlain = check new (string `http://localhost:${PLAIN_FORM_PORT}`);
    Message|Task sent = check viaPlain->sendMessage({
        message: {messageId: "m-plain", role: ROLE_USER, parts: [{text: "no context needed"}]}
    });
    test:assertTrue(sent is Message, "the plain-form handleSendMessage answered");
    test:assertEquals((<Message>sent).parts[0].text, "plain: no context needed");

    Task|Error missing = viaPlain->getTask({id: "anything"});
    test:assertTrue(missing is TaskNotFoundError, "the plain-form handleGetTask answered");
}

@test:Config {}
function testBothFormsAreDetectedAsDefined() {
    OperationBinding withContext = new (new FullService(attachRulesHandler(), authTestCard));
    OperationBinding plain = new (new PlainFormService());
    test:assertTrue(withContext.isDefined("handleGetTask"));
    test:assertTrue(plain.isDefined("handleGetTask"));
    test:assertTrue(plain.isDefined("handleSendMessage"));
    test:assertFalse(plain.isDefined("handleListTasks"));
}

@test:Config {}
function testEitherParameterOrderIsAnOperation() returns error? {
    RestListener agentListener = check attachRulesListener();
    check agentListener.attach(new RequestFirstService(), "rest");
}

// ---- services used above --------------------------------------------------

isolated service class GetTaskOnlyService {
    *Service;

    private final DefaultHandler handler;
    private final AgentCard & readonly card;

    isolated function init(DefaultHandler handler, AgentCard card) {
        self.handler = handler;
        self.card = card.cloneReadOnly();
    }

    isolated resource function get agentCard() returns AgentCard|Error => self.card;

    isolated resource function get tasks/[string id](Context context, GetTaskRequest request) returns Task|Error {
        return self.handler.handleGetTask(context, request);
    }
}

isolated service class HalfStreamingService {
    *Service;

    private final DefaultHandler handler;
    private final AgentCard & readonly card;

    isolated function init(DefaultHandler handler, AgentCard card) {
        self.handler = handler;
        self.card = card.cloneReadOnly();
    }

    isolated resource function get agentCard() returns AgentCard|Error => self.card;

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated resource function post message\:stream(Context context, SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.handler.handleSendStreamingMessage(context, request);
    }
}

isolated service class NoCardService {
    *Service;

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return error InternalError("not used");
    }
}

@ServiceConfig {
    agentCard: {
        name: "Twice Declared",
        description: "Has the annotation and the function",
        version: "1.0.0",
        skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service class TwoCardsService {
    *Service;

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return error InternalError("not used");
    }

    isolated resource function get agentCard() returns AgentCard|Error => authTestCard;
}

isolated service class FailingCardService {
    *Service;

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return error InternalError("not used");
    }

    isolated resource function get agentCard() returns AgentCard|Error {
        return error InternalError("card unavailable");
    }
}

// ---- a declarative service on two listeners ------------------------------
//
// The form the README leads with: one `service /rest on a, b` declaration. The
// runtime attaches the same service object to both listeners, so both serve the
// one handler's tasks.

final DefaultHandler declarativeHandler = new (new CountingAgent());

listener RestListener declarativeListenerA = new (DECLARATIVE_PORT_A);
listener RestListener declarativeListenerB = new (DECLARATIVE_PORT_B);

@ServiceConfig {
    agentCard: {
        name: "Declarative Agent",
        description: "Declared with service /rest on two listeners",
        version: "1.0.0",
        skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service on declarativeListenerA, declarativeListenerB {

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return declarativeHandler.handleSendMessage(context, request);
    }

    isolated resource function get tasks/[string id](Context context, GetTaskRequest request) returns Task|Error {
        return declarativeHandler.handleGetTask(context, request);
    }
}

@test:Config {}
function testDeclarativeServiceOnTwoListenersSharesOneHandler() returns error? {
    RestClient viaA = check new (string `http://localhost:${DECLARATIVE_PORT_A}`);
    RestClient viaB = check new (string `http://localhost:${DECLARATIVE_PORT_B}`);

    Message|Task sent = check viaA->sendMessage({
        message: {messageId: "m-declarative", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(sent is Task, "the declared service drives a task");
    Task created = <Task>sent;

    Task fetched = check viaB->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "both listeners serve the one handler's tasks");
}

@ServiceConfig {
    agentCard: {
        name: "Plain Form Agent",
        description: "Defines its operations without the optional context",
        version: "1.0.0",
        skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service class PlainFormService {
    *Service;

    isolated resource function post message\:send(SendMessageRequest request) returns Task|Message|Error {
        string text = request.message.parts[0]?.text ?: "";
        return {messageId: "reply-plain", role: ROLE_AGENT, parts: [{text: string `plain: ${text}`}]};
    }

    isolated resource function get tasks/[string id](GetTaskRequest request) returns Task|Error {
        string message = string `no task with id ${request.id}`;
        return error TaskNotFoundError(message, message = message, code = -32001);
    }
}

isolated service class RequestFirstService {
    *Service;

    isolated resource function get agentCard() returns AgentCard|Error => authTestCard;

    isolated resource function post message\:send(SendMessageRequest request, Context context)
            returns Task|Message|Error {
        return error InternalError("not used");
    }
}
