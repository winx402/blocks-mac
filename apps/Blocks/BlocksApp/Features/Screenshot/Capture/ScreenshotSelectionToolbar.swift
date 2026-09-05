import AppKit
import BlocksScreenshotCore
import SwiftUI

enum ScreenshotSelectionToolbarAction {
    case constraint(ScreenshotRegionConstraint)
    case delay(Double)
    case freeze(Bool)
    case watermark(UUID?)
    case scrollingMode(Bool)
    case scrollingStart
    case scrollingReselect
    case scrollingCancel
}

enum ScreenshotSelectionToolbarPresentation {
    case runtime
    case settingsCompact

    var controlHeight: CGFloat { BlocksVisualTokens.Control.compactHeight }
    var dragHandleSize: CGFloat { BlocksVisualTokens.Control.standardHeight }
    var dragHandleVisualSize: CGFloat { controlHeight }
    var outerPadding: CGFloat {
        self == .runtime ? BlocksVisualTokens.Spacing.sm : BlocksVisualTokens.Spacing.xxs
    }
    var groupSpacing: CGFloat { BlocksVisualTokens.Spacing.sm }
    var parameterControlSpacing: CGFloat { ScreenshotConstraintToolbarMetrics.parameterControlSpacing }
}

enum ScreenshotSelectionToolbarPhase: Equatable {
    case normal
    case scrollingSelecting
}

enum ScreenshotScrollingCommand: CaseIterable, Hashable {
    case start
    case reselect
    case restart
    case pause
    case resume
    case finish
    case cancel

    var systemImage: String {
        switch self {
        case .start, .resume:
            "play.fill"
        case .reselect, .restart:
            "arrow.counterclockwise"
        case .pause:
            "pause.fill"
        case .finish:
            "checkmark"
        case .cancel:
            "xmark"
        }
    }

    var localizationKey: String {
        switch self {
        case .start:
            "screenshot.scrolling.start"
        case .reselect:
            "screenshot.scrolling.reselect"
        case .restart:
            "screenshot.scrolling.restart"
        case .pause:
            "screenshot.scrolling.pause"
        case .resume:
            "screenshot.scrolling.resume"
        case .finish:
            "screenshot.scrolling.finish"
        case .cancel:
            "common.cancel"
        }
    }

    var label: String { L10n.string(localizationKey) }

    var emphasis: BlocksCompactIconButtonEmphasis {
        switch self {
        case .start, .resume, .finish:
            .accent
        case .reselect, .restart, .pause:
            .standard
        case .cancel:
            .destructive
        }
    }
}

enum ScreenshotSelectionToolbarPlacement {
    private static let edgeInset = BlocksVisualTokens.Spacing.md
    private static let keyboardMoveStep = BlocksVisualTokens.Spacing.md

    static func initialFrame(
        toolbarSize: CGSize,
        pointer: CGPoint,
        visibleFrames: [CGRect]
    ) -> CGRect {
        let target = visibleFrames.first(where: { $0.contains(pointer) }) ?? visibleFrames.first ?? .zero
        let proposed = CGRect(
            x: target.midX - toolbarSize.width / 2,
            y: target.maxY - edgeInset - toolbarSize.height,
            width: toolbarSize.width,
            height: toolbarSize.height
        )
        guard !visibleFrames.isEmpty else { return proposed }
        // The pointer selects the initial display. An oversized toolbar can
        // intersect a neighbouring display before it is fitted, so passing the
        // whole display list here would make array order override that choice.
        return clampedFrame(proposed, visibleFrames: [target])
    }

