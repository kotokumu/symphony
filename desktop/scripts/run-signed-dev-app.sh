#!/bin/sh
set -eu

signing_identity=$1
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
desktop_directory=$(dirname -- "$script_directory")

cd "$desktop_directory"
swift build --product SymphonyDesktop
swift build --product SymphonyCredentialBroker

binary_directory=$(swift build --show-bin-path)
output_directory="$binary_directory/SymphonyDevelopment"
application="$output_directory/Symphony.app"
staging_directory=$(mktemp -d "$binary_directory/SymphonyDevelopment.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT

mkdir -p "$staging_directory/Symphony.app/Contents/MacOS"
mkdir -p "$staging_directory/Symphony.app/Contents/Helpers"
cp "$binary_directory/SymphonyDesktop" "$staging_directory/Symphony.app/Contents/MacOS/SymphonyDesktop"
cp "$binary_directory/SymphonyCredentialBroker" "$staging_directory/Symphony.app/Contents/Helpers/SymphonyCredentialBroker"
cp "$script_directory/SymphonyDevelopment-Info.plist" "$staging_directory/Symphony.app/Contents/Info.plist"

codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --identifier com.kotokumu.symphony.credential-broker \
  --sign "$signing_identity" \
  "$staging_directory/Symphony.app/Contents/Helpers/SymphonyCredentialBroker"
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
