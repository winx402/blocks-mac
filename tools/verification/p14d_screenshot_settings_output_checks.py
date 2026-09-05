#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps/Blocks/BlocksApp"
CORE = ROOT / "apps/Blocks/BlocksScreenshotCore"
PROJECT = ROOT / "apps/Blocks/Blocks.xcodeproj/project.pbxproj"
L10N = APP / "Support/L10n.swift"
PREFERENCES = CORE / "ScreenshotPreferences.swift"
PREFERENCES_STORE = APP / "Features/Screenshot/Settings/ScreenshotPreferencesStore.swift"
SETTINGS_PANE = APP / "Features/Screenshot/Settings/ScreenshotSettingsPane.swift"
SETTINGS_COMPONENTS = APP / "Features/Settings/SettingsSectionList.swift"
TOOL_STRIP_BRIDGE = APP / "Features/Screenshot/Settings/ScreenshotToolStripBridge.swift"
SELECTION_TOOLBAR = APP / "Features/Screenshot/Capture/ScreenshotSelectionToolbar.swift"
SCREENSHOT_LOCALIZABLE = APP / "Features/Screenshot/Resources/ScreenshotLocalizable.xcstrings"
EDITOR_CONTROLS = APP / "Features/Screenshot/Editor/ScreenshotEditorControls.swift"
EDITOR_VIEW = APP / "Features/Screenshot/Editor/ScreenshotEditorView.swift"
WATERMARK_VIEWS = APP / "Features/Screenshot/Settings/ScreenshotWatermarkViews.swift"
WATERMARK_ASSET_STORE = APP / "Features/Screenshot/Settings/ScreenshotWatermarkAssetStore.swift"
SCREENSHOT_STORE = APP / "Features/Screenshot/ScreenshotStore.swift"


def require(path: Path, tokens: list[str], failures: list[dict]) -> None:
    if not path.exists():
        failures.append({"code": "missing_file", "path": str(path.relative_to(ROOT))})
        return
    text = path.read_text()
    missing = [token for token in tokens if token not in text]
    if missing:
        failures.append({"code": "missing_contract", "path": str(path.relative_to(ROOT)), "detail": missing})


