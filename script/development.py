#!/usr/bin/env python3
"""Stable local Blocks installation, with optional pinned certificate signing."""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import platform
import pwd
import plistlib
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "script"))
import development_signing as signing
HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
DERIVED = HOME / "Library/Caches/BlocksDev/LocalDevelopment.noindex"
DESTINATION = HOME / "Applications/Blocks.app"
LEGACY_DESTINATION = HOME / "Applications/BlocksDev/Local/Blocks Dev.app"
MANIFEST = HOME / "Library/Application Support/Blocks Dev/Installation/peers.json"
EMPTY_ENTITLEMENTS = ROOT / "apps/Blocks/BlocksApp/Blocks-LocalDevelopment.entitlements"
RENAME_EXCL = 0x00000004


def run(command: list[str], *, capture=False, timeout=900) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, timeout=timeout)
    return result.stdout if capture else ""


def doctor() -> None:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise RuntimeError("LocalDevelopment currently requires an Apple Silicon Mac.")
    selected = run(["xcode-select", "-p"], capture=True).strip()
    if "CommandLineTools" in selected:
        raise RuntimeError("Select full Xcode; Command Line Tools alone are not sufficient.")
    version = run(["xcodebuild", "-version"], capture=True)
    match = re.search(r"Xcode (\d+)\.", version)
    if not match or int(match[1]) < 26:
        raise RuntimeError("This source requires Xcode 26 or newer and a supported build-host macOS.")
    for tool in ("codesign", "ditto", "plutil", "git"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"Required tool is missing: {tool}")
    print(version.strip())
    profile = signing.configuration()
    label = "pinned certificate " + profile['identity'] if profile['mode'] == 'certificate' else "ad-hoc (rebuilds may require permission approval)"
    print(f"Configuration: LocalDevelopment; {label}; app.blocks.dev; no provisioning profile.")
    print("Official app data, credentials, and installation are not used.")


def build() -> Path:
    doctor()
    sys.path.insert(0, str(ROOT / "tools/verification"))
    from verification_build_helpers import isolated_build_registration
    with isolated_build_registration(DERIVED, "LocalDevelopment", ("Blocks.app", "Blocks Dev.app", "Blocks Selection Helper.app")):
        for scheme in ("Blocks", "BlocksCLI", "BlocksSelectionHelper"):
            run(["xcodebuild", "-project", str(ROOT / "apps/Blocks/Blocks.xcodeproj"),
                 "-scheme", scheme, "-configuration", "LocalDevelopment", "-destination",
                 "platform=macOS,arch=arm64", "-derivedDataPath", str(DERIVED),
                 "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=",
                 "BLOCKS_MAIN_APP_DEVELOPMENT_PROFILE=", "-quiet", "build"])
    return DERIVED / "Build/Products/LocalDevelopment"


def ensure_real_directory(path: Path) -> None:
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise RuntimeError(f"Refusing a symlink in the development install path: {part}")
    path.mkdir(parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid():
        raise RuntimeError(f"Directory is not owned by the current user: {path}")


def running_local_processes() -> list[int]:
    output = run(["/bin/ps", "-axo", "pid=,comm="], capture=True)
    found = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and any(fields[1].startswith(str(path) + "/") for path in (DESTINATION, LEGACY_DESTINATION)):
            found.append(int(fields[0]))
    return found


def update_plist(path: Path, change) -> None:
    data = plistlib.loads(run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)], capture=True).encode())
    change(data)
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))


def rename_display(bundle: Path, name: str) -> None:
    def change(data):
        data["CFBundleDisplayName"] = name
        data["CFBundleName"] = name
    update_plist(bundle / "Contents/Info.plist", change)
    for strings in (bundle / "Contents/Resources").glob("*.lproj/InfoPlist.strings"):
        update_plist(strings, change)


def sign(path: Path, identifier: str, entitlements: Path | None = None) -> None:
    args = ["/usr/bin/codesign", "--force", "--sign", signing.identity(), "--timestamp=none", "--identifier", identifier]
    if entitlements is not None:
        args += ["--entitlements", str(entitlements), "--generate-entitlement-der"]
    run([*args, str(path)])


def signature(path: Path) -> dict[str, str]:
    result = subprocess.run(["/usr/bin/codesign", "-dvvv", str(path)], capture_output=True, text=True, check=True)
    values = dict(line.split("=", 1) for line in result.stderr.splitlines() if "=" in line)
    signing.validate_metadata(values)
    return values


