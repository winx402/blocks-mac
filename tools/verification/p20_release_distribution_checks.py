#!/usr/bin/env python3
from __future__ import annotations

import json
import inspect
import plistlib
import re
import subprocess as _subprocess
import os
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from verification_build_helpers import run_controlled_subprocess


ROOT = Path(__file__).resolve().parents[2]
def run_fixture_subprocess(name: str, *args: object, **kwargs: object) -> _subprocess.CompletedProcess[str]:
    """Run legacy fixture commands with a bounded raw subprocess timeout."""
    kwargs["timeout"] = 15
    try:
        return _subprocess.run(*args, **kwargs)  # type: ignore[arg-type,return-value]
    except _subprocess.TimeoutExpired as error:
        raise AssertionError(f"hermetic fixture timed out: {name}: {error.cmd}") from error


def run_controlled_fixture(command: list[str], *, cwd: Path, environment: dict[str, str], name: str) -> _subprocess.CompletedProcess[str]:
    """Use the project supervisor for the nested-signature fixture only."""
    previous_environment = os.environ.copy()
    try:
        os.environ.clear(); os.environ.update(environment)
        result = run_controlled_subprocess(command, cwd=cwd, timeout=15, termination_grace_seconds=0.25)
    finally:
        os.environ.clear(); os.environ.update(previous_environment)
    if result["timed_out"]:
        raise AssertionError(f"hermetic fixture timed out: {name}; cleanup={result.get('process_cleanup')}")
    return _subprocess.CompletedProcess(command, int(result["returncode"]), str(result["stdout"]), str(result["stderr"]))


class _HermeticSubprocess:
    """Compatibility facade forcing every existing fixture call through the gate."""

    def run(self, *args: object, **kwargs: object) -> _subprocess.CompletedProcess[str]:
        caller = inspect.currentframe().f_back.f_code.co_name  # type: ignore[union-attr]
        return run_fixture_subprocess(caller, *args, **kwargs)


subprocess = _HermeticSubprocess()


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify_selection_helper_scheme(project: str, build_script: str) -> None:
    require(
        "-scheme BlocksSelectionHelper" in build_script,
        "Helper release build must reference the shared BlocksSelectionHelper scheme",
    )
    scheme_path = ROOT / "apps/Blocks/Blocks.xcodeproj/xcshareddata/xcschemes/BlocksSelectionHelper.xcscheme"
    require(scheme_path.is_file(), "shared BlocksSelectionHelper scheme is missing")
    try:
        scheme = ET.parse(scheme_path).getroot()
    except ET.ParseError as error:
        raise AssertionError(f"shared BlocksSelectionHelper scheme is invalid XML: {error}") from error

    target_id = "T27X00000000000000000001"
    target_name = "BlocksSelectionHelper"
    target_match = re.search(
        rf"{re.escape(target_id)} /\* {re.escape(target_name)} \*/ = \{{\n\s*isa = PBXNativeTarget;",
        project,
    )
    require(target_match is not None, "BlocksSelectionHelper target is missing or changed")

    test_target_id = "T27V00000000000000000001"
    test_target_name = "BlocksSelectionHelperTests"
    build_entries = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
    require(
        len(build_entries) == 2,
        "Helper scheme must contain exactly the Helper and its test target",
    )
    entries_by_target: dict[str, ET.Element] = {}
    for entry in build_entries:
        build_reference = entry.find("BuildableReference")
        require(
            build_reference is not None,
            "Helper scheme build target reference is missing",
        )
        blueprint_identifier = build_reference.attrib.get("BlueprintIdentifier")
        require(
            blueprint_identifier not in entries_by_target,
            "Helper scheme contains a duplicate build target",
        )
        entries_by_target[blueprint_identifier or ""] = entry
    require(
        set(entries_by_target) == {target_id, test_target_id},
        "Helper scheme contains an unexpected build target",
    )

    helper_entry = entries_by_target[target_id]
    helper_reference = helper_entry.find("BuildableReference")
    require(
        helper_reference is not None
        and helper_reference.attrib.get("BlueprintName") == target_name,
        "Helper scheme build target does not match BlocksSelectionHelper",
    )
    for attribute in (
        "buildForTesting",
        "buildForRunning",
        "buildForProfiling",
        "buildForArchiving",
        "buildForAnalyzing",
    ):
        require(
            helper_entry.attrib.get(attribute) == "YES",
            f"Helper scheme must enable {attribute} for the Helper target",
        )

    test_entry = entries_by_target[test_target_id]
    test_reference = test_entry.find("BuildableReference")
    require(
        test_reference is not None
        and test_reference.attrib.get("BlueprintName") == test_target_name,
        "Helper scheme test target does not match BlocksSelectionHelperTests",
    )
    require(
        test_entry.attrib.get("buildForTesting") == "YES",
        "Helper test target must be enabled for testing",
    )
    for attribute in (
        "buildForRunning",
        "buildForProfiling",
        "buildForArchiving",
        "buildForAnalyzing",
    ):
        require(
            test_entry.attrib.get(attribute) == "NO",
            f"Helper test target must not be enabled for {attribute}",
        )
    for action, configuration in (("LaunchAction", "Debug"), ("ProfileAction", "Release")):
        action_node = scheme.find(f"./{action}[@buildConfiguration='{configuration}']")
        require(action_node is not None, f"Helper scheme {action} configuration must be {configuration}")
        action_reference = action_node.find(".//BuildableReference")
        require(action_reference is not None, f"Helper scheme {action} target reference is missing")
        require(
            action_reference.attrib.get("BlueprintIdentifier") == target_id
            and action_reference.attrib.get("BlueprintName") == target_name,
            f"Helper scheme {action} target does not match BlocksSelectionHelper",
        )
    test_action = scheme.find("./TestAction[@buildConfiguration='Debug']")
    require(test_action is not None, "Helper scheme test configuration must be Debug")
    testables = test_action.findall("./Testables/TestableReference")
    require(len(testables) == 1, "Helper scheme must run exactly one test target")
    testable_reference = testables[0].find("BuildableReference")
    require(
        testable_reference is not None
        and testable_reference.attrib.get("BlueprintIdentifier") == test_target_id
        and testable_reference.attrib.get("BlueprintName") == test_target_name,
        "Helper scheme TestAction does not target BlocksSelectionHelperTests",
    )
    unit_testing_environment = test_action.find(
        "./EnvironmentVariables/EnvironmentVariable[@key='BLOCKS_UNIT_TESTING']"
    )
    require(
        unit_testing_environment is not None
        and unit_testing_environment.attrib.get("value") == "1"
        and unit_testing_environment.attrib.get("isEnabled") == "YES",
        "Helper tests must suppress the production listener with BLOCKS_UNIT_TESTING=1",
    )
    require(
        scheme.find("./ArchiveAction[@buildConfiguration='Release']") is not None,
        "Helper scheme archive configuration must be Release",
    )


def verify_unexpected_bundle_members_are_rejected() -> None:
    """Exercise the unsigned structural gate without a signing identity."""
    audit_script = ROOT / "script/release/audit_app_bundle.sh"
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_root = Path(temporary_directory)
        app = temporary_root / "Blocks.app"
        contents = app / "Contents"
        for relative in [
            "MacOS/Blocks",
            "MacOS/BlocksClipboardBroker",
            "XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner",
            "Frameworks/Unexpected.framework/Versions/A/Unexpected",
            "Resources/en.lproj/InfoPlist.strings",
            "Resources/ja.lproj/InfoPlist.strings",
            "Resources/zh-Hans.lproj/InfoPlist.strings",
            "Info.plist",
        ]:
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()

        def write_release_identity(
            *,
            channel: str,
            version: str,
            build: str,
            release_name: str,
            include_helper: bool = False,
        ) -> None:
            info = {
                "LSMinimumSystemVersion": "14.0",
                "BLOCKS_DISTRIBUTION_CHANNEL": channel,
                "CFBundleIdentifier": "app.blocks.app",
                "CFBundleDisplayName": "Blocks for Mac",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "BLOCKS_RELEASE_NAME": release_name,
                "BLOCKS_RELEASE_PAGE_URL": "https://blocks.orangeforge.top/releases/",
                "BLOCKS_SUPPORT_URL": "https://blocks.orangeforge.top/support/",
                "BLOCKS_PRIVACY_URL": "https://blocks.orangeforge.top/privacy/",
                "BLOCKS_SELECTION_HELPER_DOWNLOAD_URL": (
                    "https://downloads.orangeforge.top/beta/0.1.0-beta.1/"
                    "Blocks-Selection-Helper-0.1.0-beta.1-arm64.dmg"
                    if channel.startswith("direct-")
                    else ""
                ),
            }
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            if not include_helper:
                return
            helper_info = (
                contents / "Helpers/Blocks Selection Helper.app/Contents/Info.plist"
            )
            helper_info.write_bytes(
                plistlib.dumps(
                    {
                        "LSMinimumSystemVersion": "14.0",
                        "BLOCKS_DISTRIBUTION_CHANNEL": channel,
                        "CFBundleIdentifier": "app.blocks.selection-helper",
                        "CFBundleURLTypes": [
                            {"CFBundleURLSchemes": ["blocks-selection-helper"]}
                        ],
                        "CFBundleShortVersionString": version,
                        "CFBundleVersion": build,
                        "BLOCKS_RELEASE_NAME": release_name,
                    }
                )
            )

        write_release_identity(
            channel="app-store-beta",
            version="0.1.0",
            build="1",
            release_name="0.1.0-beta.1",
        )

        shims = temporary_root / "shims"
        shims.mkdir()
        (shims / "lipo").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ -n \"${BLOCKS_LIPO_TRACE:-}\" ]]; then printf '%s\\n' \"$2\" >> \"$BLOCKS_LIPO_TRACE\"; fi\n"
            "case \"$2\" in\n"
            "  *\"${BLOCKS_TEST_NON_ARM64_COMPONENT:-__none__}\") echo x86_64 ;;\n"
            "  *) echo arm64 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (shims / "file").write_text(
            "#!/usr/bin/env bash\n"
            "case \"$2\" in\n"
            "  */Contents/MacOS/Blocks|*/Contents/MacOS/BlocksClipboardBroker|*/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner|*/Contents/MacOS/BlocksActionBroker|*/Contents/Resources/CLI/blocks|*Unexpected.framework/*) echo Mach-O ;;\n"
            "  *) echo data ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (shims / "plutil").write_text(
            "#!/usr/bin/env bash\n"
            "case \"$2\" in\n"
            "  LSMinimumSystemVersion) echo 14.0 ;;\n"
            "  BLOCKS_DISTRIBUTION_CHANNEL) echo \"${BLOCKS_TEST_CHANNEL:-app-store-beta}\" ;;\n"
            "  CFBundleIdentifier) echo app.blocks.app ;;\n"
            "  CFBundleDisplayName) case \"$4\" in *zh-Hans*) echo 积木工具 ;; *) echo 'Blocks for Mac' ;; esac ;;\n"
            "  BLOCKS_RELEASE_PAGE_URL) echo https://blocks.orangeforge.top/releases/ ;;\n"
            "  BLOCKS_SUPPORT_URL) echo https://blocks.orangeforge.top/support/ ;;\n"
            "  BLOCKS_PRIVACY_URL) echo https://blocks.orangeforge.top/privacy/ ;;\n"
            "  BLOCKS_SELECTION_HELPER_DOWNLOAD_URL) case \"${BLOCKS_TEST_CHANNEL:-app-store-beta}\" in direct-beta|direct-stable) echo https://downloads.orangeforge.top/beta/0.1.0-beta.1/Blocks-Selection-Helper-0.1.0-beta.1-arm64.dmg ;; *) echo ;; esac ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        # Direct releases additionally allow the explicit Sparkle 2.9 helper
        # inventory plus the independently embedded Selection Helper.
        (shims / "file").write_text(
            "#!/usr/bin/env bash\n"
            "case \"$2\" in\n"
            "  */Contents/MacOS/Blocks|*/Contents/MacOS/BlocksClipboardBroker|*/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner|*/Contents/MacOS/BlocksActionBroker|*/Contents/Resources/CLI/blocks|*/Contents/Helpers/Blocks\\ Selection\\ Helper.app/Contents/MacOS/Blocks\\ Selection\\ Helper|*/Sparkle.framework/Versions/B/Sparkle|*/Sparkle.framework/Versions/B/Autoupdate|*/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater|*/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer|*/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader|*Unexpected.framework/*) echo Mach-O ;;\n"
            "  *) echo data ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        for shim in shims.iterdir():
            shim.chmod(0o755)

        environment = {"PATH": f"{shims}:/usr/bin:/bin"}
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "app-store-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        require(result.returncode != 0, "audit accepted an unexpected framework Mach-O")
        require(
            "unexpected Mach-O executable in bundle: Contents/Frameworks/Unexpected.framework/Versions/A/Unexpected"
            in result.stderr,
            "audit did not report the unexpected framework Mach-O",
        )

        unexpected_framework = (
            contents
            / "Frameworks/Unexpected.framework/Versions/A/Unexpected"
        )
        unexpected_framework.unlink()
        resource_link = contents / "Resources/UnexpectedLink"
        resource_link.symlink_to("../MacOS/Blocks")
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "app-store-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        require(result.returncode != 0, "audit accepted a symlinked bundle resource")
        require(
            "symbolic link is forbidden in release bundle: Contents/Resources/UnexpectedLink"
            in result.stderr,
            "audit did not report the symlinked bundle resource",
        )

        resource_link.unlink()
        allowlisted_broker = contents / "MacOS/BlocksClipboardBroker"
        allowlisted_broker.unlink()
        allowlisted_broker.symlink_to("Blocks")
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "app-store-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        require(result.returncode != 0, "audit accepted a symlinked allowlisted executable")
        require(
            "symbolic link is forbidden in release bundle: Contents/MacOS/BlocksClipboardBroker"
            in result.stderr,
            "audit did not report the symlinked allowlisted executable",
        )

        allowlisted_broker.unlink()
        allowlisted_broker.touch()
        lipo_trace = temporary_root / "lipo-trace.txt"
        baseline_environment = environment | {
            "BLOCKS_LIPO_TRACE": str(lipo_trace),
        }
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "app-store-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=baseline_environment,
            check=False,
        )
        require(result.returncode == 0, f"valid structural fixture failed audit: {result.stderr}")
        audited_architecture_paths = lipo_trace.read_text(encoding="utf-8").splitlines()
        expected_architecture_paths = [
            str(contents / "MacOS/Blocks"),
            str(contents / "MacOS/BlocksClipboardBroker"),
            str(
                contents
                / "XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner"
            ),
        ]
        require(
            set(audited_architecture_paths) == set(expected_architecture_paths),
            "audit did not inspect every allowlisted Store Mach-O architecture",
        )

        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "direct-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
            timeout=15,
        )
        require(result.returncode != 0, "Store fixture passed the Direct channel audit")
        require(
            "expected channel direct-beta, got: app-store-beta" in result.stderr,
            "Store fixture channel mismatch was not reported exactly",
        )

        non_arm_environment = environment | {
            "BLOCKS_TEST_NON_ARM64_COMPONENT": "BlocksClipboardBroker",
        }
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "app-store-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=non_arm_environment,
            check=False,
        )
        require(result.returncode != 0, "audit accepted an x86_64 allowlisted component")
        require(
            "expected arm64-only executable Contents/MacOS/BlocksClipboardBroker, got: x86_64"
            in result.stderr,
            "audit did not identify the non-arm64 allowlisted component",
        )

        for relative in [
            "MacOS/BlocksActionBroker",
            "Resources/CLI/blocks",
            "Library/LaunchAgents/app.blocks.action-broker.plist",
            "Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper",
            "Frameworks/Sparkle.framework/Versions/B/Sparkle",
            "Frameworks/Sparkle.framework/Versions/B/Autoupdate",
            "Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
            "Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        ]:
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()

        write_release_identity(
            channel="direct-beta",
            version="0.1.0",
            build="1",
            release_name="0.1.0-beta.1",
            include_helper=True,
        )

        direct_lipo_trace = temporary_root / "direct-lipo-trace.txt"
        direct_environment = environment | {
            "BLOCKS_TEST_CHANNEL": "direct-beta",
            "BLOCKS_LIPO_TRACE": str(direct_lipo_trace),
        }
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "direct-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=direct_environment,
            check=False,
        )
        require(result.returncode == 0, f"valid Direct structural fixture failed audit: {result.stderr}")
        direct_architecture_paths = direct_lipo_trace.read_text(
            encoding="utf-8"
        ).splitlines()
        expected_direct_architecture_paths = expected_architecture_paths + [
            str(contents / "MacOS/BlocksActionBroker"),
            str(contents / "Resources/CLI/blocks"),
            str(contents / "Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper"),
            str(contents / "Frameworks/Sparkle.framework/Versions/B/Sparkle"),
            str(contents / "Frameworks/Sparkle.framework/Versions/B/Autoupdate"),
            str(contents / "Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"),
            str(contents / "Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"),
            str(contents / "Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"),
        ]
        require(
            set(direct_architecture_paths)
            == set(expected_direct_architecture_paths),
            "audit did not inspect every allowlisted Direct Mach-O architecture",
        )

        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "app-store-beta", "--app", str(app)],
            text=True,
            capture_output=True,
            env=direct_environment,
            check=False,
            timeout=15,
        )
        require(result.returncode != 0, "Direct fixture passed the Store channel audit")
        require(
            "expected channel app-store-beta, got: direct-beta" in result.stderr,
            "Direct fixture channel mismatch was not reported exactly",
        )

        for component in [
            "BlocksClipboardBroker",
            "BlocksPluginRunner",
            "BlocksActionBroker",
            "blocks",
        ]:
            non_arm_direct_environment = direct_environment | {
                "BLOCKS_TEST_NON_ARM64_COMPONENT": component,
                "BLOCKS_LIPO_TRACE": str(
                    temporary_root / f"direct-non-arm-{component}.txt"
                ),
            }
            result = subprocess.run(
                [
                    "bash",
                    str(audit_script),
                    "--channel",
                    "direct-beta",
                    "--app",
                    str(app),
                ],
                text=True,
                capture_output=True,
                env=non_arm_direct_environment,
                check=False,
            )
            require(
                result.returncode != 0,
                f"audit accepted an x86_64 Direct component: {component}",
            )

        write_release_identity(
            channel="direct-stable",
            version="0.1.0",
            build="2",
            release_name="0.1.0",
            include_helper=True,
        )
        stable_environment = environment | {
            "BLOCKS_TEST_CHANNEL": "direct-stable",
        }
        result = subprocess.run(
            ["bash", str(audit_script), "--channel", "direct-stable", "--app", str(app)],
            text=True,
            capture_output=True,
            env=stable_environment,
            check=False,
        )
        require(
            result.returncode == 0,
            f"valid Direct stable structural fixture failed audit: {result.stderr}",
        )


