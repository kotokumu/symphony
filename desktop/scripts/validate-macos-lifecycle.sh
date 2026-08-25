#!/bin/sh
set -eu

application=${1:-}
[ -d "$application" ] || {
  echo "Usage: $0 /path/to/Symphony.app" >&2
  exit 2
}

root=$(mktemp -d "${TMPDIR:-/tmp}/symphony-lifecycle.XXXXXX")
trap 'rm -rf "$root"' EXIT
applications="$root/Applications"
user_data="$root/Library/Application Support/Symphony"
installed="$applications/Symphony.app"
mkdir -p "$applications" "$user_data"
printf '%s\n' 'namespace-metadata-sentinel' > "$user_data/namespaces.json"

ditto "$application" "$installed"
[ -x "$installed/Contents/MacOS/SymphonyDesktop" ]

upgrade_source="$root/Symphony-upgrade.app"
ditto "$application" "$upgrade_source"
rm -rf "$installed"
ditto "$upgrade_source" "$installed"
grep -qx 'namespace-metadata-sentinel' "$user_data/namespaces.json"

rm -rf "$installed"
[ ! -e "$installed" ]
[ -f "$user_data/namespaces.json" ]
echo "Install, upgrade, and uninstall data-retention validation passed"
