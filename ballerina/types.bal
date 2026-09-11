// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Spec-facing types for the A2A protocol.

# Who a `a2a:Message` came from.
#
# `ROLE_USER` is the client's side of the conversation and `ROLE_AGENT` the
# remote agent's. `ROLE_UNSPECIFIED` is the proto3 zero value and should not
# appear on a conformant message.
public enum Role {
    ROLE_UNSPECIFIED,
    ROLE_USER,
    ROLE_AGENT
}

# One unit of content within a Message.
#
# Per specification section 4.1.6, exactly one of `text`, `raw`, `url`, or
# `data` is set. Version 1.0 removed the `kind` discriminator field in
# favour of member-presence detection — the variant is determined by which
# field is non-nil, not by a tag.
public type Part record {|
    # Text content
    string text?;
    # Inline file bytes; base64 on the wire
    byte[] raw?;
    # File by reference
    string url?;
    # Arbitrary structured data
    json data?;
    # Applies to file variants (raw/url)
    string filename?;
    # MIME type; applies to all variants
    string mediaType?;
    # Free-form metadata attached to this part
    map<json> metadata?;
    // newer specification version can have additional fields
    json...;
|};

# One turn of communication between a client and an agent.
public type Message record {|
    # Required; caller generates a UUID
    string messageId;
    # ROLE_USER for outbound messages
    Role role;
    # Content of this message
    Part[] parts;
    # Groups related tasks and messages
    string contextId?;
    # Set when continuing an existing task
    string taskId?;
    # Other tasks this message references
    string[] referenceTaskIds?;
    # Extension URIs for this message
    string[] extensions?;
    # Free-form metadata attached to this message
    map<json> metadata?;
    // newer specification version can have additional fields
    json...;
|};

# The organization publishing an AgentCard.
public type AgentProvider record {|
    # Publisher name
    string organization;
    # Publisher URL
    string url;
    # Publisher contact email
    string contactEmail?;
    json...;
|};

# A protocol extension an agent supports, identified by URI.
public type AgentExtension record {|
    # Extension identifier
    string uri?;
    # Human-readable summary of what this extension does
    string description?;
    # Whether a client must understand this extension to interact with the agent
    boolean required = false;
    # Extension-specific configuration; shape is defined by the extension itself
    map<json> params?;
    json...;
|};

# Feature flags describing what an agent supports.
public type AgentCapabilities record {|
    # Whether sendStreamingMessage/subscribeToTask are supported
    boolean streaming = false;
    # Whether push-notification webhooks are supported
    boolean pushNotifications = false;
    # Whether the extended agent card endpoint is available
    boolean extendedAgentCard = false;
    # Protocol extensions this agent supports
    AgentExtension[] extensions?;
    json...;
|};

# One capability an agent exposes.
public type AgentSkill record {|
    # Unique within the agent
    string id;
    # Human-readable name
    string name;
    # Human-readable summary of what this skill does
    string description;
    # Categorization tags
    string[] tags;
    # Example prompts illustrating this skill
    string[] examples?;
    # Content types this skill accepts
    string[] inputModes?;
    # Content types this skill produces
    string[] outputModes?;
    # Per-skill security override, following the same OR-of-ANDs semantics as AgentCard.securityRequirements
    SecurityRequirement[] securityRequirements?;
    json...;
|};

# One transport binding an agent is reachable on.
public type AgentInterface record {|
    # Service URL for this interface
    string url;
    # e.g. "JSONRPC", "GRPC", "HTTP+JSON"
    string protocolBinding;
    # Protocol version served on this interface
    string protocolVersion;
    # When set, must be echoed on every subsequent operation against this interface
    string tenant?;
    json...;
|};