failures: list[dict] = []
settings_text = SETTINGS_PANE.read_text() if SETTINGS_PANE.exists() else ""
selection_toolbar_text = SELECTION_TOOLBAR.read_text() if SELECTION_TOOLBAR.exists() else ""
editor_controls_text = EDITOR_CONTROLS.read_text() if EDITOR_CONTROLS.exists() else ""
editor_view_text = EDITOR_VIEW.read_text() if EDITOR_VIEW.exists() else ""
require(L10N, ["ScreenshotLocalizable", "localizedString(forKey:"], failures)
require(
    PREFERENCES,
    [
        "public struct ScreenshotPreferences: Codable",
        "currentVersion = 19",
        "ScreenshotCustomConstraintPreset",
        "customConstraints",
        "watermarkPresets",
        "saveWatermarkPreset",
        "removeWatermarkPreset",
        "saveCustomConstraint",
        "removeCustomConstraint",
        "retainsCaptureDefaults",
        "confirmsDiscardBeforeClosing",
        "toolOrder",
        "quickToolIDs",
        "hiddenToolIDs",
        "visibleQuickToolbarItemIDs",
        "visibleExtendedToolbarItemIDs",
        "defaultQuickTools",
        "commandToolIDs",
        "normalizedQuickToolIDs",
        "init(from decoder: Decoder)",
        "toolPresets",
        "defaultToolPresets",
        "ScreenshotToolPreset(tool:",
        "tool != .line",
        "case .line: self = .arrow",
        ".counter",
        ".callout",
        ".spotlight",
        ".redact",
        ".magnifier",
        ".step",
        ".watermark",
        "recentColors",
        "recordRecentColor",
        "outputFormat",
    ],
    failures,
)
require(
    PREFERENCES_STORE,
    [
        "final class ScreenshotPreferencesStore: ObservableObject",
        "screenshot.preferences.v19",
        "legacyV18StorageKey = \"screenshot.preferences.v18\"",
        "legacyV17StorageKey = \"screenshot.preferences.v17\"",
        "legacyV16StorageKey = \"screenshot.preferences.v16\"",
        "legacyV15StorageKey = \"screenshot.preferences.v15\"",
        "legacyV14StorageKey = \"screenshot.preferences.v14\"",
        "legacyV13StorageKey = \"screenshot.preferences.v13\"",
        "decoder.decode(ScreenshotPreferences.self",
        "persistMigration(removing:",
        "JSONEncoder",
        "JSONDecoder",
        "moveTool",
        "to zone: ScreenshotToolZone",
        "before target: ScreenshotToolbarItemID?",
        "ScreenshotPreferences(",
        "resetEditorDefaults",
        "resetToolConfiguration",
        "updateCaptureDefaultsFromSession",
        "sessionDefaults.watermarkPresetID = $0.captureDefaults.watermarkPresetID",
        "recordRecentColor",
        "saveCustomConstraint",
        "removeCustomConstraint",
        "watermarkAssetStore",
        "saveWatermarkPreset",
        "removeWatermarkPreset",
    ],
    failures,
)
require(
    WATERMARK_VIEWS,
    [
        "struct ScreenshotWatermarkSettingsLibrary",
        "struct ScreenshotWatermarkPresetEditor",
        "defaultPresetBinding",
        ".pickerStyle(.menu)",
        ".frame(width: 180, alignment: .trailing)",
        ".accessibilityLabel(L10n.string(\"settings.screenshot.watermarks.default\"))",
        "ScreenshotWatermarkStyle",
        "fontSizeFraction",
        "density",
        "angleDegrees",
        "opacity",
    ],
    failures,
)
require(
    WATERMARK_ASSET_STORE,
    [
        "v19 no longer stores binary watermark assets",
        "func cleanupOrphans",
        "fileManager.removeItem(at: entry)",
    ],
    failures,
)
require(
    EDITOR_CONTROLS,
    [
        "final class ScreenshotAspectControlModel",
        "struct ScreenshotAspectRatioCapturePopover",
        "struct ScreenshotAspectRatioPropertyStrip",
        "ScreenshotNonTextFocusSink",
        "focusSinkRequestID",
        "window.initialFirstResponder = self",
        "NSWindow.didBecomeKeyNotification",
        "ScreenshotAspectOrientation",
        "struct ScreenshotNumericSlider",
        "struct ScreenshotNumericField",
        "struct ScreenshotNumericFieldDraft",
        "originalValue",
        "committedValue",
        "struct ScreenshotColorPickerButton",
        "commonColors",
        "recentColors",
        "hexRGB",
        "ScreenshotColorPanelController",
        "ScreenshotColorPanelWindowBridge",
        "ScreenshotCustomConstraintMode",
        "ScreenshotOrientationGlyph",
        "ScreenshotAspectPresetMenu",
        "screenshot.common.saveAndApply",
        "static let customControlHeight: CGFloat = 26",
        "static let customControlHitHeight: CGFloat = 28",
        "static let customVisibleRowWidth",
        "static let customClusterSpacing",
        "private var customModeControl",
        ".accessibilityAdjustableAction",
        ".controlSize(.small)",
        ".tint(.accentColor)",
    ],
    failures,
)

capture_aspect_popover = editor_controls_text.partition("struct ScreenshotAspectRatioCapturePopover")[2].partition(
    "struct ScreenshotAspectRatioPropertyStrip"
)[0]
for obsolete in [
    '.pickerStyle(.segmented)',
    "customRowMinimumGap",
    "Spacer(minLength:",
]:
    if obsolete in capture_aspect_popover:
        failures.append({
            "code": "screenshot_aspect_custom_row_native_inset_remaining",
            "path": str(EDITOR_CONTROLS.relative_to(ROOT)),
            "detail": obsolete,
        })
