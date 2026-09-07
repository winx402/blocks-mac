import AppKit
import SwiftUI

enum BlocksCompactIconButtonEmphasis: Equatable {
    case standard
    case accent
    case success
    case destructive
}

enum BlocksCompactIconButtonDensity: Equatable {
    case compact
    case micro
    case standard

    var hitTarget: CGFloat {
        switch self {
        case .micro, .compact:
            BlocksVisualTokens.Control.compactHeight
        case .standard:
            BlocksVisualTokens.Control.standardHeight
        }
    }

    var visualSize: CGFloat {
        switch self {
        case .compact:
            BlocksVisualTokens.Control.compactHeight
        case .micro:
            22
        case .standard:
            32
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact:
            BlocksVisualTokens.Control.compactIconSize
        case .micro:
            11.5
        case .standard:
            16
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .compact:
            BlocksVisualTokens.CornerRadius.small
        case .micro:
            5
        case .standard:
            BlocksVisualTokens.CornerRadius.control
        }
    }
}

enum BlocksCompactActionGroupLayout {
    static func spacing(
        for density: BlocksCompactIconButtonDensity
    ) -> CGFloat {
        switch density {
        case .compact, .standard:
            BlocksVisualTokens.Spacing.xs
        case .micro:
            1
        }
    }

    static func reservedWidth(
        density: BlocksCompactIconButtonDensity,
        slotCount: Int
    ) -> CGFloat {
        guard slotCount > 0 else { return 0 }
        return density.hitTarget * CGFloat(slotCount)
            + spacing(for: density) * CGFloat(slotCount - 1)
    }
}

/// Shared trailing action-group layout for compact macOS chrome.
///
/// A reserved slot count keeps dynamic actions from shifting stable trailing
/// controls while the shared density defines the same spacing rhythm across
/// clipboard, screenshot, and translation surfaces.
struct BlocksCompactActionGroup<Content: View>: View {
    let density: BlocksCompactIconButtonDensity
    let reservedSlotCount: Int?
    let content: Content

    init(
        density: BlocksCompactIconButtonDensity = .compact,
        reservedSlotCount: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.density = density
        self.reservedSlotCount = reservedSlotCount
        self.content = content()
    }

    var body: some View {
        HStack(
            spacing: BlocksCompactActionGroupLayout.spacing(
                for: density
            )
        ) {
            content
        }
        .frame(
            width: reservedSlotCount.map {
                BlocksCompactActionGroupLayout.reservedWidth(
                    density: density,
                    slotCount: $0
                )
            },
            alignment: .trailing
        )
    }
}

/// The single host-owned binary control used outside form-specific layout.
/// Feature surfaces provide the label and placement; the system switch owns
/// the visual state, keyboard behavior and accessibility semantics.
struct BlocksBooleanSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(title)
    }
}

enum BlocksInlineFeedbackKind: Equatable {
    case success
    case error
    case warning
    case information

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .warning: .orange
        case .information: .accentColor
        }
    }
}

struct BlocksInlineFeedback: View {
    let kind: BlocksInlineFeedbackKind
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: BlocksVisualTokens.Spacing.sm) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(kind.color)
            VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xxs) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, BlocksVisualTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
    }
}

enum BlocksCompactIconButtonVisualMetrics {
    static let microIdleForegroundOpacity: CGFloat = 0.84
    static let microActiveForegroundOpacity: CGFloat = 0.96
    static let inactiveForegroundOpacity: CGFloat = 0.82
    static let disabledForegroundOpacity: CGFloat = 0.52
    static let increasedContrastDisabledForegroundOpacity: CGFloat = 0.68
}

enum BlocksCompactIconButtonForegroundRole: Equatable {
    case primary
    case secondary
    case accent
    case success
    case destructive
}

struct BlocksCompactIconButtonAppearance: Equatable {
    let foregroundRole: BlocksCompactIconButtonForegroundRole
    let foregroundOpacity: CGFloat
    let backgroundOpacity: CGFloat
    let strokeOpacity: CGFloat

