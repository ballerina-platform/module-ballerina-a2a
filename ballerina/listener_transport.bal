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


// The HTTP half of an A2A listener, which `a2a:RestListener` and `a2a:JsonRpcListener` share: the HTTP listener, the
// authentication, the address the card advertises, stream timing, and the bookkeeping of what is attached. A binding
// brings only what differs: how operations are declared on a service, the dispatcher that serves them, and its default
// path. Keeping this in one place means a fix to the way a listener attaches, detaches or authenticates reaches both.

import ballerina/http;
import ballerina/log;

# Builds the HTTP service that serves one attached A2A service over a binding.
type DispatcherFactory isolated function (AgentCard served, OperationBinding binding, ServedCards cards,
        ListenerAuthenticator? authenticator, string interfaceScheme, string? publicUrl, StreamTiming streamTiming,
        string mountPath, boolean validateInputModes) returns http:Service;

# A service attached to a listener, with the dispatcher built for it.
type AttachedService record {|
    # The service, as the application declared it
    Service agentService;
    # The dispatcher built for it
    http:Service dispatcher;
    # The path it is mounted at
    string mountPath;
|};

isolated class ListenerTransport {
    private final http:Listener httpListener;
    private final (http:ListenerAuthConfig[] & readonly)? authConfig;
    private final ListenerAuthenticator? authenticator;
    private final StreamTiming & readonly streamTiming;
    // What the served card's interface URL is built from: the scheme this listener really serves, and the explicit
    // public URL if one was configured.
    private final string interfaceScheme;
    private final string? publicUrl;
    private final boolean validateInputModes;
    // What differs between the bindings
    private final string configName;
    private final string protocolBinding;
    private final string defaultMountPath;
    private final boolean byMethodName;
    private final DispatcherFactory newDispatcher;
    // One lock covers a service going on and off the listener, from the first step to the last, so a detach cannot
    // finish between an attach's card entry and its mount and leave the path mounted with nothing to remove it.
    private AttachedService[] attached = [];

    # + listenTo - The port, or an `http:Listener` to share
    # + config - The listener's configuration
    # + configName - The configuration record's name, for error messages
    # + protocolBinding - The binding the listener serves, such as `JSONRPC`
    # + defaultMountPath - The path a service declared without one is served at
    # + byMethodName - Whether the binding declares operations as remote functions rather than resources
    # + newDispatcher - Builds the dispatcher that serves a service over the binding
    # + return - An `a2a:Error` if the configuration is unusable or the HTTP listener cannot be made
    isolated function init(int|http:Listener listenTo, ListenerConfiguration config, string configName,
            string protocolBinding, string defaultMountPath, boolean byMethodName, DispatcherFactory newDispatcher)
            returns Error? {
        check checkStreamTiming(configName, config.streamIdleTimeout, config.keepAliveInterval);
        // A listener built on an `http:Listener` that an earlier A2A listener was built on takes that one's `auth`
        // and `publicUrl` when it sets none, so only a real conflict is an error.
        var inherited = inheritedSettings(listenTo, config.auth, config.publicUrl);
        http:ListenerAuthConfig[]? auth = inherited[0];
        string? publicUrl = inherited[1];
        ListenerAuthenticator? earlierAuthenticator = inherited[2];
        if publicUrl is string {
            self.publicUrl = check normalisePublicUrl(configName, publicUrl);
        } else {
            self.publicUrl = ();
        }
        // The auth handlers are built first, and their failure returned first: some of them reach the identity
        // provider while being built (a JWKS cache is preloaded, an LDAP server is connected to), so a listener that
        // cannot reach it must fail before anything is bound.
        if auth is http:ListenerAuthConfig[] {
            if auth.length() == 0 {
                string msg = string `${configName}.auth must contain at least one entry; `
                    + "leave it unset for no authentication";
                return error InternalError(msg, message = msg);
            }
            self.authConfig = auth.cloneReadOnly();
            // Two listeners on one `http:Listener` have the same `auth`, so they share one authenticator: a JWKS is
            // fetched and cached once, and a token is introspected once, whichever binding it arrives on.
            if earlierAuthenticator is ListenerAuthenticator {
                self.authenticator = earlierAuthenticator;
            } else {
                self.authenticator = check new (configName, auth.cloneReadOnly());
            }
        } else {
            self.authConfig = ();
            self.authenticator = ();
        }
        if listenTo is http:Listener {
            self.httpListener = listenTo;
        } else {
            http:Listener|error created = new (listenTo, httpListenerConfigurationOf(config));
            if created is error {
                return wrapTransportError(created);
            }
            self.httpListener = created;
        }
        // The scheme comes from the HTTP listener itself, so it is right for a port and for an `http:Listener` passed
        // in.
        self.interfaceScheme = self.httpListener.getConfig().secureSocket is () ? "http" : "https";
        self.streamTiming = {idleTimeout: config.streamIdleTimeout, keepAliveInterval: config.keepAliveInterval};
        self.validateInputModes = config.validateInputModes;
        self.configName = configName;
        self.protocolBinding = protocolBinding;
        self.defaultMountPath = defaultMountPath;
        self.byMethodName = byMethodName;
        self.newDispatcher = newDispatcher;
        if listenTo is http:Listener {
            rememberSharedSettings(listenTo, self.authConfig, self.publicUrl, self.authenticator);
        }
    }

    # Attaches a service: derives its capabilities and card, enters it in the card the `http:Listener` publishes, and
    # mounts its dispatcher.
    #
    # + a2aService - The service
    # + name - The `name` the runtime passed to `attach`
    # + return - An `a2a:Error` if the service is unusable, the path is taken, or the mount fails
    isolated function attach(Service a2aService, string[]|string? name) returns Error? {
        // Everything that only reads the service, before the lock: it runs the application's own `getAgentCard`, and
        // that must not run while the listener's state is held.
        string mountPath = check mountPathOf(name, self.defaultMountPath);
        OperationBinding binding = new (a2aService, byMethodName = self.byMethodName);
        // Before anything that would say a method is missing: a typo is why it is missing, and that is the useful
        // thing to report.
        if binding.problems.length() > 0 {
            string msg = string `an a2a:Service attached to a ${self.configName.substring(0,
                    self.configName.length() - "Configuration".length())} has remote functions that cannot serve an `
                + string `A2A method: ${string:'join("; ", ...binding.problems)}`;
            return error InternalError(msg, message = msg);
        }
        Capabilities capabilities = check capabilitiesOf(binding);
        AgentCard supplied = check agentCardOf(a2aService, binding);
        // Refused before anything is bound: [specification section 13.3](https://a2a-protocol.org/latest/specification/#133-extended-agent-card-access-control)
        // says `GetExtendedAgentCard` MUST require authentication, so a service that would serve it to anyone must
        // not start.
        if capabilities.extendedAgentCard && self.authenticator is () {
            string declaration = binding.declarationOf("handleGetExtendedAgentCard");
            string msg = string `a service that defines ${self.byMethodName ? declaration
                : string `the ${declaration} resource`} requires ${self.configName}.auth: `
                + "the extended agent card is for authenticated callers";
            return error InternalError(msg, message = msg);
        }
        ServedCards cards = new (self.authConfig, capabilities, self.protocolBinding);
        AgentCard & readonly served = cards.publicCard(supplied).cloneReadOnly();
        lock {
            http:Service dispatcherService = self.newDispatcher(served, binding, cards, self.authenticator,
                    self.interfaceScheme, self.publicUrl, self.streamTiming, mountPath, self.validateInputModes);
            check addCardBinding(self.httpListener, self.interfaceScheme, served, self.protocolBinding, mountPath,
                    self.authConfig, self.publicUrl, self.validateInputModes);
            error? result = attachAt(self.httpListener, dispatcherService, mountPath);
            if result is error {
                // Undoes the card entry, so the card does not advertise an interface that serves nothing and the
                // path can be used again.
                removeCardBinding(self.httpListener, mountPath);
                return wrapTransportError(result);
            }
            self.attached.push({agentService: a2aService, dispatcher: dispatcherService, mountPath});
        }
        log:printInfo("A2A service attached", path = "/" + mountPath, operations = binding.defined.toString());
    }

    # Detaches a service: takes its interface off the card and unmounts its dispatcher. A service that is not attached
    # is left alone.
    #
    # + a2aService - The service
    # + return - An `a2a:Error` if the dispatcher cannot be unmounted
    isolated function detach(Service a2aService) returns Error? {
        lock {
            foreach int i in 0 ..< self.attached.length() {
                if self.attached[i].agentService === a2aService {
                    AttachedService entry = self.attached.remove(i);
                    removeCardBinding(self.httpListener, entry.mountPath);
                    error? result = self.httpListener.detach(entry.dispatcher);
                    if result is error {
                        return wrapTransportError(result);
                    }
                    break;
                }
            }
        }
    }

    isolated function 'start() returns Error? {
        error? result = self.httpListener.'start();
        if result is error {
            return wrapTransportError(result);
        }
    }

    isolated function gracefulStop() returns Error? {
        error? result = self.httpListener.gracefulStop();
        if result is error {
            return wrapTransportError(result);
        }
    }

    isolated function immediateStop() returns Error? {
        error? result = self.httpListener.immediateStop();
        if result is error {
            return wrapTransportError(result);
        }
    }
}

