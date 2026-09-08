import AppKit
import BlocksCore
import BlocksScreenshotCore
import SwiftUI

struct ScreenshotToolbarIconButton: View {
    let systemImage: String
    let label: String
    var isEnabled = true
    var isSelected = false
    var isLoading = false
    var emphasis: BlocksCompactIconButtonEmphasis = .standard
    var focusRequestID: UUID? = nil
    let action: () -> Void
    @Environment(\.blocksImmediateTooltipHost) private var tooltipHost

    var body: some View {
        BlocksCompactIconButton(
            systemImage: systemImage,
            label: label,
            isEnabled: isEnabled,
            isSelected: isSelected,
            isLoading: isLoading,
            emphasis: emphasis,
            density: .standard,
            focusRequestID: focusRequestID,
            showsHelp: false
        ) {
            tooltipHost?.hide()
            action()
        }
        .blocksImmediateTooltip(label, isEnabled: isEnabled)
    }

}

private enum ScreenshotEditorStatusChipID: Hashable {
    case size
    case cornerRadius
    case element(UUID)
}

struct ScreenshotEditorStatusBar: View {
    let elements: [ScreenshotElement]
    let selectedElementID: UUID?
    let isRoundedOutput: Bool
    let width: CGFloat
    @Binding var isSizePanelPresented: Bool
    let sizePanel: AnyView
    let onToggleRounded: () -> Void
    let onSelectElement: (UUID) -> Void
    let onDeleteElement: (UUID, UUID?) -> Void
    var pluginContent: AnyView? = nil

    @FocusState private var focusedChip: ScreenshotEditorStatusChipID?

    var body: some View {
        ScreenshotChromeContentLayout(maximumWidth: width, height: ScreenshotEditorChromeMetrics.statusBarHeight) {
            ViewThatFits(in: .horizontal) {
                chips.fixedSize(horizontal: true, vertical: false)
                ScreenshotChromeOverflowRow(revealID: selectedElementID.map { AnyHashable(ScreenshotEditorStatusChipID.element($0)) }) {
                    chips
                }
            }
        }
        .blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)
        .onChange(of: isSizePanelPresented) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            focusedChip = .size
        }
        .onDeleteCommand(perform: deleteFocusedElement)
        .accessibilityElement(children: .contain)
    }

    private var chips: some View {
        HStack(spacing: ScreenshotEditorChromeMetrics.statusChipSpacing) {
            statusButton(id: .size, systemImage: "arrow.up.left.and.arrow.down.right",
                         title: L10n.string("screenshot.editor.status.size"), isSelected: isSizePanelPresented,
                         action: { isSizePanelPresented = true })
                .popover(isPresented: $isSizePanelPresented, arrowEdge: .top) { sizePanel }
            statusButton(id: .cornerRadius, systemImage: "rectangle.roundedtop",
                         title: L10n.string("screenshot.editor.cornerRadius"), isSelected: isRoundedOutput,
                         accessibilityValue: L10n.string(isRoundedOutput ? "screenshot.editor.status.enabled" : "screenshot.editor.status.disabled"),
                         action: onToggleRounded)
            ForEach(elements) { element in
                statusButton(id: .element(element.id), systemImage: element.kind.tool.toolbarItemID.systemImage,
                             title: ScreenshotEditorStatusBarModel.title(for: element),
                             isSelected: selectedElementID == element.id,
                             action: { onSelectElement(element.id) })
            }
            pluginContent
        }
        .padding(.horizontal, ScreenshotEditorChromeMetrics.statusBarPadding)
        .fixedSize(horizontal: true, vertical: true)
    }

    private func statusButton(
        id: ScreenshotEditorStatusChipID,
        systemImage: String,
        title: String,
        isSelected: Bool,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        BlocksSelectableChip(
            title: title,
            systemImage: systemImage,
            isSelected: isSelected,
            isFocused: focusedChip == id,
            showsHelp: false
        ) {
            focusedChip = id
            action()
        }
        .focused($focusedChip, equals: id)
        .fixedSize(horizontal: true, vertical: true)
        .id(id)
        .blocksImmediateTooltip(title)
        .accessibilityValue(accessibilityValue ?? "")
    }

    private func deleteFocusedElement() {
        guard case let .element(id) = focusedChip else { return }
        let nextFocus = ScreenshotEditorStatusBarModel.nextElementID(
            afterDeleting: id,
            from: elements
        )
        onDeleteElement(id, nextFocus)
        DispatchQueue.main.async {
            focusedChip = nextFocus.map(ScreenshotEditorStatusChipID.element) ?? .size
        }
    }

}

