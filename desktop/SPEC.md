# Symphony Desktop Specification

Status: Draft

## 1. Application Shell

Symphony Desktop runs as a native macOS application and opens a main window titled `Symphony`.

---

## 2. Empty State

The initial application shell communicates that no namespaces exist and that the user must create
one before Symphony can orchestrate work. The user can begin namespace creation from this state.

---

## 3. Namespace Management

The application supports multiple local namespaces. A user can create, rename, select, and delete
namespaces from the main window.

Each namespace has a stable identity that does not change when the namespace is renamed. Creating a
namespace selects it. Selecting a namespace displays its detail view. Deleting the selected
namespace selects an adjacent namespace when one remains, or returns the application to the empty
state when none remain.

Namespace names must:

- contain at least one character;
- contain no leading or trailing whitespace;
- contain no control characters;
- contain no more than 64 characters; and
- be unique without regard to case or canonically equivalent Unicode composition.

Validation failures are displayed without dismissing the create or rename form.

Deletion requires explicit destructive confirmation that the namespace and all of its local data
will be permanently removed from the Mac.

---

## 4. Persistence and Recovery

Namespaces and the current selection persist across application restarts. Namespace directories
remain associated with stable namespace identities, so renaming a namespace does not relocate its
local data.

The application does not replace unreadable or unsupported namespace data. It reports the problem
and allows the user to retry after correcting it. A missing namespace directory is also reported
without recreating or deleting data automatically. If local data cleanup is interrupted after a
confirmed deletion, the application reports the remaining data and retries cleanup on its next
start.

---

## 5. Namespace Daemon Lifecycle

Each namespace has an independent Symphony daemon lifecycle. Daemons are stopped when the desktop
application starts. A user can start, stop, or restart a namespace daemon without changing the
state of another namespace daemon, and multiple namespace daemons can run concurrently.

The application reports when a daemon is stopped, starting, running, or failed. A daemon is running
only after its local endpoint responds successfully. The running state displays that endpoint. A
failed start or unexpected exit displays an actionable error and allows the user to restart the
affected daemon.

Each namespace daemon has isolated workspace data, runtime configuration, logs, and a local
communication endpoint. Runtime ownership follows the namespace's stable identity: selecting or
renaming a namespace does not start, stop, or replace its daemon.

Deleting a namespace stops its daemon before deleting local namespace data. Closing the desktop
window stops all namespace daemons owned by that application instance. Quitting the application
waits for its daemons to stop; if safe shutdown fails, the application reports the failure and
cancels termination.

---

## 6. Codex Authentication

Each namespace has an independent Codex authentication state. A user can start ChatGPT browser
sign-in for the selected namespace and return to the application when Codex completes the flow.
The application reports signed-out, authenticating, signed-in, expired, and failed states. Expired
or failed authentication can be retried.

Signing in or out changes only the selected namespace. Authentication remains associated with the
namespace's stable identity across application restarts and namespace renames. The same isolated
authentication boundary is used when that namespace's Symphony daemon starts Codex. Authentication
operations stop before the namespace's local data is deleted or the application terminates.