require(
    SETTINGS_PANE,
    [
        "struct ScreenshotSettingsPane",
        "ScreenshotToolbarItemID",
        "ScreenshotToolZone",
        "onMoveTool: moveTool",
        "ScreenshotCaptureDefaultsRows",
        "ScreenshotAspectRatioCapturePopover",
        "Picker(\"\", selection: $defaults.delaySeconds)",
        "SettingsBooleanSwitch(",
        "Picker(\"\", selection: watermarkPresetBinding)",
        "private var watermarkPresetBinding",
        "ScreenshotEditorLayoutPreview",
        "ScreenshotEditorToolbarLayout.resolve(",
        "edgeMargin: 0",
        ".frame(width: layout.width, height: ScreenshotDesignTokens.toolbarMainHeight)",
        "ScreenshotEditorConfigurationSheet",
        "ScreenshotUnifiedToolConfigurationSimulator",
        "ScreenshotToolZonesBoardBridge",
        "ScreenshotToolZonesSnapshot",
        "hiddenTools: preferences.hiddenToolIDs",
        "onMoveTool: onMoveTool",
        "ScreenshotToolZonesBoardMetrics.requiredHeight",
        ".frame(maxHeight: 520)",
        "@State private var focusedTool: ScreenshotToolbarItemID?",
        "refocus(tool)",
        "settings.screenshot.tools.configureNamed",
        "label: configureAccessibilityLabel(",
        "ScreenshotSettingsWorkbench",
        "resetCaptureDefaults",
        "resetEditorDefaults",
        "resetOutputDefaults",
        "resetToolConfiguration",
        "SettingsFormRow",
        "SettingsNavigationRow",
        "BlocksNotificationPresentationState",
        "BlocksNotificationHost",
        ".frame(width: 640)",
        ".fixedSize(horizontal: false, vertical: true)",
    ],
    failures,
)
require(
    TOOL_STRIP_BRIDGE,
    [
        "struct ScreenshotToolZonesBoardBridge: NSViewRepresentable",
        "final class ScreenshotToolZonesBoardView: NSView",
        "struct ScreenshotToolZonesSnapshot: Equatable",
        "struct ScreenshotToolDropIntent: Equatable",
        "NSScrollView()",
        "ScreenshotToolCollectionView()",
        "enum ScreenshotToolDragPlacement",
        "struct Payload: Equatable",
        "sourceZone: ScreenshotToolZone",
        "sourceIndex: Int",
        "static func insertionIndex(atX locationX: CGFloat, toolCount: Int)",
        "static func intent(",
        "NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))",
        "NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))",
        "private func handlePointerDrag(",
        "func beginPointerDrag(",
        "func updatePointerDrag(atWindowPoint windowPoint: CGPoint)",
        "func completePointerDrag(atWindowPoint windowPoint: CGPoint)",
        "func cancelPointerDrag()",
        "host.collectionView.toolZone = zone",
        "pendingSnapshot = nextSnapshot",
        "card.host.showInsertionIndicator(at: insertionIndex)",
        "width: 2",
        "card.host.hideInsertionIndicator()",
        "ScreenshotToolDragPlacement.intent(",
        "onMoveTool?(intent.tool, intent.destinationZone, intent.beforeTool)",
        "horizontalScrollElasticity = .automatic",
        "hasHorizontalScroller = false",
        "tooltipHost?.show",
        "setAccessibilityCustomActions",
        "override func keyDown(with event: NSEvent)",
        "override func menu(for event: NSEvent)",
        "settings.screenshot.tools.moveToQuick",
        "settings.screenshot.tools.moveToExpanded",
        "settings.screenshot.tools.moveToHidden",
        "var nextZone: ScreenshotToolZone",
    ],
    failures,
)
for obsolete in [
    "matching: [.leftMouseDragged, .leftMouseUp]",
    "beginDraggingSession(with:",
    "pasteboardWriterForItemAt",
    "canDragItemsAt indexPaths",
    "draggingSession session: NSDraggingSession",
    "registerForDraggedTypes(",
    "setDraggingSourceOperationMask(",
    "validateDrop draggingInfo: NSDraggingInfo",
    "acceptDrop draggingInfo: NSDraggingInfo",
    "proposedDropOperation.pointee = .before",
    "DispatchQueue.main.async {",
]:
    if obsolete in TOOL_STRIP_BRIDGE.read_text():
        failures.append({
            "code": "screenshot_tool_strip_duplicate_drag_source_remaining",
            "path": str(TOOL_STRIP_BRIDGE.relative_to(ROOT)),
            "detail": obsolete,
        })
