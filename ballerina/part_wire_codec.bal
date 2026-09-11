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

// Wire-level encode/decode helpers for Part.raw, split out of
// types.bal (which should hold type definitions, not functions).

import ballerina/lang.array;

# The field names that can hold a `Part`, directly or transitively, anywhere
# in the v1.0 type hierarchy.
#
# `encodeRawBytesForWire` and `decodeRawBytesFromWire` recurse into these key
# names only. That is what stops the walkers touching free-form fields —
# `metadata`, or a data-Part's own `data` — when those happen to contain a key
# named "raw" that has nothing to do with `Part.raw`.
final readonly & string[] partBearingContainerKeys = [
    "history", "artifacts", "message", "status", "task", "statusUpdate",
    "artifactUpdate", "artifact", "tasks"
];

isolated function isPartBearingContainerKey(string k) returns boolean {
    return partBearingContainerKeys.indexOf(k) is int;
}

# The four `Part` variants, in specification order.
#
# Presence is what counts, not a non-nil value: specification section 4.1.6
# removed the `kind` discriminator in favour of member presence, and
# `specification.md` says so outright -- "member presence acts as
# discriminator". The distinction is not academic. `Part.data` is
# `google.protobuf.Value`, the one field in the whole specification where a
# JSON null is legal ("object, array, string, number, boolean, or null"),
# so a conformant `{"data": null}` is a data part carrying null. Counting
# non-nil values instead read that as zero variants set and rejected the
# part as malformed.
final readonly & string[] PART_VARIANTS = ["text", "raw", "url", "data"];

# Counts how many of text/raw/url/data are actually set on a raw,
# not-yet-typed Part JSON object. Per specification section 4.1.6,
# exactly one must be — used by both encodePartsRawField (outbound) and
# decodePartsRawField (inbound), each of which picks its own error type
# for a wrong count via outboundPartVariantError/inboundPartVariantError,
# since one direction is a caller mistake and the other is the agent's.
#
# + partMap - One Part-shaped element of a `parts` array, already
#             confirmed to be a map<json>
# + return - How many of the four variant fields are present
isolated function countSetPartVariantsJson(map<json> partMap) returns int {
    int count = 0;
    foreach string variant in PART_VARIANTS {
        if partMap.hasKey(variant) {
            count += 1;
        }
    }
    return count;
}

# The same count as countSetPartVariantsJson, for an already-typed Part —
# used by encodeV03Part and the gRPC binding's Part encode/decode, which
# work with the typed record rather than raw JSON.
#
# + part - The Part to check
# + return - How many of the four variant fields are present
isolated function countSetPartVariants(Part part) returns int {
    int count = 0;
    foreach string variant in PART_VARIANTS {
        if part.hasKey(variant) {
            count += 1;
        }
    }
    return count;
}

# A caller-constructed Part with other than exactly one variant set is a
# library-side/caller mistake -- it never reaches the wire. Matches the
# error type encodeV03Part's own (superseded) zero-set check already
# used, for consistency.
#
# + count - The actual count, for the message
# + return - A typed InternalError
isolated function outboundPartVariantError(int count) returns error {
    string msg = string `Part must have exactly one of text, raw, url, or data set; found ${count}`;
    return error InternalError(msg, message = msg);
}

# An agent that sent a Part with other than exactly one variant set
# violates specification section 4.1.6 -- the agent's fault, not ours,
# so this uses the same error type every other "the agent's response
# doesn't parse into what this call expects" case in this library uses.
#
# + count - The actual count, for the message
# + return - A typed InvalidAgentResponseError
isolated function inboundPartVariantError(int count) returns error {
    string msg = string `Part must have exactly one of text, raw, url, or data set; found ${count}`;
    return error InvalidAgentResponseError(msg, message = msg, code = -32006);
}

# Rewrites the "raw" field of each Part-shaped element of a `parts` array
# (as produced by Message.parts/Artifact.parts) from the integer-array
# shape Ballerina's default byte[] serialization produces into a base64
# string. Only ever touches the "raw" key directly on a Part object; a
# Part's own `data`/`metadata` fields are left completely untouched, so a
# data-Part whose arbitrary JSON payload happens to contain a "raw" key is
# never mistaken for Part.raw.
#
# Also validates each Part-shaped element per specification section
# 4.1.6: exactly one of text/raw/url/data must be set, or this returns an
# InternalError -- a caller building an outbound Part with zero or
# more than one set is a mistake on our side of the wire, never the
# agent's.
#
# + partsValue - The json value of a `parts` field; expected to be a
#                json[] of Part-shaped objects, but tolerates other shapes
#                by returning them unchanged
# + return - The same array with every Part.raw integer-array rewritten to
#            a base64 string, or an InternalError if a Part-shaped
#            element doesn't have exactly one of text/raw/url/data set
isolated function encodePartsRawField(json partsValue) returns json|error {
    if partsValue !is json[] {
        return partsValue;
    }
    json[] result = [];
    foreach json part in partsValue {
        if part !is map<json> {
            result.push(part);
            continue;
        }
        int variantCount = countSetPartVariantsJson(part);
        if variantCount != 1 {
            return outboundPartVariantError(variantCount);
        }
        map<json> partResult = {};
        foreach [string, json] [pk, pv] in part.entries() {
            if pk == "raw" && pv is json[] {
                byte[]|error asBytes = trap pv.cloneWithType();
                if asBytes is byte[] {
                    partResult[pk] = array:toBase64(asBytes);
                    continue;
                }
            }
            partResult[pk] = pv;
        }
        result.push(partResult);
    }
    return result;
}

