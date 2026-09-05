#!/usr/bin/env python3
"""Adversarial checks for P9-B's current source contracts (no App launch)."""

import unittest

import p9b_clipboard_appstate_repository_integration_checks as gate


def sources():
    join = lambda paths: "\n".join(gate.read(path) for path in paths)
    return {
        "app_model": join([gate.APP_MODEL, gate.MODEL_DELEGATION, gate.MODEL_BINDINGS]),
        "store": gate.read(gate.CLIPBOARD_STORE),
        "coordinator": join([gate.CLIPBOARD_COORDINATOR, gate.CLIPBOARD_COORDINATOR.with_name("ClipboardFeatureCoordinator+CapturePersistence.swift"), gate.PASTE_ORCHESTRATOR]),
        "paste": gate.read(gate.PASTE_ORCHESTRATOR),
        "copy_actions": gate.read(gate.COPY_ACTIONS),
        "panel_actions": gate.read(gate.PANEL_ACTIONS),
        "auto_paste": gate.read(gate.AUTO_PASTE),
        "history_pipeline": gate.read(gate.HISTORY_PIPELINE),
        "ocr_scheduler": gate.read(gate.OCR_SCHEDULER),
    }


class CurrentIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.current = sources()

    def test_current_contracts(self):
        checks = gate.current_contracts(self.current)
        self.assertEqual(len(checks), 9)
        self.assertTrue(all(checks.values()), checks)

    def test_each_critical_wiring_removal_fails(self):
        cases = [
            ("app_model", "clipboardCoordinator.confirmCleanupPolicy(", "cleanup_preview_and_confirmation_delegate"),
            ("panel_actions", "await self.deleteHistoryItem(recordID: recordID)", "panel_delete_delegates_to_store"),
            ("auto_paste", "try await pasteboardWriter.write(", "copy_has_no_target_dependency"),
            ("auto_paste", "try await ensurePasteboardOwnership(pasteboardLease)", "dispatch_requires_owned_lease_and_target"),
            ("paste", "await clipboardStore.commitCopyEvent(", "paste_records_physical_write_before_late_effects"),
            ("copy_actions", "await clipboardStore.commitCopyEvent(", "plain_copy_records_validated_write_before_late_effects"),
            ("store", "snapshot.generation == self.historyReadGeneration", "history_read_is_generation_scoped"),
            ("store", "payloadCache = payloadCache.filter { recordIDs.contains($0.key.recordID) }", "payload_cache_prunes_only_removed_records"),
            ("ocr_scheduler", "queue.retryOCR(recordID:", "ocr_scheduler_owns_queue"),
        ]
        for key, token, contract in cases:
            with self.subTest(contract=contract):
                self.assertIn(token, self.current[key])
                changed = dict(self.current, **{key: self.current[key].replace(token, "REMOVED_WIRING")})
                self.assertFalse(gate.current_contracts(changed)[contract])

    def test_early_cancellation_must_not_discard_committed_write(self):
        token = "pasteboardLease = copyResult.pasteboardLease"
        changed = dict(self.current, paste=self.current["paste"].replace(token, token + "\n guard copyResult.mayContinueAutomaticPaste else { return }"))
        self.assertFalse(gate.current_contracts(changed)["paste_records_physical_write_before_late_effects"])

    def test_comment_cannot_supply_missing_dispatch_validation(self):
        token = "try await ensurePasteboardOwnership(pasteboardLease)"
        changed = dict(self.current, auto_paste=self.current["auto_paste"].replace(token, "/* " + token + " */"))
        self.assertFalse(gate.current_contracts(changed)["dispatch_requires_owned_lease_and_target"])

    def test_dispatch_cannot_rewrite_the_clipboard(self):
        token = "try await ensurePasteboardOwnership(pasteboardLease)"
        changed = dict(self.current, auto_paste=self.current["auto_paste"].replace(token, token + "\n try await pasteboardWriter.write(payload: payload)"))
        self.assertFalse(gate.current_contracts(changed)["dispatch_requires_owned_lease_and_target"])


class BodyExtractionTests(unittest.TestCase):
    def test_default_closure_is_not_the_method_body(self):
        text = 'func action(allowed: () -> Bool = { true }, text: String = #")"#) async { actualWrite() }'
        body = gate.body_of(text, "func action(")
        self.assertIn("actualWrite()", body)
        self.assertNotIn("true", body)

    def test_overload_ambiguity_fails_closed(self):
        self.assertEqual(gate.body_of("func action() { first() }\nfunc action(value: Int) { second() }", "func action("), "")

    def test_prefix_name_is_not_an_overload(self):
        body = gate.body_of("func actionExtra() { wrong() }\nfunc action() { right() }", "func action")
        self.assertIn("right()", body)
        self.assertNotIn("wrong()", body)

    def test_comments_and_strings_cannot_supply_fake_bodies(self):
        text = '/* func action() { fake() } */\nfunc action() { let s = "{ fake() }"; real() }'
        body = gate.body_of(text, "func action(")
        self.assertIn("real()", body)
        self.assertNotIn("fake()", body)


if __name__ == "__main__":
    unittest.main()
