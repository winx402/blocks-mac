#!/usr/bin/env python3
"""Build a disposable UI probe; not a real upgrade or Helper acceptance.

Uses the production coordinator, failure mapping and AppKit presenter with the
exact built Sparkle framework. Synthetic drains fail twice, then succeed. Open
the emitted app, click Install, Later, Cmd-R, Retry; evidence must have one saved
install continuation. No installed Blocks process, pairing or user data is used.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", type=Path, required=True)
    parser.add_argument("--preparation-delay", type=float, default=3)
    parser.add_argument("--scenario", choices=("helper", "broker"), default="helper",
                        help="synthetic failures only; neither scenario performs an upgrade")
    args = parser.parse_args()
    if not 0 < args.preparation_delay <= 30:
        raise SystemExit("preparation delay must be between 0 and 30 seconds")
    products = args.products.resolve(strict=True)
    for name in ("Sparkle.framework/Sparkle", "BlocksCore.framework/BlocksCore", "Blocks.app/Contents/Resources"):
        if not (products / name).exists():
            raise SystemExit(f"Missing built product: {name}")
    root = Path(tempfile.mkdtemp(prefix="blocks-update-recovery-probe-"))
    app = root / "Update Recovery Probe.app"
    contents = app / "Contents"
    executable = contents / "MacOS/UpdateRecoveryProbe"
    executable.parent.mkdir(parents=True)
    marker = root / "evidence.json"
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "app.blocks.updateprobe." + uuid.uuid4().hex,
        "CFBundleExecutable": executable.name, "CFBundleName": "Update Recovery Probe",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0",
        "ProbeMarker": str(marker), "ProbeDelay": args.preparation_delay,
        "ProbeScenario": args.scenario,
    }))
    frameworks = contents / "Frameworks"
    frameworks.mkdir()
    # BlocksCore is a static framework in this project; only Sparkle is embedded.
    for name in ("Sparkle.framework",):
        shutil.copytree(products / name, frameworks / name, symlinks=True)
    resources = contents / "Resources"
    resources.mkdir()
    for folder in (products / "Blocks.app/Contents/Resources").glob("*.lproj"):
        shutil.copytree(folder, resources / folder.name)
    sources = [ROOT / relative for relative in (
        "tools/verification/fixtures/AppUpdateRecoveryProbe.swift",
        "apps/Blocks/BlocksApp/Support/L10n.swift",
        "apps/Blocks/BlocksApp/App/DistributionChannel.swift",
        "apps/Blocks/BlocksApp/Services/ApplicationLifecycleCoordinator.swift",
        "apps/Blocks/BlocksApp/Services/AppUpdatePreparationPresentation.swift",
        "apps/Blocks/BlocksApp/Services/AppUpdateCoordinator.swift",
    )]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-profile-generate", "-target", "arm64-apple-macosx14.0",
                    "-F", str(products), "-framework", "BlocksCore", "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    *map(str, sources), "-o", str(executable)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    print(json.dumps({"app": str(app), "marker": str(marker), "realUpgrade": False}))


if __name__ == "__main__":
    main()
