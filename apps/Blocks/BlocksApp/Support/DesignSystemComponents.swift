import AppKit
import SwiftUI

enum BlocksActionButtonRole: Sendable {
  case primary
  case secondary
  case destructive
}

struct BlocksActionButton: View {
  let title: String
  var systemImage: String?
  var role: BlocksActionButtonRole = .secondary
  var isEnabled = true
  let action: () -> Void

  @ViewBuilder
  var body: some View {
    if role == .primary {
      button.buttonStyle(.borderedProminent)
    } else {
      button
        .buttonStyle(.bordered)
        .tint(role == .destructive ? Color(nsColor: .systemRed) : nil)
    }
  }

  private var button: some View {
    Button(action: action) {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    .controlSize(.regular)
    .frame(minHeight: BlocksVisualTokens.Control.standardHeight)
    .disabled(!isEnabled)
    .accessibilityLabel(title)
  }
}

struct BlocksToolbarContainer<Content: View>: View {
  let density: BlocksVisualTokens.Density
  let content: Content

  init(
    density: BlocksVisualTokens.Density = .compact,
    @ViewBuilder content: () -> Content
  ) {
    self.density = density
    self.content = content()
  }

  var body: some View {
    HStack(spacing: density.contentSpacing) {
      content
    }
    .frame(minHeight: density.controlHeight)
    .blocksSurface(
      .panel,
      cornerRadius: BlocksVisualTokens.CornerRadius.section,
      padding: BlocksVisualTokens.Spacing.xs
    )
  }
}

/// A full-width row action for settings, catalogs and other content lists.
///
/// Unlike a plain button, this component gives the whole row one consistent
/// hover, keyboard-focus and press response while keeping the feature-owned
/// label completely native. It intentionally does not animate row geometry.
struct BlocksInteractiveRowButton<Content: View>: View {
  let action: () -> Void
  let content: Content
  /// Insets by which the interaction chrome can extend beyond the label's
  /// layout bounds. The label receives matching inner padding, so its visible
  /// content does not move when a parent surface needs edge-to-edge feedback.
  let interactionSurfaceInsets: EdgeInsets
  let highlightCornerStyle: BlocksInteractiveRowHighlightCornerStyle
  let highlightCornerRadius: CGFloat
  /// Debug-only geometry identity for real NSHostingView contract tests.
  let interactionSurfaceProbeIdentifier: String?

  @State private var isHovered = false
  @FocusState private var isFocused: Bool
  @Environment(\.isEnabled) private var isEnabled

  init(
    action: @escaping () -> Void,
    interactionSurfaceInsets: EdgeInsets = EdgeInsets(),
    highlightCornerStyle: BlocksInteractiveRowHighlightCornerStyle = .all,
    highlightCornerRadius: CGFloat = BlocksVisualTokens.CornerRadius.control,
    interactionSurfaceProbeIdentifier: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.action = action
    self.interactionSurfaceInsets = interactionSurfaceInsets
    self.highlightCornerStyle = highlightCornerStyle
    self.highlightCornerRadius = highlightCornerRadius
    self.interactionSurfaceProbeIdentifier = interactionSurfaceProbeIdentifier
    self.content = content()
  }

  var body: some View {
    Button(action: action) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(interactionSurfaceInsets)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      BlocksInteractiveRowButtonStyle(
        isHovered: isHovered,
        isFocused: isFocused,
        isEnabled: isEnabled,
        cornerStyle: highlightCornerStyle,
        cornerRadius: highlightCornerRadius
      )
    )
    .blocksInteractionGeometryProbe(interactionSurfaceProbeIdentifier)
    .padding(.top, -interactionSurfaceInsets.top)
    .padding(.leading, -interactionSurfaceInsets.leading)
    .padding(.bottom, -interactionSurfaceInsets.bottom)
    .padding(.trailing, -interactionSurfaceInsets.trailing)
    .focused($isFocused)
    .onHover { isHovered = $0 }
    .blocksAnimation(.hoverFocus, value: isHovered)
    .blocksAnimation(.hoverFocus, value: isFocused)
  }
}

/// Identifies which outer corners of a full-width row highlight should follow
/// its containing surface. This keeps first, middle and last rows visually
/// continuous instead of turning every row into an inset pill.
enum BlocksInteractiveRowHighlightCornerStyle: Equatable {
  case all
  case top
  case bottom
  case none
}