/// Overflow controls occupy their own columns, never cover or fade a chip.
/// The natural-content branch is selected synchronously by ViewThatFits.
private struct ScreenshotChromeOverflowRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var revealID: AnyHashable? = nil
    @ViewBuilder let content: () -> Content
    private let leadingID = "screenshot-chrome-leading"
    private let trailingID = "screenshot-chrome-trailing"

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                scrollButton(forward: false) { proxy.scrollTo(leadingID, anchor: .leading) }
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 0, height: 1).id(leadingID)
                        content().fixedSize(horizontal: true, vertical: false)
                        Color.clear.frame(width: 0, height: 1).id(trailingID)
                    }
                }
                .scrollIndicators(.hidden)
                scrollButton(forward: true) { proxy.scrollTo(trailingID, anchor: .trailing) }
            }
            .onChange(of: revealID) { _, id in
                guard let id else { return }
                withAnimation(BlocksMotionRole.hoverFocus.animation(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func scrollButton(forward: Bool, action: @escaping () -> Void) -> some View {
        BlocksCompactIconButton(
            systemImage: forward ? "chevron.forward" : "chevron.backward",
            label: L10n.string(forward ? "screenshot.editor.properties.scrollForward" : "screenshot.editor.properties.scrollBackward"),
            density: .micro, action: action
        )
        .fixedSize()
    }
}

struct ScreenshotEditorHostView: View {
    let store: ScreenshotEditorStore
    let pluginManager: BlocksNativePluginManager?
    let pluginRuntime: BlocksPluginRuntimeCoordinator?
    var canvasPresentation: ScreenshotEditorCanvasPresentation = .cropSurround
    var chromeSafeAreaInsets = EdgeInsets()
    let onFirstFrameRendered: () -> Void

    var body: some View {
        ScreenshotUnifiedEditorView(
            store: store,
            pluginManager: pluginManager,
            pluginRuntime: pluginRuntime,
            canvasPresentation: canvasPresentation,
            chromeSafeAreaInsets: chromeSafeAreaInsets,
            onFirstFrameRendered: onFirstFrameRendered
        )
            .blocksImmediateTooltipHost()
    }
}

enum ScreenshotEditorToolbarLayout {
    static func resolve(
        availableWidth: CGFloat,
        quickTools: [ScreenshotToolbarItemID],
        extendedTools: [ScreenshotToolbarItemID],
        selectedItem: ScreenshotToolbarItemID,
        allowsDirectImageCopy: Bool,
        edgeMargin: CGFloat = BlocksVisualTokens.Spacing.xl
    ) -> ScreenshotToolbarLayoutResolution {
        let maximumWidth = ScreenshotEditorChromeMetrics.maximumWidth(
            in: availableWidth,
            edgeMargin: edgeMargin
        )
        let presentation = ScreenshotToolbarPresentation.make(
            quickTools: quickTools,
            extendedTools: extendedTools,
            selectedItem: selectedItem
        )
        let intrinsicWidth = requiredWidth(
            presentation: presentation,
            allowsDirectImageCopy: allowsDirectImageCopy
        )
        return ScreenshotToolbarLayoutResolution(
            width: min(intrinsicWidth, maximumWidth),
            intrinsicWidth: intrinsicWidth,
            presentation: presentation
        )
    }

    static func requiredWidth(
        presentation: ScreenshotToolbarPresentation,
        allowsDirectImageCopy: Bool
    ) -> CGFloat {
        let commandGroup = groupWidth(itemCount: 2)
        let toolCount = presentation.visibleQuickTools.count
            + (presentation.overflowTools.isEmpty ? 0 : 1)
        let toolGroup = groupWidth(itemCount: toolCount)
        let historyGroup = groupWidth(itemCount: 2)
        let outputGroup = groupWidth(itemCount: 4)
        let groupSpacingCount: CGFloat = toolCount > 0 ? 3 : 2
        return BlocksVisualTokens.Spacing.sm * 2
            + commandGroup
            + toolGroup
            + historyGroup
            + outputGroup
            + BlocksVisualTokens.Spacing.sm * groupSpacingCount
    }

    private static func groupWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * BlocksVisualTokens.Control.minimumHitTarget
            + CGFloat(itemCount - 1) * 2
            + 4
    }

}

struct ScreenshotUnifiedEditorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScreenshotEditorStore
    let pluginManager: BlocksNativePluginManager?
    let pluginRuntime: BlocksPluginRuntimeCoordinator?
    let canvasPresentation: ScreenshotEditorCanvasPresentation
    let chromeSafeAreaInsets: EdgeInsets
    let onFirstFrameRendered: () -> Void
    @StateObject private var aspectControlModel: ScreenshotAspectControlModel
    @State private var textCommitRequestID = 0
    @State private var pendingCanvasAction: ScreenshotEditorAction?
    @State private var isSizePanelPresented = false

    init(
        store: ScreenshotEditorStore,
        pluginManager: BlocksNativePluginManager? = nil,
        pluginRuntime: BlocksPluginRuntimeCoordinator? = nil,
        canvasPresentation: ScreenshotEditorCanvasPresentation = .cropSurround,
        chromeSafeAreaInsets: EdgeInsets = EdgeInsets(),
        onFirstFrameRendered: @escaping () -> Void = {}
    ) {
        self.store = store
        self.pluginManager = pluginManager
        self.pluginRuntime = pluginRuntime
        self.canvasPresentation = canvasPresentation
        self.chromeSafeAreaInsets = chromeSafeAreaInsets
        self.onFirstFrameRendered = onFirstFrameRendered
        _aspectControlModel = StateObject(wrappedValue: ScreenshotAspectControlModel(
            selection: ScreenshotAspectSelection(
                orientation: store.aspectOrientation,
                constraint: store.cropConstraint
            ),
            customConstraints: store.preferencesStore.preferences.customConstraints
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = toolbarLayout(availableWidth: proxy.size.width)
            let statusElements = ScreenshotEditorStatusBarModel.visibleElements(
                in: store.document.presentedSnapshot
            )
            let horizontalSafeInset = canvasPresentation == .displayOverlay
                ? chromeSafeAreaInsets.leading + chromeSafeAreaInsets.trailing : 0
            let maximumChromeWidth = ScreenshotEditorChromeMetrics.maximumWidth(in: proxy.size.width - horizontalSafeInset)
            let frames = ScreenshotEditorCropChromeLayout.resolve(
                availableSize: proxy.size,
                sourceRect: store.sourceBounds,
                cropRect: store.cropRect,
                zoomScale: store.viewport.zoomScale,
                panOffset: store.viewport.panOffset,
                statusWidth: maximumChromeWidth,
                toolbarWidth: maximumChromeWidth,
                presentation: canvasPresentation,
                safeAreaInsets: chromeSafeAreaInsets
            )
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                ScreenshotEditorOverlayLayout(
                    availableSize: proxy.size, sourceRect: store.sourceBounds, cropRect: store.cropRect,
                    zoomScale: store.viewport.zoomScale, panOffset: store.viewport.panOffset,
                    presentation: canvasPresentation, safeAreaInsets: chromeSafeAreaInsets
                ) {
                canvas
                ScreenshotEditorStatusBar(
                    elements: statusElements,
                    selectedElementID: store.selectedElementID,
                    isRoundedOutput: store.isRoundedOutput,
                    width: maximumChromeWidth,
                    isSizePanelPresented: $isSizePanelPresented,
                    sizePanel: AnyView(ScreenshotAspectRatioCapturePopover(
                        selection: ScreenshotAspectSelection(
                            orientation: store.aspectOrientation,
                            constraint: store.cropConstraint
                        ),
                        customConstraints: store.preferencesStore.preferences.customConstraints,
                        onSelect: store.applyAspectSelection,
                        onSave: store.preferencesStore.saveCustomConstraint,
                        onDelete: store.preferencesStore.removeCustomConstraint
                    )),
                    onToggleRounded: store.toggleRoundedOutput,
                    onSelectElement: { requestCanvasAction(.selectElement($0)) },
                    onDeleteElement: { id, nextID in
                        store.deleteElement(id, selecting: nextID)
                    },
                    pluginContent: AnyView(screenshotPluginSlot(
                        .screenshotStatusItem,
                        context: screenshotPluginContext
                    ))
                )
                bottomToolbarContainer(layout: layout, maximumWidth: maximumChromeWidth)
                }

                if let panelFrame = manualOCRPanelFrame(in: proxy.size, toolbarFrame: frames.toolbar) {
                    manualOCRResultPanel
                        .position(x: panelFrame.midX, y: panelFrame.midY)
                        .transition(.opacity)
                }

                BlocksNotificationHost(state: store.notificationState)
                    .padding(.top, screenshotNotificationTop(statusFrame: frames.status))
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .top
                    )
                    .zIndex(60)

                if store.manualOCRState.isLocked {
                    ScreenshotManualOCRProgressOverlay(onCancel: store.cancelManualOCR)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .blocksAnimation(.hoverFocus, value: store.manualOCRState.isLocked)
        .blocksAnimation(.reveal, value: manualOCRPanelIsVisible)
        .onChange(of: store.cropConstraint) { _, constraint in
            aspectControlModel.synchronize(
                selection: ScreenshotAspectSelection(
                    orientation: store.aspectOrientation,
                    constraint: constraint
                ),
                customConstraints: store.preferencesStore.preferences.customConstraints
            )
        }
        .onChange(of: store.preferencesStore.preferences.customConstraints) { _, constraints in
            aspectControlModel.synchronize(
                selection: ScreenshotAspectSelection(
                    orientation: aspectControlModel.orientation,
                    constraint: store.cropConstraint
                ),
                customConstraints: constraints
            )
        }
        .disabled(
            store.outputState.isCloseConfirmationPresented
                || store.outputState.isPending
        )
    }

    private func screenshotNotificationTop(statusFrame: CGRect) -> CGFloat {
        BlocksNotificationLayout.editorTopInset(avoiding: statusFrame)
    }

    private var canvas: some View {
        ScreenshotEditorCanvas(
            image: store.interactionBaseImage ?? store.canvasImage,
            visibleSourceRect: store.sourceBounds,
            cropRect: store.cropRect,
            selectedTool: store.selectedTool,
            textStyle: store.activeStyle,
            zoomScale: store.viewport.zoomScale,
            panOffset: store.viewport.panOffset,
            allowsViewportNavigation: store.prefersLongImageViewport,
            prefersInitialFitWidth: store.prefersLongImageViewport,
            selectedElement: store.selectedElement,
            selectedStepComponent: store.selectedStepComponent,
            selectedCalloutComponent: store.selectedCalloutComponent,
            sceneElements: store.document.presentedSnapshot.elements,
            allowsObjectEditing: store.activeToolbarItemID != .ocr,
            isInteractionEnabled: store.canvasInputEnabled,
            draftElement: store.draftElement,
            draftCropRect: store.draftCropRect,
            manualOCRRegion: store.manualOCRRegion,
            showsCropOverlay: true,
            isRoundedOutput: store.isRoundedOutput,
            onViewportChanged: store.setViewport,
            onBegin: { point, sourceUnitsPerViewPoint, modifiers in
                store.beginGesture(
                    at: point,
                    sourceUnitsPerViewPoint: sourceUnitsPerViewPoint,
                    modifiers: modifiers,
                    allowsPersistentCropHandles: true
                )
            },
            onUpdate: store.updateGesture,
            onEnd: store.endGesture,
            onCancel: store.handleEscape,
            onDelete: store.deleteSelection,
            onSelectTool: { store.selectTool(.select) },
            onUndo: store.undo,
            onRedo: store.redo,
            onNudge: store.nudgeSelection,
            onSelectElement: store.selectElement,
            onSelectStepComponent: { id, component in
                store.selectStepComponent(id, component: component)
            },
            onCycleStepComponent: store.cycleSelectedStepComponent,
            onSelectCalloutComponent: { id, component in
                store.selectCalloutComponent(id, component: component)
            },
            onCycleCalloutComponent: store.cycleSelectedCalloutComponent,
            onRequestTextEdit: store.requestInlineTextEditing,
            onTextEditingEnded: store.endInlineTextEditing,
            onAdjustAccessibilityTarget: store.adjustAccessibilityTarget,
            onSelectCrop: { store.selectToolbarItem(.aspectRatio) },
            onResetCurvature: store.resetCurvature,
            curvatureAnchorPulse: store.curvatureAnchorPulse,
            reduceMotion: reduceMotion,
            onTextCommit: store.applyText,
            textCommitRequestID: textCommitRequestID,
            onTextCommitRequestHandled: performPendingCanvasAction,
            inlineTextEditRequestID: store.inlineTextEditRequestID,
            inlineTextEditElementID: store.inlineTextEditElementID,
            onFirstFrameRendered: onFirstFrameRendered
        )
    }

    private func toolbarLayout(availableWidth: CGFloat) -> ScreenshotToolbarLayoutResolution {
        let chromeState = store.chromeState
        return ScreenshotEditorToolbarLayout.resolve(
            availableWidth: availableWidth,
            quickTools: chromeState.quickToolbarItems,
            extendedTools: chromeState.extendedToolbarItems,
            selectedItem: chromeState.activeToolbarItemID,
            allowsDirectImageCopy: store.allowsDirectImageCopy
        )
    }

    private func bottomToolbarContainer(layout: ScreenshotToolbarLayoutResolution, maximumWidth: CGFloat) -> some View {
        ScreenshotEditorToolbarPanelLayout(maximumWidth: maximumWidth) {
            ScreenshotUnifiedEditorToolbar(
                state: store.toolbarState,
                presentation: layout.presentation,
                pluginToolContent: AnyView(screenshotPluginSlot(
                    .screenshotTool,
                    context: screenshotPluginContext,
                    protectedContext: screenshotProtectedContext,
                    requiredDataPermission: .screenshotDocument
                )),
                pluginOutputContent: AnyView(screenshotPluginSlot(
                    .screenshotOutputAction,
                    context: screenshotPluginContext,
                    protectedContext: screenshotProtectedContext,
                    requiredDataPermission: .screenshotDocument
                )),
                moreToolsPresentation: $store.moreToolsPresentation,
                moreToolsTriggerFocusRequestID: store.moreToolsTriggerFocusRequestID,
                onMoreToolsExit: store.requestMoreToolsTriggerFocus,
                onCanvasAction: requestCanvasAction
            )
            .blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)
            ScreenshotExpandedPropertiesRow(
                store: store,
                aspectControlModel: aspectControlModel,
                maximumWidth: maximumWidth,
                pluginContent: AnyView(screenshotPluginSlot(
                    .screenshotInspectorSection,
                    context: screenshotPluginContext,
                    protectedContext: screenshotProtectedContext,
                    requiredDataPermission: .screenshotDocument
                ))
            )
            .blocksSurface(.panel, cornerRadius: BlocksVisualTokens.CornerRadius.section)
        }
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
    }

    private var screenshotPluginContext: [String: JSONValue] {
        [
            "selected_tool": .string(store.activeToolbarItemID.rawValue),
            "element_count": .int(store.document.presentedSnapshot.elements.count),
            "rounded_output": .bool(store.isRoundedOutput)
        ]
    }

    private var screenshotProtectedContext: [String: JSONValue] {
        [
            "crop_x": .int(store.cropRect.x),
            "crop_y": .int(store.cropRect.y),
            "crop_width": .int(store.cropRect.width),
            "crop_height": .int(store.cropRect.height)
        ]
    }

    @ViewBuilder
    private func screenshotPluginSlot(
        _ slot: BlocksPluginUISlot,
        context: [String: JSONValue],
        protectedContext: [String: JSONValue] = [:],
        requiredDataPermission: BlocksNativePluginDataPermission? = nil
    ) -> some View {
        if let pluginManager, let pluginRuntime {
            BlocksPluginUISlotHost(
                manager: pluginManager,
                runtime: pluginRuntime,
                slot: slot,
                context: context,
                protectedContext: protectedContext,
                requiredDataPermission: requiredDataPermission
            )
        }
    }

    private func manualOCRPanelFrame(in visibleSize: CGSize, toolbarFrame: CGRect) -> CGRect? {
        guard let panelSize = ScreenshotManualOCRPanelLayout.size(for: store.manualOCRState) else { return nil }
        return ScreenshotFloatingPanelLayout.frame(
            anchorFrame: toolbarFrame,
            panelSize: panelSize,
            visibleBounds: CGRect(origin: .zero, size: visibleSize)
        )
    }

    private var manualOCRPanelIsVisible: Bool {
        switch store.manualOCRState {
        case .result, .failed:
            true
        case .idle, .selecting, .recognizing:
            false
        }
    }

    private func requestCanvasAction(_ action: ScreenshotEditorAction) {
        guard pendingCanvasAction == nil else { return }
        pendingCanvasAction = action
        textCommitRequestID &+= 1
    }

    private func performPendingCanvasAction() {
        guard let action = pendingCanvasAction else { return }
        pendingCanvasAction = nil
        switch action {
        case .close: store.close()
        case let .selectToolbarItem(item):
            if item == .watermark { store.selectOrCreateWatermark() }
            else { store.selectToolbarItem(item) }
        case let .selectElement(id): store.selectElement(id)
        case .undo: store.undo()
        case .redo: store.redo()
        case .pin: store.pinCurrent()
        case .save: store.saveAs()
        case .retake: store.retake()
        case .complete: _ = store.complete()
        }
    }

    @ViewBuilder
    private var manualOCRResultPanel: some View {
        switch store.manualOCRState {
        case let .result(_, _, _, text):
            ScreenshotManualOCRResultPanel(
                text: Binding(
                    get: { text },
                    set: store.updateManualOCRText
                ),
                allowsCopy: store.allowsDirectImageCopy,
                onCopy: store.copyManualOCRText,
                onClose: store.closeManualOCRResult
            )
        case let .failed(_, _, _, reason):
            ScreenshotManualOCRFailurePanel(
                reason: reason,
                onRetry: store.retryManualOCR,
                onClose: store.closeManualOCRResult
            )
        case .idle, .selecting, .recognizing:
            EmptyView()
        }
    }
}

struct ScreenshotToolbarPresentation: Equatable {
    let visibleQuickTools: [ScreenshotToolbarItemID]
    let overflowTools: [ScreenshotToolbarItemID]
    let activeOverflowTool: ScreenshotToolbarItemID?

    static func make(
        quickTools: [ScreenshotToolbarItemID],
        extendedTools: [ScreenshotToolbarItemID],
        selectedItem: ScreenshotToolbarItemID
    ) -> ScreenshotToolbarPresentation {
        var seen = Set<ScreenshotToolbarItemID>()
        let normalizedQuick = quickTools.filter { seen.insert($0).inserted }
        let normalizedExtended = extendedTools.filter { seen.insert($0).inserted }
        return ScreenshotToolbarPresentation(
            visibleQuickTools: normalizedQuick,
            overflowTools: normalizedExtended,
            activeOverflowTool: normalizedExtended.contains(selectedItem) ? selectedItem : nil
        )
    }
}

struct ScreenshotToolbarLayoutResolution: Equatable {
    let width: CGFloat
    let intrinsicWidth: CGFloat
    let presentation: ScreenshotToolbarPresentation

    var requiresQuickToolScrolling: Bool { intrinsicWidth > width + 1 }
}

struct ScreenshotUnifiedEditorToolbar: View {
    let state: ScreenshotEditorToolbarState
    let presentation: ScreenshotToolbarPresentation
    let pluginToolContent: AnyView?
    let pluginOutputContent: AnyView?
    @Binding var moreToolsPresentation: ScreenshotMoreToolsPresentationState
    let moreToolsTriggerFocusRequestID: UUID?
    let onMoreToolsExit: () -> Void
    let onCanvasAction: (ScreenshotEditorAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedContent.fixedSize(horizontal: true, vertical: false)
            compactContent
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, BlocksVisualTokens.Spacing.sm)
        .frame(height: ScreenshotDesignTokens.toolbarMainHeight)
        .onChange(of: state.activeToolbarItemID) { _, _ in
            moreToolsPresentation.handle(.toolbarAction)
        }
        .onChange(of: presentation.overflowTools) { _, tools in
            moreToolsPresentation.handle(.toolsChanged(hasOverflow: !tools.isEmpty))
        }
        .onDisappear {
            moreToolsPresentation.handle(.disappear)
        }
    }

    private var expandedContent: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(
                    systemImage: "xmark",
                    label: L10n.string("common.close"),
                    emphasis: .destructive,
                    action: { dispatch(.close) }
                )
                ScreenshotEditorToolButton(item: .select, selectedItem: state.activeToolbarItemID) {
                    dispatch(.selectToolbarItem($0))
                }
                pluginToolContent
            }
            .fixedSize(horizontal: true, vertical: false)

            toolCluster

            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(
                    systemImage: "arrow.uturn.backward",
                    label: L10n.string("screenshot.editor.undo"),
                    isEnabled: state.canUndo,
                    action: { dispatch(.undo) }
                )
                ScreenshotToolbarIconButton(
                    systemImage: "arrow.uturn.forward",
                    label: L10n.string("screenshot.editor.redo"),
                    isEnabled: state.canRedo,
                    action: { dispatch(.redo) }
                )
            }
            .fixedSize(horizontal: true, vertical: false)

            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(
                    systemImage: "pin.fill",
                    label: L10n.string("screenshot.result.pin"),
                    isEnabled: !state.isOutputPending,
                    isLoading: state.currentOutputCommand == .pin,
                    action: { dispatch(.pin) }
                )
                ScreenshotToolbarIconButton(
                    systemImage: "square.and.arrow.down",
                    label: L10n.string("screenshot.result.saveAs"),
                    isEnabled: !state.isOutputPending,
                    isLoading: state.currentOutputCommand == .save,
                    action: { dispatch(.save) }
                )
                ScreenshotToolbarIconButton(
                    systemImage: "camera.rotate",
                    label: L10n.string("screenshot.result.retake"),
                    isEnabled: !state.isOutputPending,
                    action: { dispatch(.retake) }
                )
                ScreenshotToolbarIconButton(
                    systemImage: "checkmark",
                    label: L10n.string("screenshot.editor.done"),
                    isEnabled: !state.isOutputPending,
                    isLoading: state.currentOutputCommand == .complete,
                    emphasis: .accent,
                    action: { dispatch(.complete) }
                )
                pluginOutputContent
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var compactContent: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            BlocksCompactControlGroup {
                ScreenshotToolbarIconButton(systemImage: "xmark", label: L10n.string("common.close"),
                                            emphasis: .destructive, action: { dispatch(.close) })
                ScreenshotEditorToolButton(item: .select, selectedItem: state.activeToolbarItemID) {
                    dispatch(.selectToolbarItem($0))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            ScreenshotChromeOverflowRow(revealID: AnyHashable(state.activeToolbarItemID)) {
                HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                    pluginToolContent
                    toolCluster
                    pluginOutputContent
                }
            }
            .frame(minWidth: BlocksVisualTokens.Control.minimumHitTarget)
            BlocksCompactControlGroup {
                Menu {
                    Button(L10n.string("screenshot.editor.undo"), systemImage: "arrow.uturn.backward") { dispatch(.undo) }
                        .disabled(!state.canUndo)
                    Button(L10n.string("screenshot.editor.redo"), systemImage: "arrow.uturn.forward") { dispatch(.redo) }
                        .disabled(!state.canRedo)
                    Divider()
                    Button(L10n.string("screenshot.result.pin"), systemImage: "pin.fill") { dispatch(.pin) }
                        .disabled(state.isOutputPending)
                    Button(L10n.string("screenshot.result.saveAs"), systemImage: "square.and.arrow.down") { dispatch(.save) }
                        .disabled(state.isOutputPending)
                    Button(L10n.string("screenshot.result.retake"), systemImage: "camera.rotate") { dispatch(.retake) }
                        .disabled(state.isOutputPending)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: BlocksVisualTokens.Control.minimumHitTarget, height: BlocksVisualTokens.Control.minimumHitTarget)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(L10n.string("screenshot.editor.moreActions"))
                .blocksImmediateTooltip(L10n.string("screenshot.editor.moreActions"))
                ScreenshotToolbarIconButton(systemImage: "checkmark", label: L10n.string("screenshot.editor.done"),
                                            isEnabled: !state.isOutputPending, isLoading: state.currentOutputCommand == .complete,
                                            emphasis: .accent, action: { dispatch(.complete) })
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var toolCluster: some View {
        if !presentation.visibleQuickTools.isEmpty || !presentation.overflowTools.isEmpty {
            BlocksCompactControlGroup {
                ForEach(presentation.visibleQuickTools, id: \.id) { item in
                    ScreenshotEditorToolButton(item: item, selectedItem: state.activeToolbarItemID) {
                        dispatch(action(for: $0))
                    }
                    .id(item)
                }
                if !presentation.overflowTools.isEmpty {
                    ScreenshotMoreToolsTriggerButton(
                        systemImage: presentation.activeOverflowTool?.systemImage ?? "ellipsis",
                        label: L10n.format("screenshot.editor.moreTools.count", presentation.overflowTools.count),
                        isSelected: presentation.activeOverflowTool != nil,
                        focusRequestID: moreToolsTriggerFocusRequestID,
                        action: { source in
                            moreToolsPresentation.handle(
                                .trigger(hasOverflow: true, source: source)
                            )
                        }
                    )
                    .popover(
                        isPresented: Binding(
                            get: { moreToolsPresentation.isPresented },
                            set: { moreToolsPresentation.isPresented = $0 }
                        ),
                        arrowEdge: .bottom
                    ) {
                        ScreenshotMoreToolsPanel(
                            tools: presentation.overflowTools,
                            selectedItem: state.activeToolbarItemID,
                            shouldAutofocus: moreToolsPresentation.shouldAutofocus,
                            onExit: onMoreToolsExit,
                            onSelect: { item in
                                dispatch(action(for: item))
                            }
                        )
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func action(for item: ScreenshotToolbarItemID) -> ScreenshotEditorAction {
        .selectToolbarItem(item)
    }

    private func dispatch(_ action: ScreenshotEditorAction) {
        moreToolsPresentation.handle(.toolbarAction)
        onCanvasAction(action)
    }
}

enum ScreenshotMoreToolsPresentationEvent: Equatable {
    case trigger(hasOverflow: Bool, source: ScreenshotMoreToolsActivationSource)
    case toolbarAction
    case toolsChanged(hasOverflow: Bool)
    case escape
    case disappear
}

enum ScreenshotMoreToolsActivationSource: Equatable {
    case mouse
    case keyboardOrAccessibility
}

struct ScreenshotMoreToolsPresentationState: Equatable {
    var isPresented = false
    var shouldAutofocus = false

    mutating func handle(_ event: ScreenshotMoreToolsPresentationEvent) {
        switch event {
        case let .trigger(hasOverflow, source):
            isPresented = hasOverflow && !isPresented
            shouldAutofocus = isPresented && source == .keyboardOrAccessibility
        case .toolbarAction, .escape, .disappear:
            isPresented = false
            shouldAutofocus = false
        case let .toolsChanged(hasOverflow):
            if !hasOverflow {
                isPresented = false
                shouldAutofocus = false
            }
        }
    }
}

struct ScreenshotMoreToolsTriggerButton: NSViewRepresentable {
    let systemImage: String
    let label: String
    let isSelected: Bool
    let focusRequestID: UUID?
    let action: (ScreenshotMoreToolsActivationSource) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> FocusableButtonContainer {
        let container = FocusableButtonContainer()
        let button = container.button
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .exterior
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        button.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.targetDidMoveToWindow()
        }
        context.coordinator.attach(button)
        container.onMouseActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateFromMouse()
        }
        update(button, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: FocusableButtonContainer, context: Context) {
        let button = container.button
        context.coordinator.action = action
        context.coordinator.attach(button)
        container.onMouseActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateFromMouse()
        }
        update(button, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ container: FocusableButtonContainer,
        coordinator: Coordinator
    ) {
        let button = container.button
        button.onWindowChange = nil
        container.onMouseActivate = nil
        container.nextTrackingEventForTesting = nil
        coordinator.detach()
    }

    private func update(_ button: FocusableButton, coordinator: Coordinator) {
        let symbol = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: nil
        )
        button.image = symbol?.withSymbolConfiguration(
            .init(
                pointSize: BlocksCompactIconButtonDensity.standard.iconSize,
                weight: .medium
            )
        )
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setBlocksSelected(isSelected)
        coordinator.requestFocus(focusRequestID)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: (ScreenshotMoreToolsActivationSource) -> Void
        private let focusCoordinator = ScreenshotFocusRequestCoordinator()
        private var lastFocusRequestID: UUID?
        private var focusGeneration = 0

        init(action: @escaping (ScreenshotMoreToolsActivationSource) -> Void) {
            self.action = action
        }

        @objc func activate(_ sender: NSButton) {
            action(.keyboardOrAccessibility)
        }

        func activateFromMouse() {
            action(.mouse)
        }

        func attach(_ button: FocusableButton) {
            focusCoordinator.attach(button)
        }

        func detach() {
            focusCoordinator.detach()
        }

        func targetDidMoveToWindow() {
            focusCoordinator.targetDidMoveToWindow()
        }

        func requestFocus(_ requestID: UUID?) {
            guard let requestID,
                  requestID != lastFocusRequestID else { return }
            lastFocusRequestID = requestID
            focusGeneration &+= 1
            focusCoordinator.requestFocusAfterCurrentEvent(focusGeneration)
        }
    }

    final class FocusableButton: BlocksAppKitCompactButton {
        var onWindowChange: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }
    }

    final class FocusableButtonContainer: NSView {
        let button = FocusableButton()
        var onMouseActivate: (() -> Void)?
        var nextTrackingEventForTesting:
            ((NSEvent.EventTypeMask) -> NSEvent?)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override var intrinsicContentSize: NSSize {
            .init(
                width: BlocksCompactIconButtonDensity.standard.hitTarget,
                height: BlocksCompactIconButtonDensity.standard.hitTarget
            )
        }

        override func layout() {
            super.layout()
            let visualSize = BlocksCompactIconButtonDensity.standard.visualSize
            button.frame = NSRect(
                x: (bounds.width - visualSize) / 2,
                y: (bounds.height - visualSize) / 2,
                width: visualSize,
                height: visualSize
            )
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard button.isEnabled,
                  !isHidden,
                  alphaValue > 0.01,
                  bounds.contains(point) else { return nil }
            return self
        }

        func activateFromMouse() {
            onMouseActivate?()
        }

        override func mouseDown(with event: NSEvent) {
            guard button.isEnabled, let window else { return }

            var isInside = true
            var receivedMouseUp = false
            button.highlight(true)
            defer { button.highlight(false) }

            let trackingMask: NSEvent.EventTypeMask = [
                .leftMouseDragged,
                .leftMouseUp,
            ]
            while let nextEvent = nextTrackingEvent(for: trackingMask, window: window) {
                isInside = bounds.contains(convert(nextEvent.locationInWindow, from: nil))
                button.highlight(isInside)
                guard nextEvent.type == .leftMouseUp else { continue }
                receivedMouseUp = true
                break
            }

            guard receivedMouseUp, isInside else { return }
            activateFromMouse()
        }

        private func nextTrackingEvent(
            for mask: NSEvent.EventTypeMask,
            window: NSWindow
        ) -> NSEvent? {
            if let nextTrackingEventForTesting {
                return nextTrackingEventForTesting(mask)
            }
            return window.nextEvent(matching: mask)
        }
    }
}

enum ScreenshotMoreToolsPanelMetrics {
    static func columnCount(toolCount: Int) -> Int {
        min(3, max(1, toolCount))
    }

    static func panelWidth(toolCount: Int) -> CGFloat {
        switch columnCount(toolCount: toolCount) {
        case 1: 176
        case 2: 224
        default: 320
        }
    }
}

private struct ScreenshotMoreToolsPanel: View {
    @Environment(\.dismiss) private var dismiss
    let tools: [ScreenshotToolbarItemID]
    let selectedItem: ScreenshotToolbarItemID
    let shouldAutofocus: Bool
    let onExit: () -> Void
    let onSelect: (ScreenshotToolbarItemID) -> Void
    @FocusState private var focusedTool: ScreenshotToolbarItemID?

    private var columnCount: Int {
        ScreenshotMoreToolsPanelMetrics.columnCount(toolCount: tools.count)
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }
    private var panelWidth: CGFloat {
        ScreenshotMoreToolsPanelMetrics.panelWidth(toolCount: tools.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.string("screenshot.editor.moreTools"), systemImage: "ellipsis")
                    .font(.headline)
                Spacer()
                Text("\(tools.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(tools) { item in
                    BlocksSelectableTile(
                        title: item.localizedTitle,
                        systemImage: item.systemImage,
                        isSelected: selectedItem == item,
                        isFocused: focusedTool == item
                    ) {
                        onSelect(item)
                    }
                    .focusable(true)
                    .focused($focusedTool, equals: item)
                }
            }
        }
        .padding(16)
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard shouldAutofocus else { return }
            focusedTool = tools.contains(selectedItem) ? selectedItem : tools.first
        }
        .onDisappear {
            focusedTool = nil
        }
        .onExitCommand {
            onExit()
            dismiss()
        }
    }
}

private struct ScreenshotExpandedPropertiesRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ScreenshotEditorStore
    @ObservedObject var aspectControlModel: ScreenshotAspectControlModel
    let maximumWidth: CGFloat
    var pluginContent: AnyView? = nil

    @State private var isNamingWatermarkPreset = false
    @State private var watermarkPresetName = ""
    @FocusState private var isWatermarkTextFocused: Bool

    var body: some View {
        ScreenshotChromeContentLayout(maximumWidth: maximumWidth, height: ScreenshotDesignTokens.toolbarPropertyHeight) {
            ViewThatFits(in: .horizontal) {
                propertyContents.fixedSize(horizontal: true, vertical: false)
                ScreenshotChromeOverflowRow { propertyContents }
                    .id(inspectorPresentationID)
            }
        }
    }

    private var propertyContents: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            styleControls
            pluginContent
        }
        .padding(.horizontal, BlocksVisualTokens.Spacing.sm)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var inspectorPresentationID: String {
        [
            store.activeToolbarItemID.rawValue,
            store.selectedElement == nil ? "empty" : "selected",
            String(describing: store.selectedStepComponent),
            String(describing: store.selectedCalloutComponent),
            store.activeStyle.fillColor == nil ? "no-fill" : "fill",
            isNamingWatermarkPreset ? "watermark-naming" : "watermark-idle"
        ].joined(separator: "|")
    }

    private func overflowButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        BlocksCompactIconButton(
            systemImage: systemImage,
            label: label,
            density: .micro,
            action: action
        )
        .frame(width: 30, height: ScreenshotDesignTokens.toolbarPropertyHeight)
    }

    @ViewBuilder
    private var styleControls: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            if store.activeToolbarItemID == .ocr {
                Text(L10n.string("screenshot.ocr.dragHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.activeToolbarItemID == .aspectRatio {
                ScreenshotAspectRatioPropertyStrip(
                    model: aspectControlModel,
                    onSelect: store.applyAspectSelection,
                    onSave: store.preferencesStore.saveCustomConstraint
                )
            } else if store.selectedTool == .select, store.selectedElement == nil {
                Text(L10n.string("screenshot.editor.noSelection"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if store.selectedElement != nil { objectActions }
                toolSpecificControls
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var toolSpecificControls: some View {
        switch store.inspectorTool {
        case .arrow, .line:
            compactColor(L10n.string("screenshot.editor.color"), path: \.strokeColor)
            compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.lineWidth), range: 1...24)
            compactPicker(L10n.string("screenshot.editor.linePattern"), selection: styleBinding(\.linePattern, commitsImmediately: true)) {
                Text(L10n.string("screenshot.editor.line.solid")).tag(ScreenshotLinePattern.solid)
                Text(L10n.string("screenshot.editor.line.dashed")).tag(ScreenshotLinePattern.dashed)
            }
            compactPicker(L10n.string("screenshot.editor.startEnding"), selection: styleBinding(\.startEnding, commitsImmediately: true)) { endingOptions }
            compactPicker(L10n.string("screenshot.editor.endEnding"), selection: styleBinding(\.endEnding, commitsImmediately: true)) { endingOptions }
            curvatureControl
            compactSlider(L10n.string("screenshot.editor.arrowHeadSize"), value: styleDoubleBinding(\.arrowHeadSize), range: 0.5...2)
            compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.opacity), range: 0.1...1)
        case .rectangle, .ellipse:
            compactColor(L10n.string("screenshot.editor.strokeColor"), path: \.strokeColor)
            compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.lineWidth), range: 1...24)
            Toggle(L10n.string("screenshot.editor.fill"), isOn: fillToggleBinding).toggleStyle(.checkbox)
            if store.activeStyle.fillColor != nil {
                compactColor(L10n.string("screenshot.editor.fillColor"), path: \.fillColorValue)
                compactSlider(L10n.string("screenshot.editor.fillOpacity"), value: styleDoubleBinding(\.fillOpacity), range: 0...1)
            }
            if store.inspectorTool == .rectangle {
                compactSlider(L10n.string("screenshot.editor.cornerRadius"), value: styleDoubleBinding(\.cornerRadius), range: 0...48)
            }
            compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.opacity), range: 0.1...1)
        case .freehand:
            compactColor(L10n.string("screenshot.editor.color"), path: \.strokeColor)
            compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.lineWidth), range: 1...24)
            compactSlider(L10n.string("screenshot.editor.smoothing"), value: styleDoubleBinding(\.smoothing), range: 0...1)
            compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.opacity), range: 0.1...1)
        case .text:
            textControls
        case .highlight:
            compactColor(L10n.string("screenshot.editor.color"), path: \.strokeColor)
            compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.lineWidth), range: 4...48)
            compactPicker(L10n.string("screenshot.editor.highlightMode"), selection: styleBinding(\.highlightMode, commitsImmediately: true)) {
                Text(L10n.string("screenshot.editor.highlight.freehand")).tag(ScreenshotHighlightMode.freehand)
                Text(L10n.string("screenshot.editor.highlight.rectangle")).tag(ScreenshotHighlightMode.rectangle)
            }
            compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.opacity), range: 0.1...1)
        case .blur, .pixelate:
            effectShapePicker
            compactSlider(L10n.string("screenshot.editor.intensity"), value: styleDoubleBinding(\.effectIntensity), range: 2...40)
        case .counter:
            compactPicker(L10n.string("screenshot.editor.shape"), selection: styleBinding(\.counterShape, commitsImmediately: true)) {
                Text(L10n.string("screenshot.editor.shape.circle")).tag(ScreenshotCounterShape.circle)
                Text(L10n.string("screenshot.editor.shape.roundedRectangle")).tag(ScreenshotCounterShape.roundedRectangle)
            }
            compactSlider(L10n.string("screenshot.editor.size"), value: styleDoubleBinding(\.counterSize), range: 18...160)
            compactColor(L10n.string("screenshot.editor.fillColor"), path: \.counterFillColor)
            compactColor(L10n.string("screenshot.editor.textColor"), path: \.counterTextColor)
            compactColor(L10n.string("screenshot.editor.strokeColor"), path: \.strokeColor)
            compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.lineWidth), range: 0...8)
        case .step:
            switch store.selectedStepComponent ?? .badge {
            case .badge:
                stepBadgeControls
            case .connector:
                stepConnectorControls
            case .note:
                stepNoteControls
            }
        case .callout:
            switch store.selectedCalloutComponent ?? .connector {
            case .target:
                if store.selectedElement.flatMap(ScreenshotCalloutResolvedLayout.init)?.targetRect != nil {
                    calloutTargetControls
                } else {
                    calloutConnectorControls
                }
            case .connector:
                calloutConnectorControls
            case .note:
                calloutNoteControls
            }
        case .spotlight:
            effectShapePicker
            compactSlider(L10n.string("screenshot.editor.dimIntensity"), value: styleDoubleBinding(\.effectIntensity), range: 0.1...0.9)
            compactSlider(L10n.string("screenshot.editor.feather"), value: styleDoubleBinding(\.spotlightFeather), range: 0...40)
        case .redact:
            compactPicker(L10n.string("screenshot.editor.redactMode"), selection: styleBinding(\.redactMode, commitsImmediately: true)) {
                Text(L10n.string("screenshot.editor.redact.solid")).tag(ScreenshotRedactMode.solid)
                Text(L10n.string("screenshot.editor.redact.securePixelate")).tag(ScreenshotRedactMode.securePixelate)
            }
            effectShapePicker
            if store.activeStyle.redactMode == .solid {
                compactColor(L10n.string("screenshot.editor.fillColor"), path: \.strokeColor)
            } else {
                compactSlider(L10n.string("screenshot.editor.intensity"), value: styleDoubleBinding(\.effectIntensity), range: 8...40)
            }
        case .magnifier:
            compactSlider(L10n.string("screenshot.editor.zoom"), value: styleDoubleBinding(\.effectIntensity), range: 1.5...5)
            compactSlider(L10n.string("screenshot.editor.diameter"), value: styleDoubleBinding(\.magnifierDiameter), range: 60...240)
            compactColor(L10n.string("screenshot.editor.strokeColor"), path: \.strokeColor)
            compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.lineWidth), range: 0...12)
            compactSlider(L10n.string("screenshot.editor.shadow"), value: styleDoubleBinding(\.magnifierShadow), range: 0...1)
        case .watermark:
            watermarkControls
        case .select:
            EmptyView()
        }
    }

    @ViewBuilder
    private var watermarkControls: some View {
        if let watermark = store.selectedWatermark {
            compactPicker(
                L10n.string("screenshot.watermark.preset"),
                selection: Binding<UUID?>(
                    get: {
                        guard let presetID = watermark.presetID,
                              store.watermarkPresets.contains(where: { $0.id == presetID }) else {
                            return nil
                        }
                        return presetID
                    },
                    set: { presetID in
                        guard let presetID,
                              let preset = store.watermarkPresets.first(where: { $0.id == presetID }) else { return }
                        _ = store.applyWatermark(preset, replacing: store.selectedElementID)
                    }
                )
            ) {
                Text(L10n.string("screenshot.watermark.custom")).tag(Optional<UUID>.none)
                ForEach(store.watermarkPresets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            TextField(
                L10n.string("screenshot.watermark.text.content"),
                text: watermarkBinding(\.text)
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 132)
            .focused($isWatermarkTextFocused)
            .onChange(of: isWatermarkTextFocused) { _, focused in
                focused ? store.beginWatermarkEditing() : store.endWatermarkEditing()
            }
            ScreenshotColorPickerButton(
                color: watermarkColorBinding,
                recentColors: store.preferencesStore.preferences.recentColors,
                onEditingChanged: { editing in
                    editing ? store.beginWatermarkEditing() : store.endWatermarkEditing()
                },
                onColorCommitted: store.recordRecentColor
            )
            compactSlider(
                L10n.string("screenshot.watermark.text.fontSize"),
                value: watermarkBinding(\.fontSizeFraction),
                range: 0.01...0.12,
                onEditingChanged: watermarkEditingChanged
            )
            compactSlider(
                L10n.string("screenshot.watermark.density"),
                value: watermarkBinding(\.density),
                range: 0...1,
                onEditingChanged: watermarkEditingChanged
            )
            compactSlider(
                L10n.string("screenshot.watermark.angle"),
                value: watermarkBinding(\.angleDegrees),
                range: -90...90,
                onEditingChanged: watermarkEditingChanged
            )
            compactSlider(
                L10n.string("screenshot.watermark.opacity"),
                value: watermarkBinding(\.opacity),
                range: 0...1,
                onEditingChanged: watermarkEditingChanged
            )
            if isNamingWatermarkPreset {
                TextField(
                    L10n.string("screenshot.watermark.name"),
                    text: $watermarkPresetName
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                Button(L10n.string("common.save")) {
                    if store.saveSelectedWatermarkPreset(name: watermarkPresetName) {
                        isNamingWatermarkPreset = false
                        watermarkPresetName = ""
                    }
                }
                .disabled(watermarkPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.string("common.cancel")) {
                    isNamingWatermarkPreset = false
                    watermarkPresetName = ""
                }
            } else {
                Button(L10n.string("screenshot.watermark.saveAsPreset")) {
                    watermarkPresetName = watermark.name
                    isNamingWatermarkPreset = true
                }
            }
        }
    }

    @ViewBuilder
    private var textControls: some View {
        compactColor(L10n.string("screenshot.editor.textColor"), path: \.strokeColor)
        compactSlider(L10n.string("screenshot.editor.fontSize"), value: styleDoubleBinding(\.fontSize), range: 10...96)
        compactPicker(L10n.string("screenshot.editor.textWeight"), selection: styleBinding(\.textWeight, commitsImmediately: true)) {
            ForEach(ScreenshotTextWeight.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        compactPicker(L10n.string("screenshot.editor.textAlignment"), selection: styleBinding(\.textAlignment, commitsImmediately: true)) {
            ForEach(ScreenshotTextAlignment.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        Toggle(L10n.string("screenshot.editor.textBackground"), isOn: textBackgroundToggleBinding).toggleStyle(.checkbox)
        if store.activeStyle.textBackgroundColor != nil {
            compactColor(
                L10n.string("screenshot.editor.backgroundColor"),
                path: \.textBackgroundColorValue,
                allowsTransparent: true,
                isTransparent: false,
                onTransparentSelected: clearTextBackground
            )
            compactSlider(L10n.string("screenshot.editor.padding"), value: styleDoubleBinding(\.textBackgroundPadding), range: 0...24)
        }
        compactSlider(L10n.string("screenshot.editor.lineSpacing"), value: styleDoubleBinding(\.textLineSpacing), range: 0.8...2)
        compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.opacity), range: 0.1...1)
    }

    @ViewBuilder
    private var stepBadgeControls: some View {
        if store.selectedElement?.kind == .step {
            ScreenshotNumericField(
                title: L10n.string("screenshot.editor.step.number"),
                value: Binding(
                    get: { Double(store.selectedElement?.stepNumber ?? 1) },
                    set: { store.updateSelectedStepNumber(max(1, Int($0.rounded()))) }
                ),
                descriptor: .init(range: 1...999, step: 1, fractionDigits: 0, unit: .number)
            )
        }
        compactPicker(
            L10n.string("screenshot.editor.shape"),
            selection: styleBinding(\.stepBadgeShape, commitsImmediately: true)
        ) {
            Text(L10n.string("screenshot.editor.shape.circle")).tag(ScreenshotCounterShape.circle)
            Text(L10n.string("screenshot.editor.shape.roundedRectangle")).tag(ScreenshotCounterShape.roundedRectangle)
        }
        compactSlider(L10n.string("screenshot.editor.size"), value: styleDoubleBinding(\.stepBadgeSize), range: 18...160)
        compactColor(L10n.string("screenshot.editor.fillColor"), path: \.stepBadgeFillColor)
        compactColor(L10n.string("screenshot.editor.textColor"), path: \.stepBadgeTextColor)
        compactColor(L10n.string("screenshot.editor.strokeColor"), path: \.stepBadgeBorderColor)
        compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.stepBadgeBorderWidth), range: 0...12)
        compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.stepBadgeOpacity), range: 0.1...1)
    }

    @ViewBuilder
    private var stepConnectorControls: some View {
        compactColor(L10n.string("screenshot.editor.color"), path: \.stepConnectorColor)
        compactSlider(L10n.string("screenshot.editor.lineWidth"), value: styleDoubleBinding(\.stepConnectorWidth), range: 1...24)
        compactPicker(
            L10n.string("screenshot.editor.linePattern"),
            selection: styleBinding(\.stepConnectorPattern, commitsImmediately: true)
        ) {
            Text(L10n.string("screenshot.editor.line.solid")).tag(ScreenshotLinePattern.solid)
            Text(L10n.string("screenshot.editor.line.dashed")).tag(ScreenshotLinePattern.dashed)
        }
        compactPicker(
            L10n.string("screenshot.editor.startEnding"),
            selection: styleBinding(\.stepConnectorStartEnding, commitsImmediately: true)
        ) { endingOptions }
        compactPicker(
            L10n.string("screenshot.editor.endEnding"),
            selection: styleBinding(\.stepConnectorEndEnding, commitsImmediately: true)
        ) { endingOptions }
        curvatureControl
        compactSlider(L10n.string("screenshot.editor.arrowHeadSize"), value: styleDoubleBinding(\.stepConnectorArrowHeadSize), range: 0.5...2)
        compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.stepConnectorOpacity), range: 0.1...1)
    }

    @ViewBuilder
    private var stepNoteControls: some View {
        compactColor(L10n.string("screenshot.editor.textColor"), path: \.stepNoteTextColor)
        compactSlider(L10n.string("screenshot.editor.fontSize"), value: styleDoubleBinding(\.stepNoteFontSize), range: 10...96)
        compactPicker(
            L10n.string("screenshot.editor.textWeight"),
            selection: styleBinding(\.stepNoteWeight, commitsImmediately: true)
        ) {
            ForEach(ScreenshotTextWeight.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        compactPicker(
            L10n.string("screenshot.editor.textAlignment"),
            selection: styleBinding(\.stepNoteAlignment, commitsImmediately: true)
        ) {
            ForEach(ScreenshotTextAlignment.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        Toggle(
            L10n.string("screenshot.editor.textBackground"),
            isOn: stepNoteBackgroundToggleBinding
        )
        .toggleStyle(.checkbox)
        if store.activeStyle.stepNoteHasBackground {
            compactColor(
                L10n.string("screenshot.editor.backgroundColor"),
                path: \.stepNoteBackgroundColor,
                allowsTransparent: true,
                isTransparent: store.activeStyle.stepNoteBackgroundColor.alpha == 0,
                onTransparentSelected: { makeBackgroundTransparent(\.stepNoteBackgroundColor) }
            )
            compactSlider(L10n.string("screenshot.editor.padding"), value: styleDoubleBinding(\.stepNotePadding), range: 0...24)
        }
        compactSlider(L10n.string("screenshot.editor.lineSpacing"), value: styleDoubleBinding(\.stepNoteLineSpacing), range: 0.8...2)
        compactSlider(L10n.string("screenshot.editor.opacity"), value: styleDoubleBinding(\.stepNoteOpacity), range: 0.1...1)
    }

    @ViewBuilder
    private var calloutTargetControls: some View {
        compactColor(L10n.string("screenshot.editor.strokeColor"), path: \.calloutTargetStrokeColor)
        compactSlider(
            L10n.string("screenshot.editor.lineWidth"),
            value: styleDoubleBinding(\.calloutTargetStrokeWidth),
            range: 1...24
        )
        Toggle(
            L10n.string("screenshot.editor.fill"),
            isOn: calloutTargetFillToggleBinding
        )
        .toggleStyle(.checkbox)
        if store.activeStyle.calloutTargetHasFill {
            compactColor(L10n.string("screenshot.editor.fillColor"), path: \.calloutTargetFillColor)
            compactSlider(
                L10n.string("screenshot.editor.fillOpacity"),
                value: styleDoubleBinding(\.calloutTargetFillOpacity),
                range: 0...1
            )
        }
        compactSlider(
            L10n.string("screenshot.editor.opacity"),
            value: styleDoubleBinding(\.calloutTargetOpacity),
            range: 0.1...1
        )
    }

    @ViewBuilder
    private var calloutConnectorControls: some View {
        compactColor(L10n.string("screenshot.editor.color"), path: \.calloutConnectorColor)
        compactSlider(
            L10n.string("screenshot.editor.lineWidth"),
            value: styleDoubleBinding(\.calloutConnectorWidth),
            range: 1...24
        )
        compactPicker(
            L10n.string("screenshot.editor.linePattern"),
            selection: styleBinding(\.calloutConnectorPattern, commitsImmediately: true)
        ) {
            Text(L10n.string("screenshot.editor.line.solid")).tag(ScreenshotLinePattern.solid)
            Text(L10n.string("screenshot.editor.line.dashed")).tag(ScreenshotLinePattern.dashed)
        }
        compactPicker(
            L10n.string("screenshot.editor.startEnding"),
            selection: styleBinding(\.calloutConnectorStartEnding, commitsImmediately: true)
        ) { endingOptions }
        compactPicker(
            L10n.string("screenshot.editor.endEnding"),
            selection: styleBinding(\.calloutConnectorEndEnding, commitsImmediately: true)
        ) { endingOptions }
        curvatureControl
        compactSlider(
            L10n.string("screenshot.editor.arrowHeadSize"),
            value: styleDoubleBinding(\.calloutConnectorArrowHeadSize),
            range: 0.5...2
        )
        compactSlider(
            L10n.string("screenshot.editor.opacity"),
            value: styleDoubleBinding(\.calloutConnectorOpacity),
            range: 0.1...1
        )
    }

    @ViewBuilder
    private var calloutNoteControls: some View {
        compactColor(L10n.string("screenshot.editor.textColor"), path: \.calloutNoteTextColor)
        compactSlider(
            L10n.string("screenshot.editor.fontSize"),
            value: styleDoubleBinding(\.calloutNoteFontSize),
            range: 10...96
        )
        compactPicker(
            L10n.string("screenshot.editor.textWeight"),
            selection: styleBinding(\.calloutNoteWeight, commitsImmediately: true)
        ) {
            ForEach(ScreenshotTextWeight.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        compactPicker(
            L10n.string("screenshot.editor.textAlignment"),
            selection: styleBinding(\.calloutNoteAlignment, commitsImmediately: true)
        ) {
            ForEach(ScreenshotTextAlignment.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        Toggle(
            L10n.string("screenshot.editor.textBackground"),
            isOn: calloutNoteBackgroundToggleBinding
        )
        .toggleStyle(.checkbox)
        if store.activeStyle.calloutNoteHasBackground {
            compactColor(
                L10n.string("screenshot.editor.backgroundColor"),
                path: \.calloutNoteBackgroundColor,
                allowsTransparent: true,
                isTransparent: store.activeStyle.calloutNoteBackgroundColor.alpha == 0,
                onTransparentSelected: { makeBackgroundTransparent(\.calloutNoteBackgroundColor) }
            )
            compactSlider(
                L10n.string("screenshot.editor.padding"),
                value: styleDoubleBinding(\.calloutNotePadding),
                range: 0...24
            )
        }
        compactSlider(
            L10n.string("screenshot.editor.lineSpacing"),
            value: styleDoubleBinding(\.calloutNoteLineSpacing),
            range: 0.8...2
        )
        compactSlider(
            L10n.string("screenshot.editor.opacity"),
            value: styleDoubleBinding(\.calloutNoteOpacity),
            range: 0.1...1
        )
    }

    @ViewBuilder
    private var effectShapePicker: some View {
        compactPicker(L10n.string("screenshot.editor.shape"), selection: styleBinding(\.effectShape, commitsImmediately: true)) {
            Text(L10n.string("screenshot.editor.shape.rectangle")).tag(ScreenshotEffectShape.rectangle)
            Text(L10n.string("screenshot.editor.shape.ellipse")).tag(ScreenshotEffectShape.ellipse)
        }
    }

    private var objectActions: some View {
        HStack(spacing: 2) {
            if store.selectedElement?.kind == .watermark {
                compactObjectButton(
                    "trash",
                    key: "screenshot.editor.object.delete",
                    role: .destructive,
                    action: store.deleteSelection
                )
            } else {
                if store.selectedElement?.kind == .step {
                    compactObjectButton(
                        "square.3.layers.3d.down.right",
                        key: "screenshot.editor.step.split",
                        action: store.splitSelectedStep
                    )
                }
                compactObjectButton("doc.on.doc", key: "screenshot.editor.object.duplicate", action: store.duplicateSelection)
                compactObjectButton("square.3.layers.3d.top.filled", key: "screenshot.editor.object.forward", action: store.moveSelectionForward)
                compactObjectButton("square.3.layers.3d.bottom.filled", key: "screenshot.editor.object.backward", action: store.moveSelectionBackward)
                compactObjectButton("trash", key: "screenshot.editor.object.delete", role: .destructive, action: store.deleteSelection)
            }
        }
    }

    @ViewBuilder
    private var endingOptions: some View {
        ForEach(ScreenshotLineEnding.allCases, id: \.self) { ending in
            Text(ending.localizedTitle).tag(ending)
        }
    }

    private func compactLabel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            content()
        }
    }

    private func compactColor(
        _ title: String,
        path: WritableKeyPath<ScreenshotElementAppearance, ScreenshotColor>,
        allowsTransparent: Bool = false,
        isTransparent: Bool = false,
        onTransparentSelected: @escaping () -> Void = {}
    ) -> some View {
        compactLabel(title) {
            ScreenshotColorPickerButton(
                color: styleScreenshotColorBinding(path),
                recentColors: store.preferencesStore.preferences.recentColors,
                allowsTransparent: allowsTransparent,
                isTransparent: isTransparent,
                onEditingChanged: styleColorEditingChanged,
                onColorCommitted: store.recordRecentColor,
                onTransparentSelected: onTransparentSelected
            )
        }
    }

    private func makeBackgroundTransparent(
        _ path: WritableKeyPath<ScreenshotElementAppearance, ScreenshotColor>
    ) {
        var style = store.activeStyle
        let current = style[keyPath: path]
        style[keyPath: path] = ScreenshotColor(
            red: current.red,
            green: current.green,
            blue: current.blue,
            alpha: 0
        )
        store.updateSelectedStyle(style)
    }

    private func clearTextBackground() {
        var style = store.activeStyle
        style.textBackgroundColor = nil
        store.updateSelectedStyle(style)
    }

    private func compactObjectButton(
        _ systemImage: String,
        key: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        ScreenshotToolbarIconButton(
            systemImage: systemImage,
            label: L10n.string(key),
            emphasis: role == .destructive ? .destructive : .standard,
            action: action
        )
    }

    private func compactPicker<Value: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .frame(minWidth: 82)
        }
    }

    private func compactSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) -> some View {
        let usesPercent = range.lowerBound >= 0 && range.upperBound <= 1
        let descriptor = ScreenshotNumericValueDescriptor(
            range: range,
            step: usesPercent ? 0.01 : (range.upperBound <= 5 ? 0.1 : 1),
            fractionDigits: range.upperBound <= 5 ? 1 : 0,
            unit: usesPercent ? .percent : (title == L10n.string("screenshot.editor.zoom") ? .multiplier : .number)
        )
        return ScreenshotNumericSlider(
            title: title,
            value: value,
            descriptor: descriptor,
            onEditingChanged: { editing in
                if let onEditingChanged {
                    onEditingChanged(editing)
                } else {
                    editing ? store.beginStyleEditing() : store.endStyleEditing()
                }
            }
        )
    }

    private func watermarkEditingChanged(_ editing: Bool) {
        editing ? store.beginWatermarkEditing() : store.endWatermarkEditing()
    }

    private var curvatureControl: some View {
        ScreenshotNumericSlider(
            title: L10n.string("screenshot.editor.curvature"),
            value: Binding(
                get: { store.activeStyle.curvature },
                set: {
                    store.updateCurvature(
                        $0,
                        bypassesAnchor: NSEvent.modifierFlags.contains(.option)
                    )
                }
            ),
            descriptor: .init(
                range: -1...1,
                step: 0.1,
                fractionDigits: 1,
                unit: .number
            ),
            onEditingChanged: { editing in
                editing ? store.beginCurvatureEditing() : store.endCurvatureEditing()
            },
            showsCenterAnchor: true
        )
        .onTapGesture(count: 2, perform: store.resetCurvature)
        .blocksImmediateTooltip(L10n.string("screenshot.editor.curvature.reset"))
    }

    private func styleBinding<Value>(
        _ path: WritableKeyPath<ScreenshotElementAppearance, Value>,
        commitsImmediately: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: { store.activeStyle[keyPath: path] },
            set: { value in
                var style = store.activeStyle
                style[keyPath: path] = value
                store.updateSelectedStyle(style, commitsImmediately: commitsImmediately)
            }
        )
    }

    private func styleDoubleBinding(_ path: WritableKeyPath<ScreenshotElementAppearance, Double>) -> Binding<Double> {
        styleBinding(path)
    }

    private func styleScreenshotColorBinding(
        _ path: WritableKeyPath<ScreenshotElementAppearance, ScreenshotColor>
    ) -> Binding<ScreenshotColor> {
        Binding(
            get: { store.activeStyle[keyPath: path].opaqueRGB },
            set: { color in
                var style = store.activeStyle
                style[keyPath: path] = color.opaqueRGB
                store.updateSelectedStyle(style)
            }
        )
    }

    private func styleColorEditingChanged(_ editing: Bool) {
        editing ? store.beginStyleEditing() : store.endStyleEditing()
    }

    private func watermarkBinding<Value>(
        _ path: WritableKeyPath<ScreenshotWatermarkStyle, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                store.selectedWatermark?.style[keyPath: path]
                    ?? ScreenshotWatermarkStyle(text: "")[keyPath: path]
            },
            set: { value in
                store.updateSelectedWatermark { $0[keyPath: path] = value }
            }
        )
    }

    private var watermarkColorBinding: Binding<ScreenshotColor> {
        Binding(
            get: { store.selectedWatermark?.style.color.opaqueRGB ?? .white },
            set: { color in store.updateSelectedWatermark { $0.color = color.opaqueRGB } }
        )
    }

    private var fillToggleBinding: Binding<Bool> {
        Binding(
            get: { store.activeStyle.fillColor != nil },
            set: { enabled in
                var style = store.activeStyle
                style.fillColor = enabled
                    ? ScreenshotColor(red: style.strokeColor.red, green: style.strokeColor.green, blue: style.strokeColor.blue, alpha: 1)
                    : nil
                store.updateSelectedStyle(style, commitsImmediately: true)
            }
        )
    }

    private var textBackgroundToggleBinding: Binding<Bool> {
        Binding(
            get: { store.activeStyle.textBackgroundColor != nil },
            set: { enabled in
                var style = store.activeStyle
                style.textBackgroundColor = enabled
                    ? ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 0.62)
                    : nil
                store.updateSelectedStyle(style, commitsImmediately: true)
            }
        )
    }

    private var stepNoteBackgroundToggleBinding: Binding<Bool> {
        Binding(
            get: { store.activeStyle.stepNoteHasBackground },
            set: { enabled in
                var style = store.activeStyle
                var step = style.stepAppearance
                step.note.backgroundColor = enabled
                    ? ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 0.62)
                    : nil
                style.stepAppearance = step
                store.updateSelectedStyle(style, commitsImmediately: true)
            }
        )
    }

    private var calloutTargetFillToggleBinding: Binding<Bool> {
        Binding(
            get: { store.activeStyle.calloutTargetHasFill },
            set: { enabled in
                var style = store.activeStyle
                var appearance = style.calloutAppearance
                appearance.target.fillColor = enabled ? appearance.target.strokeColor : nil
                style.calloutAppearance = appearance
                store.updateSelectedStyle(style, commitsImmediately: true)
            }
        )
    }

    private var calloutNoteBackgroundToggleBinding: Binding<Bool> {
        Binding(
            get: { store.activeStyle.calloutNoteHasBackground },
            set: { enabled in
                var style = store.activeStyle
                var appearance = style.calloutAppearance
                appearance.note.backgroundColor = enabled
                    ? ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 0.62)
                    : nil
                style.calloutAppearance = appearance
                store.updateSelectedStyle(style, commitsImmediately: true)
            }
        )
    }
}

