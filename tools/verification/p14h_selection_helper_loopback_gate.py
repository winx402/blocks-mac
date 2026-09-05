#!/usr/bin/env python3
"""P14-H: run the Selection Helper loopback XCTest cases on a test-only host."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from verification_build_helpers import run_controlled_subprocess, run_controlled_xcode_test


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"
SCHEME = "BlocksAppTestsNetwork"
TEST_SOURCE = ROOT / "apps/Blocks/BlocksAppTests/TranslationEntryBridgeTests.swift"
TIMEOUT_SECONDS = 180
EXPECTED_TEST_COUNT = 13
_CONTROLLED_HOST_PROBE = (
    "BlocksAppTests/TranslationEntryBridgeTests/"
    "testControlledXCTestHostInheritsVerificationTokenWhenRequired"
)


def acceptable_xcode_build_cleanup(result: dict[str, object]) -> bool:
    """Accept only Xcode's known detached ibtoold after verified cleanup."""
    cleanup = result.get("process_cleanup")
    if result.get("timed_out") or not isinstance(cleanup, dict):
        return False
    processes = cleanup.get("residual_processes")
    return (
        cleanup.get("status") == "target_group_residual_cleaned"
        and cleanup.get("child_returncode") == 0
        and isinstance(processes, list)
        and 1 <= len(processes) <= 4
        and cleanup.get("residual_process_count") == len(processes)
        and all(
            isinstance(process, dict)
            and process.get("executable") == "ibtoold"
            and process.get("ppid") == 1
            for process in processes
        )
    )


def run(
    command: list[str],
    timeout: int = TIMEOUT_SECONDS,
    *,
    allow_xcode_ibtoold_cleanup: bool = False,
    controlled_xctest: bool = False,
) -> tuple[int, str, dict[str, object] | None]:
    """Run through the shared bounded process-tree supervisor."""
    runner = run_controlled_xcode_test if controlled_xctest else run_controlled_subprocess
    result = runner(
        command,
        cwd=ROOT,
        timeout=timeout,
        termination_grace_seconds=10.0,
    )
    output = result.get("stdout", "") + result.get("stderr", "")
    if result.get("output_diagnostic"):
        output += "\n" + str(result["output_diagnostic"])
    process_metadata = {
        key: result[key]
        for key in ["process_cleanup", "output_truncation"]
        if key in result
    }
    if process_metadata:
        output += "\ncontrolled_process_metadata=" + json.dumps(
            process_metadata, ensure_ascii=True, sort_keys=True
        )
    accepted_cleanup = (
        result.get("process_cleanup")
        if allow_xcode_ibtoold_cleanup and acceptable_xcode_build_cleanup(result)
        else None
    )
    if accepted_cleanup is not None:
        return 0, output, accepted_cleanup
    returncode = result.get("returncode")
    if isinstance(returncode, int):
        return returncode, output, None
    return (124 if result.get("timed_out") else 1), output, None


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def expected_tests(source: str) -> list[str]:
    """Find every test explicitly gated by requireSelectionHelperReceiverNetworkTests."""
    matches = re.findall(
        r"\n    func (test[A-Za-z0-9_]+)[^{]*\{(?P<body>.*?)(?=\n    func |\n}\n|\Z)",
        source,
        re.DOTALL,
    )
    names = [
        name
        for name, body in matches
        if name != "testControlledXCTestHostInheritsVerificationTokenWhenRequired"
        and "requireSelectionHelperReceiverNetworkTests()" in body
    ]
    require(
        len(names) == EXPECTED_TEST_COUNT - 1,
        f"expected {EXPECTED_TEST_COUNT - 1} Selection Helper receiver network tests, found {len(names)}",
    )
    require(
        "func testControlledXCTestHostInheritsVerificationTokenWhenRequired()" in source,
        "controlled XCTest host token probe is missing",
    )
    return [
        *[f"BlocksAppTests/TranslationEntryBridgeTests/{name}" for name in names],
        _CONTROLLED_HOST_PROBE,
    ]


def find_xctestrun(derived_data: Path) -> Path:
    candidates = sorted(derived_data.rglob("*.xctestrun"))
    require(len(candidates) == 1, f"expected exactly one generated xctestrun, found {len(candidates)}")
    return candidates[0]


def test_target_from_xctestrun(xctestrun: Path) -> dict[str, object]:
    payload = plistlib.loads(xctestrun.read_bytes())
    targets = [
        target
        for configuration in payload.get("TestConfigurations", [])
        for target in configuration.get("TestTargets", [])
        if target.get("BlueprintName") == "BlocksAppTests"
    ]
    require(len(targets) == 1, "generated xctestrun must contain exactly one BlocksAppTests target")
    return targets[0]


def test_host_from_xctestrun(xctestrun: Path) -> Path:
    target = test_target_from_xctestrun(xctestrun)
    value = target.get("TestHostPath")
    require(isinstance(value, str), "generated xctestrun does not describe the Blocks test host")
    app = Path(value.replace("__TESTROOT__", str(xctestrun.parent)))
    return app / "Contents/MacOS/Blocks"


