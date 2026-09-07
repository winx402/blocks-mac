#!/usr/bin/env python3
"""Hermetic release-pipeline transaction tests; no build, Keychain, or network."""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script/release"))
SPEC = importlib.util.spec_from_file_location("release_pipeline", ROOT / "script/release/release_pipeline.py")
assert SPEC and SPEC.loader
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def arguments(root: Path, *, command: str = "prepare") -> argparse.Namespace:
    policy = root / "policy.json"
    policy.write_text(json.dumps({
        "schema_version": 1,
        "repository": "winx402/blocks-mac",
        "bundle_id": "app.blocks.app",
        "team_id": "ABCDEFGHIJ",
        "certificate_sha1": "A" * 40,
        "dmg_asset_template": "Blocks-{tag}-arm64.dmg",
    }), encoding="utf-8")
    notes = root / "notes.md"; notes.write_text("notes\n", encoding="utf-8")
    return argparse.Namespace(command=command, version="1.2.3", build_number="7", channel="stable", notes_file=str(notes), policy=str(policy), identity_file=str(root / "ReleaseIdentity.local.xcconfig"), state_dir=str(root / "state"), sparkle_sign_tool="sign_update", appcast_repository="owner/pages", appcast_branch="gh-pages", appcast_path="appcast/stable.xml", dry_run=False)


def state(pipeline: release.Pipeline, status: str = "draft_uploaded", *, signature: str | None = None) -> release.ReleaseState:
    return release.ReleaseState(
        "1.2.3", "1.2.3", "7", "stable", "a" * 40, "v1.2.3", pipeline.asset,
        pipeline.checksum_asset, "b" * 64,
        signature if signature is not None else base64.b64encode(b"s" * 64).decode("ascii"),
        base64.b64encode(b"p" * 32).decode("ascii"), 7, status,
    )


def test_prepare_identity_failure_never_publishes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        pipeline = release.Pipeline(arguments(Path(temporary)))
        calls: list[str] = []
        pipeline.preflight_checkout = lambda: "a" * 40  # type: ignore[method-assign]
        pipeline.identity_preflight = lambda: (_ for _ in ()).throw(release.ReleaseError("identity missing"))  # type: ignore[method-assign]
        with mock.patch.object(release, "run", side_effect=lambda *a, **k: calls.append("run")):
            try:
                pipeline.prepare()
            except release.ReleaseError as error:
                require("identity missing" in str(error), "identity failure changed")
            else:
                raise AssertionError("prepare accepted missing identity")
        require(not calls, "prepare identity failure reached GitHub publication")


def test_duplicate_tag_rejected() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        pipeline = release.Pipeline(arguments(Path(temporary)))
        completed = subprocess.CompletedProcess([], 0, stdout="deadbeef\trefs/tags/v1.2.3\n", stderr="")
        with mock.patch.object(release.subprocess, "run", return_value=completed):
            try:
                pipeline.preflight_remote_absence()
            except release.ReleaseError as error:
                require("tag already exists" in str(error), "duplicate tag error is not explicit")
            else:
                raise AssertionError("duplicate tag was accepted")


def test_draft_asset_and_signature_metadata_are_fail_closed() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        pipeline = release.Pipeline(arguments(Path(temporary), command="publish"))
        prepared = state(pipeline, signature="invalid")
        pipeline.save(prepared)
        try:
            pipeline.publish()
        except release.ReleaseError as error:
            require("Sparkle signature metadata" in str(error), "bad signature metadata was not rejected")
        else:
            raise AssertionError("bad Sparkle signature metadata was accepted")
        pipeline.save(state(pipeline))
        pipeline.verify_remote_tag = lambda _commit: None  # type: ignore[method-assign]
        with mock.patch.object(release, "run", return_value=json.dumps({"isDraft": True, "tagName": "v1.2.3", "targetCommitish": "a" * 40, "assets": [{"name": pipeline.asset}]})):
            try:
                pipeline._draft(state(pipeline))
            except release.ReleaseError as error:
                require("assets differ" in str(error), "wrong draft asset error is not explicit")
            else:
                raise AssertionError("wrong draft assets were accepted")


def test_feed_failure_persists_published_state() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        pipeline = release.Pipeline(arguments(Path(temporary), command="publish"))
        pipeline.save(state(pipeline))
        pipeline._draft = lambda _state: {}  # type: ignore[method-assign]
        pipeline.download_and_verify_assets = lambda _state, **_kwargs: None  # type: ignore[method-assign]
        pipeline.verify_remote_tag = lambda _commit: None  # type: ignore[method-assign]
        pipeline.update_feed = lambda _state: (_ for _ in ()).throw(release.ReleaseError("feed write failed"))  # type: ignore[method-assign]
        with mock.patch.dict(os.environ, {"BLOCKS_SPARKLE_PUBLIC_KEY": state(pipeline).sparkle_public_key}), mock.patch.object(release, "run", return_value=""):
            try:
                pipeline.publish()
            except release.ReleaseError as error:
                require("feed write failed" in str(error), "feed failure changed")
            else:
                raise AssertionError("feed failure was hidden")
        saved = json.loads(pipeline.state_path.read_text(encoding="utf-8"))
        require(saved["status"] == "published_feed_failed", "published-but-feed-failed state was not durable")


