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

// Specification rules that hold regardless of how a value reached us.
//
// These are protocol requirements, not transport concerns: the same rule
// applies to a Message built by a caller and to one decoded off any
// binding's wire. Kept out of the transport client for that reason, so the
// bindings still to come share them rather than restating them.

# Enforces non-emptiness on the two arrays the specification requires it for.
#
# Section 5.7's blanket "arrays marked as required MUST contain at least one
# element" cannot be read literally: the specification's own example in
# section 8.4.1 publishes a conformant AgentCard carrying `"skills": []`.
# REQUIRED means present, which the type system already enforces.
#
# So non-emptiness is checked only where a field says so — `Artifact.parts`,
# the one such statement in the proto — or where a2a-java corroborates it,
# which is `Message.parts`.
#
# Checked in both directions. Section 5.7 asks implementations to reject
# messages with missing required fields, not only responses, and checking
# outbound turns a round trip into an immediate local error.
#
# + name - The field's dotted name, for the message
# + length - The array's actual length
# + inbound - True when validating what an agent sent, false for what a caller
#             is about to send
# + return - An error when the array is empty, otherwise nil
isolated function requireNonEmpty(string name, int length, boolean inbound) returns Error? {
    if length > 0 {
        return;
    }
    string message = string `${name} is a required array and must contain at least one element `
        + string `(specification section 5.7)`;
    // Inbound is the agent's fault; outbound is the caller's. InternalError
    // is this library's catch-all for a client-side precondition failure --
    // the specification defines no error for one, since section 3.3.2 and
    // section 5.4 both describe server behaviour, and the same choice is
    // already made by outboundPartVariantError.
    return inbound
        ? invalidAgentResponse(message)
        : error InternalError(message, message = message);
}

# Validates a Message a caller is about to send.
#
# + message - The message to check
# + return - An error when it violates a specification requirement
isolated function validateOutboundMessage(Message message) returns Error? {
    check requireNonEmpty("Message.parts", message.parts.length(), false);
    foreach Part part in message.parts {
        int variants = countSetPartVariants(part);
        if variants != 1 {
            error variantError = outboundPartVariantError(variants);
            string m = variantError.message();
            return error InternalError(m, message = m);
        }
    }
}

# Validates a Message a caller sent to this server.
#
# The same two rules as `validateOutboundMessage`, but a failure here is a bad
# request (a 400), not the catch-all an outgoing message reports.
#
# + message - The message to check
# + return - An `invalidRequest` error when it violates a specification requirement
isolated function validateReceivedMessage(Message message) returns Error? {
    if message.parts.length() == 0 {
        return invalidRequest("Message.parts is a required array and must contain at least one element "
            + "(specification section 5.7)", "message.parts");
    }
    foreach [int, Part] [index, part] in message.parts.enumerate() {
        int variants = countSetPartVariants(part);
        if variants != 1 {
            return invalidRequest(
                string `Part must have exactly one of text, raw, url, or data set; found ${variants}`,
                string `message.parts[${index}]`);
        }
    }
}

# Validates the id a caller chose for a push-notification config.
#
# The id becomes a path segment (`/tasks/{id}/pushNotificationConfigs/{configId}`),
# so one containing `/` could never be fetched or deleted again. An unset or
# empty id is fine: the server assigns one.
#
# + config - The config the caller supplied, or `()` if none was
# + idField - Where the id sits in the request body, for the error's field violation
# + return - An `invalidRequest` error if the id cannot be used as a path segment
isolated function validatePushConfigId(TaskPushNotificationConfig? config,
        string idField = "configuration.taskPushNotificationConfig.id") returns Error? {
    string? id = config?.id;
    if id is string && id.includes("/") {
        return invalidRequest(string `push notification config id "${id}" must not contain '/'`, idField);
    }
}

# Validates a Task an agent sent us, and the artifacts and history it carries.
#
# + task - The decoded task
# + return - An error when it violates a specification requirement
isolated function validateInboundTask(Task task) returns Error? {
    foreach Artifact artifact in task.artifacts ?: [] {
        check requireNonEmpty("Artifact.parts", artifact.parts.length(), true);
    }
    foreach Message historyMessage in task.history ?: [] {
        check requireNonEmpty("Message.parts", historyMessage.parts.length(), true);
    }
}
