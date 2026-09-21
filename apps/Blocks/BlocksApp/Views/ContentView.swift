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
    @EnvironmentObject private var pluginManager: BlocksNativePluginManager
    @StateObject private var routeStateStore = SettingsRouteStateStore()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    let initialSection: AppSection?

    init(initialSection: AppSection? = nil) {
        self.initialSection = initialSection
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SettingsNativeSidebar(
                selection: sidebarSelection,
                navigationGeneration: appModel.mainWindowNavigationGeneration,
                onUserSelection: { section in
                    routeStateStore.requestFocusRestorationForSidebarSelection(
                        of: section.settingsViewMode
                    )
                }
            )
                .toolbar(removing: .sidebarToggle)
                .frame(minWidth: 208, idealWidth: 224, maxWidth: 248)
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 248)
        } detail: {
            ZStack(alignment: .topLeading) {
                SettingsShellView(mode: appModel.selectedSection.settingsViewMode)
                    .environmentObject(routeStateStore)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(BlocksSettingsDetailBacking())
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.settingsSidebarVisibility, $sidebarVisibility)
        .focusedSceneValue(\.settingsNavigationActions, navigationCommandActions)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                SettingsNavigationToolbar(store: routeStateStore) { section in
                    appModel.selectedSection = section
                }
            }
        }
        .environment(\.blocksSettingsPresentation, true)
        .modifier(BlocksSettingsWindowBacking())
        .background {
            AppleTranslationPreparationHost(
                controller:
                    AppleTranslationLanguagePackController.shared
                        .preparationController
            )
        }
        .onAppear {
            if let initialSection { appModel.selectedSection = initialSection }
            routeStateStore.recordSectionSelection(appModel.selectedSection)
        }
        .onChange(of: appModel.selectedSection) { _, section in
            routeStateStore.recordSectionSelection(section)
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
            appModel.selectedSection = section
        }
    }

    private var navigationCommandActions: SettingsNavigationCommandActions {
        SettingsNavigationCommandActions(
            canGoBack: !routeStateStore.historyIndices(backward: true, validating: isNavigationLocationAvailable).isEmpty,
            canGoForward: !routeStateStore.historyIndices(backward: false, validating: isNavigationLocationAvailable).isEmpty,
            navigate: { backward in
                if let section = routeStateStore.navigate(backward: backward, validating: isNavigationLocationAvailable) {
                    appModel.selectedSection = section
                }
            }
        )
    }

    private func isNavigationLocationAvailable(_ location: SettingsNavigationLocation) -> Bool {
        if location.section == .hooks,
           case .installed(let id) = PluginCenterRoute(token: location.routeToken) {
            return pluginManager.plugins.contains { $0.id == id }
        }
        return location.isAvailable(appModel: appModel)
    }
}

private struct SettingsSidebarVisibilityKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
    var settingsSidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[SettingsSidebarVisibilityKey.self] }
        set { self[SettingsSidebarVisibilityKey.self] = newValue }
    }
}

struct SettingsSidebarCommands: Commands {
    @FocusedValue(\.settingsSidebarVisibility) private var visibility
    private var isVisible: Bool { visibility?.wrappedValue != .detailOnly }

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(L10n.string(isVisible ? "settings.sidebar.hide" : "settings.sidebar.show")) {
                visibility?.wrappedValue = isVisible ? .detailOnly : .all
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(visibility == nil)
        }
    }
}

private struct SettingsNativeSidebar: View {
    @Binding var selection: AppSection?
    let navigationGeneration: UInt64
    let onUserSelection: (AppSection) -> Void