struct ScreenshotEditorToolStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tools: [ScreenshotToolbarItemID]
    let selectedItem: ScreenshotToolbarItemID
    let popoverItem: ScreenshotToolbarItemID?
    let isPopoverPresented: Binding<Bool>?
    let popoverContent: AnyView?
    let popoverFocusRequestID: UUID?
    let onSelect: (ScreenshotToolbarItemID) -> Void
    private let label: (ScreenshotToolbarItemID) -> String
    @State private var scrollPosition: ScreenshotToolbarItemID?

    init(
        tools: [ScreenshotToolbarItemID],
        selectedItem: ScreenshotToolbarItemID,
        label: @escaping (ScreenshotToolbarItemID) -> String = { $0.localizedTitle },
        popoverItem: ScreenshotToolbarItemID? = nil,
        isPopoverPresented: Binding<Bool>? = nil,
        popoverContent: AnyView? = nil,
        popoverFocusRequestID: UUID? = nil,
        onSelect: @escaping (ScreenshotToolbarItemID) -> Void
    ) {
        self.tools = tools
        self.selectedItem = selectedItem
        self.label = label
        self.popoverItem = popoverItem
        self.isPopoverPresented = isPopoverPresented
        self.popoverContent = popoverContent
        self.popoverFocusRequestID = popoverFocusRequestID
        self.onSelect = onSelect
    }

    var body: some View {
        GeometryReader { geometry in
            let overflows = ScreenshotEditorToolStripMetrics.overflows(
                toolCount: tools.count,
                viewportWidth: geometry.size.width
            )
            let firstVisibleIndex = scrollPosition.flatMap(tools.firstIndex(of:)) ?? 0
            let maximumFirstVisibleIndex = ScreenshotEditorToolStripMetrics.maximumFirstVisibleIndex(
                toolCount: tools.count,
                viewportWidth: geometry.size.width
            )
            let canScrollBackward = overflows && firstVisibleIndex > 0
            let canScrollForward = overflows && firstVisibleIndex < maximumFirstVisibleIndex

            ScrollView(.horizontal) {
                HStack(spacing: ScreenshotEditorToolStripMetrics.itemSpacing) {
                    ForEach(tools, id: \.id) { item in
                        toolButton(item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $scrollPosition, anchor: .leading)
            .mask {
                ScreenshotPropertyEdgeMask(
                    fadesLeadingEdge: canScrollBackward,
                    fadesTrailingEdge: canScrollForward
                )
            }
            .overlay(alignment: .leading) {
                if canScrollBackward {
                    scrollButton(systemImage: "chevron.left", direction: -1, viewportWidth: geometry.size.width)
                }
            }
            .overlay(alignment: .trailing) {
                if canScrollForward {
                    scrollButton(systemImage: "chevron.right", direction: 1, viewportWidth: geometry.size.width)
                }
            }
            .onAppear { normalizeScrollPosition() }
            .onChange(of: tools) { _, _ in normalizeScrollPosition() }
            .onChange(of: selectedItem) { _, selected in reveal(selected) }
        }
        .frame(
            minWidth: tools.isEmpty ? 0 : BlocksVisualTokens.Control.minimumHitTarget,
            idealWidth: ScreenshotEditorToolStripMetrics.intrinsicWidth(toolCount: tools.count),
            maxWidth: .infinity,
            minHeight: BlocksVisualTokens.Control.minimumHitTarget,
            maxHeight: BlocksVisualTokens.Control.minimumHitTarget
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func toolButton(_ item: ScreenshotToolbarItemID) -> some View {
        let button = ScreenshotToolbarIconButton(
            systemImage: item.systemImage,
            label: label(item),
            isSelected: selectedItem == item,
            focusRequestID: item == popoverItem ? popoverFocusRequestID : nil,
            action: { onSelect(item) }
        )
        if item == popoverItem,
           let isPopoverPresented,
           let popoverContent {
            button
                .popover(isPresented: isPopoverPresented, arrowEdge: .bottom) {
                    popoverContent
                }
                .id(item)
        } else {
            button.id(item)
        }
    }

    private func scrollButton(
        systemImage: String,
        direction: Int,
        viewportWidth: CGFloat
    ) -> some View {
        BlocksCompactIconButton(
            systemImage: systemImage,
            label: L10n.string(
                direction < 0
                    ? "screenshot.editor.properties.scrollBackward"
                    : "screenshot.editor.properties.scrollForward"
            ),
            density: .micro
        ) {
            scroll(direction: direction, viewportWidth: viewportWidth)
        }
    }

    private func scroll(direction: Int, viewportWidth: CGFloat) {
        guard !tools.isEmpty else { return }
        let currentIndex = scrollPosition.flatMap(tools.firstIndex(of:)) ?? 0
        let page = ScreenshotEditorToolStripMetrics.visibleToolCount(viewportWidth: viewportWidth)
        let maximum = ScreenshotEditorToolStripMetrics.maximumFirstVisibleIndex(
            toolCount: tools.count,
            viewportWidth: viewportWidth
        )
        let next = min(maximum, max(0, currentIndex + direction * page))
        withAnimation(BlocksMotionRole.hoverFocus.animation(reduceMotion: reduceMotion)) {
            scrollPosition = tools[next]
        }
    }

    private func normalizeScrollPosition() {
        guard !tools.isEmpty else {
            scrollPosition = nil
            return
        }
        if let scrollPosition, tools.contains(scrollPosition) { return }
        scrollPosition = tools.first
    }

    private func reveal(_ tool: ScreenshotToolbarItemID) {
        guard tools.contains(tool) else { return }
        withAnimation(BlocksMotionRole.hoverFocus.animation(reduceMotion: reduceMotion)) {
            scrollPosition = tool
        }
    }
}

enum ScreenshotEditorToolStripMetrics {
    static let itemSpacing: CGFloat = 2

    static func intrinsicWidth(toolCount: Int) -> CGFloat {
        guard toolCount > 0 else { return 0 }
        return CGFloat(toolCount) * BlocksVisualTokens.Control.minimumHitTarget
            + CGFloat(toolCount - 1) * itemSpacing
    }

    static func overflows(toolCount: Int, viewportWidth: CGFloat) -> Bool {
        intrinsicWidth(toolCount: toolCount) > viewportWidth + 1
    }

    static func visibleToolCount(viewportWidth: CGFloat) -> Int {
        let pitch = BlocksVisualTokens.Control.minimumHitTarget + itemSpacing
        return max(1, Int((max(pitch, viewportWidth) / pitch).rounded(.down)))
    }

    static func maximumFirstVisibleIndex(toolCount: Int, viewportWidth: CGFloat) -> Int {
        max(0, toolCount - visibleToolCount(viewportWidth: viewportWidth))
    }
}

struct ScreenshotEditorToolButton: View {
    let item: ScreenshotToolbarItemID
    let selectedItem: ScreenshotToolbarItemID
    let onSelect: (ScreenshotToolbarItemID) -> Void
    var body: some View {
        ScreenshotToolbarIconButton(
            systemImage: item.systemImage,
            label: item.localizedTitle,
            isSelected: selectedItem == item,
            action: { onSelect(item) }
        )
    }
}

private enum ScreenshotPropertyOverflowEdge {
    case leading
    case trailing
}

private struct ScreenshotPropertyContentWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScreenshotPropertyContentMeasurementView {
        let view = ScreenshotPropertyContentMeasurementView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenshotPropertyContentMeasurementView, context: Context) {
        nsView.onChange = onChange
        nsView.publishWidthIfNeeded()
    }
}

private final class ScreenshotPropertyContentMeasurementView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var publishedWidth: CGFloat = -1

    override func layout() {
        super.layout()
        publishWidthIfNeeded()
    }

    func publishWidthIfNeeded() {
        let width = bounds.width
        guard width > 0, abs(width - publishedWidth) > 0.5 else { return }
        publishedWidth = width
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.bounds.width - width) <= 0.5 else { return }
            self.onChange?(width)
        }
    }
}

