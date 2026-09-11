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

// Auth adaptation between the HTTP and gRPC client stacks, and optional
// card-driven credential resolution.
//
// Two ways to configure auth, deliberately kept separate:
//
// 1. `clientConfig.auth` and `headers` — the direct route, unchanged, and
//    the only route for OAuth2, OpenID Connect, and mutual TLS. These need
//    a live token exchange or a client certificate rather than a single
//    string, and ballerina/http already handles them properly, token refresh
//    included.
// 2. `CredentialProvider` — optional, opt-in, and scoped on purpose to the
//    schemes that *do* reduce to one string: API-key-in-header and HTTP
//    bearer/basic. Given a card, the provider is asked for a credential by
//    security-scheme name and the resolved value becomes a request header.
//
// An earlier buildAuthFromCard/ResolvedAuth pair was removed before
// release (issue #13) for three reasons, each of which this addresses
// rather than repeats: it claimed to cover all five scheme kinds while
// genuinely handling two (this one documents the boundary and defers the
// rest to route 1); no reference SDK did card-driven resolution at the
// time (both now ship the same scheme-name-keyed CredentialService shape);
// and it made resolution implicit (this is off unless a provider is
// passed, and the read-only view of the same card data is exposed
// separately in skill_security.bal).

# Supplies credentials by security-scheme name.
#
# The name is the key an AgentCard uses in its `securitySchemes` map, so a
# provider holding several credentials keeps them apart even when they are the
# same kind — two different bearer tokens on one agent, which a single
# `headers` map cannot express.
#
# Implement this to source credentials from wherever they live: a vault, a
# config file, an environment variable, a per-session store. Use
# `a2a:InMemoryCredentialStore` for the simple cases.
#
# Returning `()` is normal and not an error — the request is sent without that
# credential and the agent decides how to respond.
public type CredentialProvider isolated object {

    # Returns the credential for one security scheme.
    #
    # + schemeName - The scheme's key in `AgentCard.securitySchemes`
    # + return - The credential, or `()` if none is held for this scheme —
    #            for HTTP basic, the raw `username:password`, which this
    #            library base64-encodes
    public isolated function getCredential(string schemeName) returns string?;
};

# A `CredentialProvider` holding credentials in memory.
#
# ```ballerina
# a2a:InMemoryCredentialStore store = new ({"bearer-admin": "tok_abc"});
# a2a:Client agent = check new ("https://agent.example.com", credentials = store);
# ```
#
# Credentials may be added or replaced after construction, so a refreshed
# token does not require building a new client.
public isolated class InMemoryCredentialStore {
    *CredentialProvider;

    private map<string> credentials;

    # Creates a store, optionally pre-populated.
    #
    # ```ballerina
    # a2a:InMemoryCredentialStore store = new ({"bearerAuth": "eyJhbGciOi..."});
    # ```
    #
    # + credentials - Initial credentials, keyed by security-scheme name
    public isolated function init(map<string> credentials = {}) {
        self.credentials = credentials.clone();
    }

    # Adds or replaces one credential.
    #
    # + schemeName - The scheme's key in `AgentCard.securitySchemes`
    # + credential - The credential value
    public isolated function setCredential(string schemeName, string credential) {
        lock {
            self.credentials[schemeName] = credential;
        }
    }

    # Returns the credential for one security scheme.
    #
    # + schemeName - The scheme's key in `AgentCard.securitySchemes`
    # + return - The credential, or () if none is held
    public isolated function getCredential(string schemeName) returns string? {
        lock {
            return self.credentials[schemeName];
        }
    }
}

# Header names a resolved credential must never occupy.
#
# A card's API-key scheme names its own header, and a card is not
# necessarily verified (signature checking is opt-in), so an agent could
# otherwise declare a scheme whose header name is one this library relies
# on and quietly change the protocol version or content type of every
# request. Compared case-insensitively, since HTTP header names are.
final readonly & string[] RESERVED_CREDENTIAL_HEADERS = ["a2a-version", "content-type", "a2a-extensions"];

