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
// One shape: `a2a:Service`, implementing a single method, `onMessage`. An
// `a2a:DefaultHandler` runs the task lifecycle, listTasks, and the push-config
// store around it, and a listener such as `a2a:HttpListener` carries it over
// the wire -- the same split the reference SDKs draw between an
// `AgentExecutor`, a `RequestHandler`, and a transport.
//
// `ballerina/mcp` also exposes an `AdvancedService` escape hatch, for a
// developer who needs to bypass the library's own tool/resource handling.
// A2A has no equivalent need to bypass: the eleven operations are a fixed
// protocol surface around one piece of real business logic (`onMessage`),
// not a registry of developer-defined tools a library might get in the way
// of. Not planned.

# An A2A agent that implements the single message entry point and lets the
# library run everything else.
#
# The developer implements `onMessage`. For a long-running task it drives the
# supplied `a2a:TaskUpdater` through the lifecycle; for a simple exchange it
# returns a `a2a:Message` directly.
public type Service distinct isolated service object {

    # Handles one inbound message.
    #
    # + context - The message and the request that carried it
    # + updater - Drives the task this message creates, or is left unused when
    #             the reply is a direct `a2a:Message`
    # + return - A direct `a2a:Message` reply, `()` when the task was driven
    #            through `updater` instead, or an `a2a:Error`
    remote isolated function onMessage(RequestContext context, TaskUpdater updater)
        returns Message|Error?;
};

# The protocol binding an attached `a2a:Service` is served over.
public type Protocol REST|RPC;

# The HTTP+JSON (REST) binding, served by `a2a:HttpListener`.
public const REST = "REST";

# The JSON-RPC binding. Reserved: not served in this release, so attaching a
# service configured with it fails.
public const RPC = "RPC";

# Per-service configuration, given with `@a2a:ServiceConfig`.
public type ServiceConfiguration record {|
    # The protocol binding to serve this service over
    Protocol protocol = REST;
|};

# Configures an `a2a:Service` -- on a `service` declaration or a `service class`.
# A service without it is served with the defaults of `a2a:ServiceConfiguration`.
public annotation ServiceConfiguration ServiceConfig on service, class;

# The configuration an attached service declares, or the defaults when it
# carries no `@a2a:ServiceConfig`.
#
# + a2aService - The service being attached
# + return - Its configuration
isolated function serviceConfigurationOf(Service a2aService) returns ServiceConfiguration {
    typedesc<any> serviceType = typeof a2aService;
    ServiceConfiguration? config = serviceType.@ServiceConfig;
    return config ?: {};
}

# The inbound message and the context of the request that delivered it.
#
# Passed to `a2a:Service.onMessage`. Holds the message the client sent, the
# effective tenant the request was routed under (or `()` when none), the
# caller's resolved owner scope, and any `configuration` the client attached.
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
