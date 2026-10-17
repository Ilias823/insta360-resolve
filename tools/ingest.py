#!/usr/bin/env python3
"""Prepare Insta360 X5 .insv clips for DaVinci Resolve.

For each clip:
  1. split the two lens streams into <name>_lensA.mov / <name>_lensB.mov (no re-encode)
  2. write <name>.json with the lens calibration read from the file's trailer
  3. refine that calibration so the lenses line up at the seam (see tools/refine_seam.py),
     with the SeamRefine helper that ships in the plugin bundle
  4. in the running Resolve: import both files, build a double-wide timeline with the
     lenses side by side, and wrap it in a compound clip "<name> 360"

usage: ingest.py clip.insv [more.insv ...] [--out DIR] [--no-resolve] [--no-refine] [--progress]
       ingest.py --refine clip.json [more.json ...]     (step 3 only, for clips ingested before)

Uses the plugin's MediaTool when it is installed, otherwise ffmpeg/ffprobe on PATH. Step 4 needs Resolve Studio running with
Preferences > System > General > External scripting set to Local.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from insv_trailer import read_summary

RESOLVE_API = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
RESOLVE_LIB = "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
BIN_NAME = "Insta360"
# Helper programs inside the plugin bundle: the development build first, then the installed one.
BUNDLE_RESOURCES = "Insta360Stitch.ofx.bundle/Contents/Resources"
BUNDLE_DIRS = [Path(__file__).parent.parent / "plugin/build", Path("/Library/OFX/Plugins")]
REFINE_FRAMES = 10
REFINE_SIZE = 1920        # lens image size the helper expects (kWorkSize in plugin/src/SeamRefine.cpp)
VALUES_PER_LENS = 27


def media_tool():
    """The plugin's MediaTool (AVFoundation), used instead of ffmpeg when it is installed."""
    return find_bundle_tool("MediaTool")


def media_probe(path):
    done = subprocess.run([str(media_tool()), "probe", str(path)], capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip() or f"cannot read {path.name}")
    return json.loads(done.stdout)


def probe(path):
    if media_tool():
        streams = media_probe(path)["streams"]
    else:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
             "stream=index,width,height,r_frame_rate,nb_frames", "-of", "json", str(path)],
            check=True, capture_output=True, text=True).stdout
        streams = json.loads(out)["streams"]
    if len(streams) != 2:
        raise ValueError(f"{path.name}: expected 2 video streams, found {len(streams)}")
    return streams


def fps_string(rate):
    f = Fraction(rate)
    return str(f.numerator) if f.denominator == 1 else f"{float(f):.3f}".rstrip("0")


class Cancelled(Exception):
    pass