# The document a remote agent publishes to describe itself: capabilities,
# service URL, available skills, and required authentication.
public type AgentCard record {|
    # Human-readable agent name
    string name;
    # Human-readable summary of what this agent does
    string description;
    # Agent's own version, not the protocol version
    string version;
    # Feature flags describing what this agent supports
    AgentCapabilities capabilities;
    # Transport bindings this agent is reachable on, in the server's own
    # preference order — the first entry is the preferred one
    AgentInterface[] supportedInterfaces;
    # Content types this agent accepts by default
    string[] defaultInputModes;
    # Content types this agent produces by default
    string[] defaultOutputModes;
    # Capabilities this agent exposes
    AgentSkill[] skills;
    # Organization publishing this agent
    AgentProvider provider?;
    # Link to human-readable documentation
    string documentationUrl?;
    # Link to an icon representing this agent
    string iconUrl?;
    # Security schemes available to authorize requests, keyed by scheme name
    map<SecurityScheme> securitySchemes?;
    # Which security schemes apply; a logical OR across the list, each
    # entry a logical AND of the schemes it names
    SecurityRequirement[] securityRequirements?;
    # JWS signatures over this card, per specification section 8.4.
    #
    # Parsed but not verified by this library. Section 8.4.3's procedure needs
    # a public key only the caller can supply, and canonicalizing the raw body
    # rather than this record — a record carries defaults the signer never
    # sent. Fetch the body with `a2a:fetchAgentCardBody` to verify it yourself.
    AgentCardSignature[] signatures?;
    // v1.0 removed the top-level `protocolVersion` and `url` fields: a card
    // now declares both per interface, in supportedInterfaces. They are
    // deliberately not declared here — this record is open, so a server
    // still sending them round-trips through the rest field, but nothing in
    // this library reads them. Use `primaryUrl(card, binding)` for the
    // endpoint. A card that declares its transports only the pre-v1.0 way is
    // rejected by `isLegacyCard` (client.bal) with VersionNotSupportedError.
    json...;
|};

# Four states are terminal (COMPLETED, FAILED, CANCELED, REJECTED); two are
# interrupted and allow the task to resume on a follow-up message with the
# same taskId (INPUT_REQUIRED, AUTH_REQUIRED).
public enum TaskState {
    TASK_STATE_UNSPECIFIED,
    TASK_STATE_SUBMITTED,
    TASK_STATE_WORKING,
    TASK_STATE_COMPLETED,
    TASK_STATE_FAILED,
    TASK_STATE_CANCELED,
    TASK_STATE_INPUT_REQUIRED,
    TASK_STATE_REJECTED,
    TASK_STATE_AUTH_REQUIRED
}

# A Task's current lifecycle state.
public type TaskStatus record {|
    # Current lifecycle state
    TaskState state;
    # A rich message, not a plain string — lets an agent entering
    # TASK_STATE_INPUT_REQUIRED attach a structured prompt
    Message message?;
    # ISO 8601, e.g. "2023-10-27T10:00:00Z"
    string timestamp?;
    json...;
|};

# One piece of output content produced by a task.
public type Artifact record {|
    # Unique within the task; this is the identifier
    string artifactId;
    # Human-readable label, not an identifier
    string name?;
    # Human-readable summary of this artifact
    string description?;
    # Must contain at least one part
    Part[] parts;
    # Free-form metadata attached to this artifact
    map<json> metadata?;
    # Extension URIs relevant to this artifact
    string[] extensions?;
    json...;
|};

# The stateful unit of work tracked by the A2A protocol.
public type Task record {|
    # Server-generated; clients never create this
    string id;
    # Groups related tasks and messages
    string contextId?;
    # Current lifecycle state
    TaskStatus status;
    # Output produced so far. Absent and empty differ: specification section 3
    # requires this field to be omitted entirely when includeArtifacts is
    # false, and permits an empty array when it is true but the task has none.
    Artifact[] artifacts?;
    # Prior messages exchanged for this task. Omitted when historyLength is 0.
    Message[] history?;
    # Free-form metadata attached to this task
    map<json> metadata?;
    json...;
|};

# A lifecycle transition on a task, delivered over a stream.
public type TaskStatusUpdateEvent record {|
    # Task this event applies to
    string taskId;
    # Context this event's task belongs to
    string contextId;
    # New lifecycle state
    TaskStatus status;
    # Free-form metadata attached to this event
    map<json> metadata?;
    json...;
|};

# Delivered output content, delivered over a stream; supports chunked
# delivery via append/lastChunk.
public type TaskArtifactUpdateEvent record {|
    # Task this event applies to
    string taskId;
    # Context this event's task belongs to
    string contextId;
    # Output content delivered by this event
    Artifact artifact;
    # Append to a previous artifact of the same id
    boolean append = false;
    # Final chunk of this artifact
    boolean lastChunk = false;
    # Free-form metadata attached to this event
    map<json> metadata?;
    json...;
|};

