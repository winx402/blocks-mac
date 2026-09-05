import AppKit
import BlocksCore
import SwiftUI
import UniformTypeIdentifiers

struct HooksSettingsPane: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @EnvironmentObject private var pluginManager: BlocksNativePluginManager

    @SceneStorage("settings.plugins.search") private var searchText = ""
    @State private var errorMessage: String?
    @State private var configurationEditor: BlocksNativePluginMetadata?
    @State private var pendingDelete: BlocksNativePluginMetadata?
    @State private var activeOperation: PluginCenterOperationScope?
    @State private var builtInPresentations: [
        String: BlocksNativePluginPresentationLocalization
    ] = [:]

    private let builtInCatalog: BlocksBuiltInPluginCatalog? = try?
        BlocksBuiltInPluginCatalog.load()
    private let builtInPresentationLoader =
        BlocksBuiltInPluginPresentationLoader()

    private var pluginRuntime: BlocksPluginRuntimeCoordinator {
        appModel.pluginRuntimeCoordinator
    }

    private var routeTokenBinding: Binding<String> {
        routeStateStore.secondaryRouteBinding(
            for: .hooks,
            default: "catalog"
        )
    }

    private var operationInFlight: Bool {
        activeOperation != nil
    }

    private var route: PluginCenterRoute {
        get { PluginCenterRoute(token: routeTokenBinding.wrappedValue) }
        nonmutating set { routeTokenBinding.wrappedValue = newValue.token }
    }

    private var scrollRestorationID: String {
        "settings.plugins.route.\(route.token)"
    }

    var body: some View {
        ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: BlocksVisualTokens.Spacing.xl
                ) {
                    Group {
                        switch route {
                        case .catalog:
                            pluginList
                        case let .installed(pluginID):
                            if let plugin = pluginManager.plugins.first(where: {
                                $0.id == pluginID
                            }) {
                                pluginDetail(plugin)
                            } else {
                                unavailableDetail
                            }
                        case let .builtIn(pluginID):
                            if let entry = builtInCatalog?.document.entries.first(where: {
                                $0.id == pluginID
                            }) {
                                builtInDetail(entry)
                            } else {
                                unavailableDetail
                            }
                        }
                    }
                    .transition(.opacity)
                    .blocksAnimation(.selection, value: route.token)
                    BlocksPluginUISlotHost(
                        manager: appModel.translationPluginManager,
                        runtime: appModel.pluginRuntimeCoordinator,
                        slot: .settingsStatusCard,
                        context: ["settings_section": .string("plugins")]
                    )
                }
                .frame(
                    maxWidth: SettingsContentLayoutProfile.content.maximumWidth,
                    alignment: .leading
                )
                .padding(
                    .horizontal,
                    BlocksVisualTokens.Layout.settingsPageHorizontalPadding
                )
                .padding(.top, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .center)
                .background {
                    SettingsScrollPositionBridge(
                        restorationID: scrollRestorationID,
                        offset: routeStateStore.scrollOffsetBinding(
                            key: scrollRestorationID
                        )
                    )
                    .frame(width: 0, height: 0)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: route) { _, _ in
                errorMessage = nil
            }
        .onChange(of: pluginManager.plugins.map(\.id)) { _, ids in
            if case let .installed(pluginID) = route, !ids.contains(pluginID) {
                route = .catalog
            }
        }
        .task {
            await loadBuiltInPresentations()
        }
        .sheet(item: $configurationEditor) { plugin in
            TranslationPluginConfigurationEditorSheet(
                plugin: plugin,
                sourceManagementService:
                    appModel.translationSourceManagementService,
                onSaved: {}
            )
        }
        .sheet(item: pendingInstallationBinding) { pending in
            PluginInstallationReviewSheet(
                pending: pending,
                knownPlugins: knownPluginPresentations,
                isProcessing: operationInFlight,
                confirm: { confirmInstallation(pending) },
                cancel: { pluginManager.cancelPendingInstallation() }
            )
        }
        .alert(
            L10n.string("plugin.center.delete.title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { plugin in
            Button(L10n.string("common.cancel"), role: .cancel) {
                pendingDelete = nil
            }
            Button(L10n.string("plugin.center.delete"), role: .destructive) {
                uninstall(plugin)
            }
        } message: { plugin in
            Text(L10n.format(
                "plugin.center.delete.message",
                pluginDisplayName(plugin)
            ))
        }
        .navigationTitle(routeTitle)
    }

    private var knownPluginPresentations:
        [String: PluginInstallationKnownPluginPresentation] {
        Dictionary(
            uniqueKeysWithValues: pluginManager.plugins.compactMap { metadata in
                guard let manifest = pluginManager.manifest(
                    pluginID: metadata.id
                ) else {
                    return nil
                }
                let localized = manifest.presentation?.localized(
                    fallbackName: manifest.displayName
                )
                return (
                    metadata.id,
                    PluginInstallationKnownPluginPresentation(
                        name: localized?.name ?? manifest.displayName,
                        actionNames: Dictionary(
                            uniqueKeysWithValues:
                                (manifest.platform?.actions ?? []).map {
                                    ($0.id, $0.displayName)
                                }
                        )
                    )
                )
            }
        )
    }

    private var routeTitle: String {
        switch route {
        case .catalog:
            L10n.string("settings.hooks.title")
        case let .installed(pluginID):
            pluginManager.plugins.first(where: { $0.id == pluginID })
                .map(pluginDisplayName)
                ?? L10n.string("settings.hooks.title")
        case let .builtIn(pluginID):
            builtInCatalog?.document.entries.first(where: { $0.id == pluginID })?
                .localized().name
                ?? L10n.string("settings.hooks.title")
        }
    }

    private var pluginList: some View {
        VStack(alignment: .leading, spacing: 18) {
            pluginCatalogToolbar

            SettingsSection(
                title: L10n.string("plugin.center.protection.title")
            ) {
                PluginCenterSafeModeRow(runtime: pluginRuntime)
            }

            installedPluginsSection
            builtInPluginsSection

            if DistributionChannel.current.supportsExternalPlugins {
                SettingsSection(
                    title: L10n.string("plugin.center.external.title")
                ) {
                    SettingsFormRow(
                        title: L10n.string("plugin.center.install"),
                        detail: L10n.string("plugin.center.external.detail")
                    ) {
                        Button(L10n.string("plugin.center.install")) {
                            choosePluginPackage()
                        }
                        .disabled(
                            operationInFlight
                                || !pluginManager.isReadyForMutations
                        )
                    }
                }
            } else {
                SettingsSection(
                    title: L10n.string("plugin.center.external.title")
                ) {
                    SettingsReadOnlyRow(
                        title: L10n.string("release.storeCapability.title"),
                        detail: L10n.string(
                            "release.storeCapability.externalPlugins"
                        )
                    )
                }
            }

            SettingsFeedbackSlot(
                feedback: errorMessage.map {
                    SettingsFeedbackDescriptor(
                        kind: .error,
                        title: L10n.string("plugin.center.error.title"),
                        detail: $0
                    )
                }
            )
        }
    }

    private var pluginCatalogToolbar: some View {
        HStack(spacing: BlocksVisualTokens.Spacing.sm) {
            pluginSearchField
                .frame(minWidth: 220, maxWidth: .infinity)
            pluginRefreshButton
        }
    }

    private var pluginSearchField: some View {
        TextField(
            L10n.string("plugin.center.search.placeholder"),
            text: $searchText
        )
        .textFieldStyle(.roundedBorder)
    }

    private var pluginRefreshButton: some View {
        Group {
            if activeOperation == .catalog {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        width: BlocksCompactIconButtonDensity.compact.hitTarget,
                        height: BlocksCompactIconButtonDensity.compact.hitTarget
                    )
                    .accessibilityLabel(
                        L10n.string("plugin.center.refresh.help")
                    )
            } else {
                BlocksCompactIconButton(
                    systemImage: "arrow.clockwise",
                    label: L10n.string("plugin.center.refresh.help"),
                    density: .compact,
                    action: reloadPlugins
                )
                .disabled(operationInFlight)
            }
        }
    }

    private var filteredInstalledPlugins: [BlocksNativePluginMetadata] {
        pluginManager.plugins.filter { plugin in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty
                || pluginDisplayName(plugin)
                    .localizedCaseInsensitiveContains(query)
                || plugin.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredBuiltInEntries: [BlocksBuiltInPluginCatalogEntry] {
        let installedPluginIDs = Set(pluginManager.plugins.map(\.id))
        return PluginCenterCatalogPolicy.visibleEntries(
            builtInCatalog?.document.entries ?? [],
            installedPluginIDs: installedPluginIDs,
            query: searchText
        )
    }

    private var groupedBuiltInEntries: [(
        category: BlocksBuiltInPluginCategory,
        entries: [BlocksBuiltInPluginCatalogEntry]
    )] {
        BlocksBuiltInPluginCategory.allCases.compactMap { category in
            let entries = filteredBuiltInEntries.filter {
                $0.category == category
            }
            return entries.isEmpty ? nil : (category, entries)
        }
    }

    @ViewBuilder
    private var installedPluginsSection: some View {
        SettingsSection(
            title: L10n.string("plugin.center.installed.title")
        ) {
            if filteredInstalledPlugins.isEmpty {
                compactEmptyRow(L10n.string("plugin.center.installed.empty"))
            } else {
                ForEach(
                    Array(filteredInstalledPlugins.enumerated()),
                    id: \.element.id
                ) { index, plugin in
                    if index > 0 { SettingsRowDivider() }
                    pluginRow(plugin)
                }
            }
        }
    }

    @ViewBuilder
    private var builtInPluginsSection: some View {
        SettingsSection(
            title: L10n.string("plugin.center.builtIn.title")
        ) {
            if filteredBuiltInEntries.isEmpty {
                compactEmptyRow(L10n.string("plugin.center.builtIn.empty"))
            } else {
                ForEach(
                    Array(groupedBuiltInEntries.enumerated()),
                    id: \.element.category
                ) { groupIndex, group in
                    if groupIndex > 0 { SettingsRowDivider() }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.category.localizedTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.top, groupIndex == 0 ? 4 : 12)
                            .padding(.bottom, 4)
                        ForEach(
                            Array(group.entries.enumerated()),
                            id: \.element.id
                        ) { index, entry in
                            if index > 0 { SettingsRowDivider() }
                            builtInRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func compactEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
    }

    private func pluginRow(_ plugin: BlocksNativePluginMetadata) -> some View {
        HStack(spacing: 12) {
            BlocksInteractiveRowButton(action: {
                route = .installed(plugin.id)
            }) {
                HStack(spacing: 12) {
                    PluginCenterSymbol(
                        systemName: pluginSymbolName(plugin),
                        color: plugin.safetyDisabled
                            ? .orange
                            : .accentColor
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pluginDisplayName(plugin))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(pluginSummary(plugin))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 16)
                }
            }
            if plugin.debugEnabled {
                Label(
                    L10n.string("plugin.center.debug.badge"),
                    systemImage: "ladybug.fill"
                )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .help(L10n.string("plugin.center.debug.badge"))
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            if isOperating(plugin.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(pluginDisplayName(plugin))
            }
            SettingsBooleanSwitch(
                L10n.format(
                    "plugin.center.enable",
                    pluginDisplayName(plugin)
                ),
                isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { enabled in setEnabled(enabled, plugin) }
                )
            )
            .disabled(operationInFlight || plugin.safetyDisabled)
        }
        .frame(minHeight: 60)
        .id(installedAnchor(plugin.id))
    }

    private func builtInRow(
        _ entry: BlocksBuiltInPluginCatalogEntry
    ) -> some View {
        let localization = entry.localized()
        return BlocksInteractiveRowButton(action: {
            route = .builtIn(entry.id)
        }) {
            HStack(spacing: 12) {
                PluginCenterSymbol(
                    systemName: entry.symbolName,
                    color: .accentColor
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(localization.name)
                            .font(.body.weight(.medium))
                        Text(L10n.string("plugin.center.official.badge"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(localization.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 60)
        }
        .id(builtInAnchor(entry.id))
    }

    @ViewBuilder
    private func pluginDetail(_ plugin: BlocksNativePluginMetadata) -> some View {
        let presentation = pluginPresentation(plugin)
        let manifest = pluginManager.manifest(pluginID: plugin.id)
        PluginCenterDetailHeader(
            name: presentation.name ?? plugin.displayName,
            summary: presentation.summary,
            symbolName: pluginSymbolName(plugin),
            symbolColor: plugin.safetyDisabled ? .orange : .accentColor,
            showsOfficialBadge: plugin.installationOrigin == .builtIn,
            backAction: { route = .catalog }
        ) {
            HStack(spacing: BlocksVisualTokens.Spacing.sm) {
                if isOperating(plugin.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(pluginDisplayName(plugin))
                }
                if plugin.safetyDisabled {
                    Button(L10n.string("plugin.center.safety.clear")) {
                        clearSafetyDisable(plugin)
                    }
                }
                SettingsBooleanSwitch(
                    L10n.format("plugin.center.enable", pluginDisplayName(plugin)),
                    isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { enabled in setEnabled(enabled, plugin) }
                    )
                )
                .disabled(operationInFlight || plugin.safetyDisabled)
            }
        }

        SettingsSection(
            title: L10n.string("plugin.center.whatItDoes.title")
        ) {
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.whatItDoes.purpose"),
                detail: presentation.purpose
            )
            SettingsRowDivider()
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.whatItDoes.when"),
                detail: presentation.trigger
            )
            if !presentation.examples.isEmpty {
                SettingsRowDivider()
                SettingsReadOnlyRow(
                    title: L10n.string("plugin.center.whatItDoes.examples"),
                    detail: presentation.examples.joined(separator: "\n")
                )
            }
        }

        if !(manifest?.configurationFields.isEmpty ?? true) {
            SettingsSection(
                title: L10n.string("plugin.center.settings.title")
            ) {
                SettingsFormRow(
                    title: L10n.string("plugin.center.settings.rules"),
                    detail: L10n.string("plugin.center.settings.rules.detail")
                ) {
                    Button(L10n.string("plugin.center.configuration.edit")) {
                        configurationEditor = plugin
                    }
                }
            }
        }

        if let contributions = manifest?.platform?.ui,
           !contributions.isEmpty {
            SettingsSection(
                title: L10n.string("plugin.center.controls.title")
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(contributions) { contribution in
                        BlocksPluginUIRuntimeContribution(
                            pluginID: plugin.id,
                            contribution: contribution,
                            runtime: pluginRuntime,
                            performAction: { actionID, input in
                                performPluginAction(
                                    plugin,
                                    actionID: actionID,
                                    input: input
                                )
                            },
                            performFileAuthorization: { actionID, input in
                                authorizeFileAndRun(
                                    plugin,
                                    actionID: actionID,
                                    input: input
                                )
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }

        SettingsSection(
            title: L10n.string("plugin.center.activity.title")
        ) {
            PluginCenterActivityRow(
                plugin: plugin,
                runtime: pluginRuntime,
                operationInFlight: operationInFlight,
                resume: { resume(plugin) }
            )
        }

        SettingsSection(
            title: L10n.string("plugin.center.data.title")
        ) {
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.data.access"),
                detail: presentation.dataUsage
            )
        }

        SettingsSection(title: L10n.string("plugin.center.management.title")) {
            SettingsDangerRow(
                title: L10n.string("plugin.center.delete.row.title"),
                detail: L10n.string("plugin.center.delete.row.detail"),
                actionTitle: L10n.string("plugin.center.delete.row.title")
            ) {
                pendingDelete = plugin
            }
            .disabled(operationInFlight)
        }

        SettingsFeedbackSlot(
            feedback: errorMessage.map {
                SettingsFeedbackDescriptor(
                    kind: .error,
                    title: L10n.string("plugin.center.error.title"),
                    detail: $0
                )
            }
        )
    }

    @ViewBuilder
    private func builtInDetail(
        _ entry: BlocksBuiltInPluginCatalogEntry
    ) -> some View {
        let localization = entry.localized()
        let presentation = builtInPresentation(entry)
        PluginCenterDetailHeader(
            name: localization.name,
            summary: localization.summary,
            symbolName: entry.symbolName,
            symbolColor: .accentColor,
            showsOfficialBadge: true,
            backAction: { route = .catalog }
        ) {
            HStack(spacing: BlocksVisualTokens.Spacing.xs) {
                if isOperating(entry.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localization.name)
                }
                Button(L10n.string("plugin.center.builtIn.install")) {
                    installBuiltIn(entry)
                }
                .buttonStyle(.borderedProminent)
                .disabled(operationInFlight || !pluginManager.isReadyForMutations)
            }
        }

        SettingsSection(
            title: L10n.string("plugin.center.whatItDoes.title")
        ) {
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.whatItDoes.purpose"),
                detail: presentation.purpose
            )
            SettingsRowDivider()
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.whatItDoes.when"),
                detail: presentation.trigger
            )
            if !presentation.examples.isEmpty {
                SettingsRowDivider()
                SettingsReadOnlyRow(
                    title: L10n.string("plugin.center.whatItDoes.examples"),
                    detail: presentation.examples.joined(separator: "\n")
                )
            }
        }

        SettingsSection(
            title: L10n.string("plugin.center.data.title")
        ) {
            SettingsReadOnlyRow(
                title: L10n.string("plugin.center.data.access"),
                detail: presentation.dataUsage
            )
        }

        SettingsFeedbackSlot(
            feedback: errorMessage.map {
                SettingsFeedbackDescriptor(
                    kind: .error,
                    title: L10n.string("plugin.center.error.title"),
                    detail: $0
                )
            }
        )
    }

    private func pluginSymbolName(
        _ plugin: BlocksNativePluginMetadata
    ) -> String {
        if plugin.safetyDisabled {
            return "exclamationmark.shield.fill"
        }
        return builtInCatalog?.document.entries.first(where: {
            $0.id == plugin.id
        })?.symbolName ?? "puzzlepiece.extension.fill"
    }

    private func pluginDisplayName(
        _ plugin: BlocksNativePluginMetadata
    ) -> String {
        pluginPresentation(plugin).name ?? plugin.displayName
    }

    private func pluginSummary(
        _ plugin: BlocksNativePluginMetadata
    ) -> String {
        pluginPresentation(plugin).summary
    }

    private func pluginPresentation(
        _ plugin: BlocksNativePluginMetadata
    ) -> BlocksNativePluginPresentationLocalization {
        if let presentation = pluginManager.manifest(pluginID: plugin.id)?
            .presentation?.localized(fallbackName: plugin.displayName) {
            return presentation
        }
        if let catalog = builtInCatalog?.document.entries.first(where: {
            $0.id == plugin.id
        })?.localized() {
            return .init(
                name: catalog.name,
                summary: catalog.summary,
                purpose: catalog.summary,
                trigger: L10n.string("plugin.center.presentation.trigger.fallback"),
                dataUsage: L10n.string("plugin.center.presentation.data.fallback")
            )
        }
        return .init(
            name: plugin.displayName,
            summary: L10n.string("plugin.center.presentation.summary.fallback"),
            purpose: L10n.string("plugin.center.presentation.purpose.fallback"),
            trigger: L10n.string("plugin.center.presentation.trigger.fallback"),
            dataUsage: L10n.string("plugin.center.presentation.data.fallback")
        )
    }

    private func builtInPresentation(
        _ entry: BlocksBuiltInPluginCatalogEntry
    ) -> BlocksNativePluginPresentationLocalization {
        if let presentation = builtInPresentations[entry.id] {
            return presentation
        }
        let localization = entry.localized()
        return .init(
            name: localization.name,
            summary: localization.summary,
            purpose: localization.summary,
            trigger: L10n.string("plugin.center.presentation.trigger.fallback"),
            dataUsage: L10n.string("plugin.center.builtIn.localOnly.detail")
        )
    }

    private func loadBuiltInPresentations() async {
        guard builtInPresentations.isEmpty, let builtInCatalog else { return }
        let loaded = await builtInPresentationLoader.load(
            catalog: builtInCatalog,
            localeIdentifier: Locale.current.identifier
        )
        guard !Task.isCancelled else { return }
        builtInPresentations = loaded
    }

    private var unavailableDetail: some View {
        BlocksStateView(
            kind: .empty,
            title: L10n.string("plugin.center.unavailable"),
            detail: L10n.string("plugin.center.unavailable.detail")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
    }

    private var pendingInstallationBinding:
        Binding<BlocksNativePluginPendingInstallation?> {
        Binding(
            get: { pluginManager.pendingInstallation },
            set: { if $0 == nil { pluginManager.cancelPendingInstallation() } }
        )
    }

    private func choosePluginPackage() {
        guard !operationInFlight else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.string("plugin.center.install.panelTitle")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "blocksplugin") ?? .folder,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performOperation(scope: .installation) {
            _ = try await pluginManager.prepareInstallation(from: url)
        }
    }

    private func installBuiltIn(_ entry: BlocksBuiltInPluginCatalogEntry) {
        guard !operationInFlight else { return }
        guard let builtInCatalog else {
            errorMessage = BlocksBuiltInPluginCatalogError.resourceMissing
                .localizedDescription
            return
        }
        performOperation(scope: .plugin(entry.id)) {
            _ = try await pluginManager.prepareBuiltInInstallation(
                entryID: entry.id,
                catalog: builtInCatalog
            )
        }
    }

    private func confirmInstallation(
        _ pending: BlocksNativePluginPendingInstallation
    ) {
        performOperation(scope: .installation) {
            let plugin = try await pluginManager.confirmAndInstall(
                pendingID: pending.id
            )
            route = .installed(plugin.id)
        }
    }

    private func setEnabled(
        _ enabled: Bool,
        _ plugin: BlocksNativePluginMetadata
    ) {
        performOperation(scope: .plugin(plugin.id)) {
            _ = try await pluginManager.setEnabled(
                enabled,
                pluginID: plugin.id
            )
        }
    }

    private func reloadPlugins() {
        performOperation(scope: .catalog) {
            await pluginManager.reload()
        }
    }

    private func performPluginAction(
        _ plugin: BlocksNativePluginMetadata,
        actionID: String,
        input: [String: JSONValue]
    ) {
        Task { @MainActor in
            do {
                _ = try await pluginRuntime.performPluginAction(
                    pluginID: plugin.id,
                    actionID: actionID,
                    input: input,
                    origin: .explicitUser
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func authorizeFileAndRun(
        _ plugin: BlocksNativePluginMetadata,
        actionID: String,
        input: [String: JSONValue]
    ) {
        Task { @MainActor in
            guard plugin.approvedPermissions.contains(
                BlocksPluginPermissionToken.userGrantedFiles
            ) else {
                errorMessage = L10n.string(
                    "plugin.center.userFiles.notApproved"
                )
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let reference = try pluginRuntime.resources
                    .registerUserAuthorizedFile(
                        url: url,
                        mediaType: UTType(
                            filenameExtension: url.pathExtension
                        )?.preferredMIMEType,
                        metadata: [
                            "display_name": .string(url.lastPathComponent),
                        ]
                    )
                pluginRuntime.resources.authorize(
                    pluginID: plugin.id,
                    resourceIDs: [reference.id]
                )
                defer {
                    pluginRuntime.resources.revoke(
                        pluginID: plugin.id,
                        resourceIDs: [reference.id]
                    )
                    pluginRuntime.resources.remove(ids: [reference.id])
                }
                var actionInput = input
                actionInput["authorized_file"] = .object([
                    "id": .string(reference.id),
                    "kind": .string(reference.kind.rawValue),
                    "media_type": reference.mediaType.map(JSONValue.string)
                        ?? .null,
                    "byte_count": reference.byteCount.map {
                        .int(Int($0))
                    } ?? .null,
                    "sha256": reference.sha256.map(JSONValue.string)
                        ?? .null,
                    "metadata": .object(reference.metadata),
                ])
                _ = try await pluginRuntime.performPluginAction(
                    pluginID: plugin.id,
                    actionID: actionID,
                    input: actionInput,
                    kind: .uiAction,
                    origin: .explicitUser
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clearSafetyDisable(_ plugin: BlocksNativePluginMetadata) {
        performOperation(scope: .plugin(plugin.id)) {
            try await pluginManager.clearSafetyDisable(pluginID: plugin.id)
        }
    }

    private func resume(_ plugin: BlocksNativePluginMetadata) {
        performOperation(scope: .plugin(plugin.id)) {
            if plugin.safetyDisabled {
                try await pluginManager.clearSafetyDisable(pluginID: plugin.id)
            }
            _ = try await pluginManager.setEnabled(true, pluginID: plugin.id)
        }
    }

    private func uninstall(_ plugin: BlocksNativePluginMetadata) {
        performOperation(scope: .plugin(plugin.id)) {
            defer { pendingDelete = nil }
            try await pluginManager.uninstall(pluginID: plugin.id)
        }
    }

    private func performOperation(
        scope: PluginCenterOperationScope,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !operationInFlight else { return }
        activeOperation = scope
        errorMessage = nil
        Task { @MainActor in
            defer { activeOperation = nil }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isOperating(_ pluginID: String) -> Bool {
        activeOperation == .plugin(pluginID)
    }

    private func installedAnchor(_ pluginID: String) -> String {
        "plugin-center-installed-\(pluginID)"
    }

    private func builtInAnchor(_ pluginID: String) -> String {
        "plugin-center-built-in-\(pluginID)"
    }

}
