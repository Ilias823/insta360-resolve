#!/bin/sh
# Adds "Insta360 Import" to DaVinci Resolve's Workspace > Scripts menu for this user, using the
# import tool in this folder (for development; the installer package sets it up for everyone).
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
mkdir -p "$dest"
sed -e "s|@INGEST@|$here/tools/ingest.py|" "$here/resolve/Insta360 Import.lua" > "$dest/Insta360 Import.lua"
echo "installed: $dest/Insta360 Import.lua"
