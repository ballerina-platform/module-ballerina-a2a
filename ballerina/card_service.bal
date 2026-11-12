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


// The public discovery card, served at the root of the listener whichever
// bindings are attached beneath it.

import ballerina/http;
import ballerina/log;

# The card of the agent a listener serves, and the bindings it is served over.
isolated class CardRegistry {
    private AgentCard? card = ();
    private (http:ListenerAuthConfig[] & readonly)? auth = ();
    private string? publicUrl = ();
    private string[][] bindings = [];

    # Records a service's card and binding.
    #
    # The bindings on one `http:Listener` publish one card, so a second binding
    # must carry the same card, authenticate callers the same way and be
    # reached at the same public URL.
    #
    # + served - The derived card the service will be served with
    # + protocolBinding - The binding, e.g. `HTTP+JSON`
    # + mountPath - The path it is mounted at
    # + auth - The listener's `auth`, if any
    # + publicUrl - The listener's public URL, if any
    # + return - An `a2a:InternalError` if the card, `auth` or `publicUrl`
    #            differs, or the path is taken
    isolated function add(AgentCard served, string protocolBinding, string mountPath,
            (http:ListenerAuthConfig[] & readonly)? auth, string? publicUrl) returns Error? {
        json servedWithoutInterfaces = withoutInterfaces(served).toJson();
        lock {
            AgentCard? existing = self.card;
            if existing is AgentCard {
                string? mismatch = ();
                if withoutInterfaces(existing).toJson() != servedWithoutInterfaces {
                    mismatch = "declare the same agent card and define the same "
                        + "capabilities (streaming, push notifications, extended card)";
                } else if auth != self.auth {
                    mismatch = "be on listeners that configure the same `auth`";
                } else if publicUrl != self.publicUrl {
                    mismatch = "be on listeners that set the same `publicUrl`";
                }
                if mismatch is string {
                    string msg = "every a2a:Service attached to one http:Listener must " + mismatch
                        + ", since they publish one agent card";
                    return error InternalError(msg, message = msg);
                }
            }
            foreach string[] binding in self.bindings {
                if binding[1] == mountPath {
                    string msg = string `an a2a:Service is already attached at /${mountPath}`;
                    return error InternalError(msg, message = msg);
                }
            }
            self.card = served.cloneReadOnly();
            self.auth = auth;
            self.publicUrl = publicUrl;
            self.bindings.push([protocolBinding, mountPath]);
        }
    }

    # + return - Whether no binding is left
    isolated function isEmpty() returns boolean {
        lock {
            return self.bindings.length() == 0;
        }
    }

    # Forgets the binding at a path, and the card once no binding is left.
    #
    # + mountPath - The path the binding was mounted at
    isolated function remove(string mountPath) {
        lock {
            self.bindings = from string[] binding in self.bindings where binding[1] != mountPath select binding;
            if self.bindings.length() == 0 {
                self.card = ();
                self.auth = ();
                self.publicUrl = ();
            }
        }
    }

    # + interfaceScheme - The scheme the listener serves
    # + host - The `Host` the request named, used when no public URL is set
    # + return - The public card with one interface per attached binding, or `()` before any attach
    isolated function served(string interfaceScheme, string host) returns AgentCard? {
        lock {
            AgentCard? card = self.card;
            if card is () {
                return;
            }
            string baseUrl = interfaceUrlFor(self.publicUrl, interfaceScheme, host);
            AgentCard copy = {...card.clone()};
            AgentInterface[] interfaces = [];
            foreach string[] binding in self.bindings {
                interfaces.push({url: string `${baseUrl}/${binding[1]}`, protocolBinding: binding[0],
                    protocolVersion: A2A_PROTOCOL_VERSION});
            }
            copy.supportedInterfaces = interfaces;
            return copy.clone();
        }
    }
}