    static func resolve(
        emphasis: BlocksCompactIconButtonEmphasis,
        density: BlocksCompactIconButtonDensity,
        isEnabled: Bool,
        isHovered: Bool,
        isFocused: Bool,
        isSelected: Bool,
        isPressed: Bool,
        increasesContrast: Bool,
        isWindowActive: Bool
    ) -> BlocksCompactIconButtonAppearance {
        let isInteractive =
            isHovered || isFocused || isPressed || isSelected
        let foregroundRole: BlocksCompactIconButtonForegroundRole
        if !isWindowActive || !isEnabled {
            foregroundRole =
                increasesContrast ? .primary : .secondary
        } else {
            switch emphasis {
            case .standard:
                foregroundRole =
                    increasesContrast ? .primary : .secondary
            case .accent:
                foregroundRole = .accent
            case .success:
                foregroundRole = .success
            case .destructive:
                foregroundRole =
                    isHovered || isFocused || isPressed
                        ? .destructive
                        : (
                            increasesContrast
                                ? .primary
                                : .secondary
                        )
            }
        }

        let foregroundOpacity: CGFloat
        if !isEnabled {
            foregroundOpacity =
                increasesContrast
                    ? BlocksCompactIconButtonVisualMetrics
                        .increasedContrastDisabledForegroundOpacity
                    : BlocksCompactIconButtonVisualMetrics
                        .disabledForegroundOpacity
        } else if !isWindowActive {
            foregroundOpacity =
                increasesContrast
                    ? 1
                    : BlocksCompactIconButtonVisualMetrics
                        .inactiveForegroundOpacity
        } else if density == .micro {
            foregroundOpacity =
                isInteractive
                    ? BlocksCompactIconButtonVisualMetrics
                        .microActiveForegroundOpacity
                    : (
                        increasesContrast
                            ? 1
                            : BlocksCompactIconButtonVisualMetrics
                                .microIdleForegroundOpacity
                    )
        } else {
            foregroundOpacity = 1
        }

        let backgroundOpacity: CGFloat
        if !isEnabled || !isWindowActive {
            backgroundOpacity =
                isSelected
                    ? (increasesContrast ? 0.18 : 0.10)
                    : 0
        } else if isPressed {
            backgroundOpacity = increasesContrast ? 0.22 : 0.14
        } else if isSelected {
            backgroundOpacity = increasesContrast ? 0.22 : 0.16
        } else if emphasis == .accent || emphasis == .success {
            backgroundOpacity =
                isHovered
                    ? (increasesContrast ? 0.22 : 0.18)
                    : (increasesContrast ? 0.16 : 0.12)
        } else if emphasis == .destructive, isHovered {
            backgroundOpacity = increasesContrast ? 0.18 : 0.12
        } else if isHovered || isFocused {
            backgroundOpacity = increasesContrast ? 0.14 : 0.07
        } else {
            backgroundOpacity = 0
        }

        let strokeOpacity: CGFloat
        if isFocused {
            strokeOpacity = increasesContrast ? 1 : 0.70
        } else if isSelected {
            strokeOpacity = increasesContrast ? 0.68 : 0.38
        } else if increasesContrast, isEnabled {
            strokeOpacity = isWindowActive ? 0.30 : 0.22
        } else {
            strokeOpacity = 0
        }

        return BlocksCompactIconButtonAppearance(
            foregroundRole: foregroundRole,
            foregroundOpacity: foregroundOpacity,
            backgroundOpacity: backgroundOpacity,
            strokeOpacity: strokeOpacity
        )
    }
}