# One event delivered by a streaming operation.
#
# The specification models this as a `oneof` of exactly four arms
# (section 3.2.3), so a union is its exact analogue: an event *is* a Task,
# a Message, a status update, or an artifact update — never a wrapper that
# might hold two of them, or none.
#
# A union works here because the four arms are distinguishable by `is`:
# `a2a:Task` carries `id`, `a2a:Message` carries `messageId`, and the two
# update events carry `taskId`. Match each arm explicitly — every type here is
# an open record, so `else` does not narrow the union.
#
# An event carrying no arm this client recognizes is skipped rather than
# failing the stream, so a later specification revision adding an event type
# cannot break an existing client mid-stream.
public type StreamResponse Task|Message|TaskStatusUpdateEvent|TaskArtifactUpdateEvent;

# Credentials the client presents to a push-notification webhook it registers.
public type AuthenticationInfo record {|
    # IANA HTTP auth scheme, e.g. "Bearer"
    string scheme;
    # Credential value matching `scheme`
    string credentials?;
    json...;
|};

# A webhook the server will POST task updates to.
public type TaskPushNotificationConfig record {|
    # Webhook URL the server will POST to
    string url;
    # Identifier for this push notification config
    string id?;
    # Leave unset in a sendMessage request
    string taskId?;
    # Opaque token the server echoes back on each push, for correlation
    string token?;
    # How the server should authenticate to this webhook
    AuthenticationInfo authentication?;
    # Must match the tenant value from the selected AgentInterface, when
    # that field is set
    string tenant?;
    json...;
|};

# Per-request options for a sendMessage call.
public type SendMessageConfiguration record {|
    # Content types the caller can accept in the response. Omit to impose no
    # constraint -- that is the specification's own meaning for unset, and
    # agents SHOULD tailor their output to whatever this says. It previously
    # defaulted to ["text"], which quietly told every agent to withhold
    # images and files unless a caller overrode it.
    string[] acceptedOutputModes?;
    # Unset imposes no limit; zero omits history entirely; a positive value
    # requests at most that many recent messages
    int historyLength?;
    # False (default) blocks until the task reaches a terminal or
    # interrupted state; true returns as soon as the task is created
    boolean returnImmediately = false;
    # Webhook to register for this task's updates
    TaskPushNotificationConfig taskPushNotificationConfig?;
    json...;
|};

# The request payload for `sendMessage` and `sendStreamingMessage`.
#
# Specification section 10.3 — `SendMessageRequest`. Both operations take
# this same request; only their responses differ.
public type SendMessageRequest record {|
    # The message to send to the agent
    Message message;
    # Opaque routing identifier. Must match the `tenant` value from the
    # selected AgentInterface when that field is set; left unset, the client
    # supplies the tenant its own selected interface declared.
    string tenant?;
    # Per-request options
    SendMessageConfiguration configuration?;
    # Free-form context passed through to the agent
    map<json> metadata?;
    json...;
|};

# The request payload for `getTask`.
#
# Specification section 10.3 — `GetTaskRequest`.
public type GetTaskRequest record {|
    # The resource ID of the task to retrieve
    string id;
    # Opaque routing identifier
    string tenant?;
    # Maximum recent messages to include in `task.history`. Unset imposes no
    # limit; zero requests no messages at all.
    int historyLength?;
    json...;
|};

# The request payload for `listTasks`.
#
# Specification section 10.3 — `ListTasksRequest`. Every field is optional,
# so `c->listTasks()` lists with the server's own defaults.
public type ListTasksRequest record {|
    # Opaque routing identifier
    string tenant?;
    # Restrict to tasks in this context
    string contextId?;
    # Restrict to tasks in this lifecycle state
    TaskState status?;
    # Maximum results per page
    int pageSize?;
    # Opaque cursor from a previous ListTasksResponse.nextPageToken
    string pageToken?;
    # Same semantics as getTask's historyLength
    int historyLength?;
    # RFC 3339 — only tasks whose status changed at or after this timestamp
    string statusTimestampAfter?;
    # Whether to include each task's artifacts in the response
    boolean includeArtifacts?;
    json...;
|};

# The request payload for `cancelTask`.
#
# Specification section 10.3 — `CancelTaskRequest`.
public type CancelTaskRequest record {|
    # The resource ID of the task to cancel
    string id;
    # Opaque routing identifier
    string tenant?;
    # Free-form context passed through to the agent
    map<json> metadata?;
    json...;
|};

# The request payload for `subscribeToTask`.
#
# Specification section 10.3 — `SubscribeToTaskRequest`.
public type SubscribeToTaskRequest record {|
    # The resource ID of the task to subscribe to
    string id;
    # Opaque routing identifier
    string tenant?;
    json...;
|};

