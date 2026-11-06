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


// Turns the JSON body of an inbound request into the typed request an
// operation takes, and answers anything wrong with it as a 400.
//
// Every failure here is the caller's: a body that is not JSON, that does not
// match the request type, or that carries a malformed part. It is reported
// with `invalidRequest`, never with `InvalidAgentResponseError` (a 500, and
// the agent's fault) as this path used to.

# Decodes the body of a `sendMessage` or `sendStreamingMessage` request.
#
# File bytes arrive as base64 in `Part.raw`; they are decoded to `byte[]`
# before conversion, the same step the client applies to what an agent sends,
# so an agent's `execute` receives the bytes and not a string.
#
# + payload - The request's parsed JSON body, or the error parsing it raised
# + return - The typed request, or an `invalidRequest` error
isolated function decodeSendMessageRequest(json|error payload) returns SendMessageRequest|Error {
    if payload is error {
        return invalidRequest(string `request body is not valid JSON: ${payload.message()}`);
    }
    check checkMessagePartVariants(payload);
    json|error decoded = decodeRawBytesFromWire(payload);
    if decoded is error {
        // A part with no variant or several, or a `raw` that is not base64:
        // the caller's mistake, whatever type the shared decoder gives it.
        return invalidRequest(string `request body has a malformed part: ${decoded.message()}`);
    }
    SendMessageRequest|error request = pruneUnknownRequestFields(decoded).cloneWithType(SendMessageRequest);
    if request is error {
        return invalidRequest(string `request body did not match SendMessageRequest: ${request.message()}`);
    }
    return request;
}

// The fields each level of a send request defines. Anything else a caller
// adds is dropped on the way in, not stored: the task keeps the message and
// serves it back, and a strict protobuf client (Python, Go, Java) refuses a
// message that carries a field it has no name for.
final readonly & string[] SEND_REQUEST_FIELDS = ["message", "tenant", "configuration", "metadata"];
final readonly & string[] MESSAGE_FIELDS = [
    "messageId", "role", "parts", "contextId", "taskId", "referenceTaskIds", "extensions", "metadata"
];
final readonly & string[] PART_FIELDS = ["text", "raw", "url", "data", "filename", "mediaType", "metadata"];
final readonly & string[] CONFIGURATION_FIELDS = [
    "acceptedOutputModes", "historyLength", "returnImmediately", "taskPushNotificationConfig"
];
final readonly & string[] PUSH_CONFIG_FIELDS = ["url", "id", "taskId", "token", "authentication", "tenant"];
final readonly & string[] AUTHENTICATION_FIELDS = ["scheme", "credentials"];

# Drops the fields a send request does not define, down to the message's
# parts and the push config, and an unset id sent as an empty string. `metadata` maps and a data part's value are the
# caller's own structure and are left alone.
#
# + payload - The decoded request body
# + return - The same body without unknown fields
isolated function pruneUnknownRequestFields(json payload) returns json {
    map<json>|error request = payload.ensureType();
    if request is error {
        return payload;
    }
    map<json> pruned = keepFields(request, SEND_REQUEST_FIELDS);
    json message = pruned["message"];
    if message is map<json> {
        map<json> keptMessage = keepFields(message, MESSAGE_FIELDS);
        // A client that serialises protobuf defaults sends an unset id as "".
        foreach string id in ["taskId", "contextId"] {
            if keptMessage[id] == "" {
                _ = keptMessage.remove(id);
            }
        }
        json parts = keptMessage["parts"];
        if parts is json[] {
            json[] keptParts = [];
            foreach json part in parts {
                keptParts.push(part is map<json> ? keepFields(part, PART_FIELDS) : part);
            }
            keptMessage["parts"] = keptParts;
        }
        pruned["message"] = keptMessage;
    }
    json configuration = pruned["configuration"];
    if configuration is map<json> {
        map<json> keptConfiguration = keepFields(configuration, CONFIGURATION_FIELDS);
        json pushConfig = keptConfiguration["taskPushNotificationConfig"];
        if pushConfig is map<json> {
            map<json> keptPush = keepFields(pushConfig, PUSH_CONFIG_FIELDS);
            json authentication = keptPush["authentication"];
            if authentication is map<json> {
                keptPush["authentication"] = keepFields(authentication, AUTHENTICATION_FIELDS);
            }
            keptConfiguration["taskPushNotificationConfig"] = keptPush;
        }
        pruned["configuration"] = keptConfiguration;
    }
    return pruned;
}

isolated function keepFields(map<json> fields, string[] known) returns map<json> {
    map<json> kept = {};
    foreach string name in known {
        if fields.hasKey(name) {
            kept[name] = fields.get(name);
        }
    }
    return kept;
}

# Refuses a `message.parts` entry with other than exactly one of text, raw,
# url or data set, naming its position.
#
# `decodeRawBytesFromWire` makes the same check while it walks the whole body,
# but cannot say which part failed; this runs first so the error's
# `google.rpc.BadRequest` entry names `message.parts[i]`. A body without that
# shape is left for the decoder and `cloneWithType` to refuse.
#
# + payload - The request's parsed JSON body
# + return - An `invalidRequest` error naming the first bad part, or `()`
isolated function checkMessagePartVariants(json payload) returns Error? {
    if payload !is map<json> {
        return;
    }
    json message = payload["message"];
    if message !is map<json> {
        return;
    }
    json parts = message["parts"];
    if parts !is json[] {
        return;
    }
    foreach [int, json] [index, part] in parts.enumerate() {
        if part !is map<json> {
            continue;
        }
        int variants = countSetPartVariantsJson(part);
        if variants != 1 {
            return invalidRequest(
                string `Part must have exactly one of text, raw, url, or data set; found ${variants}`,
                string `message.parts[${index}]`);
        }
    }
}

# Decodes the body of a `createTaskPushNotificationConfig` request, stamping
# the parent task id from the URL path.
#
# + payload - The request's parsed JSON body, or the error parsing it raised
# + taskId - The parent task id, from the path
# + return - The typed config, or an `invalidRequest` error
isolated function decodePushConfigRequest(json|error payload, string taskId)
        returns TaskPushNotificationConfig|Error {
    if payload is error {
        return invalidRequest(string `request body is not valid JSON: ${payload.message()}`);
    }
    map<json>|error asMap = payload.ensureType();
    if asMap is error {
        return invalidRequest("request body is not a JSON object");
    }
    asMap["taskId"] = taskId;
    TaskPushNotificationConfig|error request = asMap.cloneWithType(TaskPushNotificationConfig);
    if request is error {
        return invalidRequest(string `request body did not match TaskPushNotificationConfig: ${request.message()}`);
    }
    return request;
}