/// Shared compact icon treatment for dense macOS chrome.
///
/// The visible and interactive bounds intentionally match the native compact
/// control height. Translation result cards, clipboard chrome and screenshot
/// toolbars can therefore share one visual rhythm without inventing
/// feature-specific backgrounds.
struct BlocksCompactIconButton: View {
    let systemImage: String
    let label: String
    var isEnabled = true
    var isSelected = false
    var isLoading = false
    var emphasis: BlocksCompactIconButtonEmphasis = .standard
    var density: BlocksCompactIconButtonDensity = .compact
    var focusRequestID: UUID? = nil
    var showsHelp = true
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast
    @Environment(\.controlActiveState)
    private var controlActiveState

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(
                            .system(
                                size: density.iconSize,
                                weight: .medium
                            )
                        )
                }
            }
                .frame(
                    width: density.visualSize,
                    height: density.visualSize
                )
                .frame(width: density.hitTarget, height: density.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(
            BlocksIconButtonStyle(
                isHovered: isHovered,
                isFocused: isFocused,
                isEnabled: isEnabled,
                isSelected: isSelected,
                emphasis: emphasis,
                density: density,
                increasesContrast:
                    colorSchemeContrast == .increased,
                isWindowActive:
                    controlActiveState != .inactive
            )
        )
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .modifier(
            BlocksOptionalHelpModifier(
                label: label,
                isEnabled: showsHelp
            )
        )
        .accessibilityLabel(label)
        .accessibilityRemoveTraits(.isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .blocksAnimation(.hoverFocus, value: isHovered)
        .blocksAnimation(.selection, value: isSelected)
        .task(id: focusRequestID) {
            guard let requestID = focusRequestID else { return }
            await Task.yield()
            guard !Task.isCancelled, focusRequestID == requestID else { return }
            isFocused = true
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, focusRequestID == requestID else { return }
            isFocused = true
        }
    }
}

struct BlocksOptionalHelpModifier: ViewModifier {
    let label: String
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.help(label)
        } else {
            content
        }
    }
}

struct BlocksIconButtonStyle: ButtonStyle {
    let isHovered: Bool
    let isFocused: Bool
    let isEnabled: Bool
    let isSelected: Bool
    let emphasis: BlocksCompactIconButtonEmphasis
    let density: BlocksCompactIconButtonDensity
    let increasesContrast: Bool
    let isWindowActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        let appearance = BlocksCompactIconButtonAppearance.resolve(
            emphasis: emphasis,
            density: density,
            isEnabled: isEnabled,
            isHovered: isHovered,
            isFocused: isFocused,
            isSelected: isSelected,
            isPressed: configuration.isPressed,
            increasesContrast: increasesContrast,
            isWindowActive: isWindowActive
        )
        configuration.label
            .foregroundStyle(
                foregroundStyle(
                    role: appearance.foregroundRole
                )
                .opacity(appearance.foregroundOpacity)
            )
            .background {
                RoundedRectangle(
                    cornerRadius: density.cornerRadius,
                    style: .continuous
                )
                .fill(
                    backgroundColor(
                        emphasis: emphasis,
                        isSelected: isSelected
                    )
                    .opacity(appearance.backgroundOpacity)
                )
                .frame(
                    width: density.visualSize,
                    height: density.visualSize
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: density.cornerRadius,
                    style: .continuous
                )
                    .stroke(
                        strokeColor(
                            isFocused: isFocused,
                            isSelected: isSelected
                        )
                        .opacity(appearance.strokeOpacity),
                        lineWidth: BlocksVisualTokens.Stroke.width
                    )
                    .frame(
                        width: density.visualSize,
                        height: density.visualSize
                    )
            }
    }

    private func foregroundStyle(
        role: BlocksCompactIconButtonForegroundRole
    ) -> Color {
        switch role {
        case .primary:
            .primary
        case .secondary:
            .secondary
        case .accent:
            .accentColor
        case .success:
            Color(nsColor: .systemGreen)
        case .destructive:
            Color(nsColor: .systemRed)
        }
    }

    private func backgroundColor(
        emphasis: BlocksCompactIconButtonEmphasis,
        isSelected: Bool
    ) -> Color {
        if isSelected {
            return .accentColor
        }
        switch emphasis {
        case .accent:
            return .accentColor
        case .success:
            return Color(nsColor: .systemGreen)
        case .destructive:
            return Color(nsColor: .systemRed)
        case .standard:
            return .primary
        }
    }

    private func strokeColor(
        isFocused: Bool,
        isSelected: Bool
    ) -> Color {
        if isFocused || isSelected {
            return .accentColor
        }
        return .primary
    }
}

