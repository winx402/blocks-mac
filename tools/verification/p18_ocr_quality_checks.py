#!/usr/bin/env python3
"""Build and run the low-sensitivity, real-Vision OCR quality corpus."""

from __future__ import annotations

import hashlib
import json
import math
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "apps/Blocks/BlocksApp/Features/OCR/LocalVisionOCRService.swift"
CORPUS = ROOT / "tools/verification/ocr_quality_corpus.swift"
COLD_LIMIT_MILLISECONDS = 8_000
WARM_P95_LIMIT_MILLISECONDS = 500
DEFAULT_REPORT_MEASUREMENT_SCOPE = "current-corpus-process-first-service-call"
EXPECTED_RECOGNITION_LANGUAGES = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
EXPECTED_FIXTURE_SHA256 = {
    "light-2x-mixed": "0275e8e1c00a73b4a62627fc89475cc0489d68a92f8ed68dfc9f4f2d72b3dfea",
    "dark-ui": "846721c35bf2a644d31186df673564c9f7f3700c037fc7da6f14f8aa9f683768",
    "compact-ui": "d0d1ea6834e8dfd013ae1e3430ebc95c2beece060e0cefc13771c612fb5a9202",
    "traditional-japanese": "a1a74de1bae49dddd5a7643fb6b3e5ce52c7f9c03d0be82d3dfa5f6206d84fb2",
    "transparent-alpha": "547fa58d7aa30b89bc7ef9efb6163535e67d1d02446813e1335016e32a5879b0",
    "tall": "76092653bb87041341d59e38e3489cb8630908825c7234eb6d250ca0d9ac85e5",
    "four_k": "09c8840bd204aa26e823425697ed8ab4a186b863d71433c17a9006727fa83ae6",
}
PROCESS_FIRST_FIXTURE_CONTRACTS = {
    "light-2x-mixed": (EXPECTED_FIXTURE_SHA256["light-2x-mixed"], 3, 0.02),
    "dark-ui": (EXPECTED_FIXTURE_SHA256["dark-ui"], 3, 0.02),
    "compact-ui": (EXPECTED_FIXTURE_SHA256["compact-ui"], 2, 0.08),
    "traditional-japanese": (EXPECTED_FIXTURE_SHA256["traditional-japanese"], 2, 0.08),
    "transparent-alpha": (EXPECTED_FIXTURE_SHA256["transparent-alpha"], 1, 0.02),
    "tall-scroll": (EXPECTED_FIXTURE_SHA256["tall"], 72, None),
    "4k-screen": (EXPECTED_FIXTURE_SHA256["four_k"], 24, None),
}
SHA256_HEX_PATTERN = re.compile(r"[0-9a-f]{64}")
UUID_PATTERN = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"
)
# The outer corpus clock additionally includes call dispatch and result
# serialization. It must cover the same service call, with only a tiny clock
# measurement underrun and bounded outer-call overhead.
FIRST_CALL_TIMING_MEASUREMENT_UNDERRUN_MILLISECONDS = 1.0
FIRST_CALL_TIMING_MAXIMUM_OVERHEAD_MILLISECONDS = 100.0
FIRST_CALL_TIMING_MAXIMUM_OVERHEAD_FRACTION = 0.01


def is_finite_nonnegative_number(value: object) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(float(value)) and value >= 0
    except OverflowError:
        return False


def is_canonical_recognition_id(value: object) -> bool:
    return isinstance(value, str) and UUID_PATTERN.fullmatch(value) is not None


def fixture_sha256_contract_failures(
    fixture_sha256: object,
    expected_sha256: str,
    scope: str,
) -> list[str]:
    if not isinstance(fixture_sha256, str):
        return [f"report_contract:fixture_sha256_type:{scope}"]
    if SHA256_HEX_PATTERN.fullmatch(fixture_sha256) is None:
        return [f"report_contract:fixture_sha256_format:{scope}"]
    if fixture_sha256 != expected_sha256:
        return [f"report_contract:fixture_sha256_mismatch:{scope}"]
    return []


def recognition_id_uniqueness_failures(
    scoped_timings: list[tuple[str, object]],
) -> list[str]:
    recognition_scopes: dict[str, list[str]] = {}
    for scope, timing in scoped_timings:
        if not isinstance(timing, dict):
            continue
        recognition_id = timing.get("recognitionID")
        if is_canonical_recognition_id(recognition_id):
            recognition_scopes.setdefault(recognition_id, []).append(scope)
    failures: list[str] = []
    for scopes in recognition_scopes.values():
        if len(scopes) > 1:
            failures.extend(
                f"report_contract:recognition_id_not_unique:{scope}"
                for scope in scopes
            )
    return failures


def first_call_timing_correlation_failures(
    outer_duration_milliseconds: object,
    timing: object,
    scope: str,
) -> list[str]:
    """Require the outer and service durations to describe the same first call."""
    if not is_finite_nonnegative_number(outer_duration_milliseconds):
        return [f"report_contract:first_recognition_outer_duration_invalid:{scope}"]
    if not isinstance(timing, dict):
        return [f"report_contract:first_recognition_timing_correlation_missing:{scope}"]
    total_milliseconds = timing.get("totalMilliseconds")
    if not is_finite_nonnegative_number(total_milliseconds):
        return [
            "report_contract:first_recognition_timing_correlation_total_invalid:"
            f"{scope}"
        ]
    outer_duration = float(outer_duration_milliseconds)
    service_total = float(total_milliseconds)
    maximum_overhead = max(
        FIRST_CALL_TIMING_MAXIMUM_OVERHEAD_MILLISECONDS,
        service_total * FIRST_CALL_TIMING_MAXIMUM_OVERHEAD_FRACTION,
    )
    if (outer_duration + FIRST_CALL_TIMING_MEASUREMENT_UNDERRUN_MILLISECONDS
            < service_total
            or outer_duration - service_total > maximum_overhead):
        return [
            "report_contract:first_recognition_timing_correlation:"
            f"{scope}:outer={outer_duration_milliseconds}:service={total_milliseconds}"
        ]
    return []


