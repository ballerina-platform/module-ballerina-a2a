## Overview

This module provides a Ballerina client for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org/latest/specification/) v1.0, an open protocol for communication between independent AI agents.

A2A lets an agent discover what another agent can do, delegate work to it, and follow that work as it progresses. An agent publishes an Agent Card describing its skills, transports, and authentication requirements; a client reads that card and talks to the agent over the transport it declares.

It includes capabilities for:

1. **Connecting to an agent** – Discover an agent from its Agent Card and open a client against the transport it declares.
2. **Delegating work** – Send a message and receive either a direct reply or a long-running task to follow.
3. **Following progress** – Stream updates as they happen, or register a webhook and be called back.
4. **Authenticating** – Satisfy the security schemes an agent declares, per skill where they differ.

The specification defines three transport bindings. This module implements **HTTP+JSON**; a card declaring only JSON-RPC or gRPC is rejected when the client is constructed, rather than at the first call.

## 1. Connecting to an agent

`Client` is the type to reach for. Give it an agent's base URL and it fetches the Agent Card from the well-known endpoint, confirms the agent serves HTTP+JSON, and connects.

```ballerina
import ballerina/a2a;

final a2a:Client agent = check new ("https://agent.example.com");
```

Construction is where a mismatch surfaces: an unreachable agent, a card that does not parse, or a card offering no binding this module speaks all fail here rather than on the first operation.

A `Client` is cheap to construct and needs no teardown — there is deliberately no `close`. Prefer one long-lived client per agent over one per request.

### 1.1 Connecting from an already-resolved card

When you have already fetched the card — to inspect its skills before deciding to call it — hand it over directly and it is not fetched twice:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
final a2a:Client agent = check new (card);
```

### 1.2 Choosing the binding yourself

`RestClient` connects over HTTP+JSON without consulting the card's ordering. Reach for it when the agent is known to serve that binding and you would rather not pay for card-driven selection. It exposes the same eleven operations as `Client`.

```ballerina
final a2a:RestClient agent = check new ("https://agent.example.com");
```

## 2. Delegating work

Every operation takes a single request record, matching the specification's own request messages. Optional fields are omitted rather than passed as nil.

`sendMessage` returns either a `Task` — work the agent has accepted and will continue — or a `Message`, a direct conversational reply with no task behind it:

```ballerina
public function main() returns error? {
    a2a:Task|a2a:Message reply = check agent->sendMessage({
        message: {
            messageId: "msg-1",
            role: a2a:ROLE_USER,
            parts: [{text: "What is the weather in Colombo?"}]
        }
    });

    if reply is a2a:Task {
        io:println("task ", reply.id, " is ", reply.status.state);
    } else if reply is a2a:Message {
        io:println("direct reply: ", reply.parts);
    }
}
```

> **Note:** Match each arm explicitly rather than relying on `else` to narrow. Every specification type in this module is an open record, so `else` after `is a2a:Task` leaves the value typed as the full union — the compiler will reject a field access there.

### 2.1 Message parts

A `Message` carries one or more parts. Exactly one of `text`, `raw`, `url`, or `data` is set on each — the variant is determined by which field is present, not by a discriminator field:

```ballerina
a2a:Message msg = {
    messageId: "msg-2",
    role: a2a:ROLE_USER,
    parts: [
        {text: "Summarise this report."},
        {raw: check io:fileReadBytes("report.pdf"), mediaType: "application/pdf"}
    ]
};
```

`raw` is `byte[]` in Ballerina and base64 on the wire; the conversion happens for you in both directions.

### 2.2 Following a task

`getTask` retrieves a task's current state. `historyLength` bounds how much conversation history comes back with it:

```ballerina
a2a:Task task = check agent->getTask({id: "task-1", historyLength: 10});
```

`cancelTask` asks the agent to stop. An agent that has already finished, or that does not allow cancellation, answers with `TaskNotCancelableError`:

```ballerina
a2a:Task canceled = check agent->cancelTask({id: "task-1"});
```

`listTasks` pages through tasks with a cursor. Every filter field is optional:

```ballerina
a2a:ListTasksResponse page = check agent->listTasks({
    status: a2a:TASK_STATE_WORKING,
    pageSize: 20
});

while page.nextPageToken != "" {
    page = check agent->listTasks({pageSize: 20, pageToken: page.nextPageToken});
}
```

## 3. Following progress

### 3.1 Streaming

`sendStreamingMessage` and `subscribeToTask` return a `stream<StreamResponse, error?>`. Each event is a `Task`, a `Message`, a `TaskStatusUpdateEvent`, or a `TaskArtifactUpdateEvent`. The stream closes on a terminal task state:

```ballerina
stream<a2a:StreamResponse, error?> events =
    check agent->sendStreamingMessage({message: msg});

check from a2a:StreamResponse event in events
    do {
        if event is a2a:TaskStatusUpdateEvent {
            io:println("state: ", event.status.state);
        } else if event is a2a:TaskArtifactUpdateEvent {
            io:println("artifact: ", event.artifact.artifactId);
        }
    };