# Checks a configured public URL and puts it in the form the card serves.
#
# + configName - The listener configuration's type name, for error messages
# + url - The configuration's `publicUrl`
# + return - The URL without a trailing slash, or an `a2a:InternalError` if it
#            is not an absolute `http://` or `https://` URL with a host and no
#            query or fragment
isolated function normalisePublicUrl(string configName, string url) returns string|Error {
    string rest;
    if url.startsWith("https://") {
        rest = url.substring(8);
    } else if url.startsWith("http://") {
        rest = url.substring(7);
    } else {
        return invalidPublicUrl(configName, url, "it must start with http:// or https://");
    }
    if url.includes("?") || url.includes("#") {
        return invalidPublicUrl(configName, url, "it must not have a query or a fragment");
    }
    int? slash = rest.indexOf("/");
    string host = slash is int ? rest.substring(0, slash) : rest;
    if host == "" {
        return invalidPublicUrl(configName, url, "it has no host");
    }
    return stripTrailingSlash(url);
}

# Checks the configured stream timing, which is in seconds and so cannot be
# negative.
#
# + configName - The configuration record's name, for the message
# + idleTimeout - `streamIdleTimeout`
# + keepAliveInterval - `keepAliveInterval`
# + return - An `a2a:InternalError` naming the first negative field
isolated function checkStreamTiming(string configName, decimal idleTimeout, decimal keepAliveInterval) returns Error? {
    string? negative = idleTimeout < 0d ? "streamIdleTimeout" : keepAliveInterval < 0d ? "keepAliveInterval" : ();
    if negative is string {
        string msg = string `${configName}.${negative} must not be negative; use 0 to turn it off`;
        return error InternalError(msg, message = msg);
    }
}

isolated function invalidPublicUrl(string configName, string url, string reason) returns Error {
    string msg = string `${configName}.publicUrl "${url}" is not usable: ${reason}`;
    return error InternalError(msg, message = msg);
}
