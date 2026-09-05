#!/usr/bin/env python3
"""P11-B PermissionStore boundary checks for Step 5."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
APP_MODEL = APP / "App" / "AppModel.swift"
PERMISSION_STORE = APP / "Features" / "Permissions" / "PermissionStore.swift"
PERMISSION_ACTIONS = APP / "Features" / "Permissions" / "PermissionSystemActions.swift"
PERMISSION_PANE = APP / "Features" / "Settings" / "PermissionSettingsPane.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
STEP5_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_5" / "PRD-Step5-门禁清理关闭-v0.md"


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def fail(failures: list[dict], code: str, detail: str, path: Path) -> None:
    failures.append({"code": code, "detail": detail, "path": rel(path)})


def main() -> int:
    failures: list[dict] = []
    required = [APP_MODEL, PERMISSION_STORE, PERMISSION_ACTIONS, PERMISSION_PANE, PROJECT, STEP5_PRD]
    for path in required:
        if not path.exists():
            fail(failures, "missing_file", "required current fact source missing", path)

    app_model = read(APP_MODEL)
    store = read(PERMISSION_STORE)
    pane = read(PERMISSION_PANE)
    project = read(PROJECT)

    if "PermissionStore.swift" not in project or "PermissionStore.swift in Sources" not in project:
        fail(failures, "target_membership_missing", "PermissionStore.swift", PROJECT)
    if "PermissionSystemActions.swift" not in project or "PermissionSystemActions.swift in Sources" not in project:
        fail(failures, "target_membership_missing", "PermissionSystemActions.swift", PROJECT)

    required_store_terms = [
        "final class PermissionStore: ObservableObject",
        "@Published private(set) var permissionSnapshot",
        "PermissionSnapshotProviding",
        "PermissionAccessRequesting",
        "PermissionAssistPresenting",
        "PermissionSystemActioning",
        "func refreshPermissionState()",
        "requestScreenRecordingPermissionAssist",
        "requestAccessibilityPermissionAssist",
    ]
    missing = [term for term in required_store_terms if term not in store]
    if missing:
        fail(failures, "permission_store_contract_missing", ", ".join(missing), PERMISSION_STORE)

    forbidden_app_model = [
        "var permissionSnapshot",
        "@Published var permissionSnapshot",
    ]
    hits = [term for term in forbidden_app_model if term in app_model]
    if hits:
        fail(failures, "app_model_permission_facade_remaining", ", ".join(hits), APP_MODEL)

    if "@EnvironmentObject private var permissionStore: PermissionStore" not in pane:
        fail(failures, "permission_pane_not_direct_store", "PermissionSettingsPane must read PermissionStore directly", PERMISSION_PANE)
    if "permissionStore.permissionSnapshot" not in pane:
        fail(failures, "permission_snapshot_not_from_store", "Permission pane must use store snapshot", PERMISSION_PANE)

    if "Clipboard" in store or "ClipboardStore" in store or "AppModel" in store:
        fail(failures, "permission_store_cross_feature_reference", "PermissionStore must not hold clipboard/AppModel", PERMISSION_STORE)

    payload = {
        "ok": not failures,
        "gate": "P11B",
        "checked_files": [rel(path) for path in required],
        "current_evidence": {"prd": rel(STEP5_PRD)},
        "baseline_reference": {"old_archives_used_for_ok": False},
        "failures": failures,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
