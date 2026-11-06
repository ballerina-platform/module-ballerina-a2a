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


// The agent's own logic, kept apart from the protocol: the equivalent of the
// reference SDKs' `AgentExecutor`. An `a2a:DefaultHandler` runs it for every
// message it accepts.

# The logic of one agent.
#
# For a long-running task, drive the supplied `a2a:TaskUpdater` through the
# lifecycle; for a simple exchange, return an `a2a:Message` directly.
public type AgentExecutor isolated object {

    # Handles one inbound message.
    #
    # + context - The message and the request that carried it
    # + updater - Drives the task this message creates, or is left unused when
    #             the reply is a direct `a2a:Message`
    # + return - A direct `a2a:Message` reply, `()` when the task was driven
    #            through `updater` instead, or an `a2a:Error`
    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error?;
};
