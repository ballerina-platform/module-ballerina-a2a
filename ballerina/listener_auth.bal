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

// Inbound authentication for the listener.
//
// [Specification section 7.4](https://a2a-protocol.org/latest/specification/#74-server-authentication-responsibilities)
// requires a server to authenticate every incoming request. This reuses the
// `ballerina/http` listener auth handlers rather than validating credentials
// here: the JWT, OAuth2 introspection, and file / LDAP user store handlers
// are public, and `http:ListenerAuthConfig` is the same configuration a
// developer writes in `@http:ServiceConfig`.
//
// The annotation route itself is not open to a library: the dispatcher is a
// service class this package owns, so a developer cannot annotate it, and
// `http:ListenerConfiguration` carries no interceptors. What `ballerina/http`
// keeps private is only the small step that picks a handler for a request's
// credential scheme; that step is what `ListenerAuthenticator` reproduces.

import ballerina/auth;
import ballerina/http;
import ballerina/jwt;
import ballerina/oauth2;

# The credential scheme `Authorization: Basic ...` carries.
const AUTH_SCHEME_BASIC = "basic";

# The credential scheme `Authorization: Bearer ...` carries.
const AUTH_SCHEME_BEARER = "bearer";

# Why a request was not admitted.
type AuthFailure record {|
    # True when the caller was identified but lacks a required scope (a 403);
    # false when it was not identified at all (a 401)
    boolean forbidden;
    # For a 403, the scopes the entry that identified the caller requires, any
    # one of which would have admitted it
    string[] requiredScopes = [];
|};