private struct BlocksInteractiveRowButtonStyle: ButtonStyle {
  let isHovered: Bool
  let isFocused: Bool
  let isEnabled: Bool
  let cornerStyle: BlocksInteractiveRowHighlightCornerStyle
  let cornerRadius: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    let state: BlocksInteractionState
    if !isEnabled {
      state = .disabled
    } else if configuration.isPressed {
      state = .pressed
    } else if isFocused {
      state = .focused
    } else if isHovered {
      state = .hovered
    } else {
      state = .idle
    }

    return configuration.label
      .blocksInteractionChrome(
        state,
        cornerStyle: cornerStyle,
        cornerRadius: cornerRadius
      )
      .blocksAnimation(.press, value: configuration.isPressed)
  }
}

/// A compact visual island for closely related toolbar controls.
///
/// Feature modules provide only the controls. Spacing, padding and the
/// structural treatment stay here so screenshot, clipboard and translation
/// chrome cannot drift into separate visual systems.
struct BlocksCompactControlGroup<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(spacing: BlocksVisualTokens.Spacing.xxs) {
      content
    }
    .padding(BlocksVisualTokens.Spacing.xxs)
    .background(
      Color.primary.opacity(0.055),
      in: RoundedRectangle(
        cornerRadius: BlocksVisualTokens.CornerRadius.control,
        style: .continuous
      )
    )
  }
}

/// A compact labeled selection control for status strips and dense filters.
///
/// The caller owns semantic focus routing; the component owns every visual
/// interaction state so selected backgrounds, strokes and clipping stay
/// consistent across feature modules.
struct BlocksSelectableChip: View {
  let title: String
  let systemImage: String
  var isSelected = false
  var isFocused = false
  var isEnabled = true
  var showsHelp = true
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    Button(action: action) {
      HStack(spacing: BlocksVisualTokens.Spacing.xs) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .medium))
        Text(title)
          .font(.system(size: BlocksVisualTokens.Typography.caption, weight: .medium))
          .lineLimit(1)
      }
      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      .padding(.horizontal, BlocksVisualTokens.Spacing.sm)
      .frame(height: BlocksVisualTokens.Control.compactHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      BlocksSelectableControlStyle(
        isSelected: isSelected,
        isFocused: isFocused,
        isHovered: isHovered,
        isEnabled: isEnabled,
        increasesContrast: colorSchemeContrast == .increased
      )
    )
    .frame(minHeight: BlocksVisualTokens.Control.compactHeight)
    .onHover { isHovered = $0 }
    .disabled(!isEnabled)
    .modifier(BlocksOptionalHelpModifier(label: title, isEnabled: showsHelp))
    .accessibilityLabel(title)
    .accessibilityRemoveTraits(.isSelected)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .blocksAnimation(.hoverFocus, value: isHovered)
    .blocksAnimation(.selection, value: isSelected)
    .blocksAnimation(.hoverFocus, value: isFocused)
  }

}

/// A larger selectable control for compact tool grids and choosers.
struct BlocksSelectableTile: View {
  let title: String
  let systemImage: String
  var isSelected = false
  var isFocused = false
  var isEnabled = true
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    Button(action: action) {
      VStack(spacing: BlocksVisualTokens.Spacing.xs) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .medium))
        Text(title)
          .font(.caption2)
          .lineLimit(1)
      }
      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      .frame(maxWidth: .infinity, minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      BlocksSelectableControlStyle(
        isSelected: isSelected,
        isFocused: isFocused,
        isHovered: isHovered,
        isEnabled: isEnabled,
        increasesContrast: colorSchemeContrast == .increased
      )
    )
    .onHover { isHovered = $0 }
    .disabled(!isEnabled)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityRemoveTraits(.isSelected)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .blocksAnimation(.hoverFocus, value: isHovered)
    .blocksAnimation(.selection, value: isSelected)
    .blocksAnimation(.hoverFocus, value: isFocused)
  }
}

struct BlocksSelectableControlStyle: ButtonStyle {
  let isSelected: Bool
  let isFocused: Bool
  let isHovered: Bool
  let isEnabled: Bool
  let increasesContrast: Bool

  func makeBody(configuration: Configuration) -> some View {
    let appearance = BlocksInteractionAppearance.resolve(
      interactionState(isPressed: configuration.isPressed),
      increasesContrast: increasesContrast
    )
    let shape = RoundedRectangle(
      cornerRadius: BlocksVisualTokens.CornerRadius.control,
      style: .continuous
    )
    configuration.label
      .opacity(appearance.contentOpacity)
      .background {
        shape.fill(
          (isSelected ? Color.accentColor : Color.primary)
            .opacity(appearance.fillOpacity)
        )
      }
      .overlay {
        shape.stroke(
          (isSelected || isFocused ? Color.accentColor : Color.primary)
            .opacity(appearance.borderOpacity),
          lineWidth: BlocksVisualTokens.Stroke.width
        )
      }
      .clipShape(shape)
  }

