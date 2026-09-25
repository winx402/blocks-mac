import AppKit
import BlocksCore
import SwiftUI

struct SettingsShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: SettingsViewMode

    var body: some View {
        let restorationID = routeStateStore.scrollRestorationID(for: mode)
        Group {
            if mode == .translationFavorites {
                VStack(spacing: SettingsLayout.sectionSpacing) {
                    SettingsPageHeader(mode: mode)
                    TranslationFavoritesPane { favorite in
                        appModel.showTranslationFavorite(favorite)
                    }
                }
                .frame(maxWidth: mode.layoutProfile.maximumWidth)
                .padding(
                    .horizontal,
                    BlocksVisualTokens.Layout.settingsPageHorizontalPadding
                )
                .padding(.top, BlocksVisualTokens.Spacing.md)
                .padding(.bottom, BlocksVisualTokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .top)
            } else if mode == .hooks {
                HooksSettingsPane()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: SettingsLayout.sectionSpacing
                        ) {
                            if mode.showsRootOverview, !routeStateStore.isSecondaryPage(for: mode) {
                                SettingsPageHeader(mode: mode)
                            }
                            settingsRoutesContent
                            BlocksPluginUISlotHost(
                                manager: appModel.translationPluginManager,
                                runtime: appModel.pluginRuntimeCoordinator,
                                slot: .settingsStatusCard,
                                context: [
                                    "settings_section": .string(mode.pluginContextID)
                                ]
                            )
                        }
                        .background {
                            SettingsScrollPositionBridge(
                                restorationID: restorationID,
                                offset: routeStateStore.scrollOffsetBinding(for: mode)
                            )
                            .frame(width: 0, height: 0)
                        }
                        .frame(
                            maxWidth: mode.layoutProfile.maximumWidth,
                            alignment: .leading
                        )
                        .padding(
                            .horizontal,
                            BlocksVisualTokens.Layout
                                .settingsPageHorizontalPadding
                        )
                        .padding(.top, BlocksVisualTokens.Spacing.md)
                        .padding(.bottom, 48)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onChange(of: appModel.settingsAttentionRequest?.token) { _, _ in
                        scrollToAttentionRequest(using: proxy)
                    }
                    .onChange(of: routeStateStore.secondaryScrollRequest?.token) { _, _ in
                        restoreSecondaryRouteAnchor(using: proxy)
                    }
                    .onAppear {
                        scrollToAttentionRequest(using: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(routeStateStore.location(for: mode).title(appModel: appModel))
    }

    private func scrollToAttentionRequest(using proxy: ScrollViewProxy) {
        guard let request = appModel.settingsAttentionRequest else { return }
        if reduceMotion {
            proxy.scrollTo(request.target.rawValue, anchor: .center)
        } else {
            withAnimation(BlocksMotionRole.panel.animation(reduceMotion: reduceMotion)) {
                proxy.scrollTo(request.target.rawValue, anchor: .center)
            }
        }
    }

    private func restoreSecondaryRouteAnchor(using proxy: ScrollViewProxy) {
        guard let request = routeStateStore.secondaryScrollRequest,
              request.mode == mode else {
            return
        }
        Task { @MainActor in
            // The main route must exist in the hierarchy before its anchor can
            // be resolved. Restoring on the next reconciliation turn avoids a
            // visible jump to the top of the page.
            await Task.yield()
            proxy.scrollTo(request.anchorID, anchor: .center)
        }
    }

    @ViewBuilder
    private var settingsRoutesContent: some View {
        switch mode {
        case .general:
            GeneralSettingsPane()
        case .screenshot:
            ScreenshotSettingsPane()
        case .clipboard:
            ClipboardSettingsPane(showPrivacySection: false)
        case .clipboardPrivacy:
            PrivacySettingsPane()
        case .translation:
            TranslationSettingsPane()
        case .translationFavorites:
            EmptyView()
        case .shortcuts:
            ShortcutSettingsPane()
        case .providers:
            ProviderSettingsPane()
        case .agentCLI:
            AgentCLISettingsPane()
        case .hooks:
            EmptyView()
        case .dataAudit:
            DataAuditSettingsPane()
        case .permissions:
            PermissionSettingsPane()
        }
    }
}

extension SettingsViewMode {
    var showsRootOverview: Bool {
        // Every sidebar destination has the same category overview. Privacy
        // is a nested clipboard route, not a separate sidebar category.
        self != .clipboardPrivacy
    }
}

/// Root overview only. Navigation belongs to the window toolbar.
struct SettingsPageHeader: View {
    let mode: SettingsViewMode
    var compact = false

    private var summary: String { L10n.string("settings.overview.\(mode.pluginContextID)") }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 6) {
                    icon
                    title
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .blocksSurface(.section, cornerRadius: BlocksVisualTokens.Layout.settingsGroupCornerRadius)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Text(mode.title).font(.title2.weight(.semibold)).accessibilityHeading(.h1)
    }
    private var icon: some View {
        BlocksSettingsCategoryIcon(systemImage: mode.appSection?.settingsIconSystemImage ?? "gearshape",
            tint: mode.appSection?.settingsIconColor ?? .gray, size: compact ? 32 : 40)
    }
}

/// A visited page identity, not a snapshot of the form or its credentials.
struct SettingsNavigationLocation: Equatable {
    let section: AppSection
    let routeToken: String

    @MainActor
    func isAvailable(appModel: AppModel) -> Bool {
        switch section.settingsViewMode {
        case .hooks:
            switch PluginCenterRoute(token: routeToken) {
            case .catalog: return routeToken == "catalog"
            case .installed(let id):
                return appModel.translationPluginManager.plugins.contains { $0.id == id }
            case .builtIn(let id):
                return SettingsNavigationCatalog.entries.contains { $0.id == id }
            }
        case .screenshot: return ["root", "watermarks"].contains(routeToken)
        case .clipboard: return ["root", "tags"].contains(routeToken)
        case .translation: return ["root", "services", "languageResources", "compatibilitySelection"].contains(routeToken)
        case .providers: return ["overview", "details"].contains(routeToken)
        default: return routeToken == "root"
        }
    }

    @MainActor
    func title(appModel: AppModel) -> String {
        switch (section.settingsViewMode, routeToken) {
        case (.screenshot, "watermarks"): return L10n.string("settings.screenshot.watermarks")
        case (.clipboard, "tags"): return L10n.string("settings.clipboardTags")
        case (.translation, "services"): return L10n.string("translation.services.manage")
        case (.translation, "languageResources"): return L10n.string("translation.languageResources.title")
        case (.translation, "compatibilitySelection"): return L10n.string("translation.selection.compatibility.title")
        case (.providers, "details"): return L10n.string("settings.providerDefault")
        case (.hooks, _):
            switch PluginCenterRoute(token: routeToken) {
            case .catalog: return section.title
            case .installed(let id):
                return appModel.translationPluginManager.plugins.first { $0.id == id }?.displayName ?? section.title
            case .builtIn(let id):
                return SettingsNavigationCatalog.entries.first { $0.id == id }?.localized().name ?? section.title
            }
        default: return section.title
        }
    }
}

@MainActor
private enum SettingsNavigationCatalog {
    static let entries = (try? BlocksBuiltInPluginCatalog.load())?.document.entries ?? []
}

/// Native chevrons: click to move one page, right-click for visited pages.
/// The toolbar remains present even when either side is disabled.
struct SettingsNavigationToolbar: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var pluginManager: BlocksNativePluginManager
    @ObservedObject var store: SettingsRouteStateStore
    let selectSection: (AppSection) -> Void

    var body: some View {
        SettingsNavigationButtonsBridge(
            backEntries: historyEntries(backward: true),
            forwardEntries: historyEntries(backward: false),
            navigate: navigate,
            jump: { index in
                if let section = store.navigate(toHistoryIndex: index, validating: isValid) {
                    selectSection(section)
                }
            }
        )
        .frame(width: 58, height: 28)
    }

    private func navigate(backward: Bool) {
        if let section = store.navigate(backward: backward, validating: isValid) {
            selectSection(section)
        }
    }

    private func historyEntries(backward: Bool) -> [SettingsHistoryMenuEntry] {
        store.historyIndices(backward: backward, validating: isValid).map { index in
            SettingsHistoryMenuEntry(index: index, title: store.history[index].title(appModel: appModel))
        }
    }

    private func isValid(_ location: SettingsNavigationLocation) -> Bool {
        // Observe the registry directly; AppModel does not relay every plugin
        // mutation, including an uninstall while another section is visible.
        if location.section == .hooks,
           case .installed(let id) = PluginCenterRoute(token: location.routeToken) {
            return pluginManager.plugins.contains { $0.id == id }
        }
        return location.isAvailable(appModel: appModel)
    }
}


