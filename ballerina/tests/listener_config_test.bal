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
import ballerina/time;

// The HTTP settings a caller passes to `a2a:Listener` (a `timeout`, a
// `secureSocket`, ...) must reach the HTTP listener that is created for a port.
// They used to be dropped: the listener was built from an empty configuration.
//
// Observed through `timeout`, which has a visible effect and needs no
// certificates: with a 2-second idle timeout, a stream on which the agent stays
// silent is closed by the server after about 2 seconds. Left at Ballerina's
// default it would stay open for a minute.

const int LISTENER_CONFIG_TEST_PORT = 19242;
final string listenerConfigServerUrl = string `http://localhost:${LISTENER_CONFIG_TEST_PORT}`;

final DefaultHandler shortTimeoutHandler = new ({
    name: "Silent Agent",
    description: "Says one thing, then nothing until told to finish",
    version: "1.0.0",
    skills: [{id: "silent", name: "Silent", description: "Holds", tags: ["test"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

listener HttpListener shortTimeoutListener = new (LISTENER_CONFIG_TEST_PORT, shortTimeoutHandler,
    timeout = 2,
    keepAliveInterval = 0
);

// Reports WORKING, then holds on the Gate registered under the key in its
// message ("hold:<key>") until a test releases it, then completes.
isolated service class SilentAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        string text = context.message.parts[0]?.text ?: "";
        check updater->working();
        Gate? gate = text.startsWith("hold:") ? gateFor(text.substring(5)) : ();
        if gate is Gate {
            gate.awaitStep(1);
        }
        check updater->complete();
        return;
    }
}

@test:BeforeSuite
function startShortTimeoutServer() returns error? {
    check shortTimeoutListener.attach(new SilentAgent());
}

@test:Config {}
function testListenerAppliesTheCallersHttpTimeout() returns error? {
    Gate gate = new;
    registerGate("listener-config-silent", gate);
    HttpClient c = check new (listenerConfigServerUrl);

    time:Utc started = time:utcNow();
    stream<StreamResponse, Error?> events = check c->sendStreamingMessage({
        message: {messageId: "silent-1", role: ROLE_USER, parts: [{text: "hold:listener-config-silent"}]}
    });
    boolean sawCompleted = false;
    while true {
        record {|StreamResponse value;|}|Error? next = events.next();
        if next is () || next is Error {
            break;
        }
        StreamResponse event = next.value;
        if event is TaskStatusUpdateEvent && event.status.state == TASK_STATE_COMPLETED {
            sawCompleted = true;
        }
    }
    decimal seconds = time:utcDiffSeconds(time:utcNow(), started);
    gate.advanceTo(1);

    test:assertFalse(sawCompleted, "the agent was held, so only the server closing the connection ends the stream");
    test:assertTrue(seconds < 10d, string `the 2 second timeout must apply; the stream lasted ${seconds}s`);
}
