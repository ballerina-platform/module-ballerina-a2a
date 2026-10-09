# Ballerina A2A Module Examples: Serve an Agent

## Overview

This example demonstrates how to use the Ballerina A2A module to serve an
agent over A2A. It builds the agent's `a2a:DefaultHandler`, serves it on an
`a2a:HttpListener`, implements the one method an agent author writes
(`onMessage`), and lets the library run the rest of the protocol around it.

### Features

- **One method is the whole agent**: `onMessage` is all a developer
  implements -- `getTask`, `cancelTask`, `listTasks`,
  `sendStreamingMessage`/`subscribeToTask` as Server-Sent Events, the
  push-notification configuration operations, and the well-known
  discovery endpoint are all handled by the handler and the listener.
- **Driving a task**: `updater->working()`/`addArtifact()`/`complete()`
  move a task through its lifecycle from inside `onMessage`.
- **A real, discoverable Agent Card**: served at
  `/.well-known/agent-card.json`, built from what this listener actually
  implements -- `capabilities`/`supportedInterfaces` are never left as
  placeholders on the wire, even though this example's own card literal
  leaves both empty (see Code Structure).

## Running the Serve an Agent Example

Start the program using the Ballerina runtime:

```sh
bal run
```

```
Weather Agent listening on http://localhost:9090
```

To run it on a different port:

```sh
bal run -- -CagentPort=9999
```

## Calling It

Any A2A HTTP+JSON v1.0 client works. This module's own
[`call-an-agent`](../call-an-agent/README.md) example, pointed at this
agent's port:

```sh
cd ../call-an-agent
bal run -- -CagentUrl=http://localhost:9090
```

```
Connected to "Weather Agent": Answers weather questions
Task <id>: TASK_STATE_COMPLETED
Result: Sunny, 22°C
```

Or with `curl` directly, bypassing the client module entirely:

```sh
curl -s http://localhost:9090/message:send \
  -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -d '{"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "what is the forecast?"}]}}'
```

## Code Structure

- **The handler**: `final a2a:DefaultHandler weatherAgent = new ({...})` --
  the agent as the protocol sees it: its card, and where its tasks are kept
  and who may see them (left at their defaults here).
  `capabilities`/`supportedInterfaces` in the card literal are placeholders;
  the listener replaces both with what it actually serves, so the published
  card can never advertise something this agent does not do.
- **The listener**: `listener a2a:HttpListener agent = new (agentPort, weatherAgent)`,
  declared at module level -- a listener declared inside `main` does not
  keep the program alive. It owns the wire: the port and, when configured,
  TLS, authentication, and the address the card advertises.
- **The agent itself**: an `isolated service a2a:Service on agent` whose one
  `onMessage` method is the entire business logic. `@a2a:ServiceConfig {protocol: a2a:REST}`
  chooses the HTTP+JSON binding -- the default, written out here to show
  where the choice lives.
