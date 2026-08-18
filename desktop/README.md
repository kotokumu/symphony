# Symphony Desktop

Symphony Desktop is the native macOS application for operating local Symphony namespaces. The
application can create, rename, select, and delete multiple namespaces on one Mac.

## Development Requirements

- macOS 15.3 or later
- Xcode 16.4 with its Swift 6 toolchain and macOS SDK

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
