#!/usr/bin/env python3
"""Render a private Direct distribution xcconfig overlay for one release."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from urllib.parse import urlsplit

from release_versioning import validate_bundle_version


PINNED_UPDATE_FEED_URL = "https://winx402.github.io/blocks-mac/appcast/stable.xml"


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a validated, ephemeral Direct distribution xcconfig overlay."
    )
    parser.add_argument("--base-profile", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--release-name", required=True)
    parser.add_argument("--update-feed-url", required=True)
    return parser.parse_args(argv)


def validate_base_profile(value: str) -> Path:
    base_profile = Path(value)
    if not base_profile.is_absolute():
        raise ValueError("base profile must be an absolute path")
    resolved = base_profile.resolve(strict=True)
    if not resolved.is_file():
        raise ValueError("base profile must be a regular file")
    if '"' in str(resolved) or "\n" in str(resolved) or "\r" in str(resolved):
        raise ValueError("base profile path is not safe for an xcconfig include")
    return resolved


def xcconfig_https_url(value: str) -> str:
    """Validate the pinned HTTPS feed and avoid xcconfig's // comment syntax."""
    if "\n" in value or "\r" in value:
        raise ValueError("update feed URL must be a single line")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError("update feed URL must be an absolute HTTPS URL")
    if value != PINNED_UPDATE_FEED_URL:
        raise ValueError("update feed URL does not match the pinned Direct feed")
    # xcconfig treats // as a comment. $() expands to an empty string in Xcode.
    return "https:/$()/" + value.removeprefix("https://")


def render(argv: list[str]) -> str:
    args = parse_arguments(argv)
    base_profile = validate_base_profile(args.base_profile)
    release = validate_bundle_version(
        "v" + args.release_name,
        args.release_name,
        args.version,
        args.build_number,
    )
    channel = "direct-beta" if release.is_prerelease else "direct-stable"
    update_feed_url = xcconfig_https_url(args.update_feed_url)
    return "\n".join((
        "// Generated for one release invocation. Do not commit this file.",
        f'#include "{base_profile}"',
        f"MARKETING_VERSION = {args.version}",
        f"CURRENT_PROJECT_VERSION = {args.build_number}",
        f"BLOCKS_RELEASE_NAME = {args.release_name}",
        f"BLOCKS_DISTRIBUTION_CHANNEL = {channel}",
        f"BLOCKS_UPDATE_FEED_URL = {update_feed_url}",
        "",
    ))


def main(argv: list[str] | None = None) -> int:
    try:
        print(render(sys.argv[1:] if argv is None else argv), end="")
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
