#!/usr/bin/env python3
"""P16-B result validation must reject missing, duplicated or skipped coverage."""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import p16b_scrolling_screenshot_session_checks as gate
from p16b_scrolling_screenshot_session_checks import validate_test_results


def tree(*items: tuple[str, str]) -> dict:
    return {"children": [
        {"nodeType": "Test Case", "nodeIdentifier": f"ScrollingScreenshotAppTests/{name}()", "result": result}
        for name, result in items
    ]}


class ResultValidationTests(unittest.TestCase):
    summary = {"totalTestCount": 1, "passedTests": 1, "skippedTests": 0, "failedTests": 0}

    def test_expected_case_passes(self):
        self.assertTrue(validate_test_results(self.summary, tree(("testA", "Passed")), {"testA"})["ok"])

    def test_different_case_cannot_replace_missing_case(self):
        self.assertFalse(validate_test_results(self.summary, tree(("testB", "Passed")), {"testA"})["ok"])

    def test_duplicate_cases_rejected_even_with_matching_total(self):
        summary = dict(self.summary, totalTestCount=2, passedTests=2)
        self.assertFalse(validate_test_results(summary, tree(("testA", "Passed"), ("testA", "Passed")), {"testA"})["ok"])

    def test_unexpected_skip_rejected_even_with_matching_summary(self):
        summary = dict(self.summary, passedTests=0, skippedTests=1)
        self.assertFalse(validate_test_results(summary, tree(("testA", "Skipped")), {"testA"})["ok"])

    def test_failure_rejected_even_with_runner_success(self):
        self.assertFalse(validate_test_results(self.summary, tree(("testA", "Failed")), {"testA"})["ok"])

    def test_resource_opt_in_skips_are_explicit(self):
        name = "testNearEffectiveLimitResourceProfile"
        summary = dict(self.summary, passedTests=0, skippedTests=1)
        report = validate_test_results(summary, tree((name, "Skipped")), {name})
        self.assertTrue(report["ok"])
        self.assertEqual(report["skipped"], [name])

    def test_zero_case_result_is_not_success(self):
        summary = dict(self.summary, totalTestCount=0, passedTests=0)
        self.assertFalse(validate_test_results(summary, tree(), {"testA"})["ok"])
        self.assertFalse(validate_test_results(summary, tree(), set())["ok"])

    def test_summary_case_disagreement_rejected(self):
        summary = dict(self.summary, passedTests=0)
        self.assertFalse(validate_test_results(summary, tree(("testA", "Passed")), {"testA"})["ok"])

    def test_other_suite_cannot_count_as_scrolling_coverage(self):
        other = {"nodeType": "Test Case", "nodeIdentifier": "OtherSuite/testA()", "result": "Passed"}
        self.assertFalse(validate_test_results(self.summary, other, {"testA"})["ok"])


class BuildRetryTests(unittest.TestCase):
    cleaned = {"ok": False, "returncode": 70, "process_cleanup": {
        "status": "target_group_residual_cleaned", "child_returncode": 0,
    }}
    compile_error = {"ok": False, "returncode": 65}

    def run_gate(self, results):
        output = io.StringIO()
        with tempfile.TemporaryDirectory(prefix="blocks-p16b-runner-selftest-") as derived:
            with patch.object(gate, "run_controlled_subprocess", side_effect=results) as build, \
                 patch.object(gate, "run_controlled_xcode_test") as test, \
                 patch.object(gate.subprocess, "check_output", return_value="26.5"), \
                 patch("sys.argv", ["p16b", "--derived-data", derived]), redirect_stdout(output):
                self.assertEqual(gate.main(), 1)
                test.assert_not_called()
                return build.call_count, json.loads(output.getvalue())

    def test_confirmed_cleanup_allows_only_one_incremental_retry(self):
        calls, report = self.run_gate([self.cleaned, self.cleaned])
        self.assertEqual(calls, 2)
        self.assertEqual(len(report["runtime"]["build_attempts"]), 2)
        self.assertEqual(report["status"], "fail")

    def test_compile_failure_is_not_retried(self):
        calls, _ = self.run_gate([self.compile_error])
        self.assertEqual(calls, 1)

    def test_cleanup_with_failed_compiler_is_not_retried(self):
        failure = dict(self.cleaned, process_cleanup={
            "status": "target_group_residual_cleaned", "child_returncode": 65,
        })
        calls, _ = self.run_gate([failure])
        self.assertEqual(calls, 1)

    def test_missing_xctestrun_is_not_reported_as_compile_failure(self):
        calls, report = self.run_gate([{"ok": True, "returncode": 0}])
        self.assertEqual(calls, 1)
        self.assertEqual(report["runtime"]["status"], "runner_error")
        self.assertEqual(report["runtime"]["failed_phase"], "preparing_tests")
        self.assertTrue(report["runtime"]["build_attempts"][0]["ok"])


if __name__ == "__main__":
    unittest.main()
