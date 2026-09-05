#!/usr/bin/env python3
"""P7-D permission assist and glass diagnostics checks."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP_MODEL = ROOT / "apps/Blocks/BlocksApp/App/AppModel.swift"
PERMISSION_COORDINATOR = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionFeatureCoordinator.swift"
PERMISSION_STORE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStore.swift"
PERMISSION_ACTIONS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionSystemActions.swift"
PERMISSION_DIAGNOSTICS = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionDiagnostics.swift"
PERMISSION_STATE = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionStateService.swift"
PERMISSION_VIEW = ROOT / "apps/Blocks/BlocksApp/Features/Permissions/PermissionAssistPanelView.swift"
PERMISSION_PRESENTER = ROOT / "apps/Blocks/BlocksApp/Services/PermissionAssistPanelPresenter.swift"
PERMISSION_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/PermissionSettingsPane.swift"
GENERAL_SETTINGS = ROOT / "apps/Blocks/BlocksApp/Features/Settings/GeneralSettingsPane.swift"
GLASS = ROOT / "apps" / "Blocks" / "BlocksApp" / "Support" / "GlassPanel.swift"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
LOCALIZABLE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Resources" / "Localizable.xcstrings"
LANGUAGES = ["zh-Hans", "en", "ja"]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def require(ok: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not ok:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    failures: list[dict[str, str]] = []
    app_model = text(APP_MODEL)
    permission_coordinator = text(PERMISSION_COORDINATOR)
    permission_store = text(PERMISSION_STORE)
    permission_actions = text(PERMISSION_ACTIONS)
    diagnostics = text(PERMISSION_DIAGNOSTICS)
    state_service = text(PERMISSION_STATE)
    assist_view = text(PERMISSION_VIEW)
    presenter = text(PERMISSION_PRESENTER)
    combined = "\n".join([
        app_model,
        permission_coordinator,
        permission_store,
        permission_actions,
        diagnostics,
        state_service,
        assist_view,
        presenter,
        text(PERMISSION_SETTINGS),
        text(GENERAL_SETTINGS),
        text(GLASS),
        text(PROJECT),
    ])

    required = [
        "PermissionAssistPanelPresenter.swift in Sources",
        "PermissionDiagnostics.swift in Sources",
        "PermissionStateService.swift in Sources",
        "PermissionAssistPanelView.swift in Sources",
        "requestScreenRecordingPermissionAssist",
        "PermissionAssistPanelView",
        "NSItemProvider(object: sessionModel.appURL as NSURL)",
        "AnimatedPermissionArrow",
        ".trim(from: 0, to: progress)",
        "DisclosureGroup(isExpanded: $glassDiagnosticsExpanded)",
        "title: L10n.string(\"settings.glassDiagnostics.system\")",
        ".padding(.vertical, SettingsLayout.rowVerticalPadding)",
        "SystemTransparencyDiagnostics",
        "reduceTransparencyEnabled",
        "persistentDomain(forName: \"com.apple.universalaccess\")",
        "settings.glassDiagnostics.reduceOffDetail",
        "if #available(macOS 26.0, *)",
    ]
    missing = [symbol for symbol in required if symbol not in combined]
    require(not missing, "missing_permission_glass_symbols", ", ".join(missing), failures)
    require(
        "permissionCoordinator?.requestScreenRecordingPermissionAssist()" in app_model
        and "store.requestScreenRecordingPermissionAssist" in permission_coordinator
        and "assistPresenter.present(kind: .screenRecording)" in permission_store
        and "presenter.present(kind: kind, onFlowEnded: onRefresh)" in permission_actions
        and "_ = NSWorkspace.shared.open(url)" in presenter
        and "openSystemSettings(settingsURL)" in presenter,
        "permission_assist_not_chained",
        "Opening permission should route through the assist flow, which opens System Settings and shows the panel.",
        failures,
    )

    localizable = json.loads(text(LOCALIZABLE))
    for key in [
        "permission.assist.title",
        "permission.assist.dragTitle",
        "permission.assist.dragDetail",
        "permission.assist.openedSettings",
        "settings.glassDiagnostics.title",
        "settings.glassDiagnostics.reduceOffDetail",
    ]:
        entry = localizable.get("strings", {}).get(key)
        missing_langs = [lang for lang in LANGUAGES if lang not in (entry or {}).get("localizations", {})]
        require(entry is not None and not missing_langs, "missing_localization", f"{key}:{','.join(missing_langs)}", failures)

    print(json.dumps({"ok": not failures, "suite": "p7d_permission_assist_glass_diagnostics_checks", "failures": failures}, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
