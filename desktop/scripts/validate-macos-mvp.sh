#!/bin/sh
set -eu

application=${1:-}
[ -n "$application" ] && [ -d "$application" ] || {
  echo "Usage: $0 /path/to/Symphony.app" >&2
  exit 2
}

contents="$application/Contents"
[ -x "$contents/MacOS/SymphonyDesktop" ] || { echo "error: desktop executable missing" >&2; exit 1; }
[ -x "$contents/Helpers/SymphonyCredentialBroker" ] || { echo "error: credential broker missing" >&2; exit 1; }
[ -x "$contents/bin/symphony" ] || { echo "error: Symphony daemon missing" >&2; exit 1; }
[ -f "$contents/Info.plist" ] || { echo "error: Info.plist missing" >&2; exit 1; }

if [ "${SYMPHONY_ALLOW_UNSIGNED:-0}" != 1 ]; then
  codesign --verify --deep --strict "$application"
  spctl --assess --type execute --no-cache "$application"
fi

validation_root=$(mktemp -d "${TMPDIR:-/tmp}/symphony-package-scan.XXXXXX")
trap 'rm -rf "$validation_root"' EXIT
credential_pattern='ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'

scan_tree() {
  tree=$1
  output="$validation_root/strings-$(basename "$tree")"
  if ! find "$tree" -type f -exec strings {} + > "$output" 2>/dev/null; then
    echo "error: unable to scan package files: $tree" >&2
    exit 1
  fi
  if grep -E -q "$credential_pattern" "$output"; then
    echo "error: a credential-like value was found in the package" >&2
    exit 1
  fi
  sensitive_path=
  if ! sensitive_path=$(find "$tree" -type f \( -name '*.env' -o -name '*.pem' -o -name '*.key' -o -name '*.p8' -o -name '*.p12' -o -name '*.log' \) -print -quit); then
    echo "error: unable to inspect package file names: $tree" >&2
    exit 1
  fi
  if [ -n "$sensitive_path" ]; then
    echo "error: sensitive file type found in the package: $sensitive_path" >&2
    exit 1
  fi
}

scan_tree "$application"

if [ -n "${SYMPHONY_PACKAGE_ARCHIVE:-}" ]; then
  archive="$SYMPHONY_PACKAGE_ARCHIVE"
  [ -f "$archive" ] || { echo "error: package archive not found: $archive" >&2; exit 1; }
  archive_root="$validation_root/archive"
  mkdir -p "$archive_root"
  if ! unzip -qq "$archive" -d "$archive_root"; then
    echo "error: unable to inspect package archive: $archive" >&2
    exit 1
  fi
  scan_tree "$archive_root"
fi

echo "MVP package validation passed"
"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/validate-macos-lifecycle.sh" "$application"
