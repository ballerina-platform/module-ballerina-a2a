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

// Delivers task updates to registered push-notification webhooks. Mirrors
// owner_resolver.bal's shape -- a pluggable, single-method isolated object
// -- but unlike TaskOwnerResolver (which needs an identity source this
// library cannot invent), delivery has one sensible universal default: POST
// to the registered URL. That default is HttpPushNotificationSender, below.

import ballerina/http;

# Delivers one task update to one registered webhook.
#
# `a2a:DefaultHandler` calls this once per registered
# `a2a:TaskPushNotificationConfig` whenever a task it drives reaches a new
# state -- fire-and-forget: a delivery failure is not surfaced as the
# triggering operation's own error, matching every reference SDK's posture.
# Implement this to change delivery semantics entirely (a queue, a
# different retry policy, a non-HTTP transport); to only change how a
# webhook URL is validated or how the request is built, configure
# `a2a:HttpPushNotificationSender` instead of replacing it.
public type PushNotificationSender isolated object {

    # Delivers one update.
    #
    # + config - The webhook to call, including its `token` and
    #            `authentication`, if set
    # + task - The task's state at the moment of this call
    # + return - An `a2a:Error` if delivery failed; callers are expected to
    #            log and continue, not fail the operation that triggered it
    public isolated function send(TaskPushNotificationConfig config, Task task) returns Error?;
};

# Configuration for `a2a:HttpPushNotificationSender`.
public type PushNotificationSenderConfiguration record {|
    # Per-request timeout, in seconds
    decimal timeout = 10;
    # Whether to reject a webhook URL resolving to a loopback, link-local,
    # or private address before sending -- specification section 13.2's
    # SSRF-protection obligation. On by default, matching the reference
    # Java and Go SDKs over Python's opt-in stance; turn off for a
    # deployment whose webhooks legitimately live on a private network.
    boolean validateUrl = true;
    # How a failed delivery is retried: [specification section 13.2](https://a2a-protocol.org/latest/specification/#132-push-notification-security)
    # says agents SHOULD retry "with exponential backoff". By default a
    # connection failure, or a `408`, `429`, or `5xx` gateway answer, is
    # retried three times, 1, 2 and then 4 seconds apart. Any other non-2xx
    # answer is not retried. `()` sends each update once.
    http:RetryConfig? retryConfig = {
        count: 3,
        interval: 1,
        backOffFactor: 2.0,
        maxWaitInterval: 10,
        statusCodes: [408, 429, 500, 502, 503, 504]
    };
|};

# The default `a2a:PushNotificationSender`: an HTTP POST of the task to the
# registered URL.
#
# The body is a `StreamResponse`, as [specification section 4.3.3](https://a2a-protocol.org/latest/specification/#433-push-notification-payload)
# requires -- the task under its `task` key, `{"task": {...}}`, exactly the
# shape a streaming client receives -- so a receiver can tell a task from a
# status or artifact update by the key alone. The media type is
# `application/a2a+json`.
public isolated class HttpPushNotificationSender {
    *PushNotificationSender;

    private final decimal timeout;
    private final boolean validateUrl;
    private final http:RetryConfig? & readonly retryConfig;

    # + config - Delivery configuration
    public isolated function init(*PushNotificationSenderConfiguration config) {
        self.timeout = config.timeout;
        self.validateUrl = config.validateUrl;
        self.retryConfig = config.retryConfig.cloneReadOnly();
    }

    # + config - The webhook to call
    # + task - The task's state at the moment of this call
    # + return - An `a2a:Error` if delivery failed
    public isolated function send(TaskPushNotificationConfig config, Task task) returns Error? {
        if self.validateUrl {
            check validateWebhookUrl(config.url);
        }

        // HTTP/1.1 forced, not left to negotiate: a webhook receiver is a
        // third party this server does not control, and a server that
        // advertises HTTPS without genuinely supporting HTTP/2 fails
        // negotiation with a generic, undiagnosable connection error --
        // hit directly against a real endpoint earlier in this module's
        // development. A receiver expecting HTTP/2 still speaks HTTP/1.1.
        http:Client|error webhook = new (config.url, httpVersion = http:HTTP_1_1, timeout = self.timeout,
            retryConfig = self.retryConfig
        );
        if webhook is error {
            return wrapTransportError(webhook);
        }

        // The wire envelope, not a bare `task.toJson()`: it is the same
        // StreamResponse shape a live stream carries, and it base64-encodes
        // file bytes the way the rest of the wire does, which `toJson()` on a
        // `byte[]` does not.
        json|error body = wireEnvelopeFor(task);
        if body is error {
            return wrapTransportError(body);
        }

        map<string> headers = {"Content-Type": CONTENT_TYPE_A2A_JSON};
        string? token = config?.token;
        if token is string {
            headers["X-A2A-Notification-Token"] = token;
        }
        AuthenticationInfo? auth = config?.authentication;
        if auth is AuthenticationInfo {
            string? credentials = auth?.credentials;
            if credentials is string {
                headers["Authorization"] = string `${auth.scheme} ${credentials}`;
            }
        }

        http:Response|error result = webhook->post("", body, headers);
        if result is error {
            return wrapTransportError(result);
        }
        // An `http:Response` target hands back every status, so a webhook that
        // answered 4xx or 5xx (after any retries) would otherwise count as
        // delivered. Section 13.2 has the receiver acknowledge with a 2xx.
        if result.statusCode < 200 || result.statusCode > 299 {
            string msg = string `push-notification webhook answered HTTP ${result.statusCode}`;
            return error InternalError(msg, message = msg);
        }
    }
}