@MainActor
final class SettingsRouteStateStore: ObservableObject {
    // History stores identities only. Scroll/focus/drafts remain independently
    // owned by the window store and are never copied into history entries.
    @Published private(set) var history: [SettingsNavigationLocation] = []
    @Published private(set) var historyIndex = -1
    private(set) var navigationGeneration: UInt64 = 0
    private var scrollOffsets: [String: CGFloat] = [:]
    @Published private var secondaryRouteTokens: [SettingsViewMode: String] = [:]
    @Published private(set) var secondaryScrollRequest: SettingsSecondaryScrollRequest?
    @Published private(set) var focusRestorationRequest: SettingsFocusRestorationRequest?
    private var focusTargets: [String: String] = [:]
    private var providerDetailsDrafts: [String: ProviderDetailsRouteDraft] = [:]

    var currentLocation: SettingsNavigationLocation? {
        history.indices.contains(historyIndex) ? history[historyIndex] : nil
    }

    func location(for mode: SettingsViewMode) -> SettingsNavigationLocation {
        SettingsNavigationLocation(
            section: mode.appSection ?? .settings,
            routeToken: secondaryRouteTokens[mode] ?? defaultSecondaryRouteToken(for: mode)
        )
    }

    func recordSectionSelection(_ section: AppSection) {
        record(location(for: section.settingsViewMode))
    }