# One configured way of authenticating a request, and the `ballerina/http`
# handler that checks it.
isolated class AuthEntry {
    private final string scheme;
    private final (string|string[])? & readonly scopes;
    private final http:ListenerJwtAuthHandler? jwtHandler;
    private final http:ListenerOAuth2Handler? oauth2Handler;
    private final http:ListenerFileUserStoreBasicAuthHandler? fileHandler;
    private final http:ListenerLdapUserStoreBasicAuthHandler? ldapHandler;
    // The entry after this one. A chain rather than an array because a list of
    // handler objects cannot be held by an isolated class, and a single
    // isolated object can.
    private final AuthEntry? next;

    # + configs - `HttpListenerConfiguration.auth`
    # + index - The position of the entry this one is built from; it builds
    #           the rest of the chain behind it
    # + return - An `a2a:InternalError` naming the entry, if its handler could
    #            not be initialised
    isolated function init(http:ListenerAuthConfig[] & readonly configs, int index = 0) returns Error? {
        http:ListenerAuthConfig config = configs[index];
        http:ListenerJwtAuthHandler? jwtHandler = ();
        http:ListenerOAuth2Handler? oauth2Handler = ();
        http:ListenerFileUserStoreBasicAuthHandler? fileHandler = ();
        http:ListenerLdapUserStoreBasicAuthHandler? ldapHandler = ();
        string scheme;
        // Each handler is built under `trap`: these constructors have no error
        // return, and some reach out while being built -- `ballerina/jwt` preloads
        // the JWKS when `jwksConfig.cacheConfig` is set, `ballerina/auth` connects
        // to the LDAP server -- and panic when that fails. A listener that cannot
        // reach its identity provider at start-up returns an error like any other
        // bad configuration, instead of ending the process.
        if config is http:JwtValidatorConfigWithScopes {
            http:ListenerJwtAuthHandler|error created = trap new (config.jwtValidatorConfig.cloneReadOnly());
            if created is error {
                return authEntryFailure(index, "jwtValidatorConfig", created);
            }
            jwtHandler = created;
            scheme = AUTH_SCHEME_BEARER;
        } else if config is http:OAuth2IntrospectionConfigWithScopes {
            http:ListenerOAuth2Handler|error created = trap new (config.oauth2IntrospectionConfig.cloneReadOnly());
            if created is error {
                return authEntryFailure(index, "oauth2IntrospectionConfig", created);
            }
            oauth2Handler = created;
            scheme = AUTH_SCHEME_BEARER;
        } else if config is http:FileUserStoreConfigWithScopes {
            http:ListenerFileUserStoreBasicAuthHandler|error created = trap new (config.fileUserStoreConfig.cloneReadOnly());
            if created is error {
                return authEntryFailure(index, "fileUserStoreConfig", created);
            }
            fileHandler = created;
            scheme = AUTH_SCHEME_BASIC;
        } else {
            http:ListenerLdapUserStoreBasicAuthHandler|error created = trap new (config.ldapUserStoreConfig.cloneReadOnly());
            if created is error {
                return authEntryFailure(index, "ldapUserStoreConfig", created);
            }
            ldapHandler = created;
            scheme = AUTH_SCHEME_BASIC;
        }
        AuthEntry? next = ();
        if index + 1 < configs.length() {
            next = check new AuthEntry(configs, index + 1);
        }
        self.next = next;
        self.scheme = scheme;
        self.scopes = config?.scopes.cloneReadOnly();
        self.jwtHandler = jwtHandler;
        self.oauth2Handler = oauth2Handler;
        self.fileHandler = fileHandler;
        self.ldapHandler = ldapHandler;
    }

    # Tries this entry and then the rest of the chain.
    #
    # + scheme - The request's credential scheme, lower-cased
    # + header - The full `Authorization` header value
    # + return - The caller's identity, or why no entry admitted it
    isolated function authenticateChain(string scheme, string header) returns string|AuthFailure {
        if self.scheme == scheme {
            string|http:Unauthorized|http:Forbidden result = self.verify(header);
            if result is string {
                return result;
            }
            // Identified but lacking a scope: no other entry will do better,
            // so say so rather than fall through to a 401.
            if result is http:Forbidden {
                return {forbidden: true, requiredScopes: self.requiredScopes()};
            }
        }
        AuthEntry? next = self.next;
        return next is AuthEntry ? next.authenticateChain(scheme, header) : {forbidden: false};
    }

    # The scopes this entry requires, as a list.
    #
    # + return - The configured scopes; empty when the entry requires none
    isolated function requiredScopes() returns string[] {
        (string|string[])? scopes = self.scopes;
        if scopes is string {
            return [scopes];
        }
        return scopes is string[] ? scopes.clone() : [];
    }

    # Checks one `Authorization` header value against this entry.
    #
    # + header - The full header value
    # + return - The caller's identity, `http:Unauthorized` if the credential
    #            is not valid, or `http:Forbidden` if it is valid but lacks
    #            a required scope
    isolated function verify(string header) returns string|http:Unauthorized|http:Forbidden {
        (string|string[])? scopes = self.scopes;

        http:ListenerJwtAuthHandler? jwtHandler = self.jwtHandler;
        if jwtHandler is http:ListenerJwtAuthHandler {
            jwt:Payload|http:Unauthorized authn = jwtHandler.authenticate(header);
            if authn is http:Unauthorized {
                return authn;
            }
            // `jwt:Payload` is an open record, so the check above does not
            // narrow it away from `http:Unauthorized`.
            jwt:Payload payload = <jwt:Payload>authn;
            if scopes is string|string[] {
                http:Forbidden? denied = jwtHandler.authorize(payload, scopes);
                if denied is http:Forbidden {
                    return denied;
                }
            }
            return identityOrUnauthorized(payload.sub, payload["username"]);
        }

        http:ListenerOAuth2Handler? oauth2Handler = self.oauth2Handler;
        if oauth2Handler is http:ListenerOAuth2Handler {
            oauth2:IntrospectionResponse|http:Unauthorized|http:Forbidden result =
                    oauth2Handler->authorize(header, scopes);
            if result is http:Unauthorized|http:Forbidden {
                return result;
            }
            oauth2:IntrospectionResponse introspected = <oauth2:IntrospectionResponse>result;
            return identityOrUnauthorized(introspected?.sub, introspected?.username);
        }

        http:ListenerFileUserStoreBasicAuthHandler? fileHandler = self.fileHandler;
        if fileHandler is http:ListenerFileUserStoreBasicAuthHandler {
            auth:UserDetails|http:Unauthorized authn = fileHandler.authenticate(header);
            if authn is http:Unauthorized {
                return authn;
            }
            if scopes is string|string[] {
                http:Forbidden? denied = fileHandler.authorize(authn, scopes);
                if denied is http:Forbidden {
                    return denied;
                }
            }
            return identityOrUnauthorized(authn.username);
        }

        http:ListenerLdapUserStoreBasicAuthHandler? ldapHandler = self.ldapHandler;
        if ldapHandler is http:ListenerLdapUserStoreBasicAuthHandler {
            auth:UserDetails|http:Unauthorized authn = ldapHandler->authenticate(header);
            if authn is http:Unauthorized {
                return authn;
            }
            if scopes is string|string[] {
                http:Forbidden? denied = ldapHandler->authorize(authn, scopes);
                if denied is http:Forbidden {
                    return denied;
                }
            }
            return identityOrUnauthorized(authn.username);
        }
        return <http:Unauthorized>{};
    }
}