enum BlocksAppKitInteractiveChrome {
    static func apply(
        to view: NSView,
        selected: Bool,
        hovered: Bool,
        pressed: Bool
    ) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.wantsLayer = true
            view.layer?.cornerRadius = BlocksVisualTokens.CornerRadius.control
            view.layer?.cornerCurve = .continuous
            if pressed {
                view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            } else if selected {
                view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            } else if hovered {
                view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            } else {
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
            view.layer?.borderWidth = selected ? BlocksVisualTokens.Stroke.width : 0
            view.layer?.borderColor = NSColor.controlAccentColor
                .withAlphaComponent(0.38)
                .cgColor
        }
    }
}

enum BlocksAppKitCompactButtonChrome {
    static func apply(
        to control: NSButton,
        selected: Bool,
        hovered: Bool,
        pressed: Bool
    ) {
        BlocksAppKitInteractiveChrome.apply(
            to: control,
            selected: selected,
            hovered: hovered,
            pressed: pressed
        )
        control.effectiveAppearance.performAsCurrentDrawingAppearance {
            control.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }
    }
}

/// Shared AppKit counterpart of the compact SwiftUI icon controls.
///
/// Capture overlays still need native AppKit hit testing and first-responder
/// behavior, but their hover, press and selected visuals must remain on the
/// same design-system path as the rest of the app.
class BlocksAppKitCompactButton: NSButton {
    private var blocksSelected = false
    private var blocksHovered = false
    private var blocksPressed = false
    private var blocksTrackingArea: NSTrackingArea?