# Rejects a webhook URL by form, per specification section 13.2's
# SSRF-protection obligation -- checked at send time against
# `HttpPushNotificationSender.validateUrl`, not at registration, matching
# the fire-and-forget delivery model: a caller registering a disallowed
# URL still gets a stored config back; the rejection surfaces the same way
# an unreachable webhook does, as a swallowed delivery failure.
#
# Form-level only, deliberately: Ballerina has no stdlib DNS resolver
# (`ballerina/socket` no longer exists; `tcp`/`udp` never hand back a
# resolved address), and this package carries no native Java code by its
# own build convention, so resolving a hostname to an IP is not available
# without a dependency this package does not otherwise need. A host that is
# not itself an IP literal -- `webhook.internal.corp` resolving to a
# private address, for instance -- is not caught here; that DNS-rebinding
# gap is real and left open, the same gap the reference Java SDK's own
# documentation concedes for the same reason.
#
# + url - The webhook URL to check
# + return - An `a2a:Error` if the URL's scheme or host is disallowed
isolated function validateWebhookUrl(string url) returns Error? {
    int? schemeEnd = url.indexOf("://");
    if schemeEnd is () {
        return invalidWebhookUrl(url, "missing a scheme");
    }
    string scheme = url.substring(0, schemeEnd);
    if scheme != "http" && scheme != "https" {
        return invalidWebhookUrl(url, string `scheme "${scheme}" is not http or https`);
    }

    string rest = url.substring(schemeEnd + 3);
    int authorityEnd = rest.length();
    foreach string delimiter in ["/", "?", "#"] {
        int? idx = rest.indexOf(delimiter);
        if idx is int && idx < authorityEnd {
            authorityEnd = idx;
        }
    }
    string authority = rest.substring(0, authorityEnd);

    int? atIdx = authority.lastIndexOf("@");
    string hostPort = atIdx is int ? authority.substring(atIdx + 1) : authority;

    string host;
    if hostPort.startsWith("[") {
        // An IPv6 literal, e.g. "[::1]:8080" -- the brackets disambiguate
        // its embedded colons from a port separator.
        int? closeBracket = hostPort.indexOf("]");
        host = closeBracket is int ? hostPort.substring(1, closeBracket) : hostPort;
    } else {
        int? colonIdx = hostPort.lastIndexOf(":");
        host = colonIdx is int ? hostPort.substring(0, colonIdx) : hostPort;
    }
    // A trailing dot (e.g. "localhost.") is a legal, fully-qualified form of
    // the same name -- the root label is just empty -- so it must compare
    // equal to the un-dotted form, not slip past every check below because
    // none of them account for it.
    string lowerHost = host.toLowerAscii();
    if lowerHost.endsWith(".") {
        lowerHost = lowerHost.substring(0, lowerHost.length() - 1);
    }

    if lowerHost == "localhost" || lowerHost.endsWith(".localhost") || lowerHost.endsWith(".local")
            || lowerHost == "metadata.google.internal" {
        return invalidWebhookUrl(url, string `host "${host}" is disallowed`);
    }
    if isDisallowedIpLiteral(lowerHost) {
        return invalidWebhookUrl(url, string `host "${host}" is a disallowed IP address`);
    }
}

