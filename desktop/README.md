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
make -C desktop run
```

`make -C desktop all` runs the build and test checks used by continuous integration.

## Launch Check

Run `make -C desktop run`, then verify the following behavior:

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

## Namespace Codex Boundary

The application sets `CODEX_HOME` to `<namespace>/CodexHome` for Codex login, status, logout, and
the namespace daemon's `codex app-server`. It creates this directory with owner-only permissions and
does not inherit API-key or access-token environment variables from the desktop process. Codex owns
the credential file format and browser callback flow; Symphony does not parse or rewrite those
credentials.