  private func interactionState(isPressed: Bool) -> BlocksInteractionState {
    if !isEnabled { return .disabled }
    if isPressed { return .pressed }
    if isSelected { return .selected }
    if isFocused { return .focused }
    if isHovered { return .hovered }
    return .idle
  }
}

struct BlocksInteractionChromeModifier: ViewModifier {
  let state: BlocksInteractionState
  let cornerStyle: BlocksInteractiveRowHighlightCornerStyle
  let cornerRadius: CGFloat

  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  func body(content: Content) -> some View {
    let appearance = BlocksInteractionAppearance.resolve(
      state,
      increasesContrast: colorSchemeContrast == .increased
    )
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: cornerStyle.includesTop ? cornerRadius : 0,
      bottomLeadingRadius: cornerStyle.includesBottom ? cornerRadius : 0,
      bottomTrailingRadius: cornerStyle.includesBottom ? cornerRadius : 0,
      topTrailingRadius: cornerStyle.includesTop ? cornerRadius : 0,
      style: .continuous
    )
    let usesAccent = state == .selected || state == .focused

    content
      .opacity(appearance.contentOpacity)
      .overlay {
        shape
          .fill((usesAccent ? Color.accentColor : Color.primary).opacity(appearance.fillOpacity))
          .allowsHitTesting(false)
      }
      .overlay {
        shape
          .stroke(
            (usesAccent ? Color.accentColor : Color.primary).opacity(appearance.borderOpacity),
            lineWidth: BlocksVisualTokens.Stroke.width
          )
          .allowsHitTesting(false)
      }
      .clipShape(shape)
  }
}

extension View {
  func blocksInteractionChrome(
    _ state: BlocksInteractionState,
    cornerStyle: BlocksInteractiveRowHighlightCornerStyle = .all,
    cornerRadius: CGFloat = BlocksVisualTokens.CornerRadius.control
  ) -> some View {
    modifier(
      BlocksInteractionChromeModifier(
        state: state,
        cornerStyle: cornerStyle,
        cornerRadius: cornerRadius
      )
    )
  }
}

private extension BlocksInteractiveRowHighlightCornerStyle {
  var includesTop: Bool {
    self == .all || self == .top
  }

  var includesBottom: Bool {
    self == .all || self == .bottom
  }
}

