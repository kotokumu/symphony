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
assert_rejected '-----BEGIN EC PRIVATE KEY-----' ec-private-key
assert_rejected '-----BEGIN OPENSSH PRIVATE KEY-----' openssh-private-key
for extension in env pem key p8 p12 log; do
  create_fixture
  touch "$application/Contents/secret.$extension"
  if SYMPHONY_ALLOW_UNSIGNED=1 "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null 2>&1; then
    echo "error: validator accepted sensitive file fixture .$extension" >&2
    exit 1
  fi
done

create_fixture
archive="$root/Symphony-fixture-macos.zip"
(cd "$root" && zip -qr "$archive" Symphony.app)
unzip -q "$archive" -d "$root/archive-fixture"
printf '%s\n' 'github_pat_123456789012345678901234567890' \
  >> "$root/archive-fixture/Symphony.app/Contents/MacOS/SymphonyDesktop"
(cd "$root/archive-fixture" && rm -f "$archive" && zip -qr "$archive" Symphony.app)
if SYMPHONY_ALLOW_UNSIGNED=1 SYMPHONY_PACKAGE_ARCHIVE="$archive" \
  "$script_directory/validate-macos-mvp.sh" "$root/archive-fixture/Symphony.app" >/dev/null 2>&1; then
  echo "error: validator accepted secret in archive fixture" >&2
  exit 1
fi

create_fixture
printf '%s\n' 'unreadable' > "$application/Contents/unreadable.bin"
chmod 000 "$application/Contents/unreadable.bin"
if SYMPHONY_ALLOW_UNSIGNED=1 "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null 2>&1; then
  echo "error: validator accepted unreadable fixture" >&2
  exit 1
fi
create_fixture
printf '%s\n' 'not a zip archive' > "$root/corrupt.zip"
if SYMPHONY_ALLOW_UNSIGNED=1 SYMPHONY_PACKAGE_ARCHIVE="$root/corrupt.zip" \
  "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null 2>&1; then
  echo "error: validator accepted corrupt archive fixture" >&2
  exit 1
fi
if SYMPHONY_ALLOW_UNSIGNED=1 SYMPHONY_PACKAGE_ARCHIVE="$root/missing.zip" \
  "$script_directory/validate-macos-mvp.sh" "$application" >/dev/null 2>&1; then
  echo "error: validator accepted missing archive fixture" >&2
  exit 1
fi
echo "Package security validation fixtures passed"
