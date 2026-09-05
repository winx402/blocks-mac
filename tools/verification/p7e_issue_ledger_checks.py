#!/usr/bin/env python3
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / "docs/项目管理库/实施记录/stories/p7-e-settings-clipboard-translation-permission-deep-polish.md"


def main() -> int:
    text = LEDGER.read_text(encoding="utf-8")
    required = [
        "P7-E-01",
        "P7-E-02",
        "P7-E-03",
        "P7-E-04",
        "P7-E-05",
        "Research",
        "Plan",
        "Dev",
        "Test",
        "Close",
        "pending low-sensitive manual acceptance",
    ]
    missing = [item for item in required if item not in text]
    ok = not missing
    print(json.dumps({
        "ok": ok,
        "check": "p7e_issue_ledger",
        "ledger": str(LEDGER.relative_to(ROOT)),
        "missing": missing,
    }, ensure_ascii=False, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
