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

import ballerina/test;

@test:Config {}
function testPartTextVariantRoundTrip() returns error? {
    Part original = {text: "What is the weather in Colombo?"};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.raw is (), "raw should be nil for a text Part");
    test:assertTrue(decoded?.url is (), "url should be nil for a text Part");
    test:assertTrue(decoded?.data is (), "data should be nil for a text Part");
}

@test:Config {}
function testPartRawVariantRoundTrip() returns error? {
    byte[] bytes = "some file content".toBytes();
    Part original = {raw: bytes, mediaType: "text/plain"};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded?.raw, bytes);
    test:assertTrue(decoded?.text is (), "text should be nil for a raw Part");
    test:assertTrue(decoded?.url is (), "url should be nil for a raw Part");
    test:assertTrue(decoded?.data is (), "data should be nil for a raw Part");
}

@test:Config {}
function testPartUrlVariantRoundTrip() returns error? {
    Part original = {url: "https://example.com/report.pdf", mediaType: "application/pdf"};
    Part decoded = check original.toJson().cloneWithType(Part);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.text is (), "text should be nil for a url Part");
    test:assertTrue(decoded?.raw is (), "raw should be nil for a url Part");
    test:assertTrue(decoded?.data is (), "data should be nil for a url Part");
}

@test:Config {}
function testPartFileVariantRoundTrip() returns error? {
    Part original = {raw: "hello".toBytes(), filename: "greeting.txt", mediaType: "text/plain"};
    json encoded = original.toJson();
    Part decoded = check encoded.cloneWithType(Part);
    test:assertEquals(decoded, original);
}

@test:Config {}
function testPartDataVariantRoundTrip() returns error? {
    Part original = {data: {"key": "value", "count": 3}, mediaType: "application/json"};
    json encoded = original.toJson();
    Part decoded = check encoded.cloneWithType(Part);
    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.text is (), "text should be nil for a data Part");
    test:assertTrue(decoded?.raw is (), "raw should be nil for a data Part");
    test:assertTrue(decoded?.url is (), "url should be nil for a data Part");
}

@test:Config {}
function testEncodeRawBytesForWireConvertsIntArrayToBase64() returns error? {
    Part original = {raw: "hello world".toBytes(), mediaType: "application/octet-stream"};
    // The walker is structure-aware: it only descends into a "parts"
    // array, matching how client.bal always invokes it (on a whole
    // Message/Task/etc. tree, never on a bare Part), so wrap the Part the
    // same way a real Message would.
    Message container = {messageId: "msg-1", role: ROLE_USER, parts: [original]};
    json defaultEncoded = container.toJson();
    // Confirm the bug is real: default toJson() produces an int array, not a string.
    map<json> defaultMap = check defaultEncoded.ensureType();
    json[] defaultParts = check defaultMap["parts"].ensureType();
    map<json> defaultPart = check defaultParts[0].ensureType();
    test:assertTrue(defaultPart["raw"] is json[], "sanity check: Ballerina's default toJson() must produce an int array for byte[] — if this fails, the underlying Ballerina behavior changed and this whole fix may be unnecessary");

    json fixed = check encodeRawBytesForWire(defaultEncoded);
    map<json> fixedMap = check fixed.ensureType();
    json[] fixedParts = check fixedMap["parts"].ensureType();
    map<json> fixedPart = check fixedParts[0].ensureType();
    test:assertTrue(fixedPart["raw"] is string, "after encodeRawBytesForWire, Part.raw must be a base64 string, matching the wire encoding every real A2A implementation expects");
}

@test:Config {}
function testDecodeRawBytesFromWireRoundTripsThroughEncodeRawBytesForWire() returns error? {
    byte[] originalBytes = "hello world, some bytes".toBytes();
    Part original = {raw: originalBytes, mediaType: "application/octet-stream"};
    Message container = {messageId: "msg-1", role: ROLE_USER, parts: [original]};
    json wireForm = check encodeRawBytesForWire(container.toJson());
    json restoredForm = check decodeRawBytesFromWire(wireForm);
    Message decoded = check restoredForm.cloneWithType(Message);
    test:assertEquals(decoded.parts[0]?.raw, originalBytes);
}

@test:Config {}
function testDecodeRawBytesFromWireLeavesUnrelatedMetadataRawKeyUntouched() returns error? {
    // A response whose free-form metadata happens to contain a key
    // literally named "raw" holding arbitrary non-base64 text must not
    // fail to decode, and the metadata must pass through byte-for-byte —
    // metadata is never in the walker's traversal allow-list.
    json payload = {
        "id": "task-1",
        "status": {"state": "TASK_STATE_COMPLETED"},
        "metadata": {"raw": "arbitrary non-base64 text", "other": 42},
        "history": [
            {
                "messageId": "msg-1",
                "role": "ROLE_AGENT",
                "parts": [{"raw": "aGVsbG8=", "mediaType": "text/plain"}]
            }
        ]
    };
    json decoded = check decodeRawBytesFromWire(payload);
    Task task = check decoded.cloneWithType(Task);

    test:assertEquals(task?.metadata, {"raw": "arbitrary non-base64 text", "other": 42});
    test:assertEquals((task.history ?: [])[0].parts[0]?.raw, "hello".toBytes());
}

