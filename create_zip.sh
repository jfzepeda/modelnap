#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
app="$root/dist/Napkin.app"
cli="$app/Contents/Resources/napkin"

if [ ! -x "$cli" ] || ! cmp -s "$root/cli/napkin" "$cli"; then
    printf 'Rebuild dist/Napkin.app: its bundled CLI is missing or outdated.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
archive="$root/dist/Napkin-$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
printf 'Created %s\n' "$archive"
