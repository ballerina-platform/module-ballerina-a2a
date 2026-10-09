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

// How a service reaches the wire: `@a2a:ServiceConfig` choosing its binding,
// the `a2a:DefaultHandler` it is bound to, one handler shared by two
// listeners, and a replacement `a2a:EventBroadcasterRegistry` actually used.

import ballerina/test;

const int SHARED_HANDLER_PORT_A = 19266;
const int SHARED_HANDLER_PORT_B = 19267;
const int RPC_REJECTION_PORT = 19268;
const int CUSTOM_REGISTRY_PORT = 19269;

@ServiceConfig {protocol: REST}
isolated service class RestAnnotatedAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater->complete();
    }
}

@ServiceConfig {protocol: RPC}
isolated service class RpcAnnotatedAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater->complete();
    }
}

// ---- reading the annotation ----------------------------------------------

@test:Config {}
function testServiceWithoutConfigDefaultsToRest() {
    test:assertEquals(serviceConfigurationOf(new CountingAgent()).protocol, REST);
}

@test:Config {}
function testServiceConfigIsReadFromAServiceClass() {
    test:assertEquals(serviceConfigurationOf(new RestAnnotatedAgent()).protocol, REST);
    test:assertEquals(serviceConfigurationOf(new RpcAnnotatedAgent()).protocol, RPC);
}

@test:Config {}
function testServiceConfigIsReadFromAServiceObject() {
    Service agent = @ServiceConfig {protocol: RPC} isolated service object {
        isolated remote function onMessage(RequestContext context, TaskUpdater updater) returns Message|Error? {
            check updater->complete();
        }
    };
    test:assertEquals(serviceConfigurationOf(agent).protocol, RPC);
}

// ---- attaching -----------------------------------------------------------

@test:Config {}
function testAttachRejectsRpcWithoutBindingTheHandler() returns error? {
    DefaultHandler handler = new (authTestCard);
    HttpListener rpcListener = check new (RPC_REJECTION_PORT, handler);

    error? rejected = rpcListener.attach(new RpcAnnotatedAgent());
    test:assertTrue(rejected is InternalError, "RPC is reserved: attaching it must fail");
    if rejected is error {
        test:assertTrue(rejected.message().includes("RPC"), rejected.message());
        test:assertTrue(rejected.message().includes("not supported yet"), rejected.message());
    }

    // The refused service must not have claimed the handler.
    check rpcListener.attach(new RestAnnotatedAgent());
    check rpcListener.gracefulStop();
}

@test:Config {}
function testHandlerServesOneServiceOnly() returns error? {
    DefaultHandler handler = new (authTestCard);
    CountingAgent agent = new;
    check handler.bindService(agent);
    check handler.bindService(agent);

    Error? second = handler.bindService(new CountingAgent());
    test:assertTrue(second is InternalError, "a handler's tasks belong to one agent");
}

// ---- one handler, two listeners ------------------------------------------

final DefaultHandler sharedHandler = new (authTestCard);
final CountingAgent sharedAgent = new;

listener HttpListener sharedListenerA = new (SHARED_HANDLER_PORT_A, sharedHandler);

listener HttpListener sharedListenerB = new (SHARED_HANDLER_PORT_B, sharedHandler);

@test:BeforeSuite
function startSharedHandlerListeners() returns error? {
    check sharedListenerA.attach(sharedAgent);
    check sharedListenerB.attach(sharedAgent);
}

@test:Config {}
function testOneHandlerOnTwoListenersServesTheSameTasks() returns error? {
    HttpClient viaA = check new (string `http://localhost:${SHARED_HANDLER_PORT_A}`);
    HttpClient viaB = check new (string `http://localhost:${SHARED_HANDLER_PORT_B}`);

    Message|Task sent = check viaA->sendMessage({
        message: {messageId: "m-shared", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(sent is Task, "CountingAgent drives a task");
    Task created = <Task>sent;

    Task fetched = check viaB->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "a task created through one listener is visible through the other");
    test:assertEquals(fetched.status.state, TASK_STATE_COMPLETED);
}

// ---- a declarative service on two listeners ------------------------------
//
// The form the README leads with: one `service ... on a, b` declaration. The
// runtime attaches the same service object to both listeners, so both bind
// the one shared handler without conflict.

const int DECLARATIVE_PORT_A = 19270;
const int DECLARATIVE_PORT_B = 19271;

final DefaultHandler declarativeHandler = new (authTestCard);

listener HttpListener declarativeListenerA = new (DECLARATIVE_PORT_A, declarativeHandler);

listener HttpListener declarativeListenerB = new (DECLARATIVE_PORT_B, declarativeHandler);

@ServiceConfig {protocol: REST}
isolated service Service on declarativeListenerA, declarativeListenerB {
    isolated remote function onMessage(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater->addArtifact([{text: "declared"}]);
        check updater->complete();
    }
}

@test:Config {}
function testDeclarativeServiceOnTwoListenersSharesOneHandler() returns error? {
    HttpClient viaA = check new (string `http://localhost:${DECLARATIVE_PORT_A}`);
    HttpClient viaB = check new (string `http://localhost:${DECLARATIVE_PORT_B}`);

    Message|Task sent = check viaA->sendMessage({
        message: {messageId: "m-declarative", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(sent is Task, "the declared service drives a task");
    Task created = <Task>sent;
    test:assertEquals((created.artifacts ?: [])[0].parts[0].text, "declared");

    Task fetched = check viaB->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "both listeners serve the one handler's tasks");
}

// ---- a replacement event registry ----------------------------------------

// Delegates to the in-memory default, counting the driver claims it is asked
// for -- enough to prove the handler uses the registry it was given.
isolated class CountingEventRegistry {
    *EventBroadcasterRegistry;

    private final InMemoryEventBroadcasterRegistry delegate = new;
    private int acquired = 0;

    public isolated function acquire(string taskId) returns EventBroadcaster? {
        lock {
            self.acquired += 1;
        }
        return self.delegate.acquire(taskId);
    }

    public isolated function subscribe(string taskId) returns EventBroadcaster => self.delegate.subscribe(taskId);

    public isolated function release(string taskId, boolean closed) {
        self.delegate.release(taskId, closed);
    }

    public isolated function peekBroadcaster(string taskId) returns EventBroadcaster? =>
        self.delegate.peekBroadcaster(taskId);

    isolated function acquireCount() returns int {
        lock {
            return self.acquired;
        }
    }
}

final CountingEventRegistry countingRegistry = new;
final DefaultHandler customRegistryHandler = new (authTestCard, eventRegistry = countingRegistry);

listener HttpListener customRegistryListener = new (CUSTOM_REGISTRY_PORT, customRegistryHandler);

@test:BeforeSuite
function startCustomRegistryListener() returns error? {
    check customRegistryListener.attach(new CountingAgent());
}

@test:Config {}
function testHandlerUsesTheConfiguredEventRegistry() returns error? {
    HttpClient agentClient = check new (string `http://localhost:${CUSTOM_REGISTRY_PORT}`);
    int before = countingRegistry.acquireCount();
    Message|Task _ = check agentClient->sendMessage({
        message: {messageId: "m-registry", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertEquals(countingRegistry.acquireCount(), before + 1, "every driven message claims its task once");
}