@test:Config {}
function testEncodeRawBytesForWireLeavesDataPartRawKeyUntouched() returns error? {
    // A data-Part's own arbitrary JSON payload may legitimately contain a
    // key named "raw" that has nothing to do with Part.raw — the encode
    // walker must never mistake it for bytes to base64-encode, since
    // Part.data is free-form json, not in the traversal allow-list.
    Part dataPart = {data: {"raw": [1, 2, 3], "note": "caller's own data"}, mediaType: "application/json"};
    Message container = {messageId: "msg-1", role: ROLE_USER, parts: [dataPart]};

    json encoded = check encodeRawBytesForWire(container.toJson());
    map<json> encodedMap = check encoded.ensureType();
    json[] encodedParts = check encodedMap["parts"].ensureType();
    Part decodedPart = check encodedParts[0].cloneWithType(Part);

    test:assertEquals(decodedPart?.data, {"raw": [1, 2, 3], "note": "caller's own data"});
}

@test:Config {}
function testDecodeRawBytesFromWireHandlesRealisticExternalPayload() returns error? {
    // Simulates what a real, spec-conformant external server would actually
    // send on the wire: a base64 string, not Ballerina's own int-array
    // shape — this is the case that matters for real interop, not just
    // round-tripping through our own encode function.
    json externalPayload = {
        "parts": [
            {"raw": "aGVsbG8gd29ybGQ=", "mediaType": "text/plain"} // "hello world" in base64
        ]
    };
    json decoded = check decodeRawBytesFromWire(externalPayload);
    map<json> decodedMap = check decoded.ensureType();
    json[] parts = check decodedMap["parts"].ensureType();
    Part firstPart = check parts[0].cloneWithType(Part);
    test:assertEquals(firstPart?.raw, "hello world".toBytes());
}

@test:Config {}
function testPartToleratesUnrecognizedField() returns error? {
    json payload = {
        text: "What is the weather in Colombo?",
        futureField: "some value from a newer spec revision"
    };

    Part decoded = check payload.cloneWithType(Part);

    test:assertEquals(decoded?.text, "What is the weather in Colombo?");

    json reserialized = decoded.toJson();
    test:assertEquals(
        (check reserialized.futureField),
        "some value from a newer spec revision"
    );
}

@test:Config {}
function testMessageMinimalRoundTrip() returns error? {
    Message original = {
        messageId: "msg-1",
        role: ROLE_USER,
        parts: [{text: "What is the weather in Colombo?"}]
    };
    Message decoded = check original.toJson().cloneWithType(Message);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.contextId is (), "contextId should be nil");
    test:assertTrue(decoded?.taskId is (), "taskId should be nil");
    test:assertTrue(decoded?.metadata is (), "metadata should be nil");
    // Both are optional in the specification, so an absent field decodes to
    // absent -- not to an empty array. Emitting `"extensions": []` for a
    // field the sender never set is a value, not a non-statement, and
    // specification 5.7 relies on that distinction for AgentCard signature
    // canonicalization.
    test:assertTrue(decoded?.referenceTaskIds is (), "referenceTaskIds should be absent, not defaulted to []");
    test:assertTrue(decoded?.extensions is (), "extensions should be absent, not defaulted to []");
}