def verify_direct_signature_audit_is_hermetic() -> None:
    """Run the Direct signing branch against isolated, deterministic tool shims."""
    audit_script = ROOT / "script/release/audit_app_bundle.sh"
    expected_team = "ABCDE12345"
    expected_authority = "Developer ID Application: Blocks Test (ABCDE12345)"
    expected_sha1 = "0123456789ABCDEF0123456789ABCDEF01234567"
    expected_errors = {
        "main:deep-verify": "mock codesign deep verify failed\n",
        "main:team": "error: main app TeamIdentifier differs from expected Team ID\n",
        "clipboard:team": (
            "error: signing TeamIdentifier differs from expected Team ID for "
            "Contents/MacOS/BlocksClipboardBroker\n"
        ),
        "plugin-container:team": (
            "error: signing TeamIdentifier differs from expected Team ID for "
            "Contents/XPCServices/BlocksPluginRunner.xpc\n"
        ),
        "main:sha": "error: signing certificate SHA-1 differs for <app>\n",
        "cli:sha": "error: signing certificate SHA-1 differs for Contents/Resources/CLI/blocks\n",
        "plugin-container:sha": (
            "error: signing certificate SHA-1 differs for "
            "Contents/XPCServices/BlocksPluginRunner.xpc\n"
        ),
        "main:runtime": "error: signature does not enable Hardened Runtime: <app>\n",
        "plugin:runtime": (
            "error: signature does not enable Hardened Runtime: "
            "Contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner\n"
        ),
        "main:entitlement-extra": (
            "error: unexpected signed entitlement for <app>: com.example.extra\n"
        ),
        "clipboard:entitlement-extra": (
            "error: unexpected signed entitlement for "
            "Contents/MacOS/BlocksClipboardBroker: com.example.extra\n"
        ),
        "plugin:entitlement-extra": (
            "error: unexpected signed entitlement for "
            "Contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner: "
            "com.example.extra\n"
        ),
        "action:entitlement-extra": (
            "error: unexpected signed entitlement for "
            "Contents/MacOS/BlocksActionBroker: com.example.extra\n"
        ),
        "cli:entitlement-extra": (
            "error: unexpected signed entitlement for Contents/Resources/CLI/blocks: "
            "com.example.extra\n"
        ),
        "clipboard:identifier": (
            "error: signing Identifier differs for Contents/MacOS/BlocksClipboardBroker\n"
        ),
        "plugin:identifier": (
            "error: signing Identifier differs for "
            "Contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner\n"
        ),
        "action:identifier": (
            "error: signing Identifier differs for Contents/MacOS/BlocksActionBroker\n"
        ),
        "cli:identifier": (
            "error: signing Identifier differs for Contents/Resources/CLI/blocks\n"
        ),
        "main:authority": "error: signing Authority differs for <app>\n",
        "action:authority": (
            "error: signing Authority differs for Contents/MacOS/BlocksActionBroker\n"
        ),
        "plugin-container:authority": (
            "error: signing Authority differs for Contents/XPCServices/BlocksPluginRunner.xpc\n"
        ),
        "clipboard:verify": "mock codesign verify failed\n",
        "main:keychain-missing": (
            "error: Direct app keychain-access-groups is missing or has a non-default first group\n"
        ),
        "main:keychain-wrong": (
            "error: Direct app keychain-access-groups is missing or has a non-shared second group\n"
        ),
        "main:keychain-extra": (
            "error: Direct app keychain-access-groups must contain exactly default and shared groups\n"
        ),
    }
    require(len(expected_errors) == 25, "Direct signature fixture mutation count drifted")

    def write_shim(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def write_bundle(temporary_root: Path) -> Path:
        app = temporary_root / "Blocks.app"
        contents = app / "Contents"
        info = {
            "LSMinimumSystemVersion": "14.0",
            "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
            "CFBundleIdentifier": "app.blocks.app",
            "CFBundleDisplayName": "Blocks for Mac",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "BLOCKS_RELEASE_NAME": "0.1.0-beta.1",
            "BLOCKS_RELEASE_PAGE_URL": "https://blocks.orangeforge.top/releases/",
            "BLOCKS_SUPPORT_URL": "https://blocks.orangeforge.top/support/",
            "BLOCKS_PRIVACY_URL": "https://blocks.orangeforge.top/privacy/",
            "BLOCKS_SELECTION_HELPER_DOWNLOAD_URL": (
                "https://downloads.orangeforge.top/beta/0.1.0-beta.1/"
                "Blocks-Selection-Helper-0.1.0-beta.1-arm64.dmg"
            ),
        }
        (contents / "Info.plist").parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        for language, display_name in {
            "en": "Blocks for Mac",
            "ja": "Blocks for Mac",
            "zh-Hans": "积木工具",
        }.items():
            strings_file = contents / f"Resources/{language}.lproj/InfoPlist.strings"
            strings_file.parent.mkdir(parents=True, exist_ok=True)
            strings_file.write_bytes(plistlib.dumps({"CFBundleDisplayName": display_name}))
        for relative in [
            "MacOS/Blocks",
            "MacOS/BlocksClipboardBroker",
            "XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner",
            "MacOS/BlocksActionBroker",
            "Resources/CLI/blocks",
            "Library/LaunchAgents/app.blocks.action-broker.plist",
            "Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper",
            "Frameworks/Sparkle.framework/Versions/B/Sparkle",
            "Frameworks/Sparkle.framework/Versions/B/Autoupdate",
            "Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
            "Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        ]:
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        helper_info = contents / "Helpers/Blocks Selection Helper.app/Contents/Info.plist"
        helper_info.write_bytes(plistlib.dumps({
            "LSMinimumSystemVersion": "14.0",
            "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
            "CFBundleIdentifier": "app.blocks.selection-helper",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["blocks-selection-helper"]}],
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "BLOCKS_RELEASE_NAME": "0.1.0-beta.1",
        }))
        (contents / "Helpers/Blocks Selection Helper.app/Contents/MacOS/Blocks Selection Helper").chmod(0o755)
        return app

    def run_fixture(
        mutation: str | None, *, include_authority: bool = True, authority_value: str | None = None
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app = write_bundle(temporary_root)
            shims = temporary_root / "shims"
            shims.mkdir()
            trace = temporary_root / "signature-trace.txt"
            write_shim(
                shims / "lipo",
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -archs ]] || exit 2\n"
                "printf '%s\\n' arm64\n",
            )
            write_shim(
                shims / "file",
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -b ]] || exit 2\n"
                "case \"$2\" in\n"
                "  */Contents/MacOS/Blocks|*/Contents/MacOS/BlocksClipboardBroker|*/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner|*/Contents/MacOS/BlocksActionBroker|*/Contents/Resources/CLI/blocks) printf '%s\\n' Mach-O ;;\n"
                "  *) printf '%s\\n' data ;;\n"
                "esac\n",
            )
            write_shim(
                shims / "openssl",
                "#!/usr/bin/env bash\n"
                "input=''\n"
                "while (($#)); do\n"
                "  if [[ \"$1\" == -in ]]; then input=\"$2\"; shift 2; else shift; fi\n"
                "done\n"
                "component=$(/bin/cat \"$input\")\n"
                "mutation=\"${BLOCKS_TEST_SIGNATURE_MUTATION:-}\"\n"
                "mutation_target=\"${mutation%%:*}\"\n"
                "mutation_property=\"${mutation#*:}\"\n"
                "if [[ \"$mutation_target\" == \"$component\" && \"$mutation_property\" == sha ]]; then\n"
                "  printf '%s\\n' 'sha1 Fingerprint=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'\n"
                "else\n"
                "  printf '%s\\n' 'sha1 Fingerprint=0123456789ABCDEF0123456789ABCDEF01234567'\n"
                "fi\n",
            )
            write_shim(
                shims / "plutil",
                "#!/usr/bin/env bash\n"
                "exec /usr/bin/python3 - \"$@\" <<'PY'\n"
                "import plistlib\n"
                "import sys\n"
                "\n"
                "args = sys.argv[1:]\n"
                "if args[:1] == ['-lint']:\n"
                "    source = args[-1]\n"
                "    if source == '-':\n"
                "        plistlib.loads(sys.stdin.buffer.read())\n"
                "    else:\n"
                "        plistlib.load(open(source, 'rb'))\n"
                "    raise SystemExit(0)\n"
                "if len(args) < 4 or args[0] != '-extract' or args[2] != 'raw':\n"
                "    raise SystemExit(2)\n"
                "key, source = args[1], args[-1]\n"
                "if source == '-':\n"
                "    value = plistlib.loads(sys.stdin.buffer.read())\n"
                "else:\n"
                "    value = plistlib.load(open(source, 'rb'))\n"
                "for component in key.split('.'):\n"
                "    value = value[int(component)] if component.isdigit() else value[component]\n"
                "if '-expect' in args and args[args.index('-expect') + 1] == 'string' and not isinstance(value, str):\n"
                "    raise SystemExit(1)\n"
                "if isinstance(value, bool):\n"
                "    print(str(value).lower())\n"
                "elif isinstance(value, str):\n"
                "    print(value, end='' if '-n' in args else '\\n')\n"
                "else:\n"
                "    raise SystemExit(1)\n"
                "PY\n",
            )
            write_shim(
                shims / "codesign",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "trace() { printf '%s|%s\\n' \"$1\" \"$2\" >> \"$BLOCKS_SIGNATURE_TRACE\"; }\n"
                "role() {\n"
                "  case \"$1\" in\n"
                "    *.app) printf '%s' main ;;\n"
                "    */MacOS/BlocksClipboardBroker) printf '%s' clipboard ;;\n"
                "    */XPCServices/BlocksPluginRunner.xpc) printf '%s' plugin-container ;;\n"
                "    */BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner) printf '%s' plugin ;;\n"
                "    */MacOS/BlocksActionBroker) printf '%s' action ;;\n"
                "    */Resources/CLI/blocks) printf '%s' cli ;;\n"
                "    *) exit 2 ;;\n"
                "  esac\n"
                "}\n"
                "component=\"${!#}\"\n"
                "component_role=$(role \"$component\")\n"
                "mutation=\"${BLOCKS_TEST_SIGNATURE_MUTATION:-}\"\n"
                "mutation_target=\"${mutation%%:*}\"\n"
                "mutation_property=\"${mutation#*:}\"\n"
                "if [[ \"$1\" == --verify ]]; then\n"
                "  if [[ \"$2\" == --deep ]]; then\n"
                "    trace verify-deep \"$component_role\"\n"
                "    if [[ \"$mutation_target\" == main && \"$mutation_property\" == deep-verify ]]; then echo 'mock codesign deep verify failed' >&2; exit 1; fi\n"
                "  else\n"
                "    trace verify \"$component_role\"\n"
                "    if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == verify ]]; then echo 'mock codesign verify failed' >&2; exit 1; fi\n"
                "  fi\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -dvv ]]; then\n"
                "  trace dvv \"$component_role\"\n"
                "  team=ABCDE12345\n"
                "  identifier=app.blocks.app\n"
                "  case \"$component_role\" in clipboard) identifier=app.blocks.clipboard-broker ;; plugin-container|plugin) identifier=app.blocks.plugin-runner ;; action) identifier=app.blocks.action-broker ;; cli) identifier=app.blocks.cli ;; esac\n"
                "  [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == team ]] && team=ZZZZZ99999\n"
                "  [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == identifier ]] && identifier=app.blocks.wrong\n"
                "  authority='Developer ID Application: Blocks Test (ABCDE12345)'\n"
                "  [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == authority ]] && authority='Developer ID Application: Blocks Test (ABCDE12345) extra'\n"
                "  printf 'Identifier=%s\\nTeamIdentifier=%s\\nAuthority=%s\\n' \"$identifier\" \"$team\" \"$authority\"\n"
                "  if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == runtime ]]; then printf '%s\\n' 'flags=0x0'; else printf '%s\\n' 'flags=0x10000(runtime)'; fi\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -d && \"$2\" == --extract-certificates ]]; then\n"
                "  trace cert \"$component_role\"\n"
                "  printf '%s' \"$component_role\" > \"${3}0\"\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -d && \"$2\" == --entitlements && \"$3\" == :- ]]; then\n"
                "  trace entitlements \"$component_role\"\n"
                "  exec /usr/bin/python3 - \"$component_role\" \"$mutation\" <<'PY'\n"
                "import plistlib\n"
                "import sys\n"
                "role, mutation = sys.argv[1:]\n"
                "mutation_target, _, mutation_property = mutation.partition(':')\n"
                "team = 'ABCDE12345'\n"
                "identifiers = {'main': 'app.blocks.app', 'clipboard': 'app.blocks.clipboard-broker', 'plugin': 'app.blocks.plugin-runner', 'action': 'app.blocks.action-broker', 'cli': 'app.blocks.cli'}\n"
                "values = {'com.apple.application-identifier': team + '.' + identifiers[role], 'com.apple.developer.team-identifier': team}\n"
                "if role == 'main':\n"
                "    values.update({'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-write': True, 'com.apple.security.network.client': True, 'com.apple.security.temporary-exception.files.absolute-path.read-only': ['/Applications/Blocks Selection Helper.app/'], 'com.apple.security.temporary-exception.mach-lookup.global-name': ['app.blocks.action-broker.xpc'], 'keychain-access-groups': [team + '.app.blocks.app', team + '.app.blocks.selection-helper.shared']})\n"
                "    if mutation_target == 'main' and mutation_property == 'keychain-missing': values.pop('keychain-access-groups')\n"
                "    if mutation_target == 'main' and mutation_property == 'keychain-wrong': values['keychain-access-groups'][1] = team + '.app.blocks.wrong'\n"
                "    if mutation_target == 'main' and mutation_property == 'keychain-extra': values['keychain-access-groups'].append(team + '.app.blocks.extra')\n"
                "elif role == 'clipboard':\n"
                "    values.update({'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})\n"
                "else:\n"
                "    values.update({'com.apple.security.app-sandbox': True}) if role in {'plugin', 'action'} else None\n"
                "if mutation_target == role and mutation_property == 'entitlement-extra': values['com.example.extra'] = True\n"
                "sys.stdout.buffer.write(plistlib.dumps(values))\n"
                "PY\n"
                "fi\n"
                "exit 2\n",
            )
            plutil_path = shims / "plutil"
            plutil_path.write_text(
                "#!/usr/bin/env bash\n"
                "exec /usr/bin/python3 - \"$@\" <<'PY'\n"
                "import plistlib, sys\n"
                "args = sys.argv[1:]\n"
                "if args[:1] == ['-lint']:\n"
                "    source = args[-1]\n"
                "    plistlib.loads(sys.stdin.buffer.read()) if source == '-' else plistlib.load(open(source, 'rb'))\n"
                "    raise SystemExit(0)\n"
                "if len(args) < 4 or args[0] != '-extract' or args[2] != 'raw': raise SystemExit(2)\n"
                "source = args[-1]\n"
                "value = plistlib.loads(sys.stdin.buffer.read()) if source == '-' else plistlib.load(open(source, 'rb'))\n"
                "parts = args[1].split('.')\n"
                "while parts:\n"
                "    if parts[0].isdigit(): value = value[int(parts.pop(0))]; continue\n"
                "    for count in range(len(parts), 0, -1):\n"
                "        candidate = '.'.join(parts[:count])\n"
                "        if isinstance(value, dict) and candidate in value:\n"
                "            value = value[candidate]; parts = parts[count:]; break\n"
                "    else: raise KeyError('.'.join(parts))\n"
                "if '-expect' in args and args[args.index('-expect') + 1] == 'string' and not isinstance(value, str): raise SystemExit(1)\n"
                "if isinstance(value, bool): print(str(value).lower())\n"
                "elif isinstance(value, str): print(value, end='' if '-n' in args else '\\n')\n"
                "else: raise SystemExit(1)\n"
                "PY\n",
                encoding="utf-8",
            )
            file_path = shims / "file"
            file_path.write_text(
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -b ]] || exit 2\n"
                "case \"$2\" in\n"
                "  */Contents/MacOS/Blocks|*/Contents/MacOS/BlocksClipboardBroker|*/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner|*/Contents/MacOS/BlocksActionBroker|*/Contents/Resources/CLI/blocks|*/Contents/Helpers/Blocks\\ Selection\\ Helper.app/Contents/MacOS/Blocks\\ Selection\\ Helper|*/Sparkle.framework/Versions/B/Sparkle|*/Sparkle.framework/Versions/B/Autoupdate|*/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater|*/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer|*/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader) printf '%s\\n' Mach-O ;;\n"
                "  *) printf '%s\\n' data ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            codesign_path = shims / "codesign"
            codesign_source = codesign_path.read_text(encoding="utf-8")
            newline = chr(10)
            codesign_source = codesign_source.replace(
                "    *.app) printf '%s' main ;" + newline,
                "    */Helpers/Blocks\\ Selection\\ Helper.app) printf '%s' helper ;" + newline +
                "    */Frameworks/Sparkle.framework) printf '%s' sparkle-framework ;" + newline +
                "    */Sparkle.framework/Versions/B/Updater.app) printf '%s' sparkle-updater ;" + newline +
                "    */Sparkle.framework/Versions/B/XPCServices/Installer.xpc) printf '%s' sparkle-installer ;" + newline +
                "    */Sparkle.framework/Versions/B/XPCServices/Downloader.xpc) printf '%s' sparkle-downloader ;" + newline +
                "    */Sparkle.framework/Versions/B/Autoupdate) printf '%s' sparkle-autoupdate ;" + newline +
                "    *.app) printf '%s' main ;" + newline,
            )
            codesign_source = codesign_source.replace(
                "role() {" + newline,
                "role() {" + newline
                + "  case \"$1\" in" + newline
                + "    */Helpers/Blocks\\ Selection\\ Helper.app) printf '%s' helper; return ;;" + newline
                + "    */Frameworks/Sparkle.framework) printf '%s' sparkle-framework; return ;;" + newline
                + "    */Sparkle.framework/Versions/B/Updater.app) printf '%s' sparkle-updater; return ;;" + newline
                + "    */Sparkle.framework/Versions/B/XPCServices/Installer.xpc) printf '%s' sparkle-installer; return ;;" + newline
                + "    */Sparkle.framework/Versions/B/XPCServices/Downloader.xpc) printf '%s' sparkle-downloader; return ;;" + newline
                + "    */Sparkle.framework/Versions/B/Autoupdate) printf '%s' sparkle-autoupdate; return ;;" + newline
                + "  esac" + newline,
            )
            codesign_source = codesign_source.replace(
                "case \"$component_role\" in clipboard) identifier=app.blocks.clipboard-broker ;; plugin-container|plugin) identifier=app.blocks.plugin-runner ;; action) identifier=app.blocks.action-broker ;; cli) identifier=app.blocks.cli ;; esac",
                "case \"$component_role\" in helper) identifier=app.blocks.selection-helper ;; clipboard) identifier=app.blocks.clipboard-broker ;; plugin-container|plugin) identifier=app.blocks.plugin-runner ;; action) identifier=app.blocks.action-broker ;; cli) identifier=app.blocks.cli ;; esac",
            )
            codesign_source = codesign_source.replace(
                "printf 'Identifier=%s\\nTeamIdentifier=%s\\nAuthority=%s\\n' \"$identifier\" \"$team\" \"$authority\"",
                "printf 'Identifier=%s\\nTeamIdentifier=%s\\nAuthority=%s\\nTimestamp=fixture\\n' \"$identifier\" \"$team\" \"$authority\"",
            )
            codesign_source = codesign_source.replace(
                "'cli': 'app.blocks.cli'}",
                "'cli': 'app.blocks.cli', 'helper': 'app.blocks.selection-helper', 'sparkle-framework': 'app.blocks.sparkle', 'sparkle-updater': 'app.blocks.sparkle-updater', 'sparkle-installer': 'app.blocks.sparkle-installer', 'sparkle-downloader': 'app.blocks.sparkle-downloader', 'sparkle-autoupdate': 'app.blocks.sparkle-autoupdate'}",
            )
            codesign_source = codesign_source.replace(
                "['app.blocks.action-broker.xpc'], 'keychain-access-groups'",
                "['app.blocks.action-broker.xpc', 'app.blocks.app-spks', 'app.blocks.app-spki'], 'keychain-access-groups'",
            )
            codesign_source = codesign_source.replace(
                "elif role == 'clipboard':",
                "elif role == 'helper':\n    values = {'com.apple.application-identifier': team + '.app.blocks.selection-helper', 'com.apple.developer.team-identifier': team, 'keychain-access-groups': [team + '.app.blocks.selection-helper.shared']}\nelif role == 'clipboard':",
            )
            codesign_path.write_text(codesign_source, encoding="utf-8")
            environment = {
                "PATH": f"{shims}:/usr/bin:/bin",
                "TMPDIR": str(temporary_root),
                "BLOCKS_SIGNATURE_TRACE": str(trace),
            }
            if mutation is not None:
                environment["BLOCKS_TEST_SIGNATURE_MUTATION"] = mutation
            command = [
                    "bash",
                    str(audit_script),
                    "--channel",
                    "direct-beta",
                    "--app",
                    str(app),
                    "--require-signature",
                    "--expected-team-id",
                    expected_team,
            ]
            if include_authority:
                command += ["--expected-authority", authority_value or expected_authority]
            command += ["--expected-cert-sha1", expected_sha1]
            result = run_controlled_fixture(
                command,
                cwd=ROOT,
                environment=environment,
                name=f"direct-signature-{mutation or 'baseline'}",
            )
            if mutation is not None and mutation.startswith("plugin-container:"):
                trace_lines = trace.read_text(encoding="utf-8").splitlines()
                require(
                    not any(
                        line.rsplit("|", 1)[-1] in {"plugin", "action", "cli"}
                        for line in trace_lines
                    ),
                    "XPC container identity failure continued into a later signed component",
                )
            if mutation == "main:entitlement-extra":
                require(
                    not list(temporary_root.glob("blocks-component-entitlements.*")),
                    "component entitlement audit failure leaked its temporary plist",
                )
            if mutation is None and include_authority and authority_value is None:
                require(
                    result.returncode == 0,
                    f"valid hermetic signature fixture failed audit: stdout={result.stdout!r} stderr={result.stderr!r}",
                )
                trace_lines = trace.read_text(encoding="utf-8").splitlines()
                for component in ["main", "clipboard", "plugin", "action", "cli"]:
                    for operation in ["verify", "dvv", "cert", "entitlements"]:
                        require(
                            f"{operation}|{component}" in trace_lines,
                            f"signature audit did not {operation} {component}",
                        )
                for operation in ["verify", "dvv", "cert"]:
                    require(
                        f"{operation}|plugin-container" in trace_lines,
                        f"signature audit did not {operation} the XPC service container",
                    )
                require(
                    "verify-deep|main" in trace_lines,
                    "signature audit did not deep-verify the app bundle",
                )
            return result, result.stderr.replace(str(app), "<app>")

    baseline, _ = run_fixture(None)
    require(baseline.returncode == 0, "hermetic signature baseline did not pass")
    missing_authority, missing_authority_error = run_fixture(None, include_authority=False)
    require(
        missing_authority.returncode == 2
        and "--require-signature requires an explicit non-empty --expected-authority"
        in missing_authority_error,
        "Direct signature audit accepted a missing expected Authority",
    )
    for invalid_authority in [
        "Apple Distribution: Blocks Test (ABCDE12345)",
        "Developer ID Application: Blocks Test (ZZZZZ99999)",
        "Developer ID Application: Blocks Test (ABCDE12345)\nAuthority=forged",
    ]:
        result, error = run_fixture(None, authority_value=invalid_authority)
        require(result.returncode != 0, "Direct audit accepted an invalid expected Authority")
        require("--expected-authority" in error, "Direct invalid Authority failure was not explicit")
    for mutation, expected_error in expected_errors.items():
        result, normalized_error = run_fixture(mutation)
        require(result.returncode != 0, f"signature mutation unexpectedly passed: {mutation}")
        require(
            normalized_error == expected_error,
            f"signature mutation did not fail closed with a stable error: {mutation}: {normalized_error!r}",
        )
