#!/usr/bin/env python3
"""Shared, pure version contract for publisher and installer entry points."""
from __future__ import annotations

import json
import re
import sys
from dataclasses import asdict, dataclass

_SEMVER = re.compile(
    r"^(?P<marketing>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"
    r"(?P<prerelease>-(?:0|[1-9][0-9]*|[0-9A-Za-z-]+)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]+))*)?"
    r"(?:\+(?:[0-9A-Za-z-]+)(?:\.[0-9A-Za-z-]+)*)?$")


@dataclass(frozen=True)
class ReleaseVersion:
    tag: str
    release_name: str
    marketing_version: str
    is_prerelease: bool


def parse_release_version(value: str) -> ReleaseVersion:
    """Parse an unprefixed SemVer release name into the public tag contract."""
    if not isinstance(value, str) or value.startswith("v"):
        raise ValueError("release version must be an unprefixed SemVer string")
    match = _SEMVER.fullmatch(value)
    if not match:
        raise ValueError("release version is not valid SemVer")
    prerelease = match.group("prerelease")
    if prerelease and any(part.isdigit() and len(part) > 1 and part.startswith("0")
                          for part in prerelease[1:].split(".")):
        raise ValueError("numeric prerelease identifiers cannot have leading zeroes")
    return ReleaseVersion("v" + value, value, match.group("marketing"), bool(match.group("prerelease")))


def validate_bundle_version(tag: str, release_name: str, marketing_version: str, build_number: str) -> ReleaseVersion:
    """Validate tag, Bundle release name and Apple marketing/build fields together."""
    if not isinstance(tag, str) or not tag.startswith("v"):
        raise ValueError("tag must start with v")
    parsed = parse_release_version(tag[1:])
    if parsed.release_name != release_name or parsed.marketing_version != marketing_version:
        raise ValueError("tag, BLOCKS_RELEASE_NAME, and CFBundleShortVersionString disagree")
    if not isinstance(build_number, str) or not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ValueError("CFBundleVersion must be a positive integer")
    return parsed


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] != "validate-tag":
        print("usage: release_versioning.py validate-tag VERSION", file=sys.stderr)
        return 2
    try:
        parsed = parse_release_version(argv[1])
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(asdict(parsed), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
