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

# The card of the agent a listener serves, and the bindings it is served over.
isolated class CardRegistry {
    private AgentCard? card = ();
    private string[][] bindings = [];

    # Records a service's card and binding.
    #
    # A listener serves one agent: a second service must carry the same card.
    #
    # + served - The derived card the service will be served with
    # + protocolBinding - The binding, e.g. `HTTP+JSON`
    # + mountPath - The path it is mounted at
    # + return - An `a2a:InternalError` if the card differs or the path is taken
    isolated function add(AgentCard served, string protocolBinding, string mountPath) returns Error? {
        json servedWithoutInterfaces = withoutInterfaces(served).toJson();
        lock {
            AgentCard? existing = self.card;
            if existing is AgentCard && withoutInterfaces(existing).toJson() != servedWithoutInterfaces {
                string msg = "every a2a:Service attached to one http:Listener must declare the same agent card and define the same "
                    + "capabilities (streaming, push notifications, extended card)";
                return error InternalError(msg, message = msg);
            }
            foreach string[] binding in self.bindings {
                if binding[1] == mountPath {
                    string msg = string `an a2a:Service is already attached at /${mountPath}`;
                    return error InternalError(msg, message = msg);
                }
            }
            self.card = served.cloneReadOnly();
            self.bindings.push([protocolBinding, mountPath]);
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
            }
        }
    }

    # + baseUrl - The address the listener is reached at, without a trailing slash
    # + return - The public card with one interface per attached binding, or `()` before any attach
    isolated function served(string baseUrl) returns AgentCard? {
        lock {
            AgentCard? card = self.card;
            if card is () {
                return;
            }
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
// interface.
isolated [http:Listener, CardRegistry, CardService][] sharedCardStates = [];

# Finds or creates the card registry and card service of an `http:Listener`.
#
# + httpListener - The listener the cards are served on
# + interfaceScheme - The scheme the listener serves
# + publicUrl - The configured public URL, if any
# + return - The registry, the card service, and whether the card service was just
#            created and still has to be attached
isolated function cardStateFor(http:Listener httpListener, string interfaceScheme, string? publicUrl)
        returns [CardRegistry, CardService, boolean] {
    lock {
        foreach [http:Listener, CardRegistry, CardService] [existingListener, registry, cardService] in
                sharedCardStates {
            if existingListener === httpListener {
                return [registry, cardService, false];
            }
        }
        CardRegistry registry = new;
        CardService cardService = new (registry, interfaceScheme, publicUrl);
        sharedCardStates.push([httpListener, registry, cardService]);
        return [registry, cardService, true];
    }
}

# Forgets the card state kept for an `http:Listener`, after mounting its card
# service failed, so the next attach creates and mounts a new one.
#
# + httpListener - The listener whose card service could not be mounted
isolated function dropCardState(http:Listener httpListener) {
    lock {
        foreach int i in 0 ..< sharedCardStates.length() {
            if sharedCardStates[i][0] === httpListener {
                _ = sharedCardStates.remove(i);
                return;
            }
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
    private final string? publicUrl;

    isolated function init(CardRegistry registry, string interfaceScheme, string? publicUrl) {
        self.registry = registry;
        self.interfaceScheme = interfaceScheme;
        self.publicUrl = publicUrl;
    }

    isolated resource function get \.well\-known/agent\-card\.json(http:Request req) returns http:Response|http:NotFound {
        string|http:HeaderNotFoundError host = req.getHeader("Host");
        string baseUrl = interfaceUrlFor(self.publicUrl, self.interfaceScheme, host is string ? host : "");
        AgentCard? card = self.registry.served(baseUrl);
        if card is () {
            return http:NOT_FOUND;
        }
        return cardHttpResponse(card);
    }
}