# A card with its interface list emptied, for comparing two services' cards
# whose interfaces differ only in the binding their listener speaks.
#
# + card - The card
# + return - A copy without `supportedInterfaces` entries
isolated function withoutInterfaces(AgentCard card) returns AgentCard {
    AgentCard copy = {...card.clone()};
    copy.supportedInterfaces = [];
    return copy;
}

// Listeners built on one `http:Listener` publish one card between them, so the
// registry and the card service are kept per `http:Listener`: whichever
// listener attaches first creates and mounts them, the others only add their
// interface, and the last one to detach releases them.
isolated [http:Listener, CardRegistry, CardService][] sharedCardStates = [];

# Adds an interface to the card served on an `http:Listener`, creating the card
# state and mounting its card service when it is the first.
#
# Everything happens under the lock that records the state, so a concurrent
# attach sees either no card state or one whose card service is mounted, and
# never one that is being released. A card service that fails to mount is not
# recorded, so the next attach tries again.
#
# + httpListener - The listener the cards are served on
# + interfaceScheme - The scheme the listener serves
# + served - The derived card the service will be served with
# + protocolBinding - The binding, e.g. `HTTP+JSON`
# + mountPath - The path it is mounted at
# + auth - The listener's `auth`, if any
# + publicUrl - The listener's public URL, if any
# + return - An `a2a:Error` if the card, `auth` or `publicUrl` differs from the
#            bindings already there, the path is taken, or the card service
#            cannot be mounted
isolated function addCardBinding(http:Listener httpListener, string interfaceScheme, AgentCard & readonly served,
        string protocolBinding, string mountPath, (http:ListenerAuthConfig[] & readonly)? auth,
        string? publicUrl) returns Error? {
    lock {
        foreach [http:Listener, CardRegistry, CardService] [existingListener, registry, _] in sharedCardStates {
            if existingListener === httpListener {
                return registry.add(served, protocolBinding, mountPath, auth, publicUrl);
            }
        }
        CardRegistry registry = new;
        check registry.add(served, protocolBinding, mountPath, auth, publicUrl);
        CardService cardService = new (registry, interfaceScheme);
        error? mounted = httpListener.attach(cardService);
        if mounted is error {
            return wrapTransportError(mounted);
        }
        sharedCardStates.push([httpListener, registry, cardService]);
    }
}

# Takes an interface off the card served on an `http:Listener`, and the card
# service with it when no interface is left. A no-op when no A2A listener has
# attached on it, so a detach never creates card state.
#
# The state is kept when the card service cannot be detached, so a later
# attach still finds it mounted.
#
# + httpListener - The listener the cards are served on
# + mountPath - The interface's mount path
isolated function removeCardBinding(http:Listener httpListener, string mountPath) {
    lock {
        foreach int i in 0 ..< sharedCardStates.length() {
            [http:Listener, CardRegistry, CardService] [existingListener, registry, cardService] =
                    sharedCardStates[i];
            if existingListener !== httpListener {
                continue;
            }
            registry.remove(mountPath);
            if registry.isEmpty() {
                error? detached = httpListener.detach(cardService);
                if detached is error {
                    log:printWarn("could not detach the agent card service", 'error = detached);
                } else {
                    _ = sharedCardStates.remove(i);
                }
            }
            return;
        }
    }
}

# Serves the public Agent Card at `/.well-known/agent-card.json` (specification
# section 8.2). Public: it is the one path that needs no authentication. Any
# other path outside a mounted binding gets the HTTP module's own 404 or 405.
isolated service class CardService {
    *http:Service;

    private final CardRegistry registry;
    private final string interfaceScheme;

    isolated function init(CardRegistry registry, string interfaceScheme) {
        self.registry = registry;
        self.interfaceScheme = interfaceScheme;
    }

    isolated resource function get \.well\-known/agent\-card\.json(http:Request req) returns http:Response|http:NotFound {
        string|http:HeaderNotFoundError host = req.getHeader("Host");
        AgentCard? card = self.registry.served(self.interfaceScheme, host is string ? host : "");
        if card is () {
            return http:NOT_FOUND;
        }
        return cardHttpResponse(card);
    }
}
