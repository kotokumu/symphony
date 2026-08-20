#!/bin/sh
set -eu

signing_identity=$1
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
desktop_directory=$(dirname -- "$script_directory")

cd "$desktop_directory"
swift build --product SymphonyDesktop
swift build --product SymphonyCredentialBroker
swift build --product SymphonyCredentialStoreSmoke

binary_directory=$(swift build --show-bin-path)
output_directory="$binary_directory/SymphonyDevelopment"
application="$output_directory/Symphony.app"
staging_directory=$(mktemp -d "$binary_directory/SymphonyDevelopment.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT

mkdir -p "$staging_directory/Symphony.app/Contents/MacOS"
mkdir -p "$staging_directory/Symphony.app/Contents/Helpers"
cp "$binary_directory/SymphonyDesktop" "$staging_directory/Symphony.app/Contents/MacOS/SymphonyDesktop"
cp "$binary_directory/SymphonyCredentialBroker" "$staging_directory/Symphony.app/Contents/Helpers/SymphonyCredentialBroker"
cp "$binary_directory/SymphonyCredentialStoreSmoke" "$staging_directory/SymphonyCredentialStoreSmoke"
cp "$script_directory/SymphonyDevelopment-Info.plist" "$staging_directory/Symphony.app/Contents/Info.plist"

helper="$staging_directory/Symphony.app/Contents/Helpers/SymphonyCredentialBroker"
codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --identifier com.kotokumu.symphony.credential-broker \
  --sign "$signing_identity" \
  "$helper"
team_identifier=$(codesign -d --verbose=4 "$helper" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)
if [ -z "$team_identifier" ]; then
  echo "error: the selected signing identity does not provide an Apple Team ID" >&2
  exit 1
fi

broker_entitlements="$staging_directory/SymphonyCredentialBroker.entitlements.plist"
sed "s/__TEAM_IDENTIFIER__/$team_identifier/g" \
  "$script_directory/SymphonyCredentialBroker.entitlements.plist.template" \
  > "$broker_entitlements"
codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --identifier com.kotokumu.symphony.credential-broker \
  --entitlements "$broker_entitlements" \
  --sign "$signing_identity" \
  "$helper"

credential_store_smoke="$staging_directory/SymphonyCredentialStoreSmoke"
codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --identifier com.kotokumu.symphony.credential-broker \
  --entitlements "$broker_entitlements" \
  --sign "$signing_identity" \
  "$credential_store_smoke"

signed_entitlements="$staging_directory/SymphonyCredentialBroker.signed-entitlements.plist"
codesign -d --entitlements :- "$helper" > "$signed_entitlements" 2>/dev/null
expected_application_identifier="$team_identifier.com.kotokumu.symphony.credential-broker"
actual_application_identifier=$(
  /usr/libexec/PlistBuddy \
    -c "Print :com.apple.application-identifier" \
    "$signed_entitlements"
)
if [ "$actual_application_identifier" != "$expected_application_identifier" ]; then
  echo "error: the credential broker is missing its Data Protection Keychain entitlement" >&2
  exit 1
fi
actual_keychain_group=$(
  /usr/libexec/PlistBuddy \
    -c "Print :keychain-access-groups:0" \
    "$signed_entitlements"
)
if [ "$actual_keychain_group" != "$expected_application_identifier" ]; then
  echo "error: the credential broker has an unexpected Keychain access group" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c "Print :keychain-access-groups:1" "$signed_entitlements" >/dev/null 2>&1; then
  echo "error: the credential broker has more than one Keychain access group" >&2
  exit 1
fi

"$credential_store_smoke"

codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --sign "$signing_identity" \
  "$staging_directory/Symphony.app"
codesign --verify --deep --strict "$staging_directory/Symphony.app"

mkdir -p "$output_directory"
if [ -e "$application" ]; then
  rm -rf "$application"
fi
mv "$staging_directory/Symphony.app" "$application"
open "$application"
