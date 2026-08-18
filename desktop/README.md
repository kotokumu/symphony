# Symphony Desktop

Symphony Desktop is the native macOS application for operating local Symphony namespaces. The
initial project provides an application shell and does not manage namespaces yet.

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

Run `make -C desktop run`, then verify that a window titled `Symphony` displays `No Namespaces`
and `Create a namespace to start orchestrating work with Symphony.` Quit the app with Command-Q.
