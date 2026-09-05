import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let initialSection: AppSection?

    init(initialSection: AppSection? = nil) {
        self.initialSection = initialSection
    }

    var body: some View {
        SettingsNavigationShell(initialSection: initialSection)
            .onAppear {
                appModel.configureMainWindowOpener {
                    openWindow(id: "main")
                }
                appModel.refreshPermissionState()
                appModel.registerDefaultShortcuts()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                appModel.refreshPermissionState()
                appModel.registerDefaultShortcuts()
            }
    }
}

struct SettingsNavigationShell: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var routeStateStore = SettingsRouteStateStore()

    let initialSection: AppSection?

    init(initialSection: AppSection? = nil) {
        self.initialSection = initialSection
    }

    var body: some View {
        NavigationSplitView {
            SettingsNativeSidebar(
                selection: sidebarSelection,
                navigationGeneration: appModel.mainWindowNavigationGeneration,
                onUserSelection: { section in
                    routeStateStore.requestFocusRestorationForSidebarSelection(
                        of: section.settingsViewMode
                    )
                }
            )
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 248)
        } detail: {
            ZStack(alignment: .topLeading) {
                SettingsShellView(mode: appModel.selectedSection.settingsViewMode)
                    .environmentObject(routeStateStore)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .blocksBackground(.content)
        }
        .navigationSplitViewStyle(.balanced)
        .blocksBackground(.window)
        .background {
            ZStack {
                BlocksWindowGlassConfigurator()
                    .allowsHitTesting(false)
                AppleTranslationPreparationHost(
                    controller:
                        AppleTranslationLanguagePackController.shared
                            .preparationController
                )
            }
        }
        .onAppear {
            guard let initialSection else { return }
            appModel.selectedSection = initialSection
        }
    }

    private var sidebarSelection: Binding<AppSection?> {
        Binding {
            appModel.selectedSection == .clipboardPrivacy
                ? .clipboardSettings
                : appModel.selectedSection
        } set: { section in
            guard let section else { return }
            guard appModel.selectedSection != section else { return }
            // List(selection:) may invoke its setter while SwiftUI is still
            // reconciling the sidebar row. Publish navigation on the next main
            // actor turn to avoid mutating AppModel during a view update.
            Task { @MainActor in
                guard appModel.selectedSection != section else { return }
                appModel.selectedSection = section
            }
        }
    }
}

private struct SettingsNativeSidebar: View {
    @Binding var selection: AppSection?
    let navigationGeneration: UInt64
    let onUserSelection: (AppSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsSidebarBrandHeader()
            SettingsSourceListBridge(
                selection: $selection,
                navigationGeneration: navigationGeneration,
                onUserSelection: onUserSelection
            )
        }
        .blocksBackground(.sidebar)
    }
}

enum SettingsSidebarGroupID: String, CaseIterable {
    case tools
    case system
    case intelligence
    case data
    case app
}

struct SettingsSidebarGroupDescriptor: Equatable {
    let id: SettingsSidebarGroupID
    let localizationKey: String
    let sections: [AppSection]

    var title: String {
        L10n.string(localizationKey)
    }
}

enum SettingsSidebarSourceListModel {
    static var groups: [SettingsSidebarGroupDescriptor] {
        [
            SettingsSidebarGroupDescriptor(
                id: .tools,
                localizationKey: "sidebar.group.tools",
                sections: [
                    .screenshot,
                    .clipboardSettings,
                    .translationSettings,
                    .translationFavorites,
                ]
            ),
            SettingsSidebarGroupDescriptor(
                id: .system,
                localizationKey: "sidebar.group.system",
                sections: [
                    .shortcuts,
                    .permissions,
                ]
            ),
            SettingsSidebarGroupDescriptor(
                id: .intelligence,
                localizationKey: "sidebar.group.intelligence",
                sections: intelligenceSections
            ),
            SettingsSidebarGroupDescriptor(
                id: .data,
                localizationKey: "sidebar.group.data",
                sections: [
                    .dataAudit,
                ]
            ),
            SettingsSidebarGroupDescriptor(
                id: .app,
                localizationKey: "sidebar.group.app",
                sections: [
                    .settings,
                ]
            ),
        ]
    }

