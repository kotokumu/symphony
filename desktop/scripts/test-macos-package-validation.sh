#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(mktemp -d "${TMPDIR:-/tmp}/symphony-package-validation.XXXXXX")
trap 'rm -rf "$root"' EXIT

create_fixture() {
  application="$root/Symphony.app"
  rm -rf "$application"
  mkdir -p "$application/Contents/MacOS" "$application/Contents/Helpers" "$application/Contents/bin"
  for executable in SymphonyDesktop SymphonyCredentialBroker; do
    printf '#!/bin/sh\nexit 0\n' > "$application/Contents/$([ "$executable" = SymphonyDesktop ] && printf MacOS || printf Helpers)/$executable"
  done
  printf '#!/bin/sh\nexit 0\n' > "$application/Contents/bin/symphony"
  chmod 755 "$application/Contents/MacOS/SymphonyDesktop" \
    "$application/Contents/Helpers/SymphonyCredentialBroker" "$application/Contents/bin/symphony"
  printf '%s\n' '<?xml version="1.0"?><plist><dict/></plist>' > "$application/Contents/Info.plist"
}

assert_rejected() {
  create_fixture
  printf '%s\n' "$1" >> "$application/Contents/MacOS/SymphonyDesktop"
  if SYMPHONY_ALLOW_UNSIGNED=1 "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null 2>&1; then
    echo "error: validator accepted fixture $2" >&2
    exit 1
  fi
}

create_fixture
SYMPHONY_ALLOW_UNSIGNED=1 "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null
assert_rejected 'ghp_123456789012345678901234567890' github-token
assert_rejected 'github_pat_123456789012345678901234567890' github-pat
assert_rejected 'sk-123456789012345678901234567890' api-key
assert_rejected '-----BEGIN RSA PRIVATE KEY-----' private-key
create_fixture
touch "$application/Contents/.env"
if SYMPHONY_ALLOW_UNSIGNED=1 "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null 2>&1; then
  echo "error: validator accepted sensitive file fixture" >&2
  exit 1
fi
echo "Package security validation fixtures passed"