private struct ScreenshotPropertyEdgeMask: View {
    let fadesLeadingEdge: Bool
    let fadesTrailingEdge: Bool

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [fadesLeadingEdge ? .clear : .black, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 38)
            Rectangle().fill(.black)
            LinearGradient(
                colors: [.black, fadesTrailingEdge ? .clear : .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 38)
        }
    }
}

extension ScreenshotToolbarItemID {
    var localizedTitle: String { L10n.string("screenshot.editor.tool.\(rawValue)") }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .aspectRatio: "aspectratio"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .freehand: "pencil.tip"
        case .text: "character.cursor.ibeam"
        case .highlight: "highlighter"
        case .blur: "drop.halffull"
        case .pixelate: "square.grid.3x3"
        case .counter: "number.circle"
        case .step: "list.number"
        case .callout: "text.bubble"
        case .spotlight: "scope"
        case .redact: "eye.slash.fill"
        case .magnifier: "magnifyingglass.circle"
        case .watermark: "seal"
        case .ocr: "text.viewfinder"
        }
    }
}

private extension ScreenshotEditorTool {

    var supportsColor: Bool { ![.select, .blur, .pixelate, .spotlight, .magnifier].contains(self) }
    var supportsLineWidth: Bool {
        [.arrow, .line, .rectangle, .ellipse, .freehand, .highlight, .counter, .step, .callout, .redact, .magnifier].contains(self)
    }
}

