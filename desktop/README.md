# Symphony Desktop

Symphony Desktop is the native macOS application for operating local Symphony namespaces. The
application can create, rename, select, and delete multiple namespaces on one Mac.

## Development Requirements

- macOS 15.3 or later
- Xcode 16.4 with its Swift 6 toolchain and macOS SDK
- `mise` with the tools in `elixir/mise.toml` installed when running the daemon from a source checkout
- Codex CLI available on `PATH` to use namespace authentication and run Codex through a daemon

Xcode Command Line Tools alone are insufficient because the test suite uses XCTest.

## Deployment Target

The application package targets macOS 13 or later.

## Commands

Run these commands from the repository root:

```sh
make -C desktop build
make -C desktop test
SYMPHONY_CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make -C desktop run
```

`make -C desktop all` runs the build and test checks used by continuous integration.

## Release packaging

The supported release target is macOS 13 or later on Apple Silicon hardware. A release
package contains the signed desktop app, credential broker, and Symphony daemon in one sealed
bundle; Codex remains a user-installed dependency and is never copied into the bundle.

Create and validate a signed package with an Apple Developer ID identity:

```sh
(cd elixir && mix deps.get && BURRITO_TARGET=macos_arm64 MIX_ENV=prod mise exec zig@0.15.2 -- mix release symphony --overwrite)
SYMPHONY_CODE_SIGN_IDENTITY="Developer ID Application: Your Team (TEAMID)" \
SYMPHONY_DAEMON_PATH="$PWD/elixir/burrito_out/symphony_macos_arm64" \
SYMPHONY_NOTARY_PROFILE="symphony-notary" \
SYMPHONY_VERSION="0.1.0" SYMPHONY_OUTPUT_DIR="$PWD/dist" \
  make -C desktop package
desktop/scripts/validate-macos-mvp.sh "$PWD/dist/Symphony.app"
```

The hosted release workflow expects `SYMPHONY_CODE_SIGN_IDENTITY`, an exported Developer ID
certificate (`APPLE_CERTIFICATE_P12_BASE64` and `APPLE_CERTIFICATE_PASSWORD`), and App Store
Connect API-key secrets (`APPLE_NOTARY_API_KEY_BASE64`, `APPLE_NOTARY_KEY_ID`, and
`APPLE_NOTARY_ISSUER`). It imports these into a temporary keychain and removes that keychain after
the package job.

The validator also runs an isolated install/upgrade/uninstall simulation. It verifies that replacing
or removing the app does not remove a namespace metadata sentinel; real launch, restart, and
sleep/wake checks are performed on a supported Mac using the Launch Check above.

For CI-only structural checks, `make -C desktop validate-package` creates an unsigned package and
checks its bundle contents. A distributable build must be signed, assessed by Gatekeeper, and
notarized with `xcrun notarytool` before release. The release workflow supplies the notary profile
without writing its credentials to the repository. Installing a newer package replaces only the
application bundle; namespace metadata, workspaces, Codex homes, and Keychain items remain outside
the bundle. Uninstall removes the app and helper but does not silently delete namespace data or
protected Keychain items; users must delete namespaces from Symphony when they intend to remove it.

## Launch Check

Set `SYMPHONY_CODE_SIGN_IDENTITY` to an Apple Development code-signing identity and run
`make -C desktop run`. The command assembles a signed development `Symphony.app`, nests and signs
the credential broker with its Team-scoped Data Protection Keychain access group, verifies the
signed entitlements, runs an authenticated add/load/delete smoke check against the Data Protection
Keychain, verifies the sealed bundle, and launches that application. Then verify the following
behavior:

1. The window titled `Symphony` displays the empty state and a `Create Namespace` button.
2. Create two namespaces and switch between them in the sidebar.
3. Rename one namespace and confirm the sidebar and detail view update.
4. Quit and relaunch the app, then confirm the namespaces and selection are restored.
5. Choose `Delete…`, confirm that canceling preserves the namespace, then delete it and confirm its
   local data is permanently removed.
6. Start a daemon in each of two namespaces and confirm both reach `Daemon running` with different
   local endpoints.
7. Stop one daemon and confirm the other remains running, then restart the running daemon and confirm
   it returns to `Daemon running`.
8. Close the desktop window and confirm its namespace daemons stop. Relaunch a daemon, quit the
   application, and confirm termination waits for the daemon to stop.
9. Select a signed-out namespace, choose `Sign in with ChatGPT`, complete the browser flow, and
   confirm the namespace displays `Codex signed in`.
