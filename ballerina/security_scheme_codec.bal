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

// v1.0 SecurityScheme wire-form parsing helpers, split out of
// types.bal (which should hold type definitions, not functions).

# Every JSON key that can introduce a v1.0 `SecurityScheme` oneof arm.
#
# A2A v1.0 models SecurityScheme as a protobuf `oneof` (see `proto/a2a.proto`),
# so the wire form is a single wrapper key — `{"apiKeySecurityScheme": {...}}` —
# not the v0.3/OpenAPI `type` discriminator this module's SecurityScheme union
# is shaped around. The spec's own JSON schema for SecurityScheme accepts each
# arm under two spellings: a lowerCamelCase one (its `properties`) and a
# snake_case one (its `patternProperties`), so both are recognized here.
final readonly & string[] V10_SECURITY_SCHEME_ARM_KEYS = [
    "apiKeySecurityScheme",
    "api_key_security_scheme",
    "httpAuthSecurityScheme",
    "http_auth_security_scheme",
    "oauth2SecurityScheme",
    "oauth2_security_scheme",
    "openIdConnectSecurityScheme",
    "open_id_connect_security_scheme",
    "mtlsSecurityScheme",
    "mtls_security_scheme"
];

# Counts how many v1.0 oneof arm keys an entry sets.
#
# SecurityScheme is a specification `oneof`, so a conformant entry sets
# exactly one. Counting rather than answering "any?" is what stops an entry
# with two recognised arms being silently resolved to whichever the arm list
# happens to name first -- the same rule `countSetPartVariantsJson` applies to
# `Part`.
#
# + entry - A raw securitySchemes entry
# + return - How many recognised arm keys are present
isolated function countV10SecuritySchemeArms(map<json> entry) returns int {
    int count = 0;
    foreach string armKey in V10_SECURITY_SCHEME_ARM_KEYS {
        if entry.hasKey(armKey) {
            count += 1;
        }
    }
    return count;
}

# Returns one v1.0 oneof arm's payload as a mutable copy, looked up under
# either spelling the spec accepts for it.
#
# + entry - The raw securitySchemes entry
# + camelKey - The lowerCamelCase spelling, per the spec schema's `properties`
# + snakeKey - The snake_case spelling, per its `patternProperties`
# + return - The arm's payload, or () if this entry declares no such arm (or
#            declares it as something other than an object)
isolated function v10SecuritySchemeArm(map<json> entry, string camelKey, string snakeKey) returns map<json>? {
    json? value = entry[camelKey];
    if value is () {
        value = entry[snakeKey];
    }
    return value is map<json> ? value.clone() : ();
}

# Renames one field of a raw JSON object in place, where the v1.0 wire name
# differs from this module's record field name. A no-op when the source field
# is absent, and never overwrites an existing target field.
#
# + fields - The object to rewrite
# + wireName - The field name as it arrives on the wire
# + recordName - The field name this module's record declares
isolated function renameJsonField(map<json> fields, string wireName, string recordName) {
    if fields.hasKey(wireName) && !fields.hasKey(recordName) {
        fields[recordName] = fields.remove(wireName);
    }
}

