#!/bin/sh
# Removes Insta360 Stitch. Run in Terminal:  sudo "/Library/Application Support/Insta360Stitch/uninstall.sh"
# Clips already imported and their lens files are left alone.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi
rm -rf "/Library/OFX/Plugins/Insta360Stitch.ofx.bundle"
rm -f "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/Insta360 Import.lua"
rm -rf "/Library/Application Support/Insta360Stitch"
pkgutil --forget org.insta360resolve.stitch >/dev/null 2>&1
echo "Insta360 Stitch removed. Restart DaVinci Resolve."
