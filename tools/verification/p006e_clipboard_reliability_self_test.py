#!/usr/bin/env python3
"""Mutation checks for P006-E's current owners; does not launch the App."""

import contextlib
import io
import json
import unittest
from unittest.mock import patch

import p006e_clipboard_core_reliability_checks as gate


class CurrentOwnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.current = {
            "database": gate.source("apps/Blocks/BlocksCore/AppDatabase.swift"),
            "history": gate.source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardHistoryReadPipeline.swift"),
            "scheduler": gate.source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardOCRScheduler.swift"),
            "policy": gate.source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardFeatureCoordinator+Policy.swift"),
            "store": gate.source("apps/Blocks/BlocksApp/Features/Clipboard/ClipboardStore.swift"),
            "repository": gate.source("apps/Blocks/BlocksCore/ClipboardRepository.swift"),
            "search_repository": gate.source("apps/Blocks/BlocksCore/ClipboardRepository+SearchDocuments.swift"),
        }

    def check_change(self, key, old, new, contract):
        self.assertIn(old, self.current[key])
        changed = dict(self.current, **{key: self.current[key].replace(old, new)})
        self.assertFalse(gate.current_owner_contracts(**changed)[contract])

    def test_current_contracts(self):
        checks = gate.current_owner_contracts(**self.current)
        self.assertEqual(len(checks), 4)
        self.assertTrue(all(checks.values()), checks)

    def test_required_operations_cannot_be_removed_or_commented(self):
        cases = [
            ("database", "try migrateV8()", "schema_ceiling_matches_latest_migration_and_runs_v8"),
            ("history", "filteringBatch: { candidates in", "filtered_search_limits_matching_results"),
            ("history", "ClipboardSearchCoordinator.applyFilters(", "filtered_search_limits_matching_results"),
            ("repository", "while records.count < safeLimit", "filtered_search_limits_matching_results"),
            ("repository", "matching = try filteringBatch(batch)", "filtered_search_limits_matching_results"),
            ("repository", "matching.prefix(safeLimit - records.count)", "filtered_search_limits_matching_results"),
            ("scheduler", "guard processingTask == nil", "ocr_scheduler_single_flight_drain"),
            ("scheduler", "await queue.processPending(", "ocr_scheduler_single_flight_drain"),
            ("scheduler", "if self.drainRequested { continue }", "ocr_scheduler_single_flight_drain"),
            ("scheduler", "self.schedule(context: self.pendingContext, quietDelay: 0)", "ocr_scheduler_single_flight_drain"),
            ("policy", "clipboardStore.confirmPolicyApplication(token: token)", "confirmed_policy_preserves_failure"),
            ("store", "completion(.failed)", "confirmed_policy_preserves_failure"),
            ("store", "pending == token", "confirmed_policy_preserves_failure"),
        ]
        for key, token, contract in cases:
            for replacement in ("REMOVED", "/* " + token + " */"):
                with self.subTest(key=key, token=token, replacement=replacement):
                    self.check_change(key, token, replacement, contract)

    def test_schema_ceiling_must_match_latest_write(self):
        self.check_change("database", "currentVersion > 17", "currentVersion > 9", "schema_ceiling_matches_latest_migration_and_runs_v8")

    def test_schema_contract_is_not_pinned_to_seventeen(self):
        changed = dict(self.current, database=self.current["database"].replace("currentVersion > 17", "currentVersion > 18").replace("PRAGMA user_version = 17", "PRAGMA user_version = 18"))
        self.assertTrue(gate.current_owner_contracts(**changed)["schema_ceiling_matches_latest_migration_and_runs_v8"])

    def test_filter_cannot_limit_candidates_before_matching(self):
        self.check_change("repository", "filteringBatch == nil ? max(1, limit) : -1", "max(1, limit)", "filtered_search_limits_matching_results")

    def test_candidate_batch_cannot_become_unbounded(self):
        self.check_change("repository", "while batch.count < 256, try statement.step()", "while try statement.step()", "filtered_search_limits_matching_results")

    def test_failure_cannot_be_reported_as_committed(self):
        self.check_change("store", "completion(.failed)", "completion(.committed(visibleRecordCount: 0))", "confirmed_policy_preserves_failure")

    def test_string_cannot_supply_missing_scheduler_guard(self):
        self.check_change("scheduler", "guard processingTask == nil", 'let fake = "guard processingTask == nil"', "ocr_scheduler_single_flight_drain")

    def test_unreadable_source_returns_structured_failure(self):
        for error in (FileNotFoundError("missing fixture"), ValueError("missing declaration")):
            with self.subTest(error=type(error).__name__):
                output = io.StringIO()
                with patch.object(gate, "source", side_effect=error), contextlib.redirect_stdout(output):
                    self.assertEqual(gate.run(), 1)
                report = json.loads(output.getvalue())
                self.assertFalse(report["ok"])
                self.assertEqual(report["failures"][0]["code"], "source_inspection_error")


if __name__ == "__main__":
    unittest.main()
