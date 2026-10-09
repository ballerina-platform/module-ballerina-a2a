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

// Where a server-side agent keeps the tasks it is running.
//
// A `Listener` running the task lifecycle for an `a2a:Service` needs
// somewhere to hold tasks between the request that creates one and the
// later requests that read or cancel it. That store is pluggable, matching
// both reference SDKs: `InMemoryTaskStore` is the default, and a production
// agent supplies its own backed by a database.

import ballerina/time;

// Specification 3.1.4's own bounds for ListTasks.pageSize: "If unspecified,
// at most 50 tasks will be returned. The minimum value is 1. The maximum
// value is 100."
const LIST_TASKS_DEFAULT_PAGE_SIZE = 50;
const LIST_TASKS_MIN_PAGE_SIZE = 1;
const LIST_TASKS_MAX_PAGE_SIZE = 100;

# Whether a task state is terminal — no further transition is legal from it.
#
# The four terminal states are fixed by the specification ([section 3.1.1](https://a2a-protocol.org/latest/specification/#311-send-message)):
# a message sent to a task in one of these must be refused.
#
# + state - The state to classify
# + return - Whether the state is terminal
public isolated function isTerminalState(TaskState state) returns boolean {
    return state == TASK_STATE_COMPLETED
        || state == TASK_STATE_FAILED
        || state == TASK_STATE_CANCELED
        || state == TASK_STATE_REJECTED;
}

# Persists and retrieves the tasks a server-side agent is running.
#
# Implement this to back a server's tasks with a real store — a database, a
# cache, a per-tenant partition. `a2a:InMemoryTaskStore` is provided for the
# simple case and for tests.
#
# Every method returns a narrowed `a2a:Error` on failure, so a storage fault
# surfaces the same way a protocol fault does rather than as a bare `error`.
public type TaskStore isolated object {

    # Stores a new task, or replaces an existing one with the same id.
    #
    # `owner` is an opaque scope, not an identity to trust on its own -- `()`
    # is its own scope, not a wildcard. A task id already stored under a
    # different owner is a conflict, not an overwrite: implementations should
    # reject it with `a2a:TaskNotFoundError`, the same error an unauthorized
    # caller sees elsewhere, rather than leak that the id is taken.
    #
    # + task - The task to persist
    # + owner - The caller's resolved owner scope, or `()`
    # + return - An error if the task could not be stored
    public isolated function put(Task task, string? owner) returns Error?;

    # Retrieves a task by id, scoped to `owner`.
    #
    # A task that exists under a different owner must be indistinguishable
    # from one that does not exist at all -- [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping)
    # requires that a server not reveal the existence of a resource the
    # caller is not authorized to access.
    #
    # + id - The task's id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The task, `()` if no task with this id is visible to
    #            `owner`, or an error if the lookup failed
    public isolated function get(string id, string? owner) returns Task?|Error;

    # Lists tasks matching a filter, newest first, with cursor pagination,
    # restricted to those visible to `owner`.
    #
    # + filter - The filter and pagination parameters; every field is optional
    # + owner - The caller's resolved owner scope, or `()`
    # + return - A page of matching tasks, or an error
    public isolated function list(ListTasksRequest filter, string? owner) returns ListTasksResponse|Error;

    # Removes a task by id, scoped to `owner`. A no-op when no task with the
    # id is visible to `owner` -- whether because none exists, or because it
    # belongs to a different owner; the two are not distinguished, per the
    # same section 13.1 reasoning as `get`.
    #
    # + id - The task's id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - An error if the removal failed
    public isolated function remove(string id, string? owner) returns Error?;
};