def test_draft_bytes_are_verified_before_visibility_and_feed_is_well_formed() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        pipeline = release.Pipeline(arguments(Path(temporary), command="publish"))
        release_state = state(pipeline); pipeline.save(release_state)
        trace: list[str] = []
        pipeline._draft = lambda _state: trace.append("draft") or {}  # type: ignore[method-assign]
        pipeline.verify_remote_tag = lambda _commit: trace.append("tag")  # type: ignore[method-assign]
        pipeline.download_and_verify_assets = lambda _state, *, draft: trace.append("draft-download" if draft else "published-download")  # type: ignore[method-assign]
        pipeline.update_feed = lambda _state: (_ for _ in ()).throw(release.ReleaseError("feed write failed"))  # type: ignore[method-assign]
        def fake_run(command: list[str], **_: object) -> str:
            if command[:3] == ["gh", "release", "edit"]:
                trace.append("make-public")
            return ""
        with mock.patch.dict(os.environ, {"BLOCKS_SPARKLE_PUBLIC_KEY": release_state.sparkle_public_key}), mock.patch.object(release, "run", side_effect=fake_run):
            try:
                pipeline.publish()
            except release.ReleaseError:
                pass
            else:
                raise AssertionError("feed failure was hidden")
        require(trace.index("draft-download") < trace.index("make-public") < trace.index("published-download"), "draft bytes were not verified before public release")

        feed_pipeline = release.Pipeline(arguments(Path(temporary), command="publish"))
        appcast = '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel /></rss>'
        seen: list[list[str]] = []
        def feed_run(command: list[str], **_: object) -> str:
            seen.append(command)
            if command[:4] == ["gh", "api", "--method", "GET"]:
                return json.dumps({"sha": "feedsha", "content": base64.b64encode(appcast.encode()).decode()})
            return ""
        with mock.patch.object(release, "run", side_effect=feed_run):
            feed_pipeline.update_feed(release_state)
        require(seen[0][:4] == ["gh", "api", "--method", "GET"], "appcast read did not explicitly use GET")
        content_argument = next(value for value in seen[1] if value.startswith("content="))
        rendered = ET.fromstring(base64.b64decode(content_argument.removeprefix("content=")))
        enclosure = rendered.find("./channel/item/enclosure")
        require(enclosure is not None and enclosure.attrib["length"] == "7", "appcast enclosure length is not the verified artifact size")
        require(enclosure.attrib[f"{{{release.SPARKLE_NS}}}edSignature"] == release_state.sparkle_signature, "appcast did not emit the parsed EdDSA signature")
        feed_pipeline.appcast_path = "appcast/../site/index.xml"
        try:
            feed_pipeline.update_feed(release_state)
        except release.ReleaseError:
            pass
        else:
            raise AssertionError("appcast traversal into site/ was accepted")


def test_sparkle_parser_and_shell_syntax() -> None:
    signature = base64.b64encode(b"s" * 64).decode("ascii")
    parsed, length = release.parse_sparkle_output(f'sparkle:edSignature="{signature}" length="42"')
    require(parsed == signature and length == 42, "valid sign_update output did not parse")
    for malformed in ["sparkle: anything", f'sparkle:edSignature="{signature}" length="0"', f'sparkle:edSignature="{signature}" length="42" trailing']:
        try:
            release.parse_sparkle_output(malformed)
        except release.ReleaseError:
            pass
        else:
            raise AssertionError("malformed sign_update output was accepted")
    result = subprocess.run(["bash", "-n", str(ROOT / "script/release/audit_app_bundle.sh")], text=True, capture_output=True)
    require(result.returncode == 0, f"audit shell syntax failed: {result.stderr}")


def test_ed25519_verifier_fixture() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        dmg = root / "fixture.dmg"; dmg.write_bytes(b"not a release DMG; isolated Ed25519 fixture")
        private = root / "private.pem"; public = root / "public.der"; signature = root / "signature.bin"
        for command in [
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private)],
            ["openssl", "pkey", "-in", str(private), "-pubout", "-outform", "DER", "-out", str(public)],
            ["openssl", "pkeyutl", "-sign", "-inkey", str(private), "-rawin", "-in", str(dmg), "-out", str(signature)],
        ]:
            result = subprocess.run(command, text=True, capture_output=True)
            require(result.returncode == 0, f"Ed25519 fixture command failed: {result.stderr}")
        public_key = base64.b64encode(public.read_bytes()[-32:]).decode("ascii")
        encoded_signature = base64.b64encode(signature.read_bytes()).decode("ascii")
        release.verify_ed25519_signature(dmg, public_key, encoded_signature)
        dmg.write_bytes(dmg.read_bytes() + b"tampered")
        try:
            release.verify_ed25519_signature(dmg, public_key, encoded_signature)
        except release.ReleaseError:
            pass
        else:
            raise AssertionError("Ed25519 verifier accepted tampered bytes")