# Converts one v1.0 oneof-wrapped securitySchemes entry into the equivalent
# typed SecurityScheme.
#
# Two kinds of field-name fixup are needed: `location` becomes `in`, a genuine
# rename between the v1.0 and OpenAPI spellings, and the three multi-word
# fields the specification also accepts in snake_case are normalized to
# camelCase. Every other name already matches, since protobuf JSON emits
# lowerCamelCase.
#
# The apiKey `location` value is compared case-insensitively, since a server
# generating it from a protobuf enum can emit casing other than the lowercase
# the proto documents.
#
# Known limitation: nested OAuth flow objects are not snake_case-normalized,
# so a card sending `{"authorization_code": ...}` inside `flows` leaves it in
# `OAuthFlows`' rest field rather than the typed one. This library never acts
# on OAuth2 flows itself, so this costs typing detail, not function.
#
# + entry - A raw securitySchemes entry already known to declare an arm
# + return - The typed SecurityScheme, or () if the arm's payload doesn't
#            match the shape that arm requires (the caller drops it)
isolated function unwrapV10SecurityScheme(map<json> entry) returns SecurityScheme? {
    map<json>? apiKey = v10SecuritySchemeArm(entry, "apiKeySecurityScheme", "api_key_security_scheme");
    if apiKey is map<json> {
        json? location = apiKey["location"];
        if location !is string {
            return;
        }
        string normalized = location.toLowerAscii();
        if normalized != "query" && normalized != "header" && normalized != "cookie" {
            return;
        }
        _ = apiKey.remove("location");
        apiKey["in"] = normalized;
        ApiKeySecurityScheme|error scheme = apiKey.cloneWithType(ApiKeySecurityScheme);
        return scheme is ApiKeySecurityScheme ? scheme : ();
    }

    map<json>? httpAuth = v10SecuritySchemeArm(entry, "httpAuthSecurityScheme", "http_auth_security_scheme");
    if httpAuth is map<json> {
        renameJsonField(httpAuth, "bearer_format", "bearerFormat");
        HttpAuthSecurityScheme|error scheme = httpAuth.cloneWithType(HttpAuthSecurityScheme);
        return scheme is HttpAuthSecurityScheme ? scheme : ();
    }

    map<json>? oauth2 = v10SecuritySchemeArm(entry, "oauth2SecurityScheme", "oauth2_security_scheme");
    if oauth2 is map<json> {
        renameJsonField(oauth2, "oauth2_metadata_url", "oauth2MetadataUrl");
        OAuth2SecurityScheme|error scheme = oauth2.cloneWithType(OAuth2SecurityScheme);
        return scheme is OAuth2SecurityScheme ? scheme : ();
    }

    map<json>? oidc = v10SecuritySchemeArm(entry, "openIdConnectSecurityScheme", "open_id_connect_security_scheme");
    if oidc is map<json> {
        renameJsonField(oidc, "open_id_connect_url", "openIdConnectUrl");
        OpenIdConnectSecurityScheme|error scheme = oidc.cloneWithType(OpenIdConnectSecurityScheme);
        return scheme is OpenIdConnectSecurityScheme ? scheme : ();
    }

    map<json>? mtls = v10SecuritySchemeArm(entry, "mtlsSecurityScheme", "mtls_security_scheme");
    if mtls is map<json> {
        MutualTlsSecurityScheme|error scheme = mtls.cloneWithType(MutualTlsSecurityScheme);
        return scheme is MutualTlsSecurityScheme ? scheme : ();
    }

    return;
}

# Parses each entry of a raw securitySchemes JSON object independently,
# silently omitting entries that don't match any known SecurityScheme
# variant (unrecognized `type`, or otherwise malformed) rather than
# failing the whole AgentCard parse. This keeps AgentCard parsing
# forward-compatible with scheme kinds a server might add in the future.
#
# A v1.0 card wraps each scheme in one of the five oneof arm keys; an entry
# carrying a `type` field instead clones into the union directly. The two are
# distinguished up front rather than by trying the union first, because
# `MutualTlsSecurityScheme` requires no fields and so matches any object
# without a `type` key — including every v1.0 wrapper.
#
# + raw - The raw JSON value of the AgentCard's `securitySchemes` field
# + return - A map containing only the entries that parsed successfully
isolated function parseSecuritySchemes(json raw) returns map<SecurityScheme>|error {
    map<json> rawMap = check raw.ensureType();
    map<SecurityScheme> result = {};
    foreach [string, json] [name, schemeJson] in rawMap.entries() {
        if schemeJson !is map<json> {
            continue;
        }
        int arms = countV10SecuritySchemeArms(schemeJson);
        if arms > 1 {
            // A oneof with two arms set is not a scheme this client can name.
            // Dropping it is the tolerant-parse contract: one bad entry must
            // not sink the whole card.
            continue;
        }
        if arms == 1 {
            SecurityScheme? unwrapped = unwrapV10SecurityScheme(schemeJson);
            if unwrapped is SecurityScheme {
                result[name] = unwrapped;
            }
            // A declared-but-malformed arm is dropped here, never retried
            // against the union below.
            continue;
        }
        // No arm at all. Only a `type` discriminator can identify the scheme
        // from here; without one, `cloneWithType` would match
        // MutualTlsSecurityScheme, which requires no fields and defaults its
        // own `type` -- so any unrecognised wrapper would be read as mutual
        // TLS.
        if schemeJson["type"] !is string {
            continue;
        }
        SecurityScheme|error scheme = schemeJson.cloneWithType(SecurityScheme);
        if scheme is SecurityScheme {
            result[name] = scheme;
        }
    }
    return result;
}