# The default in-memory `a2a:TaskStore`.
#
# Holds tasks in a map guarded by a lock, enforces the specification's task
# state machine on every update, and orders `list` by status timestamp
# descending as [section 3.1.4](https://a2a-protocol.org/latest/specification/#314-list-tasks) requires. Tasks do not survive a restart — a
# production agent supplies its own `a2a:TaskStore` instead.
public isolated class InMemoryTaskStore {
    *TaskStore;

    private map<Task> tasks = {};
    # Insertion order, so `list` can page deterministically and the
    # newest-first sort has a stable tiebreak when timestamps match. Global,
    # not per-owner: task ids are unique across every owner, so pagination
    # cursors keep one consistent meaning regardless of who is listing.
    private string[] insertionOrder = [];
    # The owner each task was stored under, keyed by task id. Entries exist
    # only for a non-`()` owner -- absence from this map means the task's
    # owner is `()`, avoiding a map entry for the common unscoped case.
    # A side map rather than a nested `map<map<Task>>` keeps `tasks` and
    # `insertionOrder` untouched: `string` is readonly, so reading this
    # inside `lock` needs no clone, and task ids stay globally unique, which
    # `/tasks/{id}` as a resource path and the push-config store (keyed by
    # bare taskId) both depend on.
    private map<string> taskOwners = {};

    # Stores a new task, or replaces an existing one, enforcing the state
    # machine.
    #
    # A task already in a terminal state cannot be transitioned again: the
    # four terminal states are final per [specification section 3.1.1](https://a2a-protocol.org/latest/specification/#311-send-message), so an
    # attempt to move one is a caller error, not a silent overwrite. A task
    # id already stored under a different owner is the same kind of
    # conflict -- reported as `a2a:TaskNotFoundError`, not a
    # visibility-leaking error, since `owner` not matching is
    # indistinguishable from the id belonging to someone else entirely.
    #
    # + task - The task to persist
    # + owner - The caller's resolved owner scope, or `()`
    # + return - An `a2a:InternalError` if the task would illegally leave a
    #            terminal state, an `a2a:TaskNotFoundError` if the id is
    #            already owned by a different scope, otherwise nil
    public isolated function put(Task task, string? owner) returns Error? {
        lock {
            Task? existing = self.tasks[task.id];
            string? existingOwner = self.taskOwners[task.id];
            if existing is Task && existingOwner != owner {
                return taskNotFound(task.id);
            }
            if existing is Task && isTerminalState(existing.status.state)
                    && existing.status.state != task.status.state {
                string msg = string `task ${task.id} is in terminal state `
                    + string `${existing.status.state} and cannot transition to ${task.status.state}`;
                return error InternalError(msg, message = msg);
            }
            if existing is () {
                self.insertionOrder.push(task.id);
                if owner is string {
                    self.taskOwners[task.id] = owner;
                }
            }
            self.tasks[task.id] = task.clone();
        }
    }

    # + id - The task's id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The task, or `()` if none has this id and is visible to `owner`
    public isolated function get(string id, string? owner) returns Task?|Error {
        lock {
            if self.taskOwners[id] != owner {
                return;
            }
            Task? task = self.tasks[id];
            return task is Task ? task.clone() : ();
        }
    }

    # Lists tasks newest first, filtered and paged per specification section
    # 3.1.4.
    #
    # Tasks are sorted by `status.timestamp` descending; ties break on
    # insertion order. `contextId` and `status` filter the set;
    # `statusTimestampAfter` bounds it below. `pageToken` is the id of the
    # last task on the previous page. `nextPageToken` is always present and
    # empty when the page is the last. `artifacts` is omitted from every task
    # unless `includeArtifacts` is true, and `history` is trimmed to
    # `historyLength`.
    #
    # + filter - The filter and pagination parameters
    # + owner - The caller's resolved owner scope, or `()`; only tasks
    #           visible to it are listed
    # + return - A page of matching tasks
    public isolated function list(ListTasksRequest filter, string? owner) returns ListTasksResponse|Error {
        // Snapshot the store into a local, in insertion order, before
        // querying. A query capturing `self.tasks` directly trips the
        // compiler's isolation analysis inside a lock, and a mutable array
        // declared outside the lock cannot be pushed to from within it, so
        // the snapshot is built lock-local and cloned out. The owner filter
        // is applied here, alongside the existence check, for the same
        // reason: self.taskOwners is only reachable inside this lock.
        Task[] all;
        lock {
            Task[] snapshot = [];
            foreach string id in self.insertionOrder {
                if self.taskOwners[id] != owner {
                    continue;
                }
                Task? t = self.tasks[id];
                if t is Task {
                    snapshot.push(t.clone());
                }
            }
            all = snapshot.clone();
        }

        string? contextId = filter?.contextId;
        TaskState? status = filter?.status;
        string? after = filter?.statusTimestampAfter;
        Task[] matched = from Task t in all
            where contextId is () || t?.contextId == contextId
            where status is () || t.status.state == status
            where after is () || statusAtOrAfter(t, after)
            order by statusTimestampKey(t) descending
            select t;

        // Specification 3.1.4: "If unspecified, at most 50 tasks will be
        // returned. The minimum value is 1. The maximum value is 100" --
        // an explicit value outside that range is a caller mistake (400),
        // per section 6.5's own validation example (`pageSize=150` ->
        // "Must be between 1 and 100 inclusive"), not something to clamp
        // or silently treat as "no results".
        int? requestedPageSize = filter?.pageSize;
        if requestedPageSize is int && (requestedPageSize < LIST_TASKS_MIN_PAGE_SIZE
                || requestedPageSize > LIST_TASKS_MAX_PAGE_SIZE) {
            return invalidParams(string `pageSize must be between ${LIST_TASKS_MIN_PAGE_SIZE} and `
                + string `${LIST_TASKS_MAX_PAGE_SIZE} inclusive, got ${requestedPageSize}`, "pageSize");
        }
        int pageSize = requestedPageSize ?: LIST_TASKS_DEFAULT_PAGE_SIZE;
        int startIndex = 0;
        string? pageToken = filter?.pageToken;
        if pageToken is string {
            int? found = indexOfTaskId(matched, pageToken);
            if found is () {
                // A page token this store never issued -- unlike the
                // filters above, this is never legitimately "no results";
                // it is a caller passing back a cursor from a different
                // query, an expired one, or one it invented. The reference
                // a2a-sdk agrees (InvalidParams "Invalid page token").
                return invalidParams(string `pageToken "${pageToken}" does not name a task in this result set`,
                    "pageToken");
            }
            startIndex = found + 1;
        }
        int endIndex = startIndex + pageSize;
        if endIndex > matched.length() {
            endIndex = matched.length();
        }

        boolean includeArtifacts = filter?.includeArtifacts ?: false;
        int? historyLength = filter?.historyLength;
        Task[] page = [];
        foreach int i in startIndex ..< endIndex {
            page.push(projectTask(matched[i], includeArtifacts, historyLength));
        }

        string nextPageToken = endIndex < matched.length() && page.length() > 0
            ? page[page.length() - 1].id
            : "";
        return {
            tasks: page,
            nextPageToken,
            pageSize: page.length(),
            totalSize: matched.length()
        };
    }

    # + id - The task's id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - nil; removing a task that does not exist, or is not visible
    #            to `owner`, is a no-op
    public isolated function remove(string id, string? owner) returns Error? {
        lock {
            if self.taskOwners[id] != owner {
                return;
            }
            _ = self.tasks.removeIfHasKey(id);
            _ = self.taskOwners.removeIfHasKey(id);
            int? idx = self.insertionOrder.indexOf(id);
            if idx is int {
                _ = self.insertionOrder.remove(idx);
            }
        }
    }
}

