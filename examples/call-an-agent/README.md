# Ballerina A2A Module Examples: Call an Agent

## Overview

This example demonstrates how to use the Ballerina A2A module to discover
and call a remote agent. It resolves the target's Agent Card, connects to
it, sends a message, and prints the reply.

### Features

- **Agent discovery**: Resolves an agent's card via `resolveAgentCard`.
- **Sending messages**: Sends a message using the HTTP+JSON client.
- **Handling replies**: Distinguishes a direct `Message` reply from a
  tracked `Task`.

## Prerequisites

### 1. Run a target agent

You need a running A2A agent that serves HTTP+JSON at protocol v1.0. This
example defaults to the
[`dice_agent_rest`](https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/dice_agent_rest)
sample from [`a2aproject/a2a-samples`](https://github.com/a2aproject/a2a-samples):

```sh
git clone https://github.com/a2aproject/a2a-samples.git
cd a2a-samples/samples/python/agents/dice_agent_rest
export GOOGLE_API_KEY=<your key>
uv run .
```

It listens on `http://localhost:10101` by default, matching this example's
default `agentUrl`. Any other A2A HTTP+JSON v1.0 agent works the same way.

## Running the Call an Agent Example

Start the program using the Ballerina runtime:

```sh
bal run
```

```
Connected to "Dice Agent": An agent that can roll arbitrary dice and answer if numbers are prime
Task <id>: TASK_STATE_COMPLETED
Result: You rolled an 11 sided die and got 7!
```

`dice_agent_rest` is backed by a live model call, so the exact roll and
wording vary between runs.

To point it at a different agent:

```sh
bal run -- -CagentUrl=http://localhost:9999
```

## Code Structure

- **Agent discovery**: `resolveAgentCard` fetches and parses the target's
  card.
- **`HttpClient`**: Constructed directly from the already resolved card.
- **Reply handling**: `sendMessage` returns either a `Message` or a `Task`;
  both are matched explicitly.
