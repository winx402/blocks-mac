#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks"
APP_CODE = APP / "BlocksApp"
PROJECT = APP / "Blocks.xcodeproj" / "project.pbxproj"
APP_MODEL = APP_CODE / "App" / "AppModel.swift"
MIGRATION = APP_CODE / "App" / "Step5OneShotMigration.swift"
STEP5_PRD = ROOT / "docs" / "项目管理库" / "003_架构升级" / "step_5" / "PRD-Step5-门禁清理关闭-v0.md"

DELETED_PATHS = [
    APP_CODE / "Stores" / "AppState.swift",
    APP_CODE / "Views" / "SettingsView.swift",
    APP_CODE / "Views" / "ClipboardHistoryView.swift",
    APP_CODE / "Services" / "ClipboardRecorderRuntimeService.swift",
    APP / "BlocksLoginItemHelper",
]

PROJECT_FORBIDDEN = [
    "AppState.swift",
    "SettingsView.swift",
    "ClipboardHistoryView.swift",
    "ClipboardRecorderRuntimeService.swift",
    "BlocksLoginItemHelper",
    "Embed LoginItems",
]

APP_FORBIDDEN_TOKENS = [
    "AppState",
    "SettingsView(",
    "@EnvironmentObject private var appState",
    "clipboardPayload(for:",
    "ClipboardRecorderRuntimeService",
    "RecorderRuntimeState",
    "BlocksLoginItemHelper",
    "runClipboardRecorder",
    "resetClipboardDebugStore",
    "importClipboardDebugStore",
    "recorderRuntimeState",
    "recorderSessionDurationSeconds",
    "recorderExcludeFrontmost",
]

APP_MODEL_FACADE_DENYLIST = [
    "var shortcutRegistrationResults",
    "var permissionSnapshot",
    "var lastCaptureSummary",
    "var recentCaptures",
    "var clipboardRecords",
    "var clipboardFilterState",
    "var clipboardPinboards",
    "var clipboardPinnedMetadata",
    "var clipboardRepositoryStateSummary",
    "var translationProviderProfiles",
    "var selectedTranslationProviderID",
    "var llmProviderProfiles",
    "var translationEngineProfiles",
    "var ocrEngineProfiles",
    "var selectedLLMProviderID",
    "var selectedTranslationEngineID",
    "var selectedOCREngineID",
    "var translationPreview",
    "var translationResult",
    "var translationRuntimeResult",
    "var providerAuditEvents",
    "var providerRouteResolution",
    "func filteredClipboardRecords(",
    "func clipboardPreview(",
    "func shortcutBinding(",
    "func shortcutRegistrationResult(",
    "func setClipboardFormatFilter(",
    "func setClipboardTimeFilter(",
    "func setClipboardPinboardFilter(",
    "func setClipboardSourceFilter(",
]

OLD_KEY_TOKENS = [
    "floatingPanel.clipboard.bottom.size",
    "shortcut.globalModifier.migratedControlOptionDefault.v2",
    "shortcut.customBinding.migratedControlOptionDefault.v2",
]

VERIFIER_FACT_SOURCES = [
    ROOT / "tools" / "verification" / "p11a_screenshot_store_boundary_checks.py",
    ROOT / "tools" / "verification" / "p11b_permission_store_checks.py",
    ROOT / "tools" / "verification" / "p11c_shortcut_store_checks.py",
    ROOT / "tools" / "verification" / "p11d_settings_shell_split_checks.py",
    ROOT / "tools" / "verification" / "p11e_clipboard_hardening_checks.py",
]


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def app_swift_files() -> list[Path]:
    return sorted(APP_CODE.rglob("*.swift"))


def add_failure(failures: list[dict], code: str, detail: str, path: Path | None = None) -> None:
    item = {"code": code, "detail": detail}
    if path is not None:
        item["path"] = rel(path)
    failures.append(item)


def check_deleted_paths(failures: list[dict]) -> dict:
    remaining = [path for path in DELETED_PATHS if path.exists()]
    for path in remaining:
        add_failure(failures, "deleted_path_still_exists", "Step 5 deleted path remains.", path)
    return {"remaining": [rel(path) for path in remaining]}


