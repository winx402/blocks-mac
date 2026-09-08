#!/usr/bin/env python3
"""Hermetic checks for the official-release installer; it never touches /Applications.

All network, disk-image, signing, Gatekeeper, process and architecture commands
are in-process fake tools. Fixture apps live only below TemporaryDirectory.
"""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import plistlib
import shutil
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "script/install_helpers.py"


def load_helper() -> ModuleType:
    spec = importlib.util.spec_from_file_location("blocks_install_helpers_test", HELPER_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def policy(path: Path) -> None:
    path.write_text(json.dumps({
        "schema_version": 1,
        "repository": "winx402/blocks-mac",
        "bundle_id": "app.blocks.app",
        "team_id": "ABCDE12345",
        "certificate_sha1": "0123456789ABCDEF0123456789ABCDEF01234567",
        "dmg_asset_template": "Blocks-{tag}-arm64.dmg",
    }), encoding="utf-8")


def bundle(
    path: Path,
    version: str = "1.2.3",
    *,
    bundle_id: str = "app.blocks.app",
    release_name: str | None = None,
    build_number: str = "1",
) -> None:
    executable = path / "Contents/MacOS/Blocks"
    executable.parent.mkdir(parents=True)
    executable.write_text("fixture", encoding="utf-8")
    executable.chmod(0o755)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "CFBundleExecutable": "Blocks",
        "LSMinimumSystemVersion": "14.0",
        "BLOCKS_RELEASE_NAME": release_name if release_name is not None else version,
    }))


