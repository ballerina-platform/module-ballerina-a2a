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

// Agent Card resolution and interface selection: the free functions that
// fetch and parse a card, and pick the interface to construct a client
// against.
//
// The client itself, and the transport marshaling, live with the binding
// that owns them: http_client.bal.

import ballerina/http;

# Parses a raw AgentCard JSON body into a typed `a2a:AgentCard`.
#
# `securitySchemes`, `securityRequirements`, `signatures`, and each skill's
# `securityRequirements` are parsed tolerantly, so one malformed entry in any
# of them does not fail the whole card.
#
# Module-private: a caller reaches a parsed card through
# `a2a:resolveAgentCard`. It parses in place and so may mutate `body`; the
# internal callers pass a freshly fetched body they discard immediately after.
#
# + body - The raw JSON AgentCard body, straight off the wire
# + return - The parsed card, or an `a2a:VersionNotSupportedError` for a
#            pre-v1.0 card, an `a2a:InvalidAgentResponseError` if `body` is
#            not a JSON object or does not match the AgentCard shape, or an
#            `a2a:InternalError` wrapping anything the tolerant parsers
#            reject
isolated function parseAgentCardBody(json body) returns AgentCard|Error {
    AgentCard|error result = parseAgentCardBodyRaw(body);
    if result is error {
        return wrapTransportError(result);
    }
    return result;
}

# Whether a raw card map is a pre-v1.0 (A2A v0.3) card.
#
# v0.3 declared transports with `preferredTransport` plus
# `additionalInterfaces`, or with a bare top-level `url`; v1.0 replaced all
# three with the required `supportedInterfaces`. Detected explicitly so such
# a card fails by version rather than as a missing-field shape mismatch,
# which would say nothing about why.
#
# + cardMap - The raw card map
# + return - Whether this card predates v1.0
isolated function isLegacyCard(map<json> cardMap) returns boolean {
    json? existing = cardMap["supportedInterfaces"];
    if existing is json[] && existing.length() > 0 {
        return false;
    }
    return cardMap.hasKey("preferredTransport")
        || cardMap.hasKey("additionalInterfaces")
        || cardMap.hasKey("url");
}

# The AgentCard fields carried in a v1.0-specific wire dialect that
# `cloneWithType(AgentCard)` cannot read directly. Lifting them off the raw
# body through this record gives typed field access instead of `hasKey` and
# string-key lookups; each is then parsed by its dialect-aware helper and set
# back on the card. Open (`json...`), so it carries the whole body and every
# other field falls through untouched.
type DialectCardFields record {|
    # Raw `securitySchemes`, parsed by `parseSecuritySchemes`
    json securitySchemes?;
    # Raw `securityRequirements`, parsed by `parseSecurityRequirements`
    json securityRequirements?;
    # Raw `signatures`, parsed by `parseAgentCardSignatures`
    json signatures?;
    json...;
|};

