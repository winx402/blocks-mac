#!/usr/bin/env python3
"""Exercise real shell install logic with temporary bundles, no App launch."""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "script/stable_app_install.sh"
ENTRY = ROOT / "script/build_and_run.sh"

HARNESS = r'''
set -euo pipefail
source "$1"
APP_NAME=Blocks
STABLE_APP_DIR="$2/installed"
APP_BUNDLE="$STABLE_APP_DIR/Blocks.app"
BUILT_APP_BUNDLE="$2/built/Blocks.app"
CASE="$3"
TRACE="$2/trace"
ditto() {
  echo copy >> "$TRACE"
  command cp -R "$1" "$2"
  [[ "$CASE" != copy_failure ]]
}
codesign() {
  echo verify >> "$TRACE"
  [[ "$CASE" != signature_failure ]]
}
stop_stable_app() {
  echo stop >> "$TRACE"
  if [[ "$CASE" == destination_changed ]]; then
    command mv "$APP_BUNDLE" "$STABLE_APP_DIR/relocated.app"
    ln -s "$STABLE_APP_DIR/relocated.app" "$APP_BUNDLE"
  fi
  # Also verify that the callback's parent-shell bookkeeping survives.
  STOP_RECORDED=1
  [[ "$CASE" != stop_failure ]]
}
mv() {
  echo "move:${1##*/}" >> "$TRACE"
  if [[ "$1" == "$APP_BUNDLE" && "$CASE" == backup_failure ]]; then
    return 1
  fi
  if [[ "$1" == */.Blocks-install.*/Blocks.app && ( "$CASE" == promotion_failure || "$CASE" == restore_failure ) ]]; then
    return 1
  fi
  if [[ "$1" == */previous.app && "$CASE" == restore_failure ]]; then
    return 1
  fi
  command mv "$@"
}
STOP_RECORDED=0
if install_stable_app; then
  [[ "$STOP_RECORDED" == 1 ]]
else
  exit 1
fi
'''


def bundle(path: Path, content: str, executable: bool = True) -> None:
    binary = path / "Contents/MacOS/Blocks"
    binary.parent.mkdir(parents=True)
    binary.write_text(content)
    binary.chmod(0o755 if executable else 0o644)


def run_case(case: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="blocks-install-self-test-") as tmp:
        root = Path(tmp)
        installed = root / "installed/Blocks.app"
        built = root / "built/Blocks.app"
        bundle(built, "new", executable=case != "missing_executable")
        installed.parent.mkdir()
        if case != "fresh_install":
            bundle(installed, "old")
        if case == "symlink_destination":
            installed.rename(installed.parent / "original.app")
            installed.symlink_to(installed.parent / "original.app")
        if case == "busy_install":
            (installed.parent / ".Blocks-install.lock").mkdir()
        result = subprocess.run(
            ["/bin/bash", "-c", HARNESS, "fixture", str(INSTALL), str(root), case],
            text=True, capture_output=True, timeout=15, check=False,
        )
        trace = (root / "trace").read_text().splitlines() if (root / "trace").exists() else []
        binary = installed / "Contents/MacOS/Blocks"
        contents = binary.read_text() if binary.is_file() else None
        backups = list(installed.parent.glob(".Blocks-install.*/previous.app/Contents/MacOS/Blocks"))
        success = case in {"success", "fresh_install"}
        assert (result.returncode == 0) == success, (case, result.stderr)
        if success:
            assert contents == "new" and trace[:3] == ["copy", "verify", "stop"], (case, trace)
        elif case == "restore_failure":
            assert contents is None and len(backups) == 1 and backups[0].read_text() == "old"
            assert "previous bundle retained" in result.stderr
        elif case == "destination_changed":
            assert installed.is_symlink()
            assert (installed.parent / "relocated.app/Contents/MacOS/Blocks").read_text() == "old"
        else:
            assert contents == "old", (case, contents, result.stderr)
        if case in {"copy_failure", "signature_failure", "missing_executable", "symlink_destination", "busy_install"}:
            assert "stop" not in trace, (case, trace)
        if case != "restore_failure":
            assert not [path for path in installed.parent.glob(".Blocks-install.*") if path.name != ".Blocks-install.lock"], case
        assert (installed.parent / ".Blocks-install.lock").exists() == (case == "busy_install"), case
        return {"case": case, "ok": True, "trace": trace}


