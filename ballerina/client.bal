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

// Agent Card resolution, interface selection, and the common Client that
// delegates to the transport-specific client for the binding the card
// declares.
//
// The transport marshaling lives with the client that owns it:
// rest_client.bal.

import ballerina/http;

# Parses a raw AgentCard JSON body into a typed `a2a:AgentCard`.
#
# `securitySchemes`, `securityRequirements`, `signatures`, and each skill's
# `securityRequirements` are parsed tolerantly, so one malformed entry in any
# of them does not fail the whole card.
#
# Pair it with `a2a:fetchAgentCardBody` when the raw body is needed first —
# to verify the card's signature, say — to get the typed card without a
# second round trip.
#
# + body - The raw JSON AgentCard body, straight off the wire
# + return - The parsed card, or an `a2a:VersionNotSupportedError` for a
#            pre-v1.0 card, an `a2a:InvalidAgentResponseError` if `body` is
#            not a JSON object or does not match the AgentCard shape, or an
#            `a2a:InternalError` wrapping anything the tolerant parsers
#            reject
public isolated function parseAgentCardBody(json body) returns AgentCard|Error {
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

isolated function parseAgentCardBodyRaw(json body) returns AgentCard|error {
    map<json>|error cardMapResult = body.ensureType();
    if cardMapResult is error {
        return invalidAgentResponse(string `AgentCard body is not a JSON object: ${cardMapResult.message()}`);
    }
    // Cloned, not aliased. `ensureType` casts without copying, and the field
    // removals below would otherwise strip `signatures`, `securitySchemes`,
    // and `securityRequirements` out of the caller's own `body` -- which
    // `fetchAgentCardBody` hands out precisely so it can be kept for
    // signature verification.
    map<json> cardMap = cardMapResult.clone();

    if isLegacyCard(cardMap) {
        string msg = "AgentCard declares transports the pre-v1.0 way (preferredTransport/"
            + "additionalInterfaces, or a bare top-level url); this library implements A2A v1.0 only";
        return error VersionNotSupportedError(msg, message = msg);
    }

    boolean hasSecuritySchemes = cardMap.hasKey("securitySchemes");
    json securitySchemesJson = hasSecuritySchemes ? cardMap.remove("securitySchemes") : {};

    boolean hasSecurityRequirements = cardMap.hasKey("securityRequirements");
    json securityRequirementsJson = hasSecurityRequirements ? cardMap.remove("securityRequirements") : [];

    boolean hasSignatures = cardMap.hasKey("signatures");
    json signaturesJson = hasSignatures ? cardMap.remove("signatures") : [];

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

    if hasSecuritySchemes {
        card.securitySchemes = check parseSecuritySchemes(securitySchemesJson);
    }
    if hasSecurityRequirements {
        card.securityRequirements = check parseSecurityRequirements(securityRequirementsJson);
    }
    if hasSignatures {
        card.signatures = check parseAgentCardSignatures(signaturesJson);
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
# Reach for this only when the raw body itself is needed — verifying the card's
# `signatures` is the usual reason, since section 8.4.3's canonicalization must
# run on the response exactly as received. Otherwise use `a2a:resolveAgentCard`.
#
# + agentBaseUrl - Root URL of the agent with no path component
# + clientConfig - Optional HTTP configuration for auth, TLS, or proxy
# + headers - Optional default headers
# + return - The raw JSON AgentCard body exactly as received, or an
#            `a2a:InternalError` for a connection failure or malformed JSON
public isolated function fetchAgentCardBody(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns json|Error {
    http:Client|error discoveryClient = new (stripTrailingSlash(agentBaseUrl), clientConfig);
    if discoveryClient is error {
        return wrapTransportError(discoveryClient);
    }
    map<string> reqHeaders = {"A2A-Version": "1.0"};
    foreach [string, string] [k, v] in headers.entries() {
        reqHeaders[k] = v;
    }
    http:Response|error resp = discoveryClient->get(
        "/.well-known/agent-card.json", reqHeaders
    );
    if resp is error {
        return wrapTransportError(resp);
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
#            failure or malformed JSON
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|Error {
    json body = check fetchAgentCardBody(agentBaseUrl, clientConfig, headers);
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
# + card - The agent card to read the endpoint from
# + preferredBinding - Which transport binding to resolve a URL for
# + return - The matching supportedInterfaces entry's url, or an
#            InternalError if the card declares no such entry
isolated function primaryUrl(AgentCard card, TransportBinding preferredBinding) returns string|Error {
    AgentInterface iface = check selectInterface(card, preferredBinding);
    return iface.url;
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
# + return - A VersionNotSupportedError when that interface declares a 0.x
#            protocol version, otherwise nil
isolated function requireV1Interface(AgentCard card, TransportBinding preferredBinding) returns Error? {
    AgentInterface iface = check selectInterface(card, preferredBinding);
    string? version = iface?.protocolVersion;
    // Accept the 1.x line, reject everything else. Testing only for a "0."
    // prefix let "2.0" through, and this client sends v1.0 paths and an
    // `A2A-Version: 1.0` header -- it would speak the wrong protocol
    // confidently. A later 1.x revision stays additive by definition, so it
    // is the one direction worth admitting.
    if version is string && !version.startsWith("1.") {
        string msg = string `AgentCard's ${preferredBinding} interface declares A2A protocol version `
            + string `${version}; this library implements v1.0`;
        return error VersionNotSupportedError(msg, message = msg);
    }
    return ();
}

# An A2A protocol client for a remote agent.
#
# Resolves the Agent Card, requires it to declare an HTTP+JSON interface, and
# delegates every operation to an `a2a:RestClient` built against it.
#
# ```ballerina
# a2a:Client agent = check new ("https://agent.example.com");
# a2a:Task|a2a:Message reply = check agent->sendMessage({message: msg});
# ```
#
# This release implements the HTTP+JSON binding only, so a card declaring only
# JSON-RPC or gRPC is rejected at construction rather than at the first call.
#
# A client is cheap to construct and needs no teardown — there is deliberately
# no `close`, because an `http:Client` routes through a process-wide pool that
# evicts idle connections on its own. Still, prefer one long-lived client per
# agent: construction is wasted work per call. Setting `poolConfig` in
# `clientConfig` opts out of the shared pool into a private one that cannot be
# released, so reuse is required there rather than merely preferred.
public isolated client class Client {
    *ClientMethods;

    private final RestClient delegate;

    # Creates a client pointed at a remote A2A agent.
    #
    # Accepts either the agent's base URL or an already-resolved AgentCard.
    # Given a URL the card is always resolved first: it is what determines
    # the service URL, the protocol version, and the tenant. Given a card,
    # it is passed straight to the transport-specific client, so it is
    # never fetched twice.
    #
    # + agent - The agent's base URL, or an AgentCard already resolved via
    #           resolveAgentCard
    # + clientConfig - Full http:ClientConfiguration. Covers auth, TLS,
    #                  retry, circuit breaker, proxy, timeouts, and
    #                  connection pooling
    # + headers - Default headers merged into every outbound request
    # + tenant - Optional multi-tenant routing identifier; the selected
    #            interface supplies one automatically when it declares it,
    #            and an explicit value wins
    # + requestedExtensions - Optional A2A extension URIs to request
    # + maxReconnectAttempts - Opt-in automatic stream reconnection
    # + credentials - Optional provider consulted per request for the
    #                 credentials the card's `securityRequirements` call
    #                 for, keyed by security-scheme name. Covers the
    #                 schemes that reduce to a single string (API key in a
    #                 header, HTTP bearer/basic); OAuth2, OpenID Connect,
    #                 and mutual TLS belong on `clientConfig.auth`, which
    #                 handles their token exchange properly
    # + return - A typed Error: from resolveAgentCard, if the card
    #            declares no HTTP+JSON interface, or from the underlying
    #            RestClient's own construction
    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            int maxReconnectAttempts = 0,
            CredentialProvider? credentials = ()) returns Error? {
        AgentCard card = agent is string
            ? check resolveAgentCard(agent, clientConfig, headers)
            : agent;
        self.delegate = check new RestClient(card, clientConfig, headers, tenant,
                requestedExtensions, maxReconnectAttempts, credentials);
    }

    # Sends a message to the remote agent.
    #
    # + request - The message and its send options
    # + return - A Task or a Message on success, or a typed Error on failure
    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error {
        return self.delegate->sendMessage(request);
    }

    # Sends a message and receives updates as they happen.
    #
    # + request - The message and its send options
    # + return - A stream of StreamResponse values, or a typed Error
    isolated remote function sendStreamingMessage(SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.delegate->sendStreamingMessage(request);
    }

    # Retrieves the current state of a task.
    #
    # + request - The task identifier, and optionally how much history to include
    # + return - The current Task, or a TaskNotFoundError (or other typed
    #            Error) if unknown
    isolated remote function getTask(GetTaskRequest request) returns Task|Error {
        return self.delegate->getTask(request);
    }

    # Requests cancellation of an in-progress task.
    #
    # + request - The task identifier, and any additional context for the agent
    # + return - The updated Task, or a TaskNotFoundError/TaskNotCancelableError
    #            (or other typed Error)
    isolated remote function cancelTask(CancelTaskRequest request) returns Task|Error {
        return self.delegate->cancelTask(request);
    }

    # Opens a stream on an existing task.
    #
    # + request - The task identifier
    # + return - A stream of StreamResponse values, or a typed Error
    isolated remote function subscribeToTask(SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        return self.delegate->subscribeToTask(request);
    }

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + request - Optional filter and pagination parameters
    # + return - A page of matching tasks, or a typed Error
    isolated remote function listTasks(ListTasksRequest request = {}) returns ListTasksResponse|Error {
        return self.delegate->listTasks(request);
    }

    # Registers a webhook to receive updates for a task.
    #
    # + request - The webhook configuration; its taskId identifies the task
    # + return - The created config as the server persisted it, or a
    #            PushNotificationNotSupportedError (or other typed Error)
    isolated remote function createTaskPushNotificationConfig(TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        return self.delegate->createTaskPushNotificationConfig(request);
    }

    # Retrieves a previously registered push-notification webhook config.
    #
    # + request - The parent task id and the config's own id
    # + return - The config, or a PushNotificationNotSupportedError/
    #            TaskNotFoundError (or other typed Error)
    isolated remote function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request)
            returns TaskPushNotificationConfig|Error {
        return self.delegate->getTaskPushNotificationConfig(request);
    }

    # Lists all push-notification webhook configs registered for a task.
    #
    # + request - The parent task id, and optional pagination parameters
    # + return - A page of matching configs, or a
    #            PushNotificationNotSupportedError (or other typed Error)
    isolated remote function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request)
            returns ListTaskPushNotificationConfigsResponse|Error {
        return self.delegate->listTaskPushNotificationConfigs(request);
    }

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # + request - The parent task id and the config's own id
    # + return - Nil on success, or a typed Error
    isolated remote function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request)
            returns Error? {
        return self.delegate->deleteTaskPushNotificationConfig(request);
    }

    # Retrieves the agent's extended AgentCard.
    #
    # + request - Optional routing parameters
    # + return - The extended AgentCard, or a typed Error
    isolated remote function getExtendedAgentCard(GetExtendedAgentCardRequest request = {}) returns AgentCard|Error {
        return self.delegate->getExtendedAgentCard(request);
    }
}