    static func clampedFrame(_ proposed: CGRect, visibleFrames: [CGRect]) -> CGRect {
        guard !visibleFrames.isEmpty else { return proposed }
        let target = visibleFrames.first(where: { $0.intersects(proposed) })
            ?? visibleFrames.min(by: { distance($0, to: proposed) < distance($1, to: proposed) })!
        let size = CGSize(
            width: min(proposed.width, target.width),
            height: min(proposed.height, target.height)
        )
        let x = min(max(proposed.minX, target.minX), target.maxX - size.width)
        let y = min(max(proposed.minY, target.minY), target.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func keyboardMoveDelta(for keyCode: UInt16) -> CGSize? {
        switch keyCode {
        case 123: CGSize(width: -keyboardMoveStep, height: 0)
        case 124: CGSize(width: keyboardMoveStep, height: 0)
        case 125: CGSize(width: 0, height: -keyboardMoveStep)
        case 126: CGSize(width: 0, height: keyboardMoveStep)
        default: nil
        }
    }

    private static func distance(_ frame: CGRect, to proposed: CGRect) -> CGFloat {
        hypot(frame.midX - proposed.midX, frame.midY - proposed.midY)
    }
}

final class ScreenshotSelectionToolbarPanel: ScreenshotSelectionPanel {
    private let visibleFrames: [CGRect]
    private let toolbarView: ScreenshotSelectionToolbarView
    private let toolbarViewport = NSScrollView()

    init(
        parameters: ScreenshotSelectionParameters,
        customConstraints: [ScreenshotCustomConstraintPreset] = [],
        watermarkPresets: [ScreenshotWatermarkPreset] = [],
        visibleFrames: [CGRect],
        pointer: CGPoint,
        onSaveConstraint: @escaping (ScreenshotCustomConstraintPreset) -> Void = { _ in },
        onDeleteConstraint: @escaping (UUID) -> Void = { _ in },
        onAction: @escaping (ScreenshotSelectionToolbarAction) -> Void
    ) {
        self.visibleFrames = visibleFrames
        toolbarView = ScreenshotSelectionToolbarView(
            parameters: parameters,
            customConstraints: customConstraints,
            watermarkPresets: watermarkPresets,
            allowsDragging: true,
            onSaveConstraint: onSaveConstraint,
            onDeleteConstraint: onDeleteConstraint,
            onAction: onAction
        )
        let frame = ScreenshotSelectionToolbarPlacement.initialFrame(
            toolbarSize: toolbarView.intrinsicContentSize,
            pointer: pointer,
            visibleFrames: visibleFrames
        )
        super.init(contentRect: frame)
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        configureToolbarViewport()
        contentView = toolbarViewport
        updateViewport()
        toolbarView.onDrag = { [weak self] delta in self?.move(by: delta) }
        toolbarView.onMove = { [weak self] delta in self?.move(by: delta) }
    }

    required init?(coder: NSCoder) { nil }

    func update(parameters: ScreenshotSelectionParameters) {
        let oldMidX = frame.midX
        toolbarView.update(parameters: parameters)
        resizeToFit(keepingMidX: oldMidX)
    }

    func setRegionGestureActive(_ active: Bool) {
        alphaValue = active ? 0.28 : 1
        ignoresMouseEvents = active
    }

    func update(phase: ScreenshotSelectionToolbarPhase) {
        let oldMidX = frame.midX
        toolbarView.update(phase: phase)
        resizeToFit(keepingMidX: oldMidX)
        isMovableByWindowBackground = false
    }

    private func resizeToFit(keepingMidX oldMidX: CGFloat) {
        var nextFrame = frame
        nextFrame.size = toolbarView.intrinsicContentSize
        nextFrame.origin.x = oldMidX - nextFrame.width / 2
        setFrame(ScreenshotSelectionToolbarPlacement.clampedFrame(nextFrame, visibleFrames: visibleFrames), display: true)
        updateViewport()
    }

    private func move(by delta: CGSize) {
        let proposed = frame.offsetBy(dx: delta.width, dy: delta.height)
        setFrame(ScreenshotSelectionToolbarPlacement.clampedFrame(proposed, visibleFrames: visibleFrames), display: true)
        updateViewport()
    }

    private func configureToolbarViewport() {
        toolbarViewport.borderType = .noBorder
        toolbarViewport.drawsBackground = false
        toolbarViewport.autohidesScrollers = true
        toolbarViewport.scrollerStyle = .overlay
        toolbarViewport.hasVerticalScroller = false
        toolbarViewport.documentView = toolbarView
    }

    private func updateViewport() {
        let contentSize = toolbarView.intrinsicContentSize
        toolbarView.frame = CGRect(origin: .zero, size: contentSize)
        toolbarViewport.hasHorizontalScroller = contentSize.width > frame.width
    }
}

final class ScreenshotSelectionToolbarView: BlocksAppKitGlassSurfaceView, NSPopoverDelegate {
    static let preferredSize = preferredSize(showsScrollingMode: true)

    static func preferredSize(
        showsScrollingMode: Bool,
        presentation: ScreenshotSelectionToolbarPresentation = .runtime
    ) -> CGSize {
        var contentWidth = ScreenshotConstraintToolbarMetrics.parameterIslandWidth(
            showsScrollingMode: showsScrollingMode
        )
        if presentation == .runtime {
            contentWidth += presentation.dragHandleSize
                + ScreenshotConstraintToolbarMetrics.islandHorizontalPadding
                + presentation.groupSpacing
        }
        return CGSize(
            width: contentWidth + presentation.outerPadding * 2,
            height: presentation == .settingsCompact ? 32 : ScreenshotDesignTokens.toolbarMainHeight
        )
    }

    var onDrag: ((CGSize) -> Void)?
    var onMove: ((CGSize) -> Void)?
    let allowsDragging: Bool
    private let showsScrollingMode: Bool
    private let presentation: ScreenshotSelectionToolbarPresentation
    private let onAction: (ScreenshotSelectionToolbarAction) -> Void
    private let onSaveConstraint: (ScreenshotCustomConstraintPreset) -> Void
    private let onDeleteConstraint: (UUID) -> Void
    private let constraintButton = ScreenshotParameterValueButton()
    private let delayButton = ScreenshotParameterValueButton()
    private let freezeButton = ScreenshotFreezeValueButton()
    private let watermarkButton = ScreenshotParameterValueButton()
    private let scrollingButton = BlocksAppKitCompactButton()
    private let dragHandle = ScreenshotSelectionToolbarDragHandle()
    private weak var dragIsland: NSStackView?
    private var aspectRatioPopover: NSPopover?
    private var parameters: ScreenshotSelectionParameters
    private var customConstraints: [ScreenshotCustomConstraintPreset]
    private var watermarkPresets: [ScreenshotWatermarkPreset]
    private let immediateTooltipHost = BlocksImmediateTooltipHostModel()
    private var phase: ScreenshotSelectionToolbarPhase = .normal
    private let controlsStack = NSStackView()
    private var islandViews: [NSView] = []
    private var parameterKeyLabels: [NSTextField] = []
    var interactiveControls: [NSControl] {
        [constraintButton, delayButton, freezeButton, watermarkButton]
            + (showsScrollingMode ? [scrollingButton] : [])
    }

    var dragHandleAccessibilityValue: String {
        dragHandle.accessibilityValue() as? String ?? ""
    }

    var isScrollingModeVisible: Bool { !scrollingButton.isHidden }
    var activeAspectRatioPopover: NSPopover? { aspectRatioPopover }

    init(
        parameters: ScreenshotSelectionParameters,
        customConstraints: [ScreenshotCustomConstraintPreset] = [],
        watermarkPresets: [ScreenshotWatermarkPreset] = [],
        allowsDragging: Bool,
        showsScrollingMode: Bool = true,
        presentation: ScreenshotSelectionToolbarPresentation = .runtime,
        onSaveConstraint: @escaping (ScreenshotCustomConstraintPreset) -> Void = { _ in },
        onDeleteConstraint: @escaping (UUID) -> Void = { _ in },
        onAction: @escaping (ScreenshotSelectionToolbarAction) -> Void
    ) {
        self.parameters = parameters
        self.customConstraints = customConstraints
        self.watermarkPresets = watermarkPresets
        self.allowsDragging = allowsDragging
        self.showsScrollingMode = showsScrollingMode
        self.presentation = presentation
        self.onSaveConstraint = onSaveConstraint
        self.onDeleteConstraint = onDeleteConstraint
        self.onAction = onAction
        super.init(frame: CGRect(
            origin: .zero,
            size: Self.preferredSize(showsScrollingMode: showsScrollingMode, presentation: presentation)
        ))
        blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: .panel,
            cornerRadius: presentation == .runtime
                ? BlocksVisualTokens.CornerRadius.section
                : BlocksVisualTokens.CornerRadius.control,
            drawsShadow: false
        )
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(L10n.string("screenshot.selection.accessibility.toolbar"))
        buildControls()
        updateChromeAppearance()
        update(parameters: parameters)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChromeAppearance()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hideImmediateTooltip()
            dismissAspectRatioPopover(restoresFocus: false)
        }
        immediateTooltipHost.ownerWindow = newWindow
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        guard let info = event.trackingArea?.userInfo,
              let label = info["label"] as? String,
              let anchorValue = info["anchor"] as? NSValue,
              let anchor = anchorValue.nonretainedObjectValue as? NSView else { return }
        let value: String?
        if anchor === constraintButton {
            value = constraintButton.displayTitle
        } else if anchor === delayButton {
            value = delayButton.displayTitle
        } else if anchor === freezeButton {
            value = L10n.string(
                freezeButton.isOn
                    ? "screenshot.selection.accessibility.selected"
                    : "screenshot.selection.accessibility.unselected"
            )
        } else if anchor === watermarkButton {
            value = watermarkButton.displayTitle
        } else {
            value = nil
        }
        let resolvedLabel = value.map {
            "\(L10n.format("screenshot.selection.parameter.labelFormat", label)) \($0)"
        } ?? label
        showImmediateTooltip(label: resolvedLabel, anchor: anchor)
    }

