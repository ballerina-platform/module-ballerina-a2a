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


// The card a listener serves for an attached service: where it comes from,
// which capabilities the service's operations imply, and the derivation that
// makes the served card say only what the agent really does.

import ballerina/http;

# The capabilities a service's operations imply.
type Capabilities record {|
    # Both streaming operations are defined
    boolean streaming;
    # All four push-notification configuration operations are defined
    boolean pushNotifications;
    # the `get extendedAgentCard` resource is defined
    boolean extendedAgentCard;
|};

# The `@a2a:ServiceConfig` a service declares, if it has one.
#
# + a2aService - The service being attached
# + return - Its configuration, or `()` when it carries no `@a2a:ServiceConfig`
isolated function serviceConfigurationOf(Service a2aService) returns ServiceConfiguration? {
    typedesc<any> serviceType = typeof a2aService;
    return serviceType.@ServiceConfig;
}

# Reads the capabilities a service's operations imply, and refuses a service
# that cannot be served as declared.
#
# The `post message:send` resource is required. The two streaming operations are one
# capability and the four push-notification operations another, because the
# card advertises each as a single flag: defining only part of a group would
# make the card claim something the agent cannot do.
#
# + binding - The attached service
# + return - The capabilities, or an `a2a:InternalError` naming what is missing
isolated function capabilitiesOf(OperationBinding binding) returns Capabilities|Error {
    if !binding.isDefined("handleSendMessage") {
        string msg = "an a2a:Service must define the `post message\\:send` resource";
        return error InternalError(msg, message = msg);
    }
    boolean streaming = check wholeGroup(binding, "streaming", ["handleSendStreamingMessage", "handleSubscribeToTask"]);
    boolean push = check wholeGroup(binding, "push notifications", [
        "handleCreateTaskPushNotificationConfig", "handleGetTaskPushNotificationConfig",
        "handleListTaskPushNotificationConfigs", "handleDeleteTaskPushNotificationConfig"
    ]);
    return {streaming, pushNotifications: push, extendedAgentCard: binding.isDefined("handleGetExtendedAgentCard")};
}

# Whether a group of operations that must come together is defined, all or none.
#
# + binding - The attached service
# + capability - The capability the group provides, for the message
# + names - The operations of the group
# + return - `true` if all are defined, `false` if none are, an error if only some
isolated function wholeGroup(OperationBinding binding, string capability, string[] names) returns boolean|Error {
    string[] missing = names.filter(n => !binding.isDefined(n));
    if missing.length() == 0 {
        return true;
    }
    if missing.length() == names.length() {
        return false;
    }
    string msg = string `an a2a:Service that supports ${capability} must define all of ${resourcesOf(names)}; `
        + string `missing ${resourcesOf(missing)}`;
    return error InternalError(msg, message = msg);
}

# Names the resources that serve a set of operations, for an error message.
#
# + operations - Operation names such as `handleGetTask`
# + return - The resources, e.g. `get tasks/*`, comma separated
isolated function resourcesOf(string[] operations) returns string {
    string[] resources = [];
    foreach string operation in operations {
        ResourceRoute route = OPERATION_ROUTES.get(operation);
        resources.push(string `${route.accessor} ${route.path}`);
    }
    return ", ".'join(...resources);
}

# The agent card a service declares: the `@a2a:ServiceConfig` annotation, or
# the result of its `get agentCard` resource, but not both.
#
# + a2aService - The service being attached
# + binding - The attached service
# + return - The card as declared, or an `a2a:InternalError` if there is none,
#            two, or the `get agentCard` resource failed
isolated function agentCardOf(Service a2aService, OperationBinding binding) returns AgentCard|Error {
    ServiceConfiguration? config = serviceConfigurationOf(a2aService);
    boolean hasFunction = binding.isDefined("handleGetAgentCard");
    if config is ServiceConfiguration && hasFunction {
        string msg = "an a2a:Service declares its agent card with @a2a:ServiceConfig or a get agentCard resource, not both";
        return error InternalError(msg, message = msg);
    }
    if config is ServiceConfiguration {
        return config.agentCard;
    }
    if hasFunction {
        return binding.getAgentCard();
    }
    string msg = "an a2a:Service needs an agent card: add @a2a:ServiceConfig {agentCard: ...} "
        + "or define a get agentCard resource";
    return error InternalError(msg, message = msg);
}

# Turns the card a service declared into the card that is served.
isolated class ServedCards {
    private final (http:ListenerAuthConfig[] & readonly)? auth;
    private final Capabilities & readonly capabilities;

    # + auth - The listener's `auth`, from which security schemes are derived
    # + capabilities - What the service's operations imply
    isolated function init((http:ListenerAuthConfig[] & readonly)? auth, Capabilities capabilities) {
        self.auth = auth;
        self.capabilities = capabilities.cloneReadOnly();
    }

    # + supplied - The card the service declared
    # + return - The card to serve at the discovery path
    isolated function publicCard(AgentCard supplied) returns AgentCard {
        return deriveServedCard(withDerivedSecurity(supplied, self.auth), self.capabilities.extendedAgentCard,
                self.capabilities.streaming, self.capabilities.pushNotifications);
    }

    # + supplied - The extended card the service returned
    # + return - The extended card to serve, which declares the extended card itself
    isolated function extendedCard(AgentCard supplied) returns AgentCard {
        return deriveServedCard(withDerivedSecurity(supplied, self.auth), true,
                self.capabilities.streaming, self.capabilities.pushNotifications);
    }
}

# Derives the card the server actually publishes from the one the developer
# supplied.
#
# The developer gives identity, skills, and I/O modes. This forces the
# `supportedInterfaces` to a single HTTP+JSON v1.0 entry (the listener fills in
# its URL, and adds one per attached binding) and sets the capability flags to
# what the service's operations provide, so a card never claims something the
# agent does not do, or does not accept.
#
# `extensions` is left exactly as the developer declared it, not derived --
# unlike the other three flags, this server has no way to know which
# extensions the developer's executor actually implements, so it cannot
# second-guess (or silently drop) that declaration the way it can for
# capabilities it fully owns.
#
# + supplied - The card the developer passed
# + extendedCardConfigured - Whether the service defines the `get extendedAgentCard` resource
# + streamingCapability - Whether the service defines the streaming operations
# + pushNotificationsCapability - Whether the service defines the push-notification operations
# + return - The card to serve
isolated function deriveServedCard(AgentCard supplied, boolean extendedCardConfigured,
        boolean streamingCapability, boolean pushNotificationsCapability) returns AgentCard {
    // A mutable top level even when `supplied` is readonly:
    // `clone()` alone returns an immutable value unchanged.
    AgentCard card = {...supplied.clone()};
    card.supportedInterfaces = [
        {url: "", protocolBinding: HTTP_JSON, protocolVersion: A2A_PROTOCOL_VERSION}
    ];
    card.capabilities = {
        streaming: streamingCapability,
        pushNotifications: pushNotificationsCapability,
        extensions: supplied.capabilities.extensions,
        extendedAgentCard: extendedCardConfigured
    };
    return card;
}
