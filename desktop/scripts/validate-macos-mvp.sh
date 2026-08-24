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

if find "$application" -type f -print0 | xargs -0 strings 2>/dev/null | grep -E -q 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'; then
  echo "error: a credential-like value was found in the application bundle" >&2
  exit 1
fi

if [ -n "${SYMPHONY_PACKAGE_ARCHIVE:-}" ] && [ -f "$SYMPHONY_PACKAGE_ARCHIVE" ]; then
  if unzip -Z1 "$SYMPHONY_PACKAGE_ARCHIVE" | grep -E -q '(^|/)(\.env|.*\.(pem|key|p8|p12|log))$'; then
    echo "error: sensitive file type found in the package archive" >&2
    exit 1
  fi
  if unzip -p "$SYMPHONY_PACKAGE_ARCHIVE" 2>/dev/null | strings | grep -E -q 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'; then
    echo "error: a credential-like value was found in the package archive" >&2
    exit 1
  fi
fi
if [ -n "${SYMPHONY_PACKAGE_ARCHIVE:-}" ] && [ ! -f "$SYMPHONY_PACKAGE_ARCHIVE" ]; then
  echo "error: package archive not found: $SYMPHONY_PACKAGE_ARCHIVE" >&2
  exit 1
fi
if find "$application" -type f \( -name '*.env' -o -name '*.pem' -o -name '*.key' -o -name '*.p8' -o -name '*.p12' -o -name '*.log' \) -print -quit | grep -q .; then
  echo "error: sensitive file type found in the application bundle" >&2
  exit 1
fi

echo "MVP package validation passed"
"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/validate-macos-lifecycle.sh" "$application"