    private static var intelligenceSections: [AppSection] {
        if DistributionChannel.current.supportsCLIAndActionBroker {
            [.providers, .agentCLI, .hooks]
        } else {
            [.providers, .hooks]
        }
    }

    static var sections: [AppSection] {
        groups.flatMap(\.sections)
    }

    static var localizationSignature: String {
        groups.map { group in
            ([group.title] + group.sections.map(\.title)).joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }
}

struct SettingsSourceListBridge: NSViewRepresentable {
    @Binding var selection: AppSection?
    let navigationGeneration: UInt64
    let onUserSelection: (AppSection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onUserSelection: onUserSelection)
    }

    func makeNSView(context: Context) -> SettingsSourceListNativeView {
        let sourceList = SettingsSourceListNativeView()
        sourceList.onSelectionChange = { [weak coordinator = context.coordinator] section in
            coordinator?.didSelect(section)
        }
        context.coordinator.sourceList = sourceList
        sourceList.update(
            selection: selection,
            navigationGeneration: navigationGeneration
        )
        return sourceList
    }

    func updateNSView(_ sourceList: SettingsSourceListNativeView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.onUserSelection = onUserSelection
        sourceList.update(
            selection: selection,
            navigationGeneration: navigationGeneration
        )
    }

    @MainActor
    final class Coordinator {
        var selection: Binding<AppSection?>
        var onUserSelection: (AppSection) -> Void
        weak var sourceList: SettingsSourceListNativeView?

        init(
            selection: Binding<AppSection?>,
            onUserSelection: @escaping (AppSection) -> Void
        ) {
            self.selection = selection
            self.onUserSelection = onUserSelection
        }

        func didSelect(_ section: AppSection) {
            guard selection.wrappedValue != section else { return }
            onUserSelection(section)
            selection.wrappedValue = section
        }
    }
}

@MainActor
final class SettingsSourceListNativeView: NSView {
    private let scrollView = SettingsSourceListScrollView()
    private let outlineView = NSOutlineView()
    private let dataController = SettingsSourceListDataController()
    private var localizationSignature = ""
    private var requestedSelection: AppSection?
    private var appliedNavigationGeneration: UInt64 = 0
    private var visibilityGeneration = 0
    private var isApplyingSelection = false

    var onSelectionChange: ((AppSection) -> Void)?

    var routeCount: Int {
        dataController.routeNodes.count
    }

    var groupCount: Int {
        dataController.groupNodes.count
    }

    var selectedSection: AppSection? {
        dataController.routeNode(at: outlineView.selectedRow)?.section
    }

    var rowCount: Int {
        outlineView.numberOfRows
    }

    var documentWidth: CGFloat {
        outlineView.frame.width
    }

    var groupRowsFloat: Bool {
        outlineView.floatsGroupRows
    }

    var horizontalScrollOffset: CGFloat {
        scrollView.contentView.bounds.origin.x
    }

    var horizontalScrollingIsDisabled: Bool {
        !scrollView.hasHorizontalScroller
            && scrollView.horizontalScrollElasticity == .none
            && scrollView.usesPredominantAxisScrolling
            && scrollView.contentView is SettingsVerticalOnlyClipView
    }

    var verticalScrollIndicatorIsHidden: Bool {
        !scrollView.hasVerticalScroller
    }

    var selectedRowIsVisible: Bool {
        guard outlineView.selectedRow >= 0 else { return false }
        return outlineView.visibleRect.intersects(outlineView.rect(ofRow: outlineView.selectedRow))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        sizeDocumentToViewport()
    }

    func update(
        selection: AppSection?,
        navigationGeneration: UInt64 = 0
    ) {
        let currentSignature = SettingsSidebarSourceListModel.localizationSignature
        if currentSignature != localizationSignature {
            localizationSignature = currentSignature
            reloadSourceList()
        }

        requestedSelection = selection
        applySelection(selection)
        if appliedNavigationGeneration != navigationGeneration {
            appliedNavigationGeneration = navigationGeneration
            scrollSelectionToVisible()
        }
    }

    func isSelectable(row: Int) -> Bool {
        dataController.routeNode(at: row) != nil
    }

    func section(at row: Int) -> AppSection? {
        dataController.routeNode(at: row)?.section
    }

