#!/usr/bin/env python3
"""Compatibility gate for the P14 screenshot store and platform boundaries."""

from __future__ import annotations

import argparse

from p3c_screenshot_checks import run_compatibility_gate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    return run_compatibility_gate(
        "p11a_screenshot_store_boundary_checks",
        ["P14-A", "P14-B", "P14-C", "P14-D", "P14-F"],
        args.timeout,
        legacy_gate="P11A",
    )


if __name__ == "__main__":
    raise SystemExit(main())