private extension ScreenshotElementAppearance {
    var calloutAppearance: ScreenshotCalloutAppearance {
        get { if case let .callout(value) = payload { value } else { .init() } }
        set { payload = .callout(newValue) }
    }

    var calloutTargetStrokeColor: ScreenshotColor {
        get { calloutAppearance.target.strokeColor }
        set { var value = calloutAppearance; value.target.strokeColor = newValue; calloutAppearance = value }
    }

    var calloutTargetStrokeWidth: Double {
        get { calloutAppearance.target.strokeWidth }
        set { var value = calloutAppearance; value.target.strokeWidth = newValue; calloutAppearance = value }
    }

    var calloutTargetHasFill: Bool { calloutAppearance.target.fillColor != nil }

    var calloutTargetFillColor: ScreenshotColor {
        get { calloutAppearance.target.fillColor ?? calloutAppearance.target.strokeColor }
        set { var value = calloutAppearance; value.target.fillColor = newValue; calloutAppearance = value }
    }

    var calloutTargetFillOpacity: Double {
        get { calloutAppearance.target.fillOpacity }
        set { var value = calloutAppearance; value.target.fillOpacity = newValue; calloutAppearance = value }
    }

    var calloutTargetOpacity: Double {
        get { calloutAppearance.target.opacity }
        set { var value = calloutAppearance; value.target.opacity = newValue; calloutAppearance = value }
    }