# Picks the first usable identity claim.
#
# A credential that validates but names no one cannot scope tasks to a caller
# ([specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping)),
# so it is treated as not authenticated rather than admitted anonymously.
#
# + candidates - The claims to try, in order
# + return - The first non-empty string, or `http:Unauthorized` if none is
isolated function identityOrUnauthorized(anydata... candidates) returns string|http:Unauthorized {
    foreach anydata candidate in candidates {
        if candidate is string && candidate != "" {
            return candidate;
        }
    }
    return {};
}

# Authenticates inbound requests against the configured `auth` entries.
#
# Entries are alternatives, as in `@http:ServiceConfig`: a request is admitted
# when any entry accepts it.
isolated class ListenerAuthenticator {
    private final AuthEntry first;
    private final string[] & readonly challenges;

    # + configs - `HttpListenerConfiguration.auth`, non-empty
    # + return - An `a2a:InternalError` if an entry's handler could not be initialised
    isolated function init(http:ListenerAuthConfig[] & readonly configs) returns Error? {
        string[] challenges = [];
        foreach http:ListenerAuthConfig config in configs {
            string challenge = config is http:JwtValidatorConfigWithScopes|http:OAuth2IntrospectionConfigWithScopes
                ? "Bearer" : "Basic realm=\"a2a\"";
            if challenges.indexOf(challenge) is () {
                challenges.push(challenge);
            }
        }
        self.challenges = challenges.cloneReadOnly();
        self.first = check new (configs);
    }

    # The `WWW-Authenticate` challenges to send with a 401, one per accepted
    # scheme ([specification section 7.4](https://a2a-protocol.org/latest/specification/#74-server-authentication-responsibilities)
    # asks for challenge information).
    #
    # + return - The challenge header values
    isolated function challengeHeaders() returns string[] {
        return self.challenges;
    }

    # Authenticates one request by its credential.
    #
    # Takes the credential, not the request, so any binding that can produce an
    # `Authorization` value -- an HTTP header, gRPC metadata -- authenticates
    # through the same chain.
    #
    # + authorizationHeader - The request's `Authorization` value, or `()` if it
    #                         carried none
    # + return - The caller's identity, or why it was not admitted
    isolated function authenticate(string? authorizationHeader) returns string|AuthFailure {
        // Without a credential there is nothing to check, and the handlers log
        // an error when asked to look for one that is not there.
        if authorizationHeader is () {
            return {forbidden: false};
        }
        return self.first.authenticateChain(schemeOf(authorizationHeader), authorizationHeader);
    }
}