# The request payload for `getTaskPushNotificationConfig`.
#
# Specification section 10.3 — `GetTaskPushNotificationConfigRequest`. Both
# identifiers are required and mean different things: `taskId` is the parent
# task, `id` the configuration itself.
public type GetTaskPushNotificationConfigRequest record {|
    # The parent task resource ID
    string taskId;
    # The resource ID of the configuration to retrieve
    string id;
    # Opaque routing identifier
    string tenant?;
    json...;
|};

# The request payload for `listTaskPushNotificationConfigs`.
#
# Specification section 10.3 — `ListTaskPushNotificationConfigsRequest`.
public type ListTaskPushNotificationConfigsRequest record {|
    # The parent task resource ID
    string taskId;
    # Opaque routing identifier
    string tenant?;
    # Maximum results per page
    int pageSize?;
    # Opaque cursor from a previous response's nextPageToken
    string pageToken?;
    json...;
|};

# The request payload for `deleteTaskPushNotificationConfig`.
#
# Specification section 10.3 — `DeleteTaskPushNotificationConfigRequest`.
public type DeleteTaskPushNotificationConfigRequest record {|
    # The parent task resource ID
    string taskId;
    # The resource ID of the configuration to delete
    string id;
    # Opaque routing identifier
    string tenant?;
    json...;
|};

# The request payload for `getExtendedAgentCard`.
#
# Specification section 10.3 — `GetExtendedAgentCardRequest`. Its only field
# is optional, so `c->getExtendedAgentCard()` works with no argument.
public type GetExtendedAgentCardRequest record {|
    # Opaque routing identifier
    string tenant?;
    json...;
|};

# Paginated result of a listTasks call.
public type ListTasksResponse record {|
    # The matching tasks for this page
    Task[] tasks;
    # Opaque cursor for the next page; empty when there are no more results
    string nextPageToken;
    # Echoes the effective page size used
    int pageSize;
    # Total matching tasks across all pages
    int totalSize;
    json...;
|};

# Paginated result of a listTaskPushNotificationConfigs call.
public type ListTaskPushNotificationConfigsResponse record {|
    # The matching configs for this page
    TaskPushNotificationConfig[] configs?;
    # Opaque cursor for the next page; absent when there are no more results
    string nextPageToken?;
    json...;
|};

# Configuration for one OAuth 2.0 Authorization Code flow.
public type AuthorizationCodeOAuthFlow record {|
    # The authorization URL for this flow
    string authorizationUrl;
    # URL for obtaining refresh tokens
    string refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    # Whether the authorization server requires PKCE (RFC 7636) for this flow
    boolean pkceRequired = false;
    json...;
|};

# Configuration for one OAuth 2.0 Client Credentials flow.
public type ClientCredentialsOAuthFlow record {|
    # URL for obtaining refresh tokens
    string refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    # The token URL for this flow
    string tokenUrl;
    json...;
|};

# Configuration for one OAuth 2.0 Implicit flow.
public type ImplicitOAuthFlow record {|
    # The authorization URL for this flow
    string authorizationUrl?;
    # URL for obtaining refresh tokens
    string refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes?;
    json...;
|};

# Configuration for one OAuth 2.0 Resource Owner Password flow.
public type PasswordOAuthFlow record {|
    # The token URL for this flow
    string tokenUrl?;
    # URL for obtaining refresh tokens
    string refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes?;
    json...;
|};

# Configuration for one OAuth 2.0 Device Authorization Grant flow (RFC 8628).
public type DeviceCodeOAuthFlow record {|
    # The device authorization URL for this flow
    string deviceAuthorizationUrl;
    # The token URL for this flow
    string tokenUrl;
    # URL for obtaining refresh tokens
    string refreshUrl?;
    # Scope name to human-readable description
    map<string> scopes;
    json...;
|};