    override func mouseExited(with event: NSEvent) {
        hideImmediateTooltip()
    }

    func update(parameters: ScreenshotSelectionParameters) {
        self.parameters = parameters
        let constraintTitle = Self.ratioTitle(parameters.constraint)
        constraintButton.displayTitle = constraintTitle
        constraintButton.setAccessibilityValue(constraintTitle)
        delayButton.displayTitle = Self.delayTitle(for: parameters.delaySeconds)
        delayButton.setAccessibilityValue(delayButton.displayTitle)
        rebuildWatermarkMenu()
        updateFreezeButton(active: parameters.freezesFrame)
        controlsStack.needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func update(customConstraints: [ScreenshotCustomConstraintPreset]) {
        self.customConstraints = customConstraints
    }

    func update(watermarkPresets: [ScreenshotWatermarkPreset]) {
        self.watermarkPresets = watermarkPresets
        rebuildWatermarkMenu()
        controlsStack.needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard !controlsStack.arrangedSubviews.isEmpty else {
            return Self.preferredSize(showsScrollingMode: showsScrollingMode, presentation: presentation)
        }
        let fitting = controlsStack.fittingSize
        return NSSize(
            width: ceil(max(1, fitting.width)),
            height: Self.preferredSize(
                showsScrollingMode: showsScrollingMode,
                presentation: presentation
            ).height
        )
    }

    func update(phase: ScreenshotSelectionToolbarPhase) {
        self.phase = phase
        [dragHandle, constraintButton, delayButton, freezeButton, watermarkButton]
            .forEach { $0.isHidden = false }
        dragHandle.isHidden = presentation == .settingsCompact
        scrollingButton.isHidden = !showsScrollingMode
        controlsStack.edgeInsets = NSEdgeInsets(
            top: presentation.outerPadding,
            left: presentation.outerPadding,
            bottom: presentation.outerPadding,
            right: presentation.outerPadding
        )
        updateToggle(scrollingButton, active: phase != .normal)
        updateFocusLoop()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func buildControls() {
        dragHandle.isDraggingEnabled = allowsDragging
        dragHandle.onDrag = { [weak self] delta in self?.onDrag?(delta) }
        dragHandle.onMove = { [weak self] delta in self?.onMove?(delta) }
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(equalToConstant: presentation.dragHandleSize),
            dragHandle.heightAnchor.constraint(equalToConstant: presentation.dragHandleSize),
        ])

        constraintButton.controlSize = .small
        constraintButton.target = self
        constraintButton.action = #selector(constraintChanged)
        constraintButton.isBordered = false
        constraintButton.setAccessibilityLabel(L10n.string("screenshot.selection.constraint"))
        constraintButton.wantsLayer = true
        constraintButton.layer?.cornerRadius = BlocksVisualTokens.CornerRadius.control
        constraintButton.widthAnchor.constraint(
            equalToConstant: ScreenshotConstraintToolbarMetrics.valueWidth
        ).isActive = true
        constraintButton.heightAnchor.constraint(equalToConstant: presentation.controlHeight).isActive = true
        constraintButton.setContentHuggingPriority(.required, for: .horizontal)
        constraintButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        delayButton.controlSize = .small
        delayButton.target = self
        delayButton.action = #selector(showDelayMenu)
        delayButton.isBordered = false
        delayButton.setAccessibilityRole(.popUpButton)
        delayButton.setAccessibilityLabel(L10n.string("screenshot.selection.delay"))
        delayButton.widthAnchor.constraint(
            equalToConstant: ScreenshotConstraintToolbarMetrics.valueWidth
        ).isActive = true
        delayButton.heightAnchor.constraint(equalToConstant: presentation.controlHeight).isActive = true
        delayButton.setContentHuggingPriority(.required, for: .horizontal)
        delayButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureFreezeButton()
        watermarkButton.controlSize = .small
        watermarkButton.target = self
        watermarkButton.action = #selector(showWatermarkMenu)
        watermarkButton.isBordered = false
        watermarkButton.setAccessibilityRole(.popUpButton)
        watermarkButton.setAccessibilityLabel(L10n.string("screenshot.selection.watermark"))
        watermarkButton.widthAnchor.constraint(
            equalToConstant: ScreenshotConstraintToolbarMetrics.valueWidth
        ).isActive = true
        watermarkButton.heightAnchor.constraint(equalToConstant: presentation.controlHeight).isActive = true
        watermarkButton.setContentHuggingPriority(.required, for: .horizontal)
        watermarkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        configureToggle(scrollingButton, symbol: "rectangle.stack", tooltipKey: "screenshot.scrolling.mode", action: #selector(scrollingChanged))
        scrollingButton.isHidden = !showsScrollingMode

        installImmediateTooltip(
            on: dragHandle,
            label: L10n.string("screenshot.editor.moveToolbar")
        )
        installImmediateTooltip(
            on: constraintButton,
            label: L10n.string("screenshot.selection.constraint")
        )
        installImmediateTooltip(on: delayButton, label: L10n.string("screenshot.selection.delay"))
        installImmediateTooltip(on: freezeButton, label: L10n.string("screenshot.selection.freeze"))
        installImmediateTooltip(on: watermarkButton, label: L10n.string("screenshot.selection.watermark"))
        if showsScrollingMode {
            installImmediateTooltip(on: scrollingButton, label: L10n.string("screenshot.scrolling.mode"))
        }

        let dragIsland = makeIsland([dragHandle])
        self.dragIsland = dragIsland
        let parameterControls: [NSView] = [
            makeLabeledParameterControl(
                labelKey: "screenshot.selection.constraint",
                control: constraintButton
            ),
            makeLabeledParameterControl(
                labelKey: "screenshot.selection.delay",
                control: delayButton
            ),
            makeLabeledParameterControl(
                labelKey: "screenshot.selection.freeze",
                control: freezeButton
            ),
            makeLabeledParameterControl(
                labelKey: "screenshot.selection.watermark",
                control: watermarkButton
            ),
        ]
        let parameterIsland = makeIsland(
            parameterControls,
            spacing: presentation.parameterControlSpacing
        )
        if presentation == .runtime { controlsStack.addArrangedSubview(dragIsland) }
        controlsStack.addArrangedSubview(parameterIsland)
        if showsScrollingMode {
            controlsStack.addArrangedSubview(makeIsland([scrollingButton]))
        }
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = presentation.groupSpacing
        let inset = presentation.outerPadding
        controlsStack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        addBlocksContentSubview(controlsStack)
        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: blocksContentView.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: blocksContentView.trailingAnchor),
            controlsStack.topAnchor.constraint(equalTo: blocksContentView.topAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: blocksContentView.bottomAnchor),
        ])
        updateFocusLoop()
    }

    private func makeIsland(_ views: [NSView], spacing: CGFloat = 0) -> NSStackView {
        let island = NSStackView(views: views)
        island.orientation = .horizontal
        island.alignment = .centerY
        island.spacing = spacing
        island.edgeInsets = NSEdgeInsets(
            top: 2,
            left: ScreenshotConstraintToolbarMetrics.islandHorizontalInset,
            bottom: 2,
            right: ScreenshotConstraintToolbarMetrics.islandHorizontalInset
        )
        island.wantsLayer = true
        island.layer?.cornerRadius = BlocksVisualTokens.CornerRadius.control
        islandViews.append(island)
        return island
    }

    private func makeLabeledParameterControl(
        labelKey: String,
        control: NSView
    ) -> NSStackView {
        let label = ScreenshotParameterKeyLabel(
            string: Self.parameterLabel(labelKey)
        )
        label.font = BlocksTypography.nsFont(size: 11, weight: .semibold)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = BlocksVisualTokens.CornerRadius.small
        label.layer?.cornerCurve = .continuous
        label.widthAnchor.constraint(equalToConstant: ScreenshotConstraintToolbarMetrics.keyWidth).isActive = true
        label.heightAnchor.constraint(equalToConstant: ScreenshotConstraintToolbarMetrics.keyHeight).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        parameterKeyLabels.append(label)

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = ScreenshotConstraintToolbarMetrics.contentSpacing
        stack.setAccessibilityElement(false)
        stack.widthAnchor.constraint(equalToConstant: ScreenshotConstraintToolbarMetrics.unitWidth).isActive = true
        return stack
    }

    private func updateChromeAppearance() {
        updateBlocksSurface()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            islandViews.forEach(updateIslandAppearance)
            parameterKeyLabels.forEach(updateParameterKeyAppearance)
        }
    }

    private func updateIslandAppearance(_ island: NSView) {
        island.layer?.backgroundColor = island === dragIsland
            ? NSColor.clear.cgColor
            : NSColor.labelColor.withAlphaComponent(0.055).cgColor
    }

    private func updateParameterKeyAppearance(_ label: NSTextField) {
        label.textColor = NSColor.controlAccentColor.blended(
            withFraction: 0.18,
            of: .labelColor
        ) ?? .labelColor
        label.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.13)
            .cgColor
    }

    private func configureToggle(_ button: BlocksAppKitCompactButton, symbol: String, tooltipKey: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.string(tooltipKey))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.setAccessibilityLabel(L10n.string(tooltipKey))
        button.setButtonType(.toggle)
        button.isBordered = false
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = BlocksVisualTokens.CornerRadius.control
        button.widthAnchor.constraint(equalToConstant: presentation.controlHeight).isActive = true
        button.heightAnchor.constraint(equalToConstant: presentation.controlHeight).isActive = true
    }

    private func configureFreezeButton() {
        freezeButton.target = self
        freezeButton.action = #selector(freezeChanged)
        freezeButton.setAccessibilityLabel(L10n.string("screenshot.selection.freeze"))
        freezeButton.widthAnchor.constraint(
            equalToConstant: ScreenshotConstraintToolbarMetrics.valueWidth
        ).isActive = true
        freezeButton.heightAnchor.constraint(equalToConstant: presentation.controlHeight).isActive = true
        freezeButton.setContentHuggingPriority(.required, for: .horizontal)
        freezeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateToggle(_ button: BlocksAppKitCompactButton, active: Bool) {
        button.state = active ? .on : .off
        button.setAccessibilityValue(L10n.string(
            active ? "screenshot.selection.accessibility.selected" : "screenshot.selection.accessibility.unselected"
        ))
        button.setAccessibilitySelected(active)
        button.setBlocksSelected(active)
    }

    private func updateFreezeButton(active: Bool) {
        freezeButton.isOn = active
        freezeButton.setAccessibilityValue(NSNumber(value: active))
    }

    private func updateFocusLoop() {
        let controls = interactiveControls.filter { !$0.isHidden && $0.isEnabled }
        guard let first = controls.first else { return }
        for (control, next) in zip(controls, controls.dropFirst()) {
            control.nextKeyView = next
        }
        controls.last?.nextKeyView = first
    }

    private func installImmediateTooltip(on view: NSView, label: String) {
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: ["label": label, "anchor": NSValue(nonretainedObject: view)]
        ))
    }

    private func showImmediateTooltip(label: String, anchor: NSView) {
        immediateTooltipHost.show(label: label, anchor: anchor)
    }

    private func hideImmediateTooltip() {
        immediateTooltipHost.hide()
    }

    @objc private func constraintChanged() {
        showAspectRatioPopover()
    }

    @objc private func showDelayMenu() {
        let menu = NSMenu()
        for (index, value) in Self.delays.enumerated() {
            let item = NSMenuItem(
                title: Self.delayTitles[index],
                action: #selector(selectDelayFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = value == parameters.delaySeconds ? .on : .off
            menu.addItem(item)
        }
        presentParameterMenu(menu, from: delayButton)
    }

    @objc private func selectDelayFromMenu(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        onAction(.delay(value))
    }

    @objc private func freezeChanged() {
        let active = !freezeButton.isOn
        updateFreezeButton(active: active)
        onAction(.freeze(active))
    }

    @objc private func showWatermarkMenu() {
        let menu = NSMenu()
        let none = NSMenuItem(
            title: L10n.string("screenshot.watermark.none"),
            action: #selector(selectWatermarkFromMenu(_:)),
            keyEquivalent: ""
        )
        none.target = self
        none.state = parameters.watermarkPresetID == nil ? .on : .off
        menu.addItem(none)
        for preset in watermarkPresets {
            let item = NSMenuItem(
                title: preset.name,
                action: #selector(selectWatermarkFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.id.uuidString
            item.state = preset.id == parameters.watermarkPresetID ? .on : .off
            menu.addItem(item)
        }
        presentParameterMenu(menu, from: watermarkButton)
    }

    @objc private func selectWatermarkFromMenu(_ sender: NSMenuItem) {
        let presetID = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        onAction(.watermark(presetID))
    }
    @objc private func scrollingChanged() { onAction(.scrollingMode(scrollingButton.state == .on)) }

    private func rebuildWatermarkMenu() {
        let title = parameters.watermarkPresetID
            .flatMap { id in watermarkPresets.first(where: { $0.id == id })?.name }
            ?? L10n.string("screenshot.watermark.none")
        watermarkButton.displayTitle = title
        watermarkButton.setAccessibilityValue(title)
    }

    private func presentParameterMenu(_ menu: NSMenu, from button: NSView) {
        hideImmediateTooltip()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 4),
            in: button
        )
    }

    private func showAspectRatioPopover() {
        dismissAspectRatioPopover(restoresFocus: false)
        let orientation: ScreenshotAspectOrientation = (parameters.constraint.aspectRatio ?? 1) >= 1
            ? .landscape
            : .portrait
        let controller = NSHostingController(rootView: ScreenshotAspectRatioCapturePopover(
            selection: .init(orientation: orientation, constraint: parameters.constraint),
            customConstraints: customConstraints,
            onSelect: { [weak self] selection in
                guard let self else { return }
                self.onAction(.constraint(selection.resolvedConstraint))
            },
            onSave: onSaveConstraint,
            onDelete: onDeleteConstraint
        ))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        aspectRatioPopover = popover
        popover.show(relativeTo: constraintButton.bounds, of: constraintButton, preferredEdge: .maxY)
    }

    private func dismissAspectRatioPopover(restoresFocus: Bool) {
        guard let popover = aspectRatioPopover else { return }
        aspectRatioPopover = nil
        popover.delegate = nil
        popover.close()
        guard restoresFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.constraintButton)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === aspectRatioPopover else { return }
        aspectRatioPopover = nil
        closedPopover.delegate = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.constraintButton)
        }
    }

    private static func ratioTitle(_ constraint: ScreenshotRegionConstraint) -> String {
        switch constraint {
        case let .ratio(width, height):
            return "\(formattedRatioValue(width)):\(formattedRatioValue(height))"
        case let .fixedPixels(width, height):
            return "\(width)×\(height)"
        case .free:
            return L10n.string("screenshot.selection.constraint.free")
        }
    }

    private static func formattedRatioValue(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    nonisolated fileprivate static func parameterLabel(_ key: String) -> String {
        L10n.format("screenshot.selection.parameter.labelFormat", L10n.string(key))
    }

    private static func delayTitle(for value: Double) -> String {
        guard let index = delays.firstIndex(of: value) else { return delayTitles[0] }
        return delayTitles[index]
    }

    private static let delays: [Double] = [0, 3, 5, 10]
    private static let delayTitles = ["0s", "3s", "5s", "10s"]
}