    var body: some View {
        SettingsSourceListBridge(
            selection: $selection,
            navigationGeneration: navigationGeneration,
            onUserSelection: onUserSelection
        )
        .modifier(BlocksSettingsSidebarBacking())
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
    var displayTitle: String? = nil

    var title: String {
        displayTitle ?? L10n.string(localizationKey)
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
            // This originates from NSOutlineView's user-selection callback,
            // outside SwiftUI's view-update transaction. Publish the route
            // synchronously before auxiliary state triggers a render; otherwise
            // that render can apply the old binding value back to AppKit.
            selection.wrappedValue = section
            onUserSelection(section)
        }
    }
}

@MainActor
final class SettingsSourceListNativeView: NSView {
    private let scrollView = SettingsSourceListScrollView()
    private let outlineView = SettingsViewportWidthOutlineView()
    private let groupDescriptors: [SettingsSidebarGroupDescriptor]
    private let dataController: SettingsSourceListDataController
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

    var documentColumnWidth: CGFloat {
        outlineView.outlineTableColumn?.width ?? 0
    }

    var viewportWidth: CGFloat {
        scrollView.contentView.bounds.width
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
        let groups = SettingsSidebarSourceListModel.groups
        groupDescriptors = groups
        dataController = SettingsSourceListDataController(groups: groups)
        super.init(frame: frameRect)
        configure()
    }

    init(
        frame frameRect: NSRect,
        groups: [SettingsSidebarGroupDescriptor]
    ) {
        groupDescriptors = groups
        dataController = SettingsSourceListDataController(groups: groups)
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        let groups = SettingsSidebarSourceListModel.groups
        groupDescriptors = groups
        dataController = SettingsSourceListDataController(groups: groups)
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
        let currentSignature = groupDescriptors.map { group in
            ([group.title] + group.sections.map(\.title)).joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
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
        column.resizingMask = []
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .medium
        outlineView.rowHeight = 30
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 0
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
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

    func reloadSourceList() {
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
        let viewport = scrollView.contentView.bounds
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
private final class SettingsViewportWidthOutlineView: NSOutlineView {
    override func setFrameSize(_ newSize: NSSize) {
        var constrained = newSize
        if let clipView = enclosingScrollView?.contentView, clipView.bounds.width > 0 {
            constrained.width = clipView.bounds.width
        }
        super.setFrameSize(constrained)
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
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }

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
    let groupNodes: [SettingsSidebarGroupNode]
    lazy var routeNodes: [AppSection: SettingsSidebarRouteNode] = {
        Dictionary(
            uniqueKeysWithValues: groupNodes.flatMap(\.children).map { ($0.section, $0) }
        )
    }()

    var onSelectionChange: ((AppSection) -> Void)?

    init(groups: [SettingsSidebarGroupDescriptor]) {
        groupNodes = groups.map(SettingsSidebarGroupNode.init)
        super.init()
    }

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
        // Explicit spacer rows own grouping; Source List group styling would
        // add a second, system-controlled gap above each hidden heading.
        false
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
        if let group = item as? SettingsSidebarGroupNode {
            return group === groupNodes.first ? 0.01 : 10
        }
        return 30
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
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(title: String) {}

    private func configure() {
        setAccessibilityElement(false)
    }
}

@MainActor
private final class SettingsSidebarRouteCell: NSTableCellView {
    private let iconBadge = NSView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var section: AppSection?

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
        self.section = section
        symbolView.image = NSImage(
            systemSymbolName: section.settingsIconSystemImage,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        )
        symbolView.contentTintColor = .white
        updateBadgeColor()
        titleLabel.stringValue = section.title
        titleLabel.setAccessibilityLabel(section.title)
    }

    private func configure() {
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 4
        iconBadge.setAccessibilityElement(false)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.setAccessibilityElement(false)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        textField = titleLabel
        addSubview(iconBadge)
        iconBadge.addSubview(symbolView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 20),
            iconBadge.heightAnchor.constraint(equalToConstant: 20),
            symbolView.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 12),
            symbolView.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBadgeColor()
    }

    private func updateBadgeColor() {
        guard let section else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconBadge.layer?.backgroundColor = NSColor(section.settingsIconColor).cgColor
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
