#!/bin/sh
# Builds the double-click installer: dist/Insta360Stitch-<version>.pkg
#
# It installs, for all users:
#   /Library/OFX/Plugins/Insta360Stitch.ofx.bundle      the plugin and its helper programs
#   /Library/Application Support/Insta360Stitch/        the import tool and an uninstaller
#   .../DaVinci Resolve/Fusion/Scripts/Utility/Insta360 Import.lua   the Workspace > Scripts entry
# Nothing else is needed on the target Mac: the import uses Resolve's own Python and macOS's
# AVFoundation (through the plugin's MediaTool), not Homebrew, Python or ffmpeg.
set -e
cd "$(dirname "$0")"
here="$(pwd)"
project="$(cd .. && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project/plugin/Info.plist")"
support="/Library/Application Support/Insta360Stitch"
scripts_dir="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"

make -C "$project/plugin"
make -C "$project/plugin" test

stage="$here/build"
rm -rf "${stage:?}"
root="$stage/root"
mkdir -p "$root/Library/OFX/Plugins" "$root$support/tools" "$root$scripts_dir" "$stage/dist"
cp -R "$project/plugin/build/Insta360Stitch.ofx.bundle" "$root/Library/OFX/Plugins/"
# The import tool and every module it uses (standard library only besides these).
cp "$project/tools/ingest.py" "$project/tools/insv_trailer.py" "$project/tools/insv_motion.py" \
   "$project/tools/clip_tag.py" "$root$support/tools/"
# Fail here rather than on the user's Mac if a module is missing: load it the way Resolve will.
resolve_python="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolvePython"
check_python="$( [ -x "$resolve_python" ] && echo "$resolve_python" || command -v python3 )"
"$check_python" -I -c "import sys; sys.path.insert(0, '$root$support/tools'); import ingest" \
    || { echo "the packaged import tool does not load" >&2; exit 1; }
cp "$here/uninstall.sh" "$root$support/uninstall.sh"
chmod 755 "$root$support/uninstall.sh"
sed -e "s|@INGEST@|$support/tools/ingest.py|" "$project/resolve/Insta360 Import.lua" > "$root$scripts_dir/Insta360 Import.lua"

# Extended attributes would end up in the package as "._" clutter files.
xattr -cr "$root"
export COPYFILE_DISABLE=1

# Install exactly where stated: without this, Installer may "update" another copy of the
# bundle it finds elsewhere on the disk (such as a development build) instead.
pkgbuild --analyze --root "$root" "$stage/components.plist"
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$stage/components.plist"
# Always replace the installed plugin, also with a build of the same version number.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked false" "$stage/components.plist"

pkgbuild --root "$root" --component-plist "$stage/components.plist" --scripts "$here/scripts" \
    --identifier org.insta360resolve.stitch --version "$version" --install-location / \
    --ownership recommended "$stage/Insta360Stitch.pkg"

sed -e "s|@VERSION@|$version|g" "$here/distribution.xml" > "$stage/distribution.xml"
mkdir -p "$project/dist"
productbuild --distribution "$stage/distribution.xml" --resources "$here/resources" --package-path "$stage" \
    "$project/dist/Insta360Stitch-$version.pkg"
echo "built: $project/dist/Insta360Stitch-$version.pkg"
