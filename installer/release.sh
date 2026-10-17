#!/bin/sh
# Publishes a new version on GitHub, where the plugin's "Check for Updates" button finds it.
#
#   1. raise CFBundleShortVersionString in plugin/Info.plist (e.g. 0.1.0 -> 0.2.0)
#   2. commit and push your changes
#   3. installer/release.sh "What is new in this version"
#
# It builds dist/Insta360Stitch-<version>.pkg and creates the release v<version> with the
# installer attached. Needs the GitHub CLI (gh) signed in to the repository's account.
set -e
cd "$(dirname "$0")/.."
repo="Ilias823/insta360-resolve"   # keep in step with kUpdateRepo in plugin/src/StitchPlugin.cpp
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' plugin/Info.plist)"
notes="${1:?usage: installer/release.sh \"what is new in this version\"}"

if gh release view "v$version" --repo "$repo" >/dev/null 2>&1; then
    echo "v$version is already released: raise the version in plugin/Info.plist first." >&2
    exit 1
fi
installer/build_pkg.sh
gh release create "v$version" "dist/Insta360Stitch-$version.pkg" --repo "$repo" \
    --title "Insta360 Stitch $version" --notes "$notes"
echo "released v$version"