def sparkle_framework(app: Path) -> None:
    """Build the standard versioned-framework symlink layout on real disk."""
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = framework / "Versions/A"
    (version / "Resources").mkdir(parents=True)
    (version / "Sparkle").write_text("framework binary", encoding="utf-8")
    (version / "Resources/Info.plist").write_text("fixture", encoding="utf-8")
    (framework / "Versions/Current").symlink_to("A")
    (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
    (framework / "Resources").symlink_to("Versions/Current/Resources")


def app_with_link(path: Path, target: str) -> None:
    bundle(path)
    link = path / "Contents/Resources/link"
    link.parent.mkdir(exist_ok=True)
    link.symlink_to(target)


def release(tag: str = "v1.2.3", *, prerelease: bool = False, draft: bool = False, with_checksum: bool = True) -> dict:
    name = f"Blocks-{tag}-arm64.dmg"
    base = f"https://github.com/winx402/blocks-mac/releases/download/{tag}/"
    assets = [{"name": name, "browser_download_url": base + name}]
    if with_checksum:
        assets.append({"name": name + ".sha256", "browser_download_url": base + name + ".sha256"})
    return {
        "tag_name": tag, "draft": draft, "prerelease": prerelease,
        "published_at": "2026-09-07T00:00:00Z",
        "assets": assets,
    }


def fake_command(arguments, *, capture=False):
    """In-process stand-ins for every external system tool used by the entry."""
    args = list(arguments)
    name = Path(args[0]).name
    trace = os.environ.get("FIXTURE_TRACE")
    if trace:
        with Path(trace).open("a", encoding="utf-8") as trace_file:
            trace_file.write(name + " " + " ".join(args[1:]) + "\n")
    stdout = ""
    stderr = ""
    status = 0
    if name == "curl":
        output = Path(args[args.index("--output") + 1])
        if os.environ.get("FIXTURE_NETWORK_FAIL") == "1":
            status = 22
        elif "api.github.com" in args[-1]:
            output.write_text(os.environ["FIXTURE_METADATA"], encoding="utf-8")
        elif args[-1].endswith(".sha256"):
            output.write_text(hashlib.sha256(b"fixture-dmg").hexdigest() + "  Blocks-fixture.dmg\n", encoding="utf-8")
        else:
            output.write_bytes(b"fixture-dmg")
    elif name == "hdiutil" and args[1] == "attach":
        requested_mount = Path(args[args.index("-mountpoint") + 1])
        if os.environ.get("FIXTURE_BAD_ATTACH_METADATA") == "1":
            stdout = "not a plist"
        else:
            source_mount = Path(os.environ["FIXTURE_MOUNT"])
            shutil.copytree(source_mount / "Blocks.app", requested_mount / "Blocks.app")
            (requested_mount / "Applications").symlink_to("/Applications")
            stdout = plistlib.dumps({"system-entities": [
                {"dev-entry": "/dev/disk99"}, {"dev-entry": "/dev/disk99s1"},
                {"mount-point": str(requested_mount)}
            ]}).decode()
    elif name == "hdiutil" and args[1] == "detach":
        pass
    elif name == "lipo":
        stdout = os.environ.get("FIXTURE_ARCH", "arm64") + "\n"
    elif name == "codesign":
        if os.environ.get("FIXTURE_BAD_SIGNATURE") == "1" and "--verify" in args:
            status = 1
        elif "--extract-certificates" in args:
            Path(args[args.index("--extract-certificates") + 1] + "0").write_bytes(b"certificate")
        elif "-dvv" in args:
            stderr = (
                "TeamIdentifier=" + os.environ.get("FIXTURE_TEAM", "ABCDE12345") + "\n"
                "Authority=Developer ID Application: Fixture Publisher (ABCDE12345)\n"
            )
    elif name == "openssl":
        stdout = "sha1 Fingerprint=" + os.environ.get("FIXTURE_CERT", "0123456789ABCDEF0123456789ABCDEF01234567") + "\n"
    elif name == "spctl":
        status = 1 if os.environ.get("FIXTURE_BAD_GATEKEEPER") == "1" else 0
    elif name == "pgrep":
        status = 2 if os.environ.get("FIXTURE_PGREP_FAILURE") == "1" else (0 if os.environ.get("FIXTURE_BUSY") == "1" else 1)
    else:
        raise AssertionError(f"unexpected external tool: {args}")
    return __import__("subprocess").CompletedProcess(args, status, stdout, stderr)


@contextmanager
def patched(module: ModuleType, name: str, value: object):
    original = getattr(module, name)
    setattr(module, name, value)
    try:
        yield
    finally:
        setattr(module, name, original)


def expect_refusal(call, expected: str) -> None:
    try:
        call()
    except Exception as error:  # fixture checks assert the public refusal text
        assert expected in str(error), str(error)
    else:
        raise AssertionError(f"expected refusal containing: {expected}")


def main() -> None:
    reports: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="blocks-install-entry-self-test-") as temporary:
        root = Path(temporary)
        mount = root / "mount"
        mount.mkdir()
        bundle(mount / "Blocks.app")
        (mount / "Applications").symlink_to("/Applications")
        config = root / "policy.json"
        policy(config)
        metadata = release()
        environment = {
            **os.environ,
            "FIXTURE_METADATA": json.dumps([metadata]),
            "FIXTURE_MOUNT": str(mount),
        }
        helper = load_helper()
        old_environment = os.environ.copy()
        os.environ.clear(); os.environ.update(environment)
        try:
          with patched(helper, "command", fake_command):
            trusted = helper.load_policy(config)
            target_root = root / "installed"
            selected = helper.resolve_release(trusted, None)

            # Sparkle uses versioned-framework relative symlinks. They remain
            # valid after the candidate is copied because each target resolves
            # strictly inside Blocks.app.
            sparkle_framework(mount / "Blocks.app")
            assert helper.app_info(mount / "Blocks.app", selected, trusted).name == "Blocks"
            reports.append({"case": "standard_sparkle_framework_relative_links_allowed", "ok": True})

            beta_release = helper.Release(
                tag="v1.2.3-beta.1",
                asset_name="Blocks-v1.2.3-beta.1-arm64.dmg",
                asset_url="https://github.com/winx402/blocks-mac/releases/download/v1.2.3-beta.1/Blocks-v1.2.3-beta.1-arm64.dmg",
                checksum_url=None,
            )
            beta_app = root / "beta.app"
            bundle(beta_app, "1.2.3", release_name="1.2.3-beta.1", build_number="42")
            assert helper.app_info(beta_app, beta_release, trusted).name == "Blocks"
            reports.append({"case": "beta_tag_release_name_marketing_and_build_contract", "ok": True})

            wrong_marketing = root / "wrong-marketing.app"
            bundle(wrong_marketing, "1.2.4", release_name="1.2.3", build_number="42")
            expect_refusal(
                lambda: helper.app_info(wrong_marketing, selected, trusted),
                "version fields do not match",
            )
            wrong_release_name = root / "wrong-release-name.app"
            bundle(wrong_release_name, "1.2.3", release_name="1.2.4", build_number="42")
            expect_refusal(
                lambda: helper.app_info(wrong_release_name, selected, trusted),
                "version fields do not match",
            )
            reports.append({"case": "marketing_and_release_name_mismatches_rejected", "ok": True})

            negative_links = {
                "absolute": "/tmp/not-allowed",
                "escape": "../../../outside-bundle",
                "broken": "missing-target",
                "cycle": "link",
            }
            expected_link_errors = {
                "absolute": "absolute symbolic link",
                "escape": "symbolic link escapes the bundle",
                "broken": "unresolved symbolic link",
                "cycle": "unresolved symbolic link",
            }
            (root / "outside-bundle").write_text("outside", encoding="utf-8")
            for name, target in negative_links.items():
                fixture = root / f"{name}.app"
                app_with_link(fixture, target)
                expect_refusal(
                    lambda fixture=fixture: helper.app_info(fixture, selected, trusted),
                    expected_link_errors[name],
                )
            root_link = root / "root-link.app"
            root_link.symlink_to(mount / "Blocks.app")
            expect_refusal(
                lambda: helper.app_info(root_link, selected, trusted),
                "candidate app is not a regular directory",
            )
            reports.append({"case": "unsafe_bundle_and_root_symlinks_rejected", "ok": True})

            # Full release selection/download/mount/signature/Gatekeeper flow,
            # with only the final root redirected to a temporary fixture.
            def temporary_install(candidate, selected, selected_policy, work):
                return helper.install_to(target_root, candidate, selected, selected_policy, work)
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                assert helper.main([]) == 0
            installed = target_root / "Blocks.app"
            assert installed.is_dir() and installed != mount / "Blocks.app"
            assert helper.existing_managed_bundle(installed, trusted, root) is not None
            reports.append({"case": "stable_release_full_hermetic_flow", "ok": True})

            # Existing official bundle is upgraded in place, not duplicated.
            shutil.rmtree(installed)
            bundle(installed, "0.9.0")
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                assert helper.main([]) == 0
            assert (installed / "Contents/Info.plist").is_file()
            assert len(list(target_root.glob("Blocks.app"))) == 1
            reports.append({"case": "in_place_upgrade_no_duplicate", "ok": True})

            os.environ["FIXTURE_NETWORK_FAIL"] = "1"
            expect_refusal(lambda: helper.resolve_release(trusted, None), "metadata request failed")
            os.environ.pop("FIXTURE_NETWORK_FAIL")
            reports.append({"case": "network_failure_before_artifact", "ok": True})

            os.environ["FIXTURE_BAD_SIGNATURE"] = "1"
            trace = root / "bad-dmg-signature-trace"
            os.environ["FIXTURE_TRACE"] = str(trace)
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "DMG code signature verification failed")
            assert "hdiutil attach" not in trace.read_text(encoding="utf-8")
            os.environ.pop("FIXTURE_BAD_SIGNATURE")
            os.environ.pop("FIXTURE_TRACE")
            reports.append({"case": "bad_dmg_signature_refuses_before_attach", "ok": True})

            # If hdiutil has attached at the installer-created mount point but
            # returns malformed plist metadata, only that private mount point
            # is detached before the refusal escapes.
            trace = root / "bad-attach-metadata-trace"
            os.environ["FIXTURE_BAD_ATTACH_METADATA"] = "1"
            os.environ["FIXTURE_TRACE"] = str(trace)
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "DMG attach metadata is invalid")
            assert "hdiutil detach" in trace.read_text(encoding="utf-8")
            os.environ.pop("FIXTURE_BAD_ATTACH_METADATA")
            os.environ.pop("FIXTURE_TRACE")
            reports.append({"case": "bad_attach_metadata_detaches_private_mount", "ok": True})

            os.environ["FIXTURE_TEAM"] = "ZZZZZ99999"
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "Team ID differs")
            os.environ.pop("FIXTURE_TEAM")
            reports.append({"case": "wrong_trusted_team_rejected", "ok": True})

            os.environ["FIXTURE_BAD_GATEKEEPER"] = "1"
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "Gatekeeper assessment failed")
            os.environ.pop("FIXTURE_BAD_GATEKEEPER")
            reports.append({"case": "gatekeeper_failure_preserves_install", "ok": True})

            (mount / "Blocks.app/Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "app.blocks.app", "CFBundleShortVersionString": "9.9.9",
                "CFBundleVersion": "1", "CFBundleExecutable": "Blocks", "LSMinimumSystemVersion": "14.0",
            }))
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "version fields do not match")
            bundle(mount / "replacement.app")
            shutil.rmtree(mount / "Blocks.app")
            (mount / "replacement.app").rename(mount / "Blocks.app")
            reports.append({"case": "version_mismatch_before_install", "ok": True})

            os.environ["FIXTURE_BUSY"] = "1"
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "Blocks is running")
            os.environ.pop("FIXTURE_BUSY")
            reports.append({"case": "busy_never_terminates_app", "ok": True})

            shutil.rmtree(installed)
            real = target_root / "real.app"
            bundle(real)
            installed.symlink_to(real)
            with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                expect_refusal(lambda: helper.main([]), "not a regular app bundle")
            installed.unlink()
            reports.append({"case": "symlink_destination_rejected", "ok": True})

            bundle(installed, "0.9.0")
            original_copytree = helper.shutil.copytree
            def copy_failure(*_args, **_kwargs): raise OSError("simulated copy failure")
            helper.shutil.copytree = copy_failure
            try:
                with patched(helper, "policy_path", lambda: config), patched(helper, "install", temporary_install):
                    expect_refusal(lambda: helper.main([]), "simulated copy failure")
            finally:
                helper.shutil.copytree = original_copytree
            assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "0.9.0"
            reports.append({"case": "copy_failure_preserves_existing", "ok": True})

            # A plain same-name directory is not ours merely because it is
            # named Blocks.app. Its unrelated data must survive untouched.
            shutil.rmtree(installed)
            bundle(installed, "0.9.0", bundle_id="com.example.unrelated")
            irreplaceable = installed / "unrelated-user-file"
            irreplaceable.write_text("do not delete", encoding="utf-8")
            expect_refusal(
                lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                "does not belong to app.blocks.app",
            )
            assert irreplaceable.read_text(encoding="utf-8") == "do not delete"
            shutil.rmtree(installed)
            reports.append({"case": "unrelated_same_name_directory_never_replaced", "ok": True})

            # Matching only Info.plist is insufficient: an impersonating
            # directory without the app executable must not be replaced.
            (installed / "Contents").mkdir(parents=True)
            (installed / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "app.blocks.app", "CFBundleExecutable": "Blocks",
            }))
            irreplaceable = installed / "unrelated-user-file"
            irreplaceable.write_text("do not delete", encoding="utf-8")
            expect_refusal(
                lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                "executable is missing",
            )
            assert irreplaceable.read_text(encoding="utf-8") == "do not delete"
            shutil.rmtree(installed)
            reports.append({"case": "unsigned_or_structurally_incomplete_bundle_never_replaced", "ok": True})

            # Even a correctly identified bundle is rejected if the current
            # user does not own every item that would be moved and discarded.
            bundle(installed, "0.9.0")
            actual_uid = os.geteuid()
            with patched(helper.os, "geteuid", lambda: actual_uid + 1):
                expect_refusal(
                    lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                    "not wholly owned by the current user",
                )
            assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "0.9.0"
            reports.append({"case": "foreign_owned_existing_bundle_never_replaced", "ok": True})

            os.environ["FIXTURE_BAD_SIGNATURE"] = "1"
            expect_refusal(
                lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                "code signature verification failed",
            )
            os.environ.pop("FIXTURE_BAD_SIGNATURE")
            assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "0.9.0"
            reports.append({"case": "untrusted_existing_signature_never_replaced", "ok": True})

            os.environ["FIXTURE_PGREP_FAILURE"] = "1"
            expect_refusal(
                lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                "cannot determine whether Blocks is running",
            )
            os.environ.pop("FIXTURE_PGREP_FAILURE")
            reports.append({"case": "process_query_failure_never_treated_as_idle", "ok": True})

            # A promotion error with no competing destination restores the old
            # bundle and may clean the staging directory only after that fact.
            original_rename = helper.rename_without_replacing
            def fail_promotion(self, target):
                if self.name == "Blocks.app" and self.parent.name.startswith(".Blocks-official-install-") and Path(target) == installed:
                    raise OSError("simulated promotion failure")
                return original_rename(self, target)
            helper.rename_without_replacing = fail_promotion
            try:
                expect_refusal(
                    lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                    "original app was restored",
                )
            finally:
                helper.rename_without_replacing = original_rename
            assert plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "0.9.0"
            assert not list(target_root.glob(".Blocks-official-install-*"))
            reports.append({"case": "promotion_failure_restores_old_bundle", "ok": True})

            # Race the promotion by creating a new destination in the failing
            # rename side effect. The concurrent app is never overwritten and
            # the old bundle remains in a retained recovery stage.
            def race_promotion(self, target):
                if self.name == "Blocks.app" and self.parent.name.startswith(".Blocks-official-install-") and Path(target) == installed:
                    installed.mkdir()
                return original_rename(self, target)
            helper.rename_without_replacing = race_promotion
            try:
                expect_refusal(
                    lambda: helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root),
                    "concurrently created destination was left untouched",
                )
            finally:
                helper.rename_without_replacing = original_rename
            assert installed.is_dir() and not list(installed.iterdir())
            retained = list(target_root.glob(".Blocks-official-install-*/previous.app/Contents/Info.plist"))
            assert len(retained) == 1
            assert plistlib.loads(retained[0].read_bytes())["CFBundleShortVersionString"] == "0.9.0"
            shutil.rmtree(installed)
            for recovery in target_root.glob(".Blocks-official-install-*"):
                shutil.rmtree(recovery)
            reports.append({"case": "promotion_race_preserves_old_and_concurrent_bundle", "ok": True})

            # Any non-OSError interruption after moving the old app also keeps
            # recovery material; the cleanup path must not erase it.
            bundle(installed, "0.9.0")
            def interrupt_promotion(self, target):
                if self.name == "Blocks.app" and self.parent.name.startswith(".Blocks-official-install-") and Path(target) == installed:
                    raise KeyboardInterrupt("fixture interruption")
                return original_rename(self, target)
            helper.rename_without_replacing = interrupt_promotion
            try:
                try:
                    helper.install_to(target_root, mount / "Blocks.app", selected, trusted, root)
                except KeyboardInterrupt:
                    pass
                else:
                    raise AssertionError("expected fixture interruption")
            finally:
                helper.rename_without_replacing = original_rename
            retained = list(target_root.glob(".Blocks-official-install-*/previous.app/Contents/Info.plist"))
            assert len(retained) == 1 and not installed.exists()
            assert plistlib.loads(retained[0].read_bytes())["CFBundleShortVersionString"] == "0.9.0"
            shutil.rmtree(retained[0].parents[2])
            reports.append({"case": "interruption_after_backup_retains_old_bundle", "ok": True})

            system_root, user_root = root / "system-applications", root / "user-applications"
            original_install_to = helper.install_to
            calls: list[Path] = []
            def permission_then_user(directory, *arguments):
                calls.append(directory)
                if directory == system_root:
                    raise helper.NotWritable("fixture denied")
                return original_install_to(directory, *arguments)
            with patched(helper, "install_to", permission_then_user), patched(helper, "_installation_roots", lambda: (system_root, user_root)):
                destination = helper.install(mount / "Blocks.app", metadata and helper.resolve_release(trusted, None), trusted, root)
            assert destination.parent == user_root and calls == [system_root, user_root]
            reports.append({"case": "permission_falls_back_to_user_applications", "ok": True})

            prerelease = release(tag="v1.2.3-beta.1", prerelease=True)
            os.environ["FIXTURE_METADATA"] = json.dumps([prerelease])
            expect_refusal(lambda: helper.resolve_release(trusted, None), "no installable stable release")
            os.environ["FIXTURE_METADATA"] = json.dumps(prerelease)
            assert helper.resolve_release(trusted, "v1.2.3-beta.1").tag == "v1.2.3-beta.1"
            reports.append({"case": "stable_excludes_prerelease_explicit_version_allows", "ok": True})
        finally:
            os.environ.clear(); os.environ.update(old_environment)
    print(json.dumps({"ok": True, "cases": reports}, indent=2))


if __name__ == "__main__":
    main()