def resign_nested_code(bundle: Path) -> None:
    # Preserve each nested component's sandbox/flags, but regenerate its
    # requirement from the pinned certificate (never preserve an old cdhash DR).
    components = []
    for path in bundle.rglob("*"):
        if path.is_symlink():
            continue  # Framework version symlinks refer to the real file below.
        if path.is_dir() and path.suffix in (".framework", ".xpc", ".app"):
            components.append(path)
        elif path.is_file():
            with path.open("rb") as stream:
                header = stream.read(8)
            thin = header[:4] in (b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe")
            fat = header[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") and 0 < int.from_bytes(header[4:8], "big") <= 16
            if thin or fat:
                components.append(path)
    for component in sorted(components, key=lambda path: len(path.parts), reverse=True):
        if component.is_symlink():
            raise RuntimeError("Nested code bundle must not be a symlink.")
        run(["/usr/bin/codesign", "--force", "--sign", signing.identity(), "--timestamp=none",
             "--preserve-metadata=identifier,entitlements,flags,runtime", str(component)])
        signature(component)


def verify_upgrade_identity(previous: Path, staged: Path) -> None:
    signing.verify_stable_upgrade(previous, staged)


def promote_without_replacing(source: Path, destination: Path) -> None:
    """macOS-only atomic promotion that never replaces a raced destination."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    renamex_np = libc.renamex_np
    renamex_np.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    renamex_np.restype = ctypes.c_int
    if renamex_np(os.fsencode(source), os.fsencode(destination), RENAME_EXCL) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def install_development(products: Path) -> None:
    ensure_real_directory(DESTINATION.parent)
    lock = DESTINATION.parent / ".BlocksDev-install.lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as error:
        raise RuntimeError("Another or interrupted Blocks installation owns the lock.") from error
    try:
        _install_development_locked(products)
    finally:
        try:
            lock.rmdir()
        except OSError:
            pass


def _install_development_locked(products: Path) -> None:
    if running_local_processes():
        raise RuntimeError("Quit Blocks and the previous Blocks Dev before replacing this local build; no process was killed.")
    if DESTINATION.exists() and LEGACY_DESTINATION.exists():
        raise RuntimeError("Both old and new local install paths exist; review them before replacing either.")
    existing = DESTINATION if DESTINATION.exists() else LEGACY_DESTINATION if LEGACY_DESTINATION.exists() else None
    if existing is not None:
        if existing.is_symlink() or existing.stat().st_uid != os.getuid():
            raise RuntimeError("Refusing an unowned or linked existing destination.")
        info = plistlib.loads((existing / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "app.blocks.dev":
            raise RuntimeError("Destination has a different Blocks identity; refusing to replace it.")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(existing)])
    staging_root = HOME / "Library/Caches/BlocksDev/DevelopmentInstall.noindex"
    ensure_real_directory(staging_root)
    stage = Path(tempfile.mkdtemp(prefix=".BlocksDev-install-", dir=staging_root))
    staged = stage / "Blocks.app"
    previous = stage / "previous.app"
    previous_manifest = stage / "previous-manifest.json"
    manifest_stage = stage / "peers.json"
    promoted = False
    committed = False
    staged_identity = None
    new_manifest_identity = None
    manifest_identity = None
    original_identity = None
    if existing is not None:
        source_stat = existing.stat()
        original_identity = (source_stat.st_dev, source_stat.st_ino)
    destination_identity = path_identity(DESTINATION)
    try:
        run(["/usr/bin/ditto", str(products / "Blocks.app"), str(staged)])
        helper = staged / "Contents/Helpers/Blocks Selection Helper.app"
        helper.parent.mkdir(parents=True, exist_ok=True)
        run(["/usr/bin/ditto", str(products / "Blocks Selection Helper.app"), str(helper)])
        cli = staged / "Contents/Resources/CLI/blocks"
        cli.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(products / "blocks", cli)
        wrapper = cli.with_name("blocks-dev")
        wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(str(DESTINATION / "Contents/Resources/CLI/blocks")) + ' "$@"\n')
        wrapper.chmod(0o755)
        rename_display(staged, "Blocks")
        rename_display(helper, "Blocks Helper")
        # A distinct build receipt makes repeated installations distinguishable
        # without changing product identity or pretending an unchanged code hash
        # proves permission retention across an upgrade.
        update_plist(staged / "Contents/Info.plist", lambda data: data.update(
            BlocksLocalBuildIdentifier=str(uuid.uuid4())
        ))
        def helper_info(data):
            for item in data.get("CFBundleURLTypes", []):
                item["CFBundleURLName"] = "app.blocks.dev.selection-helper"
                item["CFBundleURLSchemes"] = ["blocks-dev-selection-helper"]
        update_plist(helper / "Contents/Info.plist", helper_info)
        agents = staged / "Contents/Library/LaunchAgents"
        original_agent = agents / "app.blocks.action-broker.plist"
        agent = plistlib.loads(original_agent.read_bytes())
        agent.update(AssociatedBundleIdentifiers=["app.blocks.dev"], Label="app.blocks.dev.action-broker",
                     MachServices={"app.blocks.dev.action-broker.xpc": True})
        (agents / "app.blocks.dev.action-broker.plist").write_bytes(plistlib.dumps(agent))
        original_agent.unlink()
        resign_nested_code(staged)
        sign(cli, "app.blocks.dev.cli")
        sign(helper, "app.blocks.dev.selection-helper", EMPTY_ENTITLEMENTS)
        sign(staged / "Contents/MacOS/BlocksClipboardBroker", "app.blocks.dev.clipboard-broker", EMPTY_ENTITLEMENTS)
        sign(staged / "Contents/MacOS/BlocksActionBroker", "app.blocks.dev.action-broker", EMPTY_ENTITLEMENTS)
        sign(staged, "app.blocks.dev", EMPTY_ENTITLEMENTS)
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)])
        if existing is not None:
            verify_upgrade_identity(existing, staged)
        # Build the manifest from the verified staged bundle before any host
        # replacement. A manifest failure must leave the old app untouched.
        peers = []
        for role, relative in {
            "app": "Contents/MacOS/Blocks", "cli": "Contents/Resources/CLI/blocks",
            "broker": "Contents/MacOS/BlocksActionBroker",
            "helper": "Contents/Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper",
        }.items():
            identity = signature(staged / relative)
            expected_identifier = {
                "app": "app.blocks.dev", "cli": "app.blocks.dev.cli",
                "broker": "app.blocks.dev.action-broker", "helper": "app.blocks.dev.selection-helper",
            }[role]
            if identity.get("Identifier") != expected_identifier or re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", identity.get("CDHash", "")) is None:
                raise RuntimeError(f"Invalid staged development identity for {role}.")
            peers.append(dict(role=role, identifier=identity["Identifier"], relativeExecutablePath=relative, cdHash=identity["CDHash"]))
        ensure_real_directory(MANIFEST.parent)
        manifest_stage.write_text(json.dumps(dict(schemaVersion=1, appBundlePath=str(DESTINATION), peers=peers)), encoding="utf-8")
        manifest_stage.chmod(stat.S_IRUSR | stat.S_IWUSR)
        staged_identity = path_identity(staged)
        new_manifest_identity = path_identity(manifest_stage)
        manifest_identity = path_identity(MANIFEST)
        if manifest_identity is not None:
            metadata = MANIFEST.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
                raise RuntimeError("Existing development manifest is not a private owned regular file.")
            shutil.copy2(MANIFEST, previous_manifest)
        if running_local_processes():
            raise RuntimeError("Blocks started during staging; refusing replacement.")
        if path_identity(DESTINATION) != destination_identity or path_identity(MANIFEST) != manifest_identity or (existing is not None and path_identity(existing) != original_identity):
            raise RuntimeError("Development app or manifest changed during staging; refusing replacement.")
        if existing is not None:
            promote_without_replacing(existing, previous)
        promote_without_replacing(staged, DESTINATION)
        promoted = True
        if path_identity(MANIFEST) != manifest_identity:
            raise RuntimeError("Development manifest changed during promotion; refusing replacement.")
        os.replace(manifest_stage, MANIFEST)
        committed = True
        print(f"Installed isolated local build: {DESTINATION}")
        if previous.exists():
            print(f"Previous development app retained for recovery: {previous}")
    except BaseException:
        # Inspect actual inodes, including an interruption immediately after a
        # rename but before its Python state flag is assigned. Never move an
        # unrelated concurrent destination into our recovery directory.
        if not committed:
            try:
                if staged_identity is not None and path_identity(DESTINATION) == staged_identity:
                    promote_without_replacing(DESTINATION, staged)
                    promoted = True  # Retain this new bundle for diagnosis.
                if previous.exists() and existing is not None and path_identity(existing) is None:
                    promote_without_replacing(previous, existing)
                current_manifest = path_identity(MANIFEST)
                if new_manifest_identity is not None and current_manifest == new_manifest_identity:
                    if previous_manifest.exists():
                        os.replace(previous_manifest, MANIFEST)
                    else:
                        promote_without_replacing(MANIFEST, manifest_stage)
            except OSError as recovery_error:
                print(f"Recovery requires review; retained {stage}: {recovery_error}", file=sys.stderr)
            print(f"Installation did not complete; recovery material: {stage}", file=sys.stderr)
        raise
    finally:
        # Never discard the only recoverable old app, even after interruption.
        if not previous.exists() and not promoted:
            shutil.rmtree(stage, ignore_errors=True)
    # Development entry installs but never launches as part of this transaction.


def path_identity(path: Path) -> tuple[int, int] | None:
    try:
        metadata = path.lstat()
        return metadata.st_dev, metadata.st_ino
    except FileNotFoundError:
        return None


def test() -> None:
    doctor()
    # The existing test scheme runs an isolated test host (BLOCKS_UNIT_TESTING).
    # Production-policy tests do not require a signing identity or profile.
    sys.path.insert(0, str(ROOT / "tools/verification"))
    from verification_build_helpers import isolated_build_registration
    derived = DERIVED / "Tests"
    with isolated_build_registration(derived, "DebugTesting", ("Blocks.app", "Blocks Selection Helper.app")):
        result = run_isolated_tests(derived)
    print("PASS: isolated XCTest completed; " + json.dumps(result.get("process_cleanup", {}), sort_keys=True))


def run_isolated_tests(derived: Path) -> dict:
    from verification_build_helpers import controlled_build_failure, run_controlled_xcode_build, run_controlled_xcode_test
    print("Building the isolated XCTest host (no signing credentials required)...", flush=True)
    build_result = run_controlled_xcode_build(["xcodebuild", "-project", str(ROOT / "apps/Blocks/Blocks.xcodeproj"), "-scheme", "BlocksAppTests", "-configuration", "DebugTesting", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "-parallel-testing-enabled", "NO", "build-for-testing"], cwd=ROOT, timeout=1800, retry_cleaned_ibtoold=True)
    if not build_result["ok"]:
        print(build_result.get("stdout", ""), file=sys.stderr); print(build_result.get("stderr", ""), file=sys.stderr); print(build_result.get("process_cleanup", {}), file=sys.stderr)
        raise RuntimeError(controlled_build_failure(build_result))
    runs = list(derived.glob("Build/Products/**/*.xctestrun"))
    if len(runs) != 1: raise RuntimeError("controlled build-for-testing did not produce exactly one xctestrun")
    print("XCTest host built; executing isolated tests...", flush=True)
    result = run_controlled_xcode_test(["xcodebuild", "test-without-building", "-xctestrun", str(runs[0]), "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO", "-quiet"], cwd=ROOT, timeout=1800)
    if not result["ok"]:
        print(result.get("stdout", ""), file=sys.stderr); print(result.get("stderr", ""), file=sys.stderr); print(result.get("process_cleanup", {}), file=sys.stderr)
        raise RuntimeError("controlled test-without-building failed")
    print(result.get("stdout", ""))
    if build_result.get("incremental_retry"):
        print("Build passed after one controlled incremental retry (not a first-attempt pass).")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("doctor", "build", "run", "test", "update"), nargs="?", default="run")
    args = parser.parse_args()
    try:
        if args.command == "doctor": doctor()
        elif args.command == "test": test()
        else:
            if args.command == "update":
                if run(["git", "status", "--porcelain"], capture=True).strip():
                    raise RuntimeError("Commit or resolve local changes before update; nothing was stashed or overwritten.")
                run(["git", "pull", "--ff-only"])
            products = build()
            if args.command != "build":
                install_development(products)
                run(["/usr/bin/open", "-n", str(DESTINATION)])
        return 0
    except (RuntimeError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
