## Overview

This module provides a Ballerina client and server for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org/latest/specification/) v1.0, an open protocol for communication between independent AI agents.

A2A lets an agent discover what another agent can do, delegate work to it, and follow that work as it progresses. An agent publishes an Agent Card describing its skills, transports, and authentication requirements; a client reads that card and talks to the agent over the transport it declares.

It includes capabilities for:

1. **Connecting to an agent** – Discover an agent from its Agent Card and open a client against the transport it declares.
2. **Delegating work** – Send a message and receive either a direct reply or a long-running task to follow.
3. **Following progress** – Stream updates as they happen, or register a webhook and be called back.
4. **Authenticating** – Satisfy the security schemes an agent declares, per skill where they differ.
5. **Serving an agent** – Implement one method and publish it as an A2A agent, with the task lifecycle, streaming, and discovery handled for you.

The specification defines three transport bindings. This module implements **HTTP+JSON**, for both the client and the server; a card declaring only JSON-RPC or gRPC is rejected when the client is constructed, rather than at the first call.

## 1. Connecting to an agent

`HttpClient` is the type to reach for. Give it an agent's base URL and it fetches the Agent Card from the well-known endpoint, confirms the agent serves HTTP+JSON, and connects.

```ballerina
import ballerina/a2a;

final a2a:HttpClient agent = check new ("https://agent.example.com");
```

Construction is where a mismatch surfaces: an unreachable agent, a card that does not parse, or a card offering no binding this module speaks all fail here rather than on the first operation.

An `HttpClient` is cheap to construct and needs no teardown — there is deliberately no `close`. Prefer one long-lived client per agent over one per request.

This release implements HTTP+JSON only. When JSON-RPC and gRPC bindings land, a transport-agnostic `Client` that reads the card and picks a binding will join `HttpClient`; client code written against the operations will carry over unchanged.

### 1.1 Connecting from an already-resolved card

When you have already fetched the card — to inspect its skills before deciding to call it — hand it over directly and it is not fetched twice:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
final a2a:HttpClient agent = check new (card);
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
final a2a:HttpClient agent = check new ("https://agent.example.com", maxReconnectAttempts = 3);
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
final a2a:HttpClient agent = check new ("https://agent.example.com", clientConfig = {
    auth: {
        tokenUrl: "https://auth.example.com/oauth2/token",
        clientId: "...",
        clientSecret: "..."
    }
});
```

`ballerina/oauth2` fetches the first token while the client is being built, so a wrong client secret or an unreachable token endpoint surfaces from `new a2a:HttpClient(...)` (and from `a2a:resolveAgentCard`) as an `a2a:InternalError` whose message names the agent and carries the token endpoint's response. It is a returned error, not a panic. A token that cannot be refreshed later fails the call that needed it.

### 4.2 Credentials by security-scheme name

An agent can declare several schemes, and a client may hold a different credential for each — two bearer tokens on one agent, say, which a single `headers` map cannot express. For schemes that reduce to one header value, supply a `CredentialProvider`. It is consulted per request and keyed by the scheme name the Agent Card uses:

```ballerina
final a2a:InMemoryCredentialStore store = new ({
    "staffAuth": "eyJhbGciOi...",
    "apiKeyAuth": "sk-..."
});

final a2a:HttpClient agent = check new ("https://agent.example.com", credentials = store);
```

An agent built with this package's listener and `auth` publishes its schemes for you, named `bearerAuth` for JWT and OAuth2 entries and `basicAuth` for Basic ones ([section 7.7](#77-authenticating-callers)), so `new a2a:InMemoryCredentialStore({"bearerAuth": token})` is all such an agent needs.

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

### 4.4 When the agent rejects the credentials

A rejected request has two distinct causes, and each has its own error type:

```ballerina
a2a:Task|a2a:Error result = agent->getTask({id: "task-1"});