# Whether a host, already known to be an IP literal or plain hostname,
# names a loopback, link-local (which covers the
# `169.254.169.254`-style cloud metadata endpoint), private (RFC 1918),
# carrier-grade-NAT (`100.64.0.0/10`), or IPv6 unique-local/loopback/
# link-local address.
#
# + host - The lowercased host, brackets and port already stripped
# + return - Whether the host is a disallowed IP literal
isolated function isDisallowedIpLiteral(string host) returns boolean {
    // The numbers-and-dots form (parseIPv4Numeric), not the strict
    // dotted-quad-only parseIPv4: a real HTTP client's DNS/IP resolution
    // (confirmed against java.net.InetAddress.getByName, what a JVM-based
    // client resolves a host through) accepts short forms too --
    // "127.1" and "10.1" (the last part covering the remaining two/three
    // octets), a single 32-bit decimal ("2130706433" is 127.0.0.1), and
    // "169.254.43518" (the cloud metadata address, its last two octets
    // folded into one 16-bit number: 169*256+254 = 43518). A strict
    // 4-octet-only check lets all of these connect while believing it had
    // blocked the same address written the usual way.
    int[]? v4 = parseIPv4Numeric(host);
    if v4 is int[] {
        return isDisallowedIPv4Octets(v4);
    }
    int[]? hextets = parseIPv6Hextets(host);
    if hextets is () {
        // Not a valid literal of either family -- a plain hostname, which
        // this function's caller has already screened for the specific
        // disallowed *names* it checks by string (localhost, .local,
        // metadata.google.internal); nothing further to check here. Before
        // this fix, an IPv6-only check ran against every such hostname too,
        // so any name starting "fc"/"fd" (e.g. fdic.gov) was wrongly refused.
        return false;
    }
    // An IPv4-mapped IPv6 address (::ffff:0:0/96, RFC 4291 §2.5.5.2): the low
    // 32 bits are an IPv4 address, written either as a trailing dotted quad
    // (::ffff:127.0.0.1) or as two hex hextets (::ffff:a9fe:a9fe, the same
    // 169.254.169.254 cloud metadata address) -- both already normalized to
    // the same 8-hextet form by parseIPv6Hextets. Classify the embedded IPv4
    // address by the IPv4 rules, the same way a plain request to it would be.
    if hextets[0] == 0 && hextets[1] == 0 && hextets[2] == 0 && hextets[3] == 0
            && hextets[4] == 0 && hextets[5] == 0xffff {
        int[] mapped = [hextets[6] >> 8, hextets[6] & 0xff, hextets[7] >> 8, hextets[7] & 0xff];
        return isDisallowedIPv4Octets(mapped);
    }
    // Loopback (::1) and unspecified (::), any way they were written --
    // parseIPv6Hextets already normalizes 0:0:0:0:0:0:0:1 to the same array
    // as ::1, so a single all-zero-but-last-hextet check covers both forms.
    boolean allZeroButLast = true;
    foreach int i in 0 ..< 7 {
        if hextets[i] != 0 {
            allZeroButLast = false;
            break;
        }
    }
    if allZeroButLast {
        return true; // ::1 (hextets[7] == 1) or :: (hextets[7] == 0)
    }
    // Link-local, fe80::/10: the top 10 bits of the first hextet are
    // 1111111010, i.e. the first hextet is in 0xfe80-0xfebf.
    if hextets[0] >= 0xfe80 && hextets[0] <= 0xfebf {
        return true;
    }
    // Unique-local, fc00::/7: the first hextet's top byte is 0xfc or 0xfd.
    int topByte = hextets[0] >> 8;
    return topByte == 0xfc || topByte == 0xfd;
}

# + octets - Four IPv4 octets
# + return - Whether they name a loopback, unspecified, private (RFC 1918),
#            link-local (which covers `169.254.169.254`), or
#            carrier-grade-NAT (`100.64.0.0/10`) address
isolated function isDisallowedIPv4Octets(int[] octets) returns boolean {
    int a = octets[0];
    int b = octets[1];
    return a == 127 || a == 0 || a == 10 || (a == 172 && b >= 16 && b <= 31)
        || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127);
}

