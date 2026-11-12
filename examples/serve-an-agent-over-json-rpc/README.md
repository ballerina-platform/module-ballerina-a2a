# Ballerina A2A Module Examples: Serve an Agent over JSON-RPC

## Overview

This example serves the same weather agent as [`serve-an-agent`](../serve-an-agent/README.md), over the JSON-RPC 2.0
binding. The agent is a service attached to an `a2a:JsonRpcListener`, which serves it at `/rpc`.

### Features

- **Operations are `remote` functions named for the JSON-RPC methods**: `sendMessage`, `sendStreamingMessage`,
  `getTask`, `cancelTask`, and so on. Where HTTP+JSON addresses an operation by verb and path, JSON-RPC addresses it
  by method name. Each takes an optional `a2a:Context` and delegates to an `a2a:DefaultHandler`.
- **The same agent logic**: `WeatherExecutor` is identical to the REST example, since the executor knows nothing
  about the wire.
- **Failures are JSON-RPC errors**: an `error` object on a 200 with the specification's codes. The streaming methods
  answer with Server-Sent Events whose every `data` is a complete JSON-RPC response.
- **A derived card**: served at `/.well-known/agent-card.json` with a `JSONRPC` interface at `/rpc`, and capabilities
  that follow from the functions defined.

## Running the Example

```sh
bal run
```

```
Weather Agent listening on http://localhost:9092/rpc
```

To run it on a different port:

```sh
bal run -- -ClistenerPort=9999
```

## Calling It

`a2a:RestClient` speaks the HTTP+JSON binding, so call this agent with a JSON-RPC client, such as the
[`a2a-sdk`](https://github.com/a2aproject/a2a-python) or `@a2a-js/sdk`, or with `curl`:

```sh
curl -s http://localhost:9092/rpc \
  -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -d '{"jsonrpc": "2.0", "id": 1, "method": "SendMessage",
       "params": {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "what is the forecast?"}]}}}'
```

The reply is a JSON-RPC response whose `result.task` is completed, with the artifact "Sunny, 22°C".

An operation the service does not define answers `UnsupportedOperationError` (`-32004`), and the card does not
claim the capability.