    /// Async work may finish normally, but may navigate only if the user has
    /// not moved since it began, even if they subsequently returned here.
    func isCurrentNavigation(generation: UInt64, section: AppSection) -> Bool {
        navigationGeneration == generation && currentLocation?.section == section
    }

    private func record(_ location: SettingsNavigationLocation) {
        guard currentLocation != location else { return }
        navigationGeneration &+= 1
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(location)
        historyIndex = history.count - 1
    }

    func historyIndices(backward: Bool, validating isValid: (SettingsNavigationLocation) -> Bool) -> [Int] {
        guard history.indices.contains(historyIndex) else { return [] }
        let indices = backward
            ? Array(history.indices.filter { $0 < historyIndex }.reversed())
            : Array(history.indices.filter { $0 > historyIndex })
        return indices.filter { isValid(history[$0]) }
    }

    @discardableResult
    func navigate(toHistoryIndex index: Int, validating isValid: (SettingsNavigationLocation) -> Bool = { _ in true }) -> AppSection? {
        guard history.indices.contains(index), index != historyIndex,
              isValid(history[index]) else { return nil }
        let destination = history[index]
        navigationGeneration &+= 1
        historyIndex = index
        secondaryRouteTokens[destination.section.settingsViewMode] = destination.routeToken
        // Cancel any old anchor request: history restores the exact saved offset.
        secondaryScrollRequest = nil
        requestFocusRestorationForSidebarSelection(of: destination.section.settingsViewMode)
        return destination.section
    }

    @discardableResult
    func navigate(backward: Bool, validating isValid: (SettingsNavigationLocation) -> Bool = { _ in true }) -> AppSection? {
        guard let index = historyIndices(backward: backward, validating: isValid).first else { return nil }
        return navigate(toHistoryIndex: index, validating: isValid)
    }

