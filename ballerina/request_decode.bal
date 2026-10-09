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
# so an agent's `onMessage` receives the bytes and not a string.
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
    SendMessageRequest|error request = decoded.cloneWithType(SendMessageRequest);
    if request is error {
        return invalidRequest(string `request body did not match SendMessageRequest: ${request.message()}`);
    }
    return request;
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