def main() -> None:
    reports = [run_case(case) for case in (
        "success", "fresh_install", "copy_failure", "signature_failure",
        "missing_executable", "stop_failure", "backup_failure",
        "promotion_failure", "restore_failure", "symlink_destination",
        "destination_changed", "busy_install",
    )]
    # No usable PATH: argument rejection/help must not reach any external tool,
    # including signing, runtime enumeration, build, install or launch.
    with tempfile.TemporaryDirectory(prefix="blocks-install-args-") as tmp:
        for args, expected in ((["--unknown"], 2), ([""], 2), (["run", "extra"], 2), (["--help"], 0)):
            result = subprocess.run(
                ["/bin/bash", str(ENTRY), *args],
                env={**os.environ, "PATH": tmp},
                text=True, capture_output=True, timeout=5, check=False,
            )
            assert result.returncode == expected, (args, result.stderr)
            assert "usage:" in result.stdout + result.stderr
            assert "command not found" not in result.stderr
            reports.append({"case": "arguments:" + repr(args), "ok": True})

    with tempfile.TemporaryDirectory(prefix="blocks-install-build-failure-") as tmp:
        root = Path(tmp)
        (root / "script").mkdir()
        shutil.copy2(ENTRY, root / "script/build_and_run.sh")
        shutil.copy2(INSTALL, root / "script/stable_app_install.sh")
        shims = root / "bin"
        shims.mkdir()
        for name, body in {
            "security": "#!/bin/bash\nif [[ $1 == find-identity ]]; then echo '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA Apple Development'; fi\n",
            "xcodebuild": "#!/bin/bash\nexit 65\n",
        }.items():
            path = shims / name
            path.write_text(body)
            path.chmod(0o755)
        installed = root / "installed/Blocks.app"
        bundle(installed, "old")
        result = subprocess.run(
            ["/bin/bash", "-x", str(root / "script/build_and_run.sh"), "--verify"],
            env={"HOME": tmp, "PATH": f"{shims}:/usr/bin:/bin", "BLOCKS_STABLE_APP_DIR": str(installed.parent), "BLOCKS_USE_STABLE_SIGNING": "1", "BLOCKS_DEVELOPMENT_TEAM": "TEST_TEAM"},
            text=True, capture_output=True, timeout=10, check=False,
        )
        assert result.returncode == 65, result.stderr
        assert (installed / "Contents/MacOS/Blocks").read_text() == "old"
        assert "\n+ stop_stable_app\n" not in result.stderr
        assert "\n+ install_stable_app\n" not in result.stderr
        reports.append({"case": "entry_build_failure_preserves_host_and_install", "ok": True})

        (shims / "security").write_text("#!/bin/bash\necho '0 valid identities found'\n")
        for signing_mode in ("auto", "0", "1"):
            result = subprocess.run(
                ["/bin/bash", "-x", str(root / "script/build_and_run.sh"), "run"],
                env={"HOME": tmp, "PATH": f"{shims}:/usr/bin:/bin", "BLOCKS_USE_STABLE_SIGNING": signing_mode},
                text=True, capture_output=True, timeout=10, check=False,
            )
            assert result.returncode == 66, result.stderr
            assert "ad-hoc fallback is not supported" in result.stderr
            assert "\n+ xcodebuild " not in result.stderr
            assert "\n+ rm -rf " not in result.stderr
            assert "Library/Caches/BlocksDev/DerivedData.noindex/Blocks" in result.stderr
            assert (installed / "Contents/MacOS/Blocks").read_text() == "old"
            reports.append({"case": "unsigned_preflight:" + signing_mode, "ok": True})

    # A synthetic ad-hoc bundle exercises actual ditto/codesign/mv without
    # accessing a developer certificate, real App data, TCC or any live host.
    with tempfile.TemporaryDirectory(prefix="blocks-install-real-tools-") as tmp:
        root = Path(tmp)
        built = root / "built/Blocks.app"
        binary = built / "Contents/MacOS/Blocks"
        binary.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", binary)
        binary.chmod(0o755)
        (built / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "app.blocks.install-fixture",
            "CFBundleExecutable": "Blocks", "CFBundlePackageType": "APPL",
        }))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(built)], check=True, capture_output=True, timeout=10)
        result = subprocess.run(
            ["/bin/bash", "-c", 'set -euo pipefail; source "$1"; APP_NAME=Blocks; STABLE_APP_DIR="$2/installed"; APP_BUNDLE="$STABLE_APP_DIR/Blocks.app"; BUILT_APP_BUNDLE="$2/built/Blocks.app"; stop_stable_app() { :; }; install_stable_app', "fixture", str(INSTALL), tmp],
            text=True, capture_output=True, timeout=15, check=False,
        )
        assert result.returncode == 0, result.stderr
        installed = root / "installed/Blocks.app"
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], check=True, capture_output=True, timeout=10)
        assert (installed / "Contents/MacOS/Blocks").read_bytes() == binary.read_bytes()
        reports.append({"case": "real_tools_adhoc_bundle_no_launch", "ok": True})
    print(json.dumps({"ok": True, "cases": reports}, indent=2))


if __name__ == "__main__":
    main()