    func isSecondaryPage(for mode: SettingsViewMode) -> Bool {
        guard let token = secondaryRouteTokens[mode] else { return false }
        return token != defaultSecondaryRouteToken(for: mode)
    }

    func scrollOffsetBinding(for mode: SettingsViewMode) -> Binding<CGFloat> {
        scrollOffsetBinding(key: scrollRestorationID(for: mode))
    }

    func scrollRestorationID(for mode: SettingsViewMode) -> String {
        let routeToken = secondaryRouteTokens[mode]
            ?? defaultSecondaryRouteToken(for: mode)
        return "settings.route.\(mode.pluginContextID).\(routeToken)"
    }

    private func defaultSecondaryRouteToken(for mode: SettingsViewMode) -> String {
        switch mode {
        case .providers:
            "overview"
        case .hooks:
            "catalog"
        default:
            "root"
        }
    }

    func scrollOffsetBinding(key: String) -> Binding<CGFloat> {
        Binding(
            get: { [weak self] in self?.scrollOffsets[key] ?? 0 },
            set: { [weak self] in self?.scrollOffsets[key] = max(0, $0) }
        )
    }

    func restoreSecondaryRoute(
        for mode: SettingsViewMode,
        anchorID: String
    ) {
        secondaryScrollRequest = SettingsSecondaryScrollRequest(
            mode: mode,
            anchorID: anchorID
        )
    }

    func secondaryRouteBinding(
        for mode: SettingsViewMode,
        default defaultToken: String
    ) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.secondaryRouteTokens[mode] ?? defaultToken
            },
            set: { [weak self] token in
                guard let self else { return }
                guard self.secondaryRouteTokens[mode] != token else { return }
                self.secondaryRouteTokens[mode] = token
                // Delayed work belonging to a page that is no longer visible
                // may update its remembered route, but cannot hijack history.
                if self.currentLocation == nil || self.currentLocation?.section == mode.appSection {
                    self.record(self.location(for: mode))
                }
            }
        )
    }

    func recordFocusTarget(
        _ target: String,
        for mode: SettingsViewMode,
        routeToken: String
    ) {
        focusTargets[focusKey(for: mode, routeToken: routeToken)] = target
    }

    func clearFocusTarget(
        for mode: SettingsViewMode,
        routeToken: String
    ) {
        focusTargets.removeValue(forKey: focusKey(for: mode, routeToken: routeToken))
    }

    /// Called exclusively by the native Source List user-selection callback.
    /// Programmatic navigation intentionally does not request focus restoration.
    func requestFocusRestorationForSidebarSelection(
        of mode: SettingsViewMode
    ) {
        // A newer sidebar action always invalidates an older pending request,
        // even when the destination has no remembered field. This prevents a
        // rapid A → B selection from restoring A later via a programmatic jump.
        focusRestorationRequest = nil
        let routeToken = secondaryRouteTokens[mode]
            ?? defaultSecondaryRouteToken(for: mode)
        guard let target = focusTargets[focusKey(for: mode, routeToken: routeToken)] else {
            return
        }
        focusRestorationRequest = SettingsFocusRestorationRequest(
            mode: mode,
            routeToken: routeToken,
            target: target
        )
    }

    func shouldRestoreFocus(
        for request: SettingsFocusRestorationRequest,
        mode: SettingsViewMode,
        routeToken: String,
        voiceOverEnabled: Bool
    ) -> Bool {
        !voiceOverEnabled
            && request.mode == mode
            && request.routeToken == routeToken
    }

    func consumeFocusRestorationRequest(
        _ request: SettingsFocusRestorationRequest
    ) {
        guard focusRestorationRequest?.token == request.token else { return }
        focusRestorationRequest = nil
    }

    func providerDetailsDraft(for routeToken: String) -> ProviderDetailsRouteDraft? {
        providerDetailsDrafts[routeToken]
    }

    func updateProviderDetailsDraft(
        _ draft: ProviderDetailsRouteDraft,
        for routeToken: String
    ) {
        providerDetailsDrafts[routeToken] = draft
    }

    func clearProviderDetailsDraft(for routeToken: String) {
        providerDetailsDrafts.removeValue(forKey: routeToken)
    }

    private func focusKey(for mode: SettingsViewMode, routeToken: String) -> String {
        "\(mode.pluginContextID).\(routeToken)"
    }
}