class Progress:
    """Progress bar for runs from Resolve's Scripts menu, in the plugin's TrackProgress window.

    Without a window it does nothing. update() raises Cancelled once the user presses Cancel.
    """
    def __init__(self, title, show):
        self.proc = None
        self.last_sent = 0.0
        helper = find_bundle_tool("TrackProgress") if show else None
        if helper:
            try:
                self.proc = subprocess.Popen([str(helper), title], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                os.set_blocking(self.proc.stdout.fileno(), False)
            except OSError:
                self.proc = None

    def update(self, fraction, text, force=False):
        if self.proc is None:
            return
        try:
            if b"cancel" in (os.read(self.proc.stdout.fileno(), 256) or b""):
                self.close()
                raise Cancelled()
        except BlockingIOError:
            pass
        now = time.monotonic()
        if force or now - self.last_sent >= 0.1:     # about ten updates a second is plenty
            self.last_sent = now
            try:
                self.proc.stdin.write(f"p {min(max(fraction, 0.0), 1.0):.4f} {text}\n".encode())
                self.proc.stdin.flush()
            except OSError:
                self.proc = None    # the window went away; carry on without it

    def close(self):
        if self.proc:
            try:
                self.proc.stdin.write(b"done\n")
                self.proc.stdin.close()
                self.proc.wait(2)
            except (OSError, subprocess.TimeoutExpired):
                self.proc.kill()
            self.proc = None


def run_tool_reporting(cmd, report):
    """Runs MediaTool split, passing its "progress <fraction>" lines to report(); stops it on Cancelled."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for line in proc.stdout:
            if line.startswith("progress "):
                report(float(line.split()[1]))
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    err = proc.stderr.read()
    if proc.wait() != 0:
        raise RuntimeError(f"copying the lenses failed: {err.strip()}")


def run_reporting(cmd, seconds, report):
    """Runs ffmpeg with -progress, passing the fraction done to report(); stops it on Cancelled."""
    proc = subprocess.Popen(cmd[:1] + ["-progress", "pipe:1", "-nostats"] + cmd[1:],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for line in proc.stdout:
            if line.startswith("out_time_us=") and line.strip()[12:].isdigit():
                report(int(line.strip()[12:]) / 1e6 / max(seconds, 1e-3))
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    err = proc.stderr.read()
    if proc.wait() != 0:
        raise RuntimeError(f"ffmpeg failed: {err.strip()}")


def split(src, out_dir, report=lambda fraction: None):
    """Returns (lensA, lensB, info). Skips work already done."""
    streams = probe(src)
    lens_files = [out_dir / f"{src.stem}_lens{c}.mov" for c in "AB"]
    if not all(f.exists() and f.stat().st_mtime >= src.stat().st_mtime for f in lens_files):
        # Written under temporary names, so a cancelled or failed copy is never taken as done.
        parts = [f.with_name(f.stem + ".part.mov") for f in lens_files]
        try:
            if media_tool():
                run_tool_reporting([str(media_tool()), "split", str(src)] + [str(f) for f in parts], report)
            else:
                cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src)]
                for s, f in zip(streams, parts):
                    cmd += ["-map", f"0:{s['index']}", "-c", "copy", "-tag:v", "hvc1", str(f)]
                run_reporting(cmd, duration(src), report)
            for part, f in zip(parts, lens_files):
                part.replace(f)
        finally:
            for part in parts:
                part.unlink(missing_ok=True)
    info = read_summary(str(src))
    info.update(source=src.name, width=streams[0]["width"], height=streams[0]["height"],
                fps=fps_string(streams[0]["r_frame_rate"]), frames=int(streams[0]["nb_frames"]))
    path = out_dir / f"{src.stem}.json"
    # A seam refinement made earlier from the same factory calibration is kept.
    try:
        old = json.loads(path.read_text())
        if "seam_refinement" in old and old.get("calibration_factory") == info["calibration_raw"]:
            for key in ("calibration_factory", "lenses_factory", "calibration_raw", "lenses", "seam_refinement"):
                info[key] = old[key]
    except (OSError, ValueError, KeyError):
        pass
    path.write_text(json.dumps(info, indent=2))
    return lens_files[0], lens_files[1], info


def adjusted_lenses(lenses, x):
    """Lens list with lens B's yaw, pitch, cx and cy moved by x[0..3]."""
    out = json.loads(json.dumps(lenses))
    for key, delta in zip(("yaw", "pitch", "cx", "cy"), x):
        out[1][key] += delta
    return out


def adjusted_raw(raw, x):
    """Calibration string with the same change as adjusted_lenses()."""
    values = raw.split("_")
    s = 1 + VALUES_PER_LENS     # lens B
    for offset, delta in ((5, x[0]), (6, x[1]), (3, x[2]), (4, x[3])):
        values[s + offset] = f"{float(values[s + offset]) + delta:.3f}"
    return "_".join(values)


def apply_refinement(info, x, before, after, frames):
    """Stores a seam fit (lens B yaw, pitch, cx, cy) in a clip's info, keeping the factory values.

    A fit that does not explain the misalignment well leaves the calibration unchanged.
    Returns True if the calibration was changed.
    """
    factory_raw = info.get("calibration_factory", info["calibration_raw"])
    factory_lenses = info.get("lenses_factory", info["lenses"])
    applied = after <= 0.5 * before
    info["calibration_factory"] = factory_raw
    info["lenses_factory"] = factory_lenses
    info["calibration_raw"] = adjusted_raw(factory_raw, x) if applied else factory_raw
    info["lenses"] = adjusted_lenses(factory_lenses, x) if applied else factory_lenses
    info["seam_refinement"] = {"lens": 1, "yaw": round(float(x[0]), 4), "pitch": round(float(x[1]), 4),
                               "cx": round(float(x[2]), 2), "cy": round(float(x[3]), 2), "frames": frames,
                               "misalignment_px": [round(float(before), 1), round(float(after), 1)],
                               "applied": applied}
    return applied


def duration(path):
    if media_tool():
        return float(media_probe(path)["duration"])
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return float(out)


def read_frame(path, seconds, pix_fmt="rgb24"):
    """One frame of a lens file, scaled to REFINE_SIZE square, as raw 8-bit pixels."""
    if media_tool() and pix_fmt == "rgb24":
        return subprocess.run([str(media_tool()), "frame", str(path), f"{seconds:.3f}", str(REFINE_SIZE)],
                              check=True, capture_output=True).stdout
    return subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{seconds:.3f}", "-i", str(path), "-frames:v", "1",
                           "-vf", f"scale={REFINE_SIZE}:{REFINE_SIZE}", "-f", "rawvideo", "-pix_fmt", pix_fmt, "-"],
                          check=True, capture_output=True).stdout