10. Sign in a second namespace, sign out the first, and confirm the second remains signed in.
11. Quit and relaunch the application, select each namespace, and confirm its independent Codex
    authentication state is restored.
12. Unlock a namespace and confirm macOS requests device owner authentication, using Touch ID when
    available. Cancel the request and confirm the namespace remains locked with a retry action.
13. Unlock two namespaces, lock one, and confirm the other remains unlocked.
14. Unlock a namespace and stop its daemon, then confirm the namespace locks. Repeat by putting the
    Mac to sleep and waking it.
15. Unlock namespaces, quit the application, and confirm termination waits for their credential
    brokers to stop.

## Namespace Codex Boundary

The application sets `CODEX_HOME` to `<namespace>/CodexHome` for Codex login, status, logout, and
the namespace daemon's `codex app-server`. It creates this directory with owner-only permissions and
does not inherit API-key or access-token environment variables from the desktop process. Codex owns
the credential file format and browser callback flow; Symphony does not parse or rewrite those
credentials.

## Native Credential Broker Boundary

`SymphonyCredentialBroker` is a separate native helper process. The desktop application starts one
helper session for each unlocked namespace and communicates through private standard-input and
standard-output pipes. The process receives only a namespace identifier on its command line. The
desktop application, namespace daemon, and Codex processes do not link the Keychain implementation
or receive raw stored credential values.

Before accepting an operation, the helper requires its packaged location inside a valid sealed
application and verifies both the on-disk desktop executable and its running parent against a fixed
desktop signing identifier and the helper's own trusted signing team. This applies to unlock, purge,
and capability operations. Unknown operations are rejected. Capability responses return derived
results or non-secret metadata and cannot return the stored credential. Each namespace pipe admits
one complete request-response transaction at a time, and locking closes capability admission before
waiting for an in-flight transaction.

The helper uses LocalAuthentication for device owner approval and protects its namespace credential
with a Data Protection Keychain user-presence policy and `ThisDeviceOnly` accessibility. It copies
decrypted material into an explicitly cleared memory buffer and clears temporary mutable copies.
Locking ends the helper session; forced termination is bounded, the launcher retains failed process
ownership, and later lock or shutdown requests retry the same process instead of allowing a
replacement.

Namespace deletion records only the namespace UUID in an owner-only cleanup ledger before the local
repository transaction. A rollback removes that marker without purging Keychain material. After a
commit, failed Keychain cleanup remains pending and is retried at the next catalog load. System sleep
protection is registered for the application lifetime and uses IOKit's power acknowledgement so the
Mac does not proceed with cancellable sleep until broker locking completes successfully. A
registration failure keeps credential unlock disabled. Window-close cleanup remains tracked after
the view disappears and exposes failures for retry without unregistering sleep protection.

## GitHub App Connection Boundary

The connection sheet sends the numeric GitHub App ID and the user-selected key file path through the
authenticated broker pipe. Only `SymphonyCredentialBroker` opens that file. It validates an RSA
private key, replaces the namespace's protected Keychain payload, and keeps the decoded key inside
its explicitly cleared process memory.

The broker signs short-lived RS256 GitHub App JWTs and performs installation discovery internally.
For repository discovery it exchanges a JWT for an installation access token, uses that token only
inside the helper, and returns repository descriptors to the desktop. JWTs and installation tokens
are never written to application files, command lines, environment variables, or broker responses.
Requests use GitHub's versioned REST API and bounded pagination and response frames.

The desktop persists only the App ID, installation and account identities, and selected repository
identity and URL in `namespaces.json`. It requires Issues write access and Contents write access for
the initial Symphony workflow. A separate owner-only cleanup ledger makes connection rollback,
setup cancellation, and disconnection credential deletion retryable without deleting a credential
before the namespace metadata transaction commits.

After connection, the trusted desktop authorizes the existing namespace broker with the persisted
repository identity and namespace workspace root. The broker mints installation tokens constrained
to that repository and to Issues and Contents write permissions. Its wire protocol exposes only
typed issue reads, comment creation, issue state changes, and clone, fetch, or push results. It does
not expose raw REST paths, authorization headers, or installation tokens.

Git operations run as broker-owned subprocesses with system and global Git configuration disabled.
The broker validates the workspace, repository metadata, origin, branch, and an allowlisted local
configuration before it copies a token for the operation. A private, operation-scoped credential
helper channel supplies that copy to Git. The Git environment disables ambient credential helpers,
proxies, custom TLS configuration, redirects, hooks, and terminal prompts. Returned Git output is
bounded and redacts the active raw, encoded, and HTTP credential forms.