def verify_xctestrun_environment(xctestrun: Path) -> None:
    environment = test_target_from_xctestrun(xctestrun).get("EnvironmentVariables", {})
    require(isinstance(environment, dict), "generated xctestrun environment is malformed")
    for key in ["BLOCKS_UNIT_TESTING", "BLOCKS_HELPER_RECEIVER_NETWORK_TESTS"]:
        require(environment.get(key) == "1", f"generated xctestrun is missing {key}=1")


def validate_xcresult_payloads(
    summary: dict[str, object],
    tests: dict[str, object],
    expected: list[str],
) -> dict[str, int]:
    discovered: dict[str, str] = {}

    def visit(value: object) -> None:
        if isinstance(value, dict):
            if value.get("nodeType") == "Test Case":
                identifier = value.get("nodeIdentifier")
                result = value.get("result")
                require(
                    isinstance(identifier, str) and isinstance(result, str),
                    "xcresult contains a malformed test case",
                )
                selector = "BlocksAppTests/" + identifier.removesuffix("()")
                require(selector not in discovered, f"xcresult duplicated test case: {selector}")
                discovered[selector] = result
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(tests)
    expected_set = set(expected)
    discovered_set = set(discovered)
    require(
        discovered_set == expected_set,
        "xcresult test set mismatch; missing="
        + ",".join(sorted(expected_set - discovered_set))
        + "; unexpected="
        + ",".join(sorted(discovered_set - expected_set)),
    )
    nonpassing = {
        selector: result
        for selector, result in discovered.items()
        if result != "Passed"
    }
    require(not nonpassing, "xcresult contains non-passing tests: " + json.dumps(nonpassing))
    require(
        summary.get("result") == "Passed"
        and summary.get("totalTestCount") == len(expected)
        and summary.get("passedTests") == len(expected)
        and summary.get("failedTests") == 0
        and summary.get("skippedTests") == 0,
        "xcresult summary does not prove an exact all-pass run",
    )
    return {
        "verified_test_count": len(discovered),
        "failed_test_count": 0,
        "skipped_test_count": 0,
    }


def verify_xcresult(result_bundle: Path, expected: list[str]) -> dict[str, int]:
    payloads: dict[str, dict[str, object]] = {}
    for kind in ["summary", "tests"]:
        completed = run_controlled_subprocess(
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                kind,
                "--path",
                str(result_bundle),
            ],
            cwd=ROOT,
            timeout=30,
            termination_grace_seconds=2.0,
        )
        require(
            completed.get("ok") is True and not completed.get("timed_out"),
            f"cannot read xcresult {kind}",
        )
        value = json.loads(str(completed.get("stdout", "")))
        require(isinstance(value, dict), f"xcresult {kind} payload is malformed")
        payloads[kind] = value
    return validate_xcresult_payloads(payloads["summary"], payloads["tests"], expected)


def verify_host_entitlements(
    test_host: Path,
    *,
    runner=run_controlled_subprocess,
) -> None:
    require(test_host.is_file(), f"xctestrun test host is missing: {test_host}")
    result = runner(
        ["codesign", "-d", "--entitlements", ":-", str(test_host)],
        cwd=ROOT,
        timeout=30,
        termination_grace_seconds=2.0,
    )
    require(
        result.get("ok") is True and not result.get("timed_out"),
        "cannot read signed test-host entitlements",
    )
    entitlements = plistlib.loads(str(result.get("stdout", "")).encode("utf-8"))
    for key in [
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
        "com.apple.security.network.server",
    ]:
        require(entitlements.get(key) is True, f"test host entitlement is not true: {key}")