    func setBlocksSelected(_ selected: Bool) {
        blocksSelected = selected
        updateBlocksAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let blocksTrackingArea { removeTrackingArea(blocksTrackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        blocksTrackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        blocksHovered = true
        updateBlocksAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        blocksHovered = false
        updateBlocksAppearance()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        blocksPressed = flag
        updateBlocksAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBlocksAppearance()
    }

    private func updateBlocksAppearance() {
        BlocksAppKitCompactButtonChrome.apply(
            to: self,
            selected: blocksSelected,
            hovered: blocksHovered,
            pressed: blocksPressed
        )
    }
}

enum BlocksSurfaceRole: CaseIterable {
    case window
    case sidebar
    case content
    case section
    case panel
    case popover
    case interactive
    case hud

    var layer: BlocksSurfaceLayer {
        switch self {
        case .window, .sidebar, .content:
            .structure
        case .section:
            .content
        case .interactive:
            .interaction
        case .panel, .popover, .hud:
            .overlay
        }
    }

    var appKitMaterial: NSVisualEffectView.Material {
        switch self {
        case .window:
            .underWindowBackground
        case .sidebar:
            .sidebar
        case .content:
            .contentBackground
        case .section:
            .contentBackground
        case .panel, .popover, .interactive:
            .popover
        case .hud:
            .hudWindow
        }
    }

    var appKitBlendingMode: NSVisualEffectView.BlendingMode {
        switch self {
        case .window, .sidebar:
            .behindWindow
        case .content, .section, .panel, .popover, .interactive, .hud:
            .withinWindow
        }
    }

    var fallbackMaterial: Material {
        switch self {
        case .window, .sidebar, .panel, .popover, .hud:
            .regular
        case .content, .section, .interactive:
            .thin
        }
    }

    var opaqueFallbackColor: NSColor {
        switch self {
        case .content, .section, .interactive:
            .controlBackgroundColor
        case .window, .sidebar, .panel, .popover, .hud:
            .windowBackgroundColor
        }
    }

    var prefersLiquidGlass: Bool {
        switch self {
        case .panel, .popover, .hud:
            true
        case .window, .sidebar, .content, .section, .interactive:
            false
        }
    }

    var isInteractive: Bool { self == .interactive }

    func glassTintColor(
        isActive: Bool,
        isWindowActive: Bool = true,
        increasesContrast: Bool = false
    ) -> NSColor {
        let baseAlpha: CGFloat = switch self {
        case .panel, .popover:
            0.26
        case .hud:
            0.30
        case .interactive:
            0.22
        case .window, .sidebar, .content, .section:
            0.18
        }
        let alpha = min(
            0.48,
            baseAlpha
                + (increasesContrast ? 0.08 : 0)
                + (isWindowActive ? 0 : 0.03)
        )
        let baseColor: NSColor
        if isActive, isInteractive, isWindowActive {
            baseColor = NSColor.controlAccentColor.blended(
                withFraction: 0.72,
                of: .windowBackgroundColor
            ) ?? .windowBackgroundColor
        } else {
            baseColor = .windowBackgroundColor
        }
        return baseColor.withAlphaComponent(alpha)
    }

    func borderOpacity(
        isActive: Bool,
        isWindowActive: Bool,
        increasesContrast: Bool
    ) -> CGFloat {
        if self == .section {
            return increasesContrast ? 0.30 : 0
        }
        if increasesContrast {
            return isActive ? 0.48 : 0.30
        }
        if isActive {
            return isWindowActive
                ? BlocksVisualTokens.Stroke.activeOpacity
                : 0.14
        }
        return isWindowActive
            ? BlocksVisualTokens.Stroke.subtleOpacity
            : 0.10
    }

    func resolvedShadowOpacity(
        isWindowActive: Bool,
        increasesContrast: Bool
    ) -> CGFloat {
        let activityScale: CGFloat = isWindowActive ? 1 : 0.72
        let contrastScale: CGFloat = increasesContrast ? 0.82 : 1
        return shadowOpacity * activityScale * contrastScale
    }

    var shadowOpacity: CGFloat {
        switch self {
        case .panel, .popover, .hud:
            BlocksVisualTokens.Elevation.panelShadowOpacity
        case .interactive:
            BlocksVisualTokens.Elevation.interactiveShadowOpacity
        case .window, .sidebar, .content, .section:
            0
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .panel, .popover, .hud:
            BlocksVisualTokens.Elevation.panelShadowRadius
        case .interactive:
            BlocksVisualTokens.Elevation.interactiveShadowRadius
        case .window, .sidebar, .content, .section:
            0
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .panel, .popover, .hud:
            BlocksVisualTokens.Elevation.panelShadowY
        case .interactive:
            BlocksVisualTokens.Elevation.interactiveShadowY
        case .window, .sidebar, .content, .section:
            0
        }
    }

    func renderingMode(
        reduceTransparency: Bool,
        supportsLiquidGlass: Bool
    ) -> BlocksSurfaceRenderingMode {
        if self == .section {
            return .opaque
        }
        if reduceTransparency {
            return .opaque
        }
        if supportsLiquidGlass, prefersLiquidGlass {
            return .liquidGlass
        }
        return .material
    }

    func configure(_ view: NSVisualEffectView) {
        view.material = appKitMaterial
        view.blendingMode = appKitBlendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = isInteractive || self == .hud
    }
}

enum BlocksSurfaceLayer: String, CaseIterable, Sendable {
    case structure
    case content
    case interaction
    case overlay
}

enum BlocksSurfaceRenderingMode: Equatable {
    case opaque
    case liquidGlass
    case material
}

struct BlocksAppKitSurfaceConfiguration: Equatable {
    let role: BlocksSurfaceRole
    var cornerRadius: CGFloat = BlocksVisualTokens.CornerRadius.section
    var isActive = false
    var drawsShadow = true
}

/// Clips only the material/glass backing. The outer host deliberately remains
/// unmasked so its border and shadow can extend naturally beyond the surface.
@MainActor
enum BlocksAppKitSurfaceClip {
    static func apply(to view: NSView, cornerRadius: CGFloat) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

/// The only AppKit surface host used by custom Blocks chrome. SwiftUI remains
/// the state owner; this view only selects the platform-native backing surface.
@MainActor
class BlocksAppKitGlassSurfaceView: NSView {
    var blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(role: .panel) {
        didSet {
            guard blocksSurfaceConfiguration != oldValue else { return }
            rebuildBackingSurface()
        }
    }

    let blocksContentView = NSView()
    private(set) var activeRenderingMode: BlocksSurfaceRenderingMode = .material

    private var backingSurface: NSView?
    private weak var glassEffectView: NSView?
    private var accessibilityDisplayObserver: NSObjectProtocol?
    private var windowActivityObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let accessibilityDisplayObserver {
            NotificationCenter.default.removeObserver(accessibilityDisplayObserver)
        }
        windowActivityObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    override func layout() {
        super.layout()
        backingSurface?.frame = bounds
        blocksContentView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowActivity()
        updateSurfaceAppearance()
    }

    func addBlocksContentSubview(_ view: NSView) {
        blocksContentView.addSubview(view)
    }

    func updateBlocksSurface() {
        rebuildBackingSurface()
    }

    private func commonInit() {
        wantsLayer = true
        blocksContentView.autoresizingMask = [.width, .height]
        accessibilityDisplayObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildBackingSurface()
            }
        }
        rebuildBackingSurface()
    }

    private func observeWindowActivity() {
        windowActivityObservers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
        windowActivityObservers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
        ] {
            windowActivityObservers.append(
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateSurfaceAppearance()
                    }
                }
            )
        }
    }

    private func rebuildBackingSurface() {
        blocksContentView.removeFromSuperview()
        backingSurface?.removeFromSuperview()
        glassEffectView = nil

        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let mode = blocksSurfaceConfiguration.role.renderingMode(
            reduceTransparency: reduceTransparency,
            supportsLiquidGlass: {
                if #available(macOS 26.0, *) { return true }
                return false
            }()
        )
        activeRenderingMode = mode

        let nextSurface: NSView
        switch mode {
        case .opaque:
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = blocksSurfaceConfiguration.role.opaqueFallbackColor.cgColor
            view.addSubview(blocksContentView)
            nextSurface = view
        case .material:
            let view = NSVisualEffectView()
            blocksSurfaceConfiguration.role.configure(view)
            view.addSubview(blocksContentView)
            nextSurface = view
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                let glassView = NSGlassEffectView()
                glassView.style = .regular
                glassView.cornerRadius = blocksSurfaceConfiguration.cornerRadius
                BlocksAppKitSurfaceClip.apply(
                    to: glassView,
                    cornerRadius: blocksSurfaceConfiguration.cornerRadius
                )
                glassView.tintColor = blocksSurfaceConfiguration.role.glassTintColor(
                    isActive: blocksSurfaceConfiguration.isActive,
                    isWindowActive: isWindowActive,
                    increasesContrast:
                        NSWorkspace.shared
                            .accessibilityDisplayShouldIncreaseContrast
                )
                glassView.contentView = blocksContentView
                glassEffectView = glassView

                let container = NSGlassEffectContainerView()
                container.spacing = 0
                container.contentView = glassView
                glassView.frame = bounds
                glassView.autoresizingMask = [.width, .height]
                nextSurface = container
            } else {
                preconditionFailure("Liquid Glass mode requires macOS 26")
            }
        }

        nextSurface.frame = bounds
        nextSurface.autoresizingMask = [.width, .height]
        BlocksAppKitSurfaceClip.apply(
            to: nextSurface,
            cornerRadius: blocksSurfaceConfiguration.cornerRadius
        )
        super.addSubview(nextSurface)
        backingSurface = nextSurface
        updateSurfaceAppearance()
        needsLayout = true
    }

    private func updateSurfaceAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let increasesContrast =
                NSWorkspace.shared
                    .accessibilityDisplayShouldIncreaseContrast
            wantsLayer = true
            layer?.cornerRadius = blocksSurfaceConfiguration.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = false
            layer?.borderWidth = BlocksVisualTokens.Stroke.width
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(
                blocksSurfaceConfiguration.role.borderOpacity(
                    isActive: blocksSurfaceConfiguration.isActive,
                    isWindowActive: isWindowActive,
                    increasesContrast: increasesContrast
                )
            ).cgColor
            layer?.shadowColor = NSColor.shadowColor.cgColor
            layer?.shadowOpacity = blocksSurfaceConfiguration.drawsShadow
                ? Float(
                    blocksSurfaceConfiguration.role
                        .resolvedShadowOpacity(
                            isWindowActive: isWindowActive,
                            increasesContrast: increasesContrast
                        )
                )
                : 0
            layer?.shadowRadius = blocksSurfaceConfiguration.drawsShadow
                ? blocksSurfaceConfiguration.role.shadowRadius
                : 0
            layer?.shadowOffset = CGSize(
                width: 0,
                height: blocksSurfaceConfiguration.drawsShadow
                    ? -blocksSurfaceConfiguration.role.shadowY
                    : 0
            )

            if let visualEffectView = backingSurface as? NSVisualEffectView {
                blocksSurfaceConfiguration.role.configure(visualEffectView)
            }
            if #available(macOS 26.0, *) {
                (glassEffectView as? NSGlassEffectView)?.tintColor =
                    blocksSurfaceConfiguration.role.glassTintColor(
                        isActive: blocksSurfaceConfiguration.isActive,
                        isWindowActive: isWindowActive,
                        increasesContrast: increasesContrast
                    )
            }
        }
    }

    private var isWindowActive: Bool {
        guard let window else { return NSApp?.isActive ?? true }
        return window.isKeyWindow || window.isMainWindow
    }
}

