#!/usr/bin/env python3
"""Compatibility gate replacing the retired screenshot result panel."""

from __future__ import annotations

import argparse

from p3c_screenshot_checks import run_compatibility_gate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    return run_compatibility_gate(
        "p3e_screenshot_result_polish_checks",
        ["P14-C", "P14-D"],
        args.timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