# Expands an IPv6 literal (brackets and port already stripped by the caller)
# into its eight 16-bit hextets, handling `::` compression and a trailing
# IPv4-mapped tail (`::ffff:127.0.0.1`), so `isDisallowedIpLiteral` can
# classify an address the same way regardless of how it was written --
# `::1` and `0:0:0:0:0:0:0:1` expand to the same array.
#
# + host - The candidate host string
# + return - The eight hextets, or `()` if `host` is not a valid IPv6
#            literal -- including any plain hostname, which is exactly the
#            case this function's caller uses `()` to mean "not this family,
#            nothing more to check here"
isolated function parseIPv6Hextets(string host) returns int[]? {
    if !host.includes(":") {
        return;
    }
    int? compressionAt = host.indexOf("::");
    string left;
    string right;
    boolean compressed;
    if compressionAt is int {
        if host.indexOf("::", compressionAt + 1) is int {
            return; // a second "::" is never legal
        }
        left = host.substring(0, compressionAt);
        right = host.substring(compressionAt + 2);
        compressed = true;
    } else {
        left = host;
        right = "";
        compressed = false;
    }
    string[] leftGroups = left == "" ? [] : splitOnColon(left);
    string[] rightGroups = right == "" ? [] : splitOnColon(right);

    // A trailing IPv4 dotted quad, if present, is only ever the address's
    // very last group -- whichever of the two halves is the last one.
    string[] tailGroups = compressed ? rightGroups : leftGroups;
    int[]? v4Tail = ();
    if tailGroups.length() > 0 && tailGroups[tailGroups.length() - 1].includes(".") {
        v4Tail = parseIPv4(tailGroups[tailGroups.length() - 1]);
        if v4Tail is () {
            return; // looked like a v4 tail but wasn't a valid one
        }
        tailGroups = tailGroups.slice(0, tailGroups.length() - 1);
        if compressed {
            rightGroups = tailGroups;
        } else {
            leftGroups = tailGroups;
        }
    }

    int neededHexGroups = 8 - (v4Tail is int[] ? 2 : 0);
    int haveHexGroups = leftGroups.length() + rightGroups.length();
    if compressed {
        int missing = neededHexGroups - haveHexGroups;
        if missing < 0 {
            return; // more groups than fit -- malformed
        }
        int[] result = [];
        foreach string g in leftGroups {
            int? h = parseHextet(g);
            if h is () {
                return;
            }
            result.push(h);
        }
        foreach int _ in 0 ..< missing {
            result.push(0);
        }
        foreach string g in rightGroups {
            int? h = parseHextet(g);
            if h is () {
                return;
            }
            result.push(h);
        }
        if v4Tail is int[] {
            result.push((v4Tail[0] << 8) | v4Tail[1]);
            result.push((v4Tail[2] << 8) | v4Tail[3]);
        }
        return result;
    }
    // No "::": every group must be spelled out.
    if haveHexGroups != neededHexGroups {
        return;
    }
    int[] result = [];
    foreach string g in leftGroups {
        int? h = parseHextet(g);
        if h is () {
            return;
        }
        result.push(h);
    }
    if v4Tail is int[] {
        result.push((v4Tail[0] << 8) | v4Tail[1]);
        result.push((v4Tail[2] << 8) | v4Tail[3]);
    }
    return result;
}

# + group - A single ':'-delimited group from an IPv6 literal
# + return - Its value (0-0xffff), or `()` if it is not 1-4 hex digits
isolated function parseHextet(string group) returns int? {
    if group.length() == 0 || group.length() > 4 {
        return;
    }
    int|error n = int:fromHexString(group);
    if n is error || n < 0 || n > 0xffff {
        return;
    }
    return n;
}

# + s - A string with no leading/trailing/doubled colon (the caller has
#       already removed any `::` compression marker)
# + return - `s` split on every remaining single `:`
isolated function splitOnColon(string s) returns string[] {
    string[] parts = [];
    string remaining = s;
    while true {
        int? idx = remaining.indexOf(":");
        if idx is () {
            parts.push(remaining);
            break;
        }
        parts.push(remaining.substring(0, idx));
        remaining = remaining.substring(idx + 1);
    }
    return parts;
}

