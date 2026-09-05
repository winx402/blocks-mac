import AppKit
import BlocksScreenshotCore
import SwiftUI

enum ScreenshotCustomConstraintMode: String, CaseIterable {
    case ratio
    case fixedPixels
}

enum ScreenshotAspectRatioPanelMetrics {
    static let width: CGFloat = 420
    static let outerPadding: CGFloat = 12
    static let contentWidth = width - outerPadding * 2
    static let sectionSpacing: CGFloat = 8
    static let presetColumnCount = 3
    static let savedColumnCount = 3
    static let orientationGlyphSize = CGSize(width: 20, height: 20)
    static let customModeWidth: CGFloat = 96
    static let customFieldWidth: CGFloat = 54
    static let customControlHeight: CGFloat = 26
    static let customControlHitHeight: CGFloat = 28
    static let customControlSpacing: CGFloat = 4
    static let customSeparatorWidth: CGFloat = 8
    static let customApplyWidth: CGFloat = 50
    static let customSaveAndApplyWidth: CGFloat = 90
    static let customInputClusterWidth = customModeWidth
        + customControlSpacing
        + customFieldWidth
        + customControlSpacing
        + customSeparatorWidth
        + customControlSpacing
        + customFieldWidth
    static let customActionClusterWidth = customApplyWidth
        + customControlSpacing
        + customSaveAndApplyWidth
    static let customClusterSpacing = contentWidth
        - customInputClusterWidth
        - customActionClusterWidth
    static let customVisibleRowWidth = customInputClusterWidth
        + customClusterSpacing
        + customActionClusterWidth
    static let savedDeleteHitSize: CGFloat = 24
}

@MainActor
final class ScreenshotAspectControlModel: ObservableObject {
    @Published var orientation: ScreenshotAspectOrientation
    @Published private(set) var currentConstraint: ScreenshotRegionConstraint
    @Published var customMode: ScreenshotCustomConstraintMode
    @Published var ratioWidth: String
    @Published var ratioHeight: String
    @Published var fixedWidth: String
    @Published var fixedHeight: String
    @Published private(set) var savedConstraints: [ScreenshotCustomConstraintPreset]
    @Published var isEditingCustom = false

    init(
        selection: ScreenshotAspectSelection,
        customConstraints: [ScreenshotCustomConstraintPreset]
    ) {
        orientation = selection.orientation
        currentConstraint = selection.constraint
        customMode = if case .fixedPixels = selection.constraint { .fixedPixels } else { .ratio }
        let ratioDimensions = Self.ratioDimensions(for: selection.constraint) ?? (16, 9)
        ratioWidth = Self.formatted(ratioDimensions.0)
        ratioHeight = Self.formatted(ratioDimensions.1)
        let fixedDimensions = Self.fixedDimensions(for: selection.constraint) ?? (1_200, 800)
        fixedWidth = String(fixedDimensions.0)
        fixedHeight = String(fixedDimensions.1)
        savedConstraints = ScreenshotPreferences.normalizedCustomConstraints(customConstraints)
    }

    var canonicalConstraint: ScreenshotRegionConstraint { Self.canonical(currentConstraint) }

    var customConstraint: ScreenshotRegionConstraint? {
        switch customMode {
        case .ratio:
            guard let width = Double(ratioWidth), width.isFinite, width > 0,
                  let height = Double(ratioHeight), height.isFinite, height > 0 else { return nil }
            return ScreenshotPreferences.normalizedCustomConstraint(.ratio(width: width, height: height))
        case .fixedPixels:
            guard let width = Int(fixedWidth), width > 0,
                  let height = Int(fixedHeight), height > 0 else { return nil }
            return ScreenshotPreferences.normalizedCustomConstraint(.fixedPixels(width: width, height: height))
        }
    }

    var previewConstraint: ScreenshotRegionConstraint {
        let base = isEditingCustom ? (customConstraint ?? currentConstraint) : currentConstraint
        return ScreenshotAspectSelection(
            orientation: orientation,
            constraint: Self.canonical(base)
        ).resolvedConstraint
    }

    var widthText: String {
        get { customMode == .ratio ? ratioWidth : fixedWidth }
        set {
            if customMode == .ratio { ratioWidth = newValue } else { fixedWidth = newValue }
        }
    }

    var heightText: String {
        get { customMode == .ratio ? ratioHeight : fixedHeight }
        set {
            if customMode == .ratio { ratioHeight = newValue } else { fixedHeight = newValue }
        }
    }

    var invalidMessage: String {
        switch customMode {
        case .ratio:
            L10n.string("screenshot.aspect.invalid.ratio")
        case .fixedPixels:
            L10n.string("screenshot.aspect.invalid.size")
        }
    }

    func select(_ constraint: ScreenshotRegionConstraint) -> ScreenshotAspectSelection {
        let selection = ScreenshotAspectSelection(orientation: orientation, constraint: constraint)
        currentConstraint = selection.resolvedConstraint
        synchronizeCustomDraft(with: currentConstraint, updatesMode: true)
        return selection
    }

    func setOrientation(_ orientation: ScreenshotAspectOrientation) -> ScreenshotAspectSelection {
        self.orientation = orientation
        let selection = ScreenshotAspectSelection(
            orientation: orientation,
            constraint: Self.canonical(currentConstraint)
        )
        currentConstraint = selection.resolvedConstraint
        return selection
    }

    func applyCustom(saves: Bool) -> (selection: ScreenshotAspectSelection, preset: ScreenshotCustomConstraintPreset?)? {
        guard let customConstraint else { return nil }
        let selection = select(customConstraint)
        guard saves else { return (selection, nil) }
        let preset = ScreenshotCustomConstraintPreset(constraint: selection.resolvedConstraint)
        savedConstraints = ScreenshotPreferences.normalizedCustomConstraints([preset] + savedConstraints)
        return (selection, preset)
    }

    @discardableResult
    func deleteSaved(_ id: UUID) -> UUID? {
        let ids = savedConstraints.map(\.id)
        let index = ids.firstIndex(of: id)
        let neighbor = index.flatMap { current -> UUID? in
            if current + 1 < ids.count { return ids[current + 1] }
            if current > 0 { return ids[current - 1] }
            return nil
        }
        savedConstraints.removeAll { $0.id == id }
        return neighbor
    }

    func synchronize(
        selection: ScreenshotAspectSelection,
        customConstraints: [ScreenshotCustomConstraintPreset]
    ) {
        orientation = selection.orientation
        currentConstraint = selection.constraint
        savedConstraints = ScreenshotPreferences.normalizedCustomConstraints(customConstraints)
        guard !isEditingCustom else { return }
        synchronizeCustomDraft(with: selection.constraint, updatesMode: true)
    }

    static func title(for constraint: ScreenshotRegionConstraint) -> String {
        switch constraint {
        case .free:
            return L10n.string("screenshot.selection.constraint.free")
        case let .ratio(width, height):
            return "\(formatted(width)):\(formatted(height))"
        case let .fixedPixels(width, height):
            return "\(width)×\(height)"
        }
    }

