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

configurable string agentUrl = "http://localhost:10101";

public function main() returns error? {
    a2a:AgentCard card = check a2a:resolveAgentCard(agentUrl);
    io:println(string `Connected to "${card.name}": ${card.description}`);

    a2a:RestClient agent = check new (card);

    a2a:Task|a2a:Message reply = check agent->sendMessage({
        message: {
            messageId: "msg-1",
            role: a2a:ROLE_USER,
            parts: [{text: "Can you roll an 11 sided dice?"}]
        }
    });

    if reply is a2a:Message {
        io:println("Reply: ", reply.parts[0]?.text ?: "");
    } else if reply is a2a:Task {
        a2a:Artifact[] artifacts = reply.artifacts ?: [];
        io:println(string `Task ${reply.id}: ${reply.status.state}`);
        io:println("Result: ", artifacts.length() > 0 ? artifacts[0].parts[0]?.text ?: "" : "");
    }
}