# Parses a dotted-quad IPv4 literal into its four octets, or `()` if `host`
# is not one -- including any plain hostname, which is exactly the case
# this function's caller uses `()` to mean "not an IP literal, nothing more
# to check here."
#
# + host - The candidate host string
# + return - The four octets, or `()` if `host` is not a valid IPv4 literal
isolated function parseIPv4(string host) returns int[]? {
    string[] parts = [];
    string remaining = host;
    while true {
        int? dotIdx = remaining.indexOf(".");
        if dotIdx is () {
            parts.push(remaining);
            break;
        }
        parts.push(remaining.substring(0, dotIdx));
        remaining = remaining.substring(dotIdx + 1);
    }
    if parts.length() != 4 {
        return;
    }
    int[] result = [];
    foreach string part in parts {
        if part.length() == 0 || part.length() > 3 {
            return;
        }
        int|error n = int:fromString(part);
        if n is error || n < 0 || n > 255 {
            return;
        }
        result.push(n);
    }
    return result;
}

# Parses an IPv4 literal in any of the numbers-and-dots forms a real
# resolver actually accepts, not just the four-octet dotted-quad form --
# see `isDisallowedIpLiteral`'s own comment for why this matters. 1-4
# dot-separated decimal parts; every part but the last is exactly one
# octet, and the last absorbs however many trailing octets the count
# leaves implicit (4 parts: none, it's an octet too; 3: the last 16 bits;
# 2: the last 24 bits; 1: the whole 32 bits) -- the classic `inet_aton`
# rule, confirmed against `java.net.InetAddress.getByName` (what a
# JVM-based HTTP client resolves a host through): "127.1" -> 127.0.0.1,
# "10.1" -> 10.0.0.1, "2130706433" -> 127.0.0.1, "169.254.43518" ->
# 169.254.169.254. Hex (`0x7f...`) and full octal (`017700000001`) forms
# are not accepted by that same resolver, so they need no handling here;
# a leading zero on a decimal part is decimal, not octal (`0177.0.0.1` ->
# 177.0.0.1), matching `int:fromString`'s own behaviour, relied on below
# instead of hand-rolling digit validation.
#
# + host - The candidate host string
# + return - The four octets, or `()` if `host` is not a valid literal in
#            any of these forms
isolated function parseIPv4Numeric(string host) returns int[]? {
    string[] parts = [];
    string remaining = host;
    while true {
        int? dotIdx = remaining.indexOf(".");
        if dotIdx is () {
            parts.push(remaining);
            break;
        }
        parts.push(remaining.substring(0, dotIdx));
        remaining = remaining.substring(dotIdx + 1);
    }
    if parts.length() == 0 || parts.length() > 4 {
        return;
    }
    int[] values = [];
    foreach string part in parts {
        if part.length() == 0 {
            return;
        }
        int|error n = int:fromString(part);
        if n is error || n < 0 {
            return;
        }
        values.push(n);
    }
    foreach int i in 0 ..< values.length() - 1 {
        if values[i] > 255 {
            return;
        }
    }
    int lastValue = values[values.length() - 1];
    // Whichever position the last part is in, it stands in for every octet
    // from there to the end -- 4 parts leaves it exactly one, same as every
    // other part.
    int trailingOctets = 4 - (values.length() - 1);
    int maxLast = trailingOctets == 1 ? 255 : trailingOctets == 2 ? 65535
        : trailingOctets == 3 ? 16777215 : 4294967295;
    if lastValue > maxLast {
        return;
    }
    int[] result = [];
    foreach int i in 0 ..< values.length() - 1 {
        result.push(values[i]);
    }
    foreach int i in 0 ..< trailingOctets {
        result.push((lastValue >> ((trailingOctets - 1 - i) * 8)) & 0xff);
    }
    return result;
}

# Builds the typed error for a rejected webhook URL.
#
# + url - The rejected URL
# + reason - Why it was rejected
# + return - The typed error
isolated function invalidWebhookUrl(string url, string reason) returns Error {
    string msg = string `push-notification webhook URL "${url}" is not allowed: ${reason}`;
    return error InternalError(msg, message = msg);
}