    func accessibilityRole(at row: Int) -> NSAccessibility.Role? {
        guard row >= 0, row < outlineView.numberOfRows else {
            return nil
        }
        return outlineView
            .view(atColumn: 0, row: row, makeIfNecessary: true)?
            .accessibilityRole()
    }

    func rowFrame(for section: AppSection) -> NSRect? {
        guard let row = row(for: section), row >= 0 else { return nil }
        return outlineView.rect(ofRow: row)
    }

    func scrollSelectionToVisible() {
        guard let requestedSelection,
              let row = row(for: requestedSelection),
              row >= 0 else {
            return
        }
        guard !outlineView.visibleRect.intersects(outlineView.rect(ofRow: row)) else {
            return
        }
        outlineView.scrollRowToVisible(row)
    }

    private func configure() {
        wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings.sourceList"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .medium
        outlineView.rowHeight = 30
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
        outlineView.indentationPerLevel = 8
        outlineView.autoresizesOutlineColumn = true
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = false
        outlineView.focusRingType = .default
        outlineView.dataSource = dataController
        outlineView.delegate = dataController
        outlineView.setAccessibilityLabel(L10n.string("settings.navigation.accessibilityLabel"))

        dataController.onSelectionChange = { [weak self] section in
            guard let self else { return }
            guard !isApplyingSelection else { return }
            requestedSelection = section
            onSelectionChange?(section)
        }

        scrollView.contentView = SettingsVerticalOnlyClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = outlineView
        scrollView.viewportDidChange = { [weak self] in
            self?.scheduleSelectionVisibility()
        }
        addSubview(scrollView)

        reloadSourceList()
    }

    private func reloadSourceList() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        outlineView.setAccessibilityLabel(L10n.string("settings.navigation.accessibilityLabel"))
        outlineView.reloadData()
        dataController.groupNodes.forEach { group in
            outlineView.expandItem(group)
        }
        sizeDocumentToViewport()
        applySelection(requestedSelection)
    }

    private func applySelection(_ selection: AppSection?) {
        guard let selection,
              let row = row(for: selection),
              row >= 0 else {
            return
        }
        if outlineView.selectedRow != row {
            let wasApplyingSelection = isApplyingSelection
            isApplyingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isApplyingSelection = wasApplyingSelection
        }
        scheduleSelectionVisibility()
    }

    private func row(for section: AppSection) -> Int? {
        guard let node = dataController.routeNodes[section] else { return nil }
        return outlineView.row(forItem: node)
    }

    private func sizeDocumentToViewport() {
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let contentHeight: CGFloat
        if outlineView.numberOfRows > 0 {
            contentHeight = max(viewport.height, outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY)
        } else {
            contentHeight = viewport.height
        }
        let targetFrame = NSRect(
            x: 0,
            y: 0,
            width: viewport.width,
            height: contentHeight
        )
        if outlineView.frame != targetFrame {
            outlineView.frame = targetFrame
        }
        if let column = outlineView.tableColumns.first,
           abs(column.width - viewport.width) > 0.5 {
            column.width = viewport.width
        }
        if scrollView.contentView.bounds.origin.x != 0 {
            var origin = scrollView.contentView.bounds.origin
            origin.x = 0
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func scheduleSelectionVisibility() {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  generation == visibilityGeneration else {
                return
            }
            scrollSelectionToVisible()
        }
    }
}

@MainActor
private final class SettingsSourceListScrollView: NSScrollView {
    var viewportDidChange: (() -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        viewportDidChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewportDidChange?()
    }
}

/// Keeps Source List navigation on a single vertical axis even for diagonal
/// trackpad gestures and momentum updates. Hiding a horizontal scroller and
/// disabling elasticity alone does not prevent AppKit from proposing a
/// transient horizontal clip-view origin.
@MainActor
final class SettingsVerticalOnlyClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = 0
        return constrained
    }
}

@MainActor
private final class SettingsSidebarGroupNode: NSObject {
    let descriptor: SettingsSidebarGroupDescriptor
    let children: [SettingsSidebarRouteNode]

    init(descriptor: SettingsSidebarGroupDescriptor) {
        self.descriptor = descriptor
        children = descriptor.sections.map(SettingsSidebarRouteNode.init)
    }
}

