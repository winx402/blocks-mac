#!/usr/bin/env python3
"""Fail-closed local Developer ID release entry point.

This program deliberately has no GitHub token, private key, or Keychain access
of its own.  It only names locally configured tools/profiles after all trust
and identity pins are present.  `--dry-run` stops before every mutation.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, asdict
from contextlib import contextmanager
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from typing import Sequence
import plistlib
import stat
from release_versioning import ReleaseVersion, parse_release_version, validate_bundle_version

ROOT = Path(__file__).resolve().parents[2]
POLICY_DEFAULT = ROOT / "script/release/install-release-policy.json"
SAFE_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SAFE_REF = re.compile(r"^[A-Za-z0-9_.-]+$")
SAFE_PATH = re.compile(r"^[A-Za-z0-9_.+/-]+$")
SPARKLE_OUTPUT = re.compile(r'^sparkle:edSignature="([A-Za-z0-9+/]+={0,2})" length="([1-9][0-9]*)"$')
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


class ReleaseError(RuntimeError):
    pass


@contextmanager
def release_transaction_lock(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    lock = directory / ".release-transaction.lock"
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ReleaseError("another or interrupted release owns the transaction lock; inspect it before retrying") from error
    try:
        yield
    finally:
        lock.rmdir()


def validate_distribution_profile(profile: dict, *, uuid: str, team: str,
                                  bundle_id: str, certificate: str | None = None) -> None:
    entitlements = profile.get("Entitlements", {})
    expiration = profile.get("ExpirationDate")
    if (profile.get("UUID", "").lower() != uuid.lower()
            or profile.get("TeamIdentifier") != [team]
            or profile.get("ProvisionsAllDevices") is not True
            or "ProvisionedDevices" in profile
            or not isinstance(expiration, datetime)
            or expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)
            or entitlements.get("com.apple.application-identifier") != f"{team}.{bundle_id}"
            or entitlements.get("com.apple.developer.team-identifier") != team
            or entitlements.get("get-task-allow", False) is not False):
        raise ReleaseError("profile is not a current matching Developer ID distribution profile")
    # TN3125: a profile authorizes groups (including TEAM.*); the signed app
    # must still claim only its exact audited groups, never that wildcard.
    groups = entitlements.get("keychain-access-groups", [])
    needed = {f"{team}.app.blocks.selection-helper.shared"}
    if bundle_id == "app.blocks.app":
        needed.add(f"{team}.app.blocks.app")
    if not isinstance(groups, list) or any(not isinstance(group, str) for group in groups):
        raise ReleaseError("profile has invalid Keychain group authorization")
    if any(group not in needed | {f"{team}.*"} for group in groups) or (
            f"{team}.*" not in groups and not needed.issubset(groups)):
        raise ReleaseError("profile does not authorize the expected Keychain groups")
    if certificate is not None:
        hashes = {hashlib.sha1(item).hexdigest().upper() for item in profile.get("DeveloperCertificates", []) if isinstance(item, bytes)}
        if certificate.replace(":", "").upper() not in hashes:
            raise ReleaseError("profile does not authorize the pinned Developer ID certificate")


def run(command: Sequence[str], *, cwd: Path = ROOT, capture: bool = True) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=capture)
    if result.returncode:
        raise ReleaseError("command failed: {}\n{}".format(" ".join(command), (result.stderr or result.stdout or "").strip()))
    return result.stdout or ""


@dataclass(frozen=True)
class Policy:
    repository: str
    bundle_id: str
    team_id: str
    certificate_sha1: str
    dmg_asset_template: str


@dataclass
class ReleaseState:
    version: str
    release_name: str
    build_number: str
    channel: str
    commit: str
    tag: str
    asset: str
    checksum_asset: str
    sha256: str
    sparkle_signature: str
    sparkle_public_key: str
    size_bytes: int
    status: str


def load_policy(path: Path) -> Policy:
    if not path.is_file():
        raise ReleaseError(f"release policy is missing: {path}; refusing to infer release identity")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"release policy is unreadable: {error}") from error
    required = {"schema_version", "repository", "bundle_id", "team_id", "certificate_sha1", "dmg_asset_template"}
    if set(data) != required or data.get("schema_version") != 1:
        raise ReleaseError("release policy must use exactly schema_version=1 and the installer policy fields")
    if not all(isinstance(data[key], str) for key in required - {"schema_version"}):
        raise ReleaseError("release policy fields must be strings")
    policy = Policy(**{key: data[key] for key in required - {"schema_version"}})
    if (policy.repository != "winx402/blocks-mac" or policy.bundle_id != "app.blocks.app"
            or not re.fullmatch(r"[A-Z0-9]{10}", policy.team_id)
            or not re.fullmatch(r"[A-Fa-f0-9]{40}", policy.certificate_sha1.replace(":", ""))
            or policy.dmg_asset_template.count("{tag}") != 1
            or not re.fullmatch(r"[A-Za-z0-9._{}-]+", policy.dmg_asset_template)):
        raise ReleaseError("release policy has invalid or placeholder identity fields")
    return policy


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def committed_relative_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or not value or any(part in {"", ".", ".."} for part in path.parts):
        raise ReleaseError("--notes-file must be a committed repository-relative path")
    return path


@contextmanager
def frozen_worktree(commit: str, identity_relative: Path, identity_contents: str):
    temporary_root = Path(tempfile.mkdtemp(prefix="blocks-release-source-"))
    source_root = temporary_root / "source"
    try:
        created = subprocess.run(["git", "worktree", "add", "--detach", str(source_root), commit], cwd=ROOT, text=True, capture_output=True)
        if created.returncode:
            raise ReleaseError(f"cannot create detached release worktree: {created.stderr.strip()}")
        resolved = subprocess.run(["git", "rev-parse", "HEAD"], cwd=source_root, text=True, capture_output=True)
        if resolved.returncode or resolved.stdout.strip() != commit:
            raise ReleaseError("detached release worktree is not bound to prepared commit")
        destination = source_root / identity_relative
        if destination.exists() or destination.is_symlink():
            raise ReleaseError("frozen source unexpectedly contains the ignored release identity path")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(identity_contents, encoding="utf-8")
        destination.chmod(0o600)
        yield source_root
    finally:
        if source_root.exists():
            subprocess.run(["git", "worktree", "remove", "--force", str(source_root)], cwd=ROOT, text=True, capture_output=True)
        shutil.rmtree(temporary_root, ignore_errors=True)


def parse_sparkle_output(output: str) -> tuple[str, int]:
    match = SPARKLE_OUTPUT.fullmatch(output.strip())
    if not match:
        raise ReleaseError('sign_update must output exactly sparkle:edSignature="BASE64" length="N"')
    try:
        signature = base64.b64decode(match.group(1), validate=True)
    except ValueError as error:
        raise ReleaseError("sign_update emitted an invalid base64 EdDSA signature") from error
    if len(signature) != 64:
        raise ReleaseError("sign_update emitted an EdDSA signature with an invalid length")
    return match.group(1), int(match.group(2))


def sparkle_public_key(value: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except ValueError as error:
        raise ReleaseError("BLOCKS_SPARKLE_PUBLIC_KEY must be base64-encoded") from error
    if len(decoded) != 32:
        raise ReleaseError("BLOCKS_SPARKLE_PUBLIC_KEY must decode to a 32-byte Ed25519 public key")
    return decoded


def verify_ed25519_signature(dmg: Path, encoded_public_key: str, encoded_signature: str) -> None:
    public_key = sparkle_public_key(encoded_public_key)
    try:
        signature = base64.b64decode(encoded_signature, validate=True)
    except ValueError as error:
        raise ReleaseError("Sparkle signature is invalid base64") from error
    if len(signature) != 64:
        raise ReleaseError("Sparkle signature is not an Ed25519 signature")
    # SubjectPublicKeyInfo for Ed25519 is a stable 12-byte ASN.1 prefix plus
    # the 32 raw public-key bytes. OpenSSL verifies the exact DMG bytes.
    der = bytes.fromhex("302a300506032b6570032100") + public_key
    with tempfile.TemporaryDirectory(prefix="blocks-sparkle-verify-") as directory:
        key = Path(directory) / "public.der"
        signature_path = Path(directory) / "signature.bin"
        key.write_bytes(der)
        signature_path.write_bytes(signature)
        result = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(key), "-rawin", "-in", str(dmg), "-sigfile", str(signature_path)], text=True, capture_output=True)
    if result.returncode:
        raise ReleaseError("Sparkle Ed25519 verification failed for the exact DMG bytes")


class Pipeline:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.version: ReleaseVersion = parse_release_version(args.version)
        inferred_channel = "beta" if self.version.is_prerelease else "stable"
        if args.channel is not None and args.channel != inferred_channel:
            raise ReleaseError("--channel must agree with whether VERSION is a prerelease")
        self.args.channel = inferred_channel
        self.policy = load_policy(Path(args.policy))
        self.release_name = self.version.release_name
        self.tag = self.version.tag
        self.appcast_path = args.appcast_path or f"appcast/{inferred_channel}.xml"
        # The updater defaults to stable even in a beta package. Selecting the
        # beta feed is an explicit user preference, not a channel side effect.
        self.appcast_url = "https://winx402.github.io/blocks-mac/appcast/stable.xml"
        self.asset = self.policy.dmg_asset_template.replace("{tag}", self.tag)
        if Path(self.asset).name != self.asset or not self.asset.endswith(".dmg"):
            raise ReleaseError("dmg_asset_template must render one .dmg filename")
        self.checksum_asset = f"{self.asset}.sha256"
        self.state_path = Path(args.state_dir).expanduser() / f"{self.tag}.json"

    def dry(self, message: str) -> None:
        print(f"DRY-RUN: {message}")

    def git(self, *arguments: str) -> str:
        return run(["git", *arguments])

    def preflight_checkout(self) -> str:
        origin = self.git("remote", "get-url", "origin").strip()
        accepted = {f"https://github.com/{self.policy.repository}.git", f"git@github.com:{self.policy.repository}.git"}
        if origin not in accepted:
            raise ReleaseError("origin does not match release policy; refusing a secret-bearing release flow")
        if self.git("status", "--porcelain=v1", "--untracked-files=all").strip():
            raise ReleaseError("checkout is not clean; prepare requires an already committed, clean checkout")
        commit = self.git("rev-parse", "HEAD").strip()
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ReleaseError("cannot bind release to a committed HEAD")
        return commit

    def preflight_remote_absence(self) -> None:
        # A nonzero ls-remote is the expected "tag absent" response.
        result = subprocess.run(["git", "ls-remote", "--exit-code", "--tags", "origin", f"refs/tags/{self.tag}"], cwd=ROOT, text=True, capture_output=True)
        if result.returncode == 0 or result.stdout.strip():
            raise ReleaseError(f"tag already exists: {self.tag}; releases are never overwritten")
        if result.returncode != 2:
            raise ReleaseError(f"cannot determine whether remote tag exists: {result.stderr.strip()}")
        release = subprocess.run(["gh", "release", "view", self.tag, "--repo", self.policy.repository, "--json", "tagName"], cwd=ROOT, text=True, capture_output=True)
        if release.returncode == 0:
            raise ReleaseError(f"GitHub release already exists: {self.tag}; releases are never overwritten")
        if "not found" in release.stderr.lower():
            return
        raise ReleaseError(f"cannot determine whether GitHub release exists: {release.stderr.strip()}")

    def verify_remote_tag(self, commit: str) -> None:
        result = subprocess.run(["git", "ls-remote", "origin", f"refs/tags/{self.tag}", f"refs/tags/{self.tag}^{{}}"], cwd=ROOT, text=True, capture_output=True)
        if result.returncode:
            raise ReleaseError(f"cannot verify remote release tag: {result.stderr.strip()}")
        targets = [line.split()[0] for line in result.stdout.splitlines() if len(line.split()) == 2]
        if not targets or commit not in targets:
            raise ReleaseError("remote release tag is absent or does not resolve to the prepared commit")

    def identity_preflight(self) -> dict[str, str]:
        identity_file = Path(self.args.identity_file)
        if not identity_file.is_file():
            raise ReleaseError(f"ReleaseIdentity is missing: {identity_file}")
        contents = identity_file.read_text(encoding="utf-8")
        team = re.search(r"^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]+)\s*$", contents, re.MULTILINE)
        if not team or team.group(1) != self.policy.team_id:
            raise ReleaseError("ReleaseIdentity DEVELOPMENT_TEAM is absent or differs from the pinned policy team")
        values = {
            "identity": os.environ.get("BLOCKS_DEVELOPER_ID_APPLICATION", ""),
            "certificate": os.environ.get("BLOCKS_EXPECTED_SIGNING_CERT_SHA1", "").replace(":", "").upper(),
            "notary_profile": os.environ.get("BLOCKS_NOTARY_KEYCHAIN_PROFILE", ""),
            "sparkle_public_key": os.environ.get("BLOCKS_SPARKLE_PUBLIC_KEY", ""),
            "sparkle_account": os.environ.get("BLOCKS_SPARKLE_KEYCHAIN_ACCOUNT", ""),
        }
        if values["sparkle_account"] != "app.blocks.app.sparkle":
            raise ReleaseError("BLOCKS_SPARKLE_KEYCHAIN_ACCOUNT must be app.blocks.app.sparkle")
        if not re.fullmatch(rf"Developer ID Application: .+ \({self.policy.team_id}\)", values["identity"]):
            raise ReleaseError("BLOCKS_DEVELOPER_ID_APPLICATION is missing or not the pinned Developer ID authority")
        if values["certificate"] != self.policy.certificate_sha1.replace(":", "").upper():
            raise ReleaseError("BLOCKS_EXPECTED_SIGNING_CERT_SHA1 is missing or differs from policy")
        if not values["notary_profile"]:
            raise ReleaseError("BLOCKS_NOTARY_KEYCHAIN_PROFILE is missing; no notarization profile is locked")
        if "YOUR_" in values["sparkle_public_key"]:
            raise ReleaseError("BLOCKS_SPARKLE_PUBLIC_KEY is missing or a placeholder; refusing to make a fake Sparkle release")
        sparkle_public_key(values["sparkle_public_key"])
        if not shutil.which(self.args.sparkle_sign_tool):
            raise ReleaseError(f"Sparkle signing tool is unavailable: {self.args.sparkle_sign_tool}")
        for role, bundle_id in (("main", "app.blocks.app"), ("helper", "app.blocks.selection-helper")):
            prefix = "BLOCKS_" + role.upper()
            uuid = os.environ.get(prefix + "_DISTRIBUTION_PROFILE_UUID", "")
            profile = Path(os.environ.get(prefix + "_DISTRIBUTION_PROFILE_PATH", ""))
            if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", uuid) or not profile.is_file():
                raise ReleaseError(f"{prefix}_DISTRIBUTION_PROFILE_UUID/PATH are required")
            decoded = run(["security", "cms", "-D", "-i", str(profile)])
            validate_distribution_profile(plistlib.loads(decoded.encode()), uuid=uuid,
                                          team=self.policy.team_id, bundle_id=bundle_id,
                                          certificate=self.policy.certificate_sha1)
            values[role + "_profile_uuid"] = uuid
        if values["main_profile_uuid"] == values["helper_profile_uuid"]:
            raise ReleaseError("main and Helper must use distinct distribution profiles")
        return values

    def verify_app_sparkle_configuration(self, app: Path, expected_public_key: str) -> None:
        info_path = app / "Contents/Info.plist"
        try:
            info = plistlib.loads(info_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            raise ReleaseError(f"cannot read final app Info.plist for Sparkle verification: {error}") from error
        actual = info.get("SUPublicEDKey")
        if not isinstance(actual, str):
            raise ReleaseError("final app is missing SUPublicEDKey; Sparkle public key is not connected")
        sparkle_public_key(actual)
        if actual != expected_public_key:
            raise ReleaseError("final app SUPublicEDKey differs from BLOCKS_SPARKLE_PUBLIC_KEY")
        if info.get("SUFeedURL") != self.appcast_url:
            raise ReleaseError("final app SUFeedURL differs from the selected channel appcast")
        if info.get("SUEnableInstallerLauncherService") is not True:
            raise ReleaseError("final app does not enable Sparkle installer launcher service")

    def verify_stable_appcast_exists(self) -> None:
        if self.args.channel != "beta":
            return
        endpoint = f"repos/{self.args.appcast_repository}/contents/appcast/stable.xml"
        try:
            current = json.loads(run(["gh", "api", "--method", "GET", endpoint, "-f", f"ref={self.args.appcast_branch}"]))
            xml = base64.b64decode(current["content"]).decode("utf-8")
            if ET.fromstring(xml).find("channel") is None:
                raise ValueError("channel missing")
        except (KeyError, ValueError, ET.ParseError, UnicodeDecodeError, ReleaseError) as error:
            raise ReleaseError("beta release requires a valid published stable appcast, not a missing/404 feed") from error

    def save(self, state: ReleaseState) -> None:
        if self.args.dry_run:
            return
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        lock = self.state_path.with_suffix(".lock")
        try:
            lock.mkdir()
        except FileExistsError as error:
            raise ReleaseError("release state is busy in another process; refusing concurrent mutation") from error
        try:
            temporary = self.state_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(asdict(state), sort_keys=True, indent=2) + "\n", encoding="utf-8")
            os.replace(temporary, self.state_path)
        finally:
            lock.rmdir()

    def load_state(self) -> ReleaseState:
        if not self.state_path.is_file():
            raise ReleaseError(f"release state is missing: {self.state_path}; cannot safely publish an unknown draft")
        try:
            return ReleaseState(**json.loads(self.state_path.read_text(encoding="utf-8")))
        except (OSError, TypeError, json.JSONDecodeError) as error:
            raise ReleaseError(f"release state is invalid: {error}") from error

    def pinned_sparkle_public_key(self) -> str:
        value = os.environ.get("BLOCKS_SPARKLE_PUBLIC_KEY", "")
        if "YOUR_" in value:
            raise ReleaseError("BLOCKS_SPARKLE_PUBLIC_KEY is missing or a placeholder")
        sparkle_public_key(value)
        return value

    def verify_notary_profile(self, profile: str) -> None:
        # Read-only authentication check. It deliberately runs before any
        # build/upload so a typo cannot leave a half-prepared public release.
        try:
            run(["xcrun", "notarytool", "history", "--keychain-profile", profile, "--output-format", "json"])
        except ReleaseError as error:
            raise ReleaseError("BLOCKS_NOTARY_KEYCHAIN_PROFILE is unavailable or cannot authenticate") from error

    def prepare(self) -> None:
        if self.args.dry_run:
            commit = self.preflight_checkout()
            self.dry(f"would prepare {self.release_name} from frozen commit {commit}; no mutation")
            return
        with release_transaction_lock(self.state_path.parent):
            commit = self.preflight_checkout()
            identity = self.identity_preflight()
            identity_file = Path(self.args.identity_file).resolve()
            relative_identity = Path("apps/Blocks/Config/ReleaseIdentity.local.xcconfig")
            if identity_file != (ROOT / relative_identity).resolve():
                raise ReleaseError("release identity must use the fixed ignored configuration path")
            ignored = subprocess.run(["git", "check-ignore", "--quiet", str(relative_identity)], cwd=ROOT)
            if ignored.returncode != 0:
                raise ReleaseError("release identity must remain git-ignored")
            notes_relative = committed_relative_path(self.args.notes_file or f"release-notes/{self.release_name}.md")
            tracked = subprocess.run(["git", "cat-file", "-e", f"{commit}:{notes_relative.as_posix()}"], cwd=ROOT, capture_output=True)
            if tracked.returncode != 0:
                raise ReleaseError("release notes must exist in the prepared commit")
            with frozen_worktree(commit, relative_identity, identity_file.read_text(encoding="utf-8")) as source_root:
                self._prepare_frozen(commit, identity, source_root, notes_relative)

    def _prepare_frozen(self, commit: str, identity: dict[str, str], source_root: Path, notes_relative: Path) -> None:
        published_builds: list[int] = []
        for appcast in ("appcast/stable.xml", "appcast/beta.xml"):
            try:
                payload = json.loads(run(["gh", "api", "--method", "GET", f"repos/{self.args.appcast_repository}/contents/{appcast}", "-f", f"ref={self.args.appcast_branch}"]))
                feed = ET.fromstring(base64.b64decode(payload["content"]).decode("utf-8"))
                if feed.tag != "rss" or feed.find("channel") is None:
                    raise ValueError("invalid appcast root")
                published_builds.extend(int(entry.attrib[f"{{{SPARKLE_NS}}}version"]) for entry in feed.findall("./channel/item/enclosure"))
            except (ReleaseError, KeyError, ValueError, ET.ParseError, UnicodeDecodeError) as error:
                raise ReleaseError("cannot establish monotonic build evidence from published appcasts") from error
        local_builds = []
        for state_file in self.state_path.parent.glob("v*.json"):
            try: local_builds.append(int(json.loads(state_file.read_text(encoding="utf-8"))["build_number"]))
            except (OSError, KeyError, ValueError, json.JSONDecodeError) as error: raise ReleaseError("local release state is invalid; cannot establish monotonic build evidence") from error
        maximum = max([0, *published_builds, *local_builds])
        if self.args.build_number is None:
            self.args.build_number = str(maximum + 1)
        if int(self.args.build_number) <= maximum:
            raise ReleaseError("build number must be strictly greater than local and published release evidence")
        self.verify_notary_profile(identity["notary_profile"])
        self.verify_stable_appcast_exists()
        self.preflight_remote_absence()
        if self.state_path.exists():
            raise ReleaseError(f"release state already exists: {self.state_path}; inspect it instead of replacing a transaction")
        output = ROOT / "dist" / "release" / self.release_name
        output.mkdir(parents=True, exist_ok=False)
        helper_dd = output / "DerivedData-Helper"
        app_dd = output / "DerivedData-App"
        env = os.environ | {"BLOCKS_HELPER_DERIVED_DATA": str(helper_dd), "BLOCKS_RELEASE_DERIVED_DATA": str(app_dd)}
        def invoke(command: list[str]) -> None:
            result = subprocess.run(command, cwd=source_root, text=True, env=env)
            if result.returncode:
                raise ReleaseError("release build step failed: " + " ".join(command))
        helper = helper_dd / "Build/Products/Release/Blocks Selection Helper.app"
        app = app_dd / "Build/Products/Release/Blocks.app"
        invoke(["bash", "script/release/build_selection_helper_beta.sh", "--provisioning-profile", identity["helper_profile_uuid"], "--version", self.version.marketing_version, "--build-number", self.args.build_number, "--release-name", self.release_name, "--update-feed-url", self.appcast_url])
        invoke(["bash", "script/release/build_direct_beta.sh", "--provisioning-profile", identity["main_profile_uuid"], "--embedded-helper", str(helper), "--version", self.version.marketing_version, "--build-number", self.args.build_number, "--release-name", self.release_name, "--update-feed-url", self.appcast_url])
        self.verify_app_sparkle_configuration(app, identity["sparkle_public_key"])
        invoke(["bash", "script/release/package_dmg.sh", "--artifact", "direct-" + self.args.channel, "--app", str(app), "--release-name", self.release_name, "--expected-dmg-name", self.asset, "--expected-version", self.version.marketing_version, "--expected-build", self.args.build_number, "--output-dir", str(output), "--expected-team-id", self.policy.team_id, "--expected-cert-sha1", self.policy.certificate_sha1, "--identity", identity["identity"]])
        dmg = output / self.asset
        if not dmg.is_file():
            # package_dmg's historical filename is retained only when the policy agrees.
            candidates = list(output.glob("*.dmg"))
            if len(candidates) != 1 or candidates[0].name != self.asset:
                raise ReleaseError(f"package output does not match pinned asset name: expected {self.asset}")
            dmg = candidates[0]
        evidence = output / "notary-evidence"
        invoke(["bash", "script/release/notarize_dmg.sh", str(dmg), "--evidence-dir", str(evidence), "--expected-team-id", self.policy.team_id, "--expected-authority", identity["identity"], "--expected-cert-sha1", self.policy.certificate_sha1, "--expected-version", self.version.marketing_version, "--expected-build", self.args.build_number, "--expected-release-name", self.release_name])
        checksum = dmg.with_suffix(dmg.suffix + ".sha256")
        if not checksum.is_file() or sha256(dmg) not in checksum.read_text(encoding="utf-8"):
            raise ReleaseError("notarized DMG checksum is absent or does not match")
        sparkle_signature, sparkle_length = parse_sparkle_output(run([self.args.sparkle_sign_tool, "--account", identity["sparkle_account"], str(dmg)]))
        size_bytes = dmg.stat().st_size
        if sparkle_length != size_bytes:
            raise ReleaseError("sign_update length does not match the exact notarized DMG size")
        verify_ed25519_signature(dmg, identity["sparkle_public_key"], sparkle_signature)
        state = ReleaseState(self.release_name, self.release_name, self.args.build_number, self.args.channel, commit, self.tag, dmg.name, checksum.name, sha256(dmg), sparkle_signature, identity["sparkle_public_key"], size_bytes, "artifacts_ready")
        self.save(state)
        notes = source_root / notes_relative
        if not notes.is_file() or not notes.read_text(encoding="utf-8").strip():
            raise ReleaseError("release notes file is missing or empty")
        # Create the remote tag from the exact checked-out commit without a
        # force option. A concurrent tag creation fails rather than retargets.
        result = subprocess.run(["git", "push", "origin", f"{commit}:refs/tags/{self.tag}"], cwd=ROOT, text=True, capture_output=True)
        if result.returncode:
            raise ReleaseError(f"cannot create immutable remote release tag: {result.stderr.strip()}")
        self.verify_remote_tag(commit)
        state.status = "tag_created"; self.save(state)
        create = ["gh", "release", "create", self.tag, "--repo", self.policy.repository, "--draft", "--verify-tag", "--title", self.release_name, "--notes-file", str(notes)]
        if self.args.channel == "beta":
            create.append("--prerelease")
        run(create)
        state.status = "draft_created"; self.save(state)
        run(["gh", "release", "upload", self.tag, str(dmg), str(checksum), "--repo", self.policy.repository])
        state.status = "draft_uploaded"; self.save(state)
        print(f"PASS: draft {self.tag} uploaded; run publish only after review")

    def _draft(self, state: ReleaseState) -> dict[str, object]:
        self.verify_remote_tag(state.commit)
        raw = run(["gh", "release", "view", state.tag, "--repo", self.policy.repository, "--json", "isDraft,isPrerelease,tagName,targetCommitish,assets"])
        draft = json.loads(raw)
        if (not draft.get("isDraft") or draft.get("tagName") != state.tag
                or bool(draft.get("isPrerelease")) != (state.channel == "beta")):
            raise ReleaseError("draft is no longer immutable, draft, or bound to the prepared commit")
        names = {asset.get("name") for asset in draft.get("assets", []) if isinstance(asset, dict)}
        if names != {state.asset, state.checksum_asset}:
            raise ReleaseError("draft assets differ from the prepared DMG/checksum pair")
        return draft

    def download_and_verify_assets(self, state: ReleaseState, *, draft: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="blocks-release-download-") as directory:
            downloaded = Path(directory)
            run(["gh", "release", "download", state.tag, "--repo", self.policy.repository, "--dir", str(downloaded), "--pattern", state.asset])
            run(["gh", "release", "download", state.tag, "--repo", self.policy.repository, "--dir", str(downloaded), "--pattern", state.checksum_asset])
            dmg = downloaded / state.asset
            checksum = downloaded / state.checksum_asset
            if not dmg.is_file() or not checksum.is_file() or dmg.stat().st_size != state.size_bytes:
                phase = "draft" if draft else "published"
                raise ReleaseError(f"{phase} assets have an unexpected shape or size")
            checksum_contents = checksum.read_text(encoding="utf-8")
            if sha256(dmg) != state.sha256 or not re.fullmatch(rf"{re.escape(state.sha256)}[ \t]+{re.escape(state.asset)}\n?", checksum_contents):
                phase = "draft" if draft else "published"
                raise ReleaseError(f"{phase} assets cannot be checksum-verified")
            verify_ed25519_signature(dmg, state.sparkle_public_key, state.sparkle_signature)

    def publish(self) -> None:
        if self.args.dry_run:
            self._publish_locked()
            return
        with release_transaction_lock(self.state_path.parent):
            self._publish_locked()

    def _publish_locked(self) -> None:
        state = self.load_state()
        if state.status not in {"draft_uploaded", "release_published", "published_feed_failed"}:
            raise ReleaseError(f"release state is {state.status}; no publish or feed recovery is pending")
        if (state.tag != self.tag or state.version != self.release_name or state.release_name != self.release_name
                or state.asset != self.asset or state.checksum_asset != self.checksum_asset
                or not re.fullmatch(r"[a-f0-9]{64}", state.sha256)
                or state.size_bytes < 1):
            raise ReleaseError("release state asset or Sparkle signature metadata differs from this immutable request")
        try:
            parse_sparkle_output(f'sparkle:edSignature="{state.sparkle_signature}" length="{state.size_bytes}"')
            sparkle_public_key(state.sparkle_public_key)
        except ReleaseError as error:
            raise ReleaseError("release state Sparkle signature metadata differs from this immutable request") from error
        if self.pinned_sparkle_public_key() != state.sparkle_public_key:
            raise ReleaseError("release state Sparkle key differs from the currently pinned public key")
        if self.args.dry_run:
            self.dry(f"would verify immutable draft {state.tag}, publish it, download assets, then update only {self.appcast_path}")
            return
        if state.status == "draft_uploaded":
            self._draft(state)
            # Verify the exact bytes before making the draft public.
            self.download_and_verify_assets(state, draft=True)
            run(["gh", "release", "edit", state.tag, "--repo", self.policy.repository, "--draft=false"])
            state.status = "release_published"; self.save(state)
        try:
            self.verify_remote_tag(state.commit)
            self.download_and_verify_assets(state, draft=False)
            self.update_feed(state)
        except Exception:
            state.status = "published_feed_failed"; self.save(state)
            raise
        state.status = "published_feed_updated"; self.save(state)
        print(f"PASS: published {state.tag} and updated {self.appcast_path}")

    def update_feed(self, state: ReleaseState) -> None:
        path_parts = self.appcast_path.split("/")
        if (not SAFE_REPO.fullmatch(self.args.appcast_repository) or not SAFE_REF.fullmatch(self.args.appcast_branch)
                or not SAFE_PATH.fullmatch(self.appcast_path) or any(part in {"", ".", ".."} for part in path_parts)):
            raise ReleaseError("appcast repository, branch, or path is unsafe")
        if path_parts[0] == "site":
            raise ReleaseError("refusing to modify site/; appcast publishing is metadata-only")
        endpoint = f"repos/{self.args.appcast_repository}/contents/{self.appcast_path}"
        current = json.loads(run(["gh", "api", "--method", "GET", endpoint, "-f", f"ref={self.args.appcast_branch}"]))
        xml = base64.b64decode(current["content"]).decode("utf-8")
        root = ET.fromstring(xml)
        channel = root.find("channel")
        if channel is None:
            raise ReleaseError("appcast has no channel")
        item = ET.Element("item")
        ET.SubElement(item, "title").text = state.release_name
        ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
        enclosure = ET.SubElement(item, "enclosure")
        enclosure.set("url", f"https://github.com/{self.policy.repository}/releases/download/{state.tag}/{state.asset}")
        enclosure.set("length", str(state.size_bytes))
        enclosure.set("type", "application/octet-stream")
        enclosure.set(f"{{{SPARKLE_NS}}}edSignature", state.sparkle_signature)
        enclosure.set(f"{{{SPARKLE_NS}}}version", state.build_number)
        enclosure.set(f"{{{SPARKLE_NS}}}shortVersionString", parse_release_version(state.release_name).marketing_version)
        for existing in channel.findall("item/enclosure"):
            if existing.get(f"{{{SPARKLE_NS}}}version") == state.build_number:
                if existing.attrib != enclosure.attrib:
                    raise ReleaseError("appcast already contains conflicting metadata for this build")
                return  # A prior successful PUT may have lost its response.
        channel.insert(0, item)
        encoded = base64.b64encode(ET.tostring(root, encoding="utf-8", xml_declaration=True)).decode("ascii")
        message = f"Publish {state.release_name} appcast metadata"
        run(["gh", "api", "--method", "PUT", endpoint, "-f", f"branch={self.args.appcast_branch}", "-f", f"sha={current['sha']}", "-f", f"message={message}", "-f", f"content={encoded}"])


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description="Fail-closed Blocks local release pipeline")
    argument_parser.add_argument("command", choices=("prepare", "publish"))
    argument_parser.add_argument("version", metavar="VERSION")
    argument_parser.add_argument("--build-number")
    argument_parser.add_argument("--channel", choices=("stable", "beta"))
    argument_parser.add_argument("--notes-file")
    argument_parser.add_argument("--policy", default=str(POLICY_DEFAULT))
    argument_parser.add_argument("--identity-file", default=str(ROOT / "apps/Blocks/Config/ReleaseIdentity.local.xcconfig"))
    argument_parser.add_argument("--state-dir", default="~/Library/Application Support/BlocksRelease")
    argument_parser.add_argument("--sparkle-sign-tool", default="sign_update")
    argument_parser.add_argument("--appcast-repository", default="winx402/blocks-mac")
    argument_parser.add_argument("--appcast-branch", default="gh-pages")
    argument_parser.add_argument("--appcast-path")
    argument_parser.add_argument("--dry-run", action="store_true")
    argument_parser.add_argument("--config", default="~/.config/blocks/release.json")
    return argument_parser


def apply_local_configuration(args: argparse.Namespace) -> None:
    path = Path(args.config).expanduser()
    if not path.exists():
        return  # Explicit environment configuration remains supported.
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise ReleaseError("local release config must be an owned regular 0600 file, not a symlink")
    data = json.loads(path.read_text(encoding="utf-8"))
    allowed = {"BLOCKS_DEVELOPER_ID_APPLICATION", "BLOCKS_EXPECTED_SIGNING_CERT_SHA1",
               "BLOCKS_NOTARY_KEYCHAIN_PROFILE", "BLOCKS_SPARKLE_PUBLIC_KEY", "BLOCKS_SPARKLE_KEYCHAIN_ACCOUNT",
               "BLOCKS_MAIN_DISTRIBUTION_PROFILE_UUID", "BLOCKS_MAIN_DISTRIBUTION_PROFILE_PATH",
               "BLOCKS_HELPER_DISTRIBUTION_PROFILE_UUID", "BLOCKS_HELPER_DISTRIBUTION_PROFILE_PATH"}
    if not isinstance(data, dict) or set(data) - {"environment", "sparkle_sign_tool"}:
        raise ReleaseError("unknown local release configuration fields")
    environment = data.get("environment", {})
    if not isinstance(environment, dict) or set(environment) - allowed:
        raise ReleaseError("unknown environment fields in local release configuration")
    for key, value in environment.items():
        if not isinstance(value, str) or any(character in value for character in "\n\r\0"):
            raise ReleaseError("release configuration values must be single-line strings")
        os.environ.setdefault(key, value)
    if "sparkle_sign_tool" in data and args.sparkle_sign_tool == "sign_update":
        if not isinstance(data["sparkle_sign_tool"], str) or not Path(data["sparkle_sign_tool"]).is_absolute():
            raise ReleaseError("sparkle_sign_tool must be an absolute local executable path")
        args.sparkle_sign_tool = data["sparkle_sign_tool"]


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        apply_local_configuration(args)
        if args.build_number is not None and not re.fullmatch(r"[1-9][0-9]*", args.build_number):
            raise ReleaseError("--build-number must be a positive integer")
        pipeline = Pipeline(args)
        getattr(pipeline, args.command)()
    except (ReleaseError, ValueError, OSError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
