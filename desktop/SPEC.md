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

---

## 7. Protected Credentials and Namespace Locking

Each namespace starts locked when Symphony launches. Unlocking a namespace requires macOS device
owner authentication, including Touch ID when it is available. Denying or cancelling the request
leaves the namespace locked and allows the user to retry. Unlocking or locking one namespace does
not change the lock state of another namespace.

Long-lived namespace credentials are stored through macOS protected credential storage. They are
not written to Symphony application files, logs, command-line arguments, or environment variables.
Only a broker session started by the trusted desktop application can unlock stored credential
material. The broker exposes operations for a credential's purpose and returns only their results,
not the stored value, to Symphony. Its daemons and Codex cannot start an authorized broker session
or read stored credentials directly.

A namespace can be locked manually. Its protected credential access is also cleared when its daemon
stops or fails, before the Mac acknowledges sleep, when the namespace is deleted, when the main
window closes, and before the application terminates. If protected credential access cannot be
cleared safely before deletion or application termination, Symphony reports the failure and does
not continue the destructive lifecycle operation. If system sleep protection cannot be established,
Symphony reports the failure and does not allow protected credentials to be unlocked. A failed
window-close cleanup remains visible and can be retried when the window is shown again. Stored
credential deletion occurs only after the namespace deletion commits. A failed stored-credential
cleanup is reported and retried without restoring the deleted namespace.

---

## 8. GitHub App Connection

A namespace can connect to one platform. The first supported connection is one GitHub App
installation and one repository. A user supplies the numeric GitHub App ID and selects its private
key file, then chooses from the installations and repositories accessible to that app. Connection
setup requires the namespace to be unlocked. Before repository capabilities are activated, the
broker verifies the selected repository ID, name, and URL against GitHub for that installation.

The GitHub App private key is imported and used through the protected credential boundary. Symphony
Desktop does not read or return the private key. GitHub App authentication and installation-token
use during connection discovery remain inside that boundary. The connection is accepted only when
the installation is active, can read and write issues and repository contents, and can access the
selected repository. Missing permissions, suspended or revoked installations, inaccessible
repositories, rejected credentials, and GitHub service failures produce actionable errors.

After the namespace is unlocked, Symphony can list issues, read an issue and its comments, add an
issue comment, and open or close an issue in the selected repository. Requests for another
installation or repository, unsupported GitHub operations, and malformed or oversized requests are
rejected before GitHub credentials are used. Pull requests returned by GitHub's issues endpoints are
excluded and cannot be read or mutated through issue capabilities. Read requests recover once from
an expired credential.
Issue mutations are not repeated automatically after dispatch because their effect may already have
occurred. Successful operations return typed issue or comment records rather than raw GitHub REST
response bytes.

Symphony mints repository-scoped installation credentials inside the protected credential boundary.
It reuses an unexpired credential only in protected process memory and refreshes it before expiry.
The credential is cleared when access is rejected, the namespace is locked, or the broker exits. It
is not returned to the desktop application, daemon, or Codex and is not written to namespace files,
repository configuration, process arguments, environment variables, or logs.

Symphony can clone the selected repository into a new namespace workspace and fetch or push that
repository over HTTPS. Fetch and push reject repositories outside the namespace workspace,
repositories whose origin does not match the selected repository, unsafe Git configuration, and
unsupported push destinations. Git receives its short-lived credential through an operation-scoped
credential helper over an inherited socket capability that is unavailable to unrelated processes.
Repository URLs and configuration remain credential-free. The broker passes Git a verified
filesystem authority instead of asking it to reopen a workspace path. A macOS process sandbox limits
filesystem writes to that authority and outbound network access to a broker-owned localhost tunnel
that accepts only GitHub connections. Clone writes to a broker-named staging directory and publishes
the workspace name atomically only after Git succeeds. A failed clone atomically detaches its staging
directory under a broker-owned descriptor. Cleanup unlinks a verified entry before clearing its contents and
refuses to clear an inode that remains linked elsewhere. Symphony preserves any replacement and
reports that cleanup is required before access can resume.

Locking protected credentials stops active GitHub and Git access, cancels queued access, clears
short-lived credentials, and prevents replacement access until owned processes have exited. A stop
failure remains retryable through the namespace lock operation. Git runs in an owned process group;
the desktop verifies descendant groups are gone even when the broker must be terminated forcibly.

The selected app identity, installation, account, and repository remain associated with the
namespace's stable identity across application restarts and namespace renames. Stored private-key
material remains namespace-scoped. Connecting, checking, or disconnecting one namespace does not
grant access to or change another namespace.

A user can check a saved connection after unlocking the namespace or disconnect it. Disconnection
commits the removal of connection metadata before protected credential deletion. Failed credential
cleanup is reported and retried, while the namespace remains disconnected. A failed connection save
does not publish the connection and schedules cleanup of the imported credential.