#if DEBUG
private struct BlocksInteractionGeometryProbeReporterKey: EnvironmentKey {
  static let defaultValue: ((String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
  var blocksInteractionGeometryProbeReporter: ((String, CGRect) -> Void)? {
    get { self[BlocksInteractionGeometryProbeReporterKey.self] }
    set { self[BlocksInteractionGeometryProbeReporterKey.self] = newValue }
  }
}

private struct BlocksInteractionGeometryProbe: NSViewRepresentable {
  let identifier: String
  let reporter: (String, CGRect) -> Void

  func makeNSView(context: Context) -> BlocksInteractionGeometryProbeNSView {
    BlocksInteractionGeometryProbeNSView(identifier: identifier, reporter: reporter)
  }

  func updateNSView(
    _ nsView: BlocksInteractionGeometryProbeNSView,
    context: Context
  ) {
    nsView.probeIdentifier = identifier
    nsView.reporter = reporter
    nsView.needsLayout = true
  }
}

private struct BlocksInteractionGeometryProbeModifier: ViewModifier {
  let identifier: String?
  @Environment(\.blocksInteractionGeometryProbeReporter) private var reporter

  @ViewBuilder
  func body(content: Content) -> some View {
    if let identifier, let reporter {
      content.background(
        BlocksInteractionGeometryProbe(identifier: identifier, reporter: reporter)
      )
    } else {
      content
    }
  }
}

private final class BlocksInteractionGeometryProbeNSView: NSView {
  var probeIdentifier: String
  var reporter: ((String, CGRect) -> Void)?

  init(identifier: String, reporter: @escaping (String, CGRect) -> Void) {
    self.probeIdentifier = identifier
    self.reporter = reporter
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    guard let window else { return }
    reporter?(probeIdentifier, window.convertToScreen(convert(bounds, to: nil)))
  }
}

extension View {
  func blocksInteractionGeometryProbe(_ identifier: String?) -> some View {
    modifier(BlocksInteractionGeometryProbeModifier(identifier: identifier))
  }

  func blocksInteractionGeometryProbeReporter(
    _ reporter: @escaping (String, CGRect) -> Void
  ) -> some View {
    environment(\.blocksInteractionGeometryProbeReporter, reporter)
  }
}
#else
extension View {
  func blocksInteractionGeometryProbe(_: String?) -> some View { self }
}
#endif

struct BlocksPanelChrome<Title: View, Actions: View>: View {
  let title: Title
  let actions: Actions

  init(
    @ViewBuilder title: () -> Title,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title()
    self.actions = actions()
  }

  var body: some View {
    HStack(spacing: BlocksVisualTokens.Spacing.sm) {
      title.frame(maxWidth: .infinity, alignment: .leading)
      actions
    }
    .frame(
      maxWidth: .infinity,
      minHeight: BlocksVisualTokens.Control.standardHeight,
      alignment: .center
    )
    .padding(.horizontal, BlocksVisualTokens.Spacing.md)
  }
}

enum BlocksStateViewKind: Sendable {
  case loading
  case empty
  case information
  case success
  case warning
  case error

  var systemImage: String {
    switch self {
    case .loading: "clock.arrow.circlepath"
    case .empty: "tray"
    case .information: "info.circle"
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    }
  }

  var color: Color {
    switch self {
    case .loading, .empty: .secondary
    case .information: .accentColor
    case .success: Color(nsColor: .systemGreen)
    case .warning: Color(nsColor: .systemOrange)
    case .error: Color(nsColor: .systemRed)
    }
  }
}

struct BlocksStateView: View {
  let kind: BlocksStateViewKind
  let title: String
  var detail: String?
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: BlocksVisualTokens.Spacing.sm) {
      if kind == .loading {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: kind.systemImage)
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(kind.color)
      }
      Text(title)
        .font(.headline)
        .multilineTextAlignment(.center)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let actionTitle, let action {
        BlocksActionButton(
          title: actionTitle,
          role: .secondary,
          action: action
        )
      }
    }
    .frame(maxWidth: .infinity, minHeight: 132, alignment: .center)
    .padding(BlocksVisualTokens.Spacing.lg)
    .accessibilityElement(children: .contain)
  }
}

/// A shared immediate tooltip host for dense toolbars and canvas chrome.
///
/// The tooltip lives in its own nonactivating child panel so it is never
/// clipped by a scroll view or compact toolbar. Feature modules own only the
/// label and anchor; dismissal, screen clamping, focus isolation and visual
/// treatment remain a single global contract.
@MainActor
final class BlocksImmediateTooltipHostModel: ObservableObject {
  weak var ownerWindow: NSWindow?
  private var panel: NSPanel?
  private var mouseDownMonitor: Any?
  private var windowResignObserver: NSObjectProtocol?
  private var applicationResignObserver: NSObjectProtocol?

