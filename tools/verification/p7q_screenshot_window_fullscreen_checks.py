#!/usr/bin/env python3
"""Compatibility gate replacing the old window/fullscreen mode checks."""

from __future__ import annotations

import argparse

from p3c_screenshot_checks import run_compatibility_gate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    return run_compatibility_gate(
        "p7q_screenshot_window_fullscreen_checks",
        ["P14-B", "P14-E"],
        args.timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
