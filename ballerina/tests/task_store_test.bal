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

import ballerina/test;

isolated function taskAt(string id, TaskState state, string timestamp, string contextId = "ctx") returns Task => {
    id,
    contextId,
    status: {state, timestamp}
};

@test:Config {}
function testStorePutAndGetRoundTrips() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), ());

    Task? got = check store.get("t1", ());
    test:assertTrue(got is Task, "a stored task must be retrievable by id");
    test:assertEquals((<Task>got).status.state, TASK_STATE_WORKING);
}

@test:Config {}
function testStoreGetUnknownReturnsNil() returns error? {
    InMemoryTaskStore store = new;
    Task? got = check store.get("nope", ());
    test:assertTrue(got is (), "an unknown id must return () rather than an error");
}

@test:Config {}
function testStoreReturnsCopiesNotAliases() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_SUBMITTED, "2026-01-01T00:00:00Z"), ());

    Task got = <Task>check store.get("t1", ());
    got.status.state = TASK_STATE_COMPLETED;

    Task reread = <Task>check store.get("t1", ());
    test:assertEquals(reread.status.state, TASK_STATE_SUBMITTED,
            "mutating a returned task must not change what the store holds");
}

@test:Config {}
function testStoreRejectsTransitionOutOfTerminalState() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_COMPLETED, "2026-01-01T00:00:00Z"), ());

    Error? result = store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:01:00Z"), ());
    test:assertTrue(result is InternalError,
            "a task in a terminal state must not transition to another state");
}

@test:Config {}
function testStoreAllowsIdempotentTerminalPut() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_COMPLETED, "2026-01-01T00:00:00Z"), ());
    // Re-putting the same terminal state is not a transition and is allowed.
    Error? result = store.put(taskAt("t1", TASK_STATE_COMPLETED, "2026-01-01T00:00:00Z"), ());
    test:assertTrue(result is (), "re-storing the same terminal state must be allowed");
}

@test:Config {}
function testStoreListSortsByStatusTimestampDescending() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("oldest", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), ());
    check store.put(taskAt("newest", TASK_STATE_WORKING, "2026-01-03T00:00:00Z"), ());
    check store.put(taskAt("middle", TASK_STATE_WORKING, "2026-01-02T00:00:00Z"), ());

    ListTasksResponse page = check store.list({}, ());
    string[] ids = from Task t in page.tasks
        select t.id;
    test:assertEquals(ids, ["newest", "middle", "oldest"],
            "list must return tasks sorted by status timestamp, newest first");
    test:assertEquals(page.totalSize, 3);
    test:assertEquals(page.nextPageToken, "", "a full result set must end with an empty nextPageToken");
}

@test:Config {}
function testStoreListPaginatesWithCursor() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("a", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), ());
    check store.put(taskAt("b", TASK_STATE_WORKING, "2026-01-02T00:00:00Z"), ());
    check store.put(taskAt("c", TASK_STATE_WORKING, "2026-01-03T00:00:00Z"), ());

    ListTasksResponse first = check store.list({pageSize: 2}, ());
    test:assertEquals(from Task t in first.tasks select t.id, ["c", "b"]);
    test:assertEquals(first.nextPageToken, "b", "nextPageToken must be the id of the last task on the page");

    ListTasksResponse second = check store.list({pageSize: 2, pageToken: first.nextPageToken}, ());
    test:assertEquals(from Task t in second.tasks select t.id, ["a"]);
    test:assertEquals(second.nextPageToken, "", "the final page must end with an empty nextPageToken");
}

@test:Config {}
function testStoreListFiltersByContextAndStatus() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z", contextId = "ctx-a"), ());
    check store.put(taskAt("t2", TASK_STATE_COMPLETED, "2026-01-02T00:00:00Z", contextId = "ctx-a"), ());
    check store.put(taskAt("t3", TASK_STATE_WORKING, "2026-01-03T00:00:00Z", contextId = "ctx-b"), ());

    ListTasksResponse byContext = check store.list({contextId: "ctx-a"}, ());
    test:assertEquals(byContext.totalSize, 2, "contextId must filter the set");

    ListTasksResponse byStatus = check store.list({status: TASK_STATE_WORKING}, ());
    test:assertEquals(from Task t in byStatus.tasks select t.id, ["t3", "t1"],
            "status must filter the set, still newest first");
}

