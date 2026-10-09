# Ballerina A2A Module Examples

## Overview

Runnable examples demonstrating `ballerina/a2a`'s client and listener --
this module ships the HTTP+JSON binding at protocol v1.0, both sides.

### Call an Agent

Discovers a remote agent's Agent Card, connects, sends a message, and
handles both reply shapes (`a2a:Task` or a direct `a2a:Message`). Point it
at any A2A HTTP+JSON v1.0 agent; defaults to the official
[`dice_agent_rest`](https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/dice_agent_rest)
sample from [`a2aproject/a2a-samples`](https://github.com/a2aproject/a2a-samples).
See [`call-an-agent/README.md`](call-an-agent/README.md).

### Serve an Agent

Serves an agent over A2A: one `onMessage` method is the whole business
logic, an `a2a:DefaultHandler` runs the rest of the protocol (task
lifecycle, streaming, push-notification config) around it, and an
`a2a:HttpListener` serves it on the wire, card discovery included. Works
with `call-an-agent` pointed at its port, or any other A2A HTTP+JSON v1.0
client.
See [`serve-an-agent/README.md`](serve-an-agent/README.md).