def refine_times(lens_a, lens_b, frames):
    """Frame times spread through the clip, as refine_seam.py picks them."""
    length = min(duration(lens_a), duration(lens_b))
    return [length * (i + 0.5) / frames for i in range(frames)]


def find_bundle_tool(name):
    for folder in BUNDLE_DIRS:
        if (folder / BUNDLE_RESOURCES / name).exists():
            return folder / BUNDLE_RESOURCES / name
    return None


def measure_seam(lens_a, lens_b, factory_raw, frames=REFINE_FRAMES, helper=None, report=lambda fraction: None):
    """Runs the SeamRefine helper on frames of the clip; returns its fit as a dict."""
    helper = helper or find_bundle_tool("SeamRefine")
    if helper is None:
        raise RuntimeError("SeamRefine helper not found: install the plugin (make -C plugin install)")
    paths = [p for t in refine_times(lens_a, lens_b, frames) for p in ((lens_a, t), (lens_b, t))]
    proc = subprocess.Popen([str(helper), factory_raw, str(frames)], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        # Decoding is the slow part, so several frames decode at once; they reach the helper in order.
        with ThreadPoolExecutor(4) as pool:
            # The pipe holds little, so a pair is written once the helper has measured the one before.
            for k, data in enumerate(pool.map(lambda p: read_frame(*p), paths)):
                proc.stdin.write(data)
                report(k / len(paths))
    except BrokenPipeError:
        pass
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    out, err = proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"SeamRefine failed: {err.decode().strip()}")
    return json.loads(out)


def refine(path, lens_a, lens_b, report=lambda fraction: None):
    """Measures and stores the seam refinement in the clip's .json; returns a message."""
    info = json.loads(path.read_text())
    fit = measure_seam(lens_a, lens_b, info.get("calibration_factory", info["calibration_raw"]), report=report)
    x = [fit["yaw"], fit["pitch"], fit["cx"], fit["cy"]]
    before, after = fit["misalignment_px"]
    applied = apply_refinement(info, x, before, after, fit["frames"])
    path.write_text(json.dumps(info, indent=2))
    if not applied:
        return f"seam calibration left unchanged (fit {before:.1f} -> {after:.1f} px)"
    return f"seam calibration refined, {before:.1f} -> {after:.1f} px"


def refine_existing(paths):
    """--refine: refines .json files written by an earlier run, next to their lens files."""
    failed = 0
    for path in paths:
        try:
            stem = path.name[:-len(".json")] if path.name.endswith(".json") else path.stem
            lens_a, lens_b = (path.with_name(f"{stem}_lens{c}.mov") for c in "AB")
            print(f"{path.name}: {refine(path, lens_a, lens_b)}")
        except Exception as e:
            failed += 1
            print(f"{path.name}: FAILED: {e}", file=sys.stderr)
    return 1 if failed else 0


