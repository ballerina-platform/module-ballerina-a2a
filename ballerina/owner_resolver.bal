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

// Server-side identity resolution, for task-visibility scoping. Mirrors
// auth.bal's CredentialProvider in shape -- a pluggable, single-method
// isolated object -- for the server's own equivalent need:
// [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping) requires that "clients can only access authorized tasks,"
// but the specification defines no mechanism for establishing who a caller
// is. That is deployment policy, not protocol, so this library surfaces a
// hook rather than inventing an authentication scheme.
//
// The resolver sees a `CallerContext`, never a transport's own request type:
// whichever binding received the call builds the context from its native
// request, so one resolver serves every binding unchanged.

# Who is calling, independent of the transport that delivered the call.
#
# Built once per inbound request by the binding that received it, after
# authentication and tenant routing, and handed to `a2a:TaskOwnerResolver`.
public type CallerContext record {|
    # The identity inbound authentication already established (a JWT's `sub`,
    # the introspected `sub` or `username`, or the Basic username); unset
    # when no `auth` is configured. Prefer this over re-deriving an identity
    # from `headers`: it is the verified one.
    string identity?;
    # The tenant segment the request was routed under, if any
    string tenant?;
    # The request headers, with every name lower-cased, each mapped to all of
    # its values
    map<string[]> headers;
    # The base64-encoded certificate the client presented, when a mutual TLS
    # handshake passed; unset otherwise
    string clientCertificateBase64?;
|};

# Resolves the caller of an inbound request to an opaque owner scope, for
# task-visibility scoping.
#
# `()` is a legitimate scope, not "unscoped" or "trusted": every caller a
# configured resolver maps to `()` shares one pool, isolated from every
# other scope, same as any other value. Leaving `a2a:DefaultHandlerConfiguration`'s
# `ownerResolver` entirely unset is different from a resolver that always
# returns `()` only in that the former matches this server's behavior before
# this feature existed -- every task in one shared, unscoped pool.
#
# Implement this against whatever identifies a caller in your deployment — the
# authenticated `identity`, an mTLS certificate's principal, an API key header
# looked up against a directory. This resolves identity; it does not
# authenticate it. A resolver that trusts an unverified header is not a
# security boundary, and satisfying [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping) requires
# pairing this with real inbound authentication: configure
# `HttpListenerConfiguration.auth`, which also makes the authenticated identity the
# owner when no resolver is given.
public type TaskOwnerResolver isolated object {

    # Resolves the request's caller to an owner scope.
    #
    # + context - Who is calling, as the receiving binding established it
    # + return - The caller's owner scope, `()` if the request carries no
    #            resolvable identity, or an error if resolution itself failed
    #            (a malformed token, an unreachable directory) — distinct
    #            from a legitimately anonymous `()` result
    public isolated function resolveOwner(CallerContext context) returns string?|Error;
};
