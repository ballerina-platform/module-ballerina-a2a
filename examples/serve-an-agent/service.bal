import ballerina/a2a;
import ballerina/io;

configurable int agentPort = 9090;

// The agent as the protocol sees it: its card, and (left at their defaults
// here) where its tasks are kept and who may see them. `capabilities` and
// `supportedInterfaces` are placeholders -- the listener replaces both with
// what it actually serves, so the published card can never advertise
// something this agent does not do.
final a2a:DefaultHandler weatherAgent = new ({
    name: "Weather Agent",
    description: "Answers weather questions",
    version: "1.0.0",
    skills: [
        {id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

// How requests reach it. Declared at module level: a listener declared
// inside `main` does not keep the program alive.
listener a2a:HttpListener agent = new (agentPort, weatherAgent);

// `onMessage` is the entire agent: the handler runs the rest of the protocol
// around it -- getTask/cancelTask/listTasks over the task this creates,
// sendStreamingMessage/subscribeToTask as Server-Sent Events, the
// push-notification configuration operations -- and the listener serves the
// well-known discovery endpoint and gates versions and capabilities.
@a2a:ServiceConfig {protocol: a2a:REST}
isolated service a2a:Service on agent {
    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        // --- real agent logic goes here; this example hardcodes a reply ---
        check updater->working();
        check updater->addArtifact([{text: "Sunny, 22°C"}]);
        check updater->complete();
        return;
    }
}

function init() {
    io:println(string `Weather Agent listening on http://localhost:${agentPort}`);
}