    nonisolated static func canonical(_ constraint: ScreenshotRegionConstraint) -> ScreenshotRegionConstraint {
        switch constraint {
        case .free:
            return .free
        case let .ratio(width, height):
            return .ratio(width: max(width, height), height: min(width, height))
        case let .fixedPixels(width, height):
            return .fixedPixels(width: max(width, height), height: min(width, height))
        }
    }

    private static func ratioDimensions(for constraint: ScreenshotRegionConstraint) -> (Double, Double)? {
        switch canonical(constraint) {
        case .free, .fixedPixels: nil
        case let .ratio(width, height): (width, height)
        }
    }

    private static func fixedDimensions(for constraint: ScreenshotRegionConstraint) -> (Int, Int)? {
        guard case let .fixedPixels(width, height) = canonical(constraint) else { return nil }
        return (width, height)
    }

    private static func formatted(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func synchronizeCustomDraft(
        with constraint: ScreenshotRegionConstraint,
        updatesMode: Bool
    ) {
        if let ratio = Self.ratioDimensions(for: constraint) {
            if updatesMode { customMode = .ratio }
            ratioWidth = Self.formatted(ratio.0)
            ratioHeight = Self.formatted(ratio.1)
        } else if let fixed = Self.fixedDimensions(for: constraint) {
            if updatesMode { customMode = .fixedPixels }
            fixedWidth = String(fixed.0)
            fixedHeight = String(fixed.1)
        }
    }
}

struct ScreenshotAspectRatioCapturePopover: View {
    @StateObject private var model: ScreenshotAspectControlModel
    private let selection: ScreenshotAspectSelection
    private let customConstraints: [ScreenshotCustomConstraintPreset]
    let onSelect: (ScreenshotAspectSelection) -> Void
    let onSave: (ScreenshotCustomConstraintPreset) -> Void
    let onDelete: (UUID) -> Void
    @State private var hoveredPresetID: UUID?
    @State private var hoveredChoiceID: String?
    @State private var focusSinkRequestID = 0
    @FocusState private var focusTarget: FocusTarget?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private enum FocusTarget: Hashable {
        case customMode
        case width
        case height
        case saved(UUID)
    }

    init(
        selection: ScreenshotAspectSelection,
        customConstraints: [ScreenshotCustomConstraintPreset] = [],
        onSelect: @escaping (ScreenshotAspectSelection) -> Void,
        onSave: @escaping (ScreenshotCustomConstraintPreset) -> Void = { _ in },
        onDelete: @escaping (UUID) -> Void = { _ in }
    ) {
        self.selection = selection
        self.customConstraints = customConstraints
        self.onSelect = onSelect
        self.onSave = onSave
        self.onDelete = onDelete
        _model = StateObject(wrappedValue: ScreenshotAspectControlModel(
            selection: selection,
            customConstraints: customConstraints
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScreenshotAspectRatioPanelMetrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.string("screenshot.aspect.title"), systemImage: "aspectratio")
                    .font(.headline)
                Spacer()
                Text(ScreenshotAspectControlModel.title(for: model.previewConstraint))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                orientationButton(.landscape)
                orientationButton(.portrait)
            }
            .frame(width: ScreenshotAspectRatioPanelMetrics.contentWidth)

            Text(L10n.string("screenshot.aspect.presets"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: ScreenshotAspectRatioPanelMetrics.presetColumnCount
                ),
                spacing: 8
            ) {
                aspectButton(L10n.string("screenshot.selection.constraint.free"), constraint: .free)
                aspectButton("16:9", constraint: .ratio(width: 16, height: 9))
                aspectButton("4:3", constraint: .ratio(width: 4, height: 3))
                aspectButton("1:1", constraint: .ratio(width: 1, height: 1))
                aspectButton("800×600", constraint: .fixedPixels(width: 800, height: 600))
                aspectButton("1920×1080", constraint: .fixedPixels(width: 1920, height: 1080))
            }

            savedPresets

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: ScreenshotAspectRatioPanelMetrics.customClusterSpacing) {
                    HStack(spacing: ScreenshotAspectRatioPanelMetrics.customControlSpacing) {
                        customModeControl
                        constraintField(
                            text: widthBinding,
                            label: L10n.string("screenshot.aspect.width"),
                            focus: .width
                        )
                        Text(model.customMode == .ratio ? ":" : "×")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: ScreenshotAspectRatioPanelMetrics.customSeparatorWidth)
                        constraintField(
                            text: heightBinding,
                            label: L10n.string("screenshot.aspect.height"),
                            focus: .height
                        )
                    }
                    .frame(width: ScreenshotAspectRatioPanelMetrics.customInputClusterWidth)

                    HStack(spacing: ScreenshotAspectRatioPanelMetrics.customControlSpacing) {
                        customActionButton(
                            L10n.string("screenshot.common.apply"),
                            width: ScreenshotAspectRatioPanelMetrics.customApplyWidth,
                            isProminent: false
                        ) { applyCustom(saves: false) }
                        customActionButton(
                            L10n.string("screenshot.common.saveAndApply"),
                            width: ScreenshotAspectRatioPanelMetrics.customSaveAndApplyWidth,
                            isProminent: true
                        ) { applyCustom(saves: true) }
                    }
                    .frame(width: ScreenshotAspectRatioPanelMetrics.customActionClusterWidth)
                }
                .frame(
                    width: ScreenshotAspectRatioPanelMetrics.contentWidth,
                    height: ScreenshotAspectRatioPanelMetrics.customControlHitHeight,
                    alignment: .leading
                )