# The lower-cased credential scheme of an `Authorization` header value.
#
# + header - The full header value
# + return - The scheme, e.g. `bearer`
isolated function schemeOf(string header) returns string {
    int? space = header.indexOf(" ");
    return (space is int ? header.substring(0, space) : header).toLowerAscii();
}

# The scheme name a derived card uses for Bearer credentials.
const DERIVED_BEARER_SCHEME = "bearerAuth";

# The scheme name a derived card uses for Basic credentials.
const DERIVED_BASIC_SCHEME = "basicAuth";

# Fills in a card's security declaration from the `auth` entries that enforce it.
#
# [Specification section 7.3](https://a2a-protocol.org/latest/specification/#73-client-authentication-process)
# has a client learn what to send from the card's `securitySchemes`, and
# section 13.3 has the server authenticate with "one of the schemes declared
# in the public `AgentCard.securitySchemes`". Left to the developer, the card
# and `auth` describe the same thing twice and nothing keeps them in step.
#
# Only a card that declares neither `securitySchemes` nor `securityRequirements`
# is touched: a developer who wrote either knows something this cannot -- the
# identity provider's URLs for an `oauth2` or `openIdConnect` scheme, or a
# scheme enforced by something in front of the listener -- and their
# declaration stands.
#
# What is derived is what the handlers read off the wire: JWT and OAuth2
# introspection entries accept `Authorization: Bearer ...`, file and LDAP
# entries accept `Authorization: Basic ...`. Entries are alternatives, so each
# becomes its own requirement (an OR), carrying that entry's scopes.
#
# + card - The card the developer supplied
# + auth - `HttpListenerConfiguration.auth`
# + return - The card, with `securitySchemes` and `securityRequirements` derived
#            when they were not declared and `auth` is set; otherwise unchanged
isolated function withDerivedSecurity(AgentCard card, http:ListenerAuthConfig[]? auth) returns AgentCard {
    if auth is () || card.securitySchemes is map<SecurityScheme> || card.securityRequirements is SecurityRequirement[] {
        return card;
    }
    boolean bearerIsAlwaysJwt = true;
    foreach http:ListenerAuthConfig entry in auth {
        if entry is http:OAuth2IntrospectionConfigWithScopes {
            bearerIsAlwaysJwt = false;
        }
    }

    map<SecurityScheme> schemes = {};
    SecurityRequirement[] requirements = [];
    foreach http:ListenerAuthConfig entry in auth {
        boolean bearer = entry is http:JwtValidatorConfigWithScopes|http:OAuth2IntrospectionConfigWithScopes;
        string name = bearer ? DERIVED_BEARER_SCHEME : DERIVED_BASIC_SCHEME;
        if !schemes.hasKey(name) {
            HttpAuthSecurityScheme scheme = bearer
                ? {scheme: "Bearer", bearerFormat: bearerIsAlwaysJwt ? "JWT" : ()}
                : {scheme: "Basic"};
            schemes[name] = scheme;
        }
        (string|string[])? configured = entry?.scopes;
        string[] scopes = [];
        if configured is string {
            scopes.push(configured);
        } else if configured is string[] {
            scopes.push(...configured);
        }
        SecurityRequirement requirement = {[name]: scopes.clone()};
        if requirements.indexOf(requirement) is () {
            requirements.push(requirement);
        }
    }

    // A mutable top level even when `card` is readonly (see `deriveServedCard`).
    AgentCard derived = {...card.clone()};
    derived.securitySchemes = schemes;
    derived.securityRequirements = requirements;
    return derived;
}

# The error for an `auth` entry whose handler could not be initialised.
#
# + index - The entry's position in `HttpListenerConfiguration.auth`
# + kind - The field of the entry that configures its handler
# + cause - What the handler's constructor panicked or returned with
# + return - An `a2a:InternalError` naming the entry, with the cause's message
isolated function authEntryFailure(int index, string kind, error cause) returns Error {
    string msg = string `HttpListenerConfiguration.auth[${index}] (${kind}) could not be initialised: ${cause.message()}`;
    return error InternalError(msg, message = msg);
}
