#!/usr/bin/env python3
"""Release-version overlay checks; showBuildSettings only, never builds or signs."""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "script/release/release_xcconfig.py"
PROFILE = ROOT / "apps/Blocks/Config/Distribution.DirectBeta.xcconfig"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"
PINNED_FEED = "https://winx402.github.io/blocks-mac/appcast/stable.xml"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def render_overlay(directory: Path, *, version: str, build: str, name: str, feed: str = PINNED_FEED) -> Path:
    result = subprocess.run(
        [
            sys.executable, str(GENERATOR), "--base-profile", str(PROFILE.resolve()),
            "--version", version, "--build-number", build,
            "--release-name", name, "--update-feed-url", feed,
        ],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    require(result.returncode == 0, f"overlay generation failed: {result.stderr}")
    require(
        f'#include "{PROFILE.resolve()}"' in result.stdout
        and "BLOCKS_UPDATE_FEED_URL = https:/$()/winx402.github.io/blocks-mac/appcast/stable.xml" in result.stdout,
        "overlay did not retain the absolute base include and encoded HTTPS feed",
    )
    overlay = directory / f"{name}.xcconfig"
    overlay.write_text(result.stdout, encoding="utf-8")
    return overlay


def build_settings(scheme: str, overlay: Path) -> dict[str, set[str]]:
    result = subprocess.run(
        [
            "xcodebuild", "-project", str(PROJECT), "-scheme", scheme,
            "-configuration", "Release", "-xcconfig", str(overlay),
            "CODE_SIGNING_ALLOWED=NO", "-showBuildSettings",
        ],
        cwd=ROOT, text=True, capture_output=True, check=False,
    )
    require(
        result.returncode == 0,
        f"xcodebuild -showBuildSettings failed for {scheme}: {result.stderr}",
    )
    # The stable scheme name is an automation entry point; the Helper target
    # and product were renamed without removing that entry point.
    target = "blocksHelper" if scheme == "BlocksSelectionHelper" else scheme
    section = re.search(
        rf"Build settings for action build and target {re.escape(target)}:\n(?P<body>.*?)(?=\nBuild settings for action|\Z)",
        result.stdout,
        re.DOTALL,
    )
    require(section is not None, f"xcodebuild did not report a {target} target settings section for {scheme}")
    values: dict[str, set[str]] = {}
    for key, value in re.findall(r"(?m)^\s*([A-Z0-9_]+) = (.*)$", section.group("body")):
        values.setdefault(key, set()).add(value.strip())
    return values


def require_settings(scheme: str, overlay: Path, expected: dict[str, str]) -> None:
    settings = build_settings(scheme, overlay)
    for key, value in expected.items():
        actual = settings.get(key, set())
        require(actual == {value}, f"{scheme} {key} expected {value!r}, got {sorted(actual)!r}")
    require(
        settings.get("ENABLE_HARDENED_RUNTIME") == {"YES"},
        f"{scheme} lost the base profile hardened-runtime setting",
    )


def test_real_xcode_build_settings() -> None:
    before = PROFILE.read_bytes()
    with tempfile.TemporaryDirectory(prefix="blocks-release-xcconfig-") as temporary:
        directory = Path(temporary)
        beta = render_overlay(directory, version="0.1.0", build="2", name="0.1.0-beta.2")
        stable = render_overlay(directory, version="0.1.0", build="3", name="0.1.0")
        for scheme in ("Blocks", "BlocksSelectionHelper"):
            require_settings(scheme, beta, {
                "MARKETING_VERSION": "0.1.0",
                "CURRENT_PROJECT_VERSION": "2",
                "BLOCKS_RELEASE_NAME": "0.1.0-beta.2",
                "BLOCKS_DISTRIBUTION_CHANNEL": "direct-beta",
                "BLOCKS_UPDATE_FEED_URL": PINNED_FEED,
            })
            require_settings(scheme, stable, {
                "MARKETING_VERSION": "0.1.0",
                "CURRENT_PROJECT_VERSION": "3",
                "BLOCKS_RELEASE_NAME": "0.1.0",
                "BLOCKS_DISTRIBUTION_CHANNEL": "direct-stable",
                "BLOCKS_UPDATE_FEED_URL": PINNED_FEED,
            })
    require(PROFILE.read_bytes() == before, "overlay generation modified the committed profile")


def test_invalid_input_is_fail_closed() -> None:
    base = [sys.executable, str(GENERATOR), "--base-profile", str(PROFILE.resolve())]
    invalid = [
        ["--version", "0.1.1", "--build-number", "2", "--release-name", "0.1.0-beta.2", "--update-feed-url", PINNED_FEED],
        ["--version", "0.1.0", "--build-number", "02", "--release-name", "0.1.0-beta.2", "--update-feed-url", PINNED_FEED],
        ["--version", "0.1.0", "--build-number", "2", "--release-name", "0.1.0-beta.2", "--update-feed-url", "https://example.invalid/feed.xml\nCURRENT_PROJECT_VERSION = 99"],
    ]
    for arguments in invalid:
        result = subprocess.run(base + arguments, cwd=ROOT, text=True, capture_output=True, check=False)
        require(result.returncode != 0 and not result.stdout, f"invalid overlay input was accepted: {arguments!r}")


def test_scripts_keep_profile_default_and_overlay_cleanup() -> None:
    for relative in [
        "script/release/build_selection_helper_beta.sh",
        "script/release/build_direct_beta.sh",
    ]:
        contents = (ROOT / relative).read_text(encoding="utf-8")
        require('active_profile="$profile"' in contents, f"{relative} no-version path no longer uses the committed profile")
        require('release_xcconfig.py' in contents and '-xcconfig "$active_profile"' in contents, f"{relative} does not use the generated overlay")
        require('MARKETING_VERSION="$version"' not in contents, f"{relative} still passes release identity as a CLI setting")
        require('BLOCKS_DISTRIBUTION_CHANNEL="$channel"' not in contents, f"{relative} still overrides the profile channel at the CLI")
        require('mktemp "${TMPDIR:-/tmp}/blocks-release-overlay.XXXXXX"' in contents and 'chmod 600 "$release_overlay"' in contents, f"{relative} does not create a private overlay")
    helper = (ROOT / "script/release/build_selection_helper_beta.sh").read_text(encoding="utf-8")
    require('trap cleanup_release_artifacts EXIT' in helper, "Helper overlay cleanup replaces its entitlement cleanup trap")
    require(
        '[[ -z "${release_overlay:-}" ]] || /bin/rm -f -- "$release_overlay"' in helper
        and '[[ -z "${resolved_helper_entitlements:-}" ]] || /bin/rm -f -- "$resolved_helper_entitlements"' in helper,
        "Helper cleanup does not retain guarded overlay and entitlement cleanup",
    )
    with tempfile.TemporaryDirectory(prefix="blocks-release-no-version-") as temporary:
        for relative, expected_error in [
            ("script/release/build_selection_helper_beta.sh", "--provisioning-profile"),
            ("script/release/build_direct_beta.sh", "--embedded-helper"),
        ]:
            result = subprocess.run(
                ["bash", str(ROOT / relative)], cwd=ROOT, text=True, capture_output=True,
                env={**os.environ, "TMPDIR": temporary}, check=False,
            )
            require(result.returncode != 0 and expected_error in result.stderr, f"{relative} no-version preflight changed")
        require(not list(Path(temporary).iterdir()), "no-version preflight created a release overlay")


def main() -> None:
    test_real_xcode_build_settings()
    test_invalid_input_is_fail_closed()
    test_scripts_keep_profile_default_and_overlay_cleanup()
    print("PASS: release xcconfig overlay self-test")


if __name__ == "__main__":
    main()