# Turns one security requirement into request headers, if it can be
# satisfied in full.
#
# A requirement is an AND: every scheme it names must resolve to a header,
# or the whole requirement fails and the caller moves on to the next one.
# A requirement fails here when the card does not declare a named scheme,
# when the provider holds no credential for it, when the scheme is a kind
# this route does not cover (OAuth2, OpenID Connect, mutual TLS - see this
# file's header comment), when an API key is carried somewhere other than a
# header, or when the resolved header name is reserved.
#
# + card - The agent's card, source of the scheme definitions
# + requirement - The requirement to try
# + provider - Supplies credentials by scheme name
# + return - The headers satisfying the whole requirement, or () if it
#            cannot be satisfied
isolated function credentialHeadersFor(AgentCard card, SecurityRequirement requirement,
        CredentialProvider provider) returns map<string>? {
    map<string> headers = {};
    // Header names are case-insensitive, and two schemes in one AND
    // requirement can land on the same one -- HTTP bearer and an apiKey named
    // "Authorization", say. Overwriting would send one credential and report
    // both satisfied, so a collision fails the requirement instead.
    string[] occupied = [];
    foreach string schemeName in requirement.keys() {
        SecurityScheme? scheme = card.securitySchemes[schemeName];
        if scheme is () {
            return ();
        }
        string? credential = provider.getCredential(schemeName);
        if credential is () {
            return ();
        }
        string headerName;
        string headerValue;
        if scheme is ApiKeySecurityScheme {
            if scheme.'in != "header" {
                // Query- and cookie-borne API keys would have to reshape
                // the URL or set a cookie jar, neither of which belongs in
                // a header map.
                return ();
            }
            headerName = scheme.name;
            headerValue = credential;
        } else if scheme is HttpAuthSecurityScheme {
            string kind = scheme.scheme.toLowerAscii();
            if kind == "bearer" {
                headerName = "Authorization";
                headerValue = string `Bearer ${credential}`;
            } else if kind == "basic" {
                // The whole `username:password` string is encoded as-is.
                // Nothing here parses it, so the RFC 7617 subtlety that
                // sank the previous implementation - a password may
                // contain ":", a username may not, so a naive split
                // corrupts the credential - cannot arise.
                headerName = "Authorization";
                headerValue = string `Basic ${credential.toBytes().toBase64()}`;
            } else {
                return ();
            }
        } else {
            return ();
        }
        string normalized = headerName.toLowerAscii();
        if RESERVED_CREDENTIAL_HEADERS.indexOf(normalized) is int {
            return ();
        }
        if occupied.indexOf(normalized) is int {
            return ();
        }
        occupied.push(normalized);
        headers[headerName] = headerValue;
    }
    return headers;
}

# Resolves the headers for the first card-level security requirement the
# provider can satisfy in full.
#
# `AgentCard.securityRequirements` is an OR: any one entry being satisfied
# is enough, so entries are tried in declared order and the first complete
# match wins.
#
# Resolution is deliberately card-level, not per-skill. A `a2a:Message` carries
# no skill identifier — neither here nor in the specification's own proto — so
# at send time there is no way to know which skill will serve a call, and
# therefore no way to pick that skill's credential. Read
# `AgentSkill.securityRequirements` off the card for the per-skill view.
#
# + card - The agent's card
# + provider - Supplies credentials by scheme name, or () if the client was
#              built without one
# + return - Headers for the first satisfiable requirement; empty if there
#            is no provider, no declared requirement, or none can be met
isolated function resolveCredentialHeaders(AgentCard card, CredentialProvider? provider) returns map<string> {
    if provider is () {
        return {};
    }
    foreach SecurityRequirement requirement in card.securityRequirements ?: [] {
        map<string>? headers = credentialHeadersFor(card, requirement, provider);
        if headers is map<string> {
            return headers;
        }
    }
    return {};
}
