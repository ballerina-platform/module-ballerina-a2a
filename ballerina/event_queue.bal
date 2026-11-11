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

import ballerina/jballerina.java;

# The marker a tap's queue ends with: nothing follows it.
const CLOSED = "closed";

# What a tap's queue holds: an event, an error that completes the stream, or
# the marker that ends it.
type QueueItem StreamResponse|Error|CLOSED;

# A queue whose `take` waits until an item arrives, without polling.
#
# Any number of strands may `put`; `take` is meant for one consumer at a time
# (a tap has exactly one reader). `put` never waits. `take` parks the calling
# strand while the queue is empty, so an idle subscriber costs nothing and
# wakes the moment an item is put or its timeout passes.
isolated class EventQueue {

    isolated function init() {
        self.externInit();
    }

    isolated function externInit() = @java:Method {
        'class: "io.ballerina.lib.a2a.nativeimpl.EventQueue"
    } external;

    # Appends an item.
    #
    # + item - The item to queue; it must not be shared with another strand
    #          (`.clone()` it first)
    isolated function put(QueueItem item) = @java:Method {
        'class: "io.ballerina.lib.a2a.nativeimpl.EventQueue"
    } external;

    # Puts an item ahead of everything already queued.
    #
    # + item - The item to queue; same rule as `put`
    isolated function putFirst(QueueItem item) = @java:Method {
        'class: "io.ballerina.lib.a2a.nativeimpl.EventQueue"
    } external;

    # Removes the first item, waiting for one if the queue is empty.
    #
    # + timeout - The longest wait in seconds; `()` waits for as long as it takes
    # + return - The first item, `()` if `timeout` passed with the queue empty,
    #            or an error if the wait was interrupted
    isolated function take(decimal? timeout = ()) returns QueueItem|error? = @java:Method {
        'class: "io.ballerina.lib.a2a.nativeimpl.EventQueue"
    } external;
}
