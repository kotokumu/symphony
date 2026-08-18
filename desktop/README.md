# Symphony Desktop

Symphony Desktop is the native macOS application for operating local Symphony namespaces. The
initial project provides an application shell and does not manage namespaces yet.

## Requirements

- macOS 13 or later
- A Swift 6 toolchain with a macOS SDK, provided by Xcode or Xcode Command Line Tools

## Commands

Run these commands from the repository root:

```sh
make -C desktop build
make -C desktop test
make -C desktop run
```

`make -C desktop all` runs the build and test checks used by continuous integration.