struct BlocksWindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowReaderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

private struct BlocksStructuralBackground: View {
    let role: BlocksSurfaceRole
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: role.opaqueFallbackColor)
        } else {
            BlocksAppKitBackground(role: role)
        }
    }
}

private struct BlocksAppKitBackground: NSViewRepresentable {
    let role: BlocksSurfaceRole

    func makeNSView(context: Context) -> BlocksAppKitGlassSurfaceView {
        let view = BlocksAppKitGlassSurfaceView()
        view.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: role,
            cornerRadius: 0,
            drawsShadow: false
        )
        return view
    }

    func updateNSView(_ nsView: BlocksAppKitGlassSurfaceView, context: Context) {
        nsView.blocksSurfaceConfiguration = BlocksAppKitSurfaceConfiguration(
            role: role,
            cornerRadius: 0,
            drawsShadow: false
        )
    }
}

private struct BlocksMaterialSurface<SurfaceShape: Shape, Content: View>: View {
    let role: BlocksSurfaceRole
    let shape: SurfaceShape
    let contentInsets: EdgeInsets
    let isActive: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast)
    private var colorSchemeContrast
    @Environment(\.controlActiveState)
    private var controlActiveState

    @ViewBuilder
    var body: some View {
        if role == .section {
            fallbackSurface(
                paddedContent
                    .background(
                        Color(nsColor: role.opaqueFallbackColor)
                            .opacity(reduceTransparency ? 1 : 0.58),
                        in: shape
                    )
            )
                .overlay(surfaceBorder)
        } else {
            switch role.renderingMode(
                reduceTransparency: reduceTransparency,
                supportsLiquidGlass: {
                    if #available(macOS 26.0, *) { return true }
                    return false
                }()
            ) {
            case .opaque:
                fallbackSurface(
                    paddedContent
                        .background(Color(nsColor: role.opaqueFallbackColor), in: shape)
                )
                    .overlay(surfaceBorder)
            case .liquidGlass:
                if #available(macOS 26.0, *) {
                    paddedContent
                        .glassEffect(
                            liquidGlass,
                            in: shape
                        )
                } else {
                    materialFallback
                }
            case .material:
                materialFallback
            }
        }
    }

    private var paddedContent: some View {
        content.padding(contentInsets)
    }

    /// `glassEffect(_:in:)` owns its system clip. Material and opaque fallback
    /// surfaces need an explicit clip so their rectangular backing cannot show
    /// outside the requested shape in a transparent floating window.
    private func fallbackSurface<Surface: View>(_ surface: Surface) -> some View {
        surface.clipShape(shape)
    }

    @available(macOS 26.0, *)
    private var liquidGlass: Glass {
        let glass = Glass.regular.tint(
            Color(
                nsColor: role.glassTintColor(
                    isActive: isActive,
                    isWindowActive: isWindowActive,
                    increasesContrast: increasesContrast
                )
            )
        )
        return role.isInteractive ? glass.interactive() : glass
    }

    private var materialFallback: some View {
        fallbackSurface(
            paddedContent
                .background(role.fallbackMaterial, in: shape)
        )
            .overlay(surfaceBorder)
            .shadow(
                color: Color(nsColor: .shadowColor).opacity(
                    role.resolvedShadowOpacity(
                        isWindowActive: isWindowActive,
                        increasesContrast: increasesContrast
                    )
                ),
                radius: role.shadowRadius,
                y: role.shadowY
            )
    }

    private var surfaceBorder: some View {
        shape.stroke(
            Color.primary.opacity(
                role.borderOpacity(
                    isActive: isActive,
                    isWindowActive: isWindowActive,
                    increasesContrast: increasesContrast
                )
            ),
            lineWidth: BlocksVisualTokens.Stroke.width
        )
    }

    private var increasesContrast: Bool {
        colorSchemeContrast == .increased
    }

    private var isWindowActive: Bool {
        controlActiveState != .inactive
    }
}