                Text(model.invalidMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(model.customConstraint == nil ? 1 : 0)
                    .accessibilityHidden(model.customConstraint != nil)
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .leading)
            }
        }
        .padding(ScreenshotAspectRatioPanelMetrics.outerPadding)
        .frame(width: ScreenshotAspectRatioPanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ScreenshotNonTextFocusSink(requestID: focusSinkRequestID)
                .frame(width: 0, height: 0)
        }
        .onAppear { focusInitialControl() }
        .onChange(of: selection) { _, next in
            model.synchronize(selection: next, customConstraints: customConstraints)
        }
        .onChange(of: customConstraints) { _, next in
            model.synchronize(selection: selection, customConstraints: next)
        }
    }

    private func orientationButton(_ orientation: ScreenshotAspectOrientation) -> some View {
        let selected = model.orientation == orientation
        let choiceID = "orientation-\(orientation.rawValue)"
        let title = L10n.string(
            orientation == .landscape ? "screenshot.aspect.landscape" : "screenshot.aspect.portrait"
        )
        return Button {
            orientationBinding.wrappedValue = orientation
        } label: {
            HStack(spacing: 6) {
                ScreenshotOrientationGlyph(
                    orientation: orientation,
                    constraint: model.previewConstraint
                )
                    .frame(
                        width: ScreenshotAspectRatioPanelMetrics.orientationGlyphSize.width,
                        height: ScreenshotAspectRatioPanelMetrics.orientationGlyphSize.height
                    )
                Text(title)
                    .font(BlocksTypography.font(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(BlocksSelectableControlStyle(
            isSelected: selected,
            isFocused: false,
            isHovered: hoveredChoiceID == choiceID,
            isEnabled: true,
            increasesContrast: colorSchemeContrast == .increased
        ))
        .onHover { hoveredChoiceID = $0 ? choiceID : nil }
        .blocksAnimation(.hoverFocus, value: hoveredChoiceID == choiceID)
        .blocksAnimation(.selection, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func aspectButton(_ title: String, constraint: ScreenshotRegionConstraint) -> some View {
        let selected = model.canonicalConstraint == ScreenshotAspectControlModel.canonical(constraint)
        let choiceID = "constraint-\(String(describing: constraint))"
        Button {
            onSelect(model.select(constraint))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName(for: constraint))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(BlocksTypography.font(size: 11, weight: .medium))
                    .lineLimit(1)
            }
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(BlocksSelectableControlStyle(
            isSelected: selected,
            isFocused: false,
            isHovered: hoveredChoiceID == choiceID,
            isEnabled: true,
            increasesContrast: colorSchemeContrast == .increased
        ))
        .onHover { hoveredChoiceID = $0 ? choiceID : nil }
        .blocksAnimation(.hoverFocus, value: hoveredChoiceID == choiceID)
        .blocksAnimation(.selection, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func constraintField(
        text: Binding<String>,
        label: String,
        focus: FocusTarget
    ) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: ScreenshotAspectRatioPanelMetrics.customFieldWidth, height: 26)
            .focused($focusTarget, equals: focus)
            .overlay {
                if model.customConstraint == nil {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small
                    )
                        .stroke(Color.red.opacity(0.8), lineWidth: 1)
                }
            }
            .frame(
                width: ScreenshotAspectRatioPanelMetrics.customFieldWidth,
                height: ScreenshotAspectRatioPanelMetrics.customControlHitHeight
            )
            .contentShape(Rectangle())
    }

    private var customModeControl: some View {
        BlocksCompactControlGroup {
            customModeButton(.ratio)
            customModeButton(.fixedPixels)
        }
        .frame(
            width: ScreenshotAspectRatioPanelMetrics.customModeWidth,
            height: ScreenshotAspectRatioPanelMetrics.customControlHeight
        )
        .frame(
            width: ScreenshotAspectRatioPanelMetrics.customModeWidth,
            height: ScreenshotAspectRatioPanelMetrics.customControlHitHeight
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($focusTarget, equals: .customMode)
        .onMoveCommand { direction in
            switch direction {
            case .left, .up: model.customMode = .ratio
            case .right, .down: model.customMode = .fixedPixels
            default: break
            }
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            model.customMode = model.customMode == .ratio ? .fixedPixels : .ratio
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("screenshot.aspect.customTitle"))
        .accessibilityValue(customModeTitle(model.customMode))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.customMode = .fixedPixels
            case .decrement: model.customMode = .ratio
            @unknown default: break
            }
        }
    }

    private func customModeButton(_ mode: ScreenshotCustomConstraintMode) -> some View {
        let selected = model.customMode == mode
        return Button {
            model.customMode = mode
        } label: {
            Text(customModeTitle(mode))
                .font(BlocksTypography.font(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(BlocksSelectableControlStyle(
            isSelected: selected,
            isFocused: focusTarget == .customMode,
            isHovered: hoveredChoiceID == "custom-mode-\(mode.rawValue)",
            isEnabled: true,
            increasesContrast: colorSchemeContrast == .increased
        ))
        .onHover {
            hoveredChoiceID = $0 ? "custom-mode-\(mode.rawValue)" : nil
        }
        .blocksAnimation(.hoverFocus, value: hoveredChoiceID == "custom-mode-\(mode.rawValue)")
        .blocksAnimation(.selection, value: selected)
        .focusable(false)
        .accessibilityHidden(true)
    }

    private func customModeTitle(_ mode: ScreenshotCustomConstraintMode) -> String {
        L10n.string(
            mode == .ratio ? "screenshot.aspect.mode.ratio" : "screenshot.aspect.mode.fixed"
        )
    }

    @ViewBuilder
    private func customActionButton(
        _ title: String,
        width: CGFloat,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isEnabled = model.customConstraint != nil
        let button = Button(action: action) {
            Text(title)
                .font(BlocksTypography.font(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: width, height: ScreenshotAspectRatioPanelMetrics.customControlHeight)
        }
        .controlSize(.small)
        .frame(width: width, height: ScreenshotAspectRatioPanelMetrics.customControlHitHeight)
        .disabled(!isEnabled)
        if isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func applyCustom(saves: Bool) {
        guard let result = model.applyCustom(saves: saves) else { return }
        onSelect(result.selection)
        if let preset = result.preset { onSave(preset) }
        focusInitialControl()
    }

    private func focusInitialControl() {
        focusTarget = nil
        focusSinkRequestID &+= 1
    }

    @ViewBuilder
    private var savedPresets: some View {
        if !model.savedConstraints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("screenshot.aspect.saved"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: ScreenshotAspectRatioPanelMetrics.savedColumnCount
                    ),
                    spacing: 8
                ) {
                    ForEach(model.savedConstraints) { preset in
                        let selected = model.canonicalConstraint
                            == ScreenshotAspectControlModel.canonical(preset.constraint)
                        ZStack(alignment: .trailing) {
                            Button {
                                onSelect(model.select(preset.constraint))
                            } label: {
                                Text(ScreenshotAspectControlModel.title(for: preset.constraint))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, BlocksVisualTokens.Spacing.sm)
                                    .padding(.trailing, ScreenshotAspectRatioPanelMetrics.savedDeleteHitSize)
                                    .frame(height: BlocksVisualTokens.Control.compactHeight)
                            }
                            .buttonStyle(BlocksSelectableControlStyle(
                                isSelected: selected,
                                isFocused: false,
                                isHovered: hoveredPresetID == preset.id,
                                isEnabled: true,
                                increasesContrast: colorSchemeContrast == .increased
                            ))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            BlocksCompactIconButton(
                                systemImage: "xmark",
                                label: L10n.format(
                                    "screenshot.aspect.deleteSavedNamed",
                                    ScreenshotAspectControlModel.title(for: preset.constraint)
                                ),
                                density: .micro
                            ) {
                                deleteSaved(preset.id)
                            }
                            .focused($focusTarget, equals: .saved(preset.id))
                            .opacity(
                                hoveredPresetID == preset.id || focusTarget == .saved(preset.id)
                                    ? 1
                                    : 0.35
                            )
                        }
                        .frame(height: BlocksVisualTokens.Control.compactHeight)
                        .onHover { hoveredPresetID = $0 ? preset.id : nil }
                        .blocksAnimation(.hoverFocus, value: hoveredPresetID == preset.id)
                        .blocksAnimation(.selection, value: selected)
                    }
                }
            }
        }
    }

    private var orientationBinding: Binding<ScreenshotAspectOrientation> {
        Binding(
            get: { model.orientation },
            set: { onSelect(model.setOrientation($0)) }
        )
    }

    private var widthBinding: Binding<String> {
        Binding(get: { model.widthText }, set: { model.widthText = $0 })
    }

    private var heightBinding: Binding<String> {
        Binding(get: { model.heightText }, set: { model.heightText = $0 })
    }

    private func deleteSaved(_ id: UUID) {
        let neighbor = model.deleteSaved(id)
        onDelete(id)
        DispatchQueue.main.async {
            if let neighbor {
                focusTarget = .saved(neighbor)
            } else {
                focusInitialControl()
            }
        }
    }

    private func iconName(for constraint: ScreenshotRegionConstraint) -> String {
        switch constraint {
        case .free:
            return "crop"
        case .ratio:
            return "rectangle"
        case .fixedPixels:
            return "viewfinder.rectangular"
        }
    }

}

private struct ScreenshotNonTextFocusSink: NSViewRepresentable {
    let requestID: Int

    func makeNSView(context: Context) -> ScreenshotNonTextFocusSinkView {
        let view = ScreenshotNonTextFocusSinkView()
        view.setAccessibilityElement(false)
        view.requestFocus(requestID)
        return view
    }

    func updateNSView(_ view: ScreenshotNonTextFocusSinkView, context: Context) {
        view.requestFocus(requestID)
    }
}

/// Resolves one monotonic first-responder request from AppKit lifecycle events.
///
/// SwiftUI may create a representable before it belongs to a window, while a
/// nonactivating panel can become key after its content is mounted. Keeping the
/// request pending until either event occurs avoids wall-clock focus retries
/// and prevents an older request from stealing focus from a newer control.
@MainActor
final class ScreenshotFocusRequestCoordinator {
    typealias Eligibility = @MainActor (NSView) -> Bool
    typealias FocusPerformer = @MainActor (NSView) -> Bool

    private weak var targetView: NSView?
    private weak var observedWindow: NSWindow?
    private var keyWindowObserver: NSObjectProtocol?
    private var latestRequestID = 0
    private var pendingRequestID: Int?
    private(set) var appliedRequestID: Int?
    private let isEligible: Eligibility
    private let performFocus: FocusPerformer

    init(
        isEligible: @escaping Eligibility = { $0.window != nil },
        performFocus: @escaping FocusPerformer = { view in
            guard let window = view.window else { return false }
            return window.firstResponder === view
                || window.makeFirstResponder(view)
        }
    ) {
        self.isEligible = isEligible
        self.performFocus = performFocus
    }

    deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
    }

    func attach(_ view: NSView) {
        if targetView !== view {
            targetView = view
        }
        observeWindowIfNeeded()
        applyPendingFocus()
    }

    func detach() {
        removeWindowObservation()
        targetView = nil
        pendingRequestID = nil
    }

    func requestFocus(_ requestID: Int?) {
        guard let requestID,
              requestID > latestRequestID else { return }
        latestRequestID = requestID
        pendingRequestID = requestID
        observeWindowIfNeeded()
        applyPendingFocus()
    }

    /// Revalidates the same request after AppKit finishes dispatching the
    /// current mouse event. This covers controls created during `mouseDown`,
    /// where AppKit may restore the original responder at the end of the
    /// event, without relying on a device-dependent wall-clock retry.
    func requestFocusAfterCurrentEvent(_ requestID: Int?) {
        guard let requestID,
              requestID > latestRequestID else { return }
        requestFocus(requestID)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.latestRequestID == requestID,
                  self.targetView != nil else { return }
            self.pendingRequestID = requestID
            self.applyPendingFocus()
        }
    }

    func targetDidMoveToWindow() {
        observeWindowIfNeeded()
        applyPendingFocus()
    }

    @discardableResult
    func applyPendingFocus() -> Bool {
        guard let requestID = pendingRequestID,
              let targetView,
              isEligible(targetView),
              performFocus(targetView) else { return false }
        appliedRequestID = requestID
        pendingRequestID = nil
        return true
    }

    private func observeWindowIfNeeded() {
        guard let window = targetView?.window else { return }
        guard observedWindow !== window else { return }
        removeWindowObservation()
        observedWindow = window
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPendingFocus()
            }
        }
    }

    private func removeWindowObservation() {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        keyWindowObserver = nil
        observedWindow = nil
    }
}