def static_self_test() -> None:
    scheme = ET.parse(
        PROJECT / "xcshareddata/xcschemes/BlocksAppTestsNetwork.xcscheme"
    ).getroot()
    test_action = scheme.find("./TestAction[@buildConfiguration='DebugTesting']")
    require(test_action is not None, "network scheme must use DebugTesting")
    require(
        test_action.attrib.get("shouldUseLaunchSchemeArgsEnv") == "NO",
        "network scheme must use its TestAction environment",
    )
    network_environment = test_action.find(
        "./EnvironmentVariables/EnvironmentVariable[@key='BLOCKS_HELPER_RECEIVER_NETWORK_TESTS']"
    )
    require(
        network_environment is not None
        and network_environment.attrib.get("value") == "1"
        and network_environment.attrib.get("isEnabled") == "YES",
        "network scheme does not enable network tests",
    )
    source = TEST_SOURCE.read_text()
    tests = expected_tests(source)
    require(len(tests) == EXPECTED_TEST_COUNT, "network fixture count drifted")
    try:
        expected_tests(
            source.replace(
                "try requireSelectionHelperReceiverNetworkTests()",
                "",
                1,
            )
        )
    except RuntimeError:
        pass
    else:
        raise RuntimeError("removing one gated test must fail the fixed-count contract")
    known_cleanup = {
        "timed_out": False,
        "process_cleanup": {
            "status": "target_group_residual_cleaned",
            "child_returncode": 0,
            "residual_process_count": 1,
            "residual_processes": [{"executable": "ibtoold", "ppid": 1}],
        },
    }
    require(acceptable_xcode_build_cleanup(known_cleanup), "known ibtoold cleanup must be accepted")
    for mutation in [
        {**known_cleanup, "timed_out": True},
        {**known_cleanup, "process_cleanup": {**known_cleanup["process_cleanup"], "child_returncode": 1}},
        {**known_cleanup, "process_cleanup": {**known_cleanup["process_cleanup"], "residual_processes": [{"executable": "unknown", "ppid": 1}]}},
        {**known_cleanup, "process_cleanup": {**known_cleanup["process_cleanup"], "residual_process_count": 5, "residual_processes": [{"executable": "ibtoold", "ppid": 1}] * 5}},
    ]:
        require(not acceptable_xcode_build_cleanup(mutation), "unknown cleanup must fail closed")
    fixture_expected = ["BlocksAppTests/TranslationEntryBridgeTests/testFixture"]
    fixture_summary = {
        "result": "Passed",
        "totalTestCount": 1,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
    }
    fixture_tests = {
        "testNodes": [
            {
                "nodeType": "Test Case",
                "nodeIdentifier": "TranslationEntryBridgeTests/testFixture()",
                "result": "Passed",
            }
        ]
    }
    validate_xcresult_payloads(fixture_summary, fixture_tests, fixture_expected)
    try:
        validate_xcresult_payloads(fixture_summary, {"testNodes": []}, fixture_expected)
    except RuntimeError:
        pass
    else:
        raise RuntimeError("selector text without an xcresult test case must fail")

    with tempfile.TemporaryDirectory(prefix="blocks-p14h-codesign-timeout-") as directory:
        test_host = Path(directory) / "Blocks"
        test_host.touch()
        captured_timeout: list[int] = []

        def timed_out_runner(
            _command: list[str],
            *,
            cwd: Path,
            timeout: int,
            termination_grace_seconds: float,
        ) -> dict[str, object]:
            require(cwd == ROOT, "codesign timeout fixture used the wrong working directory")
            require(
                termination_grace_seconds == 2.0,
                "codesign timeout fixture used the wrong termination grace",
            )
            captured_timeout.append(timeout)
            return {"ok": False, "timed_out": True, "returncode": None}

        try:
            verify_host_entitlements(test_host, runner=timed_out_runner)
        except RuntimeError as error:
            require(
                str(error) == "cannot read signed test-host entitlements",
                "codesign timeout did not fail with the expected gate error",
            )
        else:
            raise RuntimeError("codesign timeout must fail closed")
        require(captured_timeout == [30], "codesign must use a 30-second timeout")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--result-bundle-path")
    args = parser.parse_args()
    failures: list[dict[str, str]] = []
    evidence: dict[str, object] = {}
    try:
        static_self_test()
        if args.self_test:
            print(json.dumps({"gate": "P14-H", "status": "pass", "mode": "static-self-test"}, indent=2))
            return 0
        expected = expected_tests(TEST_SOURCE.read_text())
        evidence["expected_test_count"] = len(expected)
        with tempfile.TemporaryDirectory(prefix="blocks-p14h-loopback-derived-data-") as directory:
            derived_data = Path(directory)
            build = ["xcodebuild", "-project", str(PROJECT), "-scheme", SCHEME, "-configuration", "DebugTesting", "-derivedDataPath", str(derived_data), "-destination", "platform=macOS", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "build-for-testing"]
            code, output, accepted_cleanup = run(
                build, allow_xcode_ibtoold_cleanup=True
            )
            if accepted_cleanup is not None:
                # A verified, cleaned detached ibtoold permits one incremental
                # retry; it is not itself build PASS evidence.
                evidence["build_first_attempt_process_cleanup"] = accepted_cleanup
                code, output, _ = run(build)
            require(
                code == 0,
                "build-for-testing failed or retained a process after retry:\n"
                + "\n".join(output.splitlines()[-80:]),
            )
            xctestrun = find_xctestrun(derived_data)
            verify_xctestrun_environment(xctestrun)
            verify_host_entitlements(test_host_from_xctestrun(xctestrun))
            result_bundle = (
                Path(args.result_bundle_path).expanduser().resolve()
                if args.result_bundle_path
                else derived_data / "P14H.xcresult"
            )
            require(result_bundle.parent.is_dir(), "result bundle parent directory is missing")
            require(not result_bundle.exists(), f"result bundle path already exists: {result_bundle}")
            test = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", "platform=macOS", "-resultBundlePath", str(result_bundle), *[f"-only-testing:{name}" for name in expected]]
            code, output, _ = run(test, controlled_xctest=True)
            require(code == 0, "loopback tests failed:\n" + "\n".join(output.splitlines()[-120:]))
            evidence.update(verify_xcresult(result_bundle, expected))
            if args.result_bundle_path:
                evidence["result_bundle_path"] = str(result_bundle)
    except (
        OSError,
        RuntimeError,
        plistlib.InvalidFileException,
        json.JSONDecodeError,
    ) as error:
        failures.append({"code": "selection_helper_loopback_gate_failed", "detail": str(error)})
    print(json.dumps({"gate": "P14-H", "status": "pass" if not failures else "fail", "failures": failures, **evidence}, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