private struct BlocksGlassContainerModifier: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct BlocksAnimationModifier<Value: Equatable>: ViewModifier {
    let role: BlocksMotionRole
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(role.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func blocksSurface(
        _ role: BlocksSurfaceRole,
        cornerRadius: CGFloat = BlocksVisualTokens.CornerRadius.section,
        padding: CGFloat = 0,
        isActive: Bool = false
    ) -> some View {
        BlocksMaterialSurface(
            role: role,
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            contentInsets: EdgeInsets(
                top: padding,
                leading: padding,
                bottom: padding,
                trailing: padding
            ),
            isActive: isActive
        ) {
            self
        }
    }

    func blocksSurface<SurfaceShape: Shape>(
        _ role: BlocksSurfaceRole,
        shape: SurfaceShape,
        contentInsets: EdgeInsets,
        isActive: Bool = false
    ) -> some View {
        BlocksMaterialSurface(
            role: role,
            shape: shape,
            contentInsets: contentInsets,
            isActive: isActive
        ) {
            self
        }
    }

    func blocksBackground(_ role: BlocksSurfaceRole) -> some View {
        background {
            BlocksStructuralBackground(role: role)
        }
    }

    func blocksGlassContainer(spacing: CGFloat = 0) -> some View {
        modifier(BlocksGlassContainerModifier(spacing: spacing))
    }

    func blocksAnimation<Value: Equatable>(
        _ role: BlocksMotionRole,
        value: Value
    ) -> some View {
        modifier(BlocksAnimationModifier(role: role, value: value))
    }

    func blocksDefaultFont(
        size: CGFloat = 13,
        weight: BlocksTypographyWeight = .regular
    ) -> some View {
        environment(\.font, BlocksTypography.font(size: size, weight: weight))
    }

    func blocksFont(
        size: CGFloat,
        weight: BlocksTypographyWeight = .regular
    ) -> some View {
        font(BlocksTypography.font(size: size, weight: weight))
    }
}

enum BlocksTypographyWeight {
    case regular
    case medium
    case semibold
    case bold

    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        }
    }
}

enum BlocksTypography {
    static func font(
        size: CGFloat,
        weight: BlocksTypographyWeight = .regular
    ) -> Font {
        .system(size: size, weight: weight.swiftUIFontWeight)
    }

    static func nsFont(
        size: CGFloat,
        weight: BlocksTypographyWeight = .regular
    ) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight.nsFontWeight)
    }
}

private extension BlocksTypographyWeight {
    var swiftUIFontWeight: Font.Weight {
        switch self {
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        }
    }
}