  func show(label: String, anchor: NSView?) {
    guard let anchor, let ownerWindow = anchor.window ?? ownerWindow else { return }
    let panel = panel ?? makePanel()
    let content = NSHostingView(rootView: BlocksImmediateTooltipBubble(label: label))
    content.frame.size = content.fittingSize
    panel.contentView = content
    panel.setContentSize(content.fittingSize)
    if panel.parent !== ownerWindow {
      panel.parent?.removeChildWindow(panel)
      ownerWindow.addChildWindow(panel, ordered: .above)
    }
    panel.level = NSWindow.Level(rawValue: ownerWindow.level.rawValue + 1)

    let windowRect = anchor.convert(anchor.bounds, to: nil)
    let screenAnchor = ownerWindow.convertToScreen(windowRect)
    let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(screenAnchor) })?.visibleFrame
      ?? ownerWindow.screen?.visibleFrame
      ?? screenAnchor.insetBy(dx: -200, dy: -200)
    let size = content.fittingSize
    let preferredAbove = CGPoint(
      x: screenAnchor.midX - size.width / 2,
      y: screenAnchor.maxY + BlocksVisualTokens.Spacing.xs + 1
    )
    let preferredBelow = CGPoint(
      x: screenAnchor.midX - size.width / 2,
      y: screenAnchor.minY - size.height - BlocksVisualTokens.Spacing.xs - 1
    )
    let preferredY = preferredAbove.y + size.height <= visibleFrame.maxY
      ? preferredAbove.y
      : preferredBelow.y
    panel.setFrameOrigin(
      CGPoint(
        x: min(
          max(preferredAbove.x, visibleFrame.minX + BlocksVisualTokens.Spacing.xs),
          visibleFrame.maxX - size.width - BlocksVisualTokens.Spacing.xs
        ),
        y: min(
          max(preferredY, visibleFrame.minY + BlocksVisualTokens.Spacing.xs),
          visibleFrame.maxY - size.height - BlocksVisualTokens.Spacing.xs
        )
      )
    )
    panel.orderFrontRegardless()
    installDismissalObservers(for: ownerWindow)
  }

  func hide() {
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    removeDismissalObservers()
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    BlocksFloatingPanelWindowRole.tooltip.apply(to: panel)
    self.panel = panel
    return panel
  }

  private func installDismissalObservers(for ownerWindow: NSWindow) {
    removeDismissalObservers()
    mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      self?.hide()
      return event
    }
    windowResignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: ownerWindow,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.hide() }
    }
    applicationResignObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.hide() }
    }
  }

  private func removeDismissalObservers() {
    if let mouseDownMonitor {
      NSEvent.removeMonitor(mouseDownMonitor)
      self.mouseDownMonitor = nil
    }
    if let windowResignObserver {
      NotificationCenter.default.removeObserver(windowResignObserver)
      self.windowResignObserver = nil
    }
    if let applicationResignObserver {
      NotificationCenter.default.removeObserver(applicationResignObserver)
      self.applicationResignObserver = nil
    }
  }
}

private struct BlocksImmediateTooltipModifier: ViewModifier {
  let label: String
  let isEnabled: Bool
  @StateObject private var tooltipAnchor = BlocksTooltipAnchor()
  @Environment(\.blocksImmediateTooltipHost) private var tooltipHost

  func body(content: Content) -> some View {
    content
      .background(BlocksTooltipAnchorReader(anchor: tooltipAnchor))
      .onHover { hovering in
        if hovering, isEnabled {
          tooltipHost?.show(label: label, anchor: tooltipAnchor.view)
        } else {
          tooltipHost?.hide()
        }
      }
      .onDisappear { tooltipHost?.hide() }
  }
}

extension View {
  func blocksImmediateTooltip(_ label: String, isEnabled: Bool = true) -> some View {
    modifier(BlocksImmediateTooltipModifier(label: label, isEnabled: isEnabled))
  }

  func blocksImmediateTooltipHost() -> some View {
    modifier(BlocksImmediateTooltipHostModifier())
  }
}

private struct BlocksImmediateTooltipBubble: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: BlocksVisualTokens.Typography.caption, weight: .medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, BlocksVisualTokens.Spacing.sm - 1)
      .padding(.vertical, BlocksVisualTokens.Spacing.xs)
      .blocksSurface(
        .panel,
        cornerRadius: BlocksVisualTokens.CornerRadius.small
      )
      .fixedSize()
  }
}

@MainActor
private final class BlocksTooltipAnchor: ObservableObject {
  weak var view: NSView?
}

private struct BlocksTooltipAnchorReader: NSViewRepresentable {
  let anchor: BlocksTooltipAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    anchor.view = view
  }
}

private struct BlocksImmediateTooltipHostKey: EnvironmentKey {
  static let defaultValue: BlocksImmediateTooltipHostModel? = nil
}

extension EnvironmentValues {
  var blocksImmediateTooltipHost: BlocksImmediateTooltipHostModel? {
    get { self[BlocksImmediateTooltipHostKey.self] }
    set { self[BlocksImmediateTooltipHostKey.self] = newValue }
  }
}

private struct BlocksImmediateTooltipHostModifier: ViewModifier {
  @StateObject private var model = BlocksImmediateTooltipHostModel()

  func body(content: Content) -> some View {
    content
      .environment(\.blocksImmediateTooltipHost, model)
      .background(BlocksTooltipWindowReader(model: model))
      .onDisappear { model.hide() }
  }
}

private struct BlocksTooltipWindowReader: NSViewRepresentable {
  let model: BlocksImmediateTooltipHostModel

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onWindowChanged = { [weak model] window in model?.ownerWindow = window }
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {
    view.onWindowChanged = { [weak model] window in model?.ownerWindow = window }
    model.ownerWindow = view.window
  }

  final class ReaderView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChanged?(window)
    }
  }
}

