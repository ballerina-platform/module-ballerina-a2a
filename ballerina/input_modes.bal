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

// The check of a message's part media types against the agent's declared input modes,
// shared by both bindings.

# Rejects a message carrying a part whose media type the agent card does not declare.
#
# The accepted set is the union of the card's `defaultInputModes` and every skill's `inputModes`: a request does
# not name the skill that will serve it, so the union is the most that can be decided here. A card that declares
# no input modes anywhere accepts everything, and a part that states no `mediaType` is not checked; only a media
# type the client actually stated can contradict the card.
#
# A declared mode matches a media type case-insensitively and ignoring parameters (`text/plain; charset=utf-8`).
# A mode that is a bare type (`text`, which the examples declare) matches every subtype of it, and `type/*` and
# `*/*` are wildcards.
#
# Specification sections 3.1.1 and 13: `ContentTypeNotSupportedError` is the error for a media type the agent does
# not support, and an agent SHOULD reject unexpected media types.
#
# + card - The served card
# + message - The message a client sent
# + return - A `ContentTypeNotSupportedError` naming the first unsupported media type, or `()`
isolated function checkInputModes(AgentCard card, Message message) returns Error? {
    string[] declared = [];
    foreach string mode in card.defaultInputModes {
        declared.push(mode);
    }
    foreach AgentSkill skill in card.skills {
        foreach string mode in skill.inputModes ?: [] {
            declared.push(mode);
        }
    }
    if declared.length() == 0 {
        return;
    }
    foreach Part part in message.parts {
        string? mediaType = part.mediaType;
        if mediaType is string && mediaType != "" && !acceptsMediaType(declared, mediaType) {
            string msg = string `media type ${mediaType} is not supported; the agent accepts ${
                    string:'join(", ", ...declared)}`;
            return error ContentTypeNotSupportedError(msg, message = msg, code = -32005);
        }
    }
}

isolated function acceptsMediaType(string[] declared, string mediaType) returns boolean {
    string wanted = baseMediaType(mediaType);
    foreach string mode in declared {
        string accepted = baseMediaType(mode);
        if accepted == wanted || accepted == "*/*" || accepted == "*" {
            return true;
        }
        int? slash = wanted.indexOf("/");
        if slash is int {
            string family = wanted.substring(0, slash);
            if accepted == family || accepted == family + "/*" {
                return true;
            }
        }
    }
    return false;
}

// The media type without parameters, trimmed and lower case.
isolated function baseMediaType(string mediaType) returns string {
    int? semicolon = mediaType.indexOf(";");
    string bare = semicolon is int ? mediaType.substring(0, semicolon) : mediaType;
    return bare.trim().toLowerAscii();
}
