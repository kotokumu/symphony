# macOS MVP Release Checklist

The release workflow proves package assembly, code signing, notarization, stapling, and static
bundle/archive security checks. A release owner must also run the following checks on a clean,
supported Apple Silicon Mac and attach the results to the release record before distribution.

## Protected-machine checks

- [ ] Install the notarized ZIP and launch `Symphony.app` from `/Applications`.
- [ ] Create two namespaces, restart the app, and verify metadata and selection are retained.
- [ ] Connect a disposable GitHub App repository and complete issue discovery, comment, mutation,
  and repository fetch/push through the packaged daemon.
- [ ] Restart each namespace daemon and verify the other namespace remains unaffected.
- [ ] Sleep and wake the Mac with a namespace unlocked; verify credentials are locked before sleep
  and the daemon recovers only after an explicit unlock.
- [ ] Upgrade over the installed package and verify namespace files, Codex homes, workspaces, and
  protected Keychain items remain.
- [ ] Remove the app and verify those user-owned files and Keychain items remain until the user
  explicitly deletes the namespace.
- [ ] Inspect namespace files, process arguments/environments, logs, and crash output for the
  disposable credential sentinel; record the commands and results.

Record the macOS version, hardware model, package SHA-256, test repository, and evidence links with
the release. Do not include real private keys, installation tokens, or Codex credentials in the
evidence.