enum ScreenshotConstraintToolbarMetrics {
    static let horizontalInset: CGFloat = 6
    static let contentSpacing: CGFloat = 4
    static let valueWidth: CGFloat = 96
    static let keyHeight: CGFloat = 28
    static let islandHorizontalInset: CGFloat = 6
    static let islandHorizontalPadding: CGFloat = islandHorizontalInset * 2
    static let parameterControlSpacing: CGFloat = 12

    static var keyWidth: CGFloat {
        let font = BlocksTypography.nsFont(size: 11, weight: .semibold)
        let textWidth = ceil([
            "screenshot.selection.constraint",
            "screenshot.selection.delay",
            "screenshot.selection.freeze",
            "screenshot.selection.watermark",
        ].map {
            (ScreenshotSelectionToolbarView.parameterLabel($0) as NSString)
                .size(withAttributes: [.font: font]).width
        }.max() ?? 0)
        return max(44, textWidth + 12)
    }

    static var unitWidth: CGFloat { keyWidth + contentSpacing + valueWidth }

    static func parameterIslandWidth(showsScrollingMode: Bool) -> CGFloat {
        return 4 * unitWidth
            + 3 * parameterControlSpacing
            + islandHorizontalPadding
            + (showsScrollingMode
                ? ScreenshotSelectionToolbarPresentation.runtime.controlHeight
                    + islandHorizontalPadding
                    + ScreenshotSelectionToolbarPresentation.runtime.groupSpacing
                : 0)
    }

}

