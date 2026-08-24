#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 --identity SIGNING_IDENTITY --version VERSION --output DIRECTORY [--notary-profile PROFILE] [--unsigned]" >&2
  exit 2
}

signing_identity=
version=
output_directory=
notary_profile=
unsigned=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) [ "$#" -ge 2 ] || usage; signing_identity=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; version=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output_directory=$2; shift 2 ;;
    --notary-profile) [ "$#" -ge 2 ] || usage; notary_profile=$2; shift 2 ;;
    --unsigned) unsigned=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$version" ] && [ -n "$output_directory" ] || usage
if [ "$unsigned" = false ] && [ -z "$signing_identity" ]; then
  echo "error: --identity is required for a signed package" >&2
  exit 2
fi
if [ "$unsigned" = true ] && [ -n "$notary_profile" ]; then
  echo "error: --notary-profile cannot be used with --unsigned" >&2
  exit 2
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
desktop_directory=$(dirname -- "$script_directory")
repository_root=$(dirname -- "$desktop_directory")
build_number=${SYMPHONY_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}
configuration=${SYMPHONY_BUILD_CONFIGURATION:-release}
binary_directory=$(cd "$desktop_directory" && swift build -c "$configuration" --show-bin-path)

swift_build() {
  (cd "$desktop_directory" && swift build -c "$configuration" --product "$1")
}

swift_build SymphonyDesktop
swift_build SymphonyCredentialBroker

daemon_source=${SYMPHONY_DAEMON_PATH:-$repository_root/elixir/bin/symphony}
if [ ! -x "$daemon_source" ]; then
  if command -v mise >/dev/null 2>&1 && [ -f "$repository_root/elixir/mix.exs" ]; then
    (cd "$repository_root/elixir" && mise exec -- mix release symphony --overwrite)
  fi
fi
[ -x "$daemon_source" ] || {
  echo "error: Symphony daemon executable not found at $daemon_source; set SYMPHONY_DAEMON_PATH" >&2
  exit 1
}

mkdir -p "$output_directory"
staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/symphony-package.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT
application="$staging_directory/Symphony.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Helpers" "$application/Contents/bin"
cp "$binary_directory/SymphonyDesktop" "$application/Contents/MacOS/SymphonyDesktop"
cp "$binary_directory/SymphonyCredentialBroker" "$application/Contents/Helpers/SymphonyCredentialBroker"
cp "$daemon_source" "$application/Contents/bin/symphony"
chmod 755 "$application/Contents/MacOS/SymphonyDesktop" "$application/Contents/Helpers/SymphonyCredentialBroker" "$application/Contents/bin/symphony"
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD_NUMBER__/$build_number/g" \
  "$script_directory/Symphony-Info.plist.template" > "$application/Contents/Info.plist"

if [ "$unsigned" = false ]; then
  codesign --force --timestamp --options runtime --sign "$signing_identity" \
    "$application/Contents/Helpers/SymphonyCredentialBroker"
  team_identifier=$(codesign -d --verbose=4 "$application/Contents/Helpers/SymphonyCredentialBroker" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)
  [ -n "$team_identifier" ] || { echo "error: could not determine signing team" >&2; exit 1; }
  entitlements="$staging_directory/SymphonyCredentialBroker.entitlements.plist"
  sed "s/__TEAM_IDENTIFIER__/$team_identifier/g" \
    "$script_directory/SymphonyCredentialBroker.entitlements.plist.template" > "$entitlements"
  codesign --force --timestamp --options runtime --identifier com.kotokumu.symphony.credential-broker \
    --entitlements "$entitlements" --sign "$signing_identity" "$application/Contents/Helpers/SymphonyCredentialBroker"
  codesign --force --timestamp --options runtime --sign "$signing_identity" "$application/Contents/bin/symphony"
  codesign --force --timestamp --options runtime --sign "$signing_identity" "$application/Contents/MacOS/SymphonyDesktop"
  codesign --force --timestamp --options runtime --sign "$signing_identity" "$application"
  codesign --verify --deep --strict "$application"
fi

final_application="$output_directory/Symphony.app"
rm -rf "$final_application"
ditto "$application" "$final_application"
archive="$output_directory/Symphony-$version-macos.zip"
ditto -c -k --keepParent "$final_application" "$archive"
if [ -n "$notary_profile" ]; then
  xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$final_application"
  rm -f "$archive"
  ditto -c -k --keepParent "$final_application" "$archive"
fi

echo "SYMPHONY_APP=$final_application"
echo "SYMPHONY_ARCHIVE=$archive"