private final class ScreenshotNonTextFocusSinkView: NSView {
    private let focusCoordinator = ScreenshotFocusRequestCoordinator()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.initialFirstResponder = self
            focusCoordinator.attach(self)
        } else {
            focusCoordinator.detach()
        }
    }

    func requestFocus(_ requestID: Int) {
        focusCoordinator.requestFocus(requestID)
    }
}

enum ScreenshotOrientationGlyphLayout {
    static let maximumEdge: CGFloat = 18
    static let minimumEdge: CGFloat = 6

    static func shapeSize(
        for constraint: ScreenshotRegionConstraint,
        orientation: ScreenshotAspectOrientation
    ) -> CGSize {
        let dimensions: (width: Double, height: Double) = switch ScreenshotAspectControlModel.canonical(constraint) {
        case .free:
            (16, 10)
        case let .ratio(width, height):
            (width, height)
        case let .fixedPixels(width, height):
            (Double(width), Double(height))
        }
        let ratio = max(1, dimensions.width / max(1, dimensions.height))
        let shortEdge = max(minimumEdge, maximumEdge / CGFloat(ratio))
        return orientation == .landscape
            ? CGSize(width: maximumEdge, height: shortEdge)
            : CGSize(width: shortEdge, height: maximumEdge)
    }
}

struct ScreenshotOrientationGlyph: View {
    let orientation: ScreenshotAspectOrientation
    let constraint: ScreenshotRegionConstraint

    var body: some View {
        let shapeSize = ScreenshotOrientationGlyphLayout.shapeSize(
            for: constraint,
            orientation: orientation
        )
        ZStack {
            RoundedRectangle(
                cornerRadius: BlocksVisualTokens.CornerRadius.small,
                style: .continuous
            )
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                        .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                }
                .frame(
                    width: shapeSize.width,
                    height: shapeSize.height
                )
        }
        .frame(
            width: ScreenshotAspectRatioPanelMetrics.orientationGlyphSize.width,
            height: ScreenshotAspectRatioPanelMetrics.orientationGlyphSize.height
        )
        .accessibilityHidden(true)
    }
}

struct ScreenshotAspectRatioPropertyStrip: View {
    @ObservedObject var model: ScreenshotAspectControlModel
    let onSelect: (ScreenshotAspectSelection) -> Void
    let onSave: (ScreenshotCustomConstraintPreset) -> Void

    @State private var customModeFocusRequestID = 0
    @State private var customTriggerFocusRequestID = 0
    @FocusState private var focusTarget: FocusTarget?

    private enum FocusTarget: Hashable {
        case width
        case height
    }