require(
    SELECTION_TOOLBAR,
    [
        "scrollingButton.isHidden = !showsScrollingMode",
        "if showsScrollingMode {",
        "let parameterControls: [NSView]",
        "spacing: presentation.parameterControlSpacing",
        "BlocksAppKitGlassSurfaceView",
        "BlocksAppKitSurfaceConfiguration(",
        "role: .panel",
        "BlocksAppKitCompactButton",
        "ScreenshotParameterValueButton",
        "ScreenshotFreezeValueButton",
        "var groupSpacing: CGFloat { BlocksVisualTokens.Spacing.sm }",
        "var controlHeight: CGFloat { BlocksVisualTokens.Control.compactHeight }",
        "delayButton.isBordered = false",
        "delayButton.setAccessibilityRole(.popUpButton)",
        "static let parameterControlSpacing: CGFloat = 12",
        "enum ScreenshotConstraintToolbarMetrics",
        "static let contentSpacing: CGFloat = 4",
        "static let valueWidth: CGFloat = 96",
        "static var keyWidth: CGFloat",
        "ScreenshotParameterKeyLabel",
        "override var alignmentRectInsets",
        "static var unitWidth: CGFloat",
        "setContentCompressionResistancePriority(.defaultLow, for: .horizontal)",
        "makeLabeledParameterControl",
        "Self.parameterLabel",
        "private let freezeButton = ScreenshotFreezeValueButton()",
        "private let switchView = NSSwitch()",
        "static func parameterIslandWidth",
        "equalToConstant: ScreenshotConstraintToolbarMetrics.valueWidth",
        "stack.widthAnchor.constraint(equalToConstant: ScreenshotConstraintToolbarMetrics.unitWidth)",
        "override var intrinsicContentSize: NSSize",
        "override func hitTest(_ point: NSPoint) -> NSView?",
        "valueLabel.setAccessibilityElement(false)",
        "contentStack.setAccessibilityElement(false)",
        "override func viewDidChangeEffectiveAppearance()",
        "updateChromeAppearance()",
        "updateIslandAppearance",
        "NSPopoverDelegate",
        "dismissAspectRatioPopover",
        "popoverDidClose",
        "popover.delegate = self",
        "showDelayMenu",
        "showWatermarkMenu",
        "watermarkButton.setAccessibilityRole(.popUpButton)",
        "presentParameterMenu",
        "watermarkButton",
        "screenshot.selection.watermark",
    ],
    failures,
)

for obsolete in [
    "ScreenshotWatermarkEditorLibrary",
    "ScreenshotWatermarkDraftEditor",
    "ScreenshotWatermarkPositionGrid",
    "maximumEncodedBytes",
    "maximumPixelCount",
]:
    if obsolete in WATERMARK_VIEWS.read_text() or obsolete in WATERMARK_ASSET_STORE.read_text():
        failures.append({
            "code": "legacy_binary_or_multi_instance_watermark_ui_remaining",
            "path": str(WATERMARK_VIEWS.relative_to(ROOT)),
            "detail": obsolete,
        })

capture_group = settings_text.partition('title: L10n.string("settings.screenshot.capture")')[2].partition(
    'title: L10n.string("settings.screenshot.editor")'
)[0]
if "ScreenshotCaptureDefaultsRows(" not in capture_group:
    failures.append({
        "code": "capture_defaults_native_rows_missing",
        "path": str(SETTINGS_PANE.relative_to(ROOT)),
    })
for token in [
    "SettingsFormRow(title: L10n.string(\"screenshot.selection.constraint\"))",
    "SettingsFormRow(title: L10n.string(\"screenshot.selection.delay\"))",
    "SettingsFormRow(title: L10n.string(\"screenshot.selection.freeze\"))",
    "SettingsFormRow(title: L10n.string(\"screenshot.selection.watermark\"))",
    "SettingsBooleanSwitch(",
]:
    if token not in settings_text:
        failures.append({
            "code": "capture_defaults_native_row_contract_missing",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })
for obsolete in [
    "trailingWidth: 500",
    "ScreenshotCaptureDefaultsToolbar",
    "ScreenshotCaptureToolbarPreview",
    "presentation: .settingsCompact",
]:
    if obsolete in settings_text:
        failures.append({
            "code": "capture_defaults_fixed_toolbar_preview_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": obsolete,
        })
for token in [
    'systemImage: "pin.fill"',
    'L10n.string("screenshot.result.pin")',
]:
    if token not in settings_text:
        failures.append({
            "code": "screenshot_settings_runtime_preview_contract_missing",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })
if 'systemImage: "doc.on.doc"' in settings_text:
    failures.append({
        "code": "screenshot_settings_preview_still_exposes_copy",
        "path": str(SETTINGS_PANE.relative_to(ROOT)),
    })

tool_configuration = settings_text.partition("private struct ScreenshotUnifiedToolConfigurationSimulator")[2]
for token in [
    "ScreenshotToolZonesBoardBridge(",
    "ScreenshotToolZonesSnapshot(",
    "onMoveTool: onMoveTool",
    ".frame(height: ScreenshotToolZonesBoardMetrics.requiredHeight)",
]:
    if token not in tool_configuration:
        failures.append({
            "code": "screenshot_tool_configuration_horizontal_strip_contract_missing",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })
for obsolete in [
    "LazyVGrid(",
    "ScreenshotToolInsertionDropTarget",
    "ScreenshotToolStripTailDropTarget",
    "ScreenshotToolLibrary",
    ".onDrag",
    "ScreenshotToolDragSession",
    "ScreenshotToolDropDelegate",
    "ScreenshotToolStripDropDelegate",
    "DropDelegate",
    ".onDrop(",
]:
    if obsolete in tool_configuration:
        failures.append({
            "code": "screenshot_tool_configuration_wrapping_layout_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": obsolete,
        })

if not TOOL_STRIP_BRIDGE.exists():
    failures.append({
        "code": "screenshot_native_tool_strip_bridge_missing",
        "path": str(TOOL_STRIP_BRIDGE.relative_to(ROOT)),
    })

for obsolete in [
    "var constraintWidth:",
    "var delayWidth:",
    "symbolView.isHidden = !ScreenshotConstraintToolbarMetrics.showsSymbol(",
]:
    if obsolete in selection_toolbar_text:
        failures.append({
            "code": "screenshot_parameter_fixed_or_divergent_control_remaining",
            "path": str(SELECTION_TOOLBAR.relative_to(ROOT)),
            "detail": obsolete,
        })
for token in [
    "ScreenshotConstraintToolbarMetrics.parameterIslandWidth",
    "ScreenshotConstraintToolbarMetrics.unitWidth",
    "ScreenshotConstraintToolbarMetrics.valueWidth",
    "ScreenshotConstraintToolbarMetrics.parameterControlSpacing",
]:
    if token not in selection_toolbar_text:
        failures.append({
            "code": "screenshot_parameter_stable_toolbar_sizing_missing",
            "path": str(SELECTION_TOOLBAR.relative_to(ROOT)),
            "detail": token,
        })
for obsolete in [
    "+ valueLabel.intrinsicContentSize.width",
    "return CGSize(width: 180, height: 32)",
    "ScreenshotParameterPopUpButton",
    "private let delayPopUp",
    "private let watermarkPopUp",
    "private let freezeSwitch = NSSwitch()",
    "static let constraintValueWidth",
    "static let delayControlWidth",
    "static let freezeSwitchWidth",
    "static let watermarkControlWidth",
]:
    if obsolete in selection_toolbar_text:
        failures.append({
            "code": "screenshot_parameter_title_driven_toolbar_sizing_remaining",
            "path": str(SELECTION_TOOLBAR.relative_to(ROOT)),
            "detail": obsolete,
        })
