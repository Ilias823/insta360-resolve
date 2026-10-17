# Insta360 Stitch for DaVinci Resolve

Edit **Insta360 X5** 360° footage directly in **DaVinci Resolve Studio** on the Mac: stitch it, reframe it into normal or vertical video, and follow subjects automatically, without exporting from Insta360 Studio first.

Free and open source. If it saves you time, you can support its development on **[Ko-fi](https://ko-fi.com/ilias823)**.

## Features

- **Import**: Workspace > Scripts > Insta360 Import turns `.insv` clips into ready-to-edit 360 clips (no re-encoding; the lens calibration is read from each file and refined automatically).
- **Stitch**: dual-fisheye to equirectangular on the GPU (Metal), with per-frame lens matching and an automatic stitch distance for close subjects.
- **Reframe**: pan, tilt, roll, field of view and distance, with Insta360 Studio-style looks (Tiny Planet, Mega View, Ultra Wide, Dewarp, Linear). Works in timelines of any shape, including vertical.
- **On-screen controls**: drag the picture to aim, drag the zoom bar to zoom (viewer set to *Open FX Overlay*).
- **Subject tracking**: put the box on a subject and press Track Subject; the view follows it as Pan/Tilt keyframes.
- **Updates**: About > Check for Updates looks for new releases here.

## Requirements

- Mac with Apple Silicon (M1 or newer), macOS 13 or later
- DaVinci Resolve Studio 21.1 or later
- Insta360 X5 footage (other models are untested)

## Install

1. Download the latest `Insta360Stitch-<version>.pkg` from [Releases](https://github.com/Ilias823/insta360-resolve/releases).
2. Quit DaVinci Resolve and double-click the installer.
3. The installer is not signed with an Apple developer certificate yet, so macOS blocks it the first time: open **System Settings > Privacy & Security** and click **Open Anyway** (on macOS 14 and earlier you can also right-click the file and choose Open).
4. Open Resolve and use **Workspace > Scripts > Insta360 Import** to bring in clips. Put a clip on a timeline and add **Effects > Open FX > Insta360 > Insta360 Stitch**.

To remove it: `sudo "/Library/Application Support/Insta360Stitch/uninstall.sh"`.

## Build from source

Needs Xcode and DaVinci Resolve (for its OpenFX SDK).

```sh
make -C plugin            # build plugin/build/Insta360Stitch.ofx.bundle
make -C plugin test       # checks that need no host application
make -C plugin install    # copy to /Library/OFX/Plugins (create it, writable, first)
tools/install_resolve_menu.sh   # Scripts menu entry using this folder's import tool
installer/build_pkg.sh    # dist/Insta360Stitch-<version>.pkg
```

`tools/` also holds the Python reference implementation (`stitch_poc.py`) and the comparison test (`compare_metal.py`) that keeps the Metal stitch in step with it; those need `numpy` and `opencv-python-headless`.

## Releasing

1. Raise `CFBundleShortVersionString` in `plugin/Info.plist`.
2. Commit and push.
3. `installer/release.sh "What is new"` builds the installer and publishes the GitHub release that Check for Updates finds.

## How it works

The X5 records the two lenses as two HEVC streams in one `.insv` file, with the factory calibration in a trailer at the end. The import copies each lens into its own `.mov` (Resolve reads one video stream per file) and builds a compound clip with lens A on the left half and lens B on the right half, a layout that holds in any timeline shape. The OpenFX plugin then stitches or reframes that compound clip using the calibration.

## Credits and licence

Licensed under the [GNU General Public License v3.0](LICENSE).

- The X5 calibration layout, lens model and seam refinement follow [insv-stitch](https://github.com/BenjaminHenriksson/insv-stitch) by Benjamin Henriksson (MIT).
- The plugin is built on the OpenFX support library (BSD) from the OpenFX SDK.

See [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). Insta360 and DaVinci Resolve are trademarks of their owners; this project is not affiliated with them.