@test:Config {}
function testMessageFullRoundTrip() returns error? {
    Message original = {
        messageId: "msg-2",
        role: ROLE_AGENT,
        parts: [
            {text: "Here is the forecast."},
            {data: {temperature: 29, condition: "partly cloudy"}}
        ],
        contextId: "ctx-1",
        taskId: "task-1",
        referenceTaskIds: ["task-0"],
        extensions: ["https://example.com/extensions/weather"],
        metadata: {"source": "weather-agent"}
    };
    Message decoded = check original.toJson().cloneWithType(Message);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testMessageToleratesUnrecognizedField() returns error? {
    json payload = {
        messageId: "msg-3",
        role: "ROLE_USER",
        parts: [{text: "What is the weather in Colombo?"}],
        futureField: "some value from a newer spec revision"
    };

    Message decoded = check payload.cloneWithType(Message);

    test:assertEquals(decoded.messageId, "msg-3");

    json reserialized = decoded.toJson();
    test:assertEquals(
        (check reserialized.futureField),
        "some value from a newer spec revision"
    );
}

@test:Config {}
function testAgentProviderRoundTrip() returns error? {
    AgentProvider original = {organization: "Acme Corp", url: "https://acme.example.com", contactEmail: "support@acme.example.com"};
    AgentProvider decoded = check original.toJson().cloneWithType(AgentProvider);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentProviderToleratesUnrecognizedField() returns error? {
    json payload = {
        organization: "Acme Corp",
        url: "https://acme.example.com",
        futureField: "some value from a newer spec revision"
    };

    AgentProvider decoded = check payload.cloneWithType(AgentProvider);

    test:assertEquals(decoded.organization, "Acme Corp");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentExtensionRoundTrip() returns error? {
    AgentExtension original = {
        uri: "https://example.com/extensions/weather",
        description: "Weather lookups",
        required: true,
        params: {"unit": "celsius"}
    };
    AgentExtension decoded = check original.toJson().cloneWithType(AgentExtension);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentExtensionToleratesUnrecognizedField() returns error? {
    json payload = {
        uri: "https://example.com/extensions/weather",
        futureField: "some value from a newer spec revision"
    };

    AgentExtension decoded = check payload.cloneWithType(AgentExtension);

    test:assertEquals(decoded.uri, "https://example.com/extensions/weather");
    test:assertEquals(decoded.required, false);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentCapabilitiesRoundTrip() returns error? {
    AgentCapabilities original = {
        streaming: true,
        pushNotifications: true,
        extendedAgentCard: true,
        extensions: [{uri: "https://example.com/extensions/weather"}]
    };
    AgentCapabilities decoded = check original.toJson().cloneWithType(AgentCapabilities);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCapabilitiesToleratesUnrecognizedField() returns error? {
    json payload = {futureField: "some value from a newer spec revision"};

    AgentCapabilities decoded = check payload.cloneWithType(AgentCapabilities);

    test:assertEquals(decoded.streaming, false);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentSkillRoundTrip() returns error? {
    AgentSkill original = {
        id: "weather-lookup",
        name: "Weather Lookup",
        description: "Reports current weather for a city",
        tags: ["weather"],
        inputModes: ["text"],
        outputModes: ["text"],
        examples: ["What is the weather in Colombo?"],
        securityRequirements: [{"bearerAuth": []}]
    };
    AgentSkill decoded = check original.toJson().cloneWithType(AgentSkill);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentSkillToleratesUnrecognizedField() returns error? {
    json payload = {
        id: "weather-lookup",
        name: "Weather Lookup",
        description: "Reports current weather for a city",
        futureField: "some value from a newer spec revision", tags: []};

    AgentSkill decoded = check payload.cloneWithType(AgentSkill);

    test:assertEquals(decoded.id, "weather-lookup");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentInterfaceRoundTrip() returns error? {
    AgentInterface original = {
        url: "https://acme.example.com/a2a",
        protocolBinding: "JSONRPC",
        protocolVersion: "1.0",
        tenant: "acme-corp"
    };
    AgentInterface decoded = check original.toJson().cloneWithType(AgentInterface);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentInterfaceToleratesUnrecognizedField() returns error? {
    json payload = {
        url: "https://acme.example.com/a2a",
        protocolBinding: "JSONRPC",
        futureField: "some value from a newer spec revision", protocolVersion: "1.0"};

    AgentInterface decoded = check payload.cloneWithType(AgentInterface);

    test:assertEquals(decoded.protocolBinding, "JSONRPC");
    test:assertTrue(decoded?.tenant is (), "tenant should be nil");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentCardCompositeRoundTrip() returns error? {
    AgentCard original = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        provider: {organization: "Acme Corp", url: "https://acme.example.com"},
        documentationUrl: "https://weather.example.com/docs",
        capabilities: {streaming: true, pushNotifications: true},
        supportedInterfaces: [
            {url: "https://weather.example.com/a2a", protocolBinding: "JSONRPC", protocolVersion: "1.0"},
            {url: "https://weather.example.com/tenant/acme", protocolBinding: "JSONRPC", tenant: "acme-corp", protocolVersion: "1.0"}
        ],
        securitySchemes: {"bearerAuth": <HttpAuthSecurityScheme>{scheme: "bearer"}},
        securityRequirements: [{"bearerAuth": []}],
        skills: [
            {
                id: "weather-lookup",
                name: "Weather Lookup",
                description: "Reports current weather for a city",
                tags: ["weather"],
                examples: ["What is the weather in Colombo?"]
            },
            {
                id: "forecast",
                name: "Forecast",
                description: "Reports a multi-day forecast for a city",
                tags: ["weather", "forecast"]
            }
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCardToleratesUnrecognizedField() returns error? {
    json payload = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        url: "https://weather.example.com/a2a",
        capabilities: {},
        supportedInterfaces: [
            {url: "https://weather.example.com/a2a", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        skills: [],
        futureField: "some value from a newer spec revision",
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };

    AgentCard decoded = check payload.cloneWithType(AgentCard);

    test:assertEquals(decoded.name, "Weather Agent");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskStatusRoundTrip() returns error? {
    TaskStatus original = {
        state: TASK_STATE_INPUT_REQUIRED,
        message: {messageId: "msg-1", role: ROLE_AGENT, parts: [{text: "Which city?"}]},
        timestamp: "2023-10-27T10:00:00Z"
    };
    TaskStatus decoded = check original.toJson().cloneWithType(TaskStatus);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskStatusToleratesUnrecognizedField() returns error? {
    json payload = {
        state: "TASK_STATE_WORKING",
        futureField: "some value from a newer spec revision"
    };

    TaskStatus decoded = check payload.cloneWithType(TaskStatus);

    test:assertEquals(decoded.state, TASK_STATE_WORKING);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testArtifactRoundTrip() returns error? {
    Artifact original = {
        artifactId: "art-1",
        name: "Forecast",
        description: "Three-day forecast",
        parts: [{text: "29 degrees Celsius and partly cloudy."}],
        metadata: {"units": "celsius"},
        extensions: ["https://example.com/extensions/weather"]
    };
    Artifact decoded = check original.toJson().cloneWithType(Artifact);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testArtifactToleratesUnrecognizedField() returns error? {
    json payload = {
        artifactId: "art-1",
        parts: [{text: "29 degrees Celsius and partly cloudy."}],
        futureField: "some value from a newer spec revision"
    };

    Artifact decoded = check payload.cloneWithType(Artifact);

    test:assertEquals(decoded.artifactId, "art-1");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskCompositeRoundTrip() returns error? {
    Task original = {
        id: "task-7f3a9b2c",
        contextId: "ctx-4e8d1a6f",
        status: {state: TASK_STATE_COMPLETED, timestamp: "2026-07-20T14:32:11Z"},
        history: [
            {messageId: "msg-1", role: ROLE_USER, parts: [{text: "What is the weather in Colombo?"}]},
            {messageId: "msg-2", role: ROLE_AGENT, parts: [{text: "Let me check that for you."}]}
        ],
        artifacts: [
            {artifactId: "art-9c2e", parts: [{text: "29 degrees Celsius and partly cloudy."}]},
            {
                artifactId: "art-9c2f",
                name: "Forecast chart",
                parts: [{url: "https://weather.example.com/chart.png", mediaType: "image/png"}],
                extensions: ["https://example.com/extensions/weather"]
            }
        ],
        metadata: {"source": "weather-agent"}
    };
    Task decoded = check original.toJson().cloneWithType(Task);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskToleratesUnrecognizedField() returns error? {
    json payload = {
        id: "task-1",
        status: {state: "TASK_STATE_SUBMITTED"},
        futureField: "some value from a newer spec revision"
    };

    Task decoded = check payload.cloneWithType(Task);

    test:assertEquals(decoded.id, "task-1");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskStatusUpdateEventRoundTrip() returns error? {
    TaskStatusUpdateEvent original = {
        taskId: "task-1",
        contextId: "ctx-1",
        status: {state: TASK_STATE_WORKING},
        metadata: {"progress": 0.5}
    };
    TaskStatusUpdateEvent decoded = check original.toJson().cloneWithType(TaskStatusUpdateEvent);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskStatusUpdateEventToleratesUnrecognizedField() returns error? {
    json payload = {
        taskId: "task-1",
        contextId: "ctx-1",
        status: {state: "TASK_STATE_WORKING"},
        futureField: "some value from a newer spec revision"
    };

    TaskStatusUpdateEvent decoded = check payload.cloneWithType(TaskStatusUpdateEvent);

    test:assertEquals(decoded.taskId, "task-1");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskArtifactUpdateEventRoundTrip() returns error? {
    TaskArtifactUpdateEvent original = {
        taskId: "task-1",
        contextId: "ctx-1",
        artifact: {artifactId: "art-1", parts: [{text: "29 degrees Celsius"}]},
        append: true,
        lastChunk: true,
        metadata: {"chunk": 2}
    };
    TaskArtifactUpdateEvent decoded = check original.toJson().cloneWithType(TaskArtifactUpdateEvent);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testTaskArtifactUpdateEventToleratesUnrecognizedField() returns error? {
    json payload = {
        taskId: "task-1",
        contextId: "ctx-1",
        artifact: {artifactId: "art-1", parts: [{text: "29 degrees Celsius"}]},
        futureField: "some value from a newer spec revision"
    };

    TaskArtifactUpdateEvent decoded = check payload.cloneWithType(TaskArtifactUpdateEvent);

    test:assertEquals(decoded.taskId, "task-1");
    test:assertEquals(decoded.append, false);
    test:assertEquals(decoded.lastChunk, false);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

// StreamResponse is a union of the four arms, so an event *is* one of them
// rather than a wrapper holding one. The wire form is still the keyed
// envelope, which decodeStreamResponseEnvelope unwraps.
//
@test:Config {}
function testStreamResponseEnvelopeDecodesToItsArm() returns error? {
    json envelope = {
        statusUpdate: {taskId: "task-1", contextId: "ctx-1", status: {state: TASK_STATE_COMPLETED}}
    };

    StreamResponse? decoded = check decodeStreamResponseEnvelope(envelope);

    test:assertTrue(decoded is TaskStatusUpdateEvent, "the statusUpdate arm should decode to its own type");
    if decoded is TaskStatusUpdateEvent {
        test:assertEquals(decoded.taskId, "task-1");
        test:assertEquals(decoded.status.state, TASK_STATE_COMPLETED);
    }
    test:assertFalse(decoded is Task, "and must not also satisfy another arm");
    test:assertFalse(decoded is TaskArtifactUpdateEvent);
}

// An arm's own unrecognized fields still round-trip, since every arm type is
// an open record.
//
@test:Config {}
function testStreamResponseArmToleratesUnrecognizedField() returns error? {
    json envelope = {
        message: {
            messageId: "msg-1",
            role: "ROLE_AGENT",
            parts: [{text: "Hello"}],
            futureField: "some value from a newer spec revision"
        }
    };

    StreamResponse? decoded = check decodeStreamResponseEnvelope(envelope);

    test:assertTrue(decoded is Message, "message should decode");
    if decoded is Message {
        json reserialized = decoded.toJson();
        test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
    }
}

// An envelope naming an arm this client does not know is skipped, not
// rejected: StreamResponse is a specification oneof, and a later revision may
// add an arm. Failing the stream on the first such event would break every
// existing client the moment that happened.
//
@test:Config {}
function testStreamResponseEnvelopeSkipsUnknownArm() returns error? {
    json envelope = {futureEvent: {someField: 1}};

    StreamResponse? decoded = check decodeStreamResponseEnvelope(envelope);

    test:assertTrue(decoded is (), "an unrecognized arm yields () so the caller can skip the event");
}

// A conformant oneof sets exactly one arm; two is malformed, and silently
// picking the first would hide a broken agent.
@test:Config {}
function testStreamResponseEnvelopeRejectsTwoArms() {
    json envelope = {
        task: {id: "t1", status: {state: TASK_STATE_WORKING}},
        message: {messageId: "m1", role: "ROLE_AGENT", parts: []}
    };

    StreamResponse?|Error decoded = decodeStreamResponseEnvelope(envelope);

    test:assertTrue(decoded is InvalidAgentResponseError, "two arms set must be rejected");
}

@test:Config {}
function testAuthenticationInfoRoundTrip() returns error? {
    AuthenticationInfo original = {scheme: "Bearer", credentials: "eyJhbGciOiJIUzI1NiIs..."};
    AuthenticationInfo decoded = check original.toJson().cloneWithType(AuthenticationInfo);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAuthenticationInfoToleratesUnrecognizedField() returns error? {
    json payload = {
        scheme: "Bearer",
        futureField: "some value from a newer spec revision"
    };

    AuthenticationInfo decoded = check payload.cloneWithType(AuthenticationInfo);

    test:assertEquals(decoded.scheme, "Bearer");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testTaskPushNotificationConfigRoundTrip() returns error? {
    TaskPushNotificationConfig original = {
        url: "https://client.example.com/webhooks/a2a",
        id: "webhook-1",
        token: "correlation-token",
        authentication: {scheme: "Bearer", credentials: "eyJhbGciOiJIUzI1NiIs..."},
        tenant: "acme-corp"
    };
    TaskPushNotificationConfig decoded = check original.toJson().cloneWithType(TaskPushNotificationConfig);

    test:assertEquals(decoded, original);
    test:assertTrue(decoded?.taskId is (), "taskId should be nil in a sendMessage-style config");
}

@test:Config {}
function testTaskPushNotificationConfigToleratesUnrecognizedField() returns error? {
    json payload = {
        url: "https://client.example.com/webhooks/a2a",
        futureField: "some value from a newer spec revision"
    };

    TaskPushNotificationConfig decoded = check payload.cloneWithType(TaskPushNotificationConfig);

    test:assertEquals(decoded.url, "https://client.example.com/webhooks/a2a");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testSendMessageConfigurationRoundTrip() returns error? {
    SendMessageConfiguration original = {
        acceptedOutputModes: ["text", "image/png"],
        historyLength: 5,
        returnImmediately: true,
        taskPushNotificationConfig: {url: "https://client.example.com/webhooks/a2a"}
    };
    SendMessageConfiguration decoded = check original.toJson().cloneWithType(SendMessageConfiguration);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testSendMessageConfigurationDefaults() returns error? {
    json payload = {};

    SendMessageConfiguration decoded = check payload.cloneWithType(SendMessageConfiguration);

    // Unset means "no constraint" per the specification, not ["text"]. The
    // old default silently told every agent to withhold images and files.
    test:assertTrue(decoded?.acceptedOutputModes is (),
            "acceptedOutputModes should be absent, imposing no constraint");
    test:assertTrue(decoded?.historyLength is (), "historyLength should be unset by default");
    test:assertEquals(decoded.returnImmediately, false);
    test:assertTrue(decoded?.taskPushNotificationConfig is (), "taskPushNotificationConfig should be unset by default");
}

@test:Config {}
function testSendMessageConfigurationToleratesUnrecognizedField() returns error? {
    json payload = {
        futureField: "some value from a newer spec revision"
    };

    SendMessageConfiguration decoded = check payload.cloneWithType(SendMessageConfiguration);

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testListTasksRequestRoundTrip() returns error? {
    ListTasksRequest original = {
        contextId: "ctx-1",
        status: TASK_STATE_COMPLETED,
        pageSize: 20,
        pageToken: "cursor-abc",
        historyLength: 10,
        statusTimestampAfter: "2026-07-29T00:00:00Z",
        includeArtifacts: true
    };
    ListTasksRequest decoded = check original.toJson().cloneWithType(ListTasksRequest);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testListTasksRequestToleratesUnrecognizedField() returns error? {
    json payload = {futureField: "some value from a newer spec revision"};

    ListTasksRequest decoded = check payload.cloneWithType(ListTasksRequest);

    test:assertTrue(decoded?.contextId is (), "contextId should be nil, not defaulted");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testListTasksResponseRoundTrip() returns error? {
    ListTasksResponse original = {
        tasks: [
            {id: "task-1", status: {state: TASK_STATE_COMPLETED}}
        ],
        nextPageToken: "cursor-def",
        pageSize: 20,
        totalSize: 1
    };
    ListTasksResponse decoded = check original.toJson().cloneWithType(ListTasksResponse);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testListTaskPushNotificationConfigsResponseRoundTrip() returns error? {
    ListTaskPushNotificationConfigsResponse original = {
        configs: [
            {url: "https://client.example.com/webhooks/a2a", id: "webhook-1"}
        ],
        nextPageToken: "cursor-ghi"
    };
    ListTaskPushNotificationConfigsResponse decoded = check original.toJson().cloneWithType(ListTaskPushNotificationConfigsResponse);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAuthorizationCodeOAuthFlowRoundTrip() returns error? {
    AuthorizationCodeOAuthFlow original = {
        authorizationUrl: "https://auth.example.com/authorize",
        refreshUrl: "https://auth.example.com/refresh",
        scopes: {"read": "Read access", "write": "Write access"},
        tokenUrl: "https://auth.example.com/token"
    };
    AuthorizationCodeOAuthFlow decoded = check original.toJson().cloneWithType(AuthorizationCodeOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAuthorizationCodeOAuthFlowToleratesUnrecognizedField() returns error? {
    json payload = {
        authorizationUrl: "https://auth.example.com/authorize",
        scopes: {"read": "Read access"},
        tokenUrl: "https://auth.example.com/token",
        futureField: "some value from a newer spec revision"
    };

    AuthorizationCodeOAuthFlow decoded = check payload.cloneWithType(AuthorizationCodeOAuthFlow);

    test:assertTrue(decoded?.refreshUrl is (), "refreshUrl should be nil");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testClientCredentialsOAuthFlowRoundTrip() returns error? {
    ClientCredentialsOAuthFlow original = {
        scopes: {"read": "Read access"},
        tokenUrl: "https://auth.example.com/token"
    };
    ClientCredentialsOAuthFlow decoded = check original.toJson().cloneWithType(ClientCredentialsOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testImplicitOAuthFlowRoundTrip() returns error? {
    ImplicitOAuthFlow original = {
        authorizationUrl: "https://auth.example.com/authorize",
        scopes: {"read": "Read access"}
    };
    ImplicitOAuthFlow decoded = check original.toJson().cloneWithType(ImplicitOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testPasswordOAuthFlowRoundTrip() returns error? {
    PasswordOAuthFlow original = {
        scopes: {"read": "Read access"},
        tokenUrl: "https://auth.example.com/token"
    };
    PasswordOAuthFlow decoded = check original.toJson().cloneWithType(PasswordOAuthFlow);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testOAuthFlowsRoundTripWithAllFourFlows() returns error? {
    OAuthFlows original = {
        authorizationCode: {
            authorizationUrl: "https://auth.example.com/authorize",
            tokenUrl: "https://auth.example.com/token",
            scopes: {"read": "Read access"}
        },
        clientCredentials: {
            tokenUrl: "https://auth.example.com/token",
            scopes: {"read": "Read access"}
        },
        implicit: {
            authorizationUrl: "https://auth.example.com/authorize",
            scopes: {"read": "Read access"}
        },
        password: {
            tokenUrl: "https://auth.example.com/token",
            scopes: {"read": "Read access"}
        }
    };
    OAuthFlows decoded = check original.toJson().cloneWithType(OAuthFlows);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testOAuthFlowsToleratesAllFieldsUnset() returns error? {
    json payload = {};

    OAuthFlows decoded = check payload.cloneWithType(OAuthFlows);

    test:assertTrue(decoded?.authorizationCode is (), "authorizationCode should be nil");
    test:assertTrue(decoded?.clientCredentials is (), "clientCredentials should be nil");
    test:assertTrue(decoded?.implicit is (), "implicit should be nil");
    test:assertTrue(decoded?.password is (), "password should be nil");
}

@test:Config {}
function testApiKeySecuritySchemeRoundTrip() returns error? {
    ApiKeySecurityScheme original = {
        description: "API key passed as a header",
        'in: "header",
        name: "X-API-Key"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is ApiKeySecurityScheme, "should decode as ApiKeySecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testHttpAuthSecuritySchemeRoundTrip() returns error? {
    HttpAuthSecurityScheme original = {
        scheme: "bearer",
        bearerFormat: "JWT"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is HttpAuthSecurityScheme, "should decode as HttpAuthSecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testOAuth2SecuritySchemeRoundTrip() returns error? {
    OAuth2SecurityScheme original = {
        flows: {
            clientCredentials: {
                tokenUrl: "https://auth.example.com/token",
                scopes: {"read": "Read access"}
            }
        }
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is OAuth2SecurityScheme, "should decode as OAuth2SecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testOpenIdConnectSecuritySchemeRoundTrip() returns error? {
    OpenIdConnectSecurityScheme original = {
        openIdConnectUrl: "https://auth.example.com/.well-known/openid-configuration"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is OpenIdConnectSecurityScheme, "should decode as OpenIdConnectSecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testMutualTlsSecuritySchemeRoundTrip() returns error? {
    MutualTlsSecurityScheme original = {
        description: "Mutual TLS required"
    };
    SecurityScheme decoded = check original.toJson().cloneWithType(SecurityScheme);

    test:assertTrue(decoded is MutualTlsSecurityScheme, "should decode as MutualTlsSecurityScheme");
    test:assertEquals(decoded, original);
}

@test:Config {}
function testApiKeySecuritySchemeToleratesUnrecognizedField() returns error? {
    json payload = {
        'in: "query",
        name: "api_key",
        'type: "apiKey",
        futureField: "some value from a newer spec revision"
    };

    SecurityScheme decoded = check payload.cloneWithType(SecurityScheme);

    test:assertTrue(decoded is ApiKeySecurityScheme, "should decode as ApiKeySecurityScheme");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testAgentCardSignatureRoundTrip() returns error? {
    AgentCardSignature original = {
        header: {"alg": "RS256", "kid": "key-1"},
        protected: "eyJhbGciOiJSUzI1NiJ9",
        signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"
    };
    AgentCardSignature decoded = check original.toJson().cloneWithType(AgentCardSignature);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCardSignatureToleratesUnrecognizedField() returns error? {
    json payload = {
        protected: "eyJhbGciOiJSUzI1NiJ9",
        signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ",
        futureField: "some value from a newer spec revision"
    };

    AgentCardSignature decoded = check payload.cloneWithType(AgentCardSignature);

    test:assertTrue(decoded?.header is (), "header should be nil");

    json reserialized = decoded.toJson();
    test:assertEquals((check reserialized.futureField), "some value from a newer spec revision");
}

@test:Config {}
function testSecurityRequirementRoundTrip() returns error? {
    SecurityRequirement original = {"oauth": ["read", "write"], "apiKey": []};
    SecurityRequirement decoded = check original.toJson().cloneWithType(SecurityRequirement);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testAgentCardWithTypedSecurityFieldsRoundTrip() returns error? {
    AgentCard original = {
        name: "Weather Agent",
        description: "Reports current weather conditions",
        version: "1.2.0",
        capabilities: {},
        securitySchemes: {
            "bearerAuth": <HttpAuthSecurityScheme>{scheme: "bearer", bearerFormat: "JWT"},
            "apiKeyAuth": <ApiKeySecurityScheme>{'in: "header", name: "X-API-Key"}
        },
        securityRequirements: [{"bearerAuth": []}, {"apiKeyAuth": []}],
        signatures: [
            {protected: "eyJhbGciOiJSUzI1NiJ9", signature: "dGhpcyBpcyBhIHNpZ25hdHVyZQ"}
        ],
        skills: [
            {
                id: "weather-lookup",
                name: "Weather Lookup",
                description: "Reports current weather for a city",
                securityRequirements: [{"bearerAuth": []}],
                tags: []
            }
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        supportedInterfaces: []
    };
    AgentCard decoded = check original.toJson().cloneWithType(AgentCard);

    test:assertEquals(decoded, original);
}

@test:Config {}
function testParseSecuritySchemesKeepsValidEntriesOfDifferentTypes() returns error? {
    json raw = {
        "bearerAuth": {"type": "http", "scheme": "bearer"},
        "apiKeyAuth": {"type": "apiKey", "in": "header", "name": "X-API-Key"}
    };

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 2);
    test:assertTrue(result.get("bearerAuth") is HttpAuthSecurityScheme);
    test:assertTrue(result.get("apiKeyAuth") is ApiKeySecurityScheme);
}

@test:Config {}
function testParseSecuritySchemesDropsUnrecognizedType() returns error? {
    json raw = {
        "bearerAuth": {"type": "http", "scheme": "bearer"},
        "quantumAuth": {"type": "quantumEntanglement", "someField": "value"}
    };

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 1);
    test:assertTrue(result.hasKey("bearerAuth"));
    test:assertFalse(result.hasKey("quantumAuth"));
}

@test:Config {}
function testParseSecuritySchemesDropsMalformedEntry() returns error? {
    // apiKey scheme missing the required "name" field
    json raw = {
        "bearerAuth": {"type": "http", "scheme": "bearer"},
        "brokenApiKey": {"type": "apiKey", "in": "header"}
    };

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 1);
    test:assertTrue(result.hasKey("bearerAuth"));
    test:assertFalse(result.hasKey("brokenApiKey"));
}

@test:Config {}
function testParseSecuritySchemesOnEmptyMap() returns error? {
    json raw = {};

    map<SecurityScheme> result = check parseSecuritySchemes(raw);

    test:assertEquals(result.length(), 0);
}

@test:Config {}
function testParseSecurityRequirementsKeepsValidEntriesDropsMalformed() returns error? {
    json raw = [
        {"oauth": ["read"]},
        {"apiKey": "not-an-array"}
    ];

    SecurityRequirement[] result = check parseSecurityRequirements(raw);

    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0], {"oauth": ["read"]});
}

@test:Config {}
function testParseSecurityRequirementsOnEmptyArray() returns error? {
    json raw = [];

    SecurityRequirement[] result = check parseSecurityRequirements(raw);

    test:assertEquals(result.length(), 0);
}

@test:Config {}
function testParseAgentCardSignaturesKeepsValidEntriesDropsMalformed() returns error? {
    json raw = [
        {"protected": "eyJhbGciOiJSUzI1NiJ9", "signature": "dGhpcyBpcyBhIHNpZ25hdHVyZQ"},
        {"header": {"alg": "RS256"}}
    ];

    AgentCardSignature[] result = check parseAgentCardSignatures(raw);

    test:assertEquals(result.length(), 1);
    test:assertEquals(result[0].protected, "eyJhbGciOiJSUzI1NiJ9");
}

@test:Config {}
function testParseAgentCardSignaturesOnEmptyArray() returns error? {
    json raw = [];

    AgentCardSignature[] result = check parseAgentCardSignatures(raw);

    test:assertEquals(result.length(), 0);
}

@test:Config {}
function testEncodeRawBytesForWireRejectsZeroVariantsSet() {
    Message container = {messageId: "msg-1", role: ROLE_USER, parts: [{}]};
    json|error result = encodeRawBytesForWire(container.toJson());
    test:assertTrue(result is InternalError, "a caller-constructed Part with none of text/raw/url/data set is an internal, not agent, error");
}

@test:Config {}
function testEncodeRawBytesForWireRejectsMultipleVariantsSet() {
    Message container = {
        messageId: "msg-1",
        role: ROLE_USER,
        parts: [{text: "hi", url: "https://example.com/x"}]
    };
    json|error result = encodeRawBytesForWire(container.toJson());
    test:assertTrue(result is InternalError, "a caller-constructed Part with more than one of text/raw/url/data set must be rejected, not silently narrowed to one");
}

@test:Config {}
function testDecodeRawBytesFromWireRejectsZeroVariantsSet() {
    json payload = {
        messageId: "msg-1",
        role: "ROLE_AGENT",
        parts: [{}]
    };
    json|error result = decodeRawBytesFromWire(payload);
    test:assertTrue(result is InvalidAgentResponseError, "an agent sending a Part with none of text/raw/url/data set is the agent's fault, not ours");
}

@test:Config {}
function testDecodeRawBytesFromWireRejectsMultipleVariantsSet() {
    json payload = {
        messageId: "msg-1",
        role: "ROLE_AGENT",
        parts: [{"text": "hi", "url": "https://example.com/x"}]
    };
    json|error result = decodeRawBytesFromWire(payload);
    test:assertTrue(result is InvalidAgentResponseError, "an agent sending a Part with more than one of text/raw/url/data set must be rejected, not silently narrowed to one");
}

// ---- Part variant counting and required-array validation ---------------

// `Part.data` is `google.protobuf.Value`, the one field in the specification
// where a JSON null is legal. Counting variants by non-nil value read
// `{"data": null}` as zero variants set and rejected a conformant data part
// as malformed; counting by member presence -- which is what the
// specification names as the discriminator -- reads it as the one variant it
// is.
@test:Config {}
function testDataPartHoldingNullCountsAsOneVariant() {
    Part dataHoldingNull = {data: ()};
    test:assertEquals(countSetPartVariants(dataHoldingNull), 1,
            "a data part whose value is JSON null is still a data part");

    map<json> wireForm = {"data": ()};
    test:assertEquals(countSetPartVariantsJson(wireForm), 1,
            "and the same holds on the raw wire form");
}

// Absence and a null value are different states, and only presence counts.
@test:Config {}
function testPartWithNoVariantCountsAsZero() {
    Part noVariant = {mediaType: "text/plain"};
    test:assertEquals(countSetPartVariants(noVariant), 0);
    test:assertEquals(countSetPartVariantsJson({"mediaType": "text/plain"}), 0);
}

// Artifact.parts is the only array the proto itself marks non-empty ("Must
// contain at least one part"), and a2a-java enforces it too.
@test:Config {}
function testEmptyArtifactPartsIsRejected() {
    Task task = {
        id: "t1",
        status: {state: TASK_STATE_COMPLETED},
        artifacts: [{artifactId: "a1", parts: []}]
    };

    Error? result = validateInboundTask(task);

    test:assertTrue(result is InvalidAgentResponseError,
            "an artifact carrying no parts violates specification section 4.1.7");
}

// Message.parts carries no proto statement, but it is the message's content
// container and a2a-java enforces it (Message.java:70).
@test:Config {}
function testEmptyMessagePartsIsRejectedOutbound() {
    Message empty = {messageId: "m1", role: ROLE_USER, parts: []};

    Error? result = validateOutboundMessage(empty);

    test:assertTrue(result is InternalError,
            "a caller's own malformed message is caught before the request is sent");
}

// An AgentCard with no skills is explicitly valid: the specification's own
// canonicalization example in section 8.4.1 publishes one and annotates
// `"skills": []` as "REQUIRED field -> include". Section 5.7's blanket
// "required arrays MUST contain at least one element" cannot be read
// literally against that.
@test:Config {}
function testAgentCardWithNoSkillsIsAccepted() returns error? {
    json payload = {
        name: "Example Agent",
        description: "",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [
            {url: "http://localhost:19199", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        skills: []
    };

    AgentCard card = check parseAgentCardBody(payload);

    test:assertEquals(card.skills.length(), 0, "an empty skills array is conformant");
}

// An empty page is a legitimate "no results matched", not a malformed
// response.
@test:Config {}
function testEmptyListTasksPageIsAccepted() returns error? {
    json payload = {tasks: [], nextPageToken: "", pageSize: 50, totalSize: 0};

    ListTasksResponse decoded = check decodeListTasksResponse(payload);

    test:assertEquals(decoded.tasks.length(), 0);
    test:assertEquals(decoded.totalSize, 0);
}

// Regression: SecurityScheme is a specification oneof, so an entry setting two
// recognised arms is not a scheme this client can name. It used to resolve to
// whichever arm V10_SECURITY_SCHEME_ARM_KEYS listed first.
@test:Config {}
function testTwoArmSecuritySchemeIsRejected() returns error? {
    map<SecurityScheme> parsed = check parseSecuritySchemes({
        "ambiguous": {
            "apiKeySecurityScheme": {"location": "header", "name": "X-API-Key"},
            "httpAuthSecurityScheme": {"scheme": "bearer"}
        }
    });
    test:assertFalse(parsed.hasKey("ambiguous"),
            "an entry setting two oneof arms must be dropped, not resolved to the first-listed arm");
}

// Regression: an entry with no recognised arm and no `type` used to clone into
// MutualTlsSecurityScheme, which requires no fields and defaults its own
// `type` -- so any unknown wrapper was read as mutual TLS.
@test:Config {}
function testUnknownSecuritySchemeWrapperIsNotReadAsMutualTls() returns error? {
    map<SecurityScheme> parsed = check parseSecuritySchemes({
        "future": {"someFutureSecurityScheme": {"whatever": true}}
    });
    test:assertFalse(parsed.hasKey("future"),
            "an unrecognised wrapper must be dropped, not silently typed as mutual TLS");
}

// The conformant shapes still parse.
@test:Config {}
function testSingleArmAndTypeDiscriminatedSchemesStillParse() returns error? {
    map<SecurityScheme> parsed = check parseSecuritySchemes({
        "byArm": {"httpAuthSecurityScheme": {"scheme": "bearer"}},
        "byType": {"type": "http", "scheme": "bearer"},
        "realMtls": {"mtlsSecurityScheme": {}}
    });
    test:assertTrue(parsed.hasKey("byArm"), "a single-arm entry must still parse");
    test:assertTrue(parsed.hasKey("byType"), "a type-discriminated entry must still parse");
    test:assertTrue(parsed["realMtls"] is MutualTlsSecurityScheme,
            "a genuine mtls arm must still resolve to MutualTlsSecurityScheme");
}