for token in [
    ".fixedSize(horizontal: true, vertical: true)",
    "func sizeThatFits(",
    "nsView.intrinsicContentSize",
]:
    if token in settings_text:
        failures.append({
            "code": "screenshot_settings_fixed_parameter_preview_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })

tool_strip_text = TOOL_STRIP_BRIDGE.read_text() if TOOL_STRIP_BRIDGE.exists() else ""
if "NSColor.secondaryLabelColor" not in tool_strip_text or ".foregroundStyle(.tertiary)" in tool_configuration:
    failures.append({
        "code": "screenshot_tool_empty_state_contrast_regressed",
        "path": str(SETTINGS_PANE.relative_to(ROOT)),
    })

preferences_text = PREFERENCES.read_text() if PREFERENCES.exists() else ""
preferences_store_text = PREFERENCES_STORE.read_text() if PREFERENCES_STORE.exists() else ""
for token in ["quickToolLimit", ".prefix(quickToolLimit)"]:
    if token in preferences_text or token in preferences_store_text:
        failures.append({
            "code": "screenshot_quick_tool_limit_remaining",
            "path": str(PREFERENCES.relative_to(ROOT)),
            "detail": token,
        })
if "func setTool(" in preferences_store_text:
    failures.append({
        "code": "screenshot_non_atomic_zone_move_remaining",
        "path": str(PREFERENCES_STORE.relative_to(ROOT)),
    })

editor_preview = settings_text.partition("private struct ScreenshotEditorLayoutPreview")[2].partition(
    "private struct ScreenshotToolPreviewStrip"
)[0]
for token in [
    "ScreenshotEditorToolbarLayout.resolve(",
    "edgeMargin: 0",
    "presentation.visibleQuickTools",
        "presentation.overflowTools",
        "ScreenshotDesignTokens.toolbarMainHeight",
        "ScreenshotToolbarItemID.select.systemImage",
]:
    if token not in editor_preview:
        failures.append({
            "code": "settings_editor_preview_runtime_layout_contract_missing",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })
for obsolete in [
    ".frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56",
    ".padding(8)",
    ".onTapGesture(perform: onConfigure)",
]:
    if obsolete in editor_preview:
        failures.append({
            "code": "settings_editor_preview_parallel_layout_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": obsolete,
        })

for token in ["includesWindowShadow", "shadowButton", "case shadow"]:
    if token in selection_toolbar_text or token in settings_text:
        failures.append({
            "code": "screenshot_shadow_compatibility_ui_remaining",
            "path": str(SELECTION_TOOLBAR.relative_to(ROOT)),
            "detail": token,
        })

for token in ["ScreenshotCapturePreviewState", "settings.screenshot.capturePreview.ready", "await appModel.startSmartScreenshot()"]:
    if token in settings_text:
        failures.append({
            "code": "capture_toolbar_preview_fake_action_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })

for legacy_layout in [
    "private struct ScreenshotSettingsSection",
    "private struct ScreenshotSettingsRow",
    "private struct ScreenshotSettingsPreviewBlock",
]:
    if legacy_layout in settings_text:
        failures.append({
            "code": "screenshot_settings_parallel_layout_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": legacy_layout,
        })

if "ScreenshotEditorToolbarState" in settings_text:
    failures.append({
        "code": "main_settings_toolbar_state_picker_remaining",
        "path": str(SETTINGS_PANE.relative_to(ROOT)),
    })

if "ScreenshotEditorStatusBar" in settings_text:
    failures.append({
        "code": "settings_status_bar_preview_remaining",
        "path": str(SETTINGS_PANE.relative_to(ROOT)),
    })
for legacy_notification in [
    "resetFeedback",
    "resetFeedbackTask",
]:
    if legacy_notification in settings_text:
        failures.append({
            "code": "screenshot_settings_private_notification_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": legacy_notification,
        })
if "ScreenshotToolbarDragHandle" in editor_view_text:
    failures.append({
        "code": "editor_toolbar_drag_handle_restored",
        "path": str(EDITOR_VIEW.relative_to(ROOT)),
    })
for legacy_visible_action in [
    'actionSystemImage: "plus"',
    'actionSystemImage: "eye.slash"',
]:
    if legacy_visible_action in settings_text:
        failures.append({
            "code": "visible_tool_add_hide_action_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": legacy_visible_action,
        })
require(
    SCREENSHOT_LOCALIZABLE,
    [
        "error.editingContextUnavailable",
        "screenshot.editor.quickContextUnavailable",
        "status.editingContextUnavailable.title",
        "status.editingContextUnavailable.detail",
        "settings.screenshot.tools.quick",
        "settings.screenshot.tools.expanded",
        "settings.screenshot.tools.movable",
        "settings.screenshot.tools.movableInZone",
        "settings.screenshot.tools.configureNamed",
        "settings.screenshot.tools.library.empty",
        "screenshot.editor.moreTools",
        "screenshot.editor.moreTools.count",
        "screenshot.aspect.title",
        "screenshot.aspect.presets",
        "screenshot.aspect.customTitle",
        "screenshot.aspect.deleteSavedNamed",
        "screenshot.aspect.currentNamed",
        "screenshot.aspect.returnToPresets",
        "screenshot.aspect.scrollBackward",
        "screenshot.aspect.scrollForward",
        "settings.screenshot.confirmsDiscardBeforeClosing",
        "screenshot.editor.unsaved.suppression",
        "screenshot.common.confirm",
    ],
    failures,
)

if 'L10n.string("common.confirm")' in EDITOR_CONTROLS.read_text():
    failures.append({
        "code": "screenshot_editor_internal_localization_key_remaining",
        "path": str(EDITOR_CONTROLS.relative_to(ROOT)),
        "detail": "common.confirm",
    })

if 'L10n.string("settings.screenshot.workbench")' in SETTINGS_PANE.read_text():
    failures.append({
        "code": "duplicate_screenshot_workbench_heading",
        "path": str(SETTINGS_PANE.relative_to(ROOT)),
    })

for token in [
    'L10n.string("settings.screenshot.captureOptions.detail")',
    '.frame(width: 640, height: 680)',
    '.frame(height: 230)',
]:
    if token in settings_text:
        failures.append({
            "code": "screenshot_settings_fixed_empty_layout_remaining",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": token,
        })

settings_components_text = SETTINGS_COMPONENTS.read_text() if SETTINGS_COMPONENTS.exists() else ""
if "struct SettingsValueColumn" not in settings_components_text:
    failures.append({
        "code": "screenshot_output_trailing_alignment_missing",
        "path": str(SETTINGS_COMPONENTS.relative_to(ROOT)),
    })
for key in [
    "settings.screenshot.format",
    "settings.screenshot.automaticallyRecognizesHistory",
]:
    row = settings_text.partition(f'L10n.string("{key}")')[2].partition("SettingsRowDivider()")[0]
    expected_control = "SettingsBooleanSwitch" if key == "settings.screenshot.automaticallyRecognizesHistory" else "Picker("
    if expected_control not in row:
        failures.append({
            "code": "screenshot_output_row_not_using_shared_trailing_control",
            "path": str(SETTINGS_PANE.relative_to(ROOT)),
            "detail": key,
        })

for path in [PREFERENCES, PREFERENCES_STORE, SETTINGS_PANE]:
    if not path.exists():
        continue
    source = path.read_text()
    remaining = [
        token for token in [
            "ScreenshotEditCommand",
            "enum ScreenshotEditorLayout",
            "case professional",
            "case .professional",
            "settings.screenshot.tools.full",
            "Button(action: onToggle)",
        ]
        if token in source
    ]
    if remaining:
        failures.append({
            "code": "legacy_editor_settings_contract_remaining",
            "path": str(path.relative_to(ROOT)),
            "detail": remaining,
        })

for path in [PREFERENCES, PREFERENCES_STORE, SETTINGS_PANE]:
    if not path.exists():
        continue
    source = path.read_text()
    remaining = [
        token for token in [
            "fullToolOrder",
            "quickToolOrder",
            "defaultEditorMode",
            "fullHiddenTools",
            "quickHiddenTools",
            "ScreenshotToolConfigurationScope",
            "setFullTool",
            "setQuickTool",
            "moveFullTool",
            "moveQuickTool",
            "screenshot.preferences.v4",
            "screenshot.preferences.v6",
            "legacyV12StorageKey",
            "legacyV11StorageKey",
            "legacyV10StorageKey",
            "legacyV9StorageKey",
            "LegacyScreenshotPreferencesV12",
            "LegacyScreenshotPreferencesV10",
            "LegacyScreenshotPreferencesV9",
        ]
        if token in source
    ]
    if remaining:
        failures.append({
            "code": "v4_tool_configuration_contract_remaining",
            "path": str(path.relative_to(ROOT)),
            "detail": remaining,
        })
require(
    APP / "Features/Screenshot/Output/ScreenshotPasteboardWriter.swift",
    ["struct ScreenshotPasteboardWriter", "ClipboardPasteboardChangeSuppressor", "NSPasteboard.PasteboardType.png"],
    failures,
)
require(
    APP / "Features/Screenshot/Output/ScreenshotEditorOutputCoordinator.swift",
    ["final class ScreenshotEditorOutputCoordinator", "func copy", "func saveAs", "ScreenshotImageEncoder"],
    failures,
)
require(
    SCREENSHOT_STORE,
    [
        "case saved(NSImage)",
        "editorPresenter.present",
        "case let .saved(image)",
        "writesPasteboard: true",
        "shouldCommitFinalOutput = false",
    ],
    failures,
)
if "pasteboardWriter.write(capture.image)" in SCREENSHOT_STORE.read_text():
    failures.append({
        "code": "initial_capture_written_before_editor_terminal_outcome",
        "path": str(SCREENSHOT_STORE.relative_to(ROOT)),
    })

controls_text = EDITOR_CONTROLS.read_text() if EDITOR_CONTROLS.exists() else ""
property_strip_custom_controls = controls_text.partition("struct ScreenshotAspectRatioPropertyStrip")[2].partition(
    "private var orientationPicker"
)[0]
if property_strip_custom_controls.count(
    ".frame(height: ScreenshotAspectRatioPanelMetrics.customControlHeight)"
) < 2 or ".tint(.accentColor)" not in property_strip_custom_controls:
    failures.append({
        "code": "screenshot_aspect_inline_custom_action_alignment_regressed",
        "path": str(EDITOR_CONTROLS.relative_to(ROOT)),
    })
for obsolete in ["ScreenshotAspectMiniPreview", "ScreenshotAspectChip", "ScreenshotSavedAspectChip"]:
    if obsolete in controls_text:
        failures.append({
            "code": "obsolete_aspect_dynamic_preview_or_chip_remaining",
            "path": str(EDITOR_CONTROLS.relative_to(ROOT)),
            "detail": obsolete,
        })

swift_text = "\n".join(path.read_text() for path in APP.rglob("*.swift"))
if "screenshotRegion" in swift_text:
    failures.append({"code": "legacy_shortcut_remaining", "detail": "screenshotRegion"})
if "case screenshotSmart" not in swift_text:
    failures.append({"code": "smart_shortcut_missing", "detail": "case screenshotSmart"})
if "screenshotRegion" in PROJECT.read_text():
    failures.append({"code": "legacy_project_contract_remaining", "detail": "screenshotRegion"})

project_text = PROJECT.read_text()
for source in [
    "ScreenshotPreferences.swift in Sources",
    "ScreenshotPreferencesStore.swift in Sources",
    "ScreenshotSettingsPane.swift in Sources",
    "ScreenshotToolStripBridge.swift in Sources",
    "ScreenshotPasteboardWriter.swift in Sources",
    "ScreenshotEditorOutputCoordinator.swift in Sources",
    "ScreenshotEditorControls.swift in Sources",
]:
    if source not in project_text:
        failures.append({"code": "target_membership_missing", "detail": source})

print(json.dumps({"gate": "P14-D", "status": "pass" if not failures else "fail", "failures": failures}, ensure_ascii=False, indent=2))
raise SystemExit(0 if not failures else 1)
