import AppKit
import SwiftUI

struct SettingsShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: SettingsViewMode

    var body: some View {
        Group {
            if mode == .translationFavorites {
                TranslationFavoritesPane { favorite in
                    appModel.showTranslationFavorite(favorite)
                }
                .padding(
                    .horizontal,
                    BlocksVisualTokens.Layout.settingsPageHorizontalPadding
                )
                .padding(.top, BlocksVisualTokens.Spacing.lg)
                .padding(.bottom, BlocksVisualTokens.Spacing.xl)
            } else if mode == .hooks {
                HooksSettingsPane()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: BlocksVisualTokens.Spacing.xl
                        ) {
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
                                restorationID: routeStateStore
                                    .scrollRestorationID(for: mode),
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
                        .padding(.top, BlocksVisualTokens.Spacing.xl)
                        .padding(.bottom, 48)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
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
        .navigationTitle(mode.title)
        .toolbar {
            if mode == .clipboardPrivacy {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appModel.selectedSection = .clipboardSettings
                    } label: {
                        Label(L10n.string("settings.backToClipboard"), systemImage: "chevron.left")
                    }
                }
            }
        }
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

@MainActor
final class SettingsRouteStateStore: ObservableObject {
    private var scrollOffsets: [String: CGFloat] = [:]
    @Published private var secondaryRouteTokens: [SettingsViewMode: String] = [:]
    @Published private(set) var secondaryScrollRequest: SettingsSecondaryScrollRequest?
    @Published private(set) var focusRestorationRequest: SettingsFocusRestorationRequest?
    private var focusTargets: [String: String] = [:]
    private var providerDetailsDrafts: [String: ProviderDetailsRouteDraft] = [:]

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
                        guard let self, let candidate,
                              !self.isApplyingRestoration else {
                            return
                        }
                        self.offset.wrappedValue =
                            candidate.contentView.bounds.origin.y
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
                let documentHeight = candidate.documentView?.bounds.height ?? 0
                let maximumOffset = max(
                    0,
                    documentHeight - candidate.contentView.bounds.height
                )
                candidate.contentView.scroll(
                    to: NSPoint(
                        x: candidate.contentView.bounds.origin.x,
                        y: min(max(0, restoredOffset), maximumOffset)
                    )
                )
                candidate.reflectScrolledClipView(candidate.contentView)
                self.isApplyingRestoration = false
                self.offset.wrappedValue =
                    candidate.contentView.bounds.origin.y
            }
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