def connect():
    os.environ.setdefault("RESOLVE_SCRIPT_API", RESOLVE_API)
    os.environ.setdefault("RESOLVE_SCRIPT_LIB", RESOLVE_LIB)
    sys.path.append(os.environ["RESOLVE_SCRIPT_API"] + "/Modules")
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        raise RuntimeError("could not reach DaVinci Resolve: is it running, with external "
                           "scripting set to Local in Preferences > System > General?")
    project = resolve.GetProjectManager().GetCurrentProject()
    if project is None:
        raise RuntimeError("no project is open in Resolve")
    return project


def get_bin(pool):
    root = pool.GetRootFolder()
    for f in root.GetSubFolderList() or []:
        if f.GetName() == BIN_NAME:
            return f
    return pool.AddSubFolder(root, BIN_NAME)


def build(project, lens_a, lens_b, info, name):
    pool = project.GetMediaPool()
    folder = get_bin(pool)
    pool.SetCurrentFolder(folder)
    compound_name = f"{name} 360"
    if any(c.GetName() == compound_name for c in folder.GetClipList() or []):
        return f"'{compound_name}' already in bin, skipped"

    if project.GetTimelineCount() == 0:
        project.SetSetting("timelineFrameRate", info["fps"])
    clips = pool.ImportMedia([str(lens_a), str(lens_b)])
    if not clips or len(clips) != 2:
        raise RuntimeError(f"{name}: Resolve did not import both lens files")
    a = next(c for c in clips if c.GetName() == lens_a.name)
    b = next(c for c in clips if c.GetName() == lens_b.name)

    timeline = pool.CreateEmptyTimeline(f"{name} dual")
    if timeline is None:
        raise RuntimeError(f"{name}: could not create timeline (name already used?)")
    width, height = 2 * info["width"], info["height"]
    timeline.SetSetting("useCustomSettings", "1")
    timeline.SetSetting("timelineResolutionWidth", str(width))
    timeline.SetSetting("timelineResolutionHeight", str(height))
    if float(timeline.GetSetting("timelineFrameRate")) != float(info["fps"]):
        timeline.SetSetting("timelineFrameRate", info["fps"])
    warning = ""
    if float(timeline.GetSetting("timelineFrameRate")) != float(info["fps"]):
        warning = (f" (WARNING: timeline is {timeline.GetSetting('timelineFrameRate')} fps, "
                   f"clip is {info['fps']} fps)")

    timeline.AddTrack("video")
    start = timeline.GetStartFrame()
    item_a = pool.AppendToTimeline([{"mediaPoolItem": a, "trackIndex": 1, "recordFrame": start}])[0]
    item_b = pool.AppendToTimeline([{"mediaPoolItem": b, "trackIndex": 2, "recordFrame": start}])[0]
    # Resolve re-renders a compound clip at the resolution of whatever timeline it is used in,
    # so the layout must not depend on the frame shape: stretch each lens over the whole frame,
    # squeeze it to half the width, and slide it a quarter of the width to its side. That puts
    # lens A exactly on the left half and lens B on the right half in any timeline.
    # (With stretch scaling, Pan is in pixels of this timeline; Resolve rescales it with the frame.)
    for item, side in ((item_a, -1), (item_b, 1)):
        item.SetProperty("Scaling", 4)       # stretch frame to all corners
        item.SetProperty("ZoomGang", False)
        item.SetProperty("ZoomX", 0.5)
        item.SetProperty("ZoomY", 1.0)
        item.SetProperty("Pan", side * width / 4.0)
    compound = timeline.CreateCompoundClip([item_a, item_b], {"name": compound_name})
    if compound is None:
        raise RuntimeError(f"{name}: could not create compound clip")
    return f"'{compound_name}' created, {width}x{height} @ {info['fps']}{warning}"


