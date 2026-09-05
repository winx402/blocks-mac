#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path

from p8m_clipboard_modularization_checks import declaration_block, swift_without_comments
from p9b_clipboard_appstate_repository_integration_checks import body_of


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, code: str, detail: str, failures: list[dict[str, str]]) -> None:
    if not condition:
        failures.append({"code": code, "detail": detail})


def current_owner_contracts(database: str, history: str, scheduler: str, policy: str, store: str, repository: str, search_repository: str) -> dict[str, bool]:
    migration = body_of(database, "func migrate()")
    ceiling = re.findall(r"currentVersion\s*>\s*(\d+)", migration)
    written_versions = [int(v) for v in re.findall(r"PRAGMA user_version\s*=\s*(\d+)", swift_without_comments(database))]
    search = body_of(history, "private static func searchRepository(")
    cursor = body_of(repository, "private func querySearchRecords(")
    fts_search = body_of(repository, "public func search(")
    fallback = body_of(repository, "private func fallbackSearch(")
    documents = body_of(search_repository, "func searchDocuments(")
    schedule = body_of(scheduler, "func schedule(")
    confirm = body_of(policy, "func confirmCleanupPolicy(")
    committed = declaration_block(confirm, "if case let .committed(visibleRecordCount) = result")
    failed = declaration_block(confirm, "else if case .failed = result")
    store_confirm = body_of(store, "func confirmPolicyApplication(")
    failure_arm = store_confirm.split("case .clear, .failure:", 1)[-1] if "case .clear, .failure:" in store_confirm else ""
    compact = lambda value: re.sub(r"\s+", "", value)
    return {
        "schema_ceiling_matches_latest_migration_and_runs_v8": (
            len(ceiling) == 1 and bool(written_versions)
            and int(ceiling[0]) == max(written_versions) >= 9
            and re.search(r"if\s+currentVersion\s*<\s*8\s*\{[^{}]*\btry\s+migrateV8\(\)", migration) is not None
        ),
        "filtered_search_limits_matching_results": (
            "repository.searchDocuments(" in search
            and "limit: visibleLimit" in search
            and "filteringBatch: { candidates in" in search
            and "ClipboardSearchCoordinator.applyFilters(" in search
            and "maximumCandidateCount" not in search
            and "search(trimmed, limit: limit, filteringBatch: filteringBatch)" in documents
            and all("filteringBatch == nil ? max(1, limit) : -1" in body for body in [fts_search, fallback])
            and "catch let error as ClipboardSearchBatchFilterError" in fts_search
            and "while records.count < safeLimit" in cursor
            and "while batch.count < 256, try statement.step()" in cursor
            and "matching = try filteringBatch(batch)" in cursor
            and "matching.prefix(safeLimit - records.count)" in cursor
            and "if batch.count < 256 { break }" in cursor
        ),
        "ocr_scheduler_single_flight_drain": (
            0 <= schedule.find("guard processingTask == nil") < schedule.find("processingTask = Task")
            and "while !Task.isCancelled" in schedule
            and "await queue.processPending(" in schedule
            and "if self.drainRequested { continue }" in schedule
            and "self.processingTask = nil" in schedule
            and "self.schedule(context: self.pendingContext, quietDelay: 0)" in schedule
        ),
        "confirmed_policy_preserves_failure": (
            "clipboardStore.confirmPolicyApplication(token: token)" in confirm
            and "self.recordStatus(.ready," in compact(committed)
            and "self.recordStatus(.failed," in compact(failed)
            and "completion(result)" in confirm
            and "completion(.failed)" in failure_arm
            and "completion(.committed" not in failure_arm
            and "pending == token" in store_confirm
        ),
    }