# Shapes a stored task for a `list` response: drops `artifacts` unless asked,
# and trims `history` to `historyLength`.
#
# Section 3.1.4 requires `artifacts` to be omitted entirely — not an empty
# array — when `includeArtifacts` is false, so this removes the field rather
# than blanking it. `history` gets the same treatment at `historyLength` 0:
# section 3.2.4 says the field SHOULD be omitted, not sent empty.
#
# + task - The stored task
# + includeArtifacts - Whether to keep the artifacts field
# + historyLength - Maximum history messages to keep, or `()` for all
# + return - The projected copy
isolated function projectTask(Task task, boolean includeArtifacts, int? historyLength) returns Task {
    Task copy = task.clone();
    if !includeArtifacts {
        _ = copy.removeIfHasKey("artifacts");
    }
    if historyLength is int {
        Message[]? history = copy?.history;
        if historyLength <= 0 {
            _ = copy.removeIfHasKey("history");
        } else if history is Message[] && history.length() > historyLength {
            copy.history = history.slice(history.length() - historyLength);
        }
    }
    return copy;
}

# Sort key for newest-first ordering: the status timestamp as epoch seconds,
# or 0 when a task carries no timestamp (it then sorts oldest, which is the
# safe default for an un-stamped task).
#
# + task - The task to key
# + return - Epoch seconds of the status timestamp, or 0
isolated function statusTimestampKey(Task task) returns decimal {
    string? ts = task.status?.timestamp;
    if ts is () {
        return 0;
    }
    time:Utc|error parsed = time:utcFromString(ts);
    return parsed is time:Utc ? <decimal>parsed[0] + parsed[1] : 0;
}

# Whether a task's status timestamp is at or after the given RFC 3339 bound.
#
# A task with no timestamp is treated as not matching a lower bound, since
# there is nothing to compare.
#
# + task - The task to test
# + after - The RFC 3339 lower bound
# + return - Whether the task's status timestamp is at or after `after`
isolated function statusAtOrAfter(Task task, string after) returns boolean {
    string? ts = task.status?.timestamp;
    if ts is () {
        return false;
    }
    time:Utc|error taskTs = time:utcFromString(ts);
    time:Utc|error bound = time:utcFromString(after);
    if taskTs is error || bound is error {
        return false;
    }
    return time:utcDiffSeconds(taskTs, bound) >= 0d;
}

# Index of the task with the given id in a list, or `()`.
#
# + tasks - The list to search
# + id - The id to find
# + return - The index, or `()` if not present
isolated function indexOfTaskId(Task[] tasks, string id) returns int? {
    foreach int i in 0 ..< tasks.length() {
        if tasks[i].id == id {
            return i;
        }
    }
    return;
}
