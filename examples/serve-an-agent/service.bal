// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/a2a;
import ballerina/io;

configurable int listenerPort = 9090;

isolated class WeatherExecutor {
    *a2a:AgentExecutor;

    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater.working();
        check updater.addArtifact([{text: "Sunny, 22°C"}]);
        check updater.complete();
        return;
    }
}

@a2a:ServiceConfig {
    agentCard: {
        name: "Weather Agent",
        description: "Answers weather questions",
        version: "1.0.0",
        provider: {organization: "Example Co", url: "https://example.com"},
        skills: [
            {id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service on new a2a:RestListener(listenerPort) {

    private final a2a:DefaultHandler handler = new (new WeatherExecutor());

    isolated function init() {
        io:println(string `Weather Agent listening on http://localhost:${listenerPort}`);
    }

    isolated resource function post message\:send(a2a:Context context, a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error {
        return self.handler.handleSendMessage(context, request);
    }

    isolated resource function post message\:stream(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.handleSendStreamingMessage(context, request);
    }

    isolated resource function get tasks/[string id]/subscribe(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.handleSubscribeToTask(context, request);
    }

    isolated resource function get tasks/[string id](a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.handleGetTask(context, request);
    }

    isolated resource function get tasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error {
        return self.handler.handleListTasks(context, request);
    }

    isolated resource function post tasks/[string id]/cancel(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.handleCancelTask(context, request);
    }

    isolated resource function post tasks/[string id]/pushNotificationConfigs(a2a:Context context,
            a2a:TaskPushNotificationConfig request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.handleCreateTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context,
            a2a:GetTaskPushNotificationConfigRequest request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.handleGetTaskPushNotificationConfig(context, request);
    }

    isolated resource function get tasks/[string id]/pushNotificationConfigs(a2a:Context context,
            a2a:ListTaskPushNotificationConfigsRequest request)
            returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error {
        return self.handler.handleListTaskPushNotificationConfigs(context, request);
    }

    isolated resource function delete tasks/[string id]/pushNotificationConfigs/[string configId](a2a:Context context,
            a2a:DeleteTaskPushNotificationConfigRequest request)
            returns a2a:Error? {
        return self.handler.handleDeleteTaskPushNotificationConfig(context, request);
    }
}
