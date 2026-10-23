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
import ballerina/test;

const int CAPABILITY_GROUPS_PORT = 19294;

// A capability is advertised as one flag, so the operations behind it come together or not at all.

isolated service class PartialPushRestService {
    *Service;

    private final DefaultHandler handler = new (new CountingAgent());

    isolated resource function get agentCard() returns AgentCard|Error => authTestCard;

    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated resource function post tasks/[string id]/pushNotificationConfigs(Context context,
            TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error {
        return self.handler.handleCreateTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](Context context,
            GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error {
        return self.handler.handleGetTaskPushNotificationConfig(context, request);
    }
}

isolated service class PartialPushRpcService {
    *Service;

    private final DefaultHandler handler = new (new CountingAgent());

    isolated remote function getAgentCard() returns AgentCard|Error => authTestCard;

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated remote function createTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        return self.handler.handleCreateTaskPushNotificationConfig(context, request);
    }

    isolated remote function deleteTaskPushNotificationConfig(Context context,
            DeleteTaskPushNotificationConfigRequest request) returns Error? {
        return self.handler.handleDeleteTaskPushNotificationConfig(context, request);
    }
}

isolated service class HalfStreamingRpcService {
    *Service;

    private final DefaultHandler handler = new (new CountingAgent());

    isolated remote function getAgentCard() returns AgentCard|Error => authTestCard;

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated remote function subscribeToTask(Context context, SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.handler.handleSubscribeToTask(context, request);
    }
}

isolated service class SendOnlyRpcService {
    *Service;

    private final DefaultHandler handler = new (new CountingAgent());

    isolated remote function getAgentCard() returns AgentCard|Error => authTestCard;

    isolated remote function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return self.handler.handleSendMessage(context, request);
    }
}

isolated service class NoSendRpcService {
    *Service;

    private final DefaultHandler handler = new (new CountingAgent());

    isolated remote function getAgentCard() returns AgentCard|Error => authTestCard;

    isolated remote function getTask(Context context, GetTaskRequest request) returns Task|Error {
        return self.handler.handleGetTask(context, request);
    }
}

function assertRefusedAs(error? rejected, string... expected) {
    test:assertTrue(rejected is InternalError, "the attach must be refused");
    string message = (<error>rejected).message();
    test:assertTrue(message.includes("must define all of"), message);
    foreach string part in expected {
        test:assertTrue(message.includes(part), string `"${part}" missing from: ${message}`);
    }
}

@test:Config {}
function testRestRefusesHalfOfThePushNotificationOperations() {
    RestListener agentListener = checkpanic new (CAPABILITY_GROUPS_PORT);
    error? rejected = agentListener.attach(new PartialPushRestService(), "rest");
    assertRefusedAs(rejected, "push notifications", "missing",
            "tasks/*/pushNotificationConfigs");
}

@test:Config {}
function testJsonRpcRefusesHalfOfThePushNotificationOperations() {
    JsonRpcListener agentListener = checkpanic new (CAPABILITY_GROUPS_PORT + 1);
    error? rejected = agentListener.attach(new PartialPushRpcService());
    assertRefusedAs(rejected, "push notifications", "getTaskPushNotificationConfig",
            "listTaskPushNotificationConfigs");
}

@test:Config {}
function testJsonRpcRefusesHalfOfTheStreamingOperations() {
    JsonRpcListener agentListener = checkpanic new (CAPABILITY_GROUPS_PORT + 2);
    error? rejected = agentListener.attach(new HalfStreamingRpcService());
    assertRefusedAs(rejected, "streaming", "sendStreamingMessage");
}

@test:Config {}
function testJsonRpcRefusesAServiceWithoutSendMessage() {
    JsonRpcListener agentListener = checkpanic new (CAPABILITY_GROUPS_PORT + 3);
    error? rejected = agentListener.attach(new NoSendRpcService());
    test:assertTrue(rejected is InternalError, "the attach must be refused");
    test:assertTrue((<error>rejected).message().includes("sendMessage"), (<error>rejected).message());
}

@test:Config {}
function testTheCardAdvertisesOnlyWhatIsDefined() returns error? {
    JsonRpcListener sendOnly = check new (CAPABILITY_GROUPS_PORT + 5);
    check sendOnly.attach(new SendOnlyRpcService());
    check sendOnly.'start();
    http:Client cardClient = check new (string `http://localhost:${CAPABILITY_GROUPS_PORT + 5}`);
    json card = check cardClient->get("/.well-known/agent-card.json");
    json capabilities = check card.capabilities;
    test:assertEquals(check capabilities.streaming, false, capabilities.toJsonString());
    test:assertEquals(check capabilities.pushNotifications, false, capabilities.toJsonString());
    check sendOnly.gracefulStop();
}

@test:Config {}
function testTheCardAdvertisesAWholeGroup() returns error? {
    RestListener full = check new (CAPABILITY_GROUPS_PORT + 6);
    check full.attach(new FullService(new DefaultHandler(new CountingAgent()), authTestCard), "rest");
    check full.'start();
    http:Client cardClient = check new (string `http://localhost:${CAPABILITY_GROUPS_PORT + 6}`);
    json card = check cardClient->get("/.well-known/agent-card.json");
    json capabilities = check card.capabilities;
    test:assertEquals(check capabilities.streaming, true, capabilities.toJsonString());
    test:assertEquals(check capabilities.pushNotifications, true, capabilities.toJsonString());
    check full.gracefulStop();
}