def timing_contract_failures(timing: object, requests: object, scope: str) -> list[str]:
    if not isinstance(timing, dict):
        return [f"report_contract:timing_missing_or_invalid:{scope}"]
    required = ("recognitionID", "terminal", "totalMilliseconds", "supportedLanguagesCacheHit",
                "supportedLanguagesMilliseconds", "requestConfigurationMilliseconds",
                "layoutMilliseconds", "requestCount", "passes", "serviceUnattributedMilliseconds")
    missing = [key for key in required if key not in timing]
    if missing:
        return [f"report_contract:timing_fields_missing:{scope}:{','.join(missing)}"]
    failures: list[str] = []
    if timing["terminal"] != "success":
        failures.append(f"report_contract:timing_terminal:{scope}")
    if not is_canonical_recognition_id(timing["recognitionID"]):
        failures.append(f"report_contract:recognition_id_invalid:{scope}")
    if not isinstance(timing["supportedLanguagesCacheHit"], bool):
        failures.append(f"report_contract:timing_cache_hit:{scope}")
    numeric = ("totalMilliseconds", "supportedLanguagesMilliseconds",
               "requestConfigurationMilliseconds", "layoutMilliseconds",
               "serviceUnattributedMilliseconds")
    if any(not is_finite_nonnegative_number(timing[key]) for key in numeric):
        return failures + [f"report_contract:timing_numeric:{scope}"]
    if timing["totalMilliseconds"] <= 0:
        failures.append(f"report_contract:timing_total_not_positive:{scope}")
    passes = timing["passes"]
    if not isinstance(passes, list):
        return failures + [f"report_contract:timing_passes:{scope}"]
    if (not isinstance(timing["requestCount"], int)
            or isinstance(timing["requestCount"], bool)):
        return failures + [f"report_contract:timing_request_count:{scope}"]
    if (timing["requestCount"] != len(passes)
            or not isinstance(requests, list)
            or timing["requestCount"] != len(requests)):
        failures.append(f"report_contract:timing_request_count:{scope}")
    pass_numeric = ("requestConstructionMilliseconds", "queueWaitMilliseconds",
                    "handlerConstructionMilliseconds", "performMilliseconds",
                    "mappingMilliseconds", "adapterTotalMilliseconds",
                    "unattributedMilliseconds")
    adapter_total = 0.0
    for index, item in enumerate(passes):
        if (not isinstance(item, dict) or item.get("ordinal") != index + 1
                or item.get("terminal") != "success"
                or not isinstance(item.get("passKind"), str)
                or not isinstance(item.get("pixelBucket"), str)):
            failures.append(f"report_contract:timing_pass_identity:{scope}:{index}")
            continue
        if any(not is_finite_nonnegative_number(item.get(key))
               for key in pass_numeric):
            failures.append(f"report_contract:timing_pass_numeric:{scope}:{index}")
            continue
        if item["adapterTotalMilliseconds"] <= 0 or item["performMilliseconds"] <= 0:
            failures.append(f"report_contract:timing_pass_not_positive:{scope}:{index}")
        known = sum(item[key] for key in pass_numeric[:-2]) + item["unattributedMilliseconds"]
        if not math.isclose(known, item["adapterTotalMilliseconds"], rel_tol=0.02, abs_tol=0.25):
            failures.append(f"report_contract:timing_pass_conservation:{scope}:{index}")
        adapter_total += item["adapterTotalMilliseconds"]
    # supported time is nested in request configuration and deliberately not added here.
    service_known = timing["requestConfigurationMilliseconds"] + timing["layoutMilliseconds"] + adapter_total + timing["serviceUnattributedMilliseconds"]
    if not math.isclose(service_known, timing["totalMilliseconds"], rel_tol=0.02, abs_tol=0.5):
        failures.append(f"report_contract:timing_service_conservation:{scope}")
    return failures


def vision_request_contract_failures(requests: object, scope: str) -> list[str]:
    """Validate the captured configurations actually passed to Vision."""
    if not isinstance(requests, list) or not requests:
        return [f"report_contract:vision_requests_missing_or_empty:{scope}"]

    failures: list[str] = []
    fields = (
        "recognitionLanguages",
        "automaticallyDetectsLanguage",
        "usesLanguageCorrection",
    )
    for index, request in enumerate(requests):
        if not isinstance(request, dict):
            failures.append(
                f"report_contract:vision_request_not_object:{scope}:{index}"
            )
            continue
        missing_fields = [field for field in fields if field not in request]
        if missing_fields:
            failures.append(
                "report_contract:first_recognition_vision_request_fields_missing:"
                f"{scope}:{index}:{','.join(missing_fields)}"
            )
            continue
        languages = request["recognitionLanguages"]
        if not isinstance(languages, list):
            failures.append(
                f"report_contract:vision_request_languages_not_array:{scope}:{index}"
            )
        elif any(not isinstance(language, str) or not language for language in languages):
            failures.append(
                f"report_contract:vision_request_languages_invalid:{scope}:{index}"
            )
        elif len(set(languages)) != len(languages):
            failures.append(
                f"report_contract:vision_request_languages_duplicate:{scope}:{index}"
            )
        elif set(languages) != set(EXPECTED_RECOGNITION_LANGUAGES):
            failures.append(
                f"report_contract:vision_request_languages_mismatch:{scope}:{index}"
            )
        boolean_fields = (
            "automaticallyDetectsLanguage",
            "usesLanguageCorrection",
        )
        invalid_boolean_fields = [
            field for field in boolean_fields if not isinstance(request[field], bool)
        ]
        if invalid_boolean_fields:
            failures.append(
                "report_contract:vision_request_booleans_invalid:"
                f"{scope}:{index}:{','.join(invalid_boolean_fields)}"
            )
            continue
        if not request["automaticallyDetectsLanguage"]:
            failures.append(
                f"report_contract:vision_request_auto_detect_disabled:{scope}:{index}"
            )
        if index == 0:
            if languages == EXPECTED_RECOGNITION_LANGUAGES:
                pass
            elif isinstance(languages, list):
                failures.append(
                    f"report_contract:vision_request_primary_language_order:{scope}"
                )
            if request["usesLanguageCorrection"]:
                failures.append(
                    f"report_contract:vision_request_primary_correction_enabled:{scope}"
                )
    return failures