isolated function parseAgentCardBodyRaw(json body) returns AgentCard|error {
    map<json>|error cardMapResult = body.ensureType();
    if cardMapResult is error {
        return invalidAgentResponse(string `AgentCard body is not a JSON object: ${cardMapResult.message()}`);
    }
    // Aliased, not cloned. `ensureType` casts without copying, so `cardMap`
    // shares storage with `body`, and the field removals below mutate it. That
    // is safe here: this function is module-private and its callers
    // (`resolveAgentCard`, `getExtendedAgentCard`) discard `body` the moment it
    // returns, so nothing can observe the mutation.
    map<json> cardMap = cardMapResult;

    if isLegacyCard(cardMap) {
        string msg = "AgentCard declares transports the pre-v1.0 way (preferredTransport/"
            + "additionalInterfaces, or a bare top-level url); this library implements A2A v1.0 only";
        return error VersionNotSupportedError(msg, message = msg);
    }

    // Read the dialect-carrying fields by typed name, then drop them from the
    // map so the strict clone below never sees the wire dialect.
    DialectCardFields dialect = check cardMap.cloneWithType();
    foreach string fieldName in ["securitySchemes", "securityRequirements", "signatures"] {
        _ = cardMap.removeIfHasKey(fieldName);
    }

    // Skill-level securityRequirements needs the same tolerant treatment,
    // but every other AgentSkill field should still be strictly validated
    // by the main clone below -- so only that one sub-field is pulled out
    // of each skill first, not the whole skill.
    json? skillsField = cardMap["skills"];
    SecurityRequirement[][] perSkillSecurityRequirements = [];
    if skillsField is json[] {
        json[] strippedSkills = [];
        foreach json skillJson in skillsField {
            if skillJson is map<json> {
                map<json> skillMap = skillJson.clone();
                json skillSecurityRequirementsJson = skillMap.hasKey("securityRequirements")
                    ? skillMap.remove("securityRequirements") : [];
                perSkillSecurityRequirements.push(check parseSecurityRequirements(skillSecurityRequirementsJson));
                strippedSkills.push(skillMap);
            } else {
                perSkillSecurityRequirements.push([]);
                strippedSkills.push(skillJson);
            }
        }
        cardMap["skills"] = strippedSkills;
    }

    AgentCard|error cardResult = cardMap.cloneWithType(AgentCard);
    if cardResult is error {
        return invalidAgentResponse(string `AgentCard did not match the expected shape: ${cardResult.message()}`);
    }
    AgentCard card = cardResult;

    json? schemes = dialect?.securitySchemes;
    if schemes is map<json> {
        card.securitySchemes = check parseSecuritySchemes(schemes);
    }
    json? requirements = dialect?.securityRequirements;
    if requirements is json[] {
        card.securityRequirements = check parseSecurityRequirements(requirements);
    }
    json? signatures = dialect?.signatures;
    if signatures is json[] {
        card.signatures = check parseAgentCardSignatures(signatures);
    }
    foreach int i in 0 ..< card.skills.length() {
        if i < perSkillSecurityRequirements.length() {
            card.skills[i].securityRequirements = perSkillSecurityRequirements[i];
        }
    }

    return card;
}

# Removes a single trailing slash from a base URL.
#
# An AgentInterface URL may legitimately end in `/`, and `http:Client` joins
# such a base with a path starting in `/.well-known/...` into a double slash,
# which 404s against every well-known endpoint tested.
#
# + url - A base URL, possibly with a trailing slash
# + return - The same URL with any single trailing slash removed
isolated function stripTrailingSlash(string url) returns string {
    if url.endsWith("/") {
        return url.substring(0, url.length() - 1);
    }
    return url;
}

# Fetches a remote agent's Agent Card as raw, unparsed JSON from its
# well-known endpoint.
#
# The canonical discovery path is `/.well-known/agent-card.json` relative to
# the agent's base URL (specification section 8.2). That endpoint is public and
# unauthenticated by design (section 14.3), so `headers` is for proxy or
# tracing use rather than credentials.
#
# Module-private: `a2a:resolveAgentCard` is the public entry point. This returns
# the body exactly as received, which is what the parse step then types.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers
# + return - The raw JSON AgentCard body exactly as received, or an
#            `a2a:InternalError` for a connection failure, malformed JSON, or
#            an OAuth2 token that cannot be obtained
isolated function fetchAgentCardBody(
        string agentBaseUrl,
        map<string> headers = {},
        *http:ClientConfiguration clientConfig) returns json|Error {
    http:Client discoveryClient = check newHttpClient(stripTrailingSlash(agentBaseUrl), clientConfig);
    map<string> reqHeaders = {[A2A_VERSION_HEADER]: A2A_VERSION};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    http:Response|error resp = discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp is error {
        return wrapTransportError(resp);
    }
    if resp.statusCode == 401 || resp.statusCode == 403 {
        // A card behind authentication: say so, rather than a generic failure.
        return toA2AErrorFromRest(resp.statusCode, (), challengesOf(resp));
    }
    if resp.statusCode != 200 {
        return error InternalError(
            string `Agent Card fetch failed with HTTP ${resp.statusCode}`,
            code = resp.statusCode
        );
    }
    json|error payload = resp.getJsonPayload();
    if payload is error {
        return wrapTransportError(payload);
    }
    return payload;
}

# Fetches and parses a remote agent's Agent Card from its well-known
# endpoint.
#
# ```ballerina
# a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
# ```
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers
# + return - The parsed card, or an `a2a:InternalError` for a connection
#            failure, malformed JSON, or an OAuth2 token that cannot be
#            obtained (a wrong client secret, an unreachable token endpoint)
public isolated function resolveAgentCard(
        string agentBaseUrl,
        map<string> headers = {},
        *http:ClientConfiguration clientConfig) returns AgentCard|Error {
    json body = check fetchAgentCardBody(agentBaseUrl, headers, clientConfig = clientConfig);
    return parseAgentCardBody(body);
}