# The reverse of encodePartsRawField: converts each Part-shaped element's
# "raw" field, when it is a base64 string, back into the integer-array
# shape cloneWithType expects for a byte[] field.
#
# Also validates each Part-shaped element per specification section
# 4.1.6: exactly one of text/raw/url/data must be set, or this returns an
# InvalidAgentResponseError -- an agent sending zero or more than one is
# a malformed response, not a caller-side mistake.
#
# + partsValue - The json value of a `parts` field
# + return - The same array with every Part.raw base64 string rewritten to
#            an integer-array, or an error if a "raw" string on an actual
#            Part isn't valid base64, or an InvalidAgentResponseError if
#            a Part-shaped element doesn't have exactly one of
#            text/raw/url/data set
isolated function decodePartsRawField(json partsValue) returns json|error {
    if partsValue !is json[] {
        return partsValue;
    }
    json[] result = [];
    foreach json part in partsValue {
        if part !is map<json> {
            result.push(part);
            continue;
        }
        int variantCount = countSetPartVariantsJson(part);
        if variantCount != 1 {
            return inboundPartVariantError(variantCount);
        }
        map<json> partResult = {};
        foreach [string, json] [pk, pv] in part.entries() {
            if pk == "raw" && pv is string {
                byte[] decoded = check array:fromBase64(pv);
                partResult[pk] = decoded.toJson();
                continue;
            }
            partResult[pk] = pv;
        }
        result.push(partResult);
    }
    return result;
}

# Rewrites every `Part.raw` in a `json` tree from the integer array
# Ballerina's `byte[]` serialization produces into a base64 string.
#
# Base64 is the protobuf JSON mapping for bytes fields, and the only shape a
# real server parses. Applied once to a tree already produced by `toJson`,
# before it is sent.
#
# Structure-aware, not key-name-driven: it recurses only into the key names
# that can hold a `Part` (see `partBearingContainerKeys`), and within a
# `parts` array touches only each element's "raw" key. A caller's own
# `metadata: {"raw": [1, 2, 3]}` therefore passes through untouched.
#
# + value - A json value (or subtree) to walk
# + return - The same tree with every Part.raw integer-array rewritten to
#            a base64 string, or an InternalError if a Part-shaped
#            element doesn't have exactly one of text/raw/url/data set
isolated function encodeRawBytesForWire(json value) returns json|error {
    if value is json[] {
        json[] result = [];
        foreach json v in value {
            result.push(check encodeRawBytesForWire(v));
        }
        return result;
    }
    if value is map<json> {
        map<json> result = {};
        foreach [string, json] [k, v] in value.entries() {
            if k == "parts" {
                result[k] = check encodePartsRawField(v);
            } else if isPartBearingContainerKey(k) {
                result[k] = check encodeRawBytesForWire(v);
            } else {
                result[k] = v;
            }
        }
        return result;
    }
    return value;
}

# The reverse of encodeRawBytesForWire: converts any "raw" field that is a
# base64 string back into the integer-array shape cloneWithType expects
# for a byte[] field — Ballerina's cloneWithType cannot decode a base64
# string into byte[] itself (confirmed empirically: it requires an
# integer-array json shape), so this must run on every inbound v1.0
# Message/Task/Artifact/StreamResponse/etc. tree before cloneWithType is
# called, or a real server's base64-encoded response would fail to parse
# entirely.
#
# Structure-aware, not key-name-driven: same traversal allow-list as
# encodeRawBytesForWire (see `partBearingContainerKeys`), so a response
# whose free-form `metadata` happens to contain a "raw" key holding
# arbitrary non-base64 text no longer fails to decode — that key is
# simply never visited, because `metadata` is not in the allow-list.
#
# + value - A json value (or subtree) to walk
# + return - The same tree with every Part.raw base64 string rewritten to
#            an integer-array, or an error if a "raw" string on an actual
#            Part isn't valid base64
isolated function decodeRawBytesFromWire(json value) returns json|error {
    if value is json[] {
        json[] result = [];
        foreach json v in value {
            result.push(check decodeRawBytesFromWire(v));
        }
        return result;
    }
    if value is map<json> {
        map<json> result = {};
        foreach [string, json] [k, v] in value.entries() {
            if k == "parts" {
                result[k] = check decodePartsRawField(v);
            } else if isPartBearingContainerKey(k) {
                result[k] = check decodeRawBytesFromWire(v);
            } else {
                result[k] = v;
            }
        }
        return result;
    }
    return value;
}