def test_shared_version_contract() -> None:
    require(release.parse_release_version("0.1.0-beta.1").marketing_version == "0.1.0", "first planned Beta rejected")
    for invalid in ("0", "01.0.0", "1.2.3-beta.01", "1.2.3-00"):
        try:
            release.parse_release_version(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid SemVer accepted: " + invalid)
    stable = release.parse_release_version("1.2.3")
    beta = release.parse_release_version("1.2.3-beta.1")
    require((stable.tag, stable.release_name, stable.marketing_version, stable.is_prerelease) == ("v1.2.3", "1.2.3", "1.2.3", False), "stable version contract drifted")
    require((beta.tag, beta.release_name, beta.marketing_version, beta.is_prerelease) == ("v1.2.3-beta.1", "1.2.3-beta.1", "1.2.3", True), "beta version contract drifted")
    release.validate_bundle_version(beta.tag, beta.release_name, beta.marketing_version, "42")
    try:
        release.validate_bundle_version(beta.tag, beta.release_name, "1.2.4", "42")
    except ValueError:
        pass
    else:
        raise AssertionError("mismatched marketing version was accepted")


def test_sparkle_nested_signing_contract() -> None:
    signer = (ROOT / "script/release/sign_direct_bundle.sh").read_text(encoding="utf-8")
    audit = (ROOT / "script/release/audit_app_bundle.sh").read_text(encoding="utf-8")
    ordered = [
        'sign "$sparkle_installer"',
        'sign "$sparkle_downloader" --preserve-metadata=entitlements',
        'sign "$sparkle_autoupdate"',
        'sign "$sparkle_updater"',
        'sign "$sparkle_framework"',
    ]
    offsets = [signer.index(item) for item in ordered]
    require(offsets == sorted(offsets), "Sparkle must be signed inner-to-outer")
    require("--force --sign \"$identity\" --options runtime --deep" not in signer, "Sparkle signing must not use --deep")
    for marker in [
        "XPCServices/Installer.xpc",
        "XPCServices/Downloader.xpc",
        'sparkle_version_root="$sparkle_framework/Versions/B"',
        'sparkle_autoupdate="$sparkle_version_root/Autoupdate"',
        'sparkle_updater="$sparkle_version_root/Updater.app"',
        "Sparkle executable lacks arm64",
        "Sparkle signature lacks a secure timestamp",
        "com.apple.security.get-task-allow",
        "com.apple.security.accessibility",
        "app.blocks.app-spks",
        "app.blocks.app-spki",
    ]:
        require(marker in audit or marker in signer, f"Sparkle release contract missing: {marker}")
    require("expected_mach_services=(app.blocks.action-broker.xpc app.blocks.app-spks app.blocks.app-spki)" in audit, "Sparkle Mach lookup allowlist is not exact")


def main() -> None:
    test_prepare_uses_frozen_commit_and_holds_transaction_lock()
    test_developer_id_profile_content_validation()
    test_prepare_identity_failure_never_publishes()
    test_duplicate_tag_rejected()
    test_draft_asset_and_signature_metadata_are_fail_closed()
    test_feed_failure_persists_published_state()
    test_draft_bytes_are_verified_before_visibility_and_feed_is_well_formed()
    test_sparkle_parser_and_shell_syntax()
    test_ed25519_verifier_fixture()
    test_shared_version_contract()
    test_sparkle_nested_signing_contract()
    print("PASS: release pipeline hermetic self-test")


def test_prepare_uses_frozen_commit_and_holds_transaction_lock() -> None:
    with tempfile.TemporaryDirectory(prefix="blocks-frozen-release-") as temporary:
        root = Path(temporary)
        args = arguments(root)
        args.build_number = None
        args.notes_file = "notes.md"
        relative_identity = Path("apps/Blocks/Config/ReleaseIdentity.local.xcconfig")
        args.identity_file = str(root / relative_identity)
        script = root / "script/release/build_selection_helper_beta.sh"
        script.parent.mkdir(parents=True)
        script.write_text("committed build script")
        (root / ".gitignore").write_text("state/\ndist/\n" + str(relative_identity) + "\n")
        real_subprocess = subprocess.run
        for command in (["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
                        ["git", "remote", "add", "origin", "https://github.com/winx402/blocks-mac.git"]):
            real_subprocess(command, cwd=root, check=True, capture_output=True)
        identity_path = root / relative_identity
        identity_path.parent.mkdir(parents=True)
        identity_path.write_text("DEVELOPMENT_TEAM = ABCDEFGHIJ\n")
        identity = {"notary_profile": "fixture", "helper_profile_uuid": "helper-uuid", "main_profile_uuid": "main-uuid",
                    "identity": "fixture", "sparkle_public_key": "A" * 43 + "=", "sparkle_account": "app.blocks.app.sparkle"}
        seen = []

        class ObservedBuild(Exception):
            pass

        def subprocess_fixture(command, **kwargs):
            if command[:2] == ["bash", "script/release/build_selection_helper_beta.sh"]:
                source_root = Path(kwargs["cwd"])
                seen.append(source_root)
                script.write_text("concurrently modified working tree")
                require(source_root != root, "build used mutable checkout")
                require((source_root / script.relative_to(root)).read_text() == "committed build script", "frozen source changed")
                require(command[command.index("--provisioning-profile") + 1] == "helper-uuid", "Helper profile missing")
                require(command[command.index("--build-number") + 1] == "10", "build did not increment published maximum")
                try:
                    with release.release_transaction_lock(Path(args.state_dir)):
                        raise AssertionError("parallel release entered")
                except release.ReleaseError:
                    pass
                raise ObservedBuild()
            return real_subprocess(command, **kwargs)

        rss = '<rss><channel><item><enclosure xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle" s:version="9"/></item></channel></rss>'
        feed = json.dumps({"content": base64.b64encode(rss.encode()).decode()})
        with mock.patch.object(release, "ROOT", root), mock.patch.object(release, "run", return_value=feed):
            pipeline = release.Pipeline(args)
            # Use actual clean checkout verification (its helper's default cwd
            # was bound at import), then exercise the complete prepare path to
            # the first build invocation without calling any release service.
            pipeline.git = lambda *parts: real_subprocess(["git", *parts], cwd=root, check=True, capture_output=True, text=True).stdout
            pipeline.identity_preflight = lambda: identity
            pipeline.verify_notary_profile = lambda _: None
            pipeline.verify_stable_appcast_exists = lambda: None
            pipeline.preflight_remote_absence = lambda: None
            with mock.patch.object(release.subprocess, "run", side_effect=subprocess_fixture):
                try:
                    pipeline.prepare()
                except ObservedBuild:
                    pass
                else:
                    raise AssertionError("prepare never reached its frozen build")
        require(len(seen) == 1 and not seen[0].exists(), "frozen worktree not cleaned")
        require(not (Path(args.state_dir) / ".release-transaction.lock").exists(), "lock not released after failure")
        require((root / "dist").exists(), "artifact directory unexpectedly removed with frozen source")
    print("PASS: prepare uses frozen committed source, independent Helper UUID, monotonic build and whole-transaction lock")


def test_developer_id_profile_content_validation() -> None:
    import copy
    import hashlib
    from datetime import datetime, timedelta
    certificate = b"public certificate fixture"
    uuid = "12345678-1234-1234-1234-123456789abc"
    profile = {"UUID": uuid, "TeamIdentifier": ["ABCDEFGHIJ"], "ProvisionsAllDevices": True,
               "ExpirationDate": datetime.now() + timedelta(days=1), "DeveloperCertificates": [certificate],
               "Entitlements": {"com.apple.application-identifier": "ABCDEFGHIJ.app.blocks.app",
                                "com.apple.developer.team-identifier": "ABCDEFGHIJ", "keychain-access-groups": ["ABCDEFGHIJ.*"]}}
    def validate(value):
        release.validate_distribution_profile(value, uuid=uuid, team="ABCDEFGHIJ", bundle_id="app.blocks.app", certificate=hashlib.sha1(certificate).hexdigest())
    validate(profile)
    changes = [lambda p: p.update(ProvisionedDevices=["fixture"]), lambda p: p.update(ProvisionsAllDevices=False),
               lambda p: p.update(ExpirationDate=datetime(2000, 1, 1)), lambda p: p.update(DeveloperCertificates=[b"wrong"]),
               lambda p: p["Entitlements"].update({"get-task-allow": True}),
               lambda p: p["Entitlements"].update({"keychain-access-groups": ["OTHERTEAM0.*"]}),
               lambda p: p["Entitlements"].update({"com.apple.application-identifier": "ABCDEFGHIJ.app.blocks.selection-helper"})]
    for change in changes:
        invalid = copy.deepcopy(profile); change(invalid)
        try:
            validate(invalid)
        except release.ReleaseError:
            pass
        else:
            raise AssertionError("invalid distribution profile accepted")
    print("PASS: Developer ID profile authorization and seven invalid variants")


if __name__ == "__main__":
    main()