    var calloutConnectorColor: ScreenshotColor {
        get { calloutAppearance.connector.color }
        set { var value = calloutAppearance; value.connector.color = newValue; calloutAppearance = value }
    }

    var calloutConnectorWidth: Double {
        get { calloutAppearance.connector.width }
        set { var value = calloutAppearance; value.connector.width = newValue; calloutAppearance = value }
    }

    var calloutConnectorPattern: ScreenshotLinePattern {
        get { calloutAppearance.connector.pattern }
        set { var value = calloutAppearance; value.connector.pattern = newValue; calloutAppearance = value }
    }

    var calloutConnectorStartEnding: ScreenshotLineEnding {
        get { calloutAppearance.connector.startEnding }
        set { var value = calloutAppearance; value.connector.startEnding = newValue; calloutAppearance = value }
    }

    var calloutConnectorEndEnding: ScreenshotLineEnding {
        get { calloutAppearance.connector.endEnding }
        set { var value = calloutAppearance; value.connector.endEnding = newValue; calloutAppearance = value }
    }

    var calloutConnectorArrowHeadSize: Double {
        get { calloutAppearance.connector.arrowHeadSize }
        set { var value = calloutAppearance; value.connector.arrowHeadSize = newValue; calloutAppearance = value }
    }

    var calloutConnectorOpacity: Double {
        get { calloutAppearance.connector.opacity }
        set { var value = calloutAppearance; value.connector.opacity = newValue; calloutAppearance = value }
    }