def evaluate_report(report: dict) -> list[str]:
    """Evaluate one current-corpus-process report with fail-closed timing scope."""
    failures: list[str] = []
    first_recognition_timings: list[tuple[str, object]] = []
    fixture_contracts = {
        "light-2x-mixed": (0.02, 3),
        "dark-ui": (0.02, 3),
        "compact-ui": (0.08, 2),
        "traditional-japanese": (0.08, 2),
        "transparent-alpha": (0.02, 1),
    }
    fixtures = report.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        return ["report_contract:fixtures_missing_or_empty"]

    if "measurementScope" not in report:
        return ["report_contract:measurement_scope_missing"]
    if not isinstance(report["measurementScope"], str):
        return ["report_contract:measurement_scope_type"]
    if report["measurementScope"] != DEFAULT_REPORT_MEASUREMENT_SCOPE:
        return ["report_contract:measurement_scope_value"]

    fixture_names = [
        fixture.get("name") if isinstance(fixture, dict) else None
        for fixture in fixtures
    ]
    if len(fixtures) != len(fixture_contracts) \
            or any(not isinstance(name, str) for name in fixture_names) \
            or len(set(fixture_names)) != len(fixture_names) \
            or set(fixture_names) != set(fixture_contracts):
        return ["report_contract:fixture_set_mismatch"]

    fixture_fields = (
        "name",
        "characterErrorRate",
        "maximumCharacterErrorRate",
        "actualLineCount",
        "expectedLineCount",
        "runsAllLineCountsValid",
        "coldDurationMilliseconds",
        "durationMilliseconds",
        "warmP95DurationMilliseconds",
        "p95DurationMilliseconds",
        "isColdEligible",
        "fixtureSHA256",
    )
    for index, fixture in enumerate(fixtures):
        if not isinstance(fixture, dict):
            failures.append(f"report_contract:fixture_not_object:fixture-{index}")
            continue
        name = fixture.get("name", f"fixture-{index}")
        scope = f"fixture:{name}" if isinstance(name, str) else f"fixture-{index}"
        failures.extend(vision_request_contract_failures(
            fixture.get("firstRecognitionVisionRequests"), scope
        ))
        first_recognition_timing = fixture.get("firstRecognitionTiming")
        first_recognition_timings.append((scope, first_recognition_timing))
        failures.extend(timing_contract_failures(
            first_recognition_timing,
            fixture.get("firstRecognitionVisionRequests"),
            scope,
        ))
        missing_fields = [field for field in fixture_fields if field not in fixture]
        if missing_fields:
            failures.append(f"report_contract:fixture_fields_missing:{name}:{','.join(missing_fields)}")
            continue
        if not isinstance(name, str):
            failures.append(f"report_contract:fixture_name_invalid:fixture-{index}")
            continue
        expected_fixture_sha256 = EXPECTED_FIXTURE_SHA256.get(name)
        if expected_fixture_sha256 is None:
            failures.append(f"report_contract:unknown_fixture:{name}")
            continue
        failures.extend(fixture_sha256_contract_failures(
            fixture["fixtureSHA256"], expected_fixture_sha256, scope
        ))
        count_fields = (
            "actualLineCount",
            "expectedLineCount",
        )
        invalid_count_fields = [
            field for field in count_fields
            if not isinstance(fixture[field], int)
            or isinstance(fixture[field], bool)
            or fixture[field] < 0
        ]
        if invalid_count_fields:
            failures.append(
                f"report_contract:fixture_count_fields_invalid:{name}:{','.join(invalid_count_fields)}"
            )
            continue
        numeric_fields = (
            "characterErrorRate",
            "maximumCharacterErrorRate",
            "coldDurationMilliseconds",
            "durationMilliseconds",
            "warmP95DurationMilliseconds",
            "p95DurationMilliseconds",
        )
        invalid_numeric_fields = [
            field for field in numeric_fields
            if not is_finite_nonnegative_number(fixture[field])
        ]
        if invalid_numeric_fields:
            failures.append(
                f"report_contract:fixture_numeric_fields_invalid:{name}:{','.join(invalid_numeric_fields)}"
            )
            continue
        failures.extend(first_call_timing_correlation_failures(
            fixture["coldDurationMilliseconds"],
            fixture.get("firstRecognitionTiming"),
            scope,
        ))
        if not isinstance(fixture["runsAllLineCountsValid"], bool) \
                or not isinstance(fixture["isColdEligible"], bool):
            failures.append(f"report_contract:fixture_boolean_fields_invalid:{name}")
            continue
        if fixture["isColdEligible"] is not (index == 0):
            failures.append(f"report_contract:cold_eligibility:{name}:expected_{index == 0}")
            continue
        fixture_limit, expected_line_count = fixture_contracts[name]
        if fixture["expectedLineCount"] != expected_line_count:
            failures.append(
                f"report_contract:fixture_expected_line_count:{name}:"
                f"{fixture['expectedLineCount']}/{expected_line_count}"
            )
            continue
        if fixture["maximumCharacterErrorRate"] < fixture["characterErrorRate"]:
            failures.append(f"report_contract:fixture_maximum_cer_below_first:{name}")
            continue
        if fixture["durationMilliseconds"] != fixture["coldDurationMilliseconds"]:
            failures.append(f"report_contract:fixture_legacy_duration_mismatch:{name}")
            continue
        if fixture["maximumCharacterErrorRate"] > fixture_limit:
            failures.append(f"quality.cer:{name}:{fixture['maximumCharacterErrorRate']:.4f}")
        if fixture["actualLineCount"] < fixture["expectedLineCount"]:
            failures.append(
                f"quality.line_recall:{name}:{fixture['actualLineCount']}/{fixture['expectedLineCount']}"
            )
        if not fixture["runsAllLineCountsValid"]:
            failures.append(f"quality.line_repeat_instability:{name}")
        if fixture["isColdEligible"] and fixture["coldDurationMilliseconds"] >= COLD_LIMIT_MILLISECONDS:
            failures.append(
                f"performance.cold:{name}:{fixture['coldDurationMilliseconds']:.1f}ms"
            )
        if fixture["warmP95DurationMilliseconds"] > WARM_P95_LIMIT_MILLISECONDS:
            failures.append(
                f"performance.regular_p95:{name}:{fixture['warmP95DurationMilliseconds']:.1f}ms"
            )

    report_fields = (
        "tallActualLineCount",
        "tallExpectedLineCount",
        "tallUniqueLineCount",
        "tallDurationMilliseconds",
        "tallRunsAllValid",
        "tallP95DurationMilliseconds",
        "fourKActualLineCount",
        "fourKExpectedLineCount",
        "fourKDurationMilliseconds",
        "fourKRunsAllValid",
        "fourKP95DurationMilliseconds",
        "tallFixtureSHA256",
        "fourKFixtureSHA256",
        "tallFirstRecognitionVisionRequests",
        "fourKFirstRecognitionVisionRequests",
        "tallFirstRecognitionTiming",
        "fourKFirstRecognitionTiming",
    )
    missing_report_fields = [field for field in report_fields if field not in report]
    if missing_report_fields:
        failures.append(
            "report_contract:report_fields_missing:" + ",".join(missing_report_fields)
        )
        return failures
    failures.extend(vision_request_contract_failures(
        report["tallFirstRecognitionVisionRequests"], "tall"
    ))
    first_recognition_timings.append(("tall", report["tallFirstRecognitionTiming"]))
    failures.extend(timing_contract_failures(
        report["tallFirstRecognitionTiming"],
        report["tallFirstRecognitionVisionRequests"],
        "tall",
    ))
    first_recognition_timings.append(("four_k", report["fourKFirstRecognitionTiming"]))
    failures.extend(timing_contract_failures(
        report["fourKFirstRecognitionTiming"],
        report["fourKFirstRecognitionVisionRequests"],
        "four_k",
    ))
    failures.extend(vision_request_contract_failures(
        report["fourKFirstRecognitionVisionRequests"], "four_k"
    ))
    failures.extend(fixture_sha256_contract_failures(
        report["tallFixtureSHA256"], EXPECTED_FIXTURE_SHA256["tall"], "tall"
    ))
    failures.extend(fixture_sha256_contract_failures(
        report["fourKFixtureSHA256"], EXPECTED_FIXTURE_SHA256["four_k"], "four_k"
    ))
    failures.extend(recognition_id_uniqueness_failures(first_recognition_timings))
    count_report_fields = (
        "tallActualLineCount",
        "tallExpectedLineCount",
        "tallUniqueLineCount",
        "fourKActualLineCount",
        "fourKExpectedLineCount",
    )
    invalid_count_report_fields = [
        field for field in count_report_fields
        if not isinstance(report[field], int)
        or isinstance(report[field], bool)
        or report[field] < 0
    ]
    if invalid_count_report_fields:
        failures.append(
            "report_contract:report_count_fields_invalid:"
            + ",".join(invalid_count_report_fields)
        )
        return failures
    duration_report_fields = (
        "tallDurationMilliseconds",
        "tallP95DurationMilliseconds",
        "fourKDurationMilliseconds",
        "fourKP95DurationMilliseconds",
    )
    invalid_duration_report_fields = [
        field for field in duration_report_fields
        if not is_finite_nonnegative_number(report[field])
    ]
    if invalid_duration_report_fields:
        failures.append(
            "report_contract:report_duration_fields_invalid:"
            + ",".join(invalid_duration_report_fields)
        )
        return failures
    failures.extend(first_call_timing_correlation_failures(
        report["tallDurationMilliseconds"],
        report.get("tallFirstRecognitionTiming"),
        "tall",
    ))
    failures.extend(first_call_timing_correlation_failures(
        report["fourKDurationMilliseconds"],
        report.get("fourKFirstRecognitionTiming"),
        "four_k",
    ))
    if not isinstance(report["tallRunsAllValid"], bool) \
            or not isinstance(report["fourKRunsAllValid"], bool):
        failures.append("report_contract:report_boolean_fields_invalid")
        return failures
    if report["tallExpectedLineCount"] != 72:
        failures.append("report_contract:tall_expected_line_count")
        return failures
    if report["fourKExpectedLineCount"] != 24:
        failures.append("report_contract:four_k_expected_line_count")
        return failures

    if report["tallActualLineCount"] != report["tallExpectedLineCount"]:
        failures.append(
            f"quality.tall_lines:{report['tallActualLineCount']}/{report['tallExpectedLineCount']}"
        )
    if report["tallUniqueLineCount"] != report["tallExpectedLineCount"]:
        failures.append(
            f"quality.tall_unique:{report['tallUniqueLineCount']}/{report['tallExpectedLineCount']}"
        )
    if not report["tallRunsAllValid"]:
        failures.append("quality.tall_repeat_instability")
    if report["tallP95DurationMilliseconds"] > 1_500:
        failures.append(f"performance.tall_p95:{report['tallP95DurationMilliseconds']:.1f}ms")
    if report["fourKActualLineCount"] != report["fourKExpectedLineCount"]:
        failures.append(
            f"quality.four_k_lines:{report['fourKActualLineCount']}/{report['fourKExpectedLineCount']}"
        )
    if not report["fourKRunsAllValid"]:
        failures.append("quality.four_k_repeat_instability")
    if report["fourKP95DurationMilliseconds"] > WARM_P95_LIMIT_MILLISECONDS:
        failures.append(f"performance.four_k_p95:{report['fourKP95DurationMilliseconds']:.1f}ms")
    return failures