private final class ScreenshotParameterKeyLabel: NSTextField {
    init(string: String) {
        super.init(frame: .zero)
        cell = ScreenshotVerticallyCenteredTextFieldCell(textCell: string)
        stringValue = string
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ScreenshotConstraintToolbarMetrics.keyWidth,
            height: ScreenshotConstraintToolbarMetrics.keyHeight
        )
    }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

private final class ScreenshotVerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        drawingRect.origin.y = floor(rect.midY - textHeight / 2)
        drawingRect.size.height = ceil(textHeight)
        return drawingRect
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class ScreenshotParameterValueButton: BlocksAppKitCompactButton {
    private let contentStack = NSStackView()
    private let valueLabel = NSTextField(labelWithString: "")

    var displayTitle: String {
        get { valueLabel.stringValue }
        set {
            valueLabel.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ScreenshotConstraintToolbarMetrics.valueWidth,
            height: 28
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = nil

        valueLabel.font = BlocksTypography.nsFont(size: 12, weight: .medium)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setAccessibilityElement(false)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 0
        contentStack.setAccessibilityElement(false)
        contentStack.addArrangedSubview(valueLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: ScreenshotConstraintToolbarMetrics.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -ScreenshotConstraintToolbarMetrics.horizontalInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor,
                constant: -(ScreenshotConstraintToolbarMetrics.horizontalInset * 2)
            ),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        valueLabel.textColor = .labelColor
    }
}

private final class ScreenshotFreezeValueButton: BlocksAppKitCompactButton {
    private let switchView = NSSwitch()

    var isOn: Bool {
        get { switchView.state == .on }
        set { switchView.state = newValue ? .on : .off }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ScreenshotConstraintToolbarMetrics.valueWidth, height: 28)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = nil
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilitySubrole(.switch)

        switchView.controlSize = .mini
        switchView.setAccessibilityElement(false)
        switchView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(switchView)
        NSLayoutConstraint.activate([
            switchView.centerXAnchor.constraint(equalTo: centerXAnchor),
            switchView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }
        return self
    }

}

private final class ScreenshotSelectionToolbarDragHandle: NSView {
    var onDrag: ((CGSize) -> Void)?
    var onMove: ((CGSize) -> Void)?
    var isDraggingEnabled = true {
        didSet {
            alphaValue = isDraggingEnabled ? 1 : 0.55
            setAccessibilityEnabled(isDraggingEnabled)
            setAccessibilityValue(L10n.string(
                isDraggingEnabled
                    ? "screenshot.selection.accessibility.ready"
                    : "screenshot.selection.accessibility.previewLocked"
            ))
        }
    }
    private var lastLocation: CGPoint?
    private var isDragging = false {
        didSet {
            setAccessibilitySelected(isDragging)
            setAccessibilityValue(L10n.string(
                isDragging
                    ? "screenshot.selection.accessibility.dragging"
                    : "screenshot.selection.accessibility.ready"
            ))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = L10n.string("screenshot.selection.dragHandle")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityValue(L10n.string("screenshot.selection.accessibility.ready"))
        setAccessibilitySelected(false)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard isDraggingEnabled else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isDraggingEnabled else { return }
        window?.makeFirstResponder(self)
        lastLocation = NSEvent.mouseLocation
        isDragging = true
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingEnabled else { return }
        let current = NSEvent.mouseLocation
        guard let lastLocation else { return }
        onDrag?(CGSize(width: current.x - lastLocation.x, height: current.y - lastLocation.y))
        self.lastLocation = current
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingEnabled else { return }
        lastLocation = nil
        isDragging = false
        NSCursor.openHand.set()
    }

    override func keyDown(with event: NSEvent) {
        guard isDraggingEnabled else {
            super.keyDown(with: event)
            return
        }
        guard let delta = ScreenshotSelectionToolbarPlacement.keyboardMoveDelta(for: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        onMove?(delta)
    }

    override func accessibilityPerformPress() -> Bool {
        isDraggingEnabled && performKeyboardMove(keyCode: 124)
    }

    override func accessibilityPerformIncrement() -> Bool {
        isDraggingEnabled && performKeyboardMove(keyCode: 126)
    }

    override func accessibilityPerformDecrement() -> Bool {
        isDraggingEnabled && performKeyboardMove(keyCode: 125)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let visualSize = min(
            ScreenshotSelectionToolbarPresentation.runtime.dragHandleVisualSize,
            min(bounds.width, bounds.height)
        )
        let visualRect = CGRect(
            x: bounds.midX - visualSize / 2,
            y: bounds.midY - visualSize / 2,
            width: visualSize,
            height: visualSize
        )
        let path = NSBezierPath()
        for x in [visualRect.midX - 3, visualRect.midX + 3] {
            path.move(to: CGPoint(x: x, y: visualRect.midY - 5))
            path.line(to: CGPoint(x: x, y: visualRect.midY + 5))
        }
        path.lineWidth = 1.5
        path.stroke()
    }

    private func performKeyboardMove(keyCode: UInt16) -> Bool {
        guard let delta = ScreenshotSelectionToolbarPlacement.keyboardMoveDelta(for: keyCode) else {
            return false
        }
        onMove?(delta)
        return true
    }
}
