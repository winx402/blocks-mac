#!/usr/bin/env python3
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


checks = {
    "database_v11": (
        "currentVersion < 11",
        "migrateV11()",
        "origin_kind",
        "is_enabled",
    ),
    "history_transaction": (
        "commitScreenshotHistory",
        "ScreenshotHistoryCommitRequest",
        "validatedScreenshotPNG",
        "visual_signature_sha256",
        "png_payload_sha256",
        "beforeDuplicateDelete",
        "beforeSQLiteCommit",
        "beforeSidecarPromote",
    ),
    "recoverable_sidecars": ("func stage", "func promote", "func abort", "func recover"),
    "repository_tests": (
        "testDuplicateCommitKeepsCurrentID",
        "testPreCommitFailurePointsRollbackDatabaseFTSAndStaging",
        "testPostCommitPromotionFailureIsRecoveredOnRepositoryRestart",
        "testStartupRecoveryFailureSkipsCleanupAndPublishesLowSensitivityStatus",
        "testOCRRetryPreparationTransitionsOnlyRetryableStateWithoutIncrementingAttempts",
        "testVersionElevenBackfillsScreenshotOriginFromExistingSystemTag",
        "testScreenshotTagCanBeHiddenWithoutDeletingOriginsAndReenableDerivesAllHistory",
        "testDisablingScreenshotTagDoesNotDeleteMaterializedAssociations",
        "testScreenshotQueriesAndEligibilityUseOriginInsteadOfTagMembership",
    ),
    "startup_maintenance": (
        "performScreenshotHistoryStartupMaintenance",
        "screenshotHistoryRecoverySucceeded",
        "ScreenshotHistoryMaintenanceStatus",
        "sidecar_recovery_failed",
        "prepareOCRRetry",
    ),
}

sources = {
    "database_v11": read("apps/Blocks/BlocksCore/AppDatabase.swift"),
    "history_transaction": read("apps/Blocks/BlocksCore/ClipboardRepository+ScreenshotHistory.swift"),
    "recoverable_sidecars": read("apps/Blocks/BlocksCore/BlobStore.swift"),
    "repository_tests": read("apps/Blocks/BlocksAppTests/ClipboardScreenshotHistoryRepositoryTests.swift"),
    "startup_maintenance": read("apps/Blocks/BlocksCore/ClipboardRepository.swift"),
}

history_coordinator = read(
    "apps/Blocks/BlocksApp/Features/Screenshot/Output/ScreenshotHistoryCoordinator.swift"
)

failures = []
for name, markers in checks.items():
    missing = [marker for marker in markers if marker not in sources[name]]
    if missing:
        failures.append({"check": name, "missing": missing})

if "png.base64EncodedString()" in history_coordinator:
    failures.append({"check": "history_commit_must_not_base64_round_trip_png"})
if "normalizedPNGData" in sources["history_transaction"]:
    failures.append({"check": "history_commit_must_not_reencode_full_png"})

xctest_command = [
    "xcodebuild",
    "test",
    "-quiet",
    "-project",
    str(ROOT / "apps/Blocks/Blocks.xcodeproj"),
    "-scheme",
    "BlocksAppTests",
    "-destination",
    "platform=macOS",
    "-only-testing:BlocksAppTests/ClipboardScreenshotHistoryRepositoryTests",
    "CODE_SIGNING_ALLOWED=NO",
]
with tempfile.TemporaryDirectory(prefix="blocks-p15a-") as derived_data:
    xctest_command[2:2] = ["-derivedDataPath", derived_data]
    xctest = subprocess.run(
        xctest_command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )

if xctest.returncode != 0:
    output_lines = xctest.stdout.splitlines()
    diagnostics = [
        line for line in output_lines
        if " error:" in line
        or line.startswith("Testing failed:")
        or line.startswith("** TEST FAILED **")
    ]
    evidence = diagnostics[-20:] or output_lines[-40:]
    failures.append({
        "check": "repository_xctest",
        "exit_code": xctest.returncode,
        "diagnostics": [line[:1000] for line in evidence],
    })

print(json.dumps({
    "gate": "P15-A",
    "status": "fail" if failures else "pass",
    "failures": failures,
    "observations": {
        "guarantee": "sqlite_atomic_filesystem_recoverable",
        "xctest": {
            "target": "BlocksAppTests/ClipboardScreenshotHistoryRepositoryTests",
            "exit_code": xctest.returncode,
            "executed": True,
        },
    },
}, ensure_ascii=False, indent=2))
raise SystemExit(1 if failures else 0)