def verify_store_signature_audit_is_hermetic() -> None:
    """Run the Store signing branch against isolated, deterministic tool shims."""
    audit_script = ROOT / "script/release/audit_app_bundle.sh"
    expected_team = "ABCDE12345"
    expected_authority = "Apple Distribution: Blocks Test (ABCDE12345)"
    expected_sha1 = "0123456789ABCDEF0123456789ABCDEF01234567"
    expected_errors = {
        "main:deep-verify": "mock codesign deep verify failed\n",
        "main:authority": "error: signing Authority differs for <app>\n",
        "clipboard:verify": "mock codesign verify failed\n",
        "clipboard:team": (
            "error: signing TeamIdentifier differs from expected Team ID for "
            "Contents/MacOS/BlocksClipboardBroker\n"
        ),
        "plugin-container:team": (
            "error: signing TeamIdentifier differs from expected Team ID for "
            "Contents/XPCServices/BlocksPluginRunner.xpc\n"
        ),
        "plugin:identifier": (
            "error: signing Identifier differs for "
            "Contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner\n"
        ),
        "clipboard:sha": (
            "error: signing certificate SHA-1 differs for "
            "Contents/MacOS/BlocksClipboardBroker\n"
        ),
        "plugin-container:sha": (
            "error: signing certificate SHA-1 differs for "
            "Contents/XPCServices/BlocksPluginRunner.xpc\n"
        ),
        "plugin-container:authority": (
            "error: signing Authority differs for Contents/XPCServices/BlocksPluginRunner.xpc\n"
        ),
        "plugin:runtime": (
            "error: signature does not enable Hardened Runtime: "
            "Contents/XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner\n"
        ),
        "clipboard:entitlement-extra": (
            "error: unexpected signed entitlement for "
            "Contents/MacOS/BlocksClipboardBroker: com.example.extra\n"
        ),
        "store:entitlement-extra": (
            "error: Store app signed entitlements differ from the allowed whitelist\n"
        ),
        "store:capability-false": (
            "error: Store app entitlement is not true: com.apple.security.app-sandbox\n"
        ),
        "store:app-id": (
            "error: Store app signed application identifier differs from expected App ID\n"
        ),
        "store:team": (
            "error: Store app signed team identifier differs from expected Team ID\n"
        ),
        "store:keychain-wrong": (
            "error: Store app keychain-access-groups contains a non-default group\n"
        ),
        "store:keychain-extra": (
            "error: Store app keychain-access-groups must contain exactly one default group\n"
        ),
        "store:keychain-shared": (
            "error: Store app keychain-access-groups must contain exactly one default group\n"
        ),
        "profile:cms": "error: Store embedded provisioning profile is not CMS-decodable\n",
        "profile:plist": "error: Store embedded provisioning profile is not a plist\n",
        "profile:team-missing": (
            "error: Store embedded provisioning profile is missing TeamIdentifier\n"
        ),
        "profile:team-wrong": (
            "error: Store embedded provisioning profile TeamIdentifier differs from "
            "expected Team ID\n"
        ),
        "profile:uuid-missing": "error: Store embedded provisioning profile is missing UUID\n",
        "profile:uuid-invalid": "error: Store embedded provisioning profile UUID is invalid\n",
        "profile:app-id": (
            "error: Store embedded provisioning profile application-identifier differs "
            "from expected App ID\n"
        ),
        "profile:entitlement-team": (
            "error: Store embedded provisioning profile entitlement team identifier "
            "differs from expected Team ID\n"
        ),
        "profile:expiration-missing": (
            "error: Store embedded provisioning profile is missing ExpirationDate\n"
        ),
        "profile:expiration-expired": (
            "error: Store embedded provisioning profile is expired or has an invalid "
            "ExpirationDate\n"
        ),
        "profile:capability-missing": (
            "error: Store embedded provisioning profile lacks required entitlement: "
            "com.apple.security.network.client\n"
        ),
    }
    require(len(expected_errors) == 29, "Store signature fixture mutation count drifted")

    def write_shim(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def write_bundle(temporary_root: Path) -> Path:
        app = temporary_root / "Blocks.app"
        contents = app / "Contents"
        info = {
            "LSMinimumSystemVersion": "14.0",
            "BLOCKS_DISTRIBUTION_CHANNEL": "app-store-beta",
            "CFBundleIdentifier": "app.blocks.app",
            "CFBundleDisplayName": "Blocks for Mac",
            "BLOCKS_RELEASE_PAGE_URL": "https://blocks.orangeforge.top/releases/",
            "BLOCKS_SUPPORT_URL": "https://blocks.orangeforge.top/support/",
            "BLOCKS_PRIVACY_URL": "https://blocks.orangeforge.top/privacy/",
            "BLOCKS_SELECTION_HELPER_DOWNLOAD_URL": "",
        }
        (contents / "Info.plist").parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        for language, display_name in {
            "en": "Blocks for Mac",
            "ja": "Blocks for Mac",
            "zh-Hans": "积木工具",
        }.items():
            strings_file = contents / f"Resources/{language}.lproj/InfoPlist.strings"
            strings_file.parent.mkdir(parents=True, exist_ok=True)
            strings_file.write_bytes(plistlib.dumps({"CFBundleDisplayName": display_name}))
        for relative in [
            "MacOS/Blocks",
            "MacOS/BlocksClipboardBroker",
            "XPCServices/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner",
            "embedded.provisionprofile",
        ]:
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        return app

    def run_fixture(
        mutation: str | None, *, include_authority: bool = True, authority_value: str | None = None
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app = write_bundle(temporary_root)
            shims = temporary_root / "shims"
            shims.mkdir()
            trace = temporary_root / "signature-trace.txt"
            write_shim(
                shims / "lipo",
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -archs ]] || exit 2\n"
                "printf '%s\\n' arm64\n",
            )
            write_shim(
                shims / "file",
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -b ]] || exit 2\n"
                "case \"$2\" in\n"
                "  */Contents/MacOS/Blocks|*/Contents/MacOS/BlocksClipboardBroker|*/BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner) printf '%s\\n' Mach-O ;;\n"
                "  *) printf '%s\\n' data ;;\n"
                "esac\n",
            )
            write_shim(
                shims / "openssl",
                "#!/usr/bin/env bash\n"
                "input=''\n"
                "while (($#)); do\n"
                "  if [[ \"$1\" == -in ]]; then input=\"$2\"; shift 2; else shift; fi\n"
                "done\n"
                "component=$(/bin/cat \"$input\")\n"
                "mutation=\"${BLOCKS_TEST_STORE_MUTATION:-}\"\n"
                "mutation_target=\"${mutation%%:*}\"\n"
                "mutation_property=\"${mutation#*:}\"\n"
                "if [[ \"$mutation_target\" == \"$component\" && \"$mutation_property\" == sha ]]; then\n"
                "  printf '%s\\n' 'sha1 Fingerprint=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'\n"
                "else\n"
                "  printf '%s\\n' 'sha1 Fingerprint=0123456789ABCDEF0123456789ABCDEF01234567'\n"
                "fi\n",
            )
            write_shim(
                shims / "plutil",
                "#!/usr/bin/python3\n"
                "import os\n"
                "import plistlib\n"
                "import sys\n"
                "\n"
                "def trace(event):\n"
                "    with open(os.environ['BLOCKS_SIGNATURE_TRACE'], 'a', encoding='utf-8') as handle:\n"
                "        handle.write(event + '\\n')\n"
                "\n"
                "def load(source):\n"
                "    data = sys.stdin.buffer.read() if source == '-' else open(source, 'rb').read()\n"
                "    return plistlib.loads(data)\n"
                "\n"
                "def extract(value, path):\n"
                "    parts = path.split('.')\n"
                "    while parts:\n"
                "        if isinstance(value, dict):\n"
                "            for length in range(len(parts), 0, -1):\n"
                "                candidate = '.'.join(parts[:length])\n"
                "                if candidate in value:\n"
                "                    value = value[candidate]\n"
                "                    parts = parts[length:]\n"
                "                    break\n"
                "            else:\n"
                "                raise KeyError(path)\n"
                "        elif isinstance(value, list):\n"
                "            value = value[int(parts.pop(0))]\n"
                "        else:\n"
                "            raise KeyError(path)\n"
                "    return value\n"
                "\n"
                "try:\n"
                "    args = sys.argv[1:]\n"
                "    if len(args) == 2 and args[0] == '-lint':\n"
                "        load(args[1])\n"
                "        trace('plutil|lint-profile' if args[1] == '-' else 'plutil|lint-file')\n"
                "    elif len(args) == 4 and args[0] == '-extract' and args[2] == 'raw':\n"
                "        key, source = args[1], args[3]\n"
                "        value = extract(load(source), key)\n"
                "        trace('plutil|profile:' + key if source == '-' else 'plutil|extract:' + key)\n"
                "        if isinstance(value, bool):\n"
                "            print(str(value).lower())\n"
                "        elif isinstance(value, str):\n"
                "            print(value)\n"
                "        else:\n"
                "            raise TypeError(key)\n"
                "    else:\n"
                "        raise ValueError(args)\n"
                "except Exception:\n"
                "    raise SystemExit(1)\n",
            )
            write_shim(
                shims / "security",
                "#!/usr/bin/python3\n"
                "import os\n"
                "import plistlib\n"
                "import sys\n"
                "\n"
                "def trace(event):\n"
                "    with open(os.environ['BLOCKS_SIGNATURE_TRACE'], 'a', encoding='utf-8') as handle:\n"
                "        handle.write(event + '\\n')\n"
                "\n"
                "if sys.argv[1:4] != ['cms', '-D', '-i']:\n"
                "    raise SystemExit(2)\n"
                "trace('security|cms')\n"
                "mutation = os.environ.get('BLOCKS_TEST_STORE_MUTATION', '')\n"
                "if mutation == 'profile:cms':\n"
                "    raise SystemExit(1)\n"
                "if mutation == 'profile:plist':\n"
                "    sys.stdout.write('not a plist')\n"
                "    raise SystemExit(0)\n"
                "team = 'ABCDE12345'\n"
                "profile = {\n"
                "    'TeamIdentifier': [team],\n"
                "    'UUID': '12345678-1234-1234-1234-1234567890ab',\n"
                "    'Entitlements': {\n"
                "        'application-identifier': team + '.app.blocks.app',\n"
                "        'com.apple.developer.team-identifier': team,\n"
                "        'com.apple.security.app-sandbox': True,\n"
                "        'com.apple.security.files.user-selected.read-write': True,\n"
                "        'com.apple.security.network.client': True,\n"
                "    },\n"
                "    'ExpirationDate': '2099-01-01T00:00:00Z',\n"
                "}\n"
                "if mutation == 'profile:team-missing':\n"
                "    profile.pop('TeamIdentifier')\n"
                "elif mutation == 'profile:team-wrong':\n"
                "    profile['TeamIdentifier'] = ['ZZZZZ99999']\n"
                "elif mutation == 'profile:uuid-missing':\n"
                "    profile.pop('UUID')\n"
                "elif mutation == 'profile:uuid-invalid':\n"
                "    profile['UUID'] = 'invalid-uuid'\n"
                "elif mutation == 'profile:app-id':\n"
                "    profile['Entitlements']['application-identifier'] = team + '.app.blocks.wrong'\n"
                "elif mutation == 'profile:entitlement-team':\n"
                "    profile['Entitlements']['com.apple.developer.team-identifier'] = 'ZZZZZ99999'\n"
                "elif mutation == 'profile:expiration-missing':\n"
                "    profile.pop('ExpirationDate')\n"
                "elif mutation == 'profile:expiration-expired':\n"
                "    profile['ExpirationDate'] = '2000-01-01T00:00:00Z'\n"
                "elif mutation == 'profile:capability-missing':\n"
                "    profile['Entitlements'].pop('com.apple.security.network.client')\n"
                "sys.stdout.buffer.write(plistlib.dumps(profile))\n",
            )
            write_shim(
                shims / "date",
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == -j ]]; then\n"
                "  [[ \"${2:-}\" == -f && \"${5:-}\" == +%s ]] || exit 2\n"
                "  case \"${4:-}\" in\n"
                "    2099-*) printf '%s\\n' 4102444800 ;;\n"
                "    2000-*) printf '%s\\n' 100 ;;\n"
                "    *) exit 1 ;;\n"
                "  esac\n"
                "elif [[ \"${1:-}\" == +%s ]]; then\n"
                "  printf '%s\\n' 200\n"
                "else\n"
                "  exit 2\n"
                "fi\n",
            )
            write_shim(
                shims / "codesign",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "trace() { printf '%s|%s\\n' \"$1\" \"$2\" >> \"$BLOCKS_SIGNATURE_TRACE\"; }\n"
                "role() {\n"
                "  case \"$1\" in\n"
                "    *.app) printf '%s' main ;;\n"
                "    */MacOS/BlocksClipboardBroker) printf '%s' clipboard ;;\n"
                "    */XPCServices/BlocksPluginRunner.xpc) printf '%s' plugin-container ;;\n"
                "    */BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner) printf '%s' plugin ;;\n"
                "    *) exit 2 ;;\n"
                "  esac\n"
                "}\n"
                "component=\"${!#}\"\n"
                "component_role=$(role \"$component\")\n"
                "mutation=\"${BLOCKS_TEST_STORE_MUTATION:-}\"\n"
                "mutation_target=\"${mutation%%:*}\"\n"
                "mutation_property=\"${mutation#*:}\"\n"
                "if [[ \"$1\" == --verify ]]; then\n"
                "  if [[ \"$2\" == --deep ]]; then\n"
                "    trace verify-deep \"$component_role\"\n"
                "    if [[ \"$mutation_target\" == main && \"$mutation_property\" == deep-verify ]]; then echo 'mock codesign deep verify failed' >&2; exit 1; fi\n"
                "  else\n"
                "    trace verify \"$component_role\"\n"
                "    if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == verify ]]; then echo 'mock codesign verify failed' >&2; exit 1; fi\n"
                "  fi\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -dvv ]]; then\n"
                "  trace dvv \"$component_role\"\n"
                "  team=ABCDE12345\n"
                "  identifier=app.blocks.app\n"
                "  case \"$component_role\" in clipboard) identifier=app.blocks.clipboard-broker ;; plugin-container|plugin) identifier=app.blocks.plugin-runner ;; esac\n"
                "  if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == team ]]; then team=ZZZZZ99999; fi\n"
                "  if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == identifier ]]; then identifier=app.blocks.wrong; fi\n"
                "  authority='Apple Distribution: Blocks Test (ABCDE12345)'\n"
                "  if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == authority ]]; then authority='Apple Distribution: Blocks Test (ABCDE12345) extra'; fi\n"
                "  printf 'Identifier=%s\\nTeamIdentifier=%s\\nAuthority=%s\\n' \"$identifier\" \"$team\" \"$authority\"\n"
                "  if [[ \"$mutation_target\" == \"$component_role\" && \"$mutation_property\" == runtime ]]; then printf '%s\\n' 'flags=0x0'; else printf '%s\\n' 'flags=0x10000(runtime)'; fi\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -d && \"$2\" == --extract-certificates ]]; then\n"
                "  trace cert \"$component_role\"\n"
                "  printf '%s' \"$component_role\" > \"${3}0\"\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -d && \"$2\" == --entitlements && \"$3\" == :- ]]; then\n"
                "  trace entitlements \"$component_role\"\n"
                "  exec /usr/bin/python3 - \"$component_role\" \"$mutation\" <<'PY'\n"
                "import plistlib\n"
                "import sys\n"
                "role, mutation = sys.argv[1:]\n"
                "target, _, property_name = mutation.partition(':')\n"
                "team = 'ABCDE12345'\n"
                "identifiers = {\n"
                "    'main': 'app.blocks.app',\n"
                "    'clipboard': 'app.blocks.clipboard-broker',\n"
                "    'plugin': 'app.blocks.plugin-runner',\n"
                "}\n"
                "values = {\n"
                "    'com.apple.application-identifier': team + '.' + identifiers[role],\n"
                "    'com.apple.developer.team-identifier': team,\n"
                "}\n"
                "if role == 'main':\n"
                "    values.update({\n"
                "        'com.apple.security.app-sandbox': True,\n"
                "        'com.apple.security.files.user-selected.read-write': True,\n"
                "        'com.apple.security.network.client': True,\n"
                "        'keychain-access-groups': [team + '.app.blocks.app'],\n"
                "    })\n"
                "    if target == 'store' and property_name == 'entitlement-extra': values['com.example.extra'] = True\n"
                "    if target == 'store' and property_name == 'capability-false': values['com.apple.security.app-sandbox'] = False\n"
                "    if target == 'store' and property_name == 'app-id': values['com.apple.application-identifier'] = team + '.app.blocks.wrong'\n"
                "    if target == 'store' and property_name == 'team': values['com.apple.developer.team-identifier'] = 'ZZZZZ99999'\n"
                "    if target == 'store' and property_name == 'keychain-wrong': values['keychain-access-groups'] = ['ZZZZZ99999.app.blocks.app']\n"
                "    if target == 'store' and property_name == 'keychain-extra': values['keychain-access-groups'].append(team + '.app.blocks.extra')\n"
                "    if target == 'store' and property_name == 'keychain-shared': values['keychain-access-groups'].append(team + '.app.blocks.selection-helper.shared')\n"
                "elif role == 'clipboard':\n"
                "    values.update({'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})\n"
                "elif role == 'plugin':\n"
                "    values.update({'com.apple.security.app-sandbox': True})\n"
                "if target == role and property_name == 'entitlement-extra': values['com.example.extra'] = True\n"
                "sys.stdout.buffer.write(plistlib.dumps(values))\n"
                "PY\n"
                "fi\n"
                "exit 2\n",
            )
            environment = {
                "PATH": f"{shims}:/usr/bin:/bin",
                "TMPDIR": str(temporary_root),
                "BLOCKS_SIGNATURE_TRACE": str(trace),
            }
            if mutation is not None:
                environment["BLOCKS_TEST_STORE_MUTATION"] = mutation
            command = [
                    "bash",
                    str(audit_script),
                    "--channel",
                    "app-store-beta",
                    "--app",
                    str(app),
                    "--require-signature",
                    "--expected-team-id",
                    expected_team,
            ]
            if include_authority:
                command += ["--expected-authority", authority_value or expected_authority]
            command += ["--expected-cert-sha1", expected_sha1]
            result = subprocess.run(
                command,
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            if mutation is not None and mutation.startswith("plugin-container:"):
                trace_lines = trace.read_text(encoding="utf-8").splitlines()
                require(
                    not any(
                        line.rsplit("|", 1)[-1] == "plugin" for line in trace_lines
                    )
                    and "security|cms" not in trace_lines,
                    "Store XPC container identity failure continued into a later release action",
                )
            if mutation is None and include_authority and authority_value is None:
                require(
                    result.returncode == 0,
                    f"valid hermetic Store signature fixture failed audit: {result.stderr}",
                )
                trace_lines = trace.read_text(encoding="utf-8").splitlines()
                for component in ["main", "clipboard", "plugin"]:
                    for operation in ["verify", "dvv", "cert", "entitlements"]:
                        require(
                            f"{operation}|{component}" in trace_lines,
                            f"Store signature audit did not {operation} {component}",
                        )
                for operation in ["verify", "dvv", "cert"]:
                    require(
                        f"{operation}|plugin-container" in trace_lines,
                        f"Store signature audit did not {operation} the XPC service container",
                    )
                require(
                    "verify-deep|main" in trace_lines,
                    "Store signature audit did not deep-verify the app bundle",
                )
                require(
                    trace_lines.count("entitlements|main") == 2,
                    "Store signature audit did not perform its second main-entitlement check",
                )
                require(
                    "security|cms" in trace_lines and "plutil|lint-profile" in trace_lines,
                    "Store signature audit did not CMS-decode and lint the provisioning profile",
                )
                for key in [
                    "TeamIdentifier.0",
                    "UUID",
                    "Entitlements.application-identifier",
                    "Entitlements.com.apple.developer.team-identifier",
                    "ExpirationDate",
                    "Entitlements.com.apple.security.app-sandbox",
                    "Entitlements.com.apple.security.files.user-selected.read-write",
                    "Entitlements.com.apple.security.network.client",
                ]:
                    require(
                        f"plutil|profile:{key}" in trace_lines,
                        f"Store signature audit did not read profile field: {key}",
                    )
            return result, result.stderr.replace(str(app), "<app>")

    baseline, _ = run_fixture(None)
    require(baseline.returncode == 0, "hermetic Store signature baseline did not pass")
    missing_authority, missing_authority_error = run_fixture(None, include_authority=False)
    require(
        missing_authority.returncode == 2
        and "--require-signature requires an explicit non-empty --expected-authority"
        in missing_authority_error,
        "Store signature audit accepted a missing expected Authority",
    )
    for invalid_authority in [
        "Developer ID Application: Blocks Test (ABCDE12345)",
        "Apple Distribution: Blocks Test (ZZZZZ99999)",
        "Apple Distribution: Blocks Test (ABCDE12345)\r\nAuthority=forged",
    ]:
        result, error = run_fixture(None, authority_value=invalid_authority)
        require(result.returncode != 0, "Store audit accepted an invalid expected Authority")
        require("--expected-authority" in error, "Store invalid Authority failure was not explicit")
    for mutation, expected_error in expected_errors.items():
        result, normalized_error = run_fixture(mutation)
        require(result.returncode != 0, f"Store signature mutation unexpectedly passed: {mutation}")
        require(
            normalized_error == expected_error,
            f"Store signature mutation did not fail closed with a stable error: "
            f"{mutation}: {normalized_error!r}",
        )


def verify_selection_helper_signature_audit_is_hermetic() -> None:
    """Run the Helper signing branch against isolated, deterministic tool shims."""
    audit_script = ROOT / "script/release/audit_selection_helper_bundle.sh"
    expected_team = "ABCDE12345"
    expected_authority = "Developer ID Application: Blocks Test (ABCDE12345)"
    expected_sha1 = "0123456789ABCDEF0123456789ABCDEF01234567"
    expected_errors = {
        "helper:deep-verify": "mock codesign deep verify failed\n",
        "helper:team": "error: Helper TeamIdentifier differs from expected Team ID\n",
        "helper:identifier": (
            "error: Helper signing Identifier differs from expected bundle identifier\n"
        ),
        "helper:authority": (
            "error: Helper signing Authority differs from expected Authority\n"
        ),
        "helper:sha": (
            "error: Helper signing certificate SHA-1 differs from expected certificate\n"
        ),
        "helper:runtime": "error: Helper signature does not enable Hardened Runtime\n",
        "helper:entitlement-team": "error: Helper signed entitlement Team ID differs\n",
        "helper:entitlement-app-id": "error: Helper signed application identifier differs\n",
        "helper:entitlement-extra": (
            "error: unexpected Helper signed entitlement: com.example.extra\n"
        ),
        "helper:keychain-missing": (
            "error: Helper signed keychain-access-groups is missing or contains a non-shared group\n"
        ),
        "helper:keychain-wrong": (
            "error: Helper signed keychain-access-groups is missing or contains a non-shared group\n"
        ),
        "helper:keychain-extra": (
            "error: Helper signed keychain-access-groups must contain exactly one shared group\n"
        ),
        "helper:nested-mach-o": (
            "error: unexpected nested Helper executable: Contents/Resources/InjectedMachO\n"
        ),
    }
    require(len(expected_errors) == 13, "Helper signature fixture mutation count drifted")

    def write_shim(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def write_bundle(temporary_root: Path, nested_mach_o: bool) -> Path:
        app = temporary_root / "Blocks Selection Helper.app"
        contents = app / "Contents"
        executable = contents / "MacOS/Blocks Selection Helper"
        executable.parent.mkdir(parents=True)
        executable.touch()
        executable.chmod(0o755)
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "LSMinimumSystemVersion": "14.0",
                    "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
                    "CFBundleIdentifier": "app.blocks.selection-helper",
                    "CFBundleShortVersionString": "0.1.0",
                    "CFBundleVersion": "1",
                    "BLOCKS_RELEASE_NAME": "0.1.0-beta.1",
                    "CFBundleURLTypes": [
                        {"CFBundleURLSchemes": ["blocks-selection-helper"]}
                    ],
                }
            )
        )
        if nested_mach_o:
            injected = contents / "Resources/InjectedMachO"
            injected.parent.mkdir(parents=True)
            injected.touch()
        return app

    def run_fixture(
        mutation: str | None, *, include_authority: bool = True, authority_value: str | None = None
    ) -> tuple[subprocess.CompletedProcess[str], str, list[str]]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app = write_bundle(
                temporary_root,
                nested_mach_o=mutation == "helper:nested-mach-o",
            )
            shims = temporary_root / "shims"
            shims.mkdir()
            trace = temporary_root / "signature-trace.txt"
            write_shim(
                shims / "lipo",
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -archs ]] || exit 2\n"
                "printf '%s\\n' arm64\n",
            )
            write_shim(
                shims / "file",
                "#!/usr/bin/env bash\n"
                "[[ \"$1\" == -b ]] || exit 2\n"
                "case \"$2\" in\n"
                "  */Contents/MacOS/Blocks\\ Selection\\ Helper|*/Contents/Resources/InjectedMachO) printf '%s\\n' Mach-O ;;\n"
                "  *) printf '%s\\n' data ;;\n"
                "esac\n",
            )
            write_shim(
                shims / "openssl",
                "#!/usr/bin/env bash\n"
                "input=''\n"
                "while (($#)); do\n"
                "  if [[ \"$1\" == -in ]]; then input=\"$2\"; shift 2; else shift; fi\n"
                "done\n"
                "component=$(/bin/cat \"$input\")\n"
                "if [[ \"${BLOCKS_TEST_HELPER_MUTATION:-}\" == helper:sha && \"$component\" == helper ]]; then\n"
                "  printf '%s\\n' 'sha1 Fingerprint=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'\n"
                "else\n"
                "  printf '%s\\n' 'sha1 Fingerprint=0123456789ABCDEF0123456789ABCDEF01234567'\n"
                "fi\n",
            )
            write_shim(
                shims / "plutil",
                "#!/usr/bin/python3\n"
                "import plistlib\n"
                "import sys\n"
                "\n"
                "def extract(value, path):\n"
                "    parts = path.split('.')\n"
                "    while parts:\n"
                "        if isinstance(value, dict):\n"
                "            for length in range(len(parts), 0, -1):\n"
                "                candidate = '.'.join(parts[:length])\n"
                "                if candidate in value:\n"
                "                    value = value[candidate]\n"
                "                    parts = parts[length:]\n"
                "                    break\n"
                "            else:\n"
                "                raise KeyError(path)\n"
                "        elif isinstance(value, list):\n"
                "            value = value[int(parts.pop(0))]\n"
                "        else:\n"
                "            raise KeyError(path)\n"
                "    return value\n"
                "\n"
                "try:\n"
                "    args = sys.argv[1:]\n"
                "    if len(args) == 2 and args[0] == '-lint':\n"
                "        plistlib.load(open(args[1], 'rb'))\n"
                "    elif len(args) == 4 and args[0] == '-extract' and args[2] == 'raw':\n"
                "        value = extract(plistlib.load(open(args[3], 'rb')), args[1])\n"
                "        if isinstance(value, bool):\n"
                "            print(str(value).lower())\n"
                "        elif isinstance(value, str):\n"
                "            print(value)\n"
                "        else:\n"
                "            raise TypeError(args[1])\n"
                "    else:\n"
                "        raise ValueError(args)\n"
                "except Exception:\n"
                "    raise SystemExit(1)\n",
            )
            write_shim(
                shims / "codesign",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "trace() { printf '%s|%s\\n' \"$1\" \"$2\" >> \"$BLOCKS_SIGNATURE_TRACE\"; }\n"
                "component=\"${!#}\"\n"
                "[[ \"$component\" == *.app ]] || exit 2\n"
                "mutation=\"${BLOCKS_TEST_HELPER_MUTATION:-}\"\n"
                "if [[ \"$1\" == --verify ]]; then\n"
                "  [[ \"$#\" -eq 5 && \"$1\" == --verify && \"$2\" == --deep && \"$3\" == --strict && \"$4\" == --verbose=2 && \"$5\" == \"$component\" ]] || exit 2\n"
                "  trace verify-deep helper\n"
                "  if [[ \"$mutation\" == helper:deep-verify ]]; then echo 'mock codesign deep verify failed' >&2; exit 1; fi\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -dvv ]]; then\n"
                "  trace dvv helper\n"
                "  team=ABCDE12345\n"
                "  identifier=app.blocks.selection-helper\n"
                "  authority='Developer ID Application: Blocks Test (ABCDE12345)'\n"
                "  if [[ \"$mutation\" == helper:team ]]; then team=ZZZZZ99999; fi\n"
                "  if [[ \"$mutation\" == helper:identifier ]]; then identifier=app.blocks.wrong; fi\n"
                "  if [[ \"$mutation\" == helper:authority ]]; then authority='Developer ID Application: Blocks Test (ABCDE12345) extra'; fi\n"
                "  printf 'Identifier=%s\\nTeamIdentifier=%s\\nAuthority=%s\\n' \"$identifier\" \"$team\" \"$authority\"\n"
                "  if [[ \"$mutation\" == helper:runtime ]]; then printf '%s\\n' 'flags=0x0'; else printf '%s\\n' 'flags=0x10000(runtime)'; fi\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -d && \"$2\" == --extract-certificates ]]; then\n"
                "  trace cert helper\n"
                "  printf '%s' helper > \"${3}0\"\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == -d && \"$2\" == --entitlements && \"$3\" == :- ]]; then\n"
                "  trace entitlements helper\n"
                "  trace entitlements-keychain helper\n"
                "    exec /usr/bin/python3 - \"$mutation\" <<'PY'\n"
                "import plistlib\n"
                "import sys\n"
                "mutation = sys.argv[1]\n"
                "team = 'ABCDE12345'\n"
                "values = {\n"
                "    'com.apple.application-identifier': team + '.app.blocks.selection-helper',\n"
                "    'com.apple.developer.team-identifier': team,\n"
                "    'keychain-access-groups': [team + '.app.blocks.selection-helper.shared'],\n"
                "}\n"
                "if mutation == 'helper:entitlement-team':\n"
                "    values['com.apple.developer.team-identifier'] = 'ZZZZZ99999'\n"
                "elif mutation == 'helper:entitlement-app-id':\n"
                "    values['com.apple.application-identifier'] = team + '.app.blocks.wrong'\n"
                "elif mutation == 'helper:entitlement-extra':\n"
                "    values['com.example.extra'] = True\n"
                "elif mutation == 'helper:keychain-missing':\n"
                "    values.pop('keychain-access-groups')\n"
                "elif mutation == 'helper:keychain-wrong':\n"
                "    values['keychain-access-groups'] = [team + '.app.blocks.wrong']\n"
                "elif mutation == 'helper:keychain-extra':\n"
                "    values['keychain-access-groups'].append(team + '.app.blocks.extra')\n"
                "sys.stdout.buffer.write(plistlib.dumps(values))\n"
                "PY\n"
                "fi\n"
                "exit 2\n",
            )
            environment = {
                "PATH": f"{shims}:/usr/bin:/bin",
                "TMPDIR": str(temporary_root),
                "BLOCKS_SIGNATURE_TRACE": str(trace),
            }
            if mutation is not None:
                environment["BLOCKS_TEST_HELPER_MUTATION"] = mutation
            if mutation is None and include_authority and authority_value is None:
                malformed_verify = subprocess.run(
                    [
                        str(shims / "codesign"),
                        "--verify",
                        "--strict",
                        "--verbose=2",
                        str(app),
                    ],
                    text=True,
                    capture_output=True,
                    env=environment,
                    check=False,
                )
                require(
                    malformed_verify.returncode != 0 and not trace.exists(),
                    "Helper codesign shim accepted a verify command without --deep",
                )
            command = [
                    "bash",
                    str(audit_script),
                    str(app),
                    "--require-signature",
                    "--expected-team-id",
                    expected_team,
            ]
            if include_authority:
                command += ["--expected-authority", authority_value or expected_authority]
            command += ["--expected-cert-sha1", expected_sha1]
            result = subprocess.run(
                command,
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            trace_lines = (
                trace.read_text(encoding="utf-8").splitlines()
                if trace.exists()
                else []
            )
            if (
                mutation is None
                and include_authority
                and authority_value is None
            ):
                require(
                    result.returncode == 0,
                    f"valid hermetic Helper signature fixture failed audit: {result.stderr}",
                )
                for trace_line in [
                    "verify-deep|helper",
                    "dvv|helper",
                    "cert|helper",
                    "entitlements|helper",
                    "entitlements-keychain|helper",
                ]:
                    require(
                        trace_line in trace_lines,
                        f"Helper signature audit did not reach {trace_line}",
                    )
            return result, result.stderr.replace(str(app), "<app>"), trace_lines

    baseline, _, _ = run_fixture(None)
    require(baseline.returncode == 0, "hermetic Helper signature baseline did not pass")
    missing_authority, missing_authority_error, _ = run_fixture(None, include_authority=False)
    require(
        missing_authority.returncode == 2
        and "--require-signature requires an explicit non-empty --expected-authority"
        in missing_authority_error,
        "Helper signature audit accepted a missing expected Authority",
    )
    for invalid_authority in [
        "Apple Distribution: Blocks Test (ABCDE12345)",
        "Developer ID Application: Blocks Test (ZZZZZ99999)",
        "Developer ID Application: Blocks Test (ABCDE12345)\nAuthority=forged",
    ]:
        result, error, _ = run_fixture(None, authority_value=invalid_authority)
        require(result.returncode != 0, "Helper audit accepted an invalid expected Authority")
        require("--expected-authority" in error, "Helper invalid Authority failure was not explicit")
    for mutation, expected_error in expected_errors.items():
        result, normalized_error, trace_lines = run_fixture(mutation)
        require(result.returncode != 0, f"Helper signature mutation unexpectedly passed: {mutation}")
        require(
            normalized_error == expected_error,
            f"Helper signature mutation did not fail closed with a stable error: "
            f"{mutation}: {normalized_error!r}",
        )
        if mutation == "helper:nested-mach-o":
            require(
                not trace_lines,
                "Helper nested Mach-O rejection reached codesign before structural failure",
            )


def verify_selection_helper_bundle_members_are_rejected() -> None:
    """Exercise the Helper structural gate before any signing command is needed."""
    audit_script = ROOT / "script/release/audit_selection_helper_bundle.sh"
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_root = Path(temporary_directory)
        app = temporary_root / "Blocks Selection Helper.app"
        contents = app / "Contents"
        executable = contents / "MacOS/Blocks Selection Helper"
        executable.parent.mkdir(parents=True)
        executable.touch()
        executable.chmod(0o755)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "BLOCKS_RELEASE_NAME": "0.1.0-beta.1",
        }))
        resource = contents / "Resources/en.lproj/Localizable.strings"
        resource.parent.mkdir(parents=True)
        resource.touch()

        shims = temporary_root / "shims"
        shims.mkdir()
        (shims / "lipo").write_text(
            "#!/usr/bin/env bash\n"
            "[[ \"$2\" == *\"Blocks Selection Helper\" ]] && echo arm64\n",
            encoding="utf-8",
        )
        (shims / "file").write_text(
            "#!/usr/bin/env bash\n"
            "case \"$2\" in\n"
            "  */Contents/MacOS/Blocks\\ Selection\\ Helper|*InjectedMachO) echo Mach-O ;;\n"
            "  *) echo data ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (shims / "plutil").write_text(
            "#!/usr/bin/env bash\n"
            "case \"$2\" in\n"
            "  LSMinimumSystemVersion) echo 14.0 ;;\n"
            "  BLOCKS_DISTRIBUTION_CHANNEL) echo direct-beta ;;\n"
            "  CFBundleIdentifier) echo app.blocks.selection-helper ;;\n"
            "  CFBundleURLTypes.0.CFBundleURLSchemes.0) echo blocks-selection-helper ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        for shim in shims.iterdir():
            shim.chmod(0o755)
        environment = {"PATH": f"{shims}:/usr/bin:/bin"}

        result = subprocess.run(
            ["bash", str(audit_script), str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        require(result.returncode == 0, f"valid Helper fixture failed audit: {result.stderr}")

        injected_mach_o = contents / "Resources/InjectedMachO"
        injected_mach_o.touch()
        result = subprocess.run(
            ["bash", str(audit_script), str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        require(result.returncode != 0, "audit accepted a non-executable nested Helper Mach-O")
        require(
            "unexpected nested Helper executable: Contents/Resources/InjectedMachO"
            in result.stderr,
            "audit did not report the non-executable nested Helper Mach-O",
        )

        injected_mach_o.unlink()
        resource_link = contents / "Resources/UnexpectedLink"
        resource_link.symlink_to("en.lproj/Localizable.strings")
        result = subprocess.run(
            ["bash", str(audit_script), str(app)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        require(result.returncode != 0, "audit accepted a symlinked Helper resource")
        require(
            "symbolic link is forbidden in Helper bundle: Contents/Resources/UnexpectedLink"
            in result.stderr,
            "audit did not report the symlinked Helper resource",
        )


def verify_selection_helper_release_identity() -> None:
    """Reject stale/malformed release metadata before signing, using real plists."""
    with tempfile.TemporaryDirectory(prefix="blocks-helper-release-identity-") as directory:
        root = Path(directory)
        audit = root / "script/release/audit_selection_helper_bundle.sh"
        audit.parent.mkdir(parents=True)
        audit.write_text(read("script/release/audit_selection_helper_bundle.sh"))
        (root / "script/release/release_versioning.py").write_text(
            read("script/release/release_versioning.py")
        )
        profile = root / "apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
        profile.parent.mkdir(parents=True)
        profile_text = (
            "MARKETING_VERSION = 2.3.4\n"
            "CURRENT_PROJECT_VERSION = 42\n"
            "BLOCKS_RELEASE_NAME = 2.3.4-beta.2\n"
        )
        profile.write_text(profile_text)
        app = root / "Helper.app"
        executable = app / "Contents/MacOS/Blocks Selection Helper"
        executable.parent.mkdir(parents=True)
        executable.touch()
        executable.chmod(0o755)
        info = app / "Contents/Info.plist"
        baseline = {
            "LSMinimumSystemVersion": "14.0",
            "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
            "CFBundleIdentifier": "app.blocks.selection-helper",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["blocks-selection-helper"]}],
            "CFBundleShortVersionString": "2.3.4",
            "CFBundleVersion": "42",
            "BLOCKS_RELEASE_NAME": "2.3.4-beta.2",
        }
        shims = root / "shims"
        shims.mkdir()
        trace = root / "signing-attempted"
        for name, source in {
            "lipo": "#!/bin/sh\nprintf '%s\\n' arm64\n",
            "file": "#!/bin/sh\nprintf '%s\\n' data\n",
            "codesign": '#!/bin/sh\n: > "$HELPER_RELEASE_TEST_TRACE"\nexit 99\n',
        }.items():
            path = shims / name
            path.write_text(source)
            path.chmod(0o755)

        def run(values: dict[str, object], *, signed: bool = False):
            info.write_bytes(plistlib.dumps(values))
            command = ["bash", str(audit), str(app)]
            if signed:
                command += [
                    "--require-signature", "--expected-team-id", "ABCDE12345",
                    "--expected-authority", "Developer ID Application: Test (ABCDE12345)",
                    "--expected-cert-sha1", "0" * 40,
                ]
            return subprocess.run(
                command, text=True, capture_output=True, check=False,
                env={"PATH": f"{shims}:/usr/bin:/bin", "HELPER_RELEASE_TEST_TRACE": str(trace)},
            )

        baseline_result = run(baseline)
        require(
            baseline_result.returncode == 0,
            "Helper release-identity baseline failed: "
            f"stdout={baseline_result.stdout!r} stderr={baseline_result.stderr!r}",
        )
        # The control proves signed mode reaches the signer only after metadata matches.
        require(run(baseline, signed=True).returncode == 99 and trace.exists(),
                "Helper signed control did not reach the isolated codesign shim")
        trace.unlink()
        for key in ("CFBundleShortVersionString", "CFBundleVersion", "BLOCKS_RELEASE_NAME"):
            for value in (None, "", "stale", "$(UNRESOLVED)", 42, [baseline[key]], baseline[key] + "\n"):
                mutated = dict(baseline)
                if value is None:
                    mutated.pop(key)
                else:
                    mutated[key] = value
                for signed in (False, True):
                    result = run(mutated, signed=signed)
                    require(result.returncode != 0, f"Helper accepted invalid release field: {key}")
                    require(f"Helper {key} differs from release profile or is not a string" in result.stderr,
                            f"Helper release field failure was not explicit: {key}")
                    require(not trace.exists(), "Mismatched Helper release reached codesign")
        for invalid_profile in (
            "", profile_text + "CURRENT_PROJECT_VERSION = 43\n",
            profile_text.replace("2.3.4\n", "$(OTHER_VERSION)\n"),
            profile_text.replace("42\n", "42=43\n"),
        ):
            profile.write_text(invalid_profile)
            result = run(baseline)
            require(result.returncode != 0 and "Helper release profile identity" in result.stderr,
                    "Helper accepted missing, ambiguous, or unresolved release profile")


def verify_store_bad_team_fails_before_xcodebuild() -> None:
    """A malformed Store Team ID must fail before any build side effect."""
    source = read("script/release/build_app_store_beta.sh")
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary_root = Path(temporary_directory)
        identity_config = temporary_root / "ReleaseIdentity.local.xcconfig"
        identity_config.write_text(
            "DEVELOPMENT_TEAM = NOT-A-TEAM\nPROVISIONING_PROFILE_SPECIFIER = TestProfile\n",
            encoding="utf-8",
        )
        script = temporary_root / "build_app_store_beta.sh"
        script.write_text(
            source.replace(
                'identity_config="$repo_root/apps/Blocks/Config/ReleaseIdentity.local.xcconfig"',
                f'identity_config="{identity_config}"',
            ),
            encoding="utf-8",
        )
        shims = temporary_root / "shims"
        shims.mkdir()
        marker = temporary_root / "xcodebuild-ran"
        xcodebuild = shims / "xcodebuild"
        xcodebuild.write_text(
            f"#!/usr/bin/env bash\ntouch '{marker}'\nexit 99\n", encoding="utf-8"
        )
        xcodebuild.chmod(0o755)
        result = subprocess.run(
            ["bash", str(script)],
            text=True,
            capture_output=True,
            env={
                "PATH": f"{shims}:/usr/bin:/bin",
                "BLOCKS_APPLE_DISTRIBUTION_IDENTITY": "Apple Distribution: Blocks Test (ABCDE12345)",
                "BLOCKS_EXPECTED_SIGNING_CERT_SHA1": "0123456789ABCDEF0123456789ABCDEF01234567",
            },
            check=False,
        )
        require(result.returncode == 67, "Store build accepted a malformed Team ID")
        require("DEVELOPMENT_TEAM must be the explicit 10-character Apple Team ID" in result.stderr, "Store bad Team ID error is not explicit")
        require(not marker.exists(), "Store build invoked xcodebuild before rejecting Team ID")


def verify_package_dmg_is_hermetic() -> None:
    """Exercise DMG identity and post-signature gates without macOS signing tools."""
    source = read("script/release/package_dmg.sh")
    expected_team = "ABCDE12345"
    identity = "Developer ID Application: Blocks Test (ABCDE12345)"
    expected_sha1 = "0123456789ABCDEF0123456789ABCDEF01234567"

    def write_executable(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_fixture(
        *,
        team: str = expected_team,
        fixture_identity: str = identity,
        authority_mode: str = "correct",
        artifact: str = "direct-beta",
        bundle_release: object = "0.1.0-beta.1",
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            repo_root = temporary_root / "repo"
            release_directory = repo_root / "script/release"
            release_directory.mkdir(parents=True)
            package_script = release_directory / "package_dmg.sh"
            write_executable(package_script, source)
            (release_directory / "release_versioning.py").write_text(read("script/release/release_versioning.py"))
            trace = temporary_root / "dmg-trace.txt"
            for audit_name in ["audit_app_bundle.sh", "audit_selection_helper_bundle.sh"]:
                write_executable(
                    release_directory / audit_name,
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' audit >> \"$P20_DMG_TRACE\"\n",
                )
            shims = temporary_root / "shims"
            shims.mkdir()
            write_executable(
                shims / "security",
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' security >> \"$P20_DMG_TRACE\"\n"
                "printf '%s\\n' '  1) mock \"Developer ID Application: Blocks Test (ABCDE12345)\"'\n",
            )
            write_executable(
                shims / "hdiutil",
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' hdiutil >> \"$P20_DMG_TRACE\"\n"
                ": > \"${!#}\"\n",
            )
            write_executable(
                shims / "codesign",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "case \"$1\" in\n"
                "  --force) printf '%s\\n' codesign-sign >> \"$P20_DMG_TRACE\" ;;\n"
                "  --verify) printf '%s\\n' codesign-verify >> \"$P20_DMG_TRACE\" ;;\n"
                "  -dvv)\n"
                "    printf '%s\\n' codesign-dvv >> \"$P20_DMG_TRACE\"\n"
                "    printf '%s\\n' 'TeamIdentifier=ABCDE12345'\n"
                "    case \"${P20_DMG_AUTHORITY_MODE:-correct}\" in\n"
                "      wrong-first) printf '%s\\n' 'Authority=Developer ID Application: Wrong (ABCDE12345)' ;;\n"
                "      extra-after) printf '%s\\n' 'Authority=Developer ID Application: Blocks Test (ABCDE12345)' 'Authority=Additional Chain Authority' ;;\n"
                "      *) printf '%s\\n' 'Authority=Developer ID Application: Blocks Test (ABCDE12345)' ;;\n"
                "    esac\n"
                "    ;;\n"
                "  -d)\n"
                "    printf '%s\\n' codesign-cert >> \"$P20_DMG_TRACE\"\n"
                "    : > \"${3}0\"\n"
                "    ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
            )
            write_executable(
                shims / "openssl",
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' openssl >> \"$P20_DMG_TRACE\"\n"
                "printf '%s\\n' 'sha1 Fingerprint=0123456789ABCDEF0123456789ABCDEF01234567'\n",
            )
            app = temporary_root / "Blocks.app"
            app.mkdir()
            (app / "placeholder").touch()
            (app / "Contents").mkdir()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(
                {} if bundle_release is None else {
                    "BLOCKS_RELEASE_NAME": bundle_release,
                    "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                    "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
                }
            ))
            output_directory = temporary_root / "output"
            environment = {
                "PATH": f"{shims}:/usr/bin:/bin",
                "TMPDIR": str(temporary_root),
                "P20_DMG_TRACE": str(trace),
                "P20_DMG_AUTHORITY_MODE": authority_mode,
                "PYTHONDONTWRITEBYTECODE": "1",
            }
            result = subprocess.run(
                [
                    "bash",
                    str(package_script),
                    "--artifact",
                    artifact,
                    "--app",
                    str(app),
                    "--release-name",
                    "0.1.0-beta.1",
                    "--output-dir",
                    str(output_directory),
                    "--expected-team-id",
                    team,
                    "--expected-cert-sha1",
                    expected_sha1,
                    "--identity",
                    fixture_identity,
                ],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
                timeout=15,
            )
            trace_lines = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
            return result, trace_lines

    for invalid_team, invalid_identity, expected_error in [
        ("NOT-A-TEAM", identity, "--expected-team-id must be the explicit 10-character Apple Team ID"),
        (expected_team, identity + "\rforged", "--identity must be a single line"),
        (expected_team, identity + "\nforged", "--identity must be a single line"),
    ]:
        result, trace_lines = run_fixture(team=invalid_team, fixture_identity=invalid_identity)
        require(result.returncode != 0, "invalid DMG package identity unexpectedly passed")
        require(expected_error in result.stderr, "invalid DMG package identity error was not explicit")
        require(
            not trace_lines,
            "invalid DMG package identity reached security, audit, hdiutil, or codesign",
        )

    baseline, baseline_trace = run_fixture()
    require(baseline.returncode == 0, f"hermetic DMG package baseline failed: {baseline.stderr}")
    helper_baseline, _ = run_fixture(artifact="selection-helper-beta")
    require(helper_baseline.returncode == 0, "Helper DMG release-name baseline failed")
    for artifact in ("direct-beta", "selection-helper-beta"):
        for invalid_release in (None, "", "0.1.0-beta.0", 1, "0.1.0-beta.1\n"):
            result, trace_lines = run_fixture(artifact=artifact, bundle_release=invalid_release)
            require(result.returncode != 0 and "--release-name must match" in result.stderr,
                    "DMG package accepted a missing, malformed, or mismatched release name")
            require(not trace_lines, "Invalid DMG release identity reached signing/packaging tools")
    require(
        baseline_trace == [
            "security",
            "audit",
            "hdiutil",
            "codesign-sign",
            "codesign-verify",
            "codesign-dvv",
            "codesign-cert",
            "openssl",
        ],
        f"DMG package baseline tool sequence drifted: {baseline_trace}",
    )
    wrong_authority, wrong_authority_trace = run_fixture(authority_mode="wrong-first")
    require(wrong_authority.returncode != 0, "DMG package accepted a wrong first Authority")
    require(
        "DMG signing Authority differs from expected Authority" in wrong_authority.stderr,
        "wrong first DMG Authority error was not explicit",
    )
    require(
        wrong_authority_trace == [
            "security", "audit", "hdiutil", "codesign-sign", "codesign-verify", "codesign-dvv"
        ],
        "DMG package continued after rejecting its first Authority",
    )
    extra_authority, extra_authority_trace = run_fixture(authority_mode="extra-after")
    require(extra_authority.returncode == 0, "DMG package rejected an additional Authority after the first")
    require(
        extra_authority_trace == baseline_trace,
        "DMG package did not complete with an additional trailing Authority",
    )


def verify_notarize_dmg_identity_pins_are_hermetic() -> None:
    """Keep notarization offline while proving every identity failure precedes notarytool."""
    source = read("script/release/notarize_dmg.sh")
    expected_team = "ABCDE12345"
    authority = "Developer ID Application: Blocks Test (ABCDE12345)"
    expected_sha1 = "0123456789ABCDEF0123456789ABCDEF01234567"

    def write_executable(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_fixture(
        *,
        dmg_mode: str = "correct",
        component_mode: str = "correct",
        detach_mode: str = "correct",
        root_payload: str = "correct",
        expected_authority: str = authority,
    ) -> tuple[subprocess.CompletedProcess[str], list[str], bool]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            repo_root = temporary_root / "repo"
            release_directory = repo_root / "script/release"
            release_directory.mkdir(parents=True)
            write_executable(release_directory / "notarize_dmg.sh", source)
            (release_directory / "release_versioning.py").write_text(read("script/release/release_versioning.py"))
            trace = temporary_root / "trace.txt"
            mount_point = temporary_root / "mounted"
            (mount_point / "Blocks.app/Contents").mkdir(parents=True)
            (mount_point / "Blocks.app/Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "app.blocks.app", "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                "BLOCKS_RELEASE_NAME": "0.1.0-beta.1",
            }))
            (mount_point / "Applications").symlink_to("/Applications")
            if root_payload == "extra-file":
                (mount_point / "unexpected.txt").touch()
            elif root_payload == "extra-directory":
                (mount_point / "Unexpected").mkdir()
            elif root_payload == "wrong-applications-target":
                (mount_point / "Applications").unlink()
                (mount_point / "Applications").symlink_to("/NotApplications")
            elif root_payload == "regular-applications":
                (mount_point / "Applications").unlink()
                (mount_point / "Applications").touch()
            elif root_payload == "extra-symlink":
                (mount_point / "UnexpectedLink").symlink_to("/Applications")
            else:
                require(root_payload == "correct", f"unknown notary root payload: {root_payload}")
            for audit_name in ["audit_app_bundle.sh", "audit_selection_helper_bundle.sh"]:
                write_executable(
                    release_directory / audit_name,
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' component-audit >> \"$P20_NOTARY_TRACE\"\n"
                    "[[ \"$*\" == *\"--expected-team-id ABCDE12345 --expected-authority Developer ID Application: Blocks Test (ABCDE12345) --expected-cert-sha1 0123456789ABCDEF0123456789ABCDEF01234567\" ]] || { echo 'error: audit pins missing' >&2; exit 1; }\n"
                    "[[ \"${P20_NOTARY_COMPONENT_MODE:-correct}\" == correct ]] || { echo 'error: component identity mismatch' >&2; exit 1; }\n",
                )
            shims = temporary_root / "shims"
            shims.mkdir()
            write_executable(
                shims / "codesign",
                "#!/usr/bin/env bash\n"
                "case \"$1\" in\n"
                "  --verify) printf '%s\\n' codesign-verify >> \"$P20_NOTARY_TRACE\" ;;\n"
                "  -dvv)\n"
                "    printf '%s\\n' codesign-dvv >> \"$P20_NOTARY_TRACE\"\n"
                "    case \"${P20_NOTARY_DMG_MODE:-correct}\" in\n"
                "      wrong-team) printf '%s\\n' 'TeamIdentifier=ZZZZZ99999' 'Authority=Developer ID Application: Blocks Test (ABCDE12345)' ;;\n"
                "      wrong-authority) printf '%s\\n' 'TeamIdentifier=ABCDE12345' 'Authority=Developer ID Application: Wrong (ABCDE12345)' ;;\n"
                "      *) printf '%s\\n' 'TeamIdentifier=ABCDE12345' 'Authority=Developer ID Application: Blocks Test (ABCDE12345)' ;;\n"
                "    esac ;;\n"
                "  -d) printf '%s\\n' codesign-cert >> \"$P20_NOTARY_TRACE\"; : > \"${3}0\" ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
            )
            write_executable(
                shims / "openssl",
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' openssl >> \"$P20_NOTARY_TRACE\"\n"
                "case \"${P20_NOTARY_DMG_MODE:-correct}\" in wrong-sha) echo 'sha1 Fingerprint=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' ;; *) echo 'sha1 Fingerprint=0123456789ABCDEF0123456789ABCDEF01234567' ;; esac\n",
            )
            write_executable(
                shims / "hdiutil",
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' hdiutil-\"$1\" >> \"$P20_NOTARY_TRACE\"\n"
                "[[ \"$1\" == detach && \"${P20_NOTARY_DETACH_MODE:-correct}\" == fail ]] && exit 1\n"
                "exit 0\n",
            )
            write_executable(
                shims / "plutil",
                "#!/usr/bin/env bash\n"
                "case \"$2\" in\n"
                "  status) grep -Fq '\"status\":\"Accepted\"' \"$4\" && echo Accepted ;;\n"
                "  id) grep -Fq '\"id\":\"mock-submission\"' \"$4\" && echo mock-submission ;;\n"
                "  system-entities.1.mount-point|system-entities.0.mount-point) echo \"$P20_NOTARY_MOUNT\" ;;\n"
                "  system-entities.0.dev-entry) echo /dev/disk99 ;;\n"
                "  CFBundleIdentifier|BLOCKS_DISTRIBUTION_CHANNEL) exec /usr/bin/plutil \"$@\" ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
            )
            write_executable(
                shims / "xcrun",
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$1-$2\" >> \"$P20_NOTARY_TRACE\"\n"
                "case \"$1:$2\" in\n"
                "  notarytool:submit) [[ \"$3\" == \"$P20_NOTARY_DMG\" && \"$4\" == --keychain-profile && \"$5\" == offline-test-profile && \"$6\" == --wait && \"$7\" == --output-format && \"$8\" == json ]] || exit 2; echo '{\"status\":\"Accepted\",\"id\":\"mock-submission\"}' ;;\n"
                "  notarytool:log) [[ \"$3\" == mock-submission && \"$4\" == --keychain-profile && \"$5\" == offline-test-profile && \"$6\" == --output-format && \"$7\" == json ]] || exit 2; echo '{}' ;;\n"
                "  stapler:staple|stapler:validate) [[ \"$3\" == \"$P20_NOTARY_DMG\" ]] || exit 2 ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n",
            )
            write_executable(
                shims / "spctl",
                "#!/usr/bin/env bash\nprintf '%s\\n' spctl >> \"$P20_NOTARY_TRACE\"\n",
            )
            dmg = temporary_root / "fixture.dmg"
            dmg.touch()
            evidence = temporary_root / "evidence"
            environment = {
                "PATH": f"{shims}:/usr/bin:/bin",
                "TMPDIR": str(temporary_root),
                "BLOCKS_NOTARY_KEYCHAIN_PROFILE": "offline-test-profile",
                "P20_NOTARY_TRACE": str(trace),
                "P20_NOTARY_MOUNT": str(mount_point),
                "P20_NOTARY_DMG_MODE": dmg_mode,
                "P20_NOTARY_COMPONENT_MODE": component_mode,
                "P20_NOTARY_DETACH_MODE": detach_mode,
                "P20_NOTARY_DMG": str(dmg),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
            result = subprocess.run(
                [
                    "bash", str(release_directory / "notarize_dmg.sh"), str(dmg),
                    "--evidence-dir", str(evidence),
                    "--expected-team-id", expected_team,
                    "--expected-authority", expected_authority,
                    "--expected-cert-sha1", expected_sha1,
                ],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
                timeout=15,
            )
            trace_lines = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
            return result, trace_lines, (temporary_root / "fixture.dmg.sha256").exists()

    baseline, baseline_trace, baseline_checksum = run_fixture()
    require(baseline.returncode == 0, f"hermetic notarize baseline failed: {baseline.stderr}")
    require("notarytool-submit" in baseline_trace, "baseline did not reach the notarytool shim")
    require(baseline_checksum, "baseline did not publish a final checksum")
    require(
        baseline_trace.count("component-audit") == 2,
        "baseline did not repeat the complete mounted artifact audit after stapling",
    )
    for before, after in [("codesign-cert", "hdiutil-attach"), ("hdiutil-attach", "component-audit"), ("component-audit", "hdiutil-detach"), ("hdiutil-detach", "notarytool-submit")]:
        require(baseline_trace.index(before) < baseline_trace.index(after), f"baseline pre-submit ordering drifted: {before} must precede {after}")

    for mode, error in [
        ("wrong-team", "dmg TeamIdentifier differs from expected Team ID"),
        ("wrong-authority", "dmg signing Authority differs from expected Authority"),
        ("wrong-sha", "dmg signing certificate SHA-1 differs from expected certificate"),
    ]:
        result, trace_lines, checksum_exists = run_fixture(dmg_mode=mode)
        require(result.returncode != 0, f"notarize accepted a {mode} DMG identity")
        require(error in result.stderr, f"{mode} DMG rejection was not explicit")
        require("notarytool-submit" not in trace_lines, f"{mode} DMG reached notarytool")
        require(not checksum_exists, f"{mode} DMG published a final checksum")

    component, component_trace, component_checksum = run_fixture(component_mode="wrong")
    require(component.returncode != 0, "notarize accepted an incorrectly pinned mounted component")
    require("component identity mismatch" in component.stderr, "mounted component rejection was not retained")
    require("notarytool-submit" not in component_trace, "mounted component mismatch reached notarytool")
    require(not component_checksum, "mounted component mismatch published a final checksum")

    for root_payload, error in [
        ("extra-file", "unexpected DMG root entry"),
        ("extra-directory", "unexpected DMG root entry"),
        ("wrong-applications-target", "unexpected DMG root symbolic link"),
        ("regular-applications", "unexpected DMG root entry"),
        ("extra-symlink", "unexpected DMG root symbolic link"),
    ]:
        result, trace_lines, checksum_exists = run_fixture(root_payload=root_payload)
        require(result.returncode != 0, f"notarize accepted root payload: {root_payload}")
        require(error in result.stderr, f"root payload rejection was not explicit: {root_payload}")
        require("notarytool-submit" not in trace_lines, f"root payload reached notarytool: {root_payload}")
        require(not checksum_exists, f"root payload published a final checksum: {root_payload}")

    crlf, crlf_trace, crlf_checksum = run_fixture(expected_authority=authority + "\rforged")
    require(crlf.returncode != 0, "notarize accepted a CRLF authority parameter")
    require("--expected-authority must be a single line" in crlf.stderr, "CRLF authority rejection was not explicit")
    require(not crlf_trace, "CRLF authority parameter reached a release tool")
    require(not crlf_checksum, "CRLF authority parameter published a final checksum")

    detach_failure, detach_trace, detach_checksum = run_fixture(detach_mode="fail")
    require(detach_failure.returncode != 0, "notarize continued after both pre-submit detach attempts failed")
    require("could not detach mounted DMG before continuing" in detach_failure.stderr, "detach failure was not explicit")
    require("notarytool-submit" not in detach_trace, "detach failure reached notarytool")
    require(not detach_checksum, "detach failure published a final checksum")



def main() -> None:
    expected_bundle_ids = {
        "app.blocks.app",
        "app.blocks.core",
        "app.blocks.screenshotcore",
        "app.blocks.action-broker",
        "app.blocks.clipboard-broker",
        "app.blocks.plugin-runner",
        "app.blocks.selection-helper",
    }
    expected_urls = {
        "BLOCKS_RELEASE_PAGE_URL": "https://blocks.orangeforge.top/releases/",
        "BLOCKS_SUPPORT_URL": "https://blocks.orangeforge.top/support/",
        "BLOCKS_PRIVACY_URL": "https://blocks.orangeforge.top/privacy/",
    }
    helper_download_url = (
        "https://downloads.orangeforge.top/beta/0.1.0-beta.1/"
        "Blocks-Selection-Helper-0.1.0-beta.1-arm64.dmg"
    )
    def xcconfig_url(value: str) -> str:
        return value.replace("://", ":/$()/")
    direct_entitlements = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksApp/Blocks.entitlements").read_bytes()
    )
    development_entitlements = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksApp/Blocks-Development.entitlements").read_bytes()
    )
    testing_entitlements = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksApp/Blocks-Testing.entitlements").read_bytes()
    )
    helper_entitlements = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksSelectionHelper/BlocksSelectionHelper.entitlements").read_bytes()
    )
    store_entitlements = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksApp/Blocks-AppStore.entitlements").read_bytes()
    )
    required_store_keys = {
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.network.client",
    }
    require(set(store_entitlements) == required_store_keys, "Store entitlements drifted")
    server_entitlement = "com.apple.security.network.server"
    for entitlement_name, entitlements in {
        "Direct": direct_entitlements,
        "Development": development_entitlements,
        "App Store": store_entitlements,
    }.items():
        require(
            server_entitlement not in entitlements,
            f"{entitlement_name} entitlement source must not grant loopback server access",
        )
    required_testing_keys = {
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
        server_entitlement,
    }
    require(
        set(testing_entitlements) == required_testing_keys
        and all(testing_entitlements.get(key) is True for key in required_testing_keys),
        "Blocks-Testing entitlements must contain only sandboxed loopback client/server access",
    )
    expected_direct_keychain_groups = [
        "$(AppIdentifierPrefix)app.blocks.app",
        "$(AppIdentifierPrefix)app.blocks.selection-helper.shared",
    ]
    require(
        direct_entitlements.get("keychain-access-groups") == expected_direct_keychain_groups,
        "Direct entitlements must retain default-first and shared Keychain access groups",
    )
    require(
        development_entitlements.get("keychain-access-groups") == expected_direct_keychain_groups,
        "Development entitlements must retain default-first and shared Keychain access groups",
    )
    require(
        set(helper_entitlements) == {"keychain-access-groups"}
        and helper_entitlements["keychain-access-groups"]
        == ["$(AppIdentifierPrefix)app.blocks.selection-helper.shared"],
        "Helper entitlement source must contain only the shared Keychain access group",
    )
    require(
        "com.apple.security.temporary-exception.mach-lookup.global-name"
        in direct_entitlements,
        "Direct channel lost the ActionBroker Mach exception",
    )
    direct_helper_read_entitlement = (
        "com.apple.security.temporary-exception.files.absolute-path.read-only"
    )
    require(
        direct_entitlements[direct_helper_read_entitlement]
        == ["/Applications/Blocks Selection Helper.app/"],
        "Direct Helper read exception is broader than the stable bundle",
    )
    helper_read_entitlement = (
        "com.apple.security.temporary-exception.files."
        "home-relative-path.read-only"
    )
    require(
        set(development_entitlements)
        == set(direct_entitlements) | {helper_read_entitlement},
        "Development entitlements differ beyond the exact Helper read exception",
    )
    require(
        development_entitlements[helper_read_entitlement]
        == ["/Applications/BlocksDev/Debug/Blocks Selection Helper.app/"],
        "Development Helper read exception is broader than the stable bundle",
    )

    project = read("apps/Blocks/Blocks.xcodeproj/project.pbxproj")
    debug_configuration = re.search(
        r"L00300000000000000000002 /\* Debug \*/ = \{(?P<body>.*?)\n\t\t\};",
        project,
        re.DOTALL,
    )
    release_configuration = re.search(
        r"L00300000000000000000003 /\* Release \*/ = \{(?P<body>.*?)\n\t\t\};",
        project,
        re.DOTALL,
    )
    require(debug_configuration is not None, "Blocks Debug configuration missing")
    require(release_configuration is not None, "Blocks Release configuration missing")
    require(
        'CODE_SIGN_ENTITLEMENTS = "BlocksApp/Blocks-Development.entitlements";'
        in debug_configuration.group("body"),
        "Blocks Debug must use the narrow development Helper read exception",
    )
    require(
        "CODE_SIGN_ENTITLEMENTS = BlocksApp/Blocks.entitlements;"
        in release_configuration.group("body"),
        "Blocks Release must not inherit the development Helper read exception",
    )
    app_store_configuration = re.search(
        r"L00300000000000000000004 /\* AppStoreRelease \*/ = \{(?P<body>.*?)\n\t\t\};",
        project,
        re.DOTALL,
    )
    debug_testing_configuration = re.search(
        r"L40T00000000000000000003 /\* DebugTesting \*/ = \{(?P<body>.*?)\n\t\t\};",
        project,
        re.DOTALL,
    )
    require(app_store_configuration is not None, "Blocks AppStoreRelease configuration missing")
    require(debug_testing_configuration is not None, "Blocks DebugTesting configuration missing")
    require(
        'CODE_SIGN_ENTITLEMENTS = "BlocksApp/Blocks-Testing.entitlements";'
        in debug_testing_configuration.group("body"),
        "only Blocks DebugTesting may use the testing loopback entitlement source",
    )
    require(
        'CODE_SIGN_IDENTITY = "-";' in debug_testing_configuration.group("body")
        and "CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;"
        in debug_testing_configuration.group("body")
        and 'DEVELOPMENT_TEAM = "";'
        in debug_testing_configuration.group("body"),
        "Blocks DebugTesting must remain ad-hoc signed without provisioning identity",
    )
    require(
        "Blocks-Testing.entitlements" not in debug_configuration.group("body")
        and "Blocks-Testing.entitlements" not in release_configuration.group("body")
        and "Blocks-Testing.entitlements" not in app_store_configuration.group("body"),
        "Blocks Debug, Release, and AppStoreRelease must not use testing entitlements",
    )
    require(
        project.count("BlocksApp/Blocks-Testing.entitlements") == 1,
        "Blocks-Testing entitlement source must be referenced only by Blocks DebugTesting",
    )
    helper_configuration_ids = [
        "L27X00000000000000000002",
        "L27X00000000000000000003",
    ]
    for configuration_id in helper_configuration_ids:
        helper_configuration = re.search(
            rf"{configuration_id} /\* .*? \*/ = \{{(?P<body>.*?)\n\t\t\}};",
            project,
            re.DOTALL,
        )
        require(
            helper_configuration is not None
            and "CODE_SIGN_ENTITLEMENTS = BlocksSelectionHelper/BlocksSelectionHelper.entitlements;"
            in helper_configuration.group("body"),
            f"Helper configuration {configuration_id} must use the shared Keychain entitlement source",
        )
    helper_store_configuration = re.search(
        r"L27X00000000000000000004 /\* AppStoreRelease \*/ = \{(?P<body>.*?)\n\t\t\};",
        project,
        re.DOTALL,
    )
    require(helper_store_configuration is not None, "Helper AppStoreRelease configuration missing")
    helper_store_body = helper_store_configuration.group("body")
    require(
        "CODE_SIGN_ENTITLEMENTS" not in helper_store_body
        and "CODE_SIGNING_ALLOWED = NO;" in helper_store_body
        and "SKIP_INSTALL = YES;" in helper_store_body,
        "Helper AppStoreRelease must be entitlement-free, unsigned, and non-installable",
    )
    selection_helper_build_script = read("script/release/build_selection_helper_beta.sh")
    verify_selection_helper_scheme(project, selection_helper_build_script)
    require("Enforce Distribution Bundle Contents" in project, "bundle strip phase missing")
    require("BLOCKS_APP_STORE_BETA" in project, "Store compile condition missing")
    require("ARCHS = arm64;" in project, "Store arm64 policy missing")
    for bundle_id in expected_bundle_ids:
        require(bundle_id in project, f"locked bundle identifier missing: {bundle_id}")
    require("InfoPlist.xcstrings in Resources" in project, "Info.plist localization missing")

    direct_profile = read("apps/Blocks/Config/Distribution.DirectBeta.xcconfig")
    store_profile = read("apps/Blocks/Config/Distribution.AppStoreBeta.xcconfig")
    release_identity_example = read(
        "apps/Blocks/Config/ReleaseIdentity.local.example.xcconfig"
    )
    require("BLOCKS_DIRECT_BETA" in direct_profile, "Direct compile condition missing")
    require("Developer ID Application" in direct_profile, "Developer ID policy missing")
    require("BLOCKS_APP_STORE_BETA" in store_profile, "Store profile condition missing")
    require("Apple Distribution" in store_profile, "Store signing policy missing")
    for key, value in expected_urls.items():
        encoded = xcconfig_url(value)
        require(f"{key} = {encoded}" in direct_profile, f"Direct URL drifted: {key}")
        require(f"{key} = {encoded}" in store_profile, f"Store URL drifted: {key}")
    require(
        f"BLOCKS_SELECTION_HELPER_DOWNLOAD_URL = {xcconfig_url(helper_download_url)}"
        in direct_profile,
        "Direct Helper download URL drifted",
    )
    require(
        "BLOCKS_SELECTION_HELPER_DOWNLOAD_URL =\n" in store_profile,
        "Store profile must not expose a Helper download URL",
    )
    require(
        "independent Developer ID profile UUIDs" in release_identity_example
        and "PROVISIONING_PROFILE_SPECIFIER =" not in release_identity_example,
        "release identity must not apply one Store/global profile to both direct targets",
    )

    manager = read(
        "apps/Blocks/BlocksApp/Features/Plugins/BlocksNativePluginManager.swift"
    )
    require(
        manager.count("externalInstallationUnavailable") >= 6,
        "external plugin rejection is not enforced at all persistence/runtime entries",
    )
    require(
        "metadata.installationOrigin == .builtIn" in manager,
        "Store runtime does not enforce built-in plugin origin",
    )

    info = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksApp/Resources/Info.plist").read_bytes()
    )
    for key in [
        "BLOCKS_DISTRIBUTION_CHANNEL",
        "BLOCKS_RELEASE_NAME",
        "BLOCKS_RELEASE_PAGE_URL",
        "BLOCKS_SUPPORT_URL",
        "BLOCKS_PRIVACY_URL",
    ]:
        require(key in info, f"release metadata key missing: {key}")
    require(info["CFBundleDisplayName"] == "$(BLOCKS_DISPLAY_NAME)", "base display name must remain build-setting driven")
    require(info["CFBundleName"] == "$(BLOCKS_DISPLAY_NAME)", "base bundle name must remain build-setting driven")
    signing_shared = read("apps/Blocks/Config/Signing.shared.xcconfig")
    local_development = read("apps/Blocks/Config/LocalDevelopment.xcconfig")
    require("BLOCKS_DISPLAY_NAME = Blocks for Mac" in signing_shared, "shared release display name drifted")
    require("BLOCKS_DISPLAY_NAME = Blocks Dev" in local_development, "local-development display name drifted")

    info_localizations = json.loads(
        read("apps/Blocks/BlocksApp/Resources/InfoPlist.xcstrings")
    )["strings"]
    expected_names = {"en": "Blocks for Mac", "ja": "Blocks for Mac", "zh-Hans": "积木工具"}
    for key in ["CFBundleDisplayName", "CFBundleName"]:
        actual = {
            language: payload["stringUnit"]["value"]
            for language, payload in info_localizations[key]["localizations"].items()
        }
        require(actual == expected_names, f"localized product name drifted: {key}")
    require(
        set(info_localizations["NSScreenCaptureUsageDescription"]["localizations"])
        == {"en", "ja", "zh-Hans"},
        "screen capture usage description localization gap",
    )

    helper_info = plistlib.loads(
        (ROOT / "apps/Blocks/BlocksSelectionHelper/Info.plist").read_bytes()
    )
    for key in ["BLOCKS_DISTRIBUTION_CHANNEL", "BLOCKS_RELEASE_NAME"]:
        require(key in helper_info, f"Helper release metadata key missing: {key}")

    localizations = json.loads(
        read("apps/Blocks/BlocksApp/Resources/Localizable.xcstrings")
    )["strings"]
    for key in [
        "release.channel.directBeta",
        "release.channel.appStoreBeta",
        "release.storeCapability.externalPlugins",
        "diagnostics.export.detail",
    ]:
        languages = localizations[key]["localizations"]
        require(set(languages) == {"en", "ja", "zh-Hans"}, f"localization gap: {key}")

    for script in [
        "build_direct_beta.sh",
        "build_app_store_beta.sh",
        "build_selection_helper_beta.sh",
        "audit_app_bundle.sh",
        "audit_selection_helper_bundle.sh",
        "sign_direct_bundle.sh",
        "package_dmg.sh",
        "notarize_dmg.sh",
    ]:
        require((ROOT / "script/release" / script).is_file(), f"release script missing: {script}")

    store_build_script = read("script/release/build_app_store_beta.sh")
    require(
        "CODE_SIGN_STYLE=Automatic" not in store_build_script,
        "Store build script must not override manual signing with Automatic",
    )
    require(
        "-allowProvisioningUpdates" not in store_build_script,
        "Store build script must not request automatic provisioning updates",
    )
    require(
        "CODE_SIGN_STYLE=Manual" in store_build_script,
        "Store build script must explicitly preserve manual signing",
    )
    require(
        "PROVISIONING_PROFILE_SPECIFIER" in store_build_script,
        "Store build script must require an explicit local provisioning profile",
    )
    require(
        "BLOCKS_APPLE_DISTRIBUTION_IDENTITY" in store_build_script
        and 'CODE_SIGN_IDENTITY="$identity"' in store_build_script
        and 'store_identity_pattern="^Apple Distribution: .+' in store_build_script
        and '--expected-authority "$identity"' in store_build_script,
        "Store build must bind its exact Apple Distribution authority to signing and audit",
    )

    app_audit_script = read("script/release/audit_app_bundle.sh")
    require(
        server_entitlement not in app_audit_script,
        "Direct/App Store signed-entitlement audit must continue rejecting network.server",
    )
    for marker in [
        "BlocksClipboardBroker",
        "BlocksPluginRunner.xpc/Contents/MacOS/BlocksPluginRunner",
        "TeamIdentifier",
        "--entitlements :-",
        "embedded.provisionprofile",
        "security cms -D -i",
        "--expected-team-id",
        "--expected-cert-sha1 must be the explicit 40-hex signing certificate SHA-1",
        "--require-signature requires an explicit non-empty --expected-authority",
        "expected_team_id",
        "allowed whitelist",
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
        "keychain-access-groups",
        "ExpirationDate",
        "application-identifier",
        "Direct ActionBroker contains a DEBUG-only identity marker",
        "Applications/BlocksDev/Debug/",
        "Library/Developer/Xcode/DerivedData/",
        "unexpected signed entitlement",
        "Direct app Mach exceptions must contain exactly ActionBroker and Sparkle spks/spki",
        "Sparkle signature lacks a secure timestamp",
        "forbidden Sparkle entitlement",
        "signing Identifier differs",
        'if [[ -s "$entitlement_file" ]]',
        'unexpected Mach-O executable in bundle',
        '"$contents/Resources/CLI/blocks"',
        'allowed_mach_o_paths',
    ]:
        require(marker in app_audit_script, f"bundle signing audit missing: {marker}")
    require(
        "BLOCKS_EXPECTED_SIGNING_AUTHORITY" not in app_audit_script,
        "bundle audit must not fall back to an optional Authority environment variable",
    )
    require('"$contents/Frameworks/"*' not in app_audit_script, "Frameworks wildcard allowlist remains")
    require(
        "find \"$contents\" -type f -print0" in app_audit_script,
        "bundle audit must inventory every regular file before signing",
    )
    require(
        "find \"$contents\" -type f -perm -111" not in app_audit_script,
        "bundle audit must not infer signing targets from executable permissions",
    )
    base_allowlist_match = re.search(
        r"allowed_mach_o_paths=\(\n((?:[ \t]+\"[^\n]+\"\n)+)[ \t]*\)", app_audit_script
    )
    require(base_allowlist_match is not None, "base Mach-O allowlist is missing")
    base_allowlist = re.findall(r'\"([^\"]+)\"', base_allowlist_match.group(1))
    require(
        base_allowlist == ["$main_executable", "$clipboard_broker", "$plugin_runner"],
        "base Mach-O allowlist differs from the exact Store policy",
    )
    direct_allowlist_match = re.search(
        r"allowed_mach_o_paths\+=\(\n((?:[ \t]+\"[^\n]+\"\n)+)[ \t]*\)", app_audit_script
    )
    require(direct_allowlist_match is not None, "Direct Mach-O allowlist is missing")
    direct_allowlist = re.findall(r'\"([^\"]+)\"', direct_allowlist_match.group(1))
    require(
        direct_allowlist == [
            "$contents/MacOS/BlocksActionBroker",
            "$contents/Resources/CLI/blocks",
            "$embedded_helper_executable",
            "$sparkle_framework_binary",
            "$sparkle_installer_binary",
            "$sparkle_downloader_binary",
            "$sparkle_autoupdate",
            "$sparkle_updater_binary",
        ],
        "Direct Mach-O allowlist differs from the exact release policy",
    )
    sign_direct_script = read("script/release/sign_direct_bundle.sh")
    require("Sparkle.framework" in sign_direct_script, "Direct signing must explicitly sign Sparkle nested components")
    require("find " not in sign_direct_script, "Direct signing must use only explicit known targets")
    for target in [
        "BlocksPluginRunner.xpc",
        "BlocksClipboardBroker",
        "BlocksActionBroker",
        "Resources/CLI/blocks",
        "XPCServices/Installer.xpc",
        "XPCServices/Downloader.xpc",
        "sparkle_autoupdate",
        "sparkle_updater",
    ]:
        require(target in sign_direct_script, f"Direct signing target missing: {target}")
    require(
        "resolved_main_entitlements" in sign_direct_script
        and "plutil -replace keychain-access-groups" in sign_direct_script
        and "--entitlements \"$resolved_main_entitlements\"" in sign_direct_script
        and "grep -Fq '$(AppIdentifierPrefix)' \"$resolved_main_entitlements\"" in sign_direct_script,
        "Direct post-sign must use a resolved Keychain entitlement file without an AppIdentifierPrefix placeholder",
    )
    verify_unexpected_bundle_members_are_rejected()
    verify_direct_signature_audit_is_hermetic()
    verify_store_signature_audit_is_hermetic()
    verify_selection_helper_bundle_members_are_rejected()
    verify_selection_helper_signature_audit_is_hermetic()
    verify_selection_helper_release_identity()
    verify_store_bad_team_fails_before_xcodebuild()
    verify_package_dmg_is_hermetic()
    verify_notarize_dmg_identity_pins_are_hermetic()

    allowed_key_blocks = []
    for block in re.findall(
        r"allowed_keys=\(\n((?:[ \t]+[^\n]+\n)+?)[ \t]+\)",
        app_audit_script,
    ):
        keys = tuple(
            sorted(
                line.strip()
                for line in block.splitlines()
                if line.strip()
            )
        )
        if keys:
            allowed_key_blocks.append(keys)
    identity_only = tuple(sorted((
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
    )))
    sandbox_identity = tuple(sorted((
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
        "com.apple.security.app-sandbox",
    )))
    expected_allowed_key_blocks = Counter({
        tuple(sorted((
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client",
            "com.apple.security.temporary-exception.files.absolute-path.read-only",
            "com.apple.security.temporary-exception.mach-lookup.global-name",
            "keychain-access-groups",
        ))): 1,
        tuple(sorted((
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "com.apple.security.app-sandbox",
            "com.apple.security.inherit",
        ))): 1,
        sandbox_identity: 2,
        identity_only: 1,
    })
    require(
        Counter(allowed_key_blocks) == expected_allowed_key_blocks,
        "component entitlement allowlists differ from the exact release policy",
    )

    store_entitlement_match = re.search(
        r"expected_store_entitlements=\(\n((?:[ \t]+[^\n]+\n)+?)[ \t]+\)",
        app_audit_script,
    )
    require(store_entitlement_match is not None, "Store entitlement allowlist is missing")
    store_entitlements = {
        line.strip()
        for line in store_entitlement_match.group(1).splitlines()
        if line.strip()
    }
    require(
        store_entitlements == {
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client",
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
        },
        "Store entitlement allowlist differs from the exact release policy",
    )

    helper_audit_script = read("script/release/audit_selection_helper_bundle.sh")
    require("--expected-team-id" in helper_audit_script, "Helper audit must require an explicit expected Team ID")
    require(
        "--require-signature requires an explicit non-empty --expected-authority" in helper_audit_script
        and "BLOCKS_EXPECTED_SIGNING_AUTHORITY" not in helper_audit_script,
        "Helper audit must require an explicit Authority without an environment fallback",
    )
    require("--expected-cert-sha1 must be the explicit 40-hex signing certificate SHA-1" in helper_audit_script, "Helper audit must require an explicit certificate SHA-1")
    require("TeamIdentifier differs from expected Team ID" in helper_audit_script, "Helper Team ID mismatch rejection missing")
    require("Helper signing Identifier differs" in helper_audit_script, "Helper signing identifier mismatch rejection missing")
    require("unexpected Helper signed entitlement" in helper_audit_script, "Helper entitlement whitelist missing")
    require("Helper signed entitlements are missing" in helper_audit_script, "Helper audit must reject a missing entitlement set")
    require("Helper signed keychain-access-groups" in helper_audit_script, "Helper audit must require the shared Keychain access group")
    require("unexpected nested Helper executable" in helper_audit_script, "Helper audit must reject unknown nested Mach-O executables")
    require(
        'find "$contents" -type l -print -quit' in helper_audit_script,
        "Helper audit must reject every symbolic link before signature validation",
    )
    require(
        'find "$contents" -type f -print0' in helper_audit_script,
        "Helper audit must inventory every regular file for Mach-O payloads",
    )
    require(
        'find "$app_bundle/Contents" -type f -perm -111' not in helper_audit_script,
        "Helper audit must not infer Mach-O payloads from executable permissions",
    )
    require(
        set(re.findall(r"com\.apple\.[A-Za-z0-9.-]+", helper_audit_script))
        == {
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
        },
        "Helper entitlement policy must remain identity plus shared Keychain only",
    )

    for build_script in [
        "script/release/build_direct_beta.sh",
        "script/release/build_app_store_beta.sh",
    ]:
        contents = read(build_script)
        require("--expected-team-id" in contents, f"signed audit does not receive expected Team ID: {build_script}")
        require('--expected-authority "$identity"' in contents, f"signed audit does not receive exact Authority: {build_script}")
        require("BLOCKS_EXPECTED_SIGNING_CERT_SHA1" in contents, f"signed build does not require expected certificate SHA-1: {build_script}")
        require("--expected-cert-sha1" in contents, f"signed audit does not receive expected certificate SHA-1: {build_script}")
    direct_build_script = read("script/release/build_direct_beta.sh")
    for script_name, contents in [
        ("Direct app", direct_build_script),
        ("Direct Helper", selection_helper_build_script),
    ]:
        require(
            "BLOCKS_DEVELOPER_ID_APPLICATION" in contents
            and 'direct_identity_pattern="^Developer ID Application: .+' in contents
            and '--expected-authority "$identity"' in contents,
            f"{script_name} build must bind an exact team-qualified Developer ID authority",
        )
    require(
        "--expected-team-id" in selection_helper_build_script,
        "signed audit does not receive expected Team ID: script/release/build_selection_helper_beta.sh",
    )
    require(
        "BLOCKS_EXPECTED_SIGNING_CERT_SHA1" in selection_helper_build_script,
        "signed build does not require expected certificate SHA-1: script/release/build_selection_helper_beta.sh",
    )
    require(
        "--expected-cert-sha1" in selection_helper_build_script,
        "signed audit does not receive expected certificate SHA-1: script/release/build_selection_helper_beta.sh",
    )
    require(
        '--expected-authority "$identity"' in selection_helper_build_script,
        "Helper signed audit does not receive exact Developer ID authority",
    )
    require(
        "resolved_helper_entitlements" in selection_helper_build_script
        and "plutil -replace keychain-access-groups" in selection_helper_build_script
        and "--entitlements \"$resolved_helper_entitlements\"" in selection_helper_build_script,
        "Helper post-sign must use a resolved shared Keychain entitlement file",
    )
    notarize_script = read("script/release/notarize_dmg.sh")
    for marker in [
        "--evidence-dir",
        "--expected-team-id",
        "--expected-authority",
        "--expected-cert-sha1",
        "verify_pinned_signature",
        "audit_mounted_artifact",
        "audit_app_bundle.sh",
        "audit_selection_helper_bundle.sh",
        "notary-submit.json",
        "notary-log.json",
        "stapler-staple.txt",
        "mounted-app-spctl-exec.txt",
        "hdiutil attach -readonly -nobrowse -plist",
        "spctl --assess --type exec",
        "hdiutil detach",
        "final-dmg.sha256",
        "shasum -a 256 -c",
        "refusing to replace a concurrently published checksum",
    ]:
        require(marker in notarize_script, f"notarization evidence contract missing: {marker}")
    require(
        re.search(r"(?m)^[ \t]*mv -n\b", notarize_script) is None,
        "final checksum publication must not use silent mv -n semantics",
    )
    package_script = read("script/release/package_dmg.sh")
    for marker in [
        "--artifact direct-stable|direct-beta|selection-helper-stable|selection-helper-beta",
        "--expected-team-id",
        "--expected-cert-sha1",
        "--expected-authority",
        "audit_app_bundle.sh",
        "audit_selection_helper_bundle.sh",
        "checksum=pending-notarization-and-staple",
        "refusing to replace a concurrently published DMG",
    ]:
        require(marker in package_script, f"DMG package identity contract missing: {marker}")
    require(
        'direct_identity_pattern="^Developer ID Application: .+' in package_script
        and '[[ "$dmg_authority" == "$identity" ]]' in package_script,
        "DMG package must require and verify the exact Direct authority",
    )
    require(
        "shasum -a 256" not in package_script,
        "DMG checksum must not be created before notarization and staple",
    )
    require(
        re.search(r"(?m)^[ \t]*mv -n\b", package_script) is None,
        "DMG publication must not use silent mv -n semantics",
    )

    site_content = read("site/app/site-content.ts")
    site_components = read("site/app/site-components.tsx")
    site_renderer = read("site/scripts/render.tsx")
    require('brand: "积木工具"' in site_content, "Chinese public brand drifted")
    require(site_content.count('brand: "Blocks for Mac"') == 2, "English/Japanese brand drifted")
    for address in [
        "support@orangeforge.top",
        "privacy@orangeforge.top",
        "security@orangeforge.top",
    ]:
        require(address in site_content, f"reserved contact missing: {address}")
    public_site_sources = site_content + site_components + site_renderer
    require("Orange Forge" not in public_site_sources, "Orange Forge exposed as a brand")
    require("积木工具 / Blocks" not in site_renderer, "legacy Chinese brand remains in renderer")
    require("積木ツール / Blocks" not in site_renderer, "legacy Japanese brand remains in renderer")
    require(
        '{ src: "/product/translation.jpeg", width: 678, height: 711 }' in site_components,
        "translation screenshot intrinsic dimensions drifted",
    )
    require(
        '{ src: "/product/clipboard.jpeg", width: 1920, height: 292 }' in site_components,
        "clipboard screenshot format or intrinsic dimensions drifted",
    )
    require("clipboard.png" not in site_components, "mislabeled clipboard screenshot returned")

    print("PASS: release distribution static checks")


if __name__ == "__main__":
    main()