struct SettingsSecondaryScrollRequest: Equatable {
    let mode: SettingsViewMode
    let anchorID: String
    let token = UUID()
}

struct SettingsFocusRestorationRequest: Equatable {
    let mode: SettingsViewMode
    let routeToken: String
    let target: String
    let token = UUID()
}

/// In-memory only; it deliberately contains no credential, confirmation, or
/// other sensitive provider state. The account alias is a user-facing keychain
/// label, not the stored secret itself.
struct ProviderDetailsRouteDraft: Equatable {
    let apiBaseURLDraft: String
    let accountAliasDraft: String
    let modelNameDraft: String
    let baseURLValidationFailed: Bool
}

enum SettingsSecondaryRouteAnchor {
    static let screenshotWatermarks = "settings.secondary.screenshot.watermarks"
    static let clipboardTags = "settings.secondary.clipboard.tags"
    static let translationServices = "settings.secondary.translation.services"
    static let translationLanguageResources = "settings.secondary.translation.languages"
    static let translationCompatibility = "settings.secondary.translation.compatibility"
    static let providerDetails = "settings.secondary.provider.details"
}

struct SettingsScrollPositionBridge: NSViewRepresentable {
    let restorationID: String
    @Binding var offset: CGFloat

    init(
        restorationID: String,
        offset: Binding<CGFloat>
    ) {
        self.restorationID = restorationID
        _offset = offset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            restorationID: restorationID,
            offset: $offset
        )
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        context.coordinator.update(
            restorationID: restorationID,
            offset: $offset
        )
        context.coordinator.attach(from: view)
    }

    final class ProbeView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }

    @MainActor
    final class Coordinator {
        private var restorationID: String
        private var offset: Binding<CGFloat>
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var restorationGeneration: UInt64 = 0
        private var restorationIsPending = true
        private var isApplyingRestoration = false

        init(
            restorationID: String,
            offset: Binding<CGFloat>
        ) {
            self.restorationID = restorationID
            self.offset = offset
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func update(
            restorationID: String,
            offset: Binding<CGFloat>
        ) {
            let routeChanged = self.restorationID != restorationID
            self.restorationID = restorationID
            self.offset = offset
            guard routeChanged else { return }
            restorationGeneration &+= 1
            restorationIsPending = true
            isApplyingRestoration = true
        }

        func attach(from view: NSView?) {
            guard let candidate = enclosingScrollView(from: view) else {
                return
            }
            if candidate !== scrollView {
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                scrollView = candidate
                candidate.contentView.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: candidate.contentView,
                    queue: .main
                ) { [weak self, weak candidate] _ in
                        Task { @MainActor [weak self, weak candidate] in
                        guard let self, let candidate else {
                            return
                        }
                        guard !self.isApplyingRestoration else { return }
                        self.offset.wrappedValue =
                            max(
                                0,
                                candidate.contentView.bounds.origin.y
                                    - self.topOffset(in: candidate)
                            )
                    }
                }
                restorationGeneration &+= 1
                restorationIsPending = true
                isApplyingRestoration = true
            }

            guard restorationIsPending else { return }
            restorationIsPending = false
            let generation = restorationGeneration
            let restoredOffset = offset.wrappedValue
            Task { @MainActor [weak self, weak candidate] in
                await Task.yield()
                guard let self, let candidate,
                      self.restorationGeneration == generation,
                      candidate === self.scrollView else {
                    return
                }
                self.applyRestoration(
                    offset: restoredOffset,
                    to: candidate
                )
                // SwiftUI can update the document geometry in the turn after
                // the bridge first attaches. Reapply the same route-owned
                // offset once that layout settles so a fresh route cannot
                // retain the outgoing page's vertical origin.
                await Task.yield()
                guard self.restorationGeneration == generation,
                      candidate === self.scrollView else {
                    return
                }
                self.applyRestoration(
                    offset: restoredOffset,
                    to: candidate
                )
                self.isApplyingRestoration = false
                self.offset.wrappedValue =
                    max(
                        0,
                        candidate.contentView.bounds.origin.y
                            - self.topOffset(in: candidate)
                    )
            }
        }

        private func applyRestoration(
            offset: CGFloat,
            to candidate: NSScrollView
        ) {
            scroll(to: topOffset(in: candidate) + max(0, offset), in: candidate)
        }

        private func topOffset(in candidate: NSScrollView) -> CGFloat {
            constrainedOrigin(
                for: -CGFloat.greatestFiniteMagnitude,
                in: candidate
            )
        }

        private func scroll(to offset: CGFloat, in candidate: NSScrollView) {
            candidate.contentView.scroll(
                to: NSPoint(
                    x: candidate.contentView.bounds.origin.x,
                    y: constrainedOrigin(for: offset, in: candidate)
                )
            )
            candidate.reflectScrolledClipView(candidate.contentView)
        }

        private func constrainedOrigin(
            for offset: CGFloat,
            in candidate: NSScrollView
        ) -> CGFloat {
            let bounds = candidate.contentView.bounds
            func nativeLimit(_ y: CGFloat) -> CGFloat {
                candidate.contentView.constrainBoundsRect(
                    NSRect(x: bounds.origin.x, y: y, width: bounds.width, height: bounds.height)
                ).origin.y
            }
            // NSClipView's document-only constraint excludes NSScrollView's
            // automatic titlebar inset. The real top is negative when that
            // inset is present, even though constrainBoundsRect returns zero.
            let lower = min(nativeLimit(-CGFloat.greatestFiniteMagnitude), -max(0, candidate.contentInsets.top))
            // SwiftUI's clip view may return zero for an extreme proposed
            // rectangle instead of its actual maximum. Use document geometry
            // for the lower edge rather than probing with an enormous origin.
            let documentMaxY = candidate.documentView?.frame.maxY ?? bounds.height
            let upper = max(lower, documentMaxY - bounds.height + max(0, candidate.contentInsets.bottom))
            return min(upper, max(lower, offset))
        }

        private func enclosingScrollView(from view: NSView?) -> NSScrollView? {
            var candidate = view?.superview
            while let current = candidate {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                candidate = current.superview
            }
            return nil
        }
    }
}