def evaluate_process_first_report(report: object) -> list[str]:
    """Validate one isolated process-first OCR diagnostic JSON report."""
    if not isinstance(report, dict):
        return ["report_contract:process_first_root_not_object"]
    required = (
        "measurementKind",
        "recognitionOrdinal",
        "fixtureName",
        "processIdentifier",
        "characterErrorRate",
        "expectedLineCount",
        "actualLineCount",
        "coldDurationMilliseconds",
        "fixtureSHA256",
        "firstRecognitionVisionRequests",
        "firstRecognitionTiming",
    )
    missing = [field for field in required if field not in report]
    if missing:
        return ["report_contract:process_first_fields_missing:" + ",".join(missing)]

    failures: list[str] = []
    if report["measurementKind"] != "process-first-service-call":
        failures.append("report_contract:process_first_measurement_kind")
    if (not isinstance(report["recognitionOrdinal"], int)
            or isinstance(report["recognitionOrdinal"], bool)
            or report["recognitionOrdinal"] != 1):
        failures.append("report_contract:process_first_recognition_ordinal")
    if (not isinstance(report["processIdentifier"], int)
            or isinstance(report["processIdentifier"], bool)
            or report["processIdentifier"] <= 0):
        failures.append("report_contract:process_first_process_identifier")

    fixture_name = report["fixtureName"]
    if not isinstance(fixture_name, str):
        failures.append("report_contract:process_first_fixture_name_type")
        fixture_contract = None
        scope = "process_first"
    else:
        fixture_contract = PROCESS_FIRST_FIXTURE_CONTRACTS.get(fixture_name)
        scope = f"process_first:{fixture_name}"
        if fixture_contract is None:
            failures.append(f"report_contract:process_first_unknown_fixture:{fixture_name}")

    count_fields = ("expectedLineCount", "actualLineCount")
    invalid_count_fields = [
        field for field in count_fields
        if not isinstance(report[field], int)
        or isinstance(report[field], bool)
        or report[field] < 0
    ]
    if invalid_count_fields:
        failures.append(
            "report_contract:process_first_count_fields_invalid:"
            + ",".join(invalid_count_fields)
        )
    numeric_fields = ("characterErrorRate", "coldDurationMilliseconds")
    invalid_numeric_fields = [
        field for field in numeric_fields
        if not is_finite_nonnegative_number(report[field])
    ]
    if invalid_numeric_fields:
        failures.append(
            "report_contract:process_first_numeric_fields_invalid:"
            + ",".join(invalid_numeric_fields)
        )

    failures.extend(vision_request_contract_failures(
        report["firstRecognitionVisionRequests"], scope
    ))
    failures.extend(timing_contract_failures(
        report["firstRecognitionTiming"],
        report["firstRecognitionVisionRequests"],
        scope,
    ))
    failures.extend(first_call_timing_correlation_failures(
        report["coldDurationMilliseconds"],
        report["firstRecognitionTiming"],
        scope,
    ))

    if fixture_contract is not None:
        expected_sha256, expected_line_count, maximum_error_rate = fixture_contract
        failures.extend(fixture_sha256_contract_failures(
            report["fixtureSHA256"], expected_sha256, scope
        ))
        if (not invalid_count_fields
                and report["expectedLineCount"] != expected_line_count):
            failures.append(
                "report_contract:process_first_expected_line_count:"
                f"{fixture_name}:{report['expectedLineCount']}/{expected_line_count}"
            )
        if not invalid_count_fields and report["actualLineCount"] < report["expectedLineCount"]:
            failures.append(
                "quality.process_first_line_recall:"
                f"{fixture_name}:{report['actualLineCount']}/{report['expectedLineCount']}"
            )
        if (maximum_error_rate is not None
                and not invalid_numeric_fields
                and report["characterErrorRate"] > maximum_error_rate):
            failures.append(
                f"quality.process_first_cer:{fixture_name}:{report['characterErrorRate']:.4f}"
            )
    if ("coldDurationMilliseconds" not in invalid_numeric_fields
            and report["coldDurationMilliseconds"] >= COLD_LIMIT_MILLISECONDS):
        failures.append(
            f"performance.process_first_cold:{report['coldDurationMilliseconds']:.1f}ms"
        )
    return failures