    var body: some View {
        Group {
            if model.isEditingCustom {
                customControls
                    .transition(.opacity)
            } else {
                presetControls
                    .transition(.opacity)
            }
        }
        .blocksAnimation(.hoverFocus, value: model.isEditingCustom)
        .onExitCommand {
            guard model.isEditingCustom else { return }
            exitCustomMode()
        }
    }

    private var presetControls: some View {
        HStack(spacing: 6) {
            orientationPicker

            ScreenshotAspectPresetMenu(
                currentConstraint: model.previewConstraint,
                savedConstraints: model.savedConstraints,
                onSelect: {
                    onSelect(model.select($0))
                }
            )

            ScreenshotCustomTriggerButton(
                focusRequestID: customTriggerFocusRequestID == 0 ? nil : customTriggerFocusRequestID,
                action: enterCustomMode
            )
            .fixedSize()
            .frame(height: 26)

        }
    }

    private var customControls: some View {
        HStack(spacing: 6) {
            orientationPicker

            Button {
                exitCustomMode()
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("screenshot.aspect.returnToPresets"))

            ScreenshotCustomModeSegmentedControl(
                mode: $model.customMode,
                focusRequestID: customModeFocusRequestID == 0 ? nil : customModeFocusRequestID,
                onCancel: exitCustomMode
            )
            .frame(
                width: ScreenshotAspectRatioPanelMetrics.customModeWidth,
                height: ScreenshotAspectRatioPanelMetrics.customControlHeight
            )

            propertyField(text: widthBinding, label: L10n.string("screenshot.aspect.width"), focus: .width)
            Text(model.customMode == .ratio ? ":" : "×")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            propertyField(text: heightBinding, label: L10n.string("screenshot.aspect.height"), focus: .height)
            if model.customConstraint == nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(model.invalidMessage)
                    .blocksImmediateTooltip(model.invalidMessage)
            }

            Button(L10n.string("screenshot.common.apply")) { applyCustom(saves: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(height: ScreenshotAspectRatioPanelMetrics.customControlHeight)
                .disabled(model.customConstraint == nil)
            Button(L10n.string("screenshot.common.saveAndApply")) { applyCustom(saves: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.accentColor)
                .frame(height: ScreenshotAspectRatioPanelMetrics.customControlHeight)
                .disabled(model.customConstraint == nil)
        }
    }

    private var orientationPicker: some View {
        Picker("", selection: orientationBinding) {
            Image(systemName: "rectangle")
                .accessibilityLabel(L10n.string("screenshot.aspect.landscape"))
                .tag(ScreenshotAspectOrientation.landscape)
            Image(systemName: "rectangle.portrait")
                .accessibilityLabel(L10n.string("screenshot.aspect.portrait"))
                .tag(ScreenshotAspectOrientation.portrait)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .frame(width: 56)
        .accessibilityLabel(L10n.string("screenshot.aspect.title"))
    }

    private func propertyField(
        text: Binding<String>,
        label: String,
        focus: FocusTarget
    ) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(
                width: ScreenshotAspectRatioPanelMetrics.customFieldWidth,
                height: ScreenshotAspectRatioPanelMetrics.customControlHeight
            )
            .focused($focusTarget, equals: focus)
            .accessibilityHint(model.customConstraint == nil ? model.invalidMessage : "")
            .overlay {
                if model.customConstraint == nil {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small
                    )
                        .stroke(Color.red.opacity(0.8), lineWidth: 1)
                }
            }
            .accessibilityValue(text.wrappedValue)
    }

    private var orientationBinding: Binding<ScreenshotAspectOrientation> {
        Binding(
            get: { model.orientation },
            set: { onSelect(model.setOrientation($0)) }
        )
    }

    private var widthBinding: Binding<String> {
        Binding(get: { model.widthText }, set: { model.widthText = $0 })
    }

    private var heightBinding: Binding<String> {
        Binding(get: { model.heightText }, set: { model.heightText = $0 })
    }

    private func applyCustom(saves: Bool) {
        guard let result = model.applyCustom(saves: saves) else { return }
        onSelect(result.selection)
        if let preset = result.preset { onSave(preset) }
        exitCustomMode()
    }

    private func clearFocus() {
        focusTarget = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func enterCustomMode() {
        clearFocus()
        model.isEditingCustom = true
        customModeFocusRequestID &+= 1
    }

    private func exitCustomMode() {
        clearFocus()
        model.isEditingCustom = false
        customTriggerFocusRequestID &+= 1
    }

}

private struct ScreenshotAspectPresetMenu: View {
    let currentConstraint: ScreenshotRegionConstraint
    let savedConstraints: [ScreenshotCustomConstraintPreset]
    let onSelect: (ScreenshotRegionConstraint) -> Void

    private let builtInConstraints: [ScreenshotRegionConstraint] = [
        .free,
        .ratio(width: 16, height: 9),
        .ratio(width: 4, height: 3),
        .ratio(width: 1, height: 1),
        .fixedPixels(width: 800, height: 600),
        .fixedPixels(width: 1_920, height: 1_080),
    ]

    var body: some View {
        Menu {
            Section(L10n.string("screenshot.aspect.presets")) {
                ForEach(Array(builtInConstraints.enumerated()), id: \.offset) { _, constraint in
                    option(constraint)
                }
            }
            if !savedConstraints.isEmpty {
                Section(L10n.string("screenshot.aspect.saved")) {
                    ForEach(savedConstraints) { preset in
                        option(preset.constraint)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11, weight: .medium))
                Text(ScreenshotAspectControlModel.title(for: currentConstraint))
                    .font(.caption.monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 112, minHeight: 26, maxHeight: 26)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.string("screenshot.selection.constraint"))
        .accessibilityValue(ScreenshotAspectControlModel.title(for: currentConstraint))
    }

    private func option(_ constraint: ScreenshotRegionConstraint) -> some View {
        let selected = ScreenshotAspectControlModel.canonical(currentConstraint)
            == ScreenshotAspectControlModel.canonical(constraint)
        return Button {
            onSelect(constraint)
        } label: {
            HStack {
                Text(ScreenshotAspectControlModel.title(for: constraint))
                if selected { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ScreenshotCustomModeSegmentedControl: NSViewRepresentable {
    @Binding var mode: ScreenshotCustomConstraintMode
    let focusRequestID: Int?
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: $mode)
    }

    func makeNSView(context: Context) -> FocusableSegmentedControl {
        let control = FocusableSegmentedControl(
            labels: [
                L10n.string("screenshot.aspect.mode.ratio"),
                L10n.string("screenshot.aspect.mode.fixed"),
            ],
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.controlSize = .mini
        control.segmentStyle = .rounded
        control.setAccessibilityLabel(L10n.string("screenshot.aspect.customTitle"))
        control.onCancel = onCancel
        context.coordinator.attach(control)
        update(control)
        context.coordinator.requestFocus(focusRequestID)
        return control
    }

    func updateNSView(_ control: FocusableSegmentedControl, context: Context) {
        context.coordinator.mode = $mode
        control.onCancel = onCancel
        control.setLabel(L10n.string("screenshot.aspect.mode.ratio"), forSegment: 0)
        control.setLabel(L10n.string("screenshot.aspect.mode.fixed"), forSegment: 1)
        control.setAccessibilityLabel(L10n.string("screenshot.aspect.customTitle"))
        context.coordinator.attach(control)
        update(control)
        context.coordinator.requestFocus(focusRequestID)
    }

    private func update(_ control: NSSegmentedControl) {
        control.selectedSegment = mode == .ratio ? 0 : 1
    }

    @MainActor
    final class Coordinator: NSObject {
        var mode: Binding<ScreenshotCustomConstraintMode>
        weak var control: FocusableSegmentedControl?
        private let focusCoordinator = ScreenshotFocusRequestCoordinator()

        init(mode: Binding<ScreenshotCustomConstraintMode>) {
            self.mode = mode
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            mode.wrappedValue = sender.selectedSegment == 1 ? .fixedPixels : .ratio
        }

        func attach(_ control: FocusableSegmentedControl) {
            self.control = control
            control.onWindowChange = { [weak self] in
                self?.focusCoordinator.targetDidMoveToWindow()
            }
            focusCoordinator.attach(control)
        }

        func requestFocus(_ requestID: Int?) {
            focusCoordinator.requestFocus(requestID)
        }
    }

    final class FocusableSegmentedControl: NSSegmentedControl, ScreenshotEditorLocalEscapeHandling {
        var onCancel: (() -> Void)?
        var onWindowChange: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func cancelOperation(_ sender: Any?) {
            _ = handleEditorEscape()
        }

        func handleEditorEscape() -> Bool {
            guard let onCancel else { return false }
            onCancel()
            return true
        }
    }
}

private struct ScreenshotCustomTriggerButton: NSViewRepresentable {
    let focusRequestID: Int?
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> FocusableButton {
        let button = FocusableButton(
            title: L10n.string("screenshot.aspect.customTitle"),
            target: context.coordinator,
            action: #selector(Coordinator.activate(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(L10n.string("screenshot.aspect.customTitle"))
        context.coordinator.attach(button)
        context.coordinator.requestFocus(focusRequestID)
        return button
    }

    func updateNSView(_ button: FocusableButton, context: Context) {
        context.coordinator.action = action
        button.title = L10n.string("screenshot.aspect.customTitle")
        button.setAccessibilityLabel(L10n.string("screenshot.aspect.customTitle"))
        context.coordinator.attach(button)
        context.coordinator.requestFocus(focusRequestID)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        weak var button: FocusableButton?
        private let focusCoordinator = ScreenshotFocusRequestCoordinator()

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate(_ sender: NSButton) {
            action()
        }

        func attach(_ button: FocusableButton) {
            self.button = button
            button.onWindowChange = { [weak self] in
                self?.focusCoordinator.targetDidMoveToWindow()
            }
            focusCoordinator.attach(button)
        }

        func requestFocus(_ requestID: Int?) {
            focusCoordinator.requestFocus(requestID)
        }
    }

    final class FocusableButton: NSButton {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }
    }
}

struct ScreenshotNumericValueDescriptor: Equatable {
    enum Unit: Equatable {
        case number
        case percent
        case multiplier
    }

    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let unit: Unit

    func clamp(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    func parse(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "×", with: "")
            .replacingOccurrences(of: "x", with: "", options: .caseInsensitive)
        guard let raw = Double(normalized), raw.isFinite else { return nil }
        let resolved = unit == .percent ? raw / 100 : raw
        return clamp(resolved)
    }

    func format(_ value: Double) -> String {
        let display = unit == .percent ? clamp(value) * 100 : clamp(value)
        let number = display.formatted(.number.precision(.fractionLength(0...fractionDigits)))
        switch unit {
        case .number: return number
        case .percent: return "\(number)%"
        case .multiplier: return "\(number)×"
        }
    }

    func stepped(_ value: Double, direction: Int) -> Double {
        clamp(value + Double(direction) * step)
    }
}

enum ScreenshotStepEditorLayout {
    static func noteRect(
        badgeCenter: ScreenshotPixelPoint,
        appearance: ScreenshotStepAppearance,
        sourceBounds: ScreenshotPixelRect,
        preferredWidth: Int = 180
    ) -> ScreenshotPixelRect {
        let width = min(max(80, preferredWidth), max(80, sourceBounds.width - 16))
        let textLayout = ScreenshotTextLayout(appearance: .text(appearance.note))
        let measured = textLayout.measure(
            L10n.string("screenshot.editor.text.placeholder"),
            sizing: .fixedWidth,
            constrainedTo: Double(width)
        )
        let height = max(44, Int(ceil(measured.height)))
        let diameter = max(16, appearance.badgeSize)
        let target = ScreenshotPixelRect(
            x: Int(floor(badgeCenter.x - diameter / 2)),
            y: Int(floor(badgeCenter.y - diameter / 2)),
            width: Int(ceil(diameter)),
            height: Int(ceil(diameter))
        )
        return ScreenshotLinkedAnnotationLayout.noteRect(
            targetBounds: target,
            noteSize: CGSize(width: width, height: height),
            gap: max(ScreenshotStepResolvedLayout.minimumGap, appearance.gap),
            constrainedTo: sourceBounds
        )
    }

    static func inlineTextAppearance(from appearance: ScreenshotElementAppearance) -> ScreenshotElementAppearance {
        guard case let .step(step) = appearance.payload else { return appearance }
        return .text(step.note)
    }

    static func editingBaseElement(from element: ScreenshotElement) -> ScreenshotElement? {
        guard element.kind != .text else { return nil }
        var base = element
        base.text = ""
        if case var .step(step) = base.appearance.payload {
            // The inline NSTextView owns the note background and border while
            // editing. Keep only the badge and connector in the rendered base
            // so translucent chrome is not composited twice.
            step.noteBackgroundColor.alpha = 0
            step.noteBorderWidth = 0
            base.appearance.payload = .step(step)
        } else if case var .callout(callout) = base.appearance.payload {
            // The inline NSTextView owns the note chrome while editing. Keep
            // the target and connector visible without double-compositing the
            // note background or its glyphs.
            callout.note.backgroundColor = nil
            callout.note.backgroundBorderWidth = 0
            base.appearance.payload = .callout(callout)
        }
        return base
    }
}

enum ScreenshotSemanticTextStyle {
    static func inlineAppearance(
        from appearance: ScreenshotElementAppearance,
        kind: ScreenshotElementKind
    ) -> ScreenshotElementAppearance {
        switch (kind, appearance.payload) {
        case let (.step, .step(step)):
            return .text(step.note)
        case let (.callout, .callout(callout)):
            return .text(callout.note)
        default:
            return appearance
        }
    }
}

struct ScreenshotNumericSlider: View {
    let title: String
    @Binding var value: Double
    let descriptor: ScreenshotNumericValueDescriptor
    let onEditingChanged: (Bool) -> Void
    var showsCenterAnchor = false

    @State private var text = ""
    @State private var originalValue = 0.0
    @State private var isTextEditing = false
    @State private var hasInvalidInput = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            ZStack {
                if showsCenterAnchor {
                    Rectangle()
                        .fill(Color.primary.opacity(0.28))
                        .frame(width: 1, height: 10)
                        .allowsHitTesting(false)
                }
                Slider(value: $value, in: descriptor.range) { editing in
                    if editing {
                        originalValue = value
                        onEditingChanged(true)
                    } else {
                        text = descriptor.format(value)
                        onEditingChanged(false)
                    }
                }
            }
            .frame(width: 88)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 46, height: 22)
                .padding(.horizontal, 4)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                        .stroke(hasInvalidInput ? Color.red.opacity(0.8) : .clear, lineWidth: 1)
                }
                .focused($isFieldFocused)
                .onSubmit(commitText)
                .onExitCommand(perform: cancelText)
                .onMoveCommand { direction in
                    switch direction {
                    case .up: applyStep(1)
                    case .down: applyStep(-1)
                    default: break
                    }
                }
        }
        .onAppear { text = descriptor.format(value) }
        .onChange(of: value) { _, next in
            guard !isFieldFocused else { return }
            text = descriptor.format(next)
        }
        .onChange(of: isFieldFocused) { _, focused in
            if focused {
                beginTextEditingIfNeeded()
            } else if isTextEditing {
                commitText()
            }
        }
    }

    private func beginTextEditingIfNeeded() {
        guard !isTextEditing else { return }
        originalValue = value
        isTextEditing = true
        hasInvalidInput = false
        onEditingChanged(true)
    }

    private func commitText() {
        guard isTextEditing else { return }
        guard let parsed = descriptor.parse(text) else {
            hasInvalidInput = true
            return
        }
        value = parsed
        text = descriptor.format(parsed)
        hasInvalidInput = false
        isTextEditing = false
        isFieldFocused = false
        onEditingChanged(false)
    }

    private func cancelText() {
        guard isTextEditing else { return }
        value = originalValue
        text = descriptor.format(originalValue)
        hasInvalidInput = false
        isTextEditing = false
        isFieldFocused = false
        onEditingChanged(false)
    }

    private func applyStep(_ direction: Int) {
        beginTextEditingIfNeeded()
        value = descriptor.stepped(value, direction: direction)
        text = descriptor.format(value)
    }
}

struct ScreenshotNumericFieldDraft: Equatable {
    let originalValue: Double
    var text: String

    init(value: Double, descriptor: ScreenshotNumericValueDescriptor) {
        originalValue = value
        text = descriptor.format(value)
    }

    mutating func step(_ direction: Int, descriptor: ScreenshotNumericValueDescriptor) {
        let source = descriptor.parse(text) ?? originalValue
        text = descriptor.format(descriptor.stepped(source, direction: direction))
    }

    func committedValue(descriptor: ScreenshotNumericValueDescriptor) -> Double? {
        descriptor.parse(text)
    }
}

struct ScreenshotNumericField: View {
    let title: String
    @Binding var value: Double
    let descriptor: ScreenshotNumericValueDescriptor

    @State private var text = ""
    @State private var draft: ScreenshotNumericFieldDraft?
    @State private var hasInvalidInput = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 52, height: 22)
                .padding(.horizontal, 4)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                        .stroke(hasInvalidInput ? Color.red.opacity(0.8) : .clear, lineWidth: 1)
                }
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)
                .onMoveCommand { direction in
                    switch direction {
                    case .up: step(1)
                    case .down: step(-1)
                    default: break
                    }
                }
        }
        .onAppear { text = descriptor.format(value) }
        .onChange(of: value) { _, next in
            guard !isFocused else { return }
            text = descriptor.format(next)
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                guard draft == nil else { return }
                draft = ScreenshotNumericFieldDraft(value: value, descriptor: descriptor)
            } else if draft != nil {
                commit()
            }
        }
    }

    private func commit() {
        guard var draft else { return }
        draft.text = text
        guard let next = draft.committedValue(descriptor: descriptor) else {
            hasInvalidInput = true
            return
        }
        value = next
        text = descriptor.format(next)
        hasInvalidInput = false
        self.draft = nil
        isFocused = false
    }

    private func cancel() {
        guard let draft else { return }
        value = draft.originalValue
        text = descriptor.format(draft.originalValue)
        hasInvalidInput = false
        self.draft = nil
        isFocused = false
    }

    private func step(_ direction: Int) {
        var nextDraft = draft ?? ScreenshotNumericFieldDraft(value: value, descriptor: descriptor)
        nextDraft.text = text
        nextDraft.step(direction, descriptor: descriptor)
        draft = nextDraft
        text = nextDraft.text
        hasInvalidInput = false
    }
}