# Unwraps one v1.0 `{"schemes": {...}}` security requirement.
#
# A2A v1.0 models SecurityRequirement as a protobuf message with a single
# `schemes` map field, and each of that map's values is a `StringList`
# message rather than a bare array — so a real v1.0 agent serves
# `{"schemes": {"bearer-staff": {"list": ["write"]}}}`, and `{}` for an
# empty scope list, where v0.3/OpenAPI served `{"bearer-staff": ["write"]}`.
# This module's SecurityRequirement type is the flat v0.3-shaped
# `map<string[]>`, so the v1.0 form has to be flattened onto it.
#
# + entry - One raw securityRequirements array element, already known to
#           be an object carrying an object-valued `schemes` key
# + return - The flattened requirement, or () if any scheme's value isn't
#            a StringList-shaped object
isolated function unwrapV10SecurityRequirement(map<json> entry) returns SecurityRequirement? {
    map<json>|error schemes = entry["schemes"].ensureType();
    if schemes is error {
        return;
    }
    SecurityRequirement flattened = {};
    foreach [string, json] [schemeName, scopesJson] in schemes.entries() {
        map<json>|error stringList = scopesJson.ensureType();
        if stringList is error {
            return;
        }
        json? listJson = stringList["list"];
        if listJson is () {
            // An empty StringList serialises as `{}` — no scopes, which is
            // the common case for a bearer or API-key scheme.
            flattened[schemeName] = [];
            continue;
        }
        string[]|error scopes = listJson.cloneWithType();
        if scopes is error {
            return;
        }
        flattened[schemeName] = scopes;
    }
    return flattened;
}

# Whether a raw securityRequirements entry is in the v1.0 wrapper form.
#
# The discriminator is deliberately narrow: a v0.3 requirement could in
# principle name a scheme "schemes", but its value would then be a scope
# *array*, never an object. Only an object-valued `schemes` key means v1.0.
#
# + entry - One raw securityRequirements array element
# + return - True if this entry is the v1.0 wrapper form
isolated function hasV10SecurityRequirementWrapper(map<json> entry) returns boolean {
    return entry["schemes"] is map<json>;
}

# Parses a raw JSON array into a list of SecurityRequirement values,
# silently dropping any entry that matches neither wire form, so one
# malformed entry can't fail the whole AgentCard parse. Used for both
# AgentCard.securityRequirements and each AgentSkill's
# securityRequirements.
#
# Handles both dialects, mirroring parseSecuritySchemes above: v1.0 wraps
# the map in a `schemes` field and encodes scope lists as StringList
# objects (see unwrapV10SecurityRequirement); v0.3 uses the flat
# OpenAPI-style map this module's type is shaped around, which clones
# directly.
#
# + raw - The raw JSON value of a securityRequirements field
# + return - A list containing only the entries that parsed successfully
isolated function parseSecurityRequirements(json raw) returns SecurityRequirement[]|error {
    json[] rawArray = check raw.ensureType();
    SecurityRequirement[] result = [];
    foreach json entry in rawArray {
        if entry is map<json> && hasV10SecurityRequirementWrapper(entry) {
            SecurityRequirement? unwrapped = unwrapV10SecurityRequirement(entry);
            if unwrapped is SecurityRequirement {
                result.push(unwrapped);
            }
            // A declared-but-malformed wrapper is dropped here, never
            // retried against the flat form below — the same rule
            // parseSecuritySchemes applies to a malformed oneof arm.
            continue;
        }
        SecurityRequirement|error req = entry.cloneWithType(SecurityRequirement);
        if req is SecurityRequirement {
            result.push(req);
        }
    }
    return result;
}

# Parses the AgentCard's raw `signatures` array into typed
# `AgentCardSignature` values.
#
# A signature is a fixed shape with no wire dialects (unlike security
# schemes/requirements), so this is a direct structural conversion — a
# malformed entry fails the parse rather than being dropped. `cloneWithType`,
# not `ensureType`: the latter only casts, so it cannot turn a `json[]` into a
# typed `AgentCardSignature[]`.
#
# + raw - The raw JSON value of the AgentCard's `signatures` field
# + return - The parsed signatures, or an error if any entry does not match
#            the `AgentCardSignature` shape
isolated function parseAgentCardSignatures(json raw) returns AgentCardSignature[]|error {
    return raw.cloneWithType();
}

// The mirror direction: serving this listener's own AgentCard needs
// securityRequirements written back out in the v1.0 wire shape, since
// this module's own SecurityRequirement type is the flat v0.3 one
// parseSecurityRequirements normalizes onto (see its own doc above).
// `AgentCard.toJson()`/`AgentSkill.toJson()` have no way to know this --
// they convert a `map<string[]>` using default JSON conversion, which
// produces the flat shape, not the wrapped one.
//
// `securitySchemes` needs the same treatment, for the same reason: a
// `SecurityScheme` record carries a flat `type` discriminator, and plain
// `toJson` emits it as is, but the v1.0 wire form wraps each scheme in the
// one oneof arm it belongs to (`{"httpAuthSecurityScheme": {...}}`) and spells an
// API key's location `location`, not `in`. `wrapV10SecurityScheme` is the
// encode-direction mirror of `unwrapV10SecurityScheme`.

