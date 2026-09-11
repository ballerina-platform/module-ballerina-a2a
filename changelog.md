# Change Log

This file documents all significant changes made to the Ballerina A2A package across releases.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial release of the A2A client, implementing the eleven client operations of A2A protocol v1.0 (specification section 9.4) over the HTTP+JSON binding.
- `Client`, which resolves an agent's card and connects over the binding it declares, and `RestClient` for an agent already known to serve HTTP+JSON.
- Agent Card discovery and parsing: `resolveAgentCard`, `fetchAgentCardBody`, `parseAgentCardBody`.
- Server-Sent Events streaming for `sendStreamingMessage` and `subscribeToTask`, with opt-in automatic reconnection.
- Credential resolution by security-scheme name via `CredentialProvider` and `InMemoryCredentialStore`.
- The nine error types of specification section 5.4, each a distinct subtype of `Error`, plus `InternalError` for failures the protocol does not name.