struct ScreenshotColorPickerButton: View {
    @Binding var color: ScreenshotColor
    let recentColors: [ScreenshotColor]
    var allowsTransparent = false
    var isTransparent = false
    let onEditingChanged: (Bool) -> Void
    let onColorCommitted: (ScreenshotColor) -> Void
    var onTransparentSelected: () -> Void = {}

    @State private var isPresented = false
    @State private var nativePanelActive = false
    @StateObject private var colorPanelController = ScreenshotColorPanelController()

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ScreenshotColorSwatch(
                color: color,
                isTransparent: isTransparent,
                cornerRadius: BlocksVisualTokens.CornerRadius.small
            )
                .frame(width: 20, height: 20)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: BlocksVisualTokens.CornerRadius.small,
                        style: .continuous
                    )
                        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("screenshot.editor.colorPicker"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScreenshotColorPickerPopover(
                color: $color,
                recentColors: recentColors,
                allowsTransparent: allowsTransparent,
                isTransparent: isTransparent,
                onTransparentSelected: onTransparentSelected,
                onOpenNativePanel: openNativeColorPanel,
                onColorCommitted: onColorCommitted
            )
            .onAppear { onEditingChanged(true) }
            .onDisappear {
                if !nativePanelActive { onEditingChanged(false) }
            }
        }
        .background(ScreenshotColorPanelWindowBridge(controller: colorPanelController))
        .onDisappear { colorPanelController.dismiss() }
    }

    private func openNativeColorPanel() {
        nativePanelActive = true
        isPresented = false
        DispatchQueue.main.async {
            colorPanelController.present(
                color: color.opaqueRGB,
                onChange: { next in color = next.opaqueRGB },
                onClose: { final, changed in
                    if changed { onColorCommitted(final.opaqueRGB) }
                    nativePanelActive = false
                    onEditingChanged(false)
                }
            )
        }
    }
}

