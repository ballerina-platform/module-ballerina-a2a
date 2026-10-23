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


// What a developer implements to serve an A2A agent.
//
// An agent is an `a2a:Service` attached to an `a2a:RestListener`. The service
// carries the agent card and defines the A2A operations it supports as
// `resource` functions, one per route of the HTTP+JSON binding; the listener
// reads which ones it defines when the service is attached, and answers
// `UnsupportedOperationError` for the others. Every operation can be written
// by hand or delegated to an `a2a:DefaultHandler`, which runs the task
// lifecycle around an `a2a:AgentExecutor`.

# An A2A agent: a service that defines some of the A2A operations.
#
# The type itself requires nothing. Which operations a service supports is
# decided by the `resource` functions it defines:
#
# | Operation | Resource |
# |---|---|
# | SendMessage | `post message\:send` |
# | SendStreamingMessage | `post message\:stream` |
# | GetTask | `get tasks/[string id]` |
# | ListTasks | `get tasks` |
# | CancelTask | `post tasks/[string id]/cancel` |
# | SubscribeToTask | `get tasks/[string id]/subscribe` |
# | CreateTaskPushNotificationConfig | `post tasks/[string id]/pushNotificationConfigs` |
# | GetTaskPushNotificationConfig | `get tasks/[string id]/pushNotificationConfigs/[string configId]` |
# | ListTaskPushNotificationConfigs | `get tasks/[string id]/pushNotificationConfigs` |
# | DeleteTaskPushNotificationConfig | `delete tasks/[string id]/pushNotificationConfigs/[string configId]` |
# | GetExtendedAgentCard | `get extendedAgentCard` |
# | agent card (dynamic) | `get agentCard` |
#
# On the wire the cancel and subscribe routes are `tasks/{id}:cancel` and
# `tasks/{id}:subscribe`, as the specification names them; the listener
# translates, because a Ballerina path parameter cannot carry a suffix.
#
# Each resource takes its path parameters, then the operation's request record,
# preceded by an `a2a:Context` if the service wants to know who is calling; the
# context is optional. A service must define `post message\:send`; the
# streaming operations (`message\:stream` with `subscribe`) and the four
# push-notification operations are each all-or-nothing, because the agent card
# advertises them as one capability.
#
# The agent card comes from `@a2a:ServiceConfig` or from an optional
# `get agentCard` resource, not both.
public type Service distinct isolated service object {
};

# Per-service configuration, given with `@a2a:ServiceConfig`.
public type ServiceConfiguration record {|
    # The agent card. `capabilities` and `supportedInterfaces` are derived by
    # the listener from the operations the service defines and the path it is
    # attached at, so pass `capabilities: {}` and `supportedInterfaces: []`.
    #
    # Annotation values must be constants. To build the card from
    # configuration, define a `get agentCard` resource instead and omit the annotation.
    AgentCard agentCard;
|};

# Gives an `a2a:Service` its agent card, on a `service` declaration or a `service class`.
public annotation ServiceConfiguration ServiceConfig on service, class;

# The inbound message and the context of the request that delivered it.
#
# Passed to `a2a:AgentExecutor.execute`. Holds the message the client sent, the
# effective tenant the request was routed under (if any), the caller's
# resolved owner scope, and any `configuration` the client attached.
public type RequestContext record {|
    # The message the client sent
    Message message;
    # The tenant segment the request arrived under, if any
    string tenant?;
    # The caller's resolved owner scope; unset when no
    # `a2a:TaskOwnerResolver` is configured, or the resolver itself returned
    # `()`. Not an authentication result -- unset is its own scope, shared by
    # every unscoped caller, not a wildcard.
    string owner?;
    # The send configuration the client attached, if any
    SendMessageConfiguration configuration?;
|};