```

`subscribeToTask` attaches to a task that is already running:

```ballerina
stream<a2a:StreamResponse, error?> events = check agent->subscribeToTask({id: "task-1"});
```

Pass `maxReconnectAttempts` to have a dropped connection resubscribe automatically:

```ballerina
final a2a:Client agent = check new ("https://agent.example.com", maxReconnectAttempts = 3);
```

Per specification section 3.1.6 a resubscription replays the task's current state, so no event is lost across a reconnect — only possibly repeated. Callers already have to tolerate duplicate and out-of-order status updates, so this adds no new burden.

When the Agent Card says the agent does not support streaming, `sendStreamingMessage` degrades to a single unary call wrapped as a one-event stream instead of opening a connection the server would reject. `subscribeToTask` has no unary equivalent, so it fails with `UnsupportedOperationError`.

### 3.2 Push notifications

Rather than holding a stream open, register a webhook and let the agent call you back:

```ballerina
a2a:TaskPushNotificationConfig config = check agent->createTaskPushNotificationConfig({
    taskId: "task-1",
    url: "https://client.example.com/webhooks/a2a"
});
```

The server assigns the config an `id`, which is what the other three operations address it by. It is optional on the record, since a caller does not supply one when creating:

```ballerina
a2a:ListTaskPushNotificationConfigsResponse configs =
    check agent->listTaskPushNotificationConfigs({taskId: "task-1"});

string? configId = config?.id;
if configId is string {
    check agent->deleteTaskPushNotificationConfig({taskId: "task-1", id: configId});
}
```

Deletion is idempotent per specification section 3.1.10.

## 4. Authenticating

### 4.1 Standard transport authentication

OAuth2, JWT, mutual TLS, and HTTP basic or bearer are configured through `clientConfig`, which is a standard `http:ClientConfiguration`. Token exchange and refresh are handled by `ballerina/oauth2` and `ballerina/jwt` as usual:

```ballerina
final a2a:Client agent = check new ("https://agent.example.com", {
    auth: {
        tokenUrl: "https://auth.example.com/oauth2/token",
        clientId: "...",
        clientSecret: "..."
    }
});
```

### 4.2 Credentials by security-scheme name

An agent can declare several schemes, and a client may hold a different credential for each — two bearer tokens on one agent, say, which a single `headers` map cannot express. For schemes that reduce to one header value, supply a `CredentialProvider`. It is consulted per request and keyed by the scheme name the Agent Card uses:

```ballerina
final a2a:InMemoryCredentialStore store = new ({
    "staffAuth": "eyJhbGciOi...",
    "apiKeyAuth": "sk-..."
});

final a2a:Client agent = check new ("https://agent.example.com", credentials = store);
```

Implement `CredentialProvider` yourself to source credentials from wherever they actually live — a vault, a config file, a per-session store. Returning `()` is normal and not an error: the request is sent without that credential and the agent decides how to respond.

### 4.3 Skill-level requirements

A skill can require more than the agent as a whole does. `AgentSkill.securityRequirements` carries what a given skill asks for, and an empty list means it inherits the card's:

```ballerina
foreach a2a:AgentSkill skill in card.skills {
    if skill.id == "adjust-payroll" {
        io:println(skill.securityRequirements);
    }
}
```

When an agent needs authorization it cannot obtain itself, it parks the task in `TASK_STATE_AUTH_REQUIRED` and attaches a status message explaining what it needs (specification section 7.6):

```ballerina
if task.status.state == a2a:TASK_STATE_AUTH_REQUIRED {
    a2a:Message? prompt = task.status?.message;
    // surface the prompt to whoever can satisfy it, then resume
}
```

## 5. Inspecting a card

`resolveAgentCard` fetches and parses a card without constructing a client — useful for inspecting an agent's skills before deciding to call it:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
foreach a2a:AgentSkill skill in card.skills {
    io:println(skill.id, ": ", skill.description);
}
```

A card may carry `signatures` (specification section 8.4). They are parsed onto the card but not verified: section 8.4.3's procedure needs a public key only you can supply, and it must run over the raw body rather than a parsed record, since a record carries defaults the signer never sent. Use `a2a:fetchAgentCardBody` to get that body:

```ballerina
json raw = check a2a:fetchAgentCardBody("https://agent.example.com");
// verify raw against your own trust store, then:
a2a:AgentCard card = check a2a:parseAgentCardBody(raw);
```

### 5.1 The extended Agent Card

An agent may publish a fuller card to authenticated callers — additional skills, or detail withheld from the public one:

```ballerina
a2a:AgentCard extended = check agent->getExtendedAgentCard();
```

When the held card declares no extended-card support this fails with `UnsupportedOperationError` rather than silently handing back the public card you already had, as specification section 3.3.4 requires.

## 6. Errors

Every operation returns a narrowed `Error`. The nine error types of specification section 5.4 are each a distinct subtype, so a caller matches on the condition rather than on a code:

```ballerina
a2a:Task|a2a:Error result = agent->getTask({id: "task-1"});

if result is a2a:TaskNotFoundError {
    // the agent does not know this task
} else if result is a2a:Error {
    io:println(result.message());
}
```

The nine are `TaskNotFoundError`, `TaskNotCancelableError`, `UnsupportedOperationError`, `ContentTypeNotSupportedError`, `InvalidAgentResponseError`, `VersionNotSupportedError`, `PushNotificationNotSupportedError`, `ExtendedAgentCardNotConfiguredError`, and `ExtensionSupportRequiredError`.

Anything the protocol does not name — a dropped connection, a malformed body, a response that does not match its declared shape, or a precondition this client checks before sending — surfaces as `InternalError`. No operation returns a bare, unmatchable `error`.
