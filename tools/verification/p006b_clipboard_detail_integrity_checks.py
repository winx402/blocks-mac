#!/usr/bin/env python3
"""P006-B executable gate for clipboard detail edit integrity."""

from __future__ import annotations

import json
import subprocess
import tempfile
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps" / "Blocks" / "BlocksCore"
DETAIL_STORE = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Clipboard" / "ClipboardDetailStore.swift"
FLOATING_CARD = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Clipboard" / "Detail" / "ClipboardFloatingDetailCard.swift"
HOVER_PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Features" / "Clipboard" / "Detail" / "ClipboardHoverDetailPanel.swift"
FLOATING_PANEL = ROOT / "apps" / "Blocks" / "BlocksApp" / "Views" / "ClipboardFloatingPanelView.swift"
PRESENTER = ROOT / "apps" / "Blocks" / "BlocksApp" / "Services" / "ClipboardHistoryPanelPresenter.swift"


FIXTURE = r'''
import CryptoKit
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

func signature(_ kind: ClipboardRecorderItemKind, _ text: String) -> String {
    SHA256.hash(data: Data("\(kind.rawValue):\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
}

func record(_ id: String, _ text: String, title: String? = nil) -> ClipboardRecorderRecord {
    let full = signature(.text, text)
    return ClipboardRecorderRecord(
        id: id,
        createdAt: Date(timeIntervalSince1970: 1_900_006_000),
        changeCount: 1,
        kind: .text,
        formatSummary: ClipboardRecorderFormatSummary(itemCount: 1, types: ["text"], textLength: text.count, byteCount: text.utf8.count),
        sourceApp: nil,
        signatureSHA256: full,
        signatureSHA256_12: String(full.prefix(12)),
        fixtureOwned: true,
        pinned: true,
        restorable: true,
        customTitle: title,
        lastCopiedAt: Date(timeIntervalSince1970: 1_900_006_123),
        summary: text
    )
}

func insert(_ repository: ClipboardRepository, _ item: ClipboardRecorderRecord, _ text: String) throws {
    _ = try repository.insert(record: item, payload: ClipboardRecorderPayload(recordID: item.id, kind: .text, text: text))
}

func save(_ repository: ClipboardRepository, _ recordID: String, _ text: String, customTitle: String? = nil) throws -> ClipboardDetailSaveResult {
    let revision = try repository.loadDetailReadModel(recordID: recordID).contentRevision
    return try repository.saveDetailEdit(command: ClipboardDetailEditCommand(
        recordID: recordID,
        expectedContentRevision: revision,
        editableKind: .plainText,
        draft: ClipboardDetailDraft(text: text),
        customTitle: customTitle,
        updatesPayload: true,
        updatesCustomTitle: customTitle != nil,
        purpose: "detailEditSave",
        now: Date(timeIntervalSince1970: 1_900_006_200)
    ))
}

func runScenario(_ id: String, _ body: () throws -> [String: Bool]) -> [String: Any] {
    do {
        let assertions = try body()
        return ["id": id, "result": assertions.values.allSatisfy { $0 } ? "pass" : "fail", "assertions": assertions]
    } catch {
        return ["id": id, "result": "fail", "assertions": ["fixture_completed": false]]
    }
}

@main
struct P006BFixture {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func repository(_ id: String) throws -> (ClipboardRepository, AppDatabase) {
            let root = base.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try AppDatabase.open(environment: StorageEnvironment(rootDirectory: root))
            return (ClipboardRepository(database: database), database)
        }

        var scenarios: [[String: Any]] = []
        scenarios.append(runScenario("signature_and_recapture_dedup") {
            let (repo, database) = try repository("signature_and_recapture_dedup")
            defer { database.close() }
            try insert(repo, record("edited", "old payload"), "old payload")
            _ = try save(repo, "edited", "new payload")
            let edited = try repo.loadRecord(recordID: "edited")!
            let old = try repo.insert(record: record("old-copy", "old payload"), payload: ClipboardRecorderPayload(recordID: "old-copy", kind: .text, text: "old payload"))
            let fresh = try repo.insert(record: record("new-copy", "new payload"), payload: ClipboardRecorderPayload(recordID: "new-copy", kind: .text, text: "new payload"))
            let expected = signature(.text, "new payload")
            return [
                "full_signature_recomputed": edited.signatureSHA256 == expected,
                "short_signature_recomputed": edited.signatureSHA256_12 == String(expected.prefix(12)),
                "old_copy_inserts": old.inserted && !old.duplicate,
                "new_copy_deduplicates_to_edited": fresh.duplicate && fresh.record.id == "edited"
            ]
        })
        scenarios.append(runScenario("signature_conflict_keeps_edited_identity") {
            let (repo, database) = try repository("signature_conflict_keeps_edited_identity")
            defer { database.close() }
            try insert(repo, record("edited", "before", title: "Edited title"), "before")
            try insert(repo, record("conflict", "shared after"), "shared after")
            let tags = ClipboardTagRepository(database: database)
            _ = try tags.toggleFavorite(recordID: "edited")
            _ = try tags.createTagAndAttach(displayName: "Keep", recordID: "edited")
            let beforeLastCopiedAt = try repo.loadRecord(recordID: "edited")!.lastCopiedAt
            _ = try save(repo, "edited", "shared after")
            let kept = try repo.loadRecord(recordID: "edited")
            let removed = try repo.loadRecord(recordID: "conflict")
            let keptTags = try tags.loadRecordTags(recordIDs: ["edited"])["edited"] ?? []
            return [
                "edited_id_retained": kept?.id == "edited",
                "conflict_record_removed": removed == nil,
                "edited_custom_title_retained": kept?.customTitle == "Edited title",
                "edited_tags_retained": keptTags.map(\.displayName).contains("Keep") && keptTags.contains(where: \.isFavorite),
                "edited_last_copied_retained": kept?.lastCopiedAt == beforeLastCopiedAt
            ]
        })
        scenarios.append(runScenario("title_and_body_rollback_together") {
            let (repo, database) = try repository("title_and_body_rollback_together")
            defer { database.close() }
            try insert(repo, record("atomic", "before", title: "Before title"), "before")
            let before = try repo.loadRecord(recordID: "atomic")!
            try database.connection.execute("CREATE TEMP TRIGGER p006b_fail_title BEFORE UPDATE ON clipboard_items WHEN NEW.custom_title IS NOT OLD.custom_title BEGIN SELECT RAISE(ABORT, 'title failed'); END;")
            var failed = false
            do {
                _ = try save(repo, "atomic", "after", customTitle: "After title")
            } catch {
                failed = true
            }
            let after = try repo.loadRecord(recordID: "atomic")!
            let payload = try repo.readPayload(recordID: "atomic")?.text
            return [
                "title_write_failed": failed,
                "body_rolled_back": payload == "before",
                "title_rolled_back": after.customTitle == "Before title",
                "signature_rolled_back": after.signatureSHA256 == before.signatureSHA256,
                "revision_rolled_back": try repo.loadDetailReadModel(recordID: "atomic").contentRevision == 1
            ]
        })
        scenarios.append(runScenario("skipped_placeholder_upgrades_in_place") {
            let (repo, database) = try repository("skipped_placeholder_upgrades_in_place")
            defer { database.close() }
            let pending = record("placeholder", "later allowed")
            let skipped = try repo.insert(
                record: pending,
                payload: ClipboardRecorderPayload(recordID: pending.id, kind: .text, text: "later allowed"),
                capturePolicy: ClipboardCapturePolicy(paused: true)
            )
            let upgraded = try repo.insert(
                record: pending,
                payload: ClipboardRecorderPayload(recordID: pending.id, kind: .text, text: "later allowed")
            )
            let stored = try repo.loadRecord(recordID: pending.id)
            let document = try repo.loadSearchDocument(recordID: pending.id)
            let count = try database.connection.firstInt("SELECT COUNT(*) FROM clipboard_items WHERE id = ?", bindings: [.string(pending.id)]) ?? 0
            return [
                "placeholder_was_skipped": skipped.skipped && !skipped.inserted,
                "allowed_result_is_not_duplicate": upgraded.inserted && !upgraded.duplicate && !upgraded.skipped,
                "record_id_preserved": stored?.id == pending.id && count == 1,
                "record_restored": stored?.restorable == true && stored?.snapshotSkipped == false && stored?.excluded == false,
                "payload_written": try repo.readPayload(recordID: pending.id)?.text == "later allowed",
                "search_document_replaced": document?.payloadDerivationState == .available && document?.contentText == "later allowed"
            ]
        })
        print(String(data: try JSONSerialization.data(withJSONObject: ["scenarios": scenarios], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True)


def static_assertions() -> dict[str, bool]:
    store = DETAIL_STORE.read_text(encoding="utf-8")
    card = FLOATING_CARD.read_text(encoding="utf-8")
    hover_panel = HOVER_PANEL.read_text(encoding="utf-8")
    panel = FLOATING_PANEL.read_text(encoding="utf-8")
    presenter = PRESENTER.read_text(encoding="utf-8")
    load_start = store.index("func load(recordID:")
    load_end = store.index("func beginEditing()", load_start)
    load_block = store[load_start:load_end]
    return {
        "inline_custom_title_entry": "TextField(L10n.string(\"clipboard.detail.title\")" in card,
        "title_uses_draft_binding": "detailStore.updateDraftTitle" in card,
        "fixed_body_height": "fixedDetailInputHeight: CGFloat = 168" in card,
        "fixed_ocr_height": "fixedDetailOCRInputHeight: CGFloat = 128" in card,
        "twelve_point_actions": "blocksFont(size: 12" in card and ".background" not in card[card.index("private var floatingDetailActionBar"):card.index("private var detailHeader")],
        "request_open_contract": "func requestOpen(recordID:" in store,
        "request_close_contract": "func requestClose()" in store,
        "request_panel_close_contract": "func requestPanelClose(after handler:" in store,
        "load_uses_dirty_contract": "requestOpen(recordID: recordID)" in load_block,
        "floating_dirty_confirmation_present": (
            ".confirmationDialog" in card
            and "detailStore.saveAndContinue()" in card
            and "detailStore.discardChangesAndContinue()" in card
            and "detailStore.continueEditing()" in card
        ),
        "floating_navigation_result_syncs_parent": (
            "onNavigationResolved" in card
            and "onNavigationResolved" in panel
            and "detailStore.continueEditing()" in card
            and "synchronizeResolvedNavigation()" in card[card.index("detailStore.continueEditing()"):]
        ),
        "hover_panel_preserves_active_identity_while_dirty": (
            "preserveDirtyDetailIdentity" in hover_panel
            and "detailStore.requestOpen(recordID: item.id)" in hover_panel
            and "activeRecordID != item.id" in hover_panel
            and "return" in hover_panel[hover_panel.index("preserveDirtyDetailIdentity"):]
        ),
        "dirty_action_contract": (
            "func requestAction(after handler:" in store
            and "case performAction" in store
            and "pendingActionHandler" in store
        ),
        "panel_close_uses_dirty_contract": (
            "detailStore.requestPanelClose" in presenter
            and "detailStore.requestClose()" in panel
        ),
    }


def main() -> int:
    failures: list[str] = []
    static = static_assertions()
    if not all(static.values()):
        failures.append("static_contract")

    with tempfile.TemporaryDirectory(prefix="blocks_p006b_") as temporary:
        temp = Path(temporary)
        fixture = temp / "P006BFixture.swift"
        executable = temp / "P006BFixture"
        fixture.write_text(textwrap.dedent(FIXTURE), encoding="utf-8")
        compiled = run([
            "xcrun", "--sdk", "macosx", "swiftc", "-O", "-g", "-lsqlite3",
            *sorted(str(path) for path in CORE.glob("*.swift")), str(fixture), "-o", str(executable),
        ])
        if compiled.returncode:
            failures.append("fixture_compile")
            report = {"ok": False, "failures": failures, "static": static}
            print(json.dumps(report, sort_keys=True))
            return 1
        executed = run([str(executable), str(temp / "storage")])
        if executed.returncode:
            failures.append("fixture_execution")
            report = {"ok": False, "failures": failures, "static": static}
            print(json.dumps(report, sort_keys=True))
            return 1
        fixture_report = json.loads(executed.stdout)
        failed_scenarios = [item["id"] for item in fixture_report["scenarios"] if item["result"] != "pass"]
        failures.extend(failed_scenarios)

    report = {"ok": not failures, "failures": failures, "static": static, "scenarios": fixture_report["scenarios"]}
    print(json.dumps(report, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