    var calloutNoteTextColor: ScreenshotColor {
        get { calloutAppearance.note.color }
        set { var value = calloutAppearance; value.note.color = newValue; calloutAppearance = value }
    }

    var calloutNoteFontSize: Double {
        get { calloutAppearance.note.fontSize }
        set { var value = calloutAppearance; value.note.fontSize = newValue; calloutAppearance = value }
    }

    var calloutNoteWeight: ScreenshotTextWeight {
        get { calloutAppearance.note.weight }
        set { var value = calloutAppearance; value.note.weight = newValue; calloutAppearance = value }
    }

    var calloutNoteAlignment: ScreenshotTextAlignment {
        get { calloutAppearance.note.alignment }
        set { var value = calloutAppearance; value.note.alignment = newValue; calloutAppearance = value }
    }

    var calloutNoteHasBackground: Bool { calloutAppearance.note.backgroundColor != nil }

    var calloutNoteBackgroundColor: ScreenshotColor {
        get { calloutAppearance.note.backgroundColor ?? .init(red: 0, green: 0, blue: 0, alpha: 0) }
        set { var value = calloutAppearance; value.note.backgroundColor = newValue; calloutAppearance = value }
    }

    var calloutNotePadding: Double {
        get { calloutAppearance.note.backgroundPadding }
        set { var value = calloutAppearance; value.note.backgroundPadding = newValue; calloutAppearance = value }
    }

    var calloutNoteLineSpacing: Double {
        get { calloutAppearance.note.lineSpacing }
        set { var value = calloutAppearance; value.note.lineSpacing = newValue; calloutAppearance = value }
    }

    var calloutNoteOpacity: Double {
        get { calloutAppearance.note.opacity }
        set { var value = calloutAppearance; value.note.opacity = newValue; calloutAppearance = value }
    }

    var stepBadgeShape: ScreenshotCounterShape {
        get { stepAppearance.badge.shape }
        set { var value = stepAppearance; value.badge.shape = newValue; stepAppearance = value }
    }

    var stepBadgeSize: Double {
        get { stepAppearance.badgeSize }
        set { var value = stepAppearance; value.badgeSize = newValue; stepAppearance = value }
    }

    var stepBadgeFillColor: ScreenshotColor {
        get { stepAppearance.badgeFillColor }
        set { var value = stepAppearance; value.badgeFillColor = newValue; stepAppearance = value }
    }

    var stepBadgeTextColor: ScreenshotColor {
        get { stepAppearance.badgeTextColor }
        set { var value = stepAppearance; value.badgeTextColor = newValue; stepAppearance = value }
    }

    var stepBadgeBorderColor: ScreenshotColor {
        get { stepAppearance.badgeBorderColor }
        set { var value = stepAppearance; value.badgeBorderColor = newValue; stepAppearance = value }
    }

    var stepBadgeBorderWidth: Double {
        get { stepAppearance.badge.borderWidth }
        set { var value = stepAppearance; value.badge.borderWidth = newValue; stepAppearance = value }
    }

    var stepBadgeOpacity: Double {
        get { stepAppearance.badge.opacity }
        set { var value = stepAppearance; value.badge.opacity = newValue; stepAppearance = value }
    }

    var stepConnectorColor: ScreenshotColor {
        get { stepAppearance.connector.color }
        set { var value = stepAppearance; value.connector.color = newValue; stepAppearance = value }
    }

    var stepConnectorWidth: Double {
        get { stepAppearance.connector.width }
        set { var value = stepAppearance; value.connector.width = newValue; stepAppearance = value }
    }

    var stepConnectorPattern: ScreenshotLinePattern {
        get { stepAppearance.connector.pattern }
        set { var value = stepAppearance; value.connector.pattern = newValue; stepAppearance = value }
    }

    var stepConnectorStartEnding: ScreenshotLineEnding {
        get { stepAppearance.connector.startEnding }
        set { var value = stepAppearance; value.connector.startEnding = newValue; stepAppearance = value }
    }

    var stepConnectorEndEnding: ScreenshotLineEnding {
        get { stepAppearance.connector.endEnding }
        set { var value = stepAppearance; value.connector.endEnding = newValue; stepAppearance = value }
    }

    var stepConnectorArrowHeadSize: Double {
        get { stepAppearance.connector.arrowHeadSize }
        set { var value = stepAppearance; value.connector.arrowHeadSize = newValue; stepAppearance = value }
    }

    var stepConnectorOpacity: Double {
        get { stepAppearance.connector.opacity }
        set { var value = stepAppearance; value.connector.opacity = newValue; stepAppearance = value }
    }

    var stepNoteBackgroundColor: ScreenshotColor {
        get { stepAppearance.noteBackgroundColor }
        set { var value = stepAppearance; value.noteBackgroundColor = newValue; stepAppearance = value }
    }

    var stepNoteHasBackground: Bool {
        stepAppearance.note.backgroundColor != nil
    }

    var stepNoteTextColor: ScreenshotColor {
        get { stepAppearance.noteTextColor }
        set { var value = stepAppearance; value.noteTextColor = newValue; stepAppearance = value }
    }

    var stepNoteFontSize: Double {
        get { stepAppearance.noteFontSize }
        set { var value = stepAppearance; value.noteFontSize = newValue; stepAppearance = value }
    }


    var stepNoteWeight: ScreenshotTextWeight {
        get { stepAppearance.note.weight }
        set { var value = stepAppearance; value.note.weight = newValue; stepAppearance = value }
    }

    var stepNoteAlignment: ScreenshotTextAlignment {
        get { stepAppearance.note.alignment }
        set { var value = stepAppearance; value.note.alignment = newValue; stepAppearance = value }
    }

    var stepNotePadding: Double {
        get { stepAppearance.note.backgroundPadding }
        set { var value = stepAppearance; value.note.backgroundPadding = newValue; stepAppearance = value }
    }

    var stepNoteLineSpacing: Double {
        get { stepAppearance.note.lineSpacing }
        set { var value = stepAppearance; value.note.lineSpacing = newValue; stepAppearance = value }
    }

    var stepNoteOpacity: Double {
        get { stepAppearance.note.opacity }
        set { var value = stepAppearance; value.note.opacity = newValue; stepAppearance = value }
    }
}

private extension ScreenshotLineEnding {
    var localizedTitle: String { L10n.string("screenshot.editor.lineEnding.\(rawValue)") }
}

private extension ScreenshotTextWeight {
    var localizedTitle: String { L10n.string("screenshot.editor.textWeight.\(rawValue)") }
}

private extension ScreenshotTextAlignment {
    var localizedTitle: String { L10n.string("screenshot.editor.textAlignment.\(rawValue)") }
}
