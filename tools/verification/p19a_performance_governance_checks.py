#!/usr/bin/env python3
"""P19-A focused performance-governance source and documentation gate."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BLOCKS = ROOT / "apps" / "Blocks"
CAPTURE_ADAPTER = (
    BLOCKS
    / "BlocksApp"
    / "Features"
    / "Screenshot"
    / "Capture"
    / "ScreenCaptureKitAdapter.swift"
)
SELECTION = (
    BLOCKS
    / "BlocksApp"
    / "Features"
    / "Screenshot"
    / "Capture"
    / "ScreenshotSelectionController.swift"
)
PRESENTER = (
    BLOCKS
    / "BlocksApp"
    / "Features"
    / "Screenshot"
    / "Editor"
    / "ScreenshotEditorPresenter.swift"
)
MODEL = BLOCKS / "BlocksApp" / "Models" / "ScreenshotCapture.swift"
CLIPBOARD = BLOCKS / "BlocksApp" / "Services" / "ClipboardLiveCaptureService.swift"
DOC = (
    ROOT
    / "docs"
    / "项目管理库"
    / "009_Blocks稳定性与性能收口"
    / "架构与审查记录.md"
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(
    condition: bool,
    code: str,
    detail: str,
    failures: list[dict[str, str]],
) -> None:
    if not condition:
        failures.append({"code": code, "detail": detail})


def main() -> int:
    failures: list[dict[str, str]] = []
    adapter = read(CAPTURE_ADAPTER)
    selection = read(SELECTION)
    presenter = read(PRESENTER)
    model = read(MODEL)
    clipboard = read(CLIPBOARD)
    doc = read(DOC)

    require(
        selection.find("let snapshot = try await task.value")
        < selection.find("showSelectionSurfaces()"),
        "frozen_snapshot_after_overlay",
        "initial frozen snapshot must complete before the overlay is shown",
        failures,
    )
    require(
        "self.selectionGeneration == generation" in selection
        and "self.continuation != nil else { return }" in selection
        and "selectionGeneration &+= 1" in selection
        and "testFrozenSelectionCancellationDoesNotWaitForNonCooperativeSnapshot" in read(
            BLOCKS / "BlocksAppTests" / "ScreenshotAppStateTests.swift"
        )
        and "testFrozenSelectionTimeoutDoesNotWaitForNonCooperativeSnapshot" in read(
            BLOCKS / "BlocksAppTests" / "ScreenshotAppStateTests.swift"
        ),
        "cancelled_frozen_snapshot_can_restore_overlay",
        "an uncooperative frozen snapshot must not show the overlay after cancel",
        failures,
    )
    require(
        "captureWindowFromDisplaySnapshot" in adapter
        and "captureLiveWindow" not in adapter
        and "selectedFrozenSnapshot != nil" in adapter,
        "interactive_capture_not_single_source",
        "interactive window/region/display paths must share display snapshots",
        failures,
    )
    require(
        "final class ScreenshotSelectionSurfaceHandoff" in model
        and "onFirstFrameRendered" in presenter
        and "editorCanvasDidDraw(" in presenter
        and "commitEditorTransition(" in presenter
        and "final class ScreenshotEditorSelectionHandoffCoordinator" in presenter
        and "func completeIfCurrent(transitionID: UUID)" in presenter
        and "guard activeTransitionID == transitionID else { return }" in presenter
        and "selectionHandoffCoordinator.begin(" in presenter
        and "selectionHandoffCoordinator.completeIfCurrent(" in presenter
        and "selectionHandoffCoordinator.cancel()" in presenter
        and "pendingHandoff?.complete()" in presenter
        and "pendingHandoff = nil" in presenter,
        "editor_handoff_missing",
        "selection surfaces must close once after the real editor canvas draw, or be cancelled on every terminal path without accepting a late completion",
        failures,
    )
    require(
        "if requiresEditingContext" in adapter
        and "transfersSelectionSurface = true" in adapter
        and "selectionSurfaceHandoff?.complete()" in adapter,
        "selection_surface_has_multiple_cleanup_owners",
        "only editor-bound captures may transfer one-shot surface ownership",
        failures,
    )
    for event in [
        '"Shortcut"',
        '"SnapshotReady"',
        '"SelectionReady"',
        '"SelectionFinished"',
        '"SelectionSurfacesCommitted"',
        '"HandoffFrameReady"',
        '"EditorCanvasDrawn"',
        '"TransitionCommitted"',
        '"EditorFirstFrame"',
    ]:
        require(
            event in adapter + selection + presenter,
            "missing_screenshot_signpost",
            event,
            failures,
        )
    for event in ['"Defer"', '"Resolve"', '"Timeout"', '"Retry"']:
        require(
            event in clipboard,
            "missing_clipboard_signpost",
            event,
            failures,
        )
    for budget in [
        "<100 ms",
        "<1.25 s",
        "<1%",
        "<30 MB",
        "<150 ms",
        "<350 ms",
        "<50 MB",
        "120%",
    ]:
        require(
            budget in doc,
            "missing_release_budget",
            budget,
            failures,
        )

    report = {
        "gate": "P19-A",
        "ok": not failures,
        "status": "pass" if not failures else "fail",
        "failures": failures,
        "note": "Runtime percentiles and soak budgets still require Release evidence.",
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