def notify(lines):
    """Shows the result in a macOS dialog, for runs started from Resolve's Scripts menu."""
    text = "\n".join(lines).replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(["osascript", "-e", f'display dialog "{text}" with title "Insta360 Import" '
                    'buttons {"OK"} default button 1'], capture_output=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("clips", nargs="+", type=Path)
    ap.add_argument("--out", type=Path, help="folder for the lens files (default: 'insta360_ingest' beside each clip)")
    ap.add_argument("--no-resolve", action="store_true", help="only split and write the calibration file")
    ap.add_argument("--no-refine", action="store_true", help="keep the factory calibration as it is")
    ap.add_argument("--refine", action="store_true", help="only refine the seam calibration of the given .json files")
    ap.add_argument("--notify", action="store_true", help="show the result in a dialog when done (implies --progress)")
    ap.add_argument("--progress", action="store_true", help="show a progress window while working")
    ap.add_argument("--report", type=Path, help="write one tab-separated line per clip for the Scripts-menu entry: "
                    "name, lens A, lens B, width, height, fps, note (or FAILED and a message)")
    args = ap.parse_args()
    if args.refine:
        return refine_existing(args.clips)

    results, failed, rows = [], 0, []
    try:
        project = None if args.no_resolve else connect()
    except Exception as e:
        results.append(f"FAILED: {e}")
        print(results[-1], file=sys.stderr)
        if args.notify:
            notify(results)
        return 1

    progress = Progress("Insta360 Import", args.progress or args.notify)
    for i, src in enumerate(args.clips):
        def stage(start, end, text):
            """Reporter for one step of this clip, which takes the bar from start to end."""
            prefix = f"Clip {i + 1} of {len(args.clips)}: " if len(args.clips) > 1 else ""
            def report(fraction, force=False):
                f = min(max(fraction, 0.0), 1.0)
                progress.update((i + start + (end - start) * f) / len(args.clips), f"{prefix}{text} {f:.0%}", force)
            report(0.0, True)     # a new step always shows, however quickly the one before went
            return report

        try:
            out_dir = args.out or src.parent / "insta360_ingest"
            out_dir.mkdir(parents=True, exist_ok=True)
            lens_a, lens_b, info = split(src, out_dir, stage(0.0, 0.45, "copying the lenses"))
            msg = f"split to {out_dir}"
            # Before the import, so the plugin reads the refined calibration from the start.
            # Without the helper the clip still works, with the factory calibration.
            note = ""
            if not args.no_refine and "seam_refinement" not in info:
                try:
                    report = stage(0.45, 0.95, "lining up the lenses")
                    note = "; " + refine(out_dir / f"{src.stem}.json", lens_a, lens_b, report)
                except Cancelled:
                    raise
                except Exception as e:
                    note = f"; seam calibration not refined: {e}"
            rows.append([src.stem, str(lens_a.resolve()), str(lens_b.resolve()), str(info["width"]),
                         str(info["height"]), str(info["fps"]), note.lstrip("; ")])
            if project:
                stage(0.95, 1.0, "adding to Resolve")
                msg = build(project, lens_a.resolve(), lens_b.resolve(), info, src.stem)
            results.append(f"{src.name}: {msg}{note}")
            print(results[-1])
        except Cancelled:
            failed += 1
            skipped = ", ".join(c.name for c in args.clips[i:])
            results.append(f"Cancelled; not imported: {skipped}")
            rows.append(["FAILED", results[-1]])
            print(results[-1], file=sys.stderr)
            break
        except Exception as e:  # keep going with the remaining clips
            failed += 1
            results.append(f"{src.name}: FAILED: {e}")
            rows.append(["FAILED", results[-1]])
            print(results[-1], file=sys.stderr)
    progress.close()
    if args.report:
        args.report.write_text("".join("\t".join(c.replace("\t", " ").replace("\n", " ") for c in r) + "\n" for r in rows))
    if args.notify:
        if project and failed < len(args.clips):
            results.append("\nThe clips are in the 'Insta360' bin. Add the Insta360 Stitch effect to use them.")
        notify(results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