# Wraps one internal, flat `SecurityRequirement` into the v1.0 wire shape:
# `{"schemes": {name: {"list": [...]}}}`. The encode-direction mirror of
# `unwrapV10SecurityRequirement`.
#
# + requirement - The internal flat requirement
# + return - The v1.0-shaped wire object
isolated function wrapV10SecurityRequirement(SecurityRequirement requirement) returns json {
    map<json> schemes = {};
    foreach [string, string[]] [name, scopes] in requirement.entries() {
        schemes[name] = {list: scopes.clone()};
    }
    return {schemes};
}

# Wraps one `SecurityScheme` into its v1.0 wire shape: the scheme's own
# fields, minus the flat `type` discriminator, under the oneof arm key the
# specification's `SecurityScheme` message names for it.
#
# + scheme - The scheme to encode
# + return - The v1.0-shaped wire object, e.g. `{"httpAuthSecurityScheme": {...}}`
isolated function wrapV10SecurityScheme(SecurityScheme scheme) returns json {
    map<json>|error converted = scheme.toJson().ensureType();
    map<json> fields = converted is map<json> ? converted : {};
    _ = fields.removeIfHasKey("type");
    string arm;
    match scheme.'type {
        "apiKey" => {
            arm = "apiKeySecurityScheme";
            // OpenAPI spells it `in`; the proto field is `location`.
            renameJsonField(fields, "in", "location");
        }
        "http" => {
            arm = "httpAuthSecurityScheme";
        }
        "oauth2" => {
            arm = "oauth2SecurityScheme";
        }
        "openIdConnect" => {
            arm = "openIdConnectSecurityScheme";
        }
        _ => {
            arm = "mtlsSecurityScheme";
        }
    }
    return {[arm]: fields};
}

# Wraps a list of internal, flat `SecurityRequirement`s into the v1.0 wire
# array shape.
#
# + requirements - The internal flat requirements
# + return - The v1.0-shaped wire array
isolated function wrapV10SecurityRequirements(SecurityRequirement[] requirements) returns json[] {
    json[] result = [];
    foreach SecurityRequirement requirement in requirements {
        result.push(wrapV10SecurityRequirement(requirement));
    }
    return result;
}

# Encodes an `AgentCard` for the wire, rewriting its own `securitySchemes` and
# `securityRequirements` and each skill's requirements from `toJson`'s default (flat,
# v0.3-shaped) conversion into the v1.0 form every A2A v1.0 server actually
# serves. Every other field round-trips through plain `toJson` correctly
# already (see the note above `wrapV10SecurityRequirement`).
#
# + card - The card to serve
# + return - The card's wire JSON, with conformant `securitySchemes` and `securityRequirements`
isolated function encodeAgentCardForWire(AgentCard card) returns json {
    map<json>|error encoded = card.toJson().ensureType();
    if encoded is error {
        // AgentCard always converts to a JSON object; unreachable in
        // practice, but keeps this function total rather than one more
        // caller that has to `check` a JSON-object cast that cannot fail.
        return card.toJson();
    }

    SecurityRequirement[]? cardRequirements = card.securityRequirements;
    if cardRequirements is SecurityRequirement[] {
        encoded["securityRequirements"] = wrapV10SecurityRequirements(cardRequirements);
    }

    map<SecurityScheme>? schemes = card.securitySchemes;
    if schemes is map<SecurityScheme> {
        map<json> wrappedSchemes = {};
        foreach [string, SecurityScheme] [name, scheme] in schemes.entries() {
            wrappedSchemes[name] = wrapV10SecurityScheme(scheme);
        }
        encoded["securitySchemes"] = wrappedSchemes;
    }

    json[]|error skillsJson = encoded["skills"].ensureType();
    if skillsJson is json[] {
        foreach int i in 0 ..< skillsJson.length() {
            SecurityRequirement[]? skillRequirements =
                i < card.skills.length() ? card.skills[i].securityRequirements : ();
            if skillRequirements is SecurityRequirement[] {
                map<json>|error skillMap = skillsJson[i].ensureType();
                if skillMap is map<json> {
                    skillMap["securityRequirements"] = wrapV10SecurityRequirements(skillRequirements);
                    skillsJson[i] = skillMap;
                }
            }
        }
        encoded["skills"] = skillsJson;
    }

    return encoded;
}
