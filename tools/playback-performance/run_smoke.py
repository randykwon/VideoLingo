#!/usr/bin/env python3
"""Compile the app model into a separate process and exercise three independent players."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 tools/playback-performance/run_smoke.py /path/to/12-second-video.mp4")
video = pathlib.Path(sys.argv[1]).resolve(strict=True)
products = root / ".build/DerivedData/Build/Products/Release"
if not (products / "VideoLingoCore.framework").exists():
    raise SystemExit("Build the Release app first (scripts/build_app.sh).")
with tempfile.TemporaryDirectory(prefix="videolingo-playback-") as directory:
    temporary = pathlib.Path(directory)
    sources = [p for p in (root / "Sources/VideoLingo").glob("*.swift") if p.name != "VideoLingoApp.swift"]
    sources += list((root / "Sources/VideoLingoTransfer").glob("*.swift"))
    snapshots = []
    for source in sources:
        target = temporary / source.name
        shutil.copy2(source, target)
        snapshots.append(str(target))
    binary = temporary / "VideoLingoPlaybackSmoke"
    subprocess.run([
        "xcrun", "swiftc", "-Onone", "-whole-module-optimization", "-parse-as-library",
        "-swift-version", "6", "-target", "arm64-apple-macos26.0", "-F", str(products),
        "-framework", "VideoLingoCore", "-Xlinker", "-rpath", "-Xlinker", str(products),
        *snapshots, str(root / "tools/playback-performance/PlaybackSmoke.swift"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary), str(video)], check=True)
