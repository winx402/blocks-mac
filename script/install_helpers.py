#!/usr/bin/env python3
"""Fail-closed installer for signed Blocks releases.

The release policy is deliberately local source-controlled metadata.  It is
not obtained from GitHub and never inferred from the DMG being installed.
Until a publisher records that non-secret policy, this program has no trusted
release identity and declines to download anything.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass


def rename_without_replacing(source: Path, destination: Path) -> None:
    """RENAME_EXCL also refuses a concurrently created empty directory."""
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = library.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote


REPOSITORY = "winx402/blocks-mac"
BUNDLE_ID = "app.blocks.app"
ARCHITECTURE = "arm64"
MINIMUM_MACOS = (14, 0)
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = ROOT / "script/release/install-release-policy.json"
VERSIONING_HELPER = ROOT / "script/release/release_versioning.py"
_VERSIONING: Any | None = None


class InstallError(RuntimeError):
    """An expected refusal.  The caller gets one concise, actionable error."""


class NotWritable(InstallError):
    pass


@dataclass(frozen=True)
class Policy:
    repository: str
    bundle_id: str
    team_id: str
    certificate_sha1: str
    dmg_asset_template: str


@dataclass(frozen=True)
class Release:
    tag: str
    asset_name: str
    asset_url: str
    checksum_url: str | None


def versioning() -> Any:
    """Load the publisher-owned, pure contract without duplicating SemVer rules."""
    global _VERSIONING
    if _VERSIONING is not None:
        return _VERSIONING
    try:
        specification = importlib.util.spec_from_file_location("blocks_release_versioning", VERSIONING_HELPER)
        if specification is None or specification.loader is None:
            raise ImportError("module specification unavailable")
        module = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = module
        specification.loader.exec_module(module)
    except (OSError, ImportError) as error:
        fail(f"shared release version contract is unavailable: {error}")
    if not callable(getattr(module, "parse_release_version", None)) or not callable(getattr(module, "validate_bundle_version", None)):
        fail("shared release version contract has an unsupported interface")
    _VERSIONING = module
    return module


def fail(message: str) -> None:
    raise InstallError(message)


def command(arguments: Iterable[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    command_line = list(arguments)
    # Installer trust decisions must not be redirected by a caller-controlled
    # PATH. Every tool below is supplied by macOS, not the release artifact.
    if command_line and command_line[0] in {"curl", "hdiutil", "lipo", "codesign", "openssl", "spctl", "pgrep"}:
        command_line[0] = f"/usr/bin/{command_line[0]}"
    try:
        return subprocess.run(
            command_line,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            check=False,
            timeout=120,
        )
    except FileNotFoundError as error:
        fail(f"required system tool is unavailable: {error.filename}")
    except subprocess.TimeoutExpired as error:
        fail(f"system tool timed out: {error.cmd}")


def checked(arguments: Iterable[str], description: str, *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    result = command(arguments, capture=capture)
    if result.returncode != 0:
        detail = ""
        if capture:
            detail = (result.stderr or result.stdout or "").strip().splitlines()
            detail = f" ({detail[-1]})" if detail else ""
        fail(f"{description} failed{detail}")
    return result


def policy_path() -> Path:
    override = os.environ.get("BLOCKS_INSTALL_RELEASE_CONFIG")
    return Path(override).expanduser() if override else DEFAULT_POLICY


def load_policy(path: Path) -> Policy:
    if not path.is_file() or path.is_symlink():
        fail(
            "no installable official release: trusted release policy is not configured; "
            "the publisher must add the non-secret Team/certificate pins before publishing"
        )
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"trusted release policy is unreadable: {error}")
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        fail("trusted release policy has an unsupported schema")
    required = {"repository", "bundle_id", "team_id", "certificate_sha1", "dmg_asset_template"}
    if set(document) != required | {"schema_version"}:
        fail("trusted release policy has unexpected or missing fields")
    values = {key: document[key] for key in required}
    if not all(isinstance(value, str) for value in values.values()):
        fail("trusted release policy fields must be strings")
    if values["repository"] != REPOSITORY or values["bundle_id"] != BUNDLE_ID:
        fail("trusted release policy is for a different application")
    if not re.fullmatch(r"[A-Z0-9]{10}", values["team_id"]):
        fail("trusted release policy has an invalid Apple Team ID pin")
    certificate_sha1 = values["certificate_sha1"].replace(":", "").upper()
    if not re.fullmatch(r"[A-F0-9]{40}", certificate_sha1):
        fail("trusted release policy has an invalid signing certificate pin")
    template = values["dmg_asset_template"]
    if template.count("{tag}") != 1 or not re.fullmatch(r"[A-Za-z0-9._{}-]+", template):
        fail("trusted release policy has an unsafe DMG asset template")
    return Policy(
        repository=REPOSITORY,
        bundle_id=BUNDLE_ID,
        team_id=values["team_id"],
        certificate_sha1=certificate_sha1,
        dmg_asset_template=template,
    )


def valid_tag(tag: str) -> str:
    if not isinstance(tag, str) or not tag.startswith("v"):
        fail("--version and published release tags must use v-prefixed complete SemVer")
    try:
        parsed = versioning().parse_release_version(tag[1:])
    except ValueError as error:
        fail(f"--version and published release tags must use v-prefixed complete SemVer: {error}")
    if parsed.tag != tag:
        fail("--version and published release tags must use canonical v-prefixed complete SemVer")
    return tag


def api_json(url: str) -> Any:
    with tempfile.NamedTemporaryFile(prefix="blocks-release-metadata-", suffix=".json", delete=False) as handle:
        output = Path(handle.name)
    try:
        checked(
            ["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--max-redirs", "3", "--silent", "--show-error", "--output", str(output), url],
            "GitHub Releases metadata request",
        )
        try:
            return json.loads(output.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"GitHub Releases metadata is invalid: {error}")
    finally:
        output.unlink(missing_ok=True)


def release_metadata(version: str | None) -> tuple[dict[str, Any], bool]:
    base = f"https://api.github.com/repos/{REPOSITORY}/releases"
    if version:
        payload = api_json(f"{base}/tags/{quote(valid_tag(version), safe='')}")
        if not isinstance(payload, dict):
            fail("GitHub did not return a release object for --version")
        return payload, True
    payload = api_json(f"{base}?per_page=100")
    if not isinstance(payload, list):
        fail("GitHub did not return a release list")
    for item in payload:
        if isinstance(item, dict) and item.get("draft") is False and item.get("prerelease") is False and item.get("published_at"):
            return item, False
    fail("no installable stable release is published yet")


def expected_asset_url(tag: str, asset: str) -> str:
    return f"https://github.com/{REPOSITORY}/releases/download/{quote(tag, safe='')}/{quote(asset, safe='')}"


def resolve_release(policy: Policy, version: str | None) -> Release:
    metadata, explicitly_requested = release_metadata(version)
    tag = metadata.get("tag_name")
    if not isinstance(tag, str) or valid_tag(tag) != tag:
        fail("release has an unsafe or missing tag name")
    if version and tag != version:
        fail("GitHub returned a different release tag than --version")
    if metadata.get("draft") is True:
        fail("draft releases are never installable")
    if metadata.get("prerelease") is True and not explicitly_requested:
        fail("prerelease is not selected by the stable channel; request its exact --version explicitly")
    if not metadata.get("published_at"):
        fail("release is not published")
    asset_name = policy.dmg_asset_template.replace("{tag}", tag)
    assets = metadata.get("assets")
    if not isinstance(assets, list):
        fail("release has no asset list")
    matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == asset_name]
    if len(matches) != 1:
        fail(f"published release {tag} lacks exactly one expected arm64 macOS 14+ DMG ({asset_name})")
    asset_url = matches[0].get("browser_download_url")
    if asset_url != expected_asset_url(tag, asset_name):
        fail("release asset URL is not the canonical GitHub download URL")
    checksum_name = asset_name + ".sha256"
    checksums = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == checksum_name]
    if len(checksums) > 1:
        fail("release contains ambiguous checksum assets")
    checksum_url: str | None = None
    if checksums:
        checksum_url = checksums[0].get("browser_download_url")
        if checksum_url != expected_asset_url(tag, checksum_name):
            fail("checksum asset URL is not the canonical GitHub download URL")
    return Release(tag=tag, asset_name=asset_name, asset_url=asset_url, checksum_url=checksum_url)


def download(url: str, destination: Path, description: str) -> None:
    checked(
        ["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--max-redirs", "3", "--silent", "--show-error", "--output", str(destination), url],
        f"download of {description}",
    )
    if not destination.is_file() or destination.is_symlink() or destination.stat().st_size == 0:
        fail(f"download of {description} did not create a regular non-empty file")


def verify_optional_checksum(release: Release, dmg: Path, work: Path) -> None:
    if not release.checksum_url:
        return
    checksum = work / (release.asset_name + ".sha256")
    download(release.checksum_url, checksum, "release checksum")
    try:
        fields = checksum.read_text(encoding="utf-8").strip().split()
    except OSError as error:
        fail(f"cannot read downloaded checksum: {error}")
    digest = hashlib.sha256()
    try:
        with dmg.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot read downloaded DMG for checksum verification: {error}")
    actual = digest.hexdigest()
    if len(fields) < 1 or not re.fullmatch(r"[A-Fa-f0-9]{64}", fields[0]) or fields[0].lower() != actual:
        fail("release checksum does not match the downloaded DMG")
    print("Integrity checksum verified; authentication still depends on the pinned Apple signing identity.")


def macos_version(value: object) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        fail("bundle has an invalid LSMinimumSystemVersion")
    return tuple(int(part) for part in value.split("."))


def is_at_least(actual: tuple[int, ...], minimum: tuple[int, ...]) -> bool:
    padded_actual = actual + (0,) * (len(minimum) - len(actual))
    padded_minimum = minimum + (0,) * (len(actual) - len(minimum))
    return padded_actual >= padded_minimum


def validate_bundle_symlinks(root: Path, label: str) -> None:
    """Permit only non-root, relative links whose final target stays in bundle."""
    if root.is_symlink() or not root.is_dir():
        fail(f"{label} is not a regular directory")
    try:
        resolved_root = root.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve {label} root: {error}")
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in [*directories, *files]:
            path = Path(parent) / name
            if path.is_symlink():
                relative = path.relative_to(root)
                try:
                    target_text = os.readlink(path)
                except OSError as error:
                    fail(f"cannot read {label} symbolic link {relative}: {error}")
                if os.path.isabs(target_text):
                    fail(f"{label} contains an absolute symbolic link: {relative}")
                try:
                    resolved_target = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    fail(f"{label} contains an unresolved symbolic link: {relative} ({error})")
                try:
                    resolved_target.relative_to(resolved_root)
                except ValueError:
                    fail(f"{label} symbolic link escapes the bundle: {relative}")


def app_info(app: Path, release: Release, policy: Policy) -> Path:
    validate_bundle_symlinks(app, "candidate app")
    info_path = app / "Contents/Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        fail("candidate app has no regular Contents/Info.plist")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"candidate app Info.plist is invalid: {error}")
    if info.get("CFBundleIdentifier") != policy.bundle_id:
        fail("candidate app Bundle ID does not match app.blocks.app")
    try:
        versioning().validate_bundle_version(
            release.tag,
            info.get("BLOCKS_RELEASE_NAME"),
            info.get("CFBundleShortVersionString"),
            info.get("CFBundleVersion"),
        )
    except ValueError as error:
        fail(f"candidate app version fields do not match the selected release tag: {error}")
    if not is_at_least(macos_version(info.get("LSMinimumSystemVersion")), MINIMUM_MACOS):
        fail("candidate app does not require macOS 14 or later")
    executable = info.get("CFBundleExecutable")
    if executable != "Blocks":
        fail("candidate app has an unexpected executable name")
    binary = app / "Contents/MacOS" / executable
    if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
        fail("candidate app executable is missing or not executable")
    architectures = checked(["lipo", "-archs", str(binary)], "architecture inspection", capture=True).stdout.split()
    if architectures != [ARCHITECTURE]:
        fail(f"candidate app is not arm64-only (reported: {' '.join(architectures) or 'none'})")
    return binary


def pinned_signing_identity(target: Path, policy: Policy, work: Path, label: str) -> None:
    details = checked(["codesign", "-dvv", str(target)], f"{label} signature identity inspection", capture=True)
    output = (details.stdout or "") + "\n" + (details.stderr or "")
    if re.search(rf"^TeamIdentifier={re.escape(policy.team_id)}$", output, re.MULTILINE) is None:
        fail(f"{label} signing Team ID differs from the trusted publisher pin")
    authority = re.compile(rf"^Authority=Developer ID Application: .+ \({re.escape(policy.team_id)}\)$", re.MULTILINE)
    if authority.search(output) is None:
        fail(f"{label} is not signed by a Developer ID Application certificate for the trusted Team")
    certificate_base = work / "signing-certificate"
    checked(["codesign", "-d", "--extract-certificates", str(certificate_base), str(target)], f"{label} signing certificate extraction", capture=True)
    certificate = Path(str(certificate_base) + "0")
    try:
        fingerprint = checked(["openssl", "x509", "-inform", "der", "-in", str(certificate), "-noout", "-fingerprint", "-sha1"], f"{label} signing certificate inspection", capture=True).stdout
    finally:
        certificate.unlink(missing_ok=True)
    actual = fingerprint.strip().split("=")[-1].replace(":", "").upper()
    if actual != policy.certificate_sha1:
        fail(f"{label} signing certificate differs from the trusted publisher pin")


def signing_details(app: Path, policy: Policy, work: Path) -> None:
    checked(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], "code signature verification", capture=True)
    pinned_signing_identity(app, policy, work, "candidate app")
    checked(["spctl", "--assess", "--type", "exec", "--context", "context:primary-signature", "--verbose=4", str(app)], "Gatekeeper assessment", capture=True)


def dmg_signing_details(dmg: Path, policy: Policy, work: Path) -> None:
    """Authenticate the container before its filesystem is attached."""
    checked(["codesign", "--verify", "--verbose=2", str(dmg)], "DMG code signature verification", capture=True)
    pinned_signing_identity(dmg, policy, work, "DMG")
    checked(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", str(dmg)], "DMG Gatekeeper assessment", capture=True)


def attach_dmg(dmg: Path, work: Path) -> tuple[Path, str]:
    attached = work / "attach.plist"
    requested_mount = work / "mounted-volume"
    try:
        requested_mount.mkdir()
    except OSError as error:
        fail(f"cannot prepare private DMG mount point: {error}")
    attached_successfully = False
    try:
        # A mount point we created is the only location cleanup may detach if
        # hdiutil succeeds but returns malformed metadata. Never guess a disk
        # device or globally detach another volume.
        result = checked(
            ["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", "-mountpoint", str(requested_mount), str(dmg)],
            "read-only DMG attach",
            capture=True,
        )
        attached_successfully = True
        attached.write_text(result.stdout, encoding="utf-8")
        data = plistlib.loads(attached.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        if attached_successfully:
            detach_dmg(requested_mount)
        fail(f"DMG attach metadata is invalid: {error}")
    except BaseException:
        if attached_successfully:
            detach_dmg(requested_mount)
        raise
    entities = data.get("system-entities") if isinstance(data, dict) else None
    if not isinstance(entities, list):
        detach_dmg(requested_mount)
        fail("DMG attach metadata has no system entities")
    mounts = [item.get("mount-point") for item in entities if isinstance(item, dict) and isinstance(item.get("mount-point"), str)]
    # Partitioned images can legitimately have several dev entries (whole disk
    # and partition) but there must be exactly one mounted filesystem.
    if len(mounts) != 1:
        detach_dmg(requested_mount)
        fail("DMG attach metadata does not identify exactly one mounted volume")
    if Path(mounts[0]) != requested_mount or not requested_mount.is_dir():
        detach_dmg(requested_mount)
        fail("DMG attach metadata does not identify a usable mounted volume")
    return requested_mount, ""


def detach_dmg(mount: Path) -> None:
    # Do not force-detach. A failure remains visible to the user instead of
    # risking another process using the volume.
    result = command(["hdiutil", "detach", str(mount)], capture=True)
    if result.returncode != 0:
        print(f"warning: could not detach read-only DMG at {mount}; detach it manually when no longer in use", file=sys.stderr)


def mounted_app(mount: Path) -> Path:
    entries = list(mount.iterdir())
    apps = [entry for entry in entries if entry.name == "Blocks.app" and entry.is_dir() and not entry.is_symlink()]
    if len(apps) != 1:
        fail("DMG must contain exactly one regular Blocks.app at its root")
    for entry in entries:
        if entry == apps[0]:
            continue
        if entry.name == "Applications" and entry.is_symlink() and os.readlink(entry) == "/Applications":
            continue
        fail(f"DMG contains an unexpected root entry: {entry.name}")
    return apps[0]


def safe_directory(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True)
    except PermissionError as error:
        raise NotWritable(f"cannot write {path}: {error}") from error
    except OSError as error:
        fail(f"cannot prepare application directory {path}: {error}")
    if path.is_symlink() or not path.is_dir():
        fail(f"application directory is not a regular directory: {path}")


def legacy_apps(directory: Path) -> list[Path]:
    names = ("Blocks Debug.app", "BlocksSelectionHelper.app", "Blocks Selection Helper.app")
    return [directory / name for name in names if (directory / name).exists() or (directory / name).is_symlink()]


def running(binary: Path) -> bool:
    # pgrep accepts a regular expression; escape the path before querying it.
    result = command(["pgrep", "-f", re.escape(str(binary))], capture=True)
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    detail = (result.stderr or result.stdout or "").strip().splitlines()
    suffix = f" ({detail[-1]})" if detail else ""
    fail(f"cannot determine whether Blocks is running; refusing replacement{suffix}")


def existing_managed_bundle(destination: Path, policy: Policy, work: Path) -> tuple[int, int] | None:
    """Return a stable identity only for an app this user may replace safely."""
    if not destination.exists() and not destination.is_symlink():
        return None
    if destination.is_symlink() or not destination.is_dir():
        fail("existing Blocks destination is not a regular app bundle; refusing replacement")
    try:
        validate_bundle_symlinks(destination, "existing Blocks app")
        for parent, directories, files in os.walk(destination, followlinks=False):
            for path in [Path(parent), *(Path(parent) / name for name in [*directories, *files])]:
                metadata = path.lstat()
                if metadata.st_uid != os.geteuid():
                    raise NotWritable("existing Blocks app is not wholly owned by the current user; refusing replacement")
                if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode)):
                    fail(f"existing Blocks app contains an unsupported filesystem entry: {path.relative_to(destination)}")
        info_path = destination / "Contents/Info.plist"
        if not info_path.is_file() or info_path.is_symlink():
            fail("existing Blocks app has no regular Contents/Info.plist; refusing replacement")
        info = plistlib.loads(info_path.read_bytes())
    except PermissionError as error:
        raise NotWritable(f"cannot inspect existing Blocks app safely: {error}") from error
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot inspect existing Blocks app safely: {error}")
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != policy.bundle_id:
        fail("existing Blocks destination does not belong to app.blocks.app; refusing replacement")
    executable = info.get("CFBundleExecutable")
    if executable != "Blocks":
        fail("existing Blocks app has an unexpected executable; refusing replacement")
    binary = destination / "Contents/MacOS" / executable
    if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
        fail("existing Blocks app executable is missing or not executable; refusing replacement")
    architectures = checked(["lipo", "-archs", str(binary)], "existing app architecture inspection", capture=True).stdout.split()
    if ARCHITECTURE not in architectures:
        fail("existing Blocks app is not an arm64 app; refusing replacement")
    # An existing version can legitimately differ from the selected release,
    # but its identity must still be in the same pinned publisher trust chain.
    signing_details(destination, policy, work)
    metadata = destination.lstat()
    return metadata.st_dev, metadata.st_ino


def install_to(directory: Path, candidate: Path, release: Release, policy: Policy, work: Path) -> Path:
    safe_directory(directory)
    old_items = legacy_apps(directory)
    if old_items:
        names = ", ".join(item.name for item in old_items)
        fail(f"legacy Debug/Helper installation detected ({names}); no files were changed. Remove or migrate it explicitly before installing.")
    destination = directory / "Blocks.app"
    original_identity = existing_managed_bundle(destination, policy, work)
    lock = directory / ".Blocks-official-install.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        fail("another or interrupted Blocks installation owns the install lock; inspect it before retrying")
    except PermissionError as error:
        raise NotWritable(f"cannot create install lock in {directory}: {error}") from error
    try:
        if original_identity is not None and running(destination / "Contents/MacOS/Blocks"):
            fail("Blocks is running; quit it yourself and retry. The installer will not terminate applications.")
        stage_root = Path(tempfile.mkdtemp(prefix=".Blocks-official-install-", dir=directory))
        retain_stage = False
        old_bundle_moved = False
        recovery_complete = True
        staged = stage_root / "Blocks.app"
        previous = stage_root / "previous.app"
        try:
            try:
                shutil.copytree(candidate, staged, symlinks=True)
            except OSError as error:
                fail(f"candidate copy into the installation staging area failed: {error}")
            app_info(staged, release, policy)
            signing_details(staged, policy, work)
            current_identity = existing_managed_bundle(destination, policy, work)
            if current_identity != original_identity:
                fail("Blocks destination changed during staging; refusing replacement")
            if current_identity is not None and running(destination / "Contents/MacOS/Blocks"):
                fail("Blocks started while the update was preparing; no files were changed")
            if current_identity is not None:
                # Mark recovery as required before the filesystem operation so
                # even an asynchronous interruption between rename(2) and the
                # following Python assignment cannot discard the old bundle.
                recovery_complete = False
                try:
                    rename_without_replacing(destination, previous)
                except OSError as error:
                    recovery_complete = True
                    fail(f"could not preserve the installed app before replacement: {error}")
                old_bundle_moved = True
                recovery_complete = False
            try:
                rename_without_replacing(staged, destination)
            except OSError as error:
                if old_bundle_moved and previous.exists() and not destination.exists() and not destination.is_symlink():
                    try:
                        rename_without_replacing(previous, destination)
                    except OSError as restore_error:
                        retain_stage = True
                        fail(f"new app could not be promoted ({error}); automatic restore also failed ({restore_error}); original app remains at {previous}")
                    recovery_complete = True
                    fail(f"new app could not be promoted; original app was restored: {error}")
                if old_bundle_moved:
                    retain_stage = True
                    fail(f"new app could not be promoted ({error}); original app remains at {previous} and any concurrently created destination was left untouched")
                fail(f"new app could not be promoted ({error}); no existing app was replaced")
            if old_bundle_moved:
                recovery_complete = True
        finally:
            if not recovery_complete:
                retain_stage = True
            if stage_root.exists() and not retain_stage:
                shutil.rmtree(stage_root, ignore_errors=True)
            elif stage_root.exists():
                print(f"warning: retained recovery staging directory at {stage_root}", file=sys.stderr)
    finally:
        try:
            lock.rmdir()
        except OSError:
            print(f"warning: could not remove install lock {lock}; inspect it before retrying", file=sys.stderr)
    return destination


def install(candidate: Path, release: Release, policy: Policy, work: Path) -> Path:
    system = Path("/Applications")
    user = Path.home() / "Applications"
    system_existing = system / "Blocks.app"
    user_existing = user / "Blocks.app"
    system_has_existing = system_existing.exists() or system_existing.is_symlink()
    user_has_existing = user_existing.exists() or user_existing.is_symlink()
    if system_has_existing and user_has_existing:
        fail("Blocks exists in both /Applications and ~/Applications; resolve the duplicate explicitly before updating")
    if user_has_existing:
        return install_to(user, candidate, release, policy, work)
    if system_has_existing:
        try:
            return install_to(system, candidate, release, policy, work)
        except NotWritable as error:
            fail(f"existing /Applications/Blocks.app cannot be safely managed; refusing to create a second copy in ~/Applications: {error}")
    try:
        return install_to(system, candidate, release, policy, work)
    except NotWritable:
        return install_to(user, candidate, release, policy, work)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install a verified official Blocks macOS release.")
    parser.add_argument("--version", metavar="TAG", help="install this published tag; permits an explicitly requested prerelease")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    policy = load_policy(policy_path())
    release = resolve_release(policy, args.version)
    with tempfile.TemporaryDirectory(prefix="blocks-official-install-") as temporary:
        work = Path(temporary)
        dmg = work / release.asset_name
        download(release.asset_url, dmg, "official Blocks DMG")
        verify_optional_checksum(release, dmg, work)
        dmg_signing_details(dmg, policy, work)
        mount: Path | None = None
        try:
            mount, _device = attach_dmg(dmg, work)
            candidate = mounted_app(mount)
            app_info(candidate, release, policy)
            signing_details(candidate, policy, work)
            destination = install(candidate, release, policy, work)
        finally:
            if mount is not None:
                detach_dmg(mount)
    print(f"Installed official Blocks {release.tag} at {destination}. It was not launched.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InstallError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
