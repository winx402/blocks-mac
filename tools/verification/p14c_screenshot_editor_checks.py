#!/usr/bin/env python3
"""P14-C screenshot scene document and unified overlay editor checks."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
APP_TEST = ROOT / "apps/Blocks/BlocksAppTests/ScreenshotAppStateTests.swift"
CORE_PREFERENCES = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotPreferences.swift"
CORE_DOCUMENT = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotDocument.swift"
CORE_GEOMETRY = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotGeometry.swift"
CORE_RENDERER = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotRenderer.swift"
CORE_BADGE_LAYOUT = ROOT / "apps/Blocks/BlocksScreenshotCore/ScreenshotBadgeTextLayout.swift"
EDITOR_STORE = APP / "Features/Screenshot/Editor/ScreenshotEditorStore.swift"
EDITOR_STATE = APP / "Features/Screenshot/Editor/ScreenshotEditorState.swift"
RENDER_PIPELINE = APP / "Features/Screenshot/Editor/ScreenshotRenderPipeline.swift"
EDITOR_VIEW = APP / "Features/Screenshot/Editor/ScreenshotEditorView.swift"
EDITOR_CHROME_LAYOUT = APP / "Features/Screenshot/Editor/ScreenshotEditorChromeLayout.swift"
PLUGIN_UI_RENDERER = APP / "Features/Plugins/BlocksPluginUIRenderer.swift"
EDITOR_OCR = APP / "Features/Screenshot/Editor/ScreenshotEditorOCRViews.swift"
EDITOR_CANVAS = APP / "Features/Screenshot/Editor/ScreenshotEditorCanvas.swift"
EDITOR_INPUT = APP / "Features/Screenshot/Editor/ScreenshotEditorInputControls.swift"
EDITOR_CONTROLS = APP / "Features/Screenshot/Editor/ScreenshotEditorControls.swift"
EDITOR_PRESENTER = APP / "Features/Screenshot/Editor/ScreenshotEditorPresenter.swift"
PINNED_SCREENSHOT = APP / "Features/Screenshot/Editor/PinnedScreenshotManager.swift"
EDITOR_OUTPUT = APP / "Features/Screenshot/Output/ScreenshotEditorOutputCoordinator.swift"
PASTEBOARD_WRITER = APP / "Features/Screenshot/Output/ScreenshotPasteboardWriter.swift"
OLD_FILES = [
    APP / "Views/ScreenshotResultView.swift",
    APP / "Services/ScreenshotResultPresenter.swift",
    APP / "Models/ScreenshotAIAction.swift",
    APP / "Models/ScreenshotHistoryEntry.swift",
]


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def swift_scope(source: str, declaration: str) -> str:
    """Read one balanced Swift scope; adjacent declarations cannot satisfy it."""
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    start = source.find(declaration)
    opening = source.find("{", start) if start >= 0 else -1
    if opening < 0:
        return ""
    depth = 0
    quoted = False
    escaped = False
    for index in range(opening, len(source)):
        char = source[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    return ""


def editor_layout_contract_failures(
    view: str,
    chrome: str,
    presenter: str,
    plugin_renderer: str,
) -> list[dict[str, str]]:
    """Static companions to hosted layout tests; never a substitute for UI evidence."""
    failures: list[dict[str, str]] = []

    def require(code: str, path: Path, source: str, tokens: list[str]) -> None:
        for token in tokens:
            if token not in source:
                failures.append({"code": code, "path": rel(path), "detail": token})

    def forbid(code: str, path: Path, source: str, tokens: list[str]) -> None:
        for token in tokens:
            if token in source:
                failures.append({"code": code, "path": rel(path), "detail": token})

    def ordered(code: str, path: Path, source: str, tokens: list[str]) -> None:
        positions = [source.find(token) for token in tokens]
        if any(position < 0 for position in positions) or positions != sorted(positions):
            failures.append({"code": code, "path": rel(path), "detail": " -> ".join(tokens)})

    content_layout = swift_scope(chrome, "struct ScreenshotChromeContentLayout")
    panel_layout = swift_scope(chrome, "struct ScreenshotEditorToolbarPanelLayout")
    overlay_layout = swift_scope(chrome, "struct ScreenshotEditorOverlayLayout")
    require("editor_synchronous_intrinsic_measurement_missing", EDITOR_CHROME_LAYOUT, content_layout, [
        "subviews.first?.sizeThatFits(.unspecified).width", "min(maximumWidth, proposal.width ?? maximumWidth)",
        "fillsProposedWidth ? available : min(available, intrinsic)",
        "proposal: ProposedViewSize(width: bounds.width, height: bounds.height)",
    ])
    require("editor_plugin_inspector_dynamic_toolbar_measurement_missing", EDITOR_CHROME_LAYOUT, panel_layout, [
        "let proposedWidth = min(maximumWidth, proposal.width ?? maximumWidth)",
        "ProposedViewSize(width: proposedWidth, height: nil)",
        "propertiesHeight = max(",
        "ScreenshotDesignTokens.toolbarPropertyHeight",
        "ScreenshotEditorChromeMetrics.toolbarDividerHeight",
        "subviews[0].place", "subviews[1].place",
        "propertyHeight = max(",
        "proposal: ProposedViewSize(\n                width: propertyWidth,\n                height: propertyHeight",
    ])
    require("editor_chrome_measured_frames_not_applied", EDITOR_CHROME_LAYOUT, overlay_layout, [
        "let maximumChromeWidth = max(",
        "safeAreaInsets.leading + safeAreaInsets.trailing",
        "let statusSize = subviews[1].sizeThatFits(",
        "let toolbarSize = subviews[2].sizeThatFits(",
        "ProposedViewSize(width: maximumChromeWidth, height: nil)",
        "statusWidth: statusSize.width",
        "toolbarWidth: toolbarSize.width",
        "toolbarHeight: toolbarSize.height",
        "presentation: presentation, safeAreaInsets: safeAreaInsets",
        "zip(subviews, [frames.canvas, frames.status, frames.toolbar])",
        "subview.place", "proposal: ProposedViewSize(width: frame.width, height: frame.height)",
    ])
    maximum_width = swift_scope(chrome, "static func maximumWidth(")
    require("editor_display_width_budget_missing", EDITOR_CHROME_LAYOUT, maximum_width, ["max(0, availableWidth - edgeMargin * 2)"])
    forbid("editor_760_point_ceiling_restored", EDITOR_CHROME_LAYOUT, maximum_width, ["760", "editorPreferredToolbarWidth"])

    mode = swift_scope(chrome, "enum ScreenshotEditorCanvasPresentation")
    require("editor_full_display_mode_boundary_missing", EDITOR_CHROME_LAYOUT, mode, [
        "!isLongImage", "!displayFrames.isEmpty", "sourceFrame.minX - captureFrame.minX",
        "sourceFrame.minY - captureFrame.minY", "sourceFrame.maxX - captureFrame.maxX",
        "sourceFrame.maxY - captureFrame.maxY", "sourceFrame == displayUnion", "coversSource",
        "? .displayOverlay : .cropSurround",
    ])
    crop_layout = swift_scope(chrome, "enum ScreenshotEditorCropChromeLayout")
    require("editor_full_display_canvas_or_safe_chrome_missing", EDITOR_CHROME_LAYOUT, crop_layout, [
        "presentation: ScreenshotEditorCanvasPresentation = .cropSurround",
        "presentation == .displayOverlay ? fullCanvas : displayCanvas(",
        "safeAreaInsets.top", "safeAreaInsets.bottom", "safeAreaInsets.leading", "safeAreaInsets.trailing",
        ": crop.minY", ": crop.maxY + ScreenshotEditorChromeMetrics.cropGap",
    ])
    require("editor_display_mode_not_wired", EDITOR_PRESENTER, presenter, [
        "ScreenshotEditorCanvasPresentation.resolve(", "captureFrame: capture.sourceRect",
        "displayFrames: capture.editingContext?.screens.map(\\.frame)",
        "isLongImage: store.prefersLongImageViewport", "canvasPresentation: canvasPresentation",
        "chromeSafeAreaInsets: chromeSafeAreaInsets",
    ])
    require("editor_chrome_measured_frames_not_applied", EDITOR_VIEW, view, [
        "ScreenshotEditorOverlayLayout(", "presentation: canvasPresentation, safeAreaInsets: chromeSafeAreaInsets",
        "ScreenshotEditorToolbarPanelLayout(maximumWidth: maximumWidth)",
    ])

    toolbar = swift_scope(view, "struct ScreenshotUnifiedEditorToolbar")
    expanded = swift_scope(toolbar, "private var expandedContent:")
    compact = swift_scope(toolbar, "private var compactContent:")
    cluster = swift_scope(toolbar, "private var toolCluster:")
    require("editor_real_plugin_slot_measurement_missing", EDITOR_VIEW, expanded, ["pluginToolContent", "pluginOutputContent", "toolCluster"])
    require("editor_real_plugin_slot_measurement_missing", EDITOR_VIEW, toolbar, [
        "expandedContent.fixedSize(horizontal: true, vertical: false)", "ViewThatFits(in: .horizontal)",
    ])
    require("editor_quick_tool_natural_geometry_missing", EDITOR_VIEW, cluster, [
        "ForEach(presentation.visibleQuickTools", ".fixedSize(horizontal: true, vertical: false)",
    ])
    forbid("editor_quick_tool_stretch_or_nested_scroll_restored", EDITOR_VIEW, cluster, [
        ".frame(maxWidth: .infinity)", ".layoutPriority(0)", "ScreenshotEditorToolStrip(",
    ])
    require("editor_narrow_primary_actions_or_overflow_missing", EDITOR_VIEW, compact, [
        "dispatch(.close)", "item: .select", "ScreenshotChromeOverflowRow(", "Menu {",
        "dispatch(.undo)", "dispatch(.redo)", "dispatch(.pin)", "dispatch(.save)", "dispatch(.retake)",
        "dispatch(.complete)", "pluginToolContent", "pluginOutputContent", "screenshot.editor.moreActions",
        ".fixedSize(horizontal: true, vertical: false)",
    ])
    if not (0 <= compact.find("dispatch(.close)") < compact.find("ScreenshotChromeOverflowRow(") < compact.find("dispatch(.complete)")):
        failures.append({"code": "editor_narrow_primary_actions_or_overflow_missing", "path": rel(EDITOR_VIEW), "detail": "close/select precede scrolling tools; complete stays in the fixed trailing group"})

    status = swift_scope(view, "struct ScreenshotEditorStatusBar:")
    properties_layout = swift_scope(view, "struct ScreenshotEditorPropertiesContentLayout")
    plugin_inspector = swift_scope(view, "struct ScreenshotPluginInspectorSection")
    plugin_viewport = swift_scope(view, "private struct ScreenshotPluginInspectorViewportLayout")
    properties = swift_scope(view, "private struct ScreenshotExpandedPropertiesRow:")
    property_strip = swift_scope(view, "private struct ScreenshotChromePropertyStrip")
    overflow = swift_scope(view, "private struct ScreenshotChromeOverflowRow<")
    require("editor_status_first_frame_geometry_missing", EDITOR_VIEW, status, [
        "ScreenshotChromeContentLayout(", "fillsProposedWidth: true", "ScrollView(.horizontal)",
        "ScrollViewReader", "proxy.scrollTo", ".fixedSize(horizontal: true, vertical: true)",
    ])
    forbid("editor_status_async_width_or_fade_restored", EDITOR_VIEW, status, [
        ".mask", "PreferenceKey", "onContentWidthChange", "measuredStatusContentWidth",
    ])
    require("editor_properties_content_sizing_or_overflow_missing", EDITOR_VIEW, properties_layout, [
        "ScreenshotChromeContentLayout(",
        "ScreenshotPluginInspectorSection(",
        "maximumPluginInspectorHeight",
        ".blocksSurface(",
    ])
    require("editor_properties_content_sizing_or_overflow_missing", EDITOR_VIEW, property_strip, [
        "propertyContents.fixedSize", "ScreenshotChromeOverflowRow { propertyContents }",
    ])
    require("editor_plugin_inspector_scroll_boundary_missing", EDITOR_VIEW, plugin_inspector, [
        "ScreenshotPluginInspectorViewportLayout(", "ViewThatFits(in: .vertical)",
        "paddedContent.fixedSize(horizontal: false, vertical: true)",
        "ScrollView(.vertical)", ".frame(height: maximumHeight)", ".blocksSurface(",
    ])
    require("editor_plugin_inspector_finite_proposal_missing", EDITOR_VIEW, plugin_viewport, [
        "let width = min(maximumWidth, proposal.width ?? maximumWidth)",
        "let height = min(maximumHeight, proposal.height ?? maximumHeight)",
        "ProposedViewSize(width: width, height: height)",
        "height: min(height, measured.height)",
        "proposal: ProposedViewSize(width: bounds.width, height: bounds.height)",
    ])
    forbid("editor_properties_full_width_slab_restored", EDITOR_VIEW, properties, [".mask"])
    require("editor_overflow_cues_or_accessibility_missing", EDITOR_VIEW, overflow, [
        "scrollButton(forward: false)", "scrollButton(forward: true)", "ScrollView(.horizontal)",
        "proxy.scrollTo(leadingID", "proxy.scrollTo(trailingID", "proxy.scrollTo(id, anchor: .center)",
        "screenshot.editor.properties.scrollForward", "screenshot.editor.properties.scrollBackward",
        "BlocksCompactIconButton(", ".accessibilityElement(children: .contain)",
    ])
    forbid("editor_overflow_cues_overlay_content", EDITOR_VIEW, overflow, [".overlay", ".mask"])

    bottom = swift_scope(view, "private func bottomToolbarContainer")
    surface = ".blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)"
    first_surface = bottom.find(surface)
    property_start = bottom.find("ScreenshotExpandedPropertiesRow(")
    if not (0 <= bottom.find("ScreenshotUnifiedEditorToolbar(") < first_surface < property_start) or bottom.count(surface) != 1:
        failures.append({"code": "editor_main_property_order_or_independent_surfaces_missing", "path": rel(EDITOR_VIEW), "detail": "main controls then content-sized inspector, each using the shared panel surface"})
    require("editor_plugin_action_error_externalization_missing", PLUGIN_UI_RENDERER, plugin_renderer, [
        "enum BlocksPluginUIActionErrorRouting", "onActionError: ((String) -> Void)? = nil",
        "BlocksPluginUIActionErrorRouting.report(", "setInlineActionError:",
    ])
    screenshot_slot = swift_scope(view, "private func screenshotPluginSlot(")
    inspector_slot = swift_scope(view, "private var screenshotInspectorPluginContent")
    require("editor_plugin_action_error_externalization_missing", EDITOR_VIEW, screenshot_slot, [
        "BlocksPluginUISlotHost(", "onActionError: presentPluginActionError",
    ])
    require("editor_plugin_action_error_externalization_missing", EDITOR_VIEW, inspector_slot, [
        "BlocksPluginUISlotHost(", "onActionError: presentPluginActionError",
    ])
    require("editor_plugin_action_error_externalization_missing", EDITOR_VIEW, view, [
        "BlocksNotificationDescriptor(",
        "deduplicationKey: \"screenshot.plugin.action.failed\"",
    ])

    # HEAD already uses session-scoped async pinning. Preserve these stronger
    # guards instead of requiring the obsolete optional-self, unscoped call.
    pin = swift_scope(presenter, "private func pinSession(")
    finish = swift_scope(presenter, "private func finishSession(")
    require("editor_async_pin_identity_contract_missing", EDITOR_PRESENTER, pin, [
        "guard activeSessionID == sessionID, self.store === store,", "sessionCompletion != nil",
        "pinnedScreenshotManager.present(presentation", "store.setFinalizingOutput(true)",
        "await finishSession(.pinned(presentation.image), sessionID: sessionID)",
        "guard !Task.isCancelled || hasCommittedFinalOutputResult(sessionID: sessionID)",
        "guard activeSessionID == sessionID, self.store === store else", "return executionResult",
    ])
    require("editor_async_finish_identity_contract_missing", EDITOR_PRESENTER, finish, [
        "guard activeSessionID == sessionID else", "let completion = sessionCompletion",
        "sessionCompletion = nil", "await completion?(outcome)",
    ])
    callback = swift_scope(presenter, "onPinned:")
    require("editor_async_pin_dispatch_contract_missing", EDITOR_PRESENTER, callback, [
        "[weak self] presentation in", "Task { @MainActor [weak self] in",
        "guard let self, self.activeSessionID == sessionID,", "let store = self.store",
        "await self.runHostFinalOutput(sessionID: sessionID)", "await presenter.pinSession(",
        "sessionID: sessionID", "store: store",
    ])
    ordered("editor_async_pin_order_regressed", EDITOR_PRESENTER, pin, [
        "guard activeSessionID == sessionID, self.store === store,",
        "pinnedScreenshotManager.present(presentation", "store.setFinalizingOutput(true)",
        "await finishSession(.pinned(presentation.image), sessionID: sessionID)",
        "guard activeSessionID == sessionID, self.store === store else", "closeEditorWindow()",
    ])
    ordered("editor_async_finish_order_regressed", EDITOR_PRESENTER, finish, [
        "guard activeSessionID == sessionID else", "let completion = sessionCompletion",
        "sessionCompletion = nil", "await completion?(outcome)",
    ])
    return failures


def verify_layout_contract_mutations(
    view: str,
    chrome: str,
    presenter: str,
    plugin_renderer: str,
) -> list[dict[str, str]]:
    """In-memory negative fixtures: no checkout or production source is modified."""
    sources = [view, chrome, presenter, plugin_renderer]
    mutations = [
        (1, "subviews.first?.sizeThatFits(.unspecified).width", "subviews.first?.sizeThatFits(proposal).width", "editor_synchronous_intrinsic_measurement_missing"),
        (1, "let proposedWidth = min(maximumWidth, proposal.width ?? maximumWidth)", "let proposedWidth = maximumWidth", "editor_plugin_inspector_dynamic_toolbar_measurement_missing"),
        (1, "toolbarHeight: toolbarSize.height", "toolbarHeight: ScreenshotEditorChromeMetrics.bottomToolbarHeight", "editor_chrome_measured_frames_not_applied"),
        (1, "max(0, availableWidth - edgeMargin * 2)", "min(760, max(0, availableWidth - edgeMargin * 2))", "editor_760_point_ceiling_restored"),
        (0, "pluginOutputContent", "removedOutputSlot", "editor_real_plugin_slot_measurement_missing"),
        (0, ".fixedSize(horizontal: true, vertical: false)", ".frame(maxWidth: .infinity)", "editor_quick_tool_stretch_or_nested_scroll_restored"),
        (0, ".onDeleteCommand(perform: deleteFocusedElement)", ".mask { Color.clear }", "editor_status_async_width_or_fade_restored"),
        (1, "presentation == .displayOverlay ? fullCanvas : displayCanvas(", "displayCanvas(", "editor_full_display_canvas_or_safe_chrome_missing"),
        (1, "!isLongImage,", "", "editor_full_display_mode_boundary_missing"),
        (1, "safeAreaInsets.top", "0", "editor_full_display_canvas_or_safe_chrome_missing"),
        (1, "zip(subviews, [frames.canvas, frames.status, frames.toolbar])", "zip(subviews, [frames.canvas])", "editor_chrome_measured_frames_not_applied"),
        (0, "Menu {", "Group {", "editor_narrow_primary_actions_or_overflow_missing"),
        (0, "scrollButton(forward: true)", "scrollButton(forward: false)", "editor_overflow_cues_or_accessibility_missing"),
        (0, "ScreenshotExpandedPropertiesRow(", "RemovedInspector(", "editor_main_property_order_or_independent_surfaces_missing"),
        (0, "ScreenshotPluginInspectorSection(", "RemovedPluginInspector(", "editor_properties_content_sizing_or_overflow_missing"),
        (0, ".frame(height: maximumHeight)", ".frame(maxHeight: maximumHeight)", "editor_plugin_inspector_scroll_boundary_missing"),
        (0, "ProposedViewSize(width: width, height: height)", ".unspecified", "editor_plugin_inspector_finite_proposal_missing"),
        (3, "onActionError: ((String) -> Void)? = nil", "onActionErrorRemoved", "editor_plugin_action_error_externalization_missing"),
        (0, "onActionError: presentPluginActionError", "onActionError: nil", "editor_plugin_action_error_externalization_missing"),
        (2, "await finishSession(.pinned(presentation.image), sessionID: sessionID)", "finishSessionWithoutWaiting(.pinned(presentation.image))", "editor_async_pin_identity_contract_missing"),
        (2, "await completion?(outcome)", "completion?(outcome)", "editor_async_finish_identity_contract_missing"),
        (2, "guard let self, self.activeSessionID == sessionID,", "guard let self,", "editor_async_pin_dispatch_contract_missing"),
    ]
    failures = []
    for index, before, after, expected in mutations:
        mutated = list(sources)
        if before not in mutated[index]:
            failures.append({"code": "editor_layout_mutation_fixture_stale", "path": rel(Path(__file__)), "detail": before})
            continue
        mutated[index] = mutated[index].replace(before, after)
        observed = {failure["code"] for failure in editor_layout_contract_failures(*mutated)}
        if expected not in observed:
            failures.append({"code": "editor_layout_mutation_not_rejected", "path": rel(Path(__file__)), "detail": expected})
    return failures


def main() -> int:
    failures: list[dict[str, str]] = []
    for path in [CORE_DOCUMENT, CORE_GEOMETRY, CORE_RENDERER, CORE_BADGE_LAYOUT, CORE_PREFERENCES, EDITOR_STORE, EDITOR_STATE, RENDER_PIPELINE, EDITOR_VIEW, EDITOR_CHROME_LAYOUT, PLUGIN_UI_RENDERER, EDITOR_OCR, EDITOR_CANVAS, EDITOR_INPUT, EDITOR_CONTROLS, EDITOR_PRESENTER, PINNED_SCREENSHOT, EDITOR_OUTPUT, PASTEBOARD_WRITER, PROJECT, APP_TEST]:
        if not path.exists():
            failures.append({"code": "missing_file", "path": rel(path)})
    for path in OLD_FILES:
        if path.exists():
            failures.append({"code": "legacy_result_surface_remaining", "path": rel(path)})

    document = text(CORE_DOCUMENT)
    geometry = text(CORE_GEOMETRY)
    renderer = text(CORE_RENDERER)
    badge_layout = text(CORE_BADGE_LAYOUT)
    preferences = text(CORE_PREFERENCES)
    store = text(EDITOR_STORE)
    state = text(EDITOR_STATE)
    render_pipeline = text(RENDER_PIPELINE)
    view = text(EDITOR_VIEW)
    chrome_layout = text(EDITOR_CHROME_LAYOUT)
    plugin_renderer = text(PLUGIN_UI_RENDERER)
    ocr = text(EDITOR_OCR)
    canvas = text(EDITOR_CANVAS)
    canvas_input = canvas + "\n" + text(EDITOR_INPUT)
    controls = text(EDITOR_CONTROLS)
    presenter = text(EDITOR_PRESENTER)
    pinned_screenshot = text(PINNED_SCREENSHOT)
    output = text(EDITOR_OUTPUT)
    pasteboard = text(PASTEBOARD_WRITER)
    project = text(PROJECT)
    app_tests = text(APP_TEST)
    failures.extend(editor_layout_contract_failures(
        view, chrome_layout, presenter, plugin_renderer
    ))
    failures.extend(verify_layout_contract_mutations(
        view, chrome_layout, presenter, plugin_renderer
    ))

    if "let imageBorder = NSBezierPath" in canvas:
        failures.append({
            "code": "editor_source_border_competes_with_active_crop",
            "path": rel(EDITOR_CANVAS),
        })
    if "runModal()" in output:
        failures.append({
            "code": "editor_save_panel_blocks_main_actor",
            "path": rel(EDITOR_OUTPUT),
        })
    if "runModal()" in presenter:
        failures.append({
            "code": "editor_confirmation_blocks_main_actor",
            "path": rel(EDITOR_PRESENTER),
        })
    for token in ["beginSheetModal(for:", "presentationWindow", "savePanelPresenter"]:
        if token not in output:
            failures.append({
                "code": "editor_save_sheet_contract_missing",
                "path": rel(EDITOR_OUTPUT),
                "detail": token,
            })
    for token in ["ScreenshotPasteboardArtifactStore", "artifactURL"]:
        if token not in pasteboard:
            failures.append({
                "code": "screenshot_stable_file_pasteboard_contract_missing",
                "path": rel(PASTEBOARD_WRITER),
                "detail": token,
            })
    if ".fileURL" not in pasteboard:
        failures.append({
            "code": "screenshot_stable_file_pasteboard_contract_missing",
            "path": rel(PASTEBOARD_WRITER),
            "detail": ".fileURL",
        })
    if "NSFilenamesPboardType" in pasteboard:
        failures.append({
            "code": "screenshot_deprecated_filename_pasteboard_type_remaining",
            "path": rel(PASTEBOARD_WRITER),
        })
    for token in [
        "enum ScreenshotDesignTokens",
        "BlocksVisualTokens.Spacing.xs",
        "BlocksVisualTokens.Spacing.sm",
        "BlocksVisualTokens.Spacing.md",
        "BlocksVisualTokens.Spacing.xl",
        "static let cropGap = BlocksVisualTokens.Spacing.sm",
        "enum ScreenshotEditorCropChromeLayout",
        "static func resolve(",
        "crop.midX",
        "statusPreferredY = presentation == .displayOverlay",
        "toolbarPreferredY = presentation == .displayOverlay",
        "centeredClampedX(",
        "let statusY = min(",
        "let toolbarY = min(",
    ]:
        if token not in chrome_layout:
            failures.append({
                "code": "editor_toolbar_stable_placement_missing",
                "path": rel(EDITOR_CHROME_LAYOUT),
                "detail": token,
            })
    if re.search(r"static let cropGap(?:\s*:\s*CGFloat)?\s*=\s*\d", chrome_layout):
        failures.append({
            "code": "editor_chrome_private_crop_gap_literal_restored",
            "path": rel(EDITOR_CHROME_LAYOUT),
        })
    for token in [
        "enum ScreenshotEditorCropChromeLayout",
        "enum ScreenshotFloatingPanelLayout",
        "enum ScreenshotDesignTokens",
    ]:
        if token in view:
            failures.append({
                "code": "editor_chrome_layout_restored_to_legacy_view_path",
                "path": rel(EDITOR_VIEW),
                "detail": token,
            })
    if "Color(nsColor: .windowBackgroundColor)" not in view:
        failures.append({
            "code": "editor_toolbar_stable_placement_missing",
            "path": rel(EDITOR_VIEW),
            "detail": "Color(nsColor: .windowBackgroundColor)",
        })
    if "drawCheckerboard(in: bounds)" in canvas or "private func drawCheckerboard" in canvas:
        failures.append({
            "code": "editor_full_canvas_checkerboard_remaining",
            "path": rel(EDITOR_CANVAS),
        })
    if "drawEditorBackdrop(in: bounds)" not in canvas or "NSColor.windowBackgroundColor" not in canvas:
        failures.append({
            "code": "editor_semantic_backdrop_missing",
            "path": rel(EDITOR_CANVAS),
        })
    if "reservedCanvas" in view or "needsReservedCanvas" in view:
        failures.append({
            "code": "editor_chrome_reflows_full_source_canvas",
            "path": rel(EDITOR_VIEW),
        })
    required_document = [
        "enum ScreenshotTextBoxSizing",
        "case auto",
        "case fixedWidth",
        "case fixedBox",
        "final class ScreenshotSceneDocument",
        "ScreenshotSceneSnapshot",
        "draftSnapshot",
        "presentedSnapshot",
        "beginInteraction()",
        "updateInteraction(",
        "commitInteraction()",
        "cancelInteraction()",
        "ScreenshotSceneRenderSnapshot",
        "ScreenshotSceneRevision",
        "ScreenshotSceneRenderRequest",
        "ScreenshotRenderCancellation",
        "makeRenderRequest()",
        "isRenderRequestCurrent(",
        "ScreenshotSourceTileDescriptor",
        "tileDescriptors",
    ]
    required_renderer = [
        "ScreenshotRenderPlan",
        "makeRenderPlan(",
        "effectSamplingOutset(",
        "effectBoundaryCount",
        "vectorBatchCount",
        "elementIndexes",
        "requiredElements",
        "vectorRenderRect(",
        "plan.elementIndexes.map",
        "case cancelled",
        "ScreenshotStrokeSmoothing.points(",
    ]
    required_store = [
        "final class ScreenshotEditorStore",
        "let document: ScreenshotSceneDocument",
        "var visibleQuickToolbarItems:",
        "var visibleExtendedToolbarItems:",
        "selectedTool",
        "sourceUnitsPerViewPoint: Double = 1",
        "updateGesture(",
        "endGesture(at",
        "document.beginInteraction()",
        "document.updateInteraction",
        "document.commitInteraction()",
        "document.cancelInteraction()",
        "ScreenshotGeometry.hitTestHandle",
        "case resizing(",
        "case cropResize(",
        "func undo()",
        "func redo()",
        "func complete() -> ScreenshotEditorOutputAdmission",
        "func copyCurrent()",
        "func pinCurrent()",
        "case .pin:",
        "func saveAs()",
        "ScreenshotEditorViewportState",
        "func completeForReplacement() async",
        "pendingReplacementCompletion",
        "requestReplacementOutput(completion:",
        "performReplacement(",
        "renderState: ScreenshotEditorRenderState",
        "renderedVisibleRect: ScreenshotPixelRect",
        "selectionBasePipeline",
        "textEditingBasePipeline",
        "prepareSelectionBase(for:",
        "prepareTextEditingBase(for:",
        "requestInlineTextEditing",
        "elements.filter { $0.id != elementID }",
        "canvasInputEnabled",
        "func shutdown()",
        "cropConstraint = editingContext.initialRegionConstraint",
        "cropConstraint = resolved",
        "scheduleEffectPreview()",
        "renderedRevision: ScreenshotSceneRevision?",
        "pendingOutputGate = ScreenshotPendingOutputGate()",
        "cachedOutputRequest()",
        "ScreenshotEditorOutputImageProcessor",
        "Task.detached(priority: .userInitiated)",
        "processOutput(",
        "outputGeneration",
        "performPendingOutputIfReady()",
        "scheduleImplicitStyleCommit()",
        "func requestMoreToolsTriggerFocus()",
        "moreToolsTriggerFocusRequestID = UUID()",
        "&& !isOutputPending",
    ]

    for token in [
        "viewWillMove(toWindow",
        "ScreenshotSemanticTextStyle.inlineAppearance",
        "ScreenshotResolvedColor(",
        "resolvedDraftStrokeColor",
    ]:
        if token not in canvas:
            failures.append({
                "code": "editor_interaction_regression_guard_missing",
                "path": rel(EDITOR_CANVAS),
                "detail": token,
            })
    if "element.appearance.strokeColor.nsColor.withAlphaComponent(element.appearance.opacity)" in canvas:
        failures.append({
            "code": "editor_draft_color_replaces_intrinsic_alpha",
            "path": rel(EDITOR_CANVAS),
        })
    required_view = [
        "struct ScreenshotEditorHostView",
        "struct ScreenshotUnifiedEditorView",
        "ScreenshotUnifiedEditorToolbar",
        "struct ScreenshotToolbarPresentation",
        "struct ScreenshotToolbarLayoutResolution",
        "static func resolve(",
        "static func requiredWidth(",
        "ScreenshotMoreToolsPanel",
        "visibleQuickTools",
        "overflowTools",
        "activeOverflowTool",
        "ScreenshotExpandedPropertiesRow",
        "chromeState.quickToolbarItems",
        "chromeState.extendedToolbarItems",
        "ScreenshotColorPickerButton",
        "onEditingChanged: styleColorEditingChanged",
        "ScrollView(.horizontal)",
        ".scrollIndicators(.hidden)",
        "ScreenshotChromeContentLayout",
        "ScreenshotChromeOverflowRow",
        "screenshot.editor.properties.scrollBackward",
        "screenshot.editor.properties.scrollForward",
        "focusRequestID: moreToolsTriggerFocusRequestID",
        "focusedTool = nil",
        "ScreenshotMoreToolsTriggerButton",
        "BlocksCompactIconButton(",
        "ScreenshotMoreToolsPanelMetrics.columnCount(toolCount: tools.count)",
        ".frame(width: panelWidth)",
        "focusedTool = tools.contains(selectedItem) ? selectedItem : tools.first",
        "onMoreToolsExit: store.requestMoreToolsTriggerFocus",
        "onExit: onMoreToolsExit",
        "ScreenshotEditorStatusBar",
        "ScreenshotEditorStatusBarModel.visibleElements",
        ".onDeleteCommand(perform: deleteFocusedElement)",
        "ScreenshotEditorOverlayLayout(",
        "bottomToolbarContainer(",
        "textCommitRequestID",
        "requestCanvasAction",
        "performPendingCanvasAction",
        "ScreenshotToolbarIconButton(",
        ".blocksImmediateTooltipHost()",
        'systemImage: "camera.rotate"',
        'systemImage: "pin.fill"',
        'systemImage: "checkmark"',
        "emphasis: .accent",
        "store.outputState.isCloseConfirmationPresented",
        "store.outputState.isPending",
        "private var curvatureControl:",
        "store.beginCurvatureEditing()",
        "store.resetCurvature",
    ]
    required_canvas = [
        "struct ScreenshotEditorCanvas",
        "final class ScreenshotEditorCanvasView",
        "allowsViewportNavigation",
        "applyMagnification(",
        "applyScroll(",
        "drawHandles(for element:",
        "acceptsFirstMouse",
        "drawDraft(",
        "sourceUnitsPerViewPoint",
        "onSelectTool",
        "onUndo",
        "onRedo",
        "ScreenshotEditorAccessibilityModel",
        "override func accessibilityChildren()",
        "NSAccessibilityCustomAction",
        "moveAccessibilityFocus(backward:",
        "commitInlineTextIfNeeded()",
        "hasMarkedText()",
        "ScreenshotInlineTextLayoutPolicy.make(",
        "ScreenshotInlineTextAttributes(",
        "mergingMarkedTextAttributes",
        "widthTracksTextView = policy.widthTracksTextView",
        "containerSize = NSSize(",
        "window.initialFirstResponder = self",
        "didRequestInitialFocus",
        "ScreenshotCanvasSnapshot",
        "ScreenshotCanvasInvalidationPolicy.invalidation(",
        "onFirstFrameRendered",
        "reportFirstFrameIfNeeded",
        "didReportFirstFrame",
        "static func draftTextRect(for element:",
        "case let .calloutComposite(_, note):",
    ]
    required_state = [
        "enum ScreenshotEditorAction",
        "struct ScreenshotEditorChromeState",
        "struct ScreenshotEditorInspectorState",
        "struct ScreenshotEditorOutputState",
        "var chromeState:",
        "var inspectorState:",
        "var outputState:",
    ]
    for token in [
        "panel.alphaValue = 0",
        "editorCanvasDidDraw(",
        "commitEditorTransition(",
        "startTransitionWatchdog(",
        "alphaValue: 1",
        "final class ScreenshotEditorSelectionHandoffCoordinator",
        "private var activeTransitionID: UUID?",
        "private var pendingHandoff: ScreenshotSelectionSurfaceHandoff?",
        "func completeIfCurrent(transitionID: UUID)",
        "guard activeTransitionID == transitionID else { return }",
        "func cancel()",
        "pendingHandoff?.complete()",
        "pendingHandoff = nil",
        "selectionHandoffCoordinator.begin(",
        "selectionHandoffCoordinator.completeIfCurrent(",
        "selectionHandoffCoordinator.cancel()",
        "stage=editor-canvas-drawn",
        "stage=transition-committed",
    ]:
        if token not in presenter:
            failures.append({
                "code": "editor_atomic_first_frame_handoff_missing",
                "path": rel(EDITOR_PRESENTER),
                "detail": token,
            })
    if "selectionHandoffCoordinator.completeIfCurrent(\n                transitionID: transitionID" not in presenter:
        failures.append({
            "code": "editor_handoff_late_completion_not_transition_guarded",
            "path": rel(EDITOR_PRESENTER),
            "detail": "canvas completion must resolve only the matching handoff transition",
        })
    for terminal_path in [
        "private func cancelEditorTransition()",
        "func windowWillClose(_ notification: Notification)",
        "startTransitionWatchdog(",
    ]:
        terminal_section = presenter.partition(terminal_path)[2]
        if "selectionHandoffCoordinator.cancel()" not in terminal_section:
            failures.append({
                "code": "editor_handoff_terminal_cleanup_missing",
                "path": rel(EDITOR_PRESENTER),
                "detail": terminal_path,
            })
    required_render_pipeline = [
        "final class ScreenshotRenderPipeline",
        "ScreenshotRenderPipelineResult",
        "generation &+= 1",
        "activeCancellation?.cancel()",
        "task?.cancel()",
        "pipeline.generation == submittedGeneration",
    ]
    unified_toolbar = view.partition("struct ScreenshotUnifiedEditorToolbar")[2].partition(
        "private struct ScreenshotMoreToolsPanel"
    )[0]
    if "private struct ScreenshotToolbarDragHandle" in view:
        failures.append({
            "code": "editor_toolbar_drag_handle_restored",
            "path": rel(EDITOR_VIEW),
        })
    if "ScrollView(.horizontal" in unified_toolbar:
        failures.append({
            "code": "editor_tool_cluster_uses_hidden_horizontal_scroll",
            "path": rel(EDITOR_VIEW),
        })
    for legacy_icon in ['"chevron.up"', '"chevron.down"']:
        if legacy_icon in view:
            failures.append({
                "code": "editor_tool_library_uses_directional_disclosure_icon",
                "path": rel(EDITOR_VIEW),
                "detail": legacy_icon,
            })

    expanded_properties = view.partition("private struct ScreenshotExpandedPropertiesRow")[2].partition(
        "private struct ScreenshotToolbar"
    )[0]
    if ".frame(maxWidth: .infinity, alignment: .leading)" in expanded_properties:
        failures.append({
            "code": "editor_properties_row_greedily_expands",
            "path": rel(EDITOR_VIEW),
        })
    if ".frame(height: 52)" in expanded_properties:
        failures.append({
            "code": "editor_properties_row_too_tall",
            "path": rel(EDITOR_VIEW),
        })
    if ".scrollIndicators(.visible)" in expanded_properties:
        failures.append({
            "code": "editor_aspect_properties_uses_height_competing_system_scrollbar",
            "path": rel(EDITOR_VIEW),
        })
    if "NSApp.activate(" in presenter:
        failures.append({
            "code": "editor_transition_activates_application",
            "path": rel(EDITOR_PRESENTER),
            "detail": "editor keyboard focus must not activate Blocks and switch the capture Space",
        })

    for obsolete in [
        "ScreenshotPropertyContentWidthPreferenceKey",
        "ScreenshotPropertyViewportWidthPreferenceKey",
        "fadeEdge: FadeEdge",
    ]:
        if obsolete in expanded_properties:
            failures.append({
                "code": "editor_properties_obsolete_overflow_feedback_remaining",
                "path": rel(EDITOR_VIEW),
                "detail": obsolete,
            })
    for token in [
        "ScreenshotEditorLocalEscapeHandling",
        "handleEditorEscape()",
        "testEditorHostPanelLetsFocusedControlConsumeEscapeLocally",
    ]:
        if token not in controls + presenter + app_tests:
            failures.append({
                "code": "editor_local_escape_routing_missing",
                "path": rel(EDITOR_CONTROLS),
                "detail": token,
            })

    for token in [
        "effectPreviewInFlight",
        "effectPreviewPending",
        "submitPendingEffectPreviewIfNeeded",
        "completeEffectPreview(with:",
        "hasActiveEffectPreview",
        "renderPipeline.cancel()",
        "anchoredSquareResize(",
        "layout.hitKind(at:",
    ]:
        if token not in store:
            failures.append({
                "code": "editor_effect_preview_latest_frame_coalescing_missing",
                "path": rel(EDITOR_STORE),
                "detail": token,
            })
    if "private var effectPreviewTask" in store:
        failures.append({
            "code": "editor_effect_preview_cancellation_starvation_path_remaining",
            "path": rel(EDITOR_STORE),
        })

    for token in ["badgeFontSize", "connectorControlPoint"]:
        if token not in geometry or token not in renderer:
            failures.append({
                "code": "editor_step_shared_render_metrics_missing",
                "path": rel(CORE_GEOMETRY),
                "detail": token,
            })
    for token in ["struct ScreenshotBadgeTextLayout", "CTLineGetBoundsWithOptions", "baselineOrigin"]:
        if token not in badge_layout or "ScreenshotBadgeTextLayout(" not in renderer:
            failures.append({
                "code": "editor_badge_optical_centering_missing",
                "path": rel(CORE_BADGE_LAYOUT),
                "detail": token,
            })
    for token, source, path in [
        ("connectorLineWidth", geometry, CORE_GEOMETRY),
        ("ScreenshotStepConnectorAttachment", document, CORE_DOCUMENT),
        ("appearance: value.connector", renderer, CORE_RENDERER),
        ("ScreenshotLinkedAnnotationLayout", geometry, CORE_GEOMETRY),
        ("beginWatermarkEditing()", store, EDITOR_STORE),
    ]:
        if token not in source:
            failures.append({
                "code": "editor_step_composite_component_contract_missing",
                "path": rel(path),
                "detail": token,
            })
    for token, source, path in [
        ("public func hitKind(", geometry, CORE_GEOMETRY),
        ("editingBaseElement(from element:", controls, EDITOR_CONTROLS),
        ("context.setBlendMode(.copy)", renderer, CORE_RENDERER),
    ]:
        if token not in source:
            failures.append({
                "code": "editor_transparent_preview_contract_missing",
                "path": rel(path),
                "detail": token,
            })

    for obsolete, source, path in [
        ("moreToolsFocusRequestID", view, EDITOR_VIEW),
        ("connectorAttachment = layout.connectorAttachment", store, EDITOR_STORE),
        ("connectorAttachment = layout?.connectorAttachment", store, EDITOR_STORE),
    ]:
        if obsolete in source:
            failures.append({
                "code": "editor_stale_focus_or_connector_state_remaining",
                "path": rel(path),
                "detail": obsolete,
            })
    # Scoped content measurement, dedicated overflow cue columns and independent
    # surfaces are checked (and mutation-tested) by editor_layout_contract_failures.
    for token in [
        "ScreenshotEditorToolbarPanelLayout(maximumWidth: maximumWidth)",
        "expandedContent.fixedSize(horizontal: true, vertical: false)",
        "let layout = toolbarLayout(availableWidth:",
        "bottomToolbarContainer(\n                    layout: layout,\n                    maximumWidth: maximumChromeWidth",
    ]:
        if token not in view:
            failures.append({
                "code": "editor_toolbar_compact_alignment_missing",
                "path": rel(EDITOR_VIEW),
                "detail": token,
            })
    for token in [
        ".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)",
        "isAspectRatioPresented",
    ]:
        if token in unified_toolbar:
            failures.append({
                "code": "editor_toolbar_obsolete_layout_remaining",
                "path": rel(EDITOR_VIEW),
                "detail": token,
            })

    for obsolete in [
        "case let .magnifier(_, lens)",
        ".magnifier(source:",
    ]:
        if obsolete in canvas or obsolete in view or obsolete in store:
            failures.append({
                "code": "editor_step_or_magnifier_obsolete_interaction_remaining",
                "path": rel(EDITOR_CANVAS),
                "detail": obsolete,
            })

    # A magnifier is an in-place crop annotation. Its interaction, accessibility,
    # document normalization, render planning, and final draw must all resolve
    # against the active crop. Keeping any of those paths on sourceBounds revives
    # the old dual-geometry behavior where the lens can escape the exported crop.
    magnifier_crop_contracts = [
        (CORE_DOCUMENT, document, [
            (
                "document normalizes magnifiers whenever the snapshot changes",
                r"private func normalizedSnapshot\([\s\S]*?normalized\.elements = normalized\.elements\.map",
            ),
            (
                "document resolves magnifier geometry against normalized crop",
                r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*cropRect",
            ),
            (
                "document persists the crop-resolved lens center and diameter",
                r"next\.geometry = \.magnifier\(center: layout\.center\)[\s\S]{0,120}?next\.appearance\.magnifierDiameter = layout\.diameter",
            ),
        ]),
        (EDITOR_STORE, store, [
            (
                "store hit testing is clipped to the active crop",
                r"ScreenshotGeometry\.hitResults\([\s\S]{0,260}?constrainedTo:\s*cropRect",
            ),
            (
                "store resolves magnifier lens geometry against the active crop",
                r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*cropRect",
            ),
            (
                "store magnifier resize is constrained to the active crop",
                r"case let \.resizingMagnifier[\s\S]{0,900}?constrainedTo:\s*cropRect",
            ),
            (
                "store magnifier creation derives available space from the active crop",
                r"case \.magnifier:[\s\S]{0,360}?let magnifierBounds = cropRect",
            ),
        ]),
        (EDITOR_CANVAS, canvas, [
            (
                "canvas accessibility bounds resolve magnifiers against the active crop",
                r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*cropRect",
            ),
            (
                "canvas pointer hit testing is clipped to the drawn crop",
                r"ScreenshotGeometry\.hitResults\([\s\S]{0,260}?constrainedTo:\s*cropRectForDrawing",
            ),
            (
                "canvas selection and handles resolve magnifiers against the drawn crop",
                r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*cropRectForDrawing",
            ),
        ]),
        (CORE_RENDERER, renderer, [
            (
                "renderer derives a local output crop for final drawing",
                r"let localOutputRect = ScreenshotPixelRect\(",
            ),
            (
                "renderer final magnifier draw is constrained to the local output crop",
                r"drawMagnifier\([\s\S]{0,260}?constrainedTo:\s*localOutputRect",
            ),
            (
                "renderer resolves final lens geometry through the shared crop-constrained layout",
                r"ScreenshotMagnifierResolvedLayout\(element: element, constrainedTo: canvas\)",
            ),
            (
                "renderer planning resolves magnifier sampling against outputRect",
                r"case let \.magnifier\(appearance\)[\s\S]{0,420}?magnifierRenderGeometry\([\s\S]{0,260}?constrainedTo:\s*\.init\([\s\S]{0,160}?x:\s*Int\(outputRect\.minX\)",
            ),
        ]),
    ]
    for path, source, contracts in magnifier_crop_contracts:
        for detail, pattern in contracts:
            if re.search(pattern, source) is None:
                failures.append({
                    "code": "magnifier_crop_constraint_contract_missing",
                    "path": rel(path),
                    "detail": detail,
                })

    magnifier_source_bounds_regressions = [
        (
            CORE_DOCUMENT,
            document,
            r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*sourceBounds",
            "document magnifier normalization must not use sourceBounds",
        ),
        (
            EDITOR_STORE,
            store,
            r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*sourceBounds",
            "store magnifier geometry must not use sourceBounds",
        ),
        (
            EDITOR_STORE,
            store,
            r"let magnifierBounds = sourceBounds",
            "store magnifier creation or clamping must not use sourceBounds",
        ),
        (
            EDITOR_CANVAS,
            canvas,
            r"ScreenshotMagnifierResolvedLayout\([\s\S]{0,220}?constrainedTo:\s*sourceBounds",
            "canvas magnifier geometry must not use sourceBounds",
        ),
        (
            CORE_RENDERER,
            renderer,
            r"drawMagnifier\([\s\S]{0,260}?constrainedTo:\s*sourceBounds",
            "renderer magnifier draw must not use sourceBounds",
        ),
        (
            CORE_RENDERER,
            renderer,
            r"magnifierRenderGeometry\([\s\S]{0,260}?canvas:\s*sourceBounds",
            "renderer magnifier planning must not use sourceBounds",
        ),
    ]
    for path, source, pattern, detail in magnifier_source_bounds_regressions:
        if re.search(pattern, source):
            failures.append({
                "code": "magnifier_source_bounds_dual_track_remaining",
                "path": rel(path),
                "detail": detail,
            })

    property_strip = controls.partition("struct ScreenshotAspectRatioPropertyStrip")[2].partition(
        "struct ScreenshotNumericValueDescriptor"
    )[0]
    for token in [
        "screenshot.aspect.returnToPresets",
        "ScreenshotCustomModeSegmentedControl",
        "ScreenshotFocusRequestCoordinator",
        "targetDidMoveToWindow()",
        "customModeFocusRequestID",
        "ScreenshotCustomTriggerButton",
        "customTriggerFocusRequestID",
        "ScreenshotAspectPresetMenu",
        "ForEach(savedConstraints)",
        "currentConstraint: model.previewConstraint",
        "cancelOperation",
    ]:
        if token not in property_strip:
            failures.append({
                "code": "editor_aspect_focus_accessibility_contract_missing",
                "path": rel(EDITOR_CONTROLS),
                "detail": token,
            })
    for obsolete in [
        "deferredFocusWorkItem",
        "DispatchQueue.main.asyncAfter(deadline: .now() + 0.08",
        "DispatchQueue.main.asyncAfter(deadline: .now() + 0.12",
    ]:
        if obsolete in controls:
            failures.append({
                "code": "editor_aspect_wall_clock_focus_retry_remaining",
                "path": rel(EDITOR_CONTROLS),
                "detail": obsolete,
            })
    for token in ["synchronizeCustomDraft(with:", "ScreenshotOrientationGlyphLayout"]:
        if token not in controls:
            failures.append({
                "code": "editor_aspect_selection_sync_contract_missing",
                "path": rel(EDITOR_CONTROLS),
                "detail": token,
            })
    for obsolete in [
        "ScreenshotAspectChip",
        "ScreenshotSavedAspectChip",
        "ScreenshotAspectMiniPreview",
        ".popover(isPresented:",
    ]:
        if obsolete in property_strip:
            failures.append({
                "code": "editor_aspect_obsolete_chip_or_subpanel_remaining",
                "path": rel(EDITOR_CONTROLS),
                "detail": obsolete,
            })

    capture_saved_presets = controls.partition("private var savedPresets: some View")[2].partition(
        "private func iconName(for constraint:"
    )[0]
    for token in [
        "model.canonicalConstraint",
        ".accessibilityAddTraits(selected ? .isSelected : [])",
        "if let neighbor",
        "focusInitialControl()",
    ]:
        if token not in capture_saved_presets:
            failures.append({
                "code": "capture_aspect_saved_preset_state_or_focus_missing",
                "path": rel(EDITOR_CONTROLS),
                "detail": token,
            })
    for token in [
        "quickToolStripWidth",
        "expandedToolStripWidth",
        "maximumWidth: min(620",
        "max(620",
        "ScreenshotControlMetrics",
    ]:
        if token in view:
            failures.append({
                "code": "editor_toolbar_changes_outer_width_when_expanded",
                "path": rel(EDITOR_VIEW),
                "detail": token,
            })
    chrome_ocr_placement_tokens = [
        "enum ScreenshotFloatingPanelLayout",
        "static func frame(",
        "candidateOrigins",
        "visibleBounds.insetBy",
        "safeBounds.contains",
        "intersectionArea(",
        "let intersection = lhs.intersection(rhs)",
        "clampedOrigin",
    ]
    for token in chrome_ocr_placement_tokens:
        if token not in chrome_layout:
            failures.append({
                "code": "editor_ocr_visible_region_placement_missing",
                "path": rel(EDITOR_CHROME_LAYOUT),
                "detail": token,
            })
    for token in [
        "manualOCRPanelFrame(in: proxy.size, toolbarFrame: frames.toolbar)",
        "anchorFrame: toolbarFrame",
    ]:
        if token not in view:
            failures.append({
                "code": "editor_ocr_toolbar_anchor_missing",
                "path": rel(EDITOR_VIEW),
                "detail": token,
            })
    for token in [
        "ScreenshotDesignTokens.ocrPanelSize",
        "width: ScreenshotDesignTokens.ocrPanelSize.width",
        "height: ScreenshotDesignTokens.ocrPanelSize.height",
    ]:
        if token not in ocr:
            failures.append({
                "code": "editor_ocr_shared_panel_size_contract_missing",
                "path": rel(EDITOR_OCR),
                "detail": token,
            })
    if "CGSize(width: 360, height: 260)" in view or "CGSize(width: 360, height: 260)" in ocr:
        failures.append({
            "code": "editor_ocr_private_panel_size_literal_restored",
            "path": rel(EDITOR_VIEW if "CGSize(width: 360, height: 260)" in view else EDITOR_OCR),
        })
    required_preferences = [
        "currentVersion = 19",
        "ScreenshotCustomConstraintPreset",
        "customConstraints",
        "confirmsDiscardBeforeClosing",
        "case aspectRatio",
        "case step",
        "case watermark",
        "recentColors",
        "quickToolIDs",
        "hiddenToolIDs",
        "visibleExtendedToolbarItemIDs",
    ]
    required_presenter = [
        "final class ScreenshotEditorPresenter",
        "final class ScreenshotEditorHostPanel",
        "private var hostPanel: ScreenshotEditorHostPanel?",
        "static func makeHostPanel(frame:",
        "ScreenshotEditorHostView(",
        "onFirstFrameRendered:",
        "NSHostingView",
        "capture.editingContext?.sourceFrame",
        "panel.orderFrontRegardless()",
        "styleMask: [.borderless, .closable, .nonactivatingPanel]",
        "override var canBecomeMain: Bool { false }",
        "prepareForNewCapture() async",
        "store?.shutdown()",
        "requestRetake",
        "await store.completeForReplacement() else { return false }",
        "final class ScreenshotEditorCloseConfirmationCoordinator",
        "alert.beginSheetModal(for: window",
        "alert.showsSuppressionButton = true",
        "suppressesFutureConfirmation",
        "confirmsDiscardBeforeClosing",
        "func decision(on window: NSWindow) async",
        "switch await dirtyDocumentDecision()",
        "closeConfirmationCoordinator.present(on: panel)",
        "var onEscape: (() -> Void)?",
        "override func sendEvent(_ event: NSEvent)",
        "panel.onEscape = store.handleEscape",
        "PinnedScreenshotManager",
        "await presenter.pinSession(",
        "await finishSession(.pinned(presentation.image), sessionID: sessionID)",
    ]
    required_pinned_screenshot = [
        "struct PinnedScreenshotPresentation",
        "logicalSize: CGSize",
        "outputPixelScale: CGFloat",
        "preferredScreenFrame: CGRect",
        "targetVisibleFrame: CGRect",
        "enum PinnedScreenshotGeometry",
        "CGFloat(initialCropRect.width) / sourceRect.width",
        "CGFloat(cropRect.height) / scale",
        "sourceFrame.maxY - CGFloat(cropRect.y + cropRect.height) / scale",
        "PinnedScreenshotGeometry.initialFrame(",
        "sourceSize: presentation.logicalSize",
        "role: .panel",
    ]
    for code, path, source, required in [
        ("scene_document_contract_missing", CORE_DOCUMENT, document, required_document),
        ("scene_renderer_contract_missing", CORE_RENDERER, renderer, required_renderer),
        ("editor_mode_contract_missing", CORE_PREFERENCES, preferences, required_preferences),
        ("editor_store_contract_missing", EDITOR_STORE, store, required_store),
        ("editor_state_slice_contract_missing", EDITOR_STATE, state, required_state),
        ("editor_render_pipeline_contract_missing", RENDER_PIPELINE, render_pipeline, required_render_pipeline),
        ("editor_dual_surface_contract_missing", EDITOR_VIEW, view, required_view),
        ("editor_canvas_contract_missing", EDITOR_CANVAS, canvas_input, required_canvas),
        ("editor_presenter_contract_missing", EDITOR_PRESENTER, presenter, required_presenter),
        ("pinned_screenshot_presentation_contract_missing", PINNED_SCREENSHOT, pinned_screenshot, required_pinned_screenshot),
    ]:
        missing = [token for token in required if token not in source]
        if missing:
            failures.append({"code": code, "path": rel(path), "detail": ", ".join(missing)})

    for obsolete in [
        "ignoresMouseEvents = true",
        "func lock()",
        "func unlock()",
        "screenshot.pin.lock",
        "screenshot.pin.unlock",
    ]:
        if obsolete in pinned_screenshot:
            failures.append({
                "code": "pinned_screenshot_click_through_contract_remaining",
                "path": rel(PINNED_SCREENSHOT),
                "detail": obsolete,
            })

    project_tokens = [
        "ScreenshotEditorStore.swift in Sources",
        "ScreenshotEditorState.swift in Sources",
        "ScreenshotRenderPipeline.swift in Sources",
        "ScreenshotEditorView.swift in Sources",
        "ScreenshotEditorCanvas.swift in Sources",
        "ScreenshotEditorControls.swift in Sources",
        "ScreenshotEditorPresenter.swift in Sources",
        "ScreenshotAppStateTests.swift in Sources",
        "ScreenshotBadgeTextLayout.swift in Sources",
        "ScreenshotOutput.swift in Sources",
        "ScreenshotWatermark.swift in Sources",
        "PinnedScreenshotManager.swift in Sources",
    ]
    missing_project = [token for token in project_tokens if token not in project]
    if missing_project:
        failures.append({
            "code": "editor_target_membership_missing",
            "path": rel(PROJECT),
            "detail": ", ".join(missing_project),
        })

    chrome_file_ref = re.search(
        r"(?P<ref>[A-Za-z0-9]+) /\* ScreenshotEditorChromeLayout\.swift \*/ = "
        r"\{isa = PBXFileReference;[^}]*?path = Features/Screenshot/Editor/"
        r"ScreenshotEditorChromeLayout\.swift;",
        project,
    )
    chrome_build_file = re.search(
        r"(?P<build>[A-Za-z0-9]+) /\* ScreenshotEditorChromeLayout\.swift in Sources \*/ = "
        r"\{isa = PBXBuildFile; fileRef = (?P<ref>[A-Za-z0-9]+) /\* "
        r"ScreenshotEditorChromeLayout\.swift \*/; \};",
        project,
    )
    blocks_target = re.search(
        r"[A-Za-z0-9]+ /\* Blocks \*/ = \{\s*isa = PBXNativeTarget;[\s\S]*?"
        r"buildPhases = \((?P<phases>[\s\S]*?)\);",
        project,
    )
    source_phase_ids = (
        re.findall(r"([A-Za-z0-9]+) /\* Sources \*/", blocks_target.group("phases"))
        if blocks_target else []
    )
    chrome_in_blocks_sources = False
    for source_phase_id in source_phase_ids:
        source_phase = re.search(
            rf"{re.escape(source_phase_id)} /\* Sources \*/ = \{{\s*isa = "
            rf"PBXSourcesBuildPhase;[\s\S]*?files = \((?P<files>[\s\S]*?)\);\s*"
            rf"runOnlyForDeploymentPostprocessing = 0;\s*\}};",
            project,
        )
        if source_phase and chrome_build_file and re.search(
            rf"{re.escape(chrome_build_file.group('build'))} /\* "
            rf"ScreenshotEditorChromeLayout\.swift in Sources \*/",
            source_phase.group("files"),
        ):
            chrome_in_blocks_sources = True
            break
    if (
        chrome_file_ref is None
        or chrome_build_file is None
        or chrome_build_file.group("ref") != chrome_file_ref.group("ref")
        or not chrome_in_blocks_sources
    ):
        failures.append({
            "code": "editor_chrome_layout_target_membership_missing",
            "path": rel(PROJECT),
            "detail": "ScreenshotEditorChromeLayout.swift must be a file reference, a build file, and a Blocks Sources member",
        })

    bottom_toolbar = swift_scope(view, "private func bottomToolbarContainer")
    ordered_bottom_tokens = [
        "ScreenshotUnifiedEditorToolbar(",
        "ScreenshotExpandedPropertiesRow(",
    ]
    bottom_positions = [bottom_toolbar.find(token) for token in ordered_bottom_tokens]
    if any(position < 0 for position in bottom_positions) or bottom_positions != sorted(bottom_positions):
        failures.append({
            "code": "editor_main_toolbar_property_row_order_regressed",
            "path": rel(EDITOR_VIEW),
            "detail": "main toolbar must precede its separate content-sized property row",
        })
    if ".blocksSurface(.panel" not in bottom_toolbar:
        failures.append({
            "code": "editor_main_toolbar_panel_surface_missing",
            "path": rel(EDITOR_VIEW),
        })
    # Layout.placeSubviews now applies canvas/status/toolbar frames together;
    # the scoped assertion above rejects missing measurement or missing placement.

    forbidden_tokens = [
        "ScreenshotEditCommand",
        "setToolbarState(",
        "initialToolbarState",
        "ScreenshotEditorLayout",
        "ScreenshotEditorMode",
        "quickOverlay",
        "fullEditor",
        "ScreenshotQuickEditorView",
        "struct ScreenshotEditorView: View",
        "presentMode(",
        "fullEditorFrame",
        "fullEditorCropLimit",
        "ScreenshotFullEditorWindow",
        "ScreenshotQuickEditorPanel",
        "private var toolRail",
        "case professional",
        "case .professional",
        "professionalLayout",
        "compactLayout",
        "ColorPicker(\"\"",
        "ScreenshotEditorTool.crop",
    ]
    for path, source in [
        (CORE_DOCUMENT, document),
        (CORE_PREFERENCES, preferences),
        (EDITOR_STORE, store),
        (EDITOR_VIEW, view),
        (EDITOR_CANVAS, canvas),
        (EDITOR_PRESENTER, presenter),
    ]:
        remaining = [token for token in forbidden_tokens if token in source]
        if remaining:
            failures.append({
                "code": "legacy_editor_contract_remaining",
                "path": rel(path),
                "detail": ", ".join(remaining),
            })

    forbidden_store_tokens = [
        "renderCurrent()",
        "cachedOutputImage() ?? renderCurrent()",
        "renderer.render(sourceContext:",
    ]
    remaining_store = [token for token in forbidden_store_tokens if token in store]
    if remaining_store:
        failures.append({
            "code": "synchronous_editor_output_path_remaining",
            "path": rel(EDITOR_STORE),
            "detail": ", ".join(remaining_store),
        })

    forbidden_renderer_tokens = [
        "var image = source",
        "private func draw(_ element: ScreenshotElement, on image: CGImage)",
        "let localElements = snapshot.elements.map",
    ]

    if "sourceTiles" in document:
        failures.append({
            "code": "duplicate_source_tiles_retained",
            "path": rel(CORE_DOCUMENT),
            "detail": "source context must retain descriptors and one composite image only",
        })
    remaining_renderer = [token for token in forbidden_renderer_tokens if token in renderer]
    if remaining_renderer:
        failures.append({
            "code": "full_source_per_element_renderer_remaining",
            "path": rel(CORE_RENDERER),
            "detail": ", ".join(remaining_renderer),
        })

    text_layout_contracts = [
        (CORE_DOCUMENT, document, [
            "struct ScreenshotTextLayout",
            "PingFangSC-Regular",
            "PingFangSC-Medium",
            "PingFangSC-Semibold",
            "case .semibold, .bold",
            "characterSpacing = 0",
            "lineHeight = fontSize * max(0.8, appearance.textLineSpacing)",
            "viewMetrics(sourceUnitsPerViewPoint:",
            "sourceUnitsPerViewPoint > 0 ? sourceUnitsPerViewPoint : 1",
            "ScreenshotResolvedColor(",
            "backgroundColor",
        ]),
        (CORE_RENDERER, renderer, [
            "ScreenshotTextLayout(appearance: element.appearance)",
            "CTFramesetterCreateWithAttributedString",
            "CTFramesetterCreateFrame",
            "CTFrameDraw",
        ]),
        (EDITOR_CANVAS, canvas_input, [
            "ScreenshotInlineTextAttributes(",
            "sourceUnitsPerViewPoint",
            "lineFragmentPadding = 0",
            "ScreenshotTextLayout.defaultMaximumAutoWidth",
            "textContainerInset = NSSize",
            "layout.measure(",
            "drawDraftText(",
            "editor.drawsBackground = resolved.drawsBackground",
            "editor.backgroundColor = resolved.backgroundColor",
            "editor.markedTextAttributes = resolved.mergingMarkedTextAttributes",
            "editor.typingAttributes = resolved.attributes",
            "selectedRange()",
            "markedRange()",
            "addAttributes(resolved.attributes, range:",
            "override func setMarkedText(",
            "ScreenshotInlineMarkedTextResolver.resolve(",
            "resolved.enumerateAttributes(",
            "textStorage?.addAttributes(resolvedMarkedTextAttributes, range: range)",
            "editor.onMarkedTextChange = { [weak self] in self?.resizeActiveTextEditor() }",
            "onMarkedTextChange?()",
        ]),
    ]
    for path, source, required in text_layout_contracts:
        missing = [token for token in required if token not in source]
        if missing:
            failures.append({
                "code": "text_layout_contract_missing",
                "path": rel(path),
                "detail": ", ".join(missing),
            })

    forbidden_text_renderer_tokens = [
        "text.split(separator: \"\\n\"",
        "Helvetica-Bold",
    ]
    remaining_text_renderer = [token for token in forbidden_text_renderer_tokens if token in renderer]
    if remaining_text_renderer:
        failures.append({
            "code": "manual_text_layout_remaining",
            "path": rel(CORE_RENDERER),
            "detail": ", ".join(remaining_text_renderer),
        })

    controls_contract = [
        "final class ScreenshotAspectControlModel",
        "struct ScreenshotAspectRatioCapturePopover",
        "struct ScreenshotAspectRatioPropertyStrip",
        "enum ScreenshotAspectRatioPanelMetrics",
        "static let width: CGFloat = 420",
        "static let presetColumnCount = 3",
        "static let savedColumnCount = 3",
        "ScreenshotPreferences.normalizedCustomConstraint(.ratio(width: width, height: height))",
        "ScreenshotPreferences.normalizedCustomConstraint(.fixedPixels(width: width, height: height))",
        ".blocksImmediateTooltip(model.invalidMessage)",
        ".accessibilityHint(model.customConstraint == nil ? model.invalidMessage : \"\")",
        "static let customModeWidth: CGFloat = 96",
        "static let customVisibleRowWidth",
        "private var customModeControl",
        "static let orientationGlyphSize = CGSize(width: 20, height: 20)",
        "screenshot.aspect.title",
        "screenshot.aspect.presets",
        "struct ScreenshotOrientationGlyph",
        "private struct ScreenshotAspectPresetMenu",
        "ScreenshotAspectOrientation.landscape",
        "ScreenshotAspectOrientation.portrait",
        "struct ScreenshotNumericSlider",
        "struct ScreenshotNumericField",
        "struct ScreenshotColorPickerButton",
        "frame(width: 20, height: 20)",
        "screenshot.editor.color.common",
        "screenshot.editor.color.recent",
        "ScreenshotColorPanelController",
        "ScreenshotColorPanelWindowBridge",
        "ScreenshotColorSwatch",
        "ScreenshotCustomConstraintMode",
        "screenshot.common.saveAndApply",
        "enum ScreenshotStepEditorLayout",
    ]
    missing_controls = [token for token in controls_contract if token not in controls]
    if missing_controls:
        failures.append({
            "code": "editor_control_contract_missing",
            "path": rel(EDITOR_CONTROLS),
            "detail": ", ".join(missing_controls),
        })

    more_tools_contract = [
        "enum ScreenshotMoreToolsPanelMetrics",
        "case 1: 176",
        "case 2: 224",
        "default: 320",
        "ScreenshotMoreToolsPanelMetrics.panelWidth(toolCount: tools.count)",
    ]
    missing_more_tools = [token for token in more_tools_contract if token not in view]
    if missing_more_tools:
        failures.append({
            "code": "more_tools_width_contract_missing",
            "path": rel(EDITOR_VIEW),
            "detail": ", ".join(missing_more_tools),
        })

    interaction_contract = [
        "ScreenshotToolCursorProvider.cursor(for: selectedTool)",
        "ScreenshotToolCursorProvider.cursor(for: cropHandle)",
        "case .step:",
        "inlineTextEditRequestID",
        "NSCursor.arrow.set()",
    ]
    missing_interaction = [token for token in interaction_contract if token not in canvas]
    if missing_interaction:
        failures.append({
            "code": "editor_interaction_contract_missing",
            "path": rel(EDITOR_CANVAS),
            "detail": ", ".join(missing_interaction),
        })

    payload = {"gate": "P14-C", "status": "pass" if not failures else "fail", "failures": failures}
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
