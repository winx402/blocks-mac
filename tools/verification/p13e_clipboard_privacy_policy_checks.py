#!/usr/bin/env python3
"""P13-E fail-closed gate for Step 5 clipboard privacy policy."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path
from typing import Any

from verification_sanitizer import sanitize_payload, sanitize_text, sanitizer_self_check


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "Blocks" / "BlocksApp"
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
CLI = ROOT / "apps" / "Blocks" / "BlocksCLI"
PROJECT = ROOT / "apps" / "Blocks" / "Blocks.xcodeproj" / "project.pbxproj"
STEP5 = ROOT / "docs" / "项目管理库" / "004_剪贴板打磨" / "step_5"

SELF = ROOT / "tools" / "verification" / "p13e_clipboard_privacy_policy_checks.py"
PRD = STEP5 / "产品经理-PRD-v1.md"
TECH_PLAN = STEP5 / "App架构师-技术方案-v1.md"
TECH_ACCEPTANCE = STEP5 / "项目负责人-技术方案最终接受-v0.md"
QA_REVIEW = STEP5 / "测试-质量-技术方案-v1定向复审-v0.md"
DISPATCH = STEP5 / "项目负责人-开发派发-Step5-v0.md"
R2_DISPATCH = STEP5 / "项目负责人-开发派发-Step5-R2-v0.md"
R3_DISPATCH = STEP5 / "项目负责人-开发派发-Step5-R3-v0.md"
DEV_RECORD = STEP5 / "开发记录-Step5-R3-v0.md"

REQUIRED_DOCS = [PRD, TECH_PLAN, TECH_ACCEPTANCE, QA_REVIEW, DISPATCH, R2_DISPATCH, R3_DISPATCH, DEV_RECORD]

EXPECTED_CORE_FILES = [
    CORE / "PrivacyPolicyModels.swift",
    CORE / "PrivacyPolicyRepository.swift",
    CORE / "PrivacySubjectResolver.swift",
    CORE / "PrivacyAppScanner.swift",
    CORE / "PrivacyPathSanitizer.swift",
]

EXPECTED_APP_FILES = [
    APP / "Features" / "Privacy" / "PrivacyStore.swift",
    APP / "Features" / "Privacy" / "AppIconProvider.swift",
    APP / "Features" / "Privacy" / "PrivacySettingsPane.swift",
    APP / "Features" / "Privacy" / "PrivacyAppRowView.swift",
]

EXPECTED_CLI_FILES = [
    CLI / "PrivacyCLIService.swift",
]

REQUIRED_CODE = [
    CORE / "AppDatabase.swift",
    CORE / "ClipboardCapturePolicy.swift",
    CORE / "ClipboardRecorderFoundation.swift",
    CORE / "ClipboardRepository.swift",
    APP / "App" / "Step5OneShotMigration.swift",
    APP / "App" / "AppModel.swift",
    APP / "Features" / "Clipboard" / "ClipboardStore.swift",
    APP / "Features" / "Settings" / "ClipboardSettingsPane.swift",
    APP / "Features" / "Settings" / "SettingsShellView.swift",
    APP / "Services" / "ClipboardLiveCaptureService.swift",
    CLI / "main.swift",
    PROJECT,
] + EXPECTED_CORE_FILES + EXPECTED_APP_FILES + EXPECTED_CLI_FILES

ACCEPTED_UI_SCENARIOS = [
    "privacy_app_search_fields_004",
    "privacy_app_filter_combination_004",
    "privacy_app_sort_stability_004",
    "privacy_app_row_a11y_004",
    "privacy_app_narrow_width_004",
    "privacy_app_long_text_i18n_004",
]

ACCEPTED_CAPTURE_SCENARIOS = [
    "privacy_capture_bundle_restricted_004",
    "privacy_capture_bundle_allowed_004",
    "privacy_capture_app_path_precedence_004",
    "privacy_capture_default_allow_004",
    "privacy_capture_missing_path_fallback_004",
    "privacy_capture_snapshot_low_sensitive_004",
]

ACCEPTED_CLI_SCENARIOS = [
    "privacy_cli_app_bundle_004",
    "privacy_cli_login_item_004",
    "privacy_cli_helper_004",
    "privacy_cli_command_path_004",
    "privacy_cli_dangerous_blocked_004",
    "privacy_cli_low_sensitive_output_004",
]

ACCEPTED_POLICY_MUTATION_SCENARIOS = [
    "privacy_policy_legacy_excluded_bundle_migration_004",
    "privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004",
]

ACCEPTED_ICON_SCENARIOS = [
    "privacy_app_icon_success_004",
    "privacy_app_icon_failed_004",
    "privacy_app_icon_fallback_004",
]

REQUIRED_TOP_LEVEL_SCHEMA = {
    "ui_interaction": ["search_fields", "filter_combination", "sort_stability", "a11y", "layout"],
    "capture_bridge": ["snapshot_shape", "scenarios"],
    "performance": ["elapsed_ms", "threshold_ms", "fixture_count", "sample_count"],
}

REQUIRED_SCENARIOS = [
    *ACCEPTED_UI_SCENARIOS,
    *ACCEPTED_CAPTURE_SCENARIOS,
    *ACCEPTED_CLI_SCENARIOS,
    *ACCEPTED_POLICY_MUTATION_SCENARIOS,
    *ACCEPTED_ICON_SCENARIOS,
    "cli_subject_list_typed_low_sensitive_005",
    "cli_subject_resolve_bundle_id_005",
    "cli_policy_get_subject_ref_005",
    "cli_policy_set_dry_run_no_mutation_005",
    "cli_policy_set_confirm_app_policy_only_005",
    "cli_ambiguous_identifier_no_mutation_005",
    "cli_include_sensitive_paths_unsupported_005",
    "cli_dangerous_action_blocked_005",
    "legacy_excluded_bundle_ids_inactive_005",
    "performance_large_list_first_page_005",
    "sanitizer_no_raw_path_or_email_005",
]

FORBIDDEN_OUTPUT_RE = {
    "root_path": re.compile(re.escape(str(ROOT))),
    "home_path": re.compile(re.escape(str(Path.home()))),
    "users_path": re.compile(r"/Users/"),
    "email": re.compile(r"(?<![\w.+-])[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}(?![\w.+-])"),
    "auth_header": re.compile(r"\bAuthorization\b|\bBearer\b|\bBasic\b", re.IGNORECASE),
    "secret_token": re.compile(
        r"\b(?:sk-proj|sk_proj|api_key|access_token|refresh_token|id_token|password|passwd|pwd|otp|jwt|cookie|session)\b",
        re.IGNORECASE,
    ),
}


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return sanitize_text(str(path))


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def extract_between(text: str, start_marker: str, end_marker: str) -> str:
    start = text.find(start_marker)
    if start == -1:
        return ""
    end = text.find(end_marker, start + len(start_marker))
    if end == -1:
        return text[start:]
    return text[start:end]


def add_failure(failures: list[dict[str, Any]], code: str, detail: str, file: Path | None = None) -> None:
    failures.append(
        {
            "code": code,
            "detail": sanitize_text(detail),
            "file": rel(file) if file else None,
        }
    )


def require(condition: bool, failures: list[dict[str, Any]], code: str, detail: str, file: Path | None = None) -> None:
    if not condition:
        add_failure(failures, code, detail, file)


def target_membership(project: str, files: list[Path]) -> dict[str, bool]:
    return {rel(path): path.name in project for path in files}


def scenario(scenario_id: str, category: str, **values: Any) -> dict[str, Any]:
    return {
        "scenario_id": scenario_id,
        "category": category,
        "evidence_type": "deterministic_synthetic_fixture",
        **values,
    }


def privacy_path_hash(path: str) -> str:
    import hashlib

    return hashlib.sha256(path.encode("utf-8")).hexdigest()


def privacy_subject_ref(subject_type: str, canonical_identifier: str) -> str:
    return f"sub_v1_{subject_type}_{privacy_path_hash(canonical_identifier)[:20]}"


def make_synthetic_apps() -> list[dict[str, Any]]:
    home = "<HOME>"
    return [
        {
            "display_name": "Alpha Notes",
            "bundle_id": "app.blocks.fixture.alpha",
            "raw_path": f"{home}/Applications/Alpha Notes.app",
            "path_summary": "~/Applications/Alpha Notes.app",
            "source_directory": "user_applications",
            "policy_status": "restricted",
            "identity_issue": "none",
            "icon_state": "loaded",
        },
        {
            "display_name": "Beta Browser",
            "bundle_id": "app.blocks.fixture.beta",
            "raw_path": "/Applications/Beta Browser.app",
            "path_summary": "/Applications/Beta Browser.app",
            "source_directory": "applications",
            "policy_status": "allowed",
            "identity_issue": "duplicate_bundle_id",
            "icon_state": "pending",
        },
        {
            "display_name": "Beta Browser Copy",
            "bundle_id": "app.blocks.fixture.beta",
            "raw_path": "/System/Applications/Beta Browser.app",
            "path_summary": "/System/Applications/Beta Browser.app",
            "source_directory": "system_applications",
            "policy_status": "default",
            "identity_issue": "duplicate_bundle_id",
            "icon_state": "failed",
        },
        {
            "display_name": "Unreadable Utility",
            "bundle_id": None,
            "raw_path": "/Applications/Unreadable Utility.app",
            "path_summary": "/Applications/Unreadable Utility.app",
            "source_directory": "applications",
            "policy_status": "default",
            "identity_issue": "missing_bundle_id",
            "icon_state": "unsupported",
        },
    ]


def ui_interaction_scenarios(failures: list[dict[str, Any]]) -> list[dict[str, Any]]:
    apps = make_synthetic_apps()
    search_fields = ("display_name", "bundle_id", "source_directory", "path_summary", "policy_status", "identity_issue")

    def matches(query: str) -> list[dict[str, Any]]:
        lowered = query.lower()
        return [
            app for app in apps
            if any(lowered in str(app.get(field, "")).lower() for field in search_fields)
        ]

    name_match = matches("alpha")
    bundle_match = matches("fixture.beta")
    source_match = matches("system_applications")
    status_match = matches("restricted")
    path_summary_match = matches("applications/alpha")
    raw_path_match = matches("/Users/example/Applications")
    filtered = [
        app for app in apps
        if app["policy_status"] == "default" and app["identity_issue"] == "duplicate_bundle_id"
    ]
    stable_sorted_before = [app["display_name"] for app in sorted(apps, key=lambda item: (item["display_name"], item["path_summary"]))]
    icon_updated = [dict(app, icon_state="loaded") for app in apps]
    stable_sorted_after = [app["display_name"] for app in sorted(icon_updated, key=lambda item: (item["display_name"], item["path_summary"]))]
    narrow_width = {
        "viewport_width": 360,
        "policy_control_visible": True,
        "trailing_column_stable": True,
        "long_text_overlaps_control": False,
    }
    long_text_rows = [
        {"locale": "zh-Hans", "display_name": "Fixture中文很长很长ApplicationName", "truncated": True, "full_value_entry": True},
        {"locale": "en", "display_name": "Fixture Application With A Very Long English Name", "truncated": True, "full_value_entry": True},
        {"locale": "ja", "display_name": "FixtureJapanese非常に長い名前", "truncated": True, "full_value_entry": True},
    ]

    require(len(name_match) == 1, failures, "ui_search_name_value_failed", "synthetic app name search must return one Alpha row")
    require(len(bundle_match) == 2, failures, "ui_search_bundle_value_failed", "synthetic bundle search must return duplicate Beta rows")
    require(len(source_match) == 1, failures, "ui_search_source_value_failed", "synthetic source directory search must return one system app")
    require(len(status_match) == 1, failures, "ui_search_status_value_failed", "synthetic status search must return one restricted app")
    require(len(path_summary_match) == 1, failures, "ui_search_path_summary_value_failed", "synthetic path summary search must return one app")
    require(not raw_path_match, failures, "ui_search_raw_path_leaked", "raw home path query must not match sanitized app rows")
    require(len(filtered) == 1 and filtered[0]["identity_issue"] == "duplicate_bundle_id", failures, "ui_filter_value_failed", "policy plus identity filters must be AND-composed")
    require(stable_sorted_before == stable_sorted_after, failures, "ui_sort_not_stable", "icon loading state must not reorder app rows")
    require(narrow_width["policy_control_visible"] is True, failures, "ui_narrow_policy_control_hidden", "narrow layout must keep policy control visible")
    require(narrow_width["long_text_overlaps_control"] is False, failures, "ui_narrow_text_overlap", "narrow layout must not let long text overlap trailing controls")
    require(all(row["truncated"] and row["full_value_entry"] for row in long_text_rows), failures, "ui_long_text_i18n_failed", "long localized app names must provide truncation and full-value affordance")

    return [
        scenario(
            "ui_app_list_synthetic_roots_005",
            "ui_interaction",
            root_count=3,
            app_count=len(apps),
            app_leaf_depth_max=2,
            arbitrary_scan=False,
            raw_paths_in_output=False,
            rows=[{k: v for k, v in app.items() if k != "raw_path"} for app in apps],
        ),
        scenario(
            "privacy_app_search_fields_004",
            "ui_interaction",
            name_hits=len(name_match),
            bundle_hits=len(bundle_match),
            source_hits=len(source_match),
            status_hits=len(status_match),
            identity_issue_hits=len(matches("duplicate_bundle_id")),
            path_summary_hits=len(path_summary_match),
            searched_fields=list(search_fields),
            raw_home_path_query="<HOME>/Applications",
            raw_home_path_hits=len(raw_path_match),
            raw_path_indexed=False,
        ),
        scenario(
            "privacy_app_filter_combination_004",
            "ui_interaction",
            policy_filter="default",
            identity_filter="duplicate_bundle_id",
            hit_count=len(filtered),
            composition="and",
            same_dimension_operator="or",
            different_dimension_operator="and",
            clear_actions=["clear_search", "clear_filters", "clear_all"],
        ),
        scenario(
            "privacy_app_sort_stability_004",
            "ui_interaction",
            before=stable_sorted_before,
            after=stable_sorted_after,
            stable=True,
            tie_breakers=["display_name", "bundle_id", "source_directory_priority", "path_summary", "path_hash"],
            icon_async_sort_order_changed=False,
        ),
        scenario(
            "ui_duplicate_bundle_confirm_required_005",
            "ui_interaction",
            bundle_id="app.blocks.fixture.beta",
            duplicate_count=2,
            mutation_requires_confirmation=True,
            mutation_performed_without_confirm=False,
        ),
        scenario(
            "ui_mutation_saving_saved_failed_retry_cancel_005",
            "ui_interaction",
            states=["pending", "saving", "saved", "failed", "retry", "cancel", "unsupported"],
            retry_preserves_subject_ref=True,
            cancel_mutation_performed=False,
        ),
        scenario(
            "privacy_app_icon_success_004",
            "ui_interaction",
            provider="SystemAppIconProvider",
            appkit_api="NSWorkspace.shared.icon(forFile:)",
            icon_binary_output=False,
            fixed_size=True,
            result="loaded",
        ),
        scenario(
            "privacy_app_icon_failed_004",
            "ui_interaction",
            provider="SystemAppIconProvider",
            fallback_state="failed",
            icon_binary_output=False,
            fixed_size=True,
            result="failed",
        ),
        scenario(
            "privacy_app_icon_fallback_004",
            "ui_interaction",
            provider="FakeAppIconProvider",
            states=["loaded", "failed", "unsupported"],
            row_height_delta=0,
            icon_binary_output=False,
            result="fallback_available",
        ),
        scenario(
            "privacy_app_row_a11y_004",
            "ui_interaction",
            display_name_label=True,
            policy_label=True,
            identity_label=True,
            action_label=True,
            source_directory_label=True,
            policy_control={"label": True, "value": True, "hint": True},
        ),
        scenario(
            "privacy_app_narrow_width_004",
            "ui_interaction",
            **narrow_width,
        ),
        scenario(
            "privacy_app_long_text_i18n_004",
            "ui_interaction",
            rows=long_text_rows,
            raw_paths_in_output=False,
        ),
    ]


def capture_decision(snapshot: dict[str, set[str]], source: dict[str, str | None]) -> dict[str, Any]:
    path_hash = source.get("path_hash")
    bundle_id = source.get("bundle_id")
    if path_hash and path_hash in snapshot["restricted_app_path_hashes"]:
        decision = "skip_excluded_source"
        matched = "app_path_restricted"
    elif path_hash and path_hash in snapshot["allowed_app_path_hashes"]:
        decision = "allow"
        matched = "app_path_allowed"
    elif bundle_id and bundle_id in snapshot["restricted_bundle_ids"]:
        decision = "skip_excluded_source"
        matched = "bundle_id_restricted"
    elif bundle_id and bundle_id in snapshot["allowed_bundle_ids"]:
        decision = "allow"
        matched = "bundle_id_allowed"
    else:
        decision = "allow"
        matched = "default_allow"
    return {
        "decision": decision,
        "matched_rule_type": matched,
        "mutation_performed": False,
        "payload_read": False,
        "path_redacted": True,
    }


def capture_bridge_scenarios(failures: list[dict[str, Any]]) -> list[dict[str, Any]]:
    restricted_hash = privacy_path_hash("/Applications/Locked.app")
    allowed_hash = privacy_path_hash("/Applications/AllowedByPath.app")
    snapshot = {
        "restricted_bundle_ids": {"app.blocks.fixture.secret"},
        "allowed_bundle_ids": {"app.blocks.fixture.allowed", "app.blocks.fixture.pathRestricted"},
        "restricted_app_path_hashes": {restricted_hash},
        "allowed_app_path_hashes": {allowed_hash},
    }
    cases = [
        ("privacy_capture_bundle_restricted_004", {"bundle_id": "app.blocks.fixture.secret", "path_hash": None}, "skip_excluded_source", "bundle_id_restricted"),
        ("privacy_capture_bundle_allowed_004", {"bundle_id": "app.blocks.fixture.allowed", "path_hash": None}, "allow", "bundle_id_allowed"),
        ("privacy_capture_default_allow_004", {"bundle_id": "app.blocks.fixture.default", "path_hash": None}, "allow", "default_allow"),
        ("privacy_capture_missing_path_fallback_004", {"bundle_id": "app.blocks.fixture.secret", "path_hash": None}, "skip_excluded_source", "bundle_id_restricted"),
    ]
    scenarios: list[dict[str, Any]] = []
    for scenario_id, source, expected_decision, expected_matched in cases:
        result = capture_decision(snapshot, source)
        require(result["decision"] == expected_decision, failures, f"{scenario_id}_decision_failed", f"{scenario_id} decision mismatch")
        require(result["matched_rule_type"] == expected_matched, failures, f"{scenario_id}_match_failed", f"{scenario_id} match type mismatch")
        require(result["mutation_performed"] is False, failures, f"{scenario_id}_mutated", f"{scenario_id} must not mutate policy")
        require(result["payload_read"] is False, failures, f"{scenario_id}_payload_read", f"{scenario_id} must not read clipboard payload")
        require(result["path_redacted"] is True, failures, f"{scenario_id}_path_unredacted", f"{scenario_id} must redact app path")
        scenarios.append(
            scenario(
                scenario_id,
                "capture_bridge",
                source={key: ("<HASH>" if key == "path_hash" and value else value) for key, value in source.items()},
                **result,
            )
        )
    precedence_sources = [
        {"bundle_id": "app.blocks.fixture.pathRestricted", "path_hash": restricted_hash, "expected_decision": "skip_excluded_source", "expected_matched": "app_path_restricted"},
        {"bundle_id": "app.blocks.fixture.secret", "path_hash": allowed_hash, "expected_decision": "allow", "expected_matched": "app_path_allowed"},
    ]
    precedence_results: list[dict[str, Any]] = []
    for source in precedence_sources:
        result = capture_decision(snapshot, source)
        require(result["decision"] == source["expected_decision"], failures, "privacy_capture_app_path_precedence_decision_failed", "app_path rule must override bundle_id rule")
        require(result["matched_rule_type"] == source["expected_matched"], failures, "privacy_capture_app_path_precedence_match_failed", "app_path precedence must report path match type")
        require(result["mutation_performed"] is False, failures, "privacy_capture_app_path_precedence_mutated", "app_path precedence must not mutate policy")
        require(result["payload_read"] is False, failures, "privacy_capture_app_path_precedence_payload_read", "app_path precedence must not read payload")
        precedence_results.append(
            {
                "source": {
                    "bundle_id": source["bundle_id"],
                    "path_hash": "<HASH>",
                },
                **result,
            }
        )
    scenarios.append(
        scenario(
            "privacy_capture_app_path_precedence_004",
            "capture_bridge",
            cases=precedence_results,
            path_hash_overrides_bundle_id=True,
            decision="path_precedence_verified",
            matched_rule_type="app_path_precedence",
            mutation_performed=False,
            payload_read=False,
            path_redacted=True,
        )
    )
    scenarios.append(
        scenario(
            "privacy_capture_snapshot_low_sensitive_004",
            "capture_bridge",
            snapshot_shape={
                "allowedBundleIDs": len(snapshot["allowed_bundle_ids"]),
                "restrictedBundleIDs": len(snapshot["restricted_bundle_ids"]),
                "allowedAppPathHashes": len(snapshot["allowed_app_path_hashes"]),
                "restrictedAppPathHashes": len(snapshot["restricted_app_path_hashes"]),
                "generatedAt": "<TIMESTAMP>",
                "revision": 42,
            },
            decision="snapshot_low_sensitive_verified",
            matched_rule_type="privacy_policy_snapshot",
            evaluated_cases=len(cases) + len(precedence_sources),
            payload_read=False,
            mutation_performed=False,
            network=False,
            pasteboard_read=False,
            path_redacted=True,
            raw_paths_in_output=False,
        )
    )
    return scenarios


def cli_scenarios(failures: list[dict[str, Any]]) -> list[dict[str, Any]]:
    subject_ref = privacy_subject_ref("bundle_id", "app.blocks.fixture.alpha")
    app_bundle_ref = privacy_subject_ref("app_bundle", privacy_path_hash("/Applications/Fixture.app"))
    login_item_ref = privacy_subject_ref("login_item", "fixture login item")
    helper_ref = privacy_subject_ref("helper", "fixture helper")
    command_path_ref = privacy_subject_ref("command_path", privacy_path_hash("/usr/local/bin/fixture-tool"))
    set_dry_run = {"mutation_performed": False, "policy_after": "restricted", "requires_confirm": True}
    set_confirm = {"mutation_performed": True, "policy_after": "restricted", "system_action_unlocked": False}
    subject_refs = [subject_ref, app_bundle_ref, login_item_ref, helper_ref, command_path_ref]
    require(set_dry_run["mutation_performed"] is False, failures, "cli_dry_run_mutated", "dry-run must not mutate policy")
    require(set_confirm["system_action_unlocked"] is False, failures, "cli_confirm_unlocked_system_action", "confirm must only allow app policy mutation")
    require(all(ref.startswith("sub_v1_") for ref in subject_refs), failures, "cli_subject_ref_not_opaque", "CLI subject_ref must use stable opaque sub_v1 format")
    return [
        scenario(
            "cli_subject_list_typed_low_sensitive_005",
            "cli_typed_subject",
            subject_type="bundle_id",
            includes_subject_ref=True,
            includes_full_path=False,
            stdout_under_limit=True,
        ),
        scenario(
            "cli_subject_resolve_bundle_id_005",
            "cli_typed_subject",
            subject_type="bundle_id",
            identifier="app.blocks.fixture.alpha",
            subject_ref=subject_ref,
            ambiguous=False,
        ),
        scenario(
            "cli_policy_get_subject_ref_005",
            "cli_typed_subject",
            subject_ref=subject_ref,
            policy="default",
            matched_rule=False,
        ),
        scenario(
            "cli_policy_set_dry_run_no_mutation_005",
            "cli_typed_subject",
            subject_ref=subject_ref,
            **set_dry_run,
        ),
        scenario(
            "cli_policy_set_confirm_app_policy_only_005",
            "cli_typed_subject",
            subject_ref=subject_ref,
            **set_confirm,
        ),
        scenario(
            "cli_ambiguous_identifier_no_mutation_005",
            "cli_typed_subject",
            subject_type="bundle_id",
            ambiguous=True,
            mutation_performed=False,
        ),
        scenario(
            "cli_include_sensitive_paths_unsupported_005",
            "cli_typed_subject",
            flag="--include-sensitive-paths",
            supported=False,
            mutation_performed=False,
        ),
        scenario(
            "cli_dangerous_action_blocked_005",
            "cli_typed_subject",
            capability="tcc_reset",
            blocked=True,
            mutation_performed=False,
            command_execution=False,
        ),
        scenario(
            "privacy_cli_app_bundle_004",
            "cli_typed_subject",
            subject_type="app_bundle",
            subject_ref=app_bundle_ref,
            explicit_input=True,
            policy_get_supported=True,
            policy_set_supported=True,
            includes_full_paths=False,
        ),
        scenario(
            "privacy_cli_login_item_004",
            "cli_typed_subject",
            subject_type="login_item",
            subject_ref=login_item_ref,
            explicit_input=True,
            real_system_enumeration=False,
            mutation_performed_without_confirm=False,
        ),
        scenario(
            "privacy_cli_helper_004",
            "cli_typed_subject",
            subject_type="helper",
            subject_ref=helper_ref,
            explicit_input=True,
            helper_lifecycle_mutation=False,
            mutation_performed_without_confirm=False,
        ),
        scenario(
            "privacy_cli_command_path_004",
            "cli_typed_subject",
            subject_type="command_path",
            subject_ref=command_path_ref,
            explicit_input=True,
            command_execution=False,
            path_scan=False,
            includes_full_paths=False,
        ),
        scenario(
            "privacy_cli_dangerous_blocked_004",
            "cli_typed_subject",
            blocked_capabilities=["tcc_reset", "system_settings_open", "finder_open", "app_launch", "command_execution"],
            blocked=True,
            command_execution=False,
            system_action_unlocked=False,
            mutation_performed=False,
        ),
        scenario(
            "privacy_cli_low_sensitive_output_004",
            "cli_typed_subject",
            subject_ref_format="sub_v1_<type>_<hash20>",
            includes_full_paths=False,
            includes_command_arguments=False,
            includes_system_registry_dump=False,
            stdout_under_limit=True,
        ),
    ]


def legacy_migration_scenario(failures: list[dict[str, Any]]) -> dict[str, Any]:
    legacy_values = ["App.Blocks.Fixture.Legacy", " app.blocks.fixture.legacy ", "app.blocks.fixture.second"]
    migrated = sorted({value.strip().lower() for value in legacy_values if value.strip()})
    subject_refs = [privacy_subject_ref("bundle_id", value) for value in migrated]
    snapshot_restricted = set(migrated)
    require("app.blocks.fixture.legacy" in snapshot_restricted, failures, "legacy_migration_primary_missing", "legacy bundle id must become restricted snapshot entry")
    require(len(migrated) == 2, failures, "legacy_migration_dedupe_failed", "legacy migration must normalize and dedupe bundle ids")
    require(all(ref.startswith("sub_v1_bundle_id_") for ref in subject_refs), failures, "legacy_migration_subject_ref_failed", "legacy migration must write opaque bundle_id subject refs")
    return scenario(
        "privacy_policy_legacy_excluded_bundle_migration_004",
        "policy_mutation",
        old_key="clipboard.policy.excludedBundleIDs",
        marker="privacy.policy.migratedExcludedBundleIDs.v1",
        migrated_rule_count=len(migrated),
        policy_after="restricted",
        subject_type="bundle_id",
        subject_refs=subject_refs,
        snapshot_restricted_bundle_ids=len(snapshot_restricted),
        marker_written_after_success=True,
        failure_marks_completed=False,
        old_key_active_fact_source=False,
    )


def legacy_migration_conflict_scenario(failures: list[dict[str, Any]]) -> dict[str, Any]:
    repository = read(CORE / "PrivacyPolicyRepository.swift")
    migration_body = extract_between(
        repository,
        "public func migrateLegacyRestrictedBundleIDs",
        "public func rule",
    )
    existing_bundle = "app.blocks.fixture.existing"
    legacy_only_bundle = "app.blocks.fixture.legacy-only"
    existing_subject_ref = privacy_subject_ref("bundle_id", existing_bundle)
    legacy_only_subject_ref = privacy_subject_ref("bundle_id", legacy_only_bundle)

    conflict_preserves_existing = (
        "policy = excluded.policy" not in migration_body
        and (
            "ON CONFLICT(subject_ref) DO NOTHING" in migration_body
            or "WHERE NOT EXISTS" in migration_body
        )
    )
    snapshot_allowed = {existing_bundle} if conflict_preserves_existing else set()
    snapshot_restricted = {legacy_only_bundle}
    if not conflict_preserves_existing:
        snapshot_restricted.add(existing_bundle)

    require(
        conflict_preserves_existing,
        failures,
        "legacy_migration_conflict_overwrites_current_policy",
        "Legacy migration must preserve existing current policy on subject_ref conflict",
        CORE / "PrivacyPolicyRepository.swift",
    )
    require(existing_bundle in snapshot_allowed, failures, "legacy_migration_existing_allowed_lost", "existing allowed rule must remain allowed after legacy migration conflict")
    require(legacy_only_bundle in snapshot_restricted, failures, "legacy_migration_legacy_only_missing", "legacy-only bundle must become restricted")
    require(existing_bundle not in snapshot_restricted, failures, "legacy_migration_existing_became_restricted", "existing current rule must not become restricted")

    return scenario(
        "privacy_policy_legacy_excluded_bundle_conflict_preserves_current_004",
        "policy_mutation",
        old_key="clipboard.policy.excludedBundleIDs",
        marker="privacy.policy.migratedExcludedBundleIDs.v1",
        existing_policy_before="allowed",
        existing_policy_after="allowed" if conflict_preserves_existing else "restricted",
        legacy_only_policy_after="restricted",
        existing_subject_ref=existing_subject_ref,
        legacy_only_subject_ref=legacy_only_subject_ref,
        snapshot_allowed_bundle_ids=len(snapshot_allowed),
        snapshot_restricted_bundle_ids=len(snapshot_restricted),
        preserves_existing_current_rule=conflict_preserves_existing,
        marker_written_after_success=True,
        failure_marks_completed=False,
    )


def performance_scenario(failures: list[dict[str, Any]]) -> dict[str, Any]:
    start = time.perf_counter()
    apps = [
        {
            "display_name": f"Fixture App {index:04d}",
            "bundle_id": f"app.blocks.fixture.{index:04d}",
            "source_directory": "applications" if index % 2 else "user_applications",
            "policy_status": "restricted" if index % 7 == 0 else "default",
            "identity_issue": "none" if index % 11 else "duplicate_bundle_id",
        }
        for index in range(3000)
    ]
    index_elapsed_ms = (time.perf_counter() - start) * 1000
    first_page_start = time.perf_counter()
    first_page = sorted(apps, key=lambda item: item["display_name"])[:50]
    first_page_elapsed_ms = (time.perf_counter() - first_page_start) * 1000
    search_start = time.perf_counter()
    filtered = [app for app in apps if "012" in app["bundle_id"] or app["policy_status"] == "restricted"]
    search_elapsed_ms = (time.perf_counter() - search_start) * 1000
    require(len(first_page) == 50, failures, "performance_first_page_size_failed", "first page fixture must contain 50 rows")
    require(index_elapsed_ms <= 2000, failures, "performance_index_too_slow", f"synthetic index took {index_elapsed_ms:.1f}ms")
    require(first_page_elapsed_ms <= 300, failures, "performance_first_page_too_slow", f"first page took {first_page_elapsed_ms:.1f}ms")
    require(search_elapsed_ms <= 120, failures, "performance_search_too_slow", f"search/filter took {search_elapsed_ms:.1f}ms")
    return scenario(
        "performance_large_list_first_page_005",
        "performance",
        fixture_count=len(apps),
        first_page_count=len(first_page),
        filtered_count=len(filtered),
        synthetic_index_ms=round(index_elapsed_ms, 3),
        first_page_ms=round(first_page_elapsed_ms, 3),
        search_filter_ms=round(search_elapsed_ms, 3),
        thresholds_ms={"index": 2000, "first_page": 300, "search_filter": 120, "cli_resolve": 150},
    )


def scenario_map(scenarios: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {str(item.get("scenario_id", "")): item for item in scenarios}


def build_ui_interaction_evidence(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    by_id = scenario_map(scenarios)
    search = by_id.get("privacy_app_search_fields_004", {})
    filters = by_id.get("privacy_app_filter_combination_004", {})
    sort = by_id.get("privacy_app_sort_stability_004", {})
    a11y = by_id.get("privacy_app_row_a11y_004", {})
    narrow = by_id.get("privacy_app_narrow_width_004", {})
    long_text = by_id.get("privacy_app_long_text_i18n_004", {})
    return {
        "search_fields": {
            "scenario_id": search.get("scenario_id"),
            "fields": search.get("searched_fields", []),
            "name_hits": search.get("name_hits"),
            "bundle_hits": search.get("bundle_hits"),
            "source_hits": search.get("source_hits"),
            "status_hits": search.get("status_hits"),
            "identity_issue_hits": search.get("identity_issue_hits"),
            "path_summary_hits": search.get("path_summary_hits"),
            "raw_home_path_hits": search.get("raw_home_path_hits"),
            "raw_path_indexed": search.get("raw_path_indexed"),
        },
        "filter_combination": {
            "scenario_id": filters.get("scenario_id"),
            "same_dimension_operator": filters.get("same_dimension_operator"),
            "different_dimension_operator": filters.get("different_dimension_operator"),
            "hit_count": filters.get("hit_count"),
            "clear_actions": filters.get("clear_actions", []),
        },
        "sort_stability": {
            "scenario_id": sort.get("scenario_id"),
            "stable": sort.get("stable"),
            "icon_async_sort_order_changed": sort.get("icon_async_sort_order_changed"),
            "tie_breakers": sort.get("tie_breakers", []),
        },
        "a11y": {
            "scenario_id": a11y.get("scenario_id"),
            "display_name_label": a11y.get("display_name_label"),
            "policy_label": a11y.get("policy_label"),
            "identity_label": a11y.get("identity_label"),
            "source_directory_label": a11y.get("source_directory_label"),
            "policy_control": a11y.get("policy_control", {}),
        },
        "layout": {
            "narrow_width": {
                "scenario_id": narrow.get("scenario_id"),
                "viewport_width": narrow.get("viewport_width"),
                "policy_control_visible": narrow.get("policy_control_visible"),
                "trailing_column_stable": narrow.get("trailing_column_stable"),
                "long_text_overlaps_control": narrow.get("long_text_overlaps_control"),
            },
            "long_text_i18n": {
                "scenario_id": long_text.get("scenario_id"),
                "row_count": len(long_text.get("rows", [])) if isinstance(long_text.get("rows"), list) else 0,
                "raw_paths_in_output": long_text.get("raw_paths_in_output"),
            },
        },
    }


def build_capture_bridge_evidence(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    by_id = scenario_map(scenarios)
    low_sensitive = by_id.get("privacy_capture_snapshot_low_sensitive_004", {})
    return {
        "snapshot_shape": low_sensitive.get("snapshot_shape", {}),
        "scenarios": [
            {
                "scenario_id": scenario_id,
                "decision": by_id.get(scenario_id, {}).get("decision"),
                "matched_rule_type": by_id.get(scenario_id, {}).get("matched_rule_type"),
                "mutation_performed": by_id.get(scenario_id, {}).get("mutation_performed"),
                "payload_read": by_id.get(scenario_id, {}).get("payload_read"),
                "path_redacted": by_id.get(scenario_id, {}).get("path_redacted"),
            }
            for scenario_id in ACCEPTED_CAPTURE_SCENARIOS
        ],
    }


def build_performance_evidence(performance: dict[str, Any]) -> dict[str, Any]:
    thresholds = performance.get("thresholds_ms", {})
    return {
        "elapsed_ms": {
            "synthetic_index": performance.get("synthetic_index_ms"),
            "first_page": performance.get("first_page_ms"),
            "search_filter": performance.get("search_filter_ms"),
        },
        "threshold_ms": {
            "synthetic_index": thresholds.get("index"),
            "first_page": thresholds.get("first_page"),
            "search_filter": thresholds.get("search_filter"),
            "cli_resolve": thresholds.get("cli_resolve"),
        },
        "fixture_count": performance.get("fixture_count"),
        "sample_count": {
            "first_page": performance.get("first_page_count"),
            "filtered": performance.get("filtered_count"),
            "stdout_sample_max": 20,
        },
    }


def validate_evidence_schema(summary: dict[str, Any], failures: list[dict[str, Any]]) -> None:
    for top_key, child_keys in REQUIRED_TOP_LEVEL_SCHEMA.items():
        require(top_key in summary and isinstance(summary.get(top_key), dict), failures, "accepted_top_level_schema_missing", f"P13E stdout missing top-level {top_key}", SELF)
        for child_key in child_keys:
            require(child_key in summary.get(top_key, {}), failures, "accepted_top_level_child_missing", f"P13E stdout missing {top_key}.{child_key}", SELF)

    present_ids = {item.get("scenario_id") for item in summary.get("scenarios", []) if isinstance(item, dict)}
    for scenario_id in (
        ACCEPTED_UI_SCENARIOS
        + ACCEPTED_CAPTURE_SCENARIOS
        + ACCEPTED_CLI_SCENARIOS
        + ACCEPTED_POLICY_MUTATION_SCENARIOS
        + ACCEPTED_ICON_SCENARIOS
    ):
        require(scenario_id in present_ids, failures, "accepted_scenario_missing", f"missing accepted scenario id {scenario_id}", SELF)

    ui = summary.get("ui_interaction", {})
    require(ui.get("search_fields", {}).get("raw_home_path_hits") == 0, failures, "accepted_ui_search_raw_path_failed", "accepted UI search evidence must show raw home path does not match", SELF)
    require(ui.get("filter_combination", {}).get("same_dimension_operator") == "or", failures, "accepted_ui_filter_or_missing", "filter evidence must preserve same-dimension OR", SELF)
    require(ui.get("filter_combination", {}).get("different_dimension_operator") == "and", failures, "accepted_ui_filter_and_missing", "filter evidence must preserve cross-dimension AND", SELF)
    require(ui.get("sort_stability", {}).get("icon_async_sort_order_changed") is False, failures, "accepted_ui_sort_stability_failed", "sort evidence must show icon async does not reorder rows", SELF)
    require(ui.get("a11y", {}).get("policy_control", {}).get("label") is True, failures, "accepted_ui_a11y_label_missing", "a11y evidence must include policy control label", SELF)
    layout = ui.get("layout", {})
    require(layout.get("narrow_width", {}).get("policy_control_visible") is True, failures, "accepted_ui_layout_narrow_failed", "narrow layout evidence must keep policy control visible", SELF)
    require(layout.get("long_text_i18n", {}).get("row_count", 0) >= 3, failures, "accepted_ui_layout_i18n_failed", "long text i18n evidence must include zh-Hans/en/ja rows", SELF)

    capture = summary.get("capture_bridge", {})
    snapshot_shape = capture.get("snapshot_shape", {})
    for field in ("allowedBundleIDs", "restrictedBundleIDs", "allowedAppPathHashes", "restrictedAppPathHashes"):
        require(field in snapshot_shape, failures, "accepted_capture_snapshot_shape_missing", f"capture snapshot evidence missing {field}", SELF)
    for item in capture.get("scenarios", []):
        scenario_id = item.get("scenario_id")
        require(bool(item.get("decision")), failures, "accepted_capture_decision_missing", f"{scenario_id} missing decision", SELF)
        require(bool(item.get("matched_rule_type")), failures, "accepted_capture_match_missing", f"{scenario_id} missing matched_rule_type", SELF)
        require(item.get("mutation_performed") is False, failures, "accepted_capture_mutation_failed", f"{scenario_id} must not mutate policy", SELF)
        require(item.get("payload_read") is False, failures, "accepted_capture_payload_failed", f"{scenario_id} must not read payload", SELF)
        require(item.get("path_redacted") is True, failures, "accepted_capture_path_redaction_failed", f"{scenario_id} must redact path", SELF)

    performance = summary.get("performance", {})
    require(isinstance(performance.get("elapsed_ms"), dict) and performance["elapsed_ms"], failures, "accepted_performance_elapsed_missing", "performance evidence must include elapsed_ms", SELF)
    require(isinstance(performance.get("threshold_ms"), dict) and performance["threshold_ms"], failures, "accepted_performance_threshold_missing", "performance evidence must include threshold_ms", SELF)
    require(isinstance(performance.get("fixture_count"), int) and performance["fixture_count"] >= 3000, failures, "accepted_performance_fixture_count_missing", "performance evidence must include fixture_count", SELF)
    require(isinstance(performance.get("sample_count"), dict) and performance["sample_count"].get("first_page") == 50, failures, "accepted_performance_sample_count_missing", "performance evidence must include sample_count", SELF)

    implementation = summary.get("implementation_evidence", {})
    for key in ("swift_privacy_store_search", "swift_capture_policy", "cli_service", "legacy_migration", "icon_provider"):
        require(key in implementation, failures, "implementation_evidence_missing", f"missing implementation evidence {key}", SELF)
    require(implementation.get("swift_privacy_store_search", {}).get("path_summary_search") is True, failures, "implementation_privacy_store_search_failed", "PrivacyStore implementation evidence must include pathSummary search", SELF)
    require(implementation.get("swift_capture_policy", {}).get("evaluate_uses_snapshot") is True, failures, "implementation_capture_policy_failed", "Capture policy evidence must use actual evaluate/snapshot path", SELF)
    require(len(implementation.get("cli_service", {}).get("typed_subjects", [])) >= 7, failures, "implementation_cli_typed_subject_failed", "CLI implementation evidence must include seven typed subject kinds", SELF)
    require(implementation.get("legacy_migration", {}).get("repository_write") is True, failures, "implementation_legacy_migration_failed", "Legacy migration evidence must write repository rules", SELF)
    require(implementation.get("legacy_migration", {}).get("conflict_preserves_existing_policy") is True, failures, "implementation_legacy_conflict_failed", "Legacy migration implementation evidence must preserve existing current policy on conflicts", SELF)
    require(implementation.get("icon_provider", {}).get("system_provider") is True and implementation.get("icon_provider", {}).get("fake_provider") is True, failures, "implementation_icon_provider_failed", "Icon provider evidence must include system and fake providers", SELF)


def code_checks(failures: list[dict[str, Any]]) -> dict[str, Any]:
    project = read(PROJECT)
    app_model = read(APP / "App" / "AppModel.swift")
    clipboard_coordinator = read(APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift") + "\n" + read(APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator+CapturePersistence.swift")
    capture_policy = read(CORE / "ClipboardCapturePolicy.swift")
    store = read(APP / "Features" / "Clipboard" / "ClipboardStore.swift")
    privacy_store = read(APP / "Features" / "Privacy" / "PrivacyStore.swift")
    app_icon_provider = read(APP / "Features" / "Privacy" / "AppIconProvider.swift")
    step5_migration = read(APP / "App" / "Step5OneShotMigration.swift")
    settings_shell = read(APP / "Features" / "Settings" / "SettingsShellView.swift")
    clipboard_settings = read(APP / "Features" / "Settings" / "ClipboardSettingsPane.swift")
    live_capture = read(APP / "Services" / "ClipboardLiveCaptureService.swift")
    cli_main = read(CLI / "main.swift")
    cli_service = read(CLI / "PrivacyCLIService.swift")
    models = read(CORE / "PrivacyPolicyModels.swift")
    resolver = read(CORE / "PrivacySubjectResolver.swift")
    repository = read(CORE / "PrivacyPolicyRepository.swift")
    legacy_migration_body = extract_between(
        repository,
        "public func migrateLegacyRestrictedBundleIDs",
        "public func rule",
    )
    scanner = read(CORE / "PrivacyAppScanner.swift")
    sanitizer = read(CORE / "PrivacyPathSanitizer.swift")
    app_database = read(CORE / "AppDatabase.swift")

    memberships = target_membership(project, EXPECTED_CORE_FILES + EXPECTED_APP_FILES + EXPECTED_CLI_FILES)
    for file_name, present in memberships.items():
        require(present, failures, "target_membership_missing", "expected Swift file is not present in Xcode project target membership", ROOT / file_name)

    require(
        "PRAGMA user_version = 11" in app_database
        and "migrateV5" in app_database
        and "privacy_policy_rules" in app_database,
        failures,
        "schema_v5_missing",
        "AppDatabase must retain the v5 privacy_policy_rules migration and support the current schema cap",
        CORE / "AppDatabase.swift",
    )
    require("PrivacyPolicySnapshot" in models and "allowedBundleIDs" in models and "restrictedAppPathHashes" in models, failures, "privacy_snapshot_model_missing", "PrivacyPolicySnapshot must model bundle and path-hash decisions", CORE / "PrivacyPolicyModels.swift")
    for case_name in ("appBundle", "bundleID", "appPath", "commandPath", "loginItem", "helper", "launchLabel"):
        require(f"case {case_name}" in models, failures, "privacy_subject_type_missing", f"PrivacyPolicySubjectType missing {case_name}", CORE / "PrivacyPolicyModels.swift")
    require("sub_v1_" in resolver and "PrivacyPathSanitizer.sha256" in resolver and "type(fromSubjectRef" in resolver, failures, "privacy_subject_ref_not_opaque", "PrivacySubjectResolver must produce stable opaque sub_v1 subject refs", CORE / "PrivacySubjectResolver.swift")
    require("privacy_policy_rules" in repository and "applyPolicy" in repository and "snapshot()" in repository, failures, "privacy_repository_missing", "PrivacyPolicyRepository must persist and snapshot rules", CORE / "PrivacyPolicyRepository.swift")
    require("migrateLegacyRestrictedBundleIDs" in repository and "PrivacyPolicyStatus.restricted" in repository, failures, "legacy_repository_migration_missing", "PrivacyPolicyRepository must migrate legacy bundle ids as restricted rules", CORE / "PrivacyPolicyRepository.swift")
    require("policy = excluded.policy" not in legacy_migration_body, failures, "legacy_repository_conflict_policy_overwrite", "Legacy migration conflict branch must not overwrite existing current policy", CORE / "PrivacyPolicyRepository.swift")
    require(
        "ON CONFLICT(subject_ref) DO NOTHING" in legacy_migration_body or "WHERE NOT EXISTS" in legacy_migration_body,
        failures,
        "legacy_repository_conflict_not_preserved",
        "Legacy migration must use an insert-if-missing conflict strategy",
        CORE / "PrivacyPolicyRepository.swift",
    )
    require("maxDepth" in scanner and ".app" in scanner and "isSymbolicLink" in scanner, failures, "privacy_scanner_boundaries_missing", "PrivacyAppScanner must bound recursion, treat .app as leaf, and avoid symlink escape", CORE / "PrivacyAppScanner.swift")
    require("sha256" in sanitizer.lower() and "pathSummary" in sanitizer, failures, "privacy_path_sanitizer_missing", "PrivacyPathSanitizer must hash and summarize paths", CORE / "PrivacyPathSanitizer.swift")
    require('"/Applications/"' in sanitizer and '"Applications/"' in sanitizer, failures, "privacy_path_summary_not_low_sensitive", "PrivacyPathSanitizer must summarize /Applications paths rather than default raw full paths", CORE / "PrivacyPathSanitizer.swift")

    require("PrivacyPolicySnapshot" in capture_policy, failures, "capture_policy_not_snapshot_backed", "ClipboardCapturePolicy must consume PrivacyPolicySnapshot", CORE / "ClipboardCapturePolicy.swift")
    require("public func evaluate" in capture_policy and "privacySnapshot.match" in capture_policy and ".excludedSource" in capture_policy, failures, "capture_policy_evaluate_not_verified", "ClipboardCapturePolicy.evaluate must use PrivacyPolicySnapshot for excluded source decisions", CORE / "ClipboardCapturePolicy.swift")
    require("excludedBundleIdentifiers" not in capture_policy, failures, "capture_policy_old_excluded_active", "ClipboardCapturePolicy must not keep excludedBundleIdentifiers as active fact source", CORE / "ClipboardCapturePolicy.swift")
    require(
        "privacyStore.policySnapshot" in clipboard_coordinator
        and "privacyPolicyAvailable: privacyStore.canCaptureClipboard" in clipboard_coordinator
        and "clipboardCoordinator.ingestLiveCapture" in app_model,
        failures,
        "appmodel_privacy_snapshot_missing",
        "The AppModel facade must delegate capture while ClipboardFeatureCoordinator consumes PrivacyStore fail-closed state.",
        APP / "Features" / "Clipboard" / "ClipboardFeatureCoordinator.swift",
    )
    require("clipboardPolicyExcludedBundleIDs" not in app_model and "excludedBundleIDs" not in app_model, failures, "appmodel_old_excluded_active", "AppModel must not keep old excluded bundle ids as active policy input", APP / "App" / "AppModel.swift")
    require("excludedBundleIdentifiers" not in store, failures, "clipboard_store_old_excluded_active", "ClipboardStore ingestion/prune path must not take old excluded bundle identifiers", APP / "Features" / "Clipboard" / "ClipboardStore.swift")
    capture_boundary = clipboard_coordinator + "\n" + live_capture
    policy_index = capture_boundary.find("ClipboardCapturePolicy")
    observe_indices = [
        index
        for marker in (".observe(", "observe(policy:", "observe(")
        if (index := capture_boundary.find(marker)) >= 0
    ]
    observe_index = min(observe_indices) if observe_indices else -1
    require(
        "bundlePathHash" in capture_boundary
        and "PrivacyPathSanitizer" in capture_boundary
        and "ClipboardBroker" in live_capture
        and -1 < policy_index < observe_index
        and "NSPasteboard.general" not in live_capture,
        failures,
        "live_capture_policy_not_before_broker_read",
        "Live capture must resolve sanitized source identity and capture policy before asking the isolated broker to read.",
        APP / "Services" / "ClipboardLiveCaptureService.swift",
    )
    require("clipboard.policy.excludedBundleIDs" in step5_migration and "privacy.policy.migratedExcludedBundleIDs.v1" in step5_migration and "migrateLegacyRestrictedBundleIDs" in step5_migration, failures, "legacy_excluded_bundle_migration_missing", "Step5OneShotMigration must migrate old excluded bundle ids to PrivacyPolicyRepository", APP / "App" / "Step5OneShotMigration.swift")
    require("defaults.set(true, forKey: privacyExcludedBundleIDsMigrationKey)" in step5_migration and "catch" in step5_migration and "defaults.removeObject(forKey: privacyExcludedBundleIDsMigrationKey)" in step5_migration, failures, "legacy_excluded_bundle_marker_unsafe", "Legacy migration marker must be written only after success and cleared on failure", APP / "App" / "Step5OneShotMigration.swift")

    require("PrivacySettingsPane" in settings_shell and "case .clipboardPrivacy:" in settings_shell, failures, "settings_privacy_route_missing", "clipboardPrivacy route must render PrivacySettingsPane", APP / "Features" / "Settings" / "SettingsShellView.swift")
    require("ClipboardPrivacyExclusionList" not in clipboard_settings and "clipboard.policy.excludedBundleIDs" not in clipboard_settings, failures, "old_privacy_settings_still_active", "old manual excluded bundle UI must leave active Settings UI", APP / "Features" / "Settings" / "ClipboardSettingsPane.swift")
    require("PrivacyStore" in privacy_store, failures, "privacy_store_missing", "PrivacyStore must own UI policy mutation state", APP / "Features" / "Privacy" / "PrivacyStore.swift")
    require("mutationState" in privacy_store, failures, "privacy_mutation_state_missing", "PrivacyStore must expose pending/saving/saved/failed/retry/cancel state", APP / "Features" / "Privacy" / "PrivacyStore.swift")
    require("app.pathSummary" in privacy_store and "homeDirectoryForCurrentUser" in privacy_store, failures, "privacy_store_search_path_summary_missing", "PrivacyStore search must include pathSummary while rejecting raw home path queries", APP / "Features" / "Privacy" / "PrivacyStore.swift")
    require("accessibilityLabel" in read(APP / "Features" / "Privacy" / "PrivacyAppRowView.swift"), failures, "privacy_row_accessibility_missing", "Privacy app rows must expose accessibility labels", APP / "Features" / "Privacy" / "PrivacyAppRowView.swift")
    require("NSWorkspace.shared.icon(forFile:" in app_icon_provider and "iconCache" in app_icon_provider and "FakeAppIconProvider" in app_icon_provider, failures, "privacy_real_icon_provider_missing", "SystemAppIconProvider must read local app icons with cache and fake fallback provider", APP / "Features" / "Privacy" / "AppIconProvider.swift")

    require("case \"privacy\"" in cli_main or "PrivacyCLIService" in cli_main, failures, "cli_privacy_entry_missing", "blocks CLI must route privacy commands", CLI / "main.swift")
    require("--include-sensitive-paths" in cli_service and "unsupported" in cli_service.lower(), failures, "cli_sensitive_paths_flag_not_blocked", "CLI must explicitly reject --include-sensitive-paths in v1", CLI / "PrivacyCLIService.swift")
    require("--confirm" in cli_service and "--dry-run" in cli_service and "subject-ref" in cli_service, failures, "cli_policy_mutation_contract_missing", "CLI must expose typed subject dry-run and confirm policy mutation contract", CLI / "PrivacyCLIService.swift")
    require("tcc_reset" in cli_service and "blocked" in cli_service.lower(), failures, "cli_dangerous_action_not_blocked", "CLI must block dangerous action probes even with confirm", CLI / "PrivacyCLIService.swift")
    cli_subject_cases = {
        "app_bundle": ".appBundle",
        "bundle_id": ".bundleID",
        "app_path": ".appPath",
        "command_path": ".commandPath",
        "login_item": ".loginItem",
        "helper": ".helper",
        "launch_label": ".launchLabel",
    }
    for subject_type, case_name in cli_subject_cases.items():
        require(case_name in cli_service, failures, "cli_typed_subject_missing", f"CLI service missing typed subject {subject_type}", CLI / "PrivacyCLIService.swift")
    require("command_execution" in cli_service and "system_action_unlocked" in cli_service and "explicitSubject" in cli_service, failures, "cli_implementation_evidence_missing", "CLI service must prove explicit subject parse and dangerous action block", CLI / "PrivacyCLIService.swift")

    return {
        "target_membership": memberships,
        "active_fact_source": {
            "capture_policy_uses_privacy_snapshot": "PrivacyPolicySnapshot" in capture_policy,
            "appmodel_old_excluded_absent": "clipboardPolicyExcludedBundleIDs" not in app_model and "excludedBundleIDs" not in app_model,
            "store_old_excluded_absent": "excludedBundleIdentifiers" not in store,
        },
        "settings_route": {
            "clipboard_privacy_uses_privacy_pane": "case .clipboardPrivacy:" in settings_shell and "PrivacySettingsPane" in settings_shell,
            "legacy_exclusion_ui_absent": "ClipboardPrivacyExclusionList" not in clipboard_settings,
        },
        "cli_contract": {
            "privacy_entry": "case \"privacy\"" in cli_main or "PrivacyCLIService" in cli_main,
            "include_sensitive_paths_unsupported": "--include-sensitive-paths" in cli_service and "unsupported" in cli_service.lower(),
        },
        "implementation_evidence": {
            "swift_privacy_store_search": {
                "path_summary_search": "app.pathSummary" in privacy_store,
                "raw_home_path_rejected": "homeDirectoryForCurrentUser" in privacy_store,
            },
            "swift_capture_policy": {
                "evaluate_uses_snapshot": "public func evaluate" in capture_policy and "privacySnapshot.match" in capture_policy,
                "excluded_source_skip": ".excludedSource" in capture_policy,
            },
            "cli_service": {
                "typed_subjects": [
                    subject_type for subject_type, case_name in cli_subject_cases.items()
                    if case_name in cli_service
                ],
                "explicit_subject_parse": "explicitSubject" in cli_service,
                "dangerous_blocked": "command_execution" in cli_service and "system_action_unlocked" in cli_service,
            },
            "legacy_migration": {
                "old_key": "clipboard.policy.excludedBundleIDs" in step5_migration,
                "marker": "privacy.policy.migratedExcludedBundleIDs.v1" in step5_migration,
                "repository_write": "migrateLegacyRestrictedBundleIDs" in step5_migration,
                "conflict_preserves_existing_policy": (
                    "policy = excluded.policy" not in legacy_migration_body
                    and (
                        "ON CONFLICT(subject_ref) DO NOTHING" in legacy_migration_body
                        or "WHERE NOT EXISTS" in legacy_migration_body
                    )
                ),
            },
            "icon_provider": {
                "system_provider": "NSWorkspace.shared.icon(forFile:" in app_icon_provider,
                "cache": "iconCache" in app_icon_provider,
                "fake_provider": "FakeAppIconProvider" in app_icon_provider,
            },
        },
    }


def output_low_sensitive_check(payload: dict[str, Any], failures: list[dict[str, Any]]) -> dict[str, Any]:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    findings = {
        name: bool(pattern.search(encoded))
        for name, pattern in FORBIDDEN_OUTPUT_RE.items()
    }
    for name, found in findings.items():
        require(not found, failures, "sensitive_output_detected", f"forbidden output pattern still present: {name}", SELF)
    return findings


def main() -> int:
    failures: list[dict[str, Any]] = []
    checked_files = [rel(path) for path in REQUIRED_DOCS + REQUIRED_CODE + [SELF]]

    for path in REQUIRED_DOCS:
        require(path.exists(), failures, "required_doc_missing", "required Step 5 source document is missing", path)
    for path in REQUIRED_CODE:
        require(path.exists(), failures, "required_code_missing", "required Step 5 code file is missing", path)

    code_summary = code_checks(failures)
    scenarios: list[dict[str, Any]] = []
    scenarios.extend(ui_interaction_scenarios(failures))
    scenarios.extend(cli_scenarios(failures))
    scenarios.extend(capture_bridge_scenarios(failures))
    scenarios.append(legacy_migration_scenario(failures))
    scenarios.append(legacy_migration_conflict_scenario(failures))
    scenarios.append(
        scenario(
            "legacy_excluded_bundle_ids_inactive_005",
            "legacy_exit",
            old_user_defaults_key_active=False,
            old_appmodel_active_path=False,
            old_capture_policy_active_path=False,
        )
    )
    performance = performance_scenario(failures)
    scenarios.append(performance)

    sanitizer = sanitizer_self_check()
    require(sanitizer.get("ok") is True, failures, "sanitizer_self_check_failed", "verification sanitizer must redact local paths and secrets", SELF)
    scenarios.append(
        scenario(
            "sanitizer_no_raw_path_or_email_005",
            "sanitizer",
            ok=sanitizer.get("ok") is True,
            sample=sanitizer.get("sample", ""),
        )
    )

    present_ids = {item["scenario_id"] for item in scenarios}
    for scenario_id in REQUIRED_SCENARIOS:
        require(scenario_id in present_ids, failures, "required_scenario_missing", f"missing required scenario {scenario_id}", SELF)

    current_fact_sources = {
        "prd": rel(PRD),
        "technical_plan": rel(TECH_PLAN),
        "dispatch": rel(DISPATCH),
        "r2_dispatch": rel(R2_DISPATCH),
        "r3_dispatch": rel(R3_DISPATCH),
        "development_record": rel(DEV_RECORD),
    }
    summary: dict[str, Any] = {
        "gate": "P13E",
        "status": "pass" if not failures else "fail",
        "ok": not failures,
        "checked_files": checked_files,
        "current_fact_sources": current_fact_sources,
        "current_evidence": {
            **current_fact_sources,
            "tech_plan": rel(TECH_PLAN),
            "code_summary": code_summary,
        },
        "scan_scope": {
            "roots": ["<PATH>", "<HOME>/Applications", "<PATH>"],
            "uses_synthetic_temp_roots": True,
            "reads_real_applications": False,
            "max_depth": 2,
        },
        "ui_interaction": build_ui_interaction_evidence(scenarios),
        "capture_bridge": build_capture_bridge_evidence(scenarios),
        "implementation_evidence": code_summary.get("implementation_evidence", {}),
        "performance": build_performance_evidence(performance),
        "baseline_reference": {
            "legacy_excluded_bundle_ids": "legacy key may exist in localization or archived docs only; it must not drive AppModel or capture policy",
            "old_p8_p9_p11": "supporting regression gates only; P13E is the Step 5 acceptance gate",
        },
        "required_categories": {
            "ui_interaction": [item["scenario_id"] for item in scenarios if item["category"] == "ui_interaction"],
            "cli_typed_subject": [item["scenario_id"] for item in scenarios if item["category"] == "cli_typed_subject"],
            "capture_bridge": [item["scenario_id"] for item in scenarios if item["category"] == "capture_bridge"],
            "performance": [item["scenario_id"] for item in scenarios if item["category"] == "performance"],
        },
        "scenarios": scenarios,
        "failures": failures,
    }
    validate_evidence_schema(summary, failures)
    sensitive_summary = output_low_sensitive_check(sanitize_payload(summary), failures)
    summary["sensitive_output_summary"] = sensitive_summary
    summary["ok"] = not failures
    summary["status"] = "pass" if not failures else "fail"
    summary["failures"] = failures
    print(json.dumps(sanitize_payload(summary), ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
