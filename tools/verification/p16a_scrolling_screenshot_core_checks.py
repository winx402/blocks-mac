#!/usr/bin/env python3
"""P16-A scrolling screenshot Core algorithms and fixture gate."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "apps/Blocks/BlocksScreenshotCore"
TESTS = ROOT / "apps/Blocks/BlocksScreenshotCoreTests"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def main() -> int:
    failures: list[dict[str, object]] = []
    required = {
        CORE / "ScrollingScreenshotModels.swift": [
            "ScrollingScreenshotSessionState",
            "ScrollingStitchDecision",
            "ScrollingScreenshotRecoveryReason",
            "lumaSamples",
            "minimumMatchedBlockRatio",
        ],
        CORE / "ScrollingScreenshotMatcher.swift": [
            "ambiguousOverlap",
            "reverseScroll",
            "fixedHeaderRows",
            "fixedFooterRows",
            "coarseSimilarity",
            "refinedAlignment",
            "blockSimilarity",
            "footerInsetCandidates",
            "allowsAsymmetricReplacement",
        ],
        CORE / "ScrollingScreenshotAssembler.swift": [
            "ScrollingScreenshotAssemblyDecision",
            "sizePolicy.assess",
            "lastAcceptedFrame",
        ],
        CORE / "ScrollingScreenshotSizePolicy.swift": [
            "absoluteMaximumDimension = 32_768",
            "absoluteMaximumPixelCount = 120_000_000",
            "effectiveMaximumDimension = 16_384",
            "effectiveMaximumPixelCount = 64_000_000",
            "warningFraction: Double = 0.9",
        ],
        TESTS / "ScrollingScreenshotMatcherTests.swift": [
            "testRepeatedTextureWithTwoPlausibleOffsetsIsAmbiguous",
            "testStableFixedHeaderIsRemovedOnlyAfterUniqueContentOverlap",
            "testStableHeaderAndFooterAreExcludedFromAppendedRows",
            "testChangingFooterIsRejectedInsteadOfBeingClassifiedAsFixed",
            "testChangedKnownFooterUsesPreviousFooterAsReplaceableTail",
            "testBrowserRenderedDescriptorsMatchWithinInteractiveBudget",
            "testLargeRepeatedBlankRegionIsRejectedInsteadOfGuessingAnOffset",
            "testSparseDynamicRowsDoNotInvalidateAnOtherwiseUniqueOverlap",
            "testWidespreadDynamicRowsRemainFailClosed",
            "testTwoDimensionalConsensusIgnoresFixedSidebarAndLocalAnimation",
            "testExpectedScrollPriorDisambiguatesRepeatedDocumentRows",
            "testLargeViewportMatcherStaysWithinInteractiveBudget",
        ],
        TESTS / "ScrollingScreenshotAssemblerTests.swift": [
            "testVerticalFramesAssembleToIndependentGroundTruth",
            "testReverseFrameIsRejectedAndNextForwardFrameRecoversFromLastAcceptedFrame",
            "testDelayedLazyContentAfterUnchangedFrameContinuesFromLastAcceptedAnchor",
            "testFixedFooterReservesItsFinalPositionBeforeWritingNewRows",
            "testChangedFixedFooterIsReplacedWithoutLeavingASeam",
            "testSizeLimitStopsBeforeWritingAndPreservesPartialResult",
        ],
    }
    for path, markers in required.items():
        source = read(path)
        missing = [marker for marker in markers if marker not in source]
        if missing:
            failures.append({"check": str(path.relative_to(ROOT)), "missing": missing})

    if not failures:
        with tempfile.TemporaryDirectory(prefix="blocks-p16a-") as derived:
            result = subprocess.run(
                [
                    "xcodebuild", "-quiet", "-project", str(PROJECT),
                    "-scheme", "BlocksScreenshotCoreTests",
                    "-derivedDataPath", derived,
                    "-destination", "platform=macOS",
                    "CODE_SIGNING_ALLOWED=NO", "test",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=300,
                check=False,
            )
        if result.returncode:
            failures.append({"check": "core_xctest", "tail": result.stdout.splitlines()[-40:]})

    print(json.dumps({
        "gate": "P16-A",
        "status": "fail" if failures else "pass",
        "failures": failures,
        "observations": {
            "ground_truth": "independent 2D luminance fixtures",
            "limits": {
                "absolute_dimension": 32768,
                "absolute_pixels": 120000000,
                "effective_dimension": 16384,
                "effective_pixels": 64000000,
                "warning_fraction": 0.9,
            },
        },
    }, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