def check_project(failures: list[dict]) -> dict:
    text = read(PROJECT)
    hits = [token for token in PROJECT_FORBIDDEN if token in text]
    for token in hits:
        add_failure(failures, "project_forbidden_token", token, PROJECT)
    target_names_ok = all(token not in text for token in ["T00500000000000000000001", "P00500000000000000000001", "L00500000000000000000001"])
    if not target_names_ok:
        add_failure(failures, "project_helper_target_ids_remaining", "Helper target/build phases/config ids remain.", PROJECT)
    return {"forbidden_hits": hits, "helper_target_ids_absent": target_names_ok}


def check_app_tokens(failures: list[dict]) -> dict:
    hits: list[dict] = []
    allowed_old_key_file = MIGRATION.resolve()
    for path in app_swift_files():
        text = read(path)
        for token in APP_FORBIDDEN_TOKENS:
            if token in text:
                hits.append({"path": rel(path), "token": token})
                add_failure(failures, "app_forbidden_token", token, path)
        for token in OLD_KEY_TOKENS:
            if token in text and path.resolve() != allowed_old_key_file:
                hits.append({"path": rel(path), "token": token})
                add_failure(failures, "old_key_outside_one_shot_migration", token, path)
    return {"hits": hits}


def check_app_model_boundary(failures: list[dict]) -> dict:
    text = read(APP_MODEL)
    hits = [token for token in APP_MODEL_FACADE_DENYLIST if token in text]
    for token in hits:
        add_failure(failures, "app_model_feature_facade", token, APP_MODEL)
    required = [
        "let clipboardStore: ClipboardStore",
        "let providerStore: ProviderStore",
        "let translationStore: TranslationStore",
        "let permissionStore: PermissionStore",
        "let screenshotStore: ScreenshotStore",
        "let shortcutStore: ShortcutStore",
        "Step5OneShotMigration.run()",
    ]
    missing = [token for token in required if token not in text]
    for token in missing:
        add_failure(failures, "app_model_required_composition_missing", token, APP_MODEL)
    return {"facade_hits": hits, "required_missing": missing}


def check_helper_product_absent(failures: list[dict]) -> dict:
    app_bundle = ROOT / "DerivedData" / "Step5" / "Build" / "Products" / "Debug" / "Blocks.app"
    login_items = app_bundle / "Contents" / "Library" / "LoginItems"
    helper = login_items / "BlocksLoginItemHelper.app"
    if helper.exists():
        add_failure(failures, "built_product_helper_remaining", "Fresh Step5 build still contains helper app.", helper)
    return {
        "checked_bundle": rel(app_bundle),
        "login_items_exists": login_items.exists(),
        "helper_exists": helper.exists(),
    }


def check_verifiers_current_sources(failures: list[dict]) -> dict:
    result = {}
    for path in VERIFIER_FACT_SOURCES:
        if not path.exists():
            add_failure(failures, "required_verifier_missing", "Required P11 verifier is missing.", path)
            result[rel(path)] = {"exists": False}
            continue
        text = read(path)
        forbidden = [token for token in ["Stores/AppState.swift", "Views/SettingsView.swift", "000_归档"] if token in text]
        for token in forbidden:
            add_failure(failures, "verifier_uses_old_fact_source", token, path)
        result[rel(path)] = {
            "exists": True,
            "old_fact_source_hits": forbidden,
            "has_current_evidence": "current_evidence" in text or "Step5" in text,
        }
    return result


def check_prd_flow(failures: list[dict]) -> dict:
    text = read(STEP5_PRD) if STEP5_PRD.exists() else ""
    required_tokens = [
        "Step 5",
        "P12",
        "AppModel",
        "one-shot migration",
        "低敏实物证据",
        "VoiceOver",
        "fresh DerivedData",
    ]
    missing = [token for token in required_tokens if token not in text]
    for token in missing:
        add_failure(failures, "prd_step5_contract_missing", token, STEP5_PRD)
    return {"missing": missing}


def main() -> int:
    failures: list[dict] = []
    checks = {
        "deleted_paths": check_deleted_paths(failures),
        "project": check_project(failures),
        "app_tokens": check_app_tokens(failures),
        "app_model_boundary": check_app_model_boundary(failures),
        "helper_product_absent": check_helper_product_absent(failures),
        "verifiers_current_sources": check_verifiers_current_sources(failures),
        "prd_flow": check_prd_flow(failures),
    }
    payload = {
        "ok": not failures,
        "gate": "P12",
        "checks": checks,
        "failures": failures,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