def evaluate_process_first_reports(reports: object) -> list[str]:
    """Validate a pure-JSON process-first report set, including ID uniqueness."""
    if not isinstance(reports, list) or not reports:
        return ["report_contract:process_first_reports_missing_or_empty"]
    failures: list[str] = []
    scoped_timings: list[tuple[str, object]] = []
    for index, report in enumerate(reports):
        failures.extend(evaluate_process_first_report(report))
        if not isinstance(report, dict):
            continue
        fixture_name = report.get("fixtureName")
        scope_name = fixture_name if isinstance(fixture_name, str) else f"report-{index}"
        scoped_timings.append((
            f"process_first:{scope_name}:{index}",
            report.get("firstRecognitionTiming"),
        ))
    failures.extend(recognition_id_uniqueness_failures(scoped_timings))
    return failures


def run_contract_self_test() -> int:
    """Exercise JSON-only negative cases without compiling or invoking Vision."""
    valid_requests = [{
        "recognitionLanguages": EXPECTED_RECOGNITION_LANGUAGES,
        "automaticallyDetectsLanguage": True,
        "usesLanguageCorrection": False,
    }, {
        "recognitionLanguages": ["ja-JP", "zh-Hans", "zh-Hant", "en-US"],
        "automaticallyDetectsLanguage": True,
        "usesLanguageCorrection": True,
    }]

    def make_snapshot_timing(recognition_id: str) -> dict:
        return {
            "recognitionID": recognition_id,
            "terminal": "success",
            "totalMilliseconds": 11.5,
            "supportedLanguagesCacheHit": False,
            "supportedLanguagesMilliseconds": 1.0,
            "requestConfigurationMilliseconds": 2.0,
            "layoutMilliseconds": 1.0,
            "requestCount": 2,
            "serviceUnattributedMilliseconds": 1.0,
            "passes": [
                {"ordinal": 1, "passKind": "primary", "pixelBucket": "under_1mp", "terminal": "success", "requestConstructionMilliseconds": 1.0, "queueWaitMilliseconds": 1.0, "handlerConstructionMilliseconds": 1.0, "performMilliseconds": 1.0, "mappingMilliseconds": 1.0, "adapterTotalMilliseconds": 5.0, "unattributedMilliseconds": 0.0},
                {"ordinal": 2, "passKind": "correction_fallback", "pixelBucket": "under_1mp", "terminal": "success", "requestConstructionMilliseconds": 0.5, "queueWaitMilliseconds": 0.5, "handlerConstructionMilliseconds": 0.5, "performMilliseconds": 0.5, "mappingMilliseconds": 0.5, "adapterTotalMilliseconds": 2.5, "unattributedMilliseconds": 0.0},
            ],
        }

    standalone_valid_timing = make_snapshot_timing(
        "00000000-0000-4000-8000-000000000001"
    )
    invalid_scoped_reports = (
        ({"fixtures": [{"name": "fixture-under-test", "firstRecognitionVisionRequests": []}]},
         "fixture:fixture-under-test"),
        ({"fixtures": [], "fourKFirstRecognitionVisionRequests": valid_requests}, "tall"),
        ({"fixtures": [], "tallFirstRecognitionVisionRequests": valid_requests,
          "fourKFirstRecognitionVisionRequests": "not-an-array"}, "four_k"),
    )
    invalid_request_lists = (
        [{}],
        [{
                "recognitionLanguages": [""],
                "automaticallyDetectsLanguage": True,
                "usesLanguageCorrection": False,
            }],
        [{
                "recognitionLanguages": ["en-US", "en-US"],
                "automaticallyDetectsLanguage": True,
                "usesLanguageCorrection": False,
            }],
        [{
                "recognitionLanguages": [],
                "automaticallyDetectsLanguage": 1,
                "usesLanguageCorrection": "false",
            }],
        [{
                "recognitionLanguages": ["zh-Hans", "zh-Hant", "en-US"],
                "automaticallyDetectsLanguage": True,
                "usesLanguageCorrection": False,
            }],
        [{
                "recognitionLanguages": EXPECTED_RECOGNITION_LANGUAGES + ["fr-FR"],
                "automaticallyDetectsLanguage": True,
                "usesLanguageCorrection": False,
            }],
        [{
                "recognitionLanguages": EXPECTED_RECOGNITION_LANGUAGES,
                "automaticallyDetectsLanguage": False,
                "usesLanguageCorrection": False,
            }],
        [{
                "recognitionLanguages": EXPECTED_RECOGNITION_LANGUAGES,
                "automaticallyDetectsLanguage": True,
                "usesLanguageCorrection": True,
            }],
    )
    if vision_request_contract_failures(valid_requests, "self-test-valid"):
        return print_failure("self_test:vision_request_contract_legal_case_rejected")
    if timing_contract_failures(standalone_valid_timing, valid_requests, "self-test-valid"):
        return print_failure("self_test:timing_legal_case_rejected")
    invalid_timings = []
    for key, value in (("totalMilliseconds", float("nan")), ("requestCount", 1)):
        candidate = json.loads(json.dumps(standalone_valid_timing)); candidate[key] = value; invalid_timings.append(candidate)
    negative = json.loads(json.dumps(standalone_valid_timing)); negative["passes"][0]["performMilliseconds"] = -1; invalid_timings.append(negative)
    ordinal = json.loads(json.dumps(standalone_valid_timing)); ordinal["passes"][1]["ordinal"] = 3; invalid_timings.append(ordinal)
    conservation = json.loads(json.dumps(standalone_valid_timing)); conservation["totalMilliseconds"] = 99; invalid_timings.append(conservation)
    missing = json.loads(json.dumps(standalone_valid_timing)); del missing["passes"]; invalid_timings.append(missing)
    all_zero = json.loads(json.dumps(standalone_valid_timing))
    all_zero["totalMilliseconds"] = 0.0
    all_zero["supportedLanguagesMilliseconds"] = 0.0
    all_zero["requestConfigurationMilliseconds"] = 0.0
    all_zero["layoutMilliseconds"] = 0.0
    all_zero["serviceUnattributedMilliseconds"] = 0.0
    for item in all_zero["passes"]:
        for key in ("requestConstructionMilliseconds", "queueWaitMilliseconds",
                    "handlerConstructionMilliseconds", "performMilliseconds",
                    "mappingMilliseconds", "adapterTotalMilliseconds",
                    "unattributedMilliseconds"):
            item[key] = 0.0
    invalid_timings.append(all_zero)
    invalid_type = json.loads(json.dumps(standalone_valid_timing)); invalid_type["totalMilliseconds"] = "invalid"; invalid_timings.append(invalid_type)
    overflow = json.loads(json.dumps(standalone_valid_timing)); overflow["totalMilliseconds"] = 10 ** 400; invalid_timings.append(overflow)
    if any(not timing_contract_failures(candidate, valid_requests, "self-test") for candidate in invalid_timings):
        return print_failure("self_test:timing_negative_case_accepted")

    def valid_report() -> dict:
        fixture_contracts = (
            ("light-2x-mixed", 3, 0.02),
            ("dark-ui", 3, 0.02),
            ("compact-ui", 2, 0.08),
            ("traditional-japanese", 2, 0.08),
            ("transparent-alpha", 1, 0.02),
        )
        fixture_recognition_ids = {
            name: f"00000000-0000-4000-8000-{index + 2:012d}"
            for index, (name, _, _) in enumerate(fixture_contracts)
        }
        fixtures = [{
            "name": name,
            "characterErrorRate": 0.0,
            "maximumCharacterErrorRate": maximum_error_rate,
            "actualLineCount": line_count,
            "expectedLineCount": line_count,
            "runsAllLineCountsValid": True,
            "coldDurationMilliseconds": 15.0,
            "durationMilliseconds": 15.0,
            "warmP95DurationMilliseconds": 15.0,
            "p95DurationMilliseconds": 15.0,
            "isColdEligible": index == 0,
            "fixtureSHA256": EXPECTED_FIXTURE_SHA256[name],
            "firstRecognitionVisionRequests": valid_requests,
            "firstRecognitionTiming": make_snapshot_timing(
                fixture_recognition_ids[name]
            ),
        } for index, (name, line_count, maximum_error_rate)
            in enumerate(fixture_contracts)]
        return {
            "measurementScope": DEFAULT_REPORT_MEASUREMENT_SCOPE,
            "fixtures": fixtures,
            "tallActualLineCount": 72,
            "tallExpectedLineCount": 72,
            "tallUniqueLineCount": 72,
            "tallDurationMilliseconds": 15.0,
            "tallRunsAllValid": True,
            "tallP95DurationMilliseconds": 15.0,
            "tallFixtureSHA256": EXPECTED_FIXTURE_SHA256["tall"],
            "fourKActualLineCount": 24,
            "fourKExpectedLineCount": 24,
            "fourKDurationMilliseconds": 15.0,
            "fourKRunsAllValid": True,
            "fourKP95DurationMilliseconds": 15.0,
            "fourKFixtureSHA256": EXPECTED_FIXTURE_SHA256["four_k"],
            "tallFirstRecognitionVisionRequests": valid_requests,
            "fourKFirstRecognitionVisionRequests": valid_requests,
            "tallFirstRecognitionTiming": make_snapshot_timing(
                "00000000-0000-4000-8000-0000000000f0"
            ),
            "fourKFirstRecognitionTiming": make_snapshot_timing(
                "00000000-0000-4000-8000-0000000000f1"
            ),
        }

    process_first_fixture_names = (
        "light-2x-mixed",
        "dark-ui",
        "compact-ui",
        "traditional-japanese",
        "transparent-alpha",
        "tall-scroll",
        "4k-screen",
    )

    def valid_process_first_report(fixture_name: str, ordinal: int) -> dict:
        fixture_sha256, expected_line_count, _ = PROCESS_FIRST_FIXTURE_CONTRACTS[
            fixture_name
        ]
        return {
            "measurementKind": "process-first-service-call",
            "recognitionOrdinal": 1,
            "fixtureName": fixture_name,
            "processIdentifier": ordinal + 1,
            "characterErrorRate": 0.0,
            "expectedLineCount": expected_line_count,
            "actualLineCount": expected_line_count,
            "coldDurationMilliseconds": 15.0,
            "fixtureSHA256": fixture_sha256,
            "firstRecognitionVisionRequests": valid_requests,
            "firstRecognitionTiming": make_snapshot_timing(
                f"00000000-0000-4000-8000-{ordinal + 0x100:012x}"
            ),
        }

    legal_process_first_reports = [
        valid_process_first_report(fixture_name, ordinal)
        for ordinal, fixture_name in enumerate(process_first_fixture_names)
    ]
    if evaluate_process_first_reports(legal_process_first_reports):
        return print_failure("self_test:process_first_legal_selections_rejected")

    unknown_process_fixture = valid_process_first_report("light-2x-mixed", 0)
    unknown_process_fixture["fixtureName"] = "unknown-fixture"
    if "report_contract:process_first_unknown_fixture:unknown-fixture" not in (
        evaluate_process_first_report(unknown_process_fixture)
    ):
        return print_failure("self_test:process_first_unknown_fixture_accepted")

    wrong_process_digest = valid_process_first_report("light-2x-mixed", 0)
    wrong_process_digest["fixtureSHA256"] = "0" * 64
    if "report_contract:fixture_sha256_mismatch:process_first:light-2x-mixed" not in (
        evaluate_process_first_report(wrong_process_digest)
    ):
        return print_failure("self_test:process_first_wrong_digest_accepted")

    missing_process_timing = valid_process_first_report("light-2x-mixed", 0)
    del missing_process_timing["firstRecognitionTiming"]
    if not any(
        failure.startswith("report_contract:process_first_fields_missing:")
        for failure in evaluate_process_first_report(missing_process_timing)
    ):
        return print_failure("self_test:process_first_missing_timing_accepted")
    invalid_process_timing = valid_process_first_report("light-2x-mixed", 0)
    invalid_process_timing["firstRecognitionTiming"] = "invalid"
    if "report_contract:timing_missing_or_invalid:process_first:light-2x-mixed" not in (
        evaluate_process_first_report(invalid_process_timing)
    ):
        return print_failure("self_test:process_first_invalid_timing_accepted")

    duplicate_process_snapshot_id = json.loads(json.dumps(legal_process_first_reports))
    duplicate_process_snapshot_id[5]["firstRecognitionTiming"] = json.loads(json.dumps(
        duplicate_process_snapshot_id[0]["firstRecognitionTiming"]
    ))
    if not any(
        failure.startswith("report_contract:recognition_id_not_unique:process_first:")
        for failure in evaluate_process_first_reports(duplicate_process_snapshot_id)
    ):
        return print_failure("self_test:process_first_duplicate_snapshot_id_accepted")

    malformed_process_snapshot_id = valid_process_first_report("light-2x-mixed", 0)
    malformed_process_snapshot_id["firstRecognitionTiming"]["recognitionID"] = (
        "00000000-0000-0000-0000-000000000100"
    )
    if "report_contract:recognition_id_invalid:process_first:light-2x-mixed" not in (
        evaluate_process_first_report(malformed_process_snapshot_id)
    ):
        return print_failure("self_test:process_first_snapshot_id_format_accepted")

    process_outer_service_mismatch = valid_process_first_report("light-2x-mixed", 0)
    process_outer_service_mismatch["coldDurationMilliseconds"] = 7_999.0
    if not any(
        failure.startswith(
            "report_contract:first_recognition_timing_correlation:"
            "process_first:light-2x-mixed:"
        )
        for failure in evaluate_process_first_report(process_outer_service_mismatch)
    ):
        return print_failure("self_test:process_first_outer_service_mismatch_accepted")

    def correlation_reference_report() -> dict:
        report = json.loads(json.dumps(valid_report()))
        timings = [
            *(fixture["firstRecognitionTiming"] for fixture in report["fixtures"]),
            report["tallFirstRecognitionTiming"],
            report["fourKFirstRecognitionTiming"],
        ]
        for timing in timings:
            timing["totalMilliseconds"] = 1_000.0
            timing["serviceUnattributedMilliseconds"] = 989.5
        for fixture in report["fixtures"]:
            fixture["coldDurationMilliseconds"] = 1_050.0
            fixture["durationMilliseconds"] = 1_050.0
        report["tallDurationMilliseconds"] = 1_050.0
        report["fourKDurationMilliseconds"] = 1_050.0
        return report

    def set_outer_duration(report: dict, scope: str, value: float) -> None:
        if scope.startswith("fixture:"):
            fixture = report["fixtures"][0]
            fixture["coldDurationMilliseconds"] = value
            fixture["durationMilliseconds"] = value
        elif scope == "tall":
            report["tallDurationMilliseconds"] = value
        else:
            report["fourKDurationMilliseconds"] = value

    def fixture_sha256_for_self_test(
        name: str,
        lines: tuple[str, ...],
        font_size: int,
        width: int,
        height: int,
        line_step: int,
        foreground: tuple[str, str, str, str],
        background: tuple[str, str, str, str],
    ) -> str:
        fields = [
            ("schemaVersion", "blocks-ocr-quality-fixture-v1"),
            ("name", name),
            ("lineCount", str(len(lines))),
            *((f"line[{index}]", line) for index, line in enumerate(lines)),
            ("fontName", "system"),
            ("fontSize", str(font_size)),
            ("canvasWidth", str(width)),
            ("canvasHeight", str(height)),
            ("lineStep", str(line_step)),
            ("foregroundRed", foreground[0]),
            ("foregroundGreen", foreground[1]),
            ("foregroundBlue", foreground[2]),
            ("foregroundAlpha", foreground[3]),
            ("backgroundRed", background[0]),
            ("backgroundGreen", background[1]),
            ("backgroundBlue", background[2]),
            ("backgroundAlpha", background[3]),
            ("colorSpace", "sRGB"),
            ("bitsPerComponent", "8"),
            ("bytesPerRow", "0"),
            ("bitmapAlphaInfo", "premultipliedLast"),
            ("graphicsContextFlipped", "false"),
            ("textRenderer", "NSString.draw"),
            ("textOriginX", "72"),
            ("textTopInset", "100"),
        ]
        payload = bytearray()
        for key, value in fields:
            for part in (key, value):
                encoded = part.encode("utf-8")
                payload.extend(len(encoded).to_bytes(8, "big"))
                payload.extend(encoded)
        return hashlib.sha256(payload).hexdigest()

    light_fixture_lines = (
        "Blocks 截图文字识别",
        "The quick brown fox 1234567890",
        "スクリーンショット文字認識",
    )
    if fixture_sha256_for_self_test(
        "light-2x-mixed", light_fixture_lines, 36, 1_600, 720, 150,
        ("0", "0", "0", "1"), ("1", "1", "1", "1"),
    ) != EXPECTED_FIXTURE_SHA256["light-2x-mixed"]:
        return print_failure("self_test:fixture_sha256_constant_drift")
    if evaluate_report(valid_report()):
        return print_failure("self_test:fixture_sha256_or_recognition_id_legal_case_rejected")

    missing_measurement_scope = valid_report()
    del missing_measurement_scope["measurementScope"]
    if "report_contract:measurement_scope_missing" not in evaluate_report(
        missing_measurement_scope
    ):
        return print_failure("self_test:measurement_scope_missing_accepted")
    invalid_measurement_scope_type = valid_report()
    invalid_measurement_scope_type["measurementScope"] = 1
    if "report_contract:measurement_scope_type" not in evaluate_report(
        invalid_measurement_scope_type
    ):
        return print_failure("self_test:measurement_scope_type_accepted")
    invalid_measurement_scope_value = valid_report()
    invalid_measurement_scope_value["measurementScope"] = "system-cold"
    if "report_contract:measurement_scope_value" not in evaluate_report(
        invalid_measurement_scope_value
    ):
        return print_failure("self_test:measurement_scope_value_accepted")

    fixture_text_mutation = valid_report()
    fixture_text_mutation["fixtures"][0]["fixtureSHA256"] = fixture_sha256_for_self_test(
        "light-2x-mixed",
        (light_fixture_lines[0], "simple ascii line", light_fixture_lines[2]),
        36, 1_600, 720, 150,
        ("0", "0", "0", "1"), ("1", "1", "1", "1"),
    )
    if not any(
        failure == "report_contract:fixture_sha256_mismatch:fixture:light-2x-mixed"
        for failure in evaluate_report(fixture_text_mutation)
    ):
        return print_failure("self_test:fixture_sha256_text_mutation_accepted")

    for timing_field, scope in (
        ("tallFirstRecognitionTiming", "tall"),
        ("fourKFirstRecognitionTiming", "four_k"),
    ):
        copied_snapshot_timing = valid_report()
        copied_snapshot_timing[timing_field] = json.loads(json.dumps(
            copied_snapshot_timing["fixtures"][0]["firstRecognitionTiming"]
        ))
        if not any(
            failure == f"report_contract:recognition_id_not_unique:{scope}"
            for failure in evaluate_report(copied_snapshot_timing)
        ):
            return print_failure(
                "self_test:recognition_id_copied_timing_accepted:" + scope
            )

    missing_recognition_id = valid_report()
    del missing_recognition_id["fixtures"][0]["firstRecognitionTiming"]["recognitionID"]
    if not any(
        failure.startswith(
            "report_contract:timing_fields_missing:fixture:light-2x-mixed:"
        )
        for failure in evaluate_report(missing_recognition_id)
    ):
        return print_failure("self_test:recognition_id_missing_accepted")
    invalid_recognition_id = valid_report()
    invalid_recognition_id["fixtures"][0]["firstRecognitionTiming"]["recognitionID"] = 1
    if "report_contract:recognition_id_invalid:fixture:light-2x-mixed" not in evaluate_report(
        invalid_recognition_id
    ):
        return print_failure("self_test:recognition_id_type_accepted")
    malformed_recognition_id = valid_report()
    malformed_recognition_id["fixtures"][0]["firstRecognitionTiming"]["recognitionID"] = (
        "00000000-0000-0000-0000-000000000001"
    )
    if "report_contract:recognition_id_invalid:fixture:light-2x-mixed" not in evaluate_report(
        malformed_recognition_id
    ):
        return print_failure("self_test:recognition_id_format_accepted")

    if evaluate_report(correlation_reference_report()):
        return print_failure("self_test:timing_correlation_legal_case_rejected")
    measurement_underrun_within_tolerance = correlation_reference_report()
    for scope in ("fixture:light-2x-mixed", "tall", "four_k"):
        set_outer_duration(measurement_underrun_within_tolerance, scope, 999.0)
    if evaluate_report(measurement_underrun_within_tolerance):
        return print_failure("self_test:timing_correlation_underrun_tolerance_rejected")
    correlation_negative_cases = (
        ("fixture:light-2x-mixed", 760.0, "under_coverage"),
        ("tall", 1_300.0, "excessive_overhead"),
        ("four_k", 998.99, "underrun_exceeds_tolerance"),
    )
    for scope, outer_duration, case in correlation_negative_cases:
        candidate = correlation_reference_report()
        set_outer_duration(candidate, scope, outer_duration)
        if not any(
            failure.startswith(
                "report_contract:first_recognition_timing_correlation:"
                f"{scope}:"
            )
            for failure in evaluate_report(candidate)
        ):
            return print_failure(
                "self_test:timing_correlation_negative_case_accepted:"
                + case
            )
    severe_mismatch_reports = []
    fixture_mismatch = valid_report()
    fixture_mismatch["fixtures"][0]["coldDurationMilliseconds"] = 7_999.0
    fixture_mismatch["fixtures"][0]["durationMilliseconds"] = 7_999.0
    severe_mismatch_reports.append((fixture_mismatch, "fixture:light-2x-mixed"))
    tall_mismatch = valid_report()
    tall_mismatch["tallDurationMilliseconds"] = 7_999.0
    severe_mismatch_reports.append((tall_mismatch, "tall"))
    four_k_mismatch = valid_report()
    four_k_mismatch["fourKDurationMilliseconds"] = 7_999.0
    severe_mismatch_reports.append((four_k_mismatch, "four_k"))
    for severe_mismatch_report, scope in severe_mismatch_reports:
        if not any(
            failure.startswith(
                "report_contract:first_recognition_timing_correlation:"
                f"{scope}:"
            )
            for failure in evaluate_report(severe_mismatch_report)
        ):
            return print_failure(
                "self_test:timing_correlation_severe_mismatch_accepted:"
                + scope
            )
    invalid_outer_duration_report = valid_report()
    invalid_outer_duration_report["fixtures"][0]["coldDurationMilliseconds"] = 10 ** 400
    if not any(
        failure.startswith(
            "report_contract:fixture_numeric_fields_invalid:light-2x-mixed:"
        )
        for failure in evaluate_report(invalid_outer_duration_report)
    ):
        return print_failure("self_test:timing_correlation_invalid_outer_accepted")
    if any(
        not vision_request_contract_failures(
            report.get("tallFirstRecognitionVisionRequests") if scope == "tall"
            else report.get("fourKFirstRecognitionVisionRequests") if scope == "four_k"
            else report["fixtures"][0].get("firstRecognitionVisionRequests"),
            scope,
        )
        for report, scope in invalid_scoped_reports
    ) or any(
        not vision_request_contract_failures(requests, "self-test")
        for requests in invalid_request_lists
    ):
        return print_failure("self_test:vision_request_contract_negative_case_accepted")
    print(json.dumps({"gate": "P18-OCR", "status": "pass", "selfTest": True}))
    return 0


