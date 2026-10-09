# Change Log

This file documents all significant changes made to the Ballerina A2A package across releases.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- [Introduce `ballerina/a2a`, an A2A (Agent2Agent) Protocol Client over HTTP+JSON](https://github.com/ballerina-platform/ballerina-library/issues/9158)
- Add `HttpClient`, Which Resolves an Agent's Card and Connects over the HTTP+JSON Binding
- Add Agent Card Discovery and Parsing via `resolveAgentCard`
- Add Server-Sent Events Streaming for `sendStreamingMessage` and `subscribeToTask`, with Opt-In Automatic Reconnection
- Add Credential Resolution by Security-Scheme Name via `CredentialProvider` and `InMemoryCredentialStore`
- Add the Nine Error Types of Specification Section 5.4 as Distinct Subtypes of `Error`, plus `InternalError` for Unnamed Failures
- Add `HttpListener`, an A2A Server over the HTTP+JSON Binding, Where a Single `Service.onMessage` Method Is the Whole Agent
- Add `DefaultHandler`, the Transport-Free Engine Holding an Agent's Card, Task Store, and Policies, Built Once and Given to One or More Listeners So Each Serves the Same Tasks
- Add `@ServiceConfig`, Choosing the Binding a Service Is Served Over: `REST` (HTTP+JSON), with `RPC` Reserved
- Add `TaskUpdater` for Driving a Task Through Its States, Including Streaming and Input-Required Pauses
- Add `TaskStore` and the Default `InMemoryTaskStore`, Which Enforces Legal State Transitions
- Add Task-Scoped Push-Notification Configuration Storage and an Optional Extended Agent Card to the Server
- Add `TaskOwnerResolver` for Per-Caller Task and Push-Notification-Config Visibility Scoping, per Specification Section 13.1, Resolving From a Transport-Free `CallerContext` That Carries the Identity Authentication Already Established
- Add Real Push-Notification Delivery via `PushNotificationSender`, with `HttpPushNotificationSender` Rejecting Non-Public Webhook URLs by Default per Specification Section 13.2
- Run `onMessage` Detached from the Request That Started It, so a Separate `subscribeToTask` Call Can Follow a Task Still in Progress
- Stream `sendStreamingMessage` and `subscribeToTask` Live, with Correct Multi-Subscriber Fan-Out per Specification Section 3.5.2
- Add `EventBroadcaster` and `EventBroadcasterRegistry`, Making Live-Event Fan-Out Pluggable Like `TaskStore`, with `InMemoryEventBroadcasterRegistry` as the Default
- Add Task Continuation via `message.taskId`, per Specification Sections 3.4.2 and 3.4.3
- Honor `SendMessageConfiguration.returnImmediately`, Returning a Task Before `onMessage` Finishes
- Enforce Required Extensions per Specification Sections 3.3.4/4.6.3, via the `A2A-Extensions` Header
- Serve `securityRequirements` in the Correct v1.0 Wire Shape, and Add Agent Card `Cache-Control`/`ETag` Headers per Specification Section 8.6.1
- Add `DefaultHandlerConfiguration.streamingCapability`/`pushNotificationsCapability`, Letting a Deployment Deliberately Withhold a Capability the Server Otherwise Always Implements
- Add `HttpListenerConfiguration.keepAliveInterval`, Sending SSE Keep-Alive Comments so a Quiet, Long-Running Stream Survives HTTP Idle Timeouts
- Add `HttpListenerConfiguration.auth`, Authenticating Every Request Except the Public Card with `ballerina/http`'s JWT, OAuth2 Introspection, and File/LDAP Basic Handlers per Specification Section 7.4, with the Authenticated Identity Scoping Tasks per Section 13.1
- Derive the Served Agent Card's `securitySchemes` and `securityRequirements` from `HttpListenerConfiguration.auth` when the Card Declares Neither, per Specification Sections 7.3 and 13.3
- Add `AuthenticationError` (401) and `AuthorizationError` (403), Typed from the `ErrorInfo` Reason or the Bare Status, with an `AuthenticationError` Carrying the `WWW-Authenticate` Challenges; the Server Maps Both to Their Statuses
- Refuse to Start an `HttpListener` Given a Handler with an `extendedAgentCard` but No `auth`, per Specification Section 13.3 (a Breaking Change for Any Such Configuration)
- Add `HttpListenerConfiguration.publicUrl`, the Base URL Served as the Card's Interface URL, for a Listener Behind a Proxy or Gateway That Terminates TLS or Rewrites the Host
- Retry Push-Notification Delivery With Exponential Backoff per Specification Section 13.2, via `PushNotificationSenderConfiguration.retryConfig` (Three Retries, 1, 2 and 4 Seconds Apart, by Default; `()` Sends Once)
- Attach a `google.rpc.BadRequest` Entry Naming the Field at Fault to Validation Errors, per Specification Section 11.6, With the Field Also in `ErrorInfo.metadata.field`
- Name the Required Scopes in a 403, in Its Message and in `ErrorInfo.metadata.requiredScopes`, per Specification Section 3.3.2
- Log Authentication Failures, Authorization Denials, Agent Failures and Undeliverable Push Notifications Through `ballerina/log`, Never Including Credentials, per Specification Section 13.4

### Fixed

- A Live Stream Now Ends When Its Task Pauses on `TASK_STATE_INPUT_REQUIRED`, per Specification Section 11.7, Instead of Staying Open Until `streamIdleTimeout`; `TASK_STATE_AUTH_REQUIRED` Still Keeps It Open (Section 7.6.1). `EventBroadcasterRegistry.release`'s Second Parameter Is Renamed `terminal` to `closed` to Match (a Breaking Change for a Custom Registry Calling It by Name)
- `historyLength: 0` Now Omits `history` Entirely, per Specification Section 3.2.4, Instead of Sending an Empty Array
- `includeArtifacts` Other Than `true`/`false`, and a Non-Numeric `historyLength` on `getTask` or `pageSize` on the Push-Config List, Are Now a `400` Instead of Being Read as `false` or Ignored
- A Push Notification the Webhook Answers With a Non-2xx Status Is Now a Failed Delivery; It Was Counted as Delivered
- Status Timestamps Are Now Written at Millisecond Precision, per Specification Section 5.6.1, Instead of Microseconds
- The Extended Agent Card Is Now Served `Cache-Control: private`, So a Shared Cache Cannot Store It for Other Callers (Specification Section 13.3)
- Return an `InternalError`, Not a Panic, from `HttpClient` and `resolveAgentCard` When the Initial OAuth2 Token Cannot Be Obtained (a Wrong Client Secret, an Unreachable Token Endpoint)
- Return an `InternalError` Naming the Entry, Not a Panic, from `HttpListener` When an `auth` Entry Cannot Be Initialised (a JWKS That Cannot Be Preloaded, an Unreachable LDAP Server); the Authenticator Is Now Built Before the HTTP Listener
- An `HttpListener` Serving TLS Now Advertises an `https` Interface URL in Its Card, Instead of `http`, Which Sent Clients to Plain HTTP on a TLS Port (Specification Section 7.1)
- Serve the Agent Card's `securitySchemes` in the Specification's Wrapped Shape (`{"httpAuthSecurityScheme": {...}}`, with `location` for an API Key), Instead of the Flat Shape with a `type` Discriminator, per Specification Section 4.5
- A Request to a Path That Is No A2A Operation Is Now a 404 (`METHOD_NOT_FOUND`), and a Request Naming a Tenant the Agent Does Not Serve Is Now a 400 (`INVALID_PARAMS`), Instead of a 500 for Both; the Specification Reserves 5xx for System Failures and an Agent's Own Malformed Response
- A 401 or 403 Is Now an `AuthenticationError` or `AuthorizationError` Instead of an `InternalError` Carrying That Status as Its Code
- `subscribeToTask` on an Already-Terminal Task Now Correctly Answers `UnsupportedOperationError` per Specification Section 3.1.6, Instead of a One-Event Snapshot
- A Panic or Returned `Error` from `onMessage` Now Transitions the Task to `TASK_STATE_FAILED` Instead of Leaving It at Whatever State It Was Left In
- A Second Concurrent Message to a Task Already Being Driven Is Now Rejected Before Its Text Is Written to History or Its Inline Push Config Is Registered, Instead of After
- Subscribing to a Task Just as It Reaches a Terminal State No Longer Leaks a Broadcaster That Nothing Will Ever Close (Specification Section 3.1.6)
- `notifyPushConfigs` Now Runs Detached from `sendMessage`/`cancelTask`'s Response, So a Slow or Unresponsive Registered Webhook No Longer Holds Up the Caller
- A Fresh Task's `history` Now Seeds With the Triggering Message, Matching the Continuation Path, Which Has Always Appended It
- `cancelTask` Racing a Driver to a Different Terminal State Now Answers `TaskNotCancelableError` Instead of a Bare 500
- A Direct `Message` Reply to a Continued (Not Fresh) Task No Longer Closes Every Other Live Subscriber's Stream for That Task (Specification Section 3.5.2)
- The Webhook SSRF Guard No Longer Refuses Ordinary Hostnames That Happen to Start With `fc`/`fd` (e.g. `fdic.gov`), and Now Correctly Rejects IPv4-Mapped and Uncompressed-Form IPv6 Loopback/Link-Local Addresses It Previously Let Through (Specification Section 13.2)
- The Extended Agent Card Now Has Its `capabilities`/`supportedInterfaces` Derived the Same Way the Public Card's Are, Instead of Being Served With Whatever Placeholder Shape the Developer's Card Literal Had
- `GET /pushNotificationConfigs` With No Task Id No Longer Panics the Handler; It Is Now a 404
- A Tenant Segment Sharing a Prefix With a Known Operation Path (e.g. `/tasks-eu/...`) Is No Longer Misrouted as an Unmatched `/tasks` Request
- A Client Disconnecting From a Live Stream Now Actually Closes the Server-Side Subscription, Instead of Leaving It Idle Until `streamIdleTimeout`
- `listTaskPushNotificationConfigs` on a Task With No Registered Configs No Longer Panics
- The Webhook SSRF Guard Now Rejects a Numbers-and-Dots IPv4 Form a Real Resolver Still Accepts (`127.1`, `10.1`, a Single 32-Bit Decimal, or the Cloud Metadata Address Folded Into One Number), and a Hostname With a Trailing Dot, Both of Which Previously Bypassed It
- A Task That Fails (`onMessage` Returns an `Error`, or Panics) Now Notifies Its Registered Webhooks, Matching Every Other State Transition
- An Inline `taskPushNotificationConfig` on `sendMessage`/`sendStreamingMessage` Is Now Rejected When `capabilities.pushNotifications` Is `false`, Instead of Being Silently Registered
- `sendMessage` and `sendStreamingMessage` Now Honor `configuration.historyLength`, Trimming `task.history` the Same Way `getTask` and `listTasks` Already Did (Specification Sections 3.1.3, 3.2.2, 3.2.4); Previously the Full History Was Always Returned, Including the One Task Snapshot a Streaming Send Broadcasts Live
- `HttpClient` No Longer Builds a Double-Slashed Path (`//message:send`) Against an Agent Whose Card Interface URL Ends in `/`, a Real Shape a Root-Mounted `@a2a-js/sdk` Agent Advertises
- `HttpClient.listTasks` No Longer Rejects a `"tasks": null` Response, Which a Real `a2a-go` Server Sends for an Empty Page (Its Go Zero Value for an Unset Slice); Treated as an Empty List, Matching What ProtoJSON Already Means for a Missing Repeated Field
- `A2A-Version` Is Now Matched on `Major.Minor` Only, per Specification Section 3.6; a Patch-Qualified Version Like `1.0.5` Was Previously Refused as Unsupported, Even Though Both Reference SDKs Already Accept It
- `GET /tasks` Now Applies Specification Section 3.1.4's Own `pageSize` Bounds — a Default of 50 When Unset, and an Explicit `400` for a Value Outside 1–100 — Instead of Returning Every Matching Task Unbounded, or Silently Turning a Zero or Negative Value Into an Empty Page
- `GET /tasks` Now Rejects an Unrecognized `status`, a Non-Numeric `pageSize`/`historyLength`, an Unparseable `statusTimestampAfter`, or a `pageToken` Naming No Task in the Result Set With a `400`, per the Validation Example in Specification Section 6.5 — Previously Each Was Silently Dropped or Misread as "No Results," Not Reported as the Caller's Own Mistake
- Corrected a Comment Above `errorBindingFor` That Misdescribed Specification Section 5.4's Error-Code Table; the Actual HTTP Statuses Returned for `TaskNotCancelableError`/`ContentTypeNotSupportedError`/`InvalidAgentResponseError` Are Unchanged and Already Match Every Reference SDK Checked
- `HttpClient` No Longer Silently Reads an Unparseable 2xx Body (a Truncated Stream, an HTML Error Page) as an Empty `{}` Success; It Is Now a Typed `InvalidAgentResponseError`, Except for `deleteTaskPushNotificationConfig`, Whose google.protobuf.Empty Wire Response Legitimately Has No Body
- `HttpClient.listTasks` No Longer Rejects a Response That Omits `nextPageToken`/`pageSize`/`totalSize` at Their Default Value, Which a Real `a2a-rs` Server's Last Page (and `{}` for an Empty Page) Sends; Defaulted to `""`/`0`/`0`, Matching What ProtoJSON Already Means for Omitted Default-Valued Fields (Specification Section 5.7) and What Both Reference Clients Already Accept
- `HttpClient` Now Accepts a `null` `history`/`metadata` on a `Task` and an Integer `TaskState` Ordinal in Place of Its Name, Both of Which ProtoJSON Permits (Specification Section 5.5) and Both Reference Clients Already Read; No Reference Server Has Been Seen Sending Either Yet
- `GET /tasks/{id}`, `POST /tasks/{id}:cancel`, and `GET`/`POST /tasks/{id}:subscribe` No Longer Treat a `/` Inside `{id}` as Part of the Task Id (e.g. `GET /tasks/a/b/c` as a Lookup for Task `a/b/c`); Such a Path Now Falls Through to the Same `404 METHOD_NOT_FOUND` an Unmatched Route Gets, Since the Proto's `{id=*}` Matches Exactly One Path Segment
