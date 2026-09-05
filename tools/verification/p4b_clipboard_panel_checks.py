#!/usr/bin/env python3
"""Retired P4-B gate retained as a no-build Step 5 cleanup guard."""

from __future__ import annotations

import argparse

from retired_p4_step5_cleanup_guard import main as step5_retired_main


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--skip-build", "--no-build", action="store_true", dest="skip_build")
    parser.parse_args()
    return step5_retired_main(__file__)


if __name__ == "__main__":
    raise SystemExit(main())