private struct ScreenshotColorPickerPopover: View {
    @Binding var color: ScreenshotColor
    let recentColors: [ScreenshotColor]
    let allowsTransparent: Bool
    let isTransparent: Bool
    let onTransparentSelected: () -> Void
    let onOpenNativePanel: () -> Void
    let onColorCommitted: (ScreenshotColor) -> Void

    @State private var hex = ""
    @State private var invalidHex = false

    private let columns = Array(repeating: GridItem(.fixed(24), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allowsTransparent {
                Text(L10n.string("screenshot.editor.color.background"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    invalidHex = false
                    onTransparentSelected()
                } label: {
                    HStack(spacing: 7) {
                        ScreenshotColorSwatch(
                            color: ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 0),
                            isTransparent: true,
                            cornerRadius: BlocksVisualTokens.CornerRadius.small
                        )
                        .frame(width: 20, height: 20)
                        Text(L10n.string("screenshot.editor.color.transparent"))
                        Spacer()
                        if isTransparent { Image(systemName: "checkmark") }
                    }
                    .frame(height: 24)
                }
                .buttonStyle(.plain)
            }
            colorGrid(title: L10n.string("screenshot.editor.color.common"), colors: Self.commonColors)
            if !recentColors.isEmpty {
                colorGrid(title: L10n.string("screenshot.editor.color.recent"), colors: recentColors)
            }
            Divider()
            HStack(spacing: 6) {
                Text("#")
                    .foregroundStyle(.secondary)
                TextField("RRGGBB", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 92)
                    .onSubmit(commitHex)
                Button(L10n.string("screenshot.common.confirm"), action: commitHex)
                    .controlSize(.small)
            }
            if invalidHex {
                Text(L10n.string("screenshot.editor.color.invalidHex"))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                Text(L10n.string("screenshot.editor.color.custom"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onOpenNativePanel) {
                    Image(systemName: "eyedropper.full")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("screenshot.editor.color.custom"))
            }
        }
        .padding(12)
        .frame(width: 212)
        .onAppear { hex = color.hexRGB }
    }

    @ViewBuilder
    private func colorGrid(title: String, colors: [ScreenshotColor]) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, item in
                Button { apply(item) } label: {
                    Circle()
                        .fill(item.swiftUIColor)
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle().stroke(Color.primary.opacity(item == color ? 0.9 : 0.22), lineWidth: item == color ? 2 : 1)
                        }
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commitHex() {
        guard let next = ScreenshotColor(hexRGB: hex) else {
            invalidHex = true
            return
        }
        apply(next)
    }

    private func apply(_ next: ScreenshotColor) {
        color = next.opaqueRGB
        hex = next.hexRGB
        invalidHex = false
        onColorCommitted(next.opaqueRGB)
    }

    private static let commonColors: [ScreenshotColor] = [
        .init(red: 0.93, green: 0.23, blue: 0.25, alpha: 1),
        .init(red: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        .init(red: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        .init(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        .init(red: 0.00, green: 0.72, blue: 0.74, alpha: 1),
        .init(red: 0.18, green: 0.52, blue: 0.98, alpha: 1),
        .init(red: 0.42, green: 0.36, blue: 0.90, alpha: 1),
        .init(red: 0.75, green: 0.28, blue: 0.82, alpha: 1),
        .init(red: 0.98, green: 0.35, blue: 0.63, alpha: 1),
        .init(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        .init(red: 0.50, green: 0.50, blue: 0.50, alpha: 1),
        .init(red: 0.08, green: 0.08, blue: 0.09, alpha: 1),
    ]
}

private struct ScreenshotColorSwatch: View {
    let color: ScreenshotColor
    let isTransparent: Bool
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if isTransparent {
                Canvas { context, size in
                    let cell = max(3, size.width / 4)
                    for row in 0..<4 {
                        for column in 0..<4 where (row + column).isMultiple(of: 2) {
                            context.fill(
                                Path(CGRect(
                                    x: CGFloat(column) * cell,
                                    y: CGFloat(row) * cell,
                                    width: cell,
                                    height: cell
                                )),
                                with: .color(Color.secondary.opacity(0.28))
                            )
                        }
                    }
                }
                Color.primary.opacity(0.035)
                Path { path in
                    path.move(to: CGPoint(x: 2, y: 18))
                    path.addLine(to: CGPoint(x: 18, y: 2))
                }
                .stroke(Color.red.opacity(0.8), lineWidth: 1.5)
            } else {
                color.swiftUIColor
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

@MainActor
final class ScreenshotColorPanelController: NSObject, ObservableObject {
    weak var ownerWindow: NSWindow?

    private weak var panel: NSColorPanel?
    private var originalLevel: NSWindow.Level?
    private var closeObserver: NSObjectProtocol?
    private var onChange: ((ScreenshotColor) -> Void)?
    private var onClose: ((ScreenshotColor, Bool) -> Void)?
    private var currentColor = ScreenshotColor(red: 0, green: 0, blue: 0, alpha: 1)
    private var didChange = false

    func present(
        color: ScreenshotColor,
        onChange: @escaping (ScreenshotColor) -> Void,
        onClose: @escaping (ScreenshotColor, Bool) -> Void
    ) {
        dismiss(notifies: false)
        guard let ownerWindow else {
            onClose(color, false)
            return
        }
        let panel = NSColorPanel.shared
        self.panel = panel
        self.onChange = onChange
        self.onClose = onClose
        currentColor = color.opaqueRGB
        didChange = false
        originalLevel = panel.level
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        )
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        ownerWindow.addChildWindow(panel, ordered: .above)
        panel.level = NSWindow.Level(rawValue: ownerWindow.level.rawValue + 1)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func dismiss() { dismiss(notifies: true) }

    private func dismiss(notifies: Bool) {
        guard panel != nil || onClose != nil else { return }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let panel {
            ownerWindow?.removeChildWindow(panel)
            if let originalLevel { panel.level = originalLevel }
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.orderOut(nil)
        }
        let completion = onClose
        let final = currentColor
        let changed = didChange
        panel = nil
        onChange = nil
        onClose = nil
        ownerWindow?.makeKeyAndOrderFront(nil)
        if notifies { completion?(final, changed) }
    }

    @objc func colorChanged(_ sender: NSColorPanel) {
        guard let converted = sender.color.usingColorSpace(.sRGB) else { return }
        let next = ScreenshotColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: 1
        )
        currentColor = next
        didChange = true
        onChange?(next)
    }
}

private struct ScreenshotColorPanelWindowBridge: NSViewRepresentable {
    let controller: ScreenshotColorPanelController

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChanged = { [weak controller] window in
            controller?.ownerWindow = window
        }
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.onWindowChanged = { [weak controller] window in
            controller?.ownerWindow = window
        }
        controller.ownerWindow = view.window
    }

    final class WindowReaderView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

extension ScreenshotColor {
    init?(hexRGB: String) {
        let normalized = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let value = UInt64(normalized, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexRGB: String {
        String(
            format: "%02X%02X%02X",
            Int(min(1, max(0, red)) * 255).clampedByte,
            Int(min(1, max(0, green)) * 255).clampedByte,
            Int(min(1, max(0, blue)) * 255).clampedByte
        )
    }

    var opaqueRGB: ScreenshotColor { ScreenshotColor(red: red, green: green, blue: blue, alpha: 1) }
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

private extension Int {
    var clampedByte: Int { Swift.min(255, Swift.max(0, self)) }
}