if result is a2a:AuthenticationError {
    // 401: the credential is missing, expired, or invalid
} else if result is a2a:AuthorizationError {
    // 403: the credential is valid but not permitted to do this, e.g. a missing scope
}
```

An `AuthenticationError` carries the response's `WWW-Authenticate` challenges in `result.detail()?.data`, as `{"wwwAuthenticate": ["Bearer", ...]}`, which say which scheme the agent wants. Both types are recognised whether the agent answers with an A2A error body or, as a gateway or proxy does, with only the status. The same two types are what fails an `sendStreamingMessage` or `subscribeToTask` that is rejected before any event, and a card that itself sits behind authentication (`resolveAgentCard`).

Specification section 5.x describes these two conditions without naming an error type, so these two names are this package's own.

## 5. Inspecting a card

`resolveAgentCard` fetches and parses a card without constructing a client — useful for inspecting an agent's skills before deciding to call it:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
foreach a2a:AgentSkill skill in card.skills {
    io:println(skill.id, ": ", skill.description);
}
```

A card may carry `signatures` (specification section 8.4). They are parsed onto the card but not verified: section 8.4.3's procedure needs a public key only you can supply. Verifying a signature also has to run over the raw body rather than a parsed record, since a record carries defaults the signer never sent; raw-body signature verification is out of scope for this release.

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

