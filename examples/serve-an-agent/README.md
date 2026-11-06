# Ballerina A2A Module Examples: Serve an Agent

## Overview

This example demonstrates how to use the Ballerina A2A module to serve an
agent over A2A. The agent is a service attached to an
`a2a:RestListener`, which serves it at `/rest`. It carries the agent card, defines the A2A operations,
and hands each one to an `a2a:DefaultHandler`, which runs the task around
the agent's `a2a:AgentExecutor`.

### Features

- **One class is the agent's logic**: the executor's `execute` method is
  all a developer writes for the agent itself. The service's operations
  (the `get tasks/[string id]`, `post tasks/[string id]/cancel` and
  `get tasks` resources, `post message\:stream` and the subscribe resource
  as Server-Sent Events, the push-notification resources) delegate to the
  handler.
- **Driving a task**: `updater.working()`/`addArtifact()`/`complete()`
  move a task through its lifecycle from inside `execute`.
- **A real, discoverable Agent Card**: declared once with
  `@a2a:ServiceConfig` and served at `/.well-known/agent-card.json`. Its
  `capabilities` and `supportedInterfaces` are derived from the operations
  the service defines and the listener's address, so they are never
  placeholders on the wire, even though this example's card literal leaves
  both empty (see Code Structure).

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
bal run -- -ClistenerPort=9999
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
curl -s http://localhost:9090/rest/message:send \
  -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -d '{"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "what is the forecast?"}]}}'
```

## Code Structure

- **The executor**: `isolated class WeatherExecutor` implements
  `a2a:AgentExecutor`. Its `execute` method is the agent's business logic.
- **The service**: `isolated service on new a2a:RestListener(listenerPort)`.
  The listener names the binding: `a2a:RestListener` serves HTTP+JSON under `/rest`. The `new` creates the
  listener, which owns the wire -- the port and, when configured, TLS,
  authentication, and the address the card advertises -- and holds no agent.
  The Ballerina runtime attaches the service to it and starts it, so there
  is no `main`.
- **The card**: `@a2a:ServiceConfig` carries the agent card.
  `capabilities`/`supportedInterfaces` in the card literal are placeholders
  that the listener replaces with what the service defines, so the
  published card can never advertise something this agent does not do.
- **The handler**: a `private final a2a:DefaultHandler` field of the
  service, built from the executor. Each operation the service defines
  hands its request to it. Leaving an operation out answers
  `UnsupportedOperationError` and drops its capability from the card; this
  example defines every operation except the extended card, which needs
  `auth` on the listener.

To configure the listener (TLS, `auth`, `publicUrl`) or share it between
services, declare it at module level and name it in the service instead:
`listener a2a:RestListener agent = new (listenerPort, auth = [...]);` and
`isolated service on agent`.