def main() -> int:
    failures: list[dict[str, str]] = []
    capture_policy = source("apps/Blocks/BlocksCore/ClipboardCapturePolicy.swift")
    app_database = source("apps/Blocks/BlocksCore/AppDatabase.swift")
    repository = source("apps/Blocks/BlocksCore/ClipboardRepository.swift")
    search_repository = source("apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift")
    store = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift")
    controller = source("apps/Blocks/BlocksApp/Stores/ClipboardController.swift")
    search = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardSearchCoordinator.swift")
    filters = source("apps/Blocks/BlocksApp/Support/ClipboardFilters.swift")
    settings = source("apps/Blocks/BlocksApp/Features/Settings/ClipboardSettingsPane.swift")
    coordinator = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator.swift") + "\n" + source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator+CapturePersistence.swift")
    ocr_queue = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardVisionOCRQueue.swift")
    sqlite_connection = source("apps/Blocks/BlocksCore/SQLiteConnection.swift")
    privacy_repository = source("apps/Blocks/BlocksCore/PrivacyPolicyRepository.swift")
    search_builder = source("apps/Blocks/BlocksCore/ClipboardSearchDocumentBuilder.swift")
    migration = source("apps/Blocks/BlocksApp/App/Step5OneShotMigration.swift")
    blob_store = source("apps/Blocks/BlocksCore/BlobStore.swift")
    recorder_localization = source("apps/Blocks/BlocksApp/Support/ClipboardRecorder+Localization.swift")
    floating_detail_card = source("apps/Blocks/BlocksApp/Features/Clipboard/Detail/ClipboardFloatingDetailCard.swift")
    detail_sources = sorted((ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/Detail").glob("*.swift"))
    detail_sources.append(ROOT / "apps/Blocks/BlocksApp/Features/Clipboard/ClipboardDetailStore.swift")
    detail_editor = "\n".join(path.read_text(encoding="utf-8") for path in detail_sources)
    localizable = source("apps/Blocks/BlocksApp/Resources/Localizable.xcstrings")
    history_pipeline = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardHistoryReadPipeline.swift")
    scheduler = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardOCRScheduler.swift")
    policy_coordinator = source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator+Policy.swift")
    owner_contracts = current_owner_contracts(app_database, history_pipeline, scheduler, policy_coordinator, store, repository, search_repository)

    ingest_start = store.index("func ingestLiveCapture(")
    ingest_end = store.index("func toggleFavorite", ingest_start)
    ingest = store[ingest_start:ingest_end]
    require(
        "capturePolicy.evaluate" in ingest
        and ingest.index("capturePolicy.evaluate") < ingest.index("guard let repository"),
        "capture_policy_not_evaluated_before_repository",
        "ClipboardStore must evaluate capture policy before choosing repository or memory persistence.",
        failures,
    )
    require(
        "ClipboardCapturePolicyDecision" in controller and "snapshot.payload" not in controller,
        "memory_fallback_consumes_raw_snapshot",
        "In-memory fallback must consume a pre-evaluated policy decision, never a raw snapshot.",
        failures,
    )
    require(
        "existingRecord.excluded" in controller
        and "payloads[payload.recordID] = payload" in controller,
        "memory_cannot_upgrade_skipped_duplicate",
        "In-memory capture must upgrade an existing skipped placeholder when the same record later becomes allowed.",
        failures,
    )
    require(
        "sanitizedSkippedSignature" in capture_policy
        and "types: []" in capture_policy,
        "skipped_record_retains_payload_fingerprint",
        "Skipped records must not retain payload-derived signatures or pasteboard type metadata.",
        failures,
    )
    require(
        "case privacyPolicyUnavailable" in capture_policy
        and "privacyPolicyAvailable" in capture_policy
        and "summaryCode" in capture_policy
        and "Clipboard capture skipped: recorder paused." not in capture_policy
        and "paused: clipboardStore.recorderPaused" in coordinator
        and "privacyPolicyAvailable: privacyStore.canCaptureClipboard" in coordinator
        and "localizedPreviewBody" in recorder_localization
        and all(key in localizable for key in [
            "clipboard.preview.capturePaused",
            "clipboard.preview.excludedSource",
            "clipboard.preview.unsupportedContent",
            "clipboard.preview.privacyPolicyUnavailable",
        ]),
        "fail_closed_capture_reason_is_ambiguous_or_unlocalized",
        "Fail-closed placeholders must distinguish policy unavailability from user pause and localize stable reason codes.",
        failures,
    )
    require(
        "ClipboardCaptureSkipReason(summaryCode: record.summary)" in floating_detail_card
        and "skipReason.localizedPreviewBody" in floating_detail_card
        and "record.kind.localizedTitle" in floating_detail_card,
        "fail_closed_detail_discards_specific_reason",
        "Skipped-record detail must preserve the localized capture reason and avoid exposing the raw unknown kind title.",
        failures,
    )
    legacy_skip_summaries = [
        "Clipboard capture skipped: recorder paused.",
        "Clipboard capture skipped: excluded source.",
        "Clipboard capture skipped: unsupported content.",
    ]
    require(
        owner_contracts["schema_ceiling_matches_latest_migration_and_runs_v8"]
        and "migrateV8" in app_database
        and all(summary in app_database for summary in legacy_skip_summaries)
        and all(summary not in repository + store + floating_detail_card + detail_editor for summary in legacy_skip_summaries)
        and "let reason = ClipboardCaptureSkipReason.excludedSource" in repository
        and "reason.summaryCode" in repository,
        "legacy_skipped_records_lack_one_shot_migration",
        "Current schema must migrate legacy skipped summaries and active runtime paths must only emit stable reason codes.",
        failures,
    )
    evaluate = capture_policy[capture_policy.index("public func evaluate"):capture_policy.index("public static let defaultSupportedKinds")]
    require(
        evaluate.index("if paused") < evaluate.index("if record.snapshotSkipped")
        and evaluate.index("privacySnapshot.match") < evaluate.index("if record.snapshotSkipped")
        and "return skippedDecision(record: record, reason: .unsupportedContent)" in evaluate,
        "pre_skipped_records_bypass_current_privacy_policy",
        "Pre-skipped records must still honor current pause/privacy state and be redacted through the normal skipped decision.",
        failures,
    )
    require(
        "upgradeSkippedPlaceholder" in repository
        and "placeholder.snapshotSkipped" in repository
        and "inserted: true" in repository,
        "repository_cannot_upgrade_skipped_duplicate",
        "A later allowed capture must upgrade a skipped placeholder instead of remaining non-restorable.",
        failures,
    )
    require(
        owner_contracts["filtered_search_limits_matching_results"],
        "search_filters_after_limit_without_overfetch",
        "Search must filter bounded candidate batches before limiting matching results, without a global candidate cutoff.",
        failures,
    )
    require(
        "filterState.time.matches(record.lastCopiedAt" in search,
        "time_filter_uses_created_at",
        "Time filters must use the same last-copied timestamp shown and used for ordering.",
        failures,
    )
    require(
        "recoverInterruptedOCR" in search_repository
        and "rebuildPendingSearchDocuments" in search_repository
        and "preservingOCRFrom" in search_repository
        and "scheduleIndexMaintenance" in store
        and "while rebuiltCount == indexBatchSize" in store,
        "search_index_has_no_production_recovery",
        "Production startup must recover interrupted OCR and rebuild pending search documents without discarding OCR state.",
        failures,
    )
    require(
        "actor ClipboardVisionOCRQueue" in ocr_queue
        and "@MainActor\nfinal class ClipboardVisionOCRQueue" not in ocr_queue,
        "ocr_queue_runs_repository_work_on_main_actor",
        "OCR repository reads and payload decoding must be isolated from the UI main actor.",
        failures,
    )
    require(
        owner_contracts["ocr_scheduler_single_flight_drain"],
        "ocr_queue_has_no_single_flight_drain",
        "Pending OCR must drain in a single-flight task instead of processing only one startup batch.",
        failures,
    )
    require(
        "ClipboardSourceFilterKey" in filters and "sourceFilterKey" in filters,
        "source_filter_nil_collides_with_all",
        "Source filtering must distinguish all from sources without bundle identifiers.",
        failures,
    )
    require(
        ".tag(3650)" not in settings and "ClipboardRetentionPolicy" in settings,
        "forever_is_ten_years",
        "Forever retention must use an explicit no-age-limit policy, not 3650 days.",
        failures,
    )
    require(
        owner_contracts["confirmed_policy_preserves_failure"],
        "policy_failure_reported_as_success",
        "Policy application must return a typed failure and never unconditionally publish success.",
        failures,
    )
    require(
        "NSRecursiveLock" in sqlite_connection
        and "transactionDepth" in sqlite_connection
        and "lock.withLock" in sqlite_connection,
        "sqlite_connection_transactions_can_interleave",
        "The shared SQLite connection must serialize statements and support nested transactions.",
        failures,
    )
    require(
        "case malformedRule" in privacy_repository
        and "throw PrivacyPolicyRepositoryError.malformedRule" in privacy_repository
        and "continue" not in privacy_repository[privacy_repository.index("public func loadRules"):privacy_repository.index("@discardableResult", privacy_repository.index("public func loadRules"))],
        "malformed_privacy_rows_fail_open",
        "Malformed privacy policy rows must make snapshot loading fail closed instead of being skipped.",
        failures,
    )
    require(
        "clipboard.policy.retentionDays" in migration
        and "clipboard.policy.retention" in migration
        and "3650" in migration
        and "removeObject(forKey: oldClipboardRetentionDaysKey)" in migration,
        "legacy_retention_policy_not_migrated",
        "The former numeric retention setting must be migrated once to the typed policy and then removed.",
        failures,
    )
    upsert_start = search_repository.index("func upsertSearchDocument")
    upsert_end = search_repository.index("func ", upsert_start + 5)
    upsert = search_repository[upsert_start:upsert_end]
    require(
        "database.connection.transaction" in upsert
        and "UPDATE clipboard_items" in upsert
        and "replaceFTS" in upsert,
        "search_document_projection_is_not_atomic",
        "Search document, compatibility projection, and FTS projection must update in one transaction.",
        failures,
    )
    require(
        "record.lastCopiedAt" in search_builder
        and '"v2:' in search_builder
        and 'terms.append("today")' not in search_builder
        and 'terms.append("yesterday")' not in search_builder
        and "expandedRelativeDateQuery" in repository,
        "relative_time_search_tokens_go_stale",
        "Search indexing must use last-copied stable dates and expand relative date terms at query time.",
        failures,
    )
    require(
        "cleanupOrphans" in blob_store
        and "cleanupUnreferencedSidecars" in repository
        and "try? blobStore.delete" in repository,
        "sidecar_lifecycle_can_leave_orphans_or_fail_committed_delete",
        "Sidecar writes/deletes must be rollback tolerant and have repository orphan cleanup.",
        failures,
    )

    report = {
        "gate": "P006E",
        "ok": not failures,
        "failures": failures,
        "verification_scope": "source_contracts_only",
        "current_owner_contracts": owner_contracts,
        "limits": {
            "search_runtime_and_concurrency_require_separate_tests": True,
            "ocr_shutdown_restart_overlap": "not_verified; current production shutdown call is Store deinit",
        },
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


def run() -> int:
    try:
        return main()
    except (OSError, ValueError) as error:
        print(json.dumps({"gate": "P006E", "ok": False, "failures": [{"code": "source_inspection_error", "detail": str(error)}]}, ensure_ascii=False, indent=2))
        return 1


if __name__ == "__main__":
    raise SystemExit(run())