Two more describe a rejected request rather than a failed operation: `AuthenticationError` (401) and `AuthorizationError` (403), see [section 4.4](#44-when-the-agent-rejects-the-credentials).

Anything the protocol does not name — a dropped connection, a malformed body, a response that does not match its declared shape, or a precondition this client checks before sending — surfaces as `InternalError`. No operation returns a bare, unmatchable `error`.

## 7. Serving an Agent

```ballerina
import ballerina/a2a;

final a2a:DefaultHandler weatherAgent = new ({
    name: "Weather Agent",
    description: "Answers weather questions",
    version: "1.0.0",
    skills: [{id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

listener a2a:HttpListener agent = new (9090, weatherAgent);

isolated service a2a:Service on agent {
    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater->working();
        check updater->addArtifact([{text: "Sunny, 22°C"}]);
        check updater->complete();
        return;
    }
}
```

Serving an agent takes three pieces, each with one job:

- **`a2a:DefaultHandler`** is the agent as the protocol sees it: its card, where its tasks are kept, who may see them, what it advertises. It knows nothing about the wire.
- **`a2a:HttpListener`** is how requests reach it: the port, TLS, authentication, the address the card advertises, stream keep-alives.
- **The `a2a:Service`** is your logic: one method, `onMessage`.

Declare the listener at module level: a listener declared inside `main` does not keep the program alive. `capabilities` and `supportedInterfaces` on the card are placeholders; the listener replaces both with what it actually serves, so the published card can never advertise something the server does not do. A `service class` works too, attached with `check agent.attach(new WeatherAgent())` from a module-level `function init()`.

One method, `onMessage`, is the entire agent. The handler runs the rest of the protocol around it: `getTask`, `cancelTask` and `listTasks` over the task `onMessage` created; `sendStreamingMessage` and `subscribeToTask` as Server-Sent Events; and the push-notification configuration operations. The listener adds the well-known discovery endpoint and version and capability gating. Errors are serialized exactly as the client half of this module decodes them, so this module's `HttpClient` can be pointed at its own `HttpListener`. Only HTTP+JSON at protocol version 1.0 is served in this release.

A service chooses its binding with `@a2a:ServiceConfig`. `a2a:REST` (HTTP+JSON) is the default; `a2a:RPC` (JSON-RPC) is reserved, and attaching a service that asks for it fails:

```ballerina
@a2a:ServiceConfig {protocol: a2a:REST}
isolated service a2a:Service on agent {
    // ...
}
```

A handler serves one agent, but can be given to more than one listener. Declaring the service on each, `isolated service a2a:Service on publicListener, internalListener { ... }`, serves the same tasks over both: a task created through one is visible through the other. Giving one handler a second, different service is an error.

### 7.1 Driving a task

`a2a:TaskUpdater` moves a long-running task through its states from inside `onMessage`:

```ballerina
check updater->working();
check updater->addArtifact([{text: "partial result"}]);
check updater->requireInput(promptMessage);
check updater->complete();
```

`requireInput` pauses the task at `TASK_STATE_INPUT_REQUIRED`; a later message continuing the same task (see [section 7.2](#72-live-streaming-and-continuing-a-task)) runs `onMessage` again. Every call is persisted through the attached `a2a:TaskStore`. `requireAuth` is the same shape as `requireInput`, for a task that needs the caller to authorize.

`onMessage` runs detached from the request that started it, so a slow or long-running agent never blocks a separate `subscribeToTask` call from attaching to the same task's events as they happen. A panic in `onMessage` is caught and transitions the task to `TASK_STATE_FAILED` with the panic's message, the same as returning an `a2a:Error` does -- neither crashes the server or strands the task at whatever state it was left in.

### 7.2 Live streaming and continuing a task

`sendStreamingMessage` and `subscribeToTask` both return a live stream: events arrive as `onMessage` produces them, not replayed after the fact. Two callers following the same task -- a `sendStreamingMessage` caller and a later `subscribeToTask` caller, or several `subscribeToTask` callers -- each see every event from the point they attached, in the same order; closing one stream does not affect another (specification section 3.5.2). `subscribeToTask` on a task already in a terminal state is `UnsupportedOperationError`, not a snapshot -- there is nothing further it could ever stream (specification section 3.1.6).

A client continues an existing, non-terminal task by setting `message.taskId` on a later `sendMessage`/`sendStreamingMessage` call:

```ballerina
a2a:Task|a2a:Message reply = check agent->sendMessage({
    message: {
        messageId: "msg-2",
        role: a2a:ROLE_USER,
        taskId: pausedTask.id,
        contextId: pausedTask.contextId,
        parts: [{text: "here is the information you asked for"}]
    }
});
```

`onMessage` runs again against the same task, with the continuing message appended to its `history`. An unrecognized `taskId` is `TaskNotFoundError` -- a client cannot name a new task into existence this way (specification section 3.4.2); a `contextId` that disagrees with the task's own is rejected; a task already terminal cannot be continued (`UnsupportedOperationError`), the same rejection a second concurrent message to a task still being driven gets. Any non-terminal state can be continued, not only `TASK_STATE_INPUT_REQUIRED`/`TASK_STATE_AUTH_REQUIRED`.

`sendMessage`'s default behavior is unchanged: it blocks until the task reaches a terminal or interrupted state, or `onMessage` replies with a direct `a2a:Message`. Set `configuration.returnImmediately: true` to instead get the task back as soon as it exists, without waiting:

```ballerina
a2a:Task submitted = <a2a:Task>check agent->sendMessage({
    message: {messageId: "msg-1", role: a2a:ROLE_USER, parts: [{text: "start this"}]},
    configuration: {returnImmediately: true}
});
```

`onMessage` keeps running detached either way. This removes the implicit backpressure a blocking `sendMessage` gave for free -- every concurrent task used to hold a worker for its full duration -- so a deployment expecting many concurrent long-running tasks under `returnImmediately: true` should plan capacity accordingly. `returnImmediately` has no effect on `sendStreamingMessage`, which already runs detached and streams live regardless (specification's own text); if `onMessage` replies with a direct `a2a:Message` under `returnImmediately: true`, the caller already holds the task's id from the immediate-return snapshot, so the task completes with that `a2a:Message` as its final `status.message` instead of the task disappearing as if it never existed.

`streamIdleTimeout` on `HttpListenerConfiguration` (default 300 seconds) bounds how long a live stream may sit with no event before the server ends it -- the backstop for a client that disconnects without the transport surfacing it as a clean close.

A live stream ends when its task reaches a terminal state or pauses on `TASK_STATE_INPUT_REQUIRED` (specification section 11.7): the client's reply is a new message, and it gets a new stream. A task paused on `TASK_STATE_AUTH_REQUIRED` keeps its stream open, as section 7.6.1 asks, so the client sees the task resume once it has authorized out of band.

`keepAliveInterval` (default 15 seconds, `0` to disable) makes the server send an SSE comment frame (`: keep-alive`) whenever a stream has had nothing to deliver for that long. A long-running agent can easily be quiet for longer than an HTTP idle timeout -- Ballerina's defaults are 60 seconds for a listener and 30 for a client -- and without keep-alives its stream is cut mid-task even though the task carries on. Keep the interval below the smallest idle timeout in play. The client skips the frames, and they do not count as activity: `streamIdleTimeout` still ends a stream nothing is being produced on.

Given a port, `HttpListenerConfiguration` also carries every `http:ListenerConfiguration` field (`timeout`, `secureSocket`, `host`, ...) and applies them to the HTTP listener it creates. Given an already-built `http:Listener` instead, configure that listener when you build it; those fields have nothing to apply to and are ignored.

The interface URL the served card gives clients is built from the request's `Host` header and the scheme the listener really serves: `https` when `secureSocket` is configured, `http` otherwise. When clients do not reach the listener directly, say where they do with `publicUrl`, for a proxy or gateway that terminates TLS or rewrites the host, or for an `http:Listener` passed in whose public address the package cannot know:

```ballerina
listener a2a:HttpListener agent = new (9090, handler, publicUrl = "https://agents.example.com/travel");
```

`publicUrl` must start with `http://` or `https://` and carry no query or fragment; a trailing `/` is dropped. `X-Forwarded-*` headers are not consulted, since any caller can send them.

### 7.3 Task storage

```ballerina
final a2a:DefaultHandler handler = new (card, taskStore = new MyDatabaseTaskStore());
```

`a2a:InMemoryTaskStore` is the default, and its tasks do not survive a restart. Implement `a2a:TaskStore` (`put`, `get`, `list`, `remove`) to back an agent with real storage. `list` must sort by status timestamp, newest first, and omit `artifacts` unless asked.

Live streams reach their subscribers through an `a2a:EventBroadcasterRegistry`. The default, `a2a:InMemoryEventBroadcasterRegistry`, reaches subscribers in the same process. A deployment that needs something else, such as a broker so a subscriber on one instance follows a task driven on another, supplies its own as `eventRegistry`:

```ballerina
final a2a:DefaultHandler handler = new (card, eventRegistry = new MyBrokerEventRegistry());
```

A replacement must keep two guarantees: only one driver at a time per in-flight task (`acquire` returns `()` while another holds it), and every subscriber gets every event in the same order (specification section 3.5.2). To follow a task across instances without replacing anything, use push notifications ([section 7.5](#75-push-notifications)).

### 7.4 The extended Agent Card

```ballerina
final a2a:DefaultHandler handler = new (publicCard, extendedAgentCard = richerCard);
```

Left unset, `capabilities.extendedAgentCard` is `false` and a request for it fails with `UnsupportedOperationError`. Configuring one flips the capability on and serves the card from `GET /extendedAgentCard`.

Specification section 13.3 requires this operation to require authentication: an extended card exists to reveal what the *public* card deliberately doesn't. So a listener given a handler with an `extendedAgentCard` must also be configured with `auth` ([section 7.7](#77-authenticating-callers)); without it, `new a2a:HttpListener(...)` returns an error and nothing is served.

### 7.5 Push notifications

An agent can register, read, list and remove a task's webhook configuration, and this listener actually calls it: whenever a task it drives reaches a new state — including cancellation — every webhook registered for that task gets a POST of the task's current state as a `StreamResponse` — `{"task": {...}}`, the same shape a stream carries (specification section 4.3.3), with media type `application/a2a+json`. Delivery is fire-and-forget: a webhook that is unreachable or errors does not fail the operation that triggered it.

A client registers a webhook one of two ways. Inline, attached to a `sendMessage`/`sendStreamingMessage` call — the only channel that works before a task's id is even known, since a config normally has to name an existing `taskId`:

```ballerina
a2a:Task|a2a:Message reply = check agent->sendMessage({
    message: {messageId: "msg-1", role: a2a:ROLE_USER, parts: [{text: "..."}]},
    configuration: {
        taskPushNotificationConfig: {url: "https://client.example.com/webhooks/a2a"}
    }
});
```

Or explicitly, once a `taskId` is already known — the register/read/list/remove operations from [section 3.2](#32-push-notifications):

```ballerina
a2a:TaskPushNotificationConfig config = check agent->createTaskPushNotificationConfig({
    taskId: "task-1",
    url: "https://client.example.com/webhooks/a2a"
});
```

`config.token`, if set, is echoed back as the `X-A2A-Notification-Token` header on every delivery, for correlation. `config.authentication`, if set, becomes a standard `Authorization: <scheme> <credentials>` header on the outbound call.

Delivery uses `a2a:HttpPushNotificationSender` by default, an HTTP POST with a configurable timeout. It rejects a webhook URL that is not `http`/`https`, or whose host is a loopback, link-local, private (RFC 1918), carrier-grade-NAT, or otherwise non-public address — specification section 13.2's SSRF-protection obligation — before ever connecting:

```ballerina
final a2a:DefaultHandler handler = new (card,
    pushSender = new a2a:HttpPushNotificationSender({validateUrl: false, timeout: 5}));
```

A failed delivery is retried with exponential backoff (specification section 13.2): a connection failure, or a `408`, `429`, `500`, `502`, `503` or `504` answer, is retried three times, 1, 2 and then 4 seconds apart. Any other non-2xx answer fails the delivery at once. `retryConfig` takes an `http:RetryConfig` to change that, or `()` to send each update once. A delivery that still fails is logged as a warning; it never fails the operation that triggered it.

`validateUrl: false` is the escape hatch a deployment with a legitimately internal webhook host needs. The check is by URL form, not by resolving the hostname — a name that only resolves to a private address at connect time (DNS rebinding) is not caught; supply your own `a2a:PushNotificationSender` to close that gap with whatever resolution your deployment trusts.

Streaming and push notifications are always *implemented* by this listener, but each is only *advertised* — and accepted — when its `DefaultHandlerConfiguration` flag is left at its `true` default:

```ballerina
final a2a:DefaultHandler handler = new (card, streamingCapability = false, pushNotificationsCapability = false);
```

Set one `false` when a deployment deliberately wants to withhold that capability — no outbound network access for webhooks, an operator policy against it, whatever the reason. The served card then declares `capabilities.streaming`/`capabilities.pushNotifications` as `false`, and the corresponding operations are rejected server-side (`UnsupportedOperationError` / `PushNotificationNotSupportedError`) exactly as if this listener had never implemented them — never a card that quietly claims something the server then refuses.

### 7.6 Task ownership and authorization scoping

Specification section 13.1 requires that "clients can only access authorized tasks." By default this listener does not enforce that — every task is visible to every caller, in one shared pool. Supply a `TaskOwnerResolver` to change that:

```ballerina
isolated class TeamOwnerResolver {
    *a2a:TaskOwnerResolver;

    public isolated function resolveOwner(a2a:CallerContext context) returns string?|a2a:Error {
        // Scope by team rather than by individual caller. `identity` is the
        // caller `auth` already verified; a resolver that trusts an
        // unverified header instead is not a security boundary.
        string? caller = context?.identity;
        return caller is string ? teamOf(caller) : ();
    }
}

final a2a:DefaultHandler handler = new (card, ownerResolver = new TeamOwnerResolver());
```

The resolver is given an `a2a:CallerContext`, not an HTTP request: the `identity` inbound authentication established, the `tenant` the request was routed under, its `headers` (names lower-cased), and the client certificate when a mutual TLS handshake passed. The same resolver therefore works for any binding a listener serves. It is configured on the handler, so every listener given that handler shares it.

Once configured, `getTask`, `cancelTask`, `listTasks`, `subscribeToTask`, and the four push-notification config operations all become owner-scoped: a task, or a task's push configs, created under one resolved owner are invisible to every other owner — indistinguishable from not existing at all, per the same section's requirement that a server "MUST NOT reveal the existence of resources the client is not authorized to access." `TaskUpdater` stamps every write with the owner the task was created under, so an agent's own driven updates stay in the right scope automatically.

`()` — an unauthenticated caller, or simply no resolver configured — is its own scope, not a wildcard: every caller a resolver maps to `()` shares one pool, isolated from every named owner but not from each other. A resolver alone does not authenticate anyone: it maps a request to an owner, and trusts whatever it reads. Pair it with `auth` ([section 7.7](#77-authenticating-callers)); when `auth` is configured and no resolver is, the authenticated identity is the owner, so most agents need no resolver at all.

### 7.7 Authenticating callers

Specification section 7.4 requires a server to authenticate every incoming request. Configure `auth` with the same entries a service's `@http:ServiceConfig` takes; the listener runs the `ballerina/http` listener auth handlers for you:

```ballerina
listener a2a:HttpListener agent = new (9090, handler, auth = [
    {
        jwtValidatorConfig: {
            issuer: "https://idp.example.com",
            audience: "my-agent",
            signatureConfig: {jwksConfig: {url: "https://idp.example.com/.well-known/jwks.json"}}
        },
        scopes: ["a2a:invoke"]
    }
]);
```

The four kinds of entry are JWT validation (`jwtValidatorConfig`), OAuth2 token introspection (`oauth2IntrospectionConfig`), and Basic authentication against a file (`fileUserStoreConfig`) or an LDAP (`ldapUserStoreConfig`) user store, each with optional `scopes`. Entries are alternatives: a request that any one accepts is admitted. API-key and mutual-TLS authentication are not covered here; mutual TLS is a `secureSocket` setting on the HTTP listener.

With `auth` set:

- every request except the public card at `/.well-known/agent-card.json` must authenticate, including requests for paths that do not exist, so an unauthenticated caller learns nothing about the server;
- a missing or invalid credential is a `401` with a `WWW-Authenticate` challenge for each scheme the entries accept, and a valid one that lacks a required scope is a `403`. Both carry the same `google.rpc.Status` body as any other error, with `ErrorInfo.reason` `UNAUTHENTICATED` or `PERMISSION_DENIED`, and a message that names no resource;
- the rejection happens before the agent runs and before a stream opens, so a rejected `sendStreamingMessage` is a plain `401`, not an event stream;
- the authenticated identity is the task owner. That is a JWT's `sub` (or `username`) claim, the introspected `sub` (or `username`), or the Basic username. A caller sees only its own tasks ([section 7.6](#76-task-ownership-and-authorization-scoping)). A credential that validates but names no one is rejected, since there is no owner to scope to. An `ownerResolver` configured on the handler takes precedence.

The card tells a client how to authenticate (specification section 7.3), so `auth` also fills it in. When the card you pass declares neither `securitySchemes` nor `securityRequirements`, both are derived: JWT and OAuth2 introspection entries become an HTTP `Bearer` scheme named `bearerAuth` (with `bearerFormat: "JWT"` only when every Bearer entry is a JWT), file and LDAP entries become an HTTP `Basic` scheme named `basicAuth`, and each entry is its own requirement, in order, carrying its `scopes`. The extended card gets the same. A client given only the agent's URL and `new a2a:InMemoryCredentialStore({"bearerAuth": token})` then authenticates with nothing else written by hand.

If you declare either field yourself, nothing is derived and yours is served as written. That is the way to publish an `oauth2` or `openIdConnect` scheme, which needs your identity provider's URLs, or a scheme enforced by something in front of the listener. Keep what you declare in agreement with what `auth` enforces: the listener enforces `auth`, and the card only advertises.

`auth` applies whether the listener is given a port or an existing `http:Listener`. Serve over HTTPS in production (specification section 7.1); credentials in the clear are only reasonable on localhost.

An `auth` entry that cannot be set up is an error returned from `new a2a:HttpListener(...)`, naming the entry (`HttpListenerConfiguration.auth[1] (jwtValidatorConfig) could not be initialised: ...`), before anything is bound. That includes an identity provider that cannot be reached at start-up when the entry needs it then: a JWT entry whose `jwksConfig` has a `cacheConfig` preloads the keys, and an LDAP entry connects to the server.

Mind how the JWKS is fetched. Without `jwksConfig.cacheConfig` the identity provider is asked for its keys on every authenticated request, which costs a round trip per call and turns an identity-provider outage into a `401` for every caller. Setting `cacheConfig` avoids that for the keys present at start-up, but `ballerina/jwt` fills that cache once, when the listener starts: a key the provider rotates in later is fetched on every request that uses it, and once `defaultMaxAge` passes the cached keys are gone and the cache is not refilled. Until that is fixed upstream, size `capacity` and `defaultMaxAge` for the life of the process, and expect a per-request fetch for keys rotated in after start-up; restarting the listener refills the cache.

LDAP is passed through to `ballerina/http` and is not covered by this package's tests, which have no LDAP server.