enum BlocksDesignSystemGalleryCatalog {
  static let interactionStates = BlocksInteractionState.allCases
  static let surfaceLayers = BlocksSurfaceLayer.allCases
  static let densities = BlocksVisualTokens.Density.allCases
  static let localizationSamples = [
    "Settings",
    "设置与交互状态示例",
    "設定とインタラクション状態の長い例",
  ]
}

#if DEBUG
  struct BlocksDesignSystemGallery: View {
    @State private var toggleValue = true
    @State private var selection = 0

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xl) {
          galleryHeader
          tokenScale
          actionExamples
          interactionExamples
          stateExamples
          formExamples
          localizationExamples
        }
        .padding(BlocksVisualTokens.Spacing.xl)
        .frame(maxWidth: 920, alignment: .leading)
      }
      .blocksBackground(.content)
    }

    private var galleryHeader: some View {
      VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.xs) {
        Text("Blocks Design System Gallery").font(.title2.weight(.semibold))
        Text(
          "Tokens, components, interaction states, accessibility fallbacks, and localization pressure tests."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }

    private var tokenScale: some View {
      gallerySection("Spacing and surfaces") {
        HStack(alignment: .bottom, spacing: BlocksVisualTokens.Spacing.sm) {
          ForEach([2, 4, 8, 12, 16, 24, 32], id: \.self) { value in
            RoundedRectangle(
              cornerRadius: BlocksVisualTokens.CornerRadius.small,
              style: .continuous
            )
            .fill(.tint)
            .frame(width: CGFloat(value), height: CGFloat(value))
            .accessibilityLabel("Spacing \(value) points")
          }
        }
      }
    }

    private var actionExamples: some View {
      gallerySection("Actions") {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
          BlocksActionButton(title: "Primary", role: .primary) {}
          BlocksActionButton(title: "Secondary") {}
          BlocksActionButton(title: "Delete", role: .destructive) {}
          BlocksCompactActionGroup {
            BlocksCompactIconButton(systemImage: "doc.on.doc", label: "Copy") {}
            BlocksCompactIconButton(systemImage: "info.circle", label: "Information") {}
          }
          BlocksSelectableChip(
            title: "Selected",
            systemImage: "checkmark.circle",
            isSelected: true
          ) {}
          BlocksSelectableTile(
            title: "Tool",
            systemImage: "rectangle.and.pencil.and.ellipsis",
            isSelected: true
          ) {}
          .frame(width: 84)
        }
      }
    }

    private var interactionExamples: some View {
      gallerySection("Interaction states") {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 116))],
          alignment: .leading,
          spacing: BlocksVisualTokens.Spacing.sm
        ) {
          ForEach(BlocksDesignSystemGalleryCatalog.interactionStates, id: \.self) { state in
            let appearance = BlocksInteractionAppearance.resolve(state)
            Text(state.rawValue)
              .frame(maxWidth: .infinity, minHeight: 36)
              .opacity(appearance.contentOpacity)
              .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.control,
                isActive: state == .selected || state == .focused
              )
          }
        }
      }
    }

    private var stateExamples: some View {
      gallerySection("Content states") {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220))],
          spacing: BlocksVisualTokens.Spacing.sm
        ) {
          BlocksStateView(
            kind: .loading, title: "Loading", detail: "The stable region does not change size.")
          BlocksStateView(kind: .empty, title: "No items", detail: "Create an item to get started.")
          BlocksStateView(
            kind: .error,
            title: "Could not load",
            detail: "The reason and next action remain explicit.",
            actionTitle: "Retry",
            action: {}
          )
        }
      }
    }

    private var formExamples: some View {
      gallerySection("Native controls") {
        VStack(spacing: BlocksVisualTokens.Spacing.sm) {
          Toggle("Enabled", isOn: $toggleValue)
          Picker("Mode", selection: $selection) {
            Text("Automatic").tag(0)
            Text("Manual").tag(1)
          }
          .pickerStyle(.segmented)
        }
        .frame(maxWidth: 360, alignment: .leading)
      }
    }

    private var localizationExamples: some View {
      gallerySection("Localization pressure") {
        VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.sm) {
          ForEach(BlocksDesignSystemGalleryCatalog.localizationSamples, id: \.self) { sample in
            Text(sample).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }

    private func gallerySection<Content: View>(
      _ title: String,
      @ViewBuilder content: () -> Content
    ) -> some View {
      VStack(alignment: .leading, spacing: BlocksVisualTokens.Spacing.md) {
        Text(title).font(.headline)
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
#endif