private extension SettingsViewMode {
    var pluginContextID: String {
        switch self {
        case .general: "general"
        case .screenshot: "screenshot"
        case .clipboard: "clipboard"
        case .clipboardPrivacy: "clipboard_privacy"
        case .translation: "translation"
        case .translationFavorites: "translation_favorites"
        case .shortcuts: "shortcuts"
        case .providers: "providers"
        case .agentCLI: "agent_cli"
        case .hooks: "plugins"
        case .dataAudit: "data_audit"
        case .permissions: "permissions"
        }
    }
}

extension SettingsViewMode {
    var layoutProfile: SettingsContentLayoutProfile {
        switch self {
        case .translationFavorites, .hooks:
            .content
        case .general, .screenshot, .clipboard, .clipboardPrivacy,
                .translation, .shortcuts, .providers, .agentCLI,
                .dataAudit, .permissions:
            .form
        }
    }

    var title: String {
        switch self {
        case .general: L10n.string("settings.general.title")
        case .screenshot: L10n.string("settings.screenshot.title")
        case .clipboard: L10n.string("settings.clipboard.title")
        case .clipboardPrivacy: L10n.string("menu.clipboardPrivacy")
        case .translation: L10n.string("settings.translation.title")
        case .translationFavorites: L10n.string("translation.favorite.title")
        case .shortcuts: L10n.string("settings.shortcuts")
        case .providers: L10n.string("settings.providerAI")
        case .agentCLI: L10n.string("settings.agentCLI.title")
        case .hooks: L10n.string("settings.hooks.title")
        case .dataAudit: L10n.string("settings.dataAudit.title")
        case .permissions: L10n.string("settings.permissionsPrivacy")
        }
    }
}