@test:Config {}
function testStoreListOmitsArtifactsUnlessRequested() returns error? {
    InMemoryTaskStore store = new;
    Task withArtifacts = {
        id: "t1", contextId: "ctx",
        status: {state: TASK_STATE_COMPLETED, timestamp: "2026-01-01T00:00:00Z"},
        artifacts: [{artifactId: "a1", parts: [{text: "output"}]}]
    };
    check store.put(withArtifacts, ());

    ListTasksResponse defaulted = check store.list({}, ());
    test:assertFalse((defaulted.tasks[0]).hasKey("artifacts"),
            "section 3.1.4: artifacts must be omitted entirely when includeArtifacts is false");

    ListTasksResponse requested = check store.list({includeArtifacts: true}, ());
    test:assertTrue((requested.tasks[0]).hasKey("artifacts"),
            "artifacts must be present when includeArtifacts is true");
}

@test:Config {}
function testStoreRemoveIsIdempotent() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), ());

    check store.remove("t1", ());
    test:assertTrue(check store.get("t1", ()) is (), "a removed task must be gone");
    check store.remove("t1", ());
    check store.remove("never-existed", ());
}

@test:Config {}
function testStoreGetHidesTaskFromNonOwner() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), "alice");

    test:assertTrue(check store.get("t1", "alice") is Task, "the owner must see their own task");
    test:assertTrue(check store.get("t1", "bob") is (),
            "a different owner must not see the task -- indistinguishable from nonexistent");
    test:assertTrue(check store.get("t1", ()) is (),
            "an unscoped caller must not see a task owned by someone else");
}

@test:Config {}
function testStoreUnscopedTasksFormTheirOwnPool() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), ());

    test:assertTrue(check store.get("t1", ()) is Task,
            "() is its own scope: an unscoped task is visible to an unscoped caller");
    test:assertTrue(check store.get("t1", "alice") is (),
            "an owned caller must not see a task stored under the unscoped pool");
}

@test:Config {}
function testStorePutConflictsAcrossOwners() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), "alice");

    Error? result = store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:01:00Z"), "bob");
    test:assertTrue(result is TaskNotFoundError,
            "a task id already owned by a different scope must not be silently taken over or ignored");

    // The original is untouched.
    Task? stillAlices = check store.get("t1", "alice");
    test:assertTrue(stillAlices is Task, "the original owner's task must be unaffected by the rejected write");
}

@test:Config {}
function testStoreListScopesToOwner() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("a1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), "alice");
    check store.put(taskAt("a2", TASK_STATE_WORKING, "2026-01-02T00:00:00Z"), "alice");
    check store.put(taskAt("b1", TASK_STATE_WORKING, "2026-01-03T00:00:00Z"), "bob");
    check store.put(taskAt("u1", TASK_STATE_WORKING, "2026-01-04T00:00:00Z"), ());

    ListTasksResponse aliceView = check store.list({}, "alice");
    test:assertEquals(from Task t in aliceView.tasks select t.id, ["a2", "a1"],
            "listing must see only the caller's own tasks");

    ListTasksResponse unscopedView = check store.list({}, ());
    test:assertEquals(from Task t in unscopedView.tasks select t.id, ["u1"],
            "the unscoped pool is its own scope, not a view over everything");
}

@test:Config {}
function testStoreRemoveHidesFromNonOwner() returns error? {
    InMemoryTaskStore store = new;
    check store.put(taskAt("t1", TASK_STATE_WORKING, "2026-01-01T00:00:00Z"), "alice");

    check store.remove("t1", "bob");
    test:assertTrue(check store.get("t1", "alice") is Task,
            "removing as a different owner must be a no-op, not a deletion");

    check store.remove("t1", "alice");
    test:assertTrue(check store.get("t1", "alice") is (), "removing as the true owner must succeed");
}