@MainActor
private final class SettingsSidebarRouteNode: NSObject {
    let section: AppSection

    init(section: AppSection) {
        self.section = section
    }
}

@MainActor
private final class SettingsSourceListDataController: NSObject,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    let groupNodes = SettingsSidebarSourceListModel.groups.map(SettingsSidebarGroupNode.init)
    lazy var routeNodes: [AppSection: SettingsSidebarRouteNode] = {
        Dictionary(
            uniqueKeysWithValues: groupNodes.flatMap(\.children).map { ($0.section, $0) }
        )
    }()

    var onSelectionChange: ((AppSection) -> Void)?

    func routeNode(at row: Int) -> SettingsSidebarRouteNode? {
        guard row >= 0,
              let outlineView,
              row < outlineView.numberOfRows else {
            return nil
        }
        return outlineView.item(atRow: row) as? SettingsSidebarRouteNode
    }

    private weak var outlineView: NSOutlineView?

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        self.outlineView = outlineView
        if let group = item as? SettingsSidebarGroupNode {
            return group.children.count
        }
        return item == nil ? groupNodes.count : 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if let group = item as? SettingsSidebarGroupNode {
            return group.children[index]
        }
        return groupNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SettingsSidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SettingsSidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SettingsSidebarRouteNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        item is SettingsSidebarGroupNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        item is SettingsSidebarGroupNode ? 24 : 30
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let group = item as? SettingsSidebarGroupNode {
            let identifier = NSUserInterfaceItemIdentifier("settings.sourceList.group")
            let cell = (
                outlineView.makeView(withIdentifier: identifier, owner: self)
                    as? SettingsSidebarGroupCell
            ) ?? SettingsSidebarGroupCell(identifier: identifier)
            cell.update(title: group.descriptor.title)
            return cell
        }

        guard let route = item as? SettingsSidebarRouteNode else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("settings.sourceList.route")
        let cell = (
            outlineView.makeView(withIdentifier: identifier, owner: self)
                as? SettingsSidebarRouteCell
        ) ?? SettingsSidebarRouteCell(identifier: identifier)
        cell.update(section: route.section)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView,
              let route = routeNode(at: outlineView.selectedRow) else {
            return
        }
        onSelectionChange?(route.section)
    }
}

@MainActor
private final class SettingsSidebarGroupCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(title: String) {
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
    }

    private func configure() {
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

@MainActor
private final class SettingsSidebarRouteCell: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(section: AppSection) {
        symbolView.image = NSImage(
            systemSymbolName: section.systemImage,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        symbolView.contentTintColor = NSColor(section.iconColor)
        titleLabel.stringValue = section.title
        titleLabel.setAccessibilityLabel(section.title)
    }

    private func configure() {
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.setAccessibilityElement(false)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        imageView = symbolView
        textField = titleLabel
        addSubview(symbolView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private struct SettingsSidebarBrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("app.name"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.string("sidebar.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

extension AppSection {
    var settingsViewMode: SettingsViewMode {
        switch self {
        case .screenshot:
            .screenshot
        case .clipboardSettings:
            .clipboard
        case .clipboardPrivacy:
            .clipboardPrivacy
        case .translationSettings:
            .translation
        case .translationFavorites:
            .translationFavorites
        case .shortcuts:
            .shortcuts
        case .permissions:
            .permissions
        case .providers:
            .providers
        case .agentCLI:
            .agentCLI
        case .hooks:
            .hooks
        case .dataAudit:
            .dataAudit
        case .settings:
            .general
        }
    }
}

extension SettingsViewMode {
    var appSection: AppSection? {
        switch self {
        case .general:
            .settings
        case .screenshot:
            .screenshot
        case .clipboard:
            .clipboardSettings
        case .clipboardPrivacy:
            .clipboardPrivacy
        case .translation:
            .translationSettings
        case .translationFavorites:
            .translationFavorites
        case .shortcuts:
            .shortcuts
        case .providers:
            .providers
        case .agentCLI:
            .agentCLI
        case .hooks:
            .hooks
        case .dataAudit:
            .dataAudit
        case .permissions:
            .permissions
        }
    }
}