# The set of OAuth 2.0 flows an OAuth2SecurityScheme supports.
#
# The specification models this as a `oneof`, so exactly one arm is set. It
# is kept as a record rather than a Ballerina union because the arm types are
# not mutually distinguishable by `is`: with the two deprecated flows' fields
# all optional (as the specification marks them), a PasswordOAuthFlow value
# satisfies ClientCredentialsOAuthFlow exactly, and a DeviceCodeOAuthFlow
# value satisfies it too once its extra field falls into the rest field.
# Verified. Here the *field name* is the discriminator, which is unambiguous
# where structural typing is not.
public type OAuthFlows record {|
    # Configuration for the Authorization Code flow
    AuthorizationCodeOAuthFlow authorizationCode?;
    # Configuration for the Client Credentials flow
    ClientCredentialsOAuthFlow clientCredentials?;
    # Configuration for the Device Authorization Grant flow
    DeviceCodeOAuthFlow deviceCode?;
    # Configuration for the Implicit flow. Deprecated in the specification;
    # use Authorization Code with PKCE instead.
    ImplicitOAuthFlow implicit?;
    # Configuration for the Resource Owner Password flow. Deprecated in the
    # specification; use Authorization Code with PKCE, or Device Code.
    PasswordOAuthFlow password?;
    json...;
|};

# A security scheme using an API key, per OpenAPI 3.0's Security Scheme
# Object.
public type ApiKeySecurityScheme record {|
    # Human-readable summary of this scheme
    string description?;
    # Where the API key is sent
    "query"|"header"|"cookie" 'in;
    # The header, query, or cookie parameter name
    string name;
    # Discriminator; always "apiKey"
    "apiKey" 'type = "apiKey";
    json...;
|};

# A security scheme using HTTP authentication (e.g. Bearer, Basic), per
# OpenAPI 3.0's Security Scheme Object.
public type HttpAuthSecurityScheme record {|
    # Human-readable summary of this scheme
    string description?;
    # The IANA HTTP Authentication Scheme name, e.g. "Bearer"
    string scheme;
    # Hint for how the bearer token is formatted, e.g. "JWT"
    string bearerFormat?;
    # Discriminator; always "http"
    "http" 'type = "http";
    json...;
|};

# A security scheme using OAuth 2.0, per OpenAPI 3.0's Security Scheme
# Object.
public type OAuth2SecurityScheme record {|
    # Human-readable summary of this scheme
    string description?;
    # The OAuth 2.0 flows this scheme supports
    OAuthFlows flows;
    # URL to the OAuth2 authorization server's RFC 8414 metadata
    string oauth2MetadataUrl?;
    # Discriminator; always "oauth2"
    "oauth2" 'type = "oauth2";
    json...;
|};

# A security scheme using OpenID Connect, per OpenAPI 3.0's Security
# Scheme Object.
public type OpenIdConnectSecurityScheme record {|
    # Human-readable summary of this scheme
    string description?;
    # The OpenID Connect Discovery URL for the provider's metadata
    string openIdConnectUrl;
    # Discriminator; always "openIdConnect"
    "openIdConnect" 'type = "openIdConnect";
    json...;
|};

# A security scheme using mutual TLS authentication, per OpenAPI 3.0's
# Security Scheme Object.
public type MutualTlsSecurityScheme record {|
    # Human-readable summary of this scheme
    string description?;
    # Discriminator; always "mutualTLS"
    "mutualTLS" 'type = "mutualTLS";
    json...;
|};

# A security scheme an agent declares as available to authorize requests.
# Discriminated by the `type` field's literal value; cloneWithType against
# this union selects the one variant whose `type` literal matches the JSON.
public type SecurityScheme ApiKeySecurityScheme|HttpAuthSecurityScheme|OAuth2SecurityScheme
    |OpenIdConnectSecurityScheme|MutualTlsSecurityScheme;

# One security requirement: a set of scheme names that must all be
# satisfied together (an AND), with each scheme's required OAuth scopes
# (empty for scheme types that don't use scopes). AgentCard/AgentSkill
# express a list of these, which is an OR across the list — "either this
# whole requirement, or that one."
public type SecurityRequirement map<string[]>;

# A JSON Web Signature (RFC 7515) computed over an AgentCard, for
# authenticity verification.
#
# This library captures the signature's shape so a card round-trips
# without loss, but does **not** verify it. Spec 8.4.3 mandates a
# canonicalize-and-verify procedure without defining an API for it, and
# no reference SDK implements one; a prior attempt here could not perform
# the RFC 8785 canonicalization the procedure requires. Callers needing
# verification must do it out-of-band for now. See issue #12.
public type AgentCardSignature record {|
    # Unprotected JWS header values
    map<json> header?;
    # Base64url-encoded protected JWS header
    string protected;
    # Base64url-encoded computed signature
    string signature;
    json...;
|};