def main() -> int:
    try:
        with tempfile.TemporaryDirectory(prefix="blocks-ocr-quality-") as directory:
            binary = Path(directory) / "blocks-ocr-quality-corpus"
            compile_result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-parse-as-library",
                    str(SERVICE),
                    str(CORPUS),
                    "-framework",
                    "AppKit",
                    "-framework",
                    "Vision",
                    "-framework",
                    "ImageIO",
                    "-o",
                    str(binary),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
            if compile_result.returncode != 0:
                return print_failure("compile_failed:" + compile_result.stderr[-2_000:])

            run_result = subprocess.run(
                [str(binary)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
    except subprocess.TimeoutExpired as error:
        phase = "compile" if error.timeout == 120 else "corpus"
        return print_failure(f"{phase}_timed_out:{error.timeout}s")
    except OSError as error:
        return print_failure(f"execution_failed:{type(error).__name__}")

    if run_result.returncode != 0:
        return print_failure("corpus_failed:" + run_result.stderr[-2_000:])

    try:
        report = json.loads(
            run_result.stdout,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"invalid JSON constant: {value}")
            ),
        )
    except (json.JSONDecodeError, TypeError, ValueError):
        return print_failure("report_contract:invalid_json")
    if not isinstance(report, dict):
        return print_failure("report_contract:root_not_object")

    try:
        failures = evaluate_report(report)
    except Exception as error:
        return print_failure(
            "report_contract:evaluation_failed:" + type(error).__name__
        )

    print(json.dumps({
        "gate": "P18-OCR",
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "report": report,
    }, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


def print_failure(failure: str) -> int:
    print(json.dumps({
        "gate": "P18-OCR",
        "status": "fail",
        "failures": [failure],
    }, ensure_ascii=False, indent=2))
    return 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        raise SystemExit(run_contract_self_test())
    raise SystemExit(main())
