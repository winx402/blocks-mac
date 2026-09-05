#!/usr/bin/env python3
"""Compatibility gate replacing the retired screenshot AI action entry."""

from __future__ import annotations

import argparse

from p3c_screenshot_checks import run_compatibility_gate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    return run_compatibility_gate(
        "p3d_screenshot_ai_action_entry_checks",
        ["P14-C"],
        args.timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