# The A2A transport bindings this library knows how to name.
#
# Not public: a caller selects a binding by choosing a client type, never by
# naming one. Only HTTP+JSON is implemented in this release; the other two
# are recognised so that a card declaring them can be read and reported on
# rather than mistaken for malformed.
type TransportBinding "JSONRPC"|"HTTP+JSON"|"GRPC";

// Named, not public -- same reasoning as TransportBinding itself: these
// exist so call sites don't repeat the bare string literals, not to give
// callers a way to name a binding themselves.
const TransportBinding JSONRPC = "JSONRPC";
const TransportBinding HTTP_JSON = "HTTP+JSON";
const TransportBinding GRPC = "GRPC";

# Resolves the whole matched AgentInterface for a binding, not just its url
# — callers need the interface's own tenant and protocolVersion, which must
# come from the same entry the url did, not be independently re-derived (a
# card can list several interfaces with different tenant/version values).
#
# Among several entries declaring the same binding, the earliest wins.
# Specification section 8.3.2 orders `supportedInterfaces` by the server's own
# preference, so the order is the server's decision, not this library's.
#
# + card - The agent card to read the endpoint from
# + preferredBinding - Which transport binding to look for
# + return - The earliest supportedInterfaces entry declaring the matching
#            protocolBinding, or an InternalError if none exists — a
#            card/binding mismatch, not a wire-protocol error
isolated function selectInterface(
        AgentCard card,
        TransportBinding preferredBinding) returns AgentInterface|Error {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == preferredBinding {
            return iface;
        }
    }
    string msg = string `AgentCard has no ${preferredBinding} entry in supportedInterfaces`;
    return error InternalError(msg, message = msg);
}

# Resolves the URL to construct a client against.
#
# Stripped of any trailing slash for the same reason `stripTrailingSlash`'s
# own doc comment gives for card discovery: `http:Client` joins a base
# ending in `/` with a path starting in `/` into a double slash
# (`//message:send`), which the server 404s. Confirmed directly, against a
# real `@a2a-js/sdk` agent: it advertises exactly this shape for a
# root-mounted deployment (`http://host:port/`), and every operation
# against it failed until this was stripped.
#
# + card - The agent card to read the endpoint from
# + preferredBinding - Which transport binding to resolve a URL for
# + return - The matching supportedInterfaces entry's url, or an
#            InternalError if the card declares no such entry
isolated function primaryUrl(AgentCard card, TransportBinding preferredBinding) returns string|Error {
    AgentInterface iface = check selectInterface(card, preferredBinding);
    return stripTrailingSlash(iface.url);
}

# Rejects a card whose interface for the given binding declares a pre-v1.0
# protocol version.
#
# The card's shape alone does not settle this: a card can carry a
# v1.0-shaped `supportedInterfaces` array whose entries declare
# `protocolVersion: "0.3"`. Left unchecked, this library would speak v1.0
# to a v0.3 agent and fail at the first call with whatever that agent made
# of the request. Checking at construction turns that into an immediate,
# named error instead.
#
# + card - The resolved Agent Card
# + preferredBinding - The binding whose interface to read the version from
# + return - A VersionNotSupportedError when that interface declares any
#            protocol version other than exactly 1.0, otherwise nil
isolated function requireV1Interface(AgentCard card, TransportBinding preferredBinding) returns Error? {
    AgentInterface iface = check selectInterface(card, preferredBinding);
    string? version = iface?.protocolVersion;
    // Accept only the exact version this client implements. Specification
    // section 3.6.2 requires processing to match Major.Minor exactly and
    // gives no guarantee that a later 1.x minor stays wire-compatible with
    // 1.0 -- so "1.1" is exactly as unsafe to speak v1.0 paths to as "2.0"
    // or "0.3" is. Testing only for a "0." or non-"1." prefix let both
    // "1.1" and "2.0" through.
    if version is string && version != "1.0" {
        string msg = string `AgentCard's ${preferredBinding} interface declares A2A protocol version `
            + string `${version}; this library implements v1.0`;
        return error VersionNotSupportedError(msg, message = msg);
    }
    return;
}
