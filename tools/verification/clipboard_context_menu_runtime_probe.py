#!/usr/bin/env python3
"""Build a disposable NSHostingView/pointer-overlay menu probe, not user data.

Use --baseline <commit> for a frozen before/after comparison. Real pointer
interaction must be performed through CUA; this script never synthesizes input.
The menu is synthetic; this proves routing, not the complete production menu.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
POINTER = "apps/Blocks/BlocksApp/Features/Clipboard/Records/ClipboardRecordPointerSurface.swift"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="blocks-pointer-probe-"))
    pointer = ROOT / POINTER
    if args.baseline:
        snapshot = subprocess.run(["git", "show", f"{args.baseline}:{POINTER}"], cwd=ROOT, check=True, capture_output=True).stdout
        pointer = root / "ClipboardRecordPointerSurface.swift"
        pointer.write_bytes(snapshot)
    app = root / "Clipboard Pointer Probe.app"
    contents = app / "Contents"
    binary = contents / "MacOS/PointerProbe"
    binary.parent.mkdir(parents=True)
    marker = root / "evidence.json"
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "app.blocks.pointerprobe." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name, "CFBundleName": "Clipboard Pointer Probe",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0", "ProbeMarker": str(marker),
    }))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-DDEBUG", "-target", "arm64-apple-macosx14.0",
                    str(pointer), str(ROOT / "tools/verification/fixtures/ClipboardContextMenuProbe.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    print(json.dumps({"app": str(app), "marker": str(marker), "baseline": args.baseline}))


if __name__ == "__main__":
    main()
