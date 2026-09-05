import AppKit
import BlocksCore
import SwiftUI
import UniformTypeIdentifiers

enum TranslationFavoritesLayoutMode: Equatable {
    case singlePane
    case columns
    case stacked

    static func resolve(availableWidth: CGFloat) -> Self {
        availableWidth >= 760 ? .columns : .stacked
    }

    static func resolve(
        availableWidth: CGFloat,
        hasFavorites: Bool
    ) -> Self {
        guard hasFavorites else { return .singlePane }
        return resolve(availableWidth: availableWidth)
    }
}

struct TranslationFavoriteLoadMoreFeedbackState: Equatable {
    private(set) var requestStartCount: Int?

    mutating func begin(currentCount: Int) {
        requestStartCount = currentCount
    }

    mutating func reset() {
        requestStartCount = nil
    }

    mutating func summariesDidChange(currentCount: Int) {
        guard let requestStartCount,
              currentCount > requestStartCount else {
            return
        }
        reset()
    }

    func visibleFailure(
        isLoading: Bool,
        errorMessage: String?
    ) -> String? {
        guard requestStartCount != nil,
              !isLoading,
              let errorMessage,
              !errorMessage.isEmpty else {
            return nil
        }
        return errorMessage
    }
}

enum TranslationFavoriteAccessibilitySummary {
    static let maximumCharacterCount = 72

    static func compact(
        _ text: String,
        maximumCharacterCount: Int = 72
    ) -> String {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > maximumCharacterCount else {
            return normalized
        }
        return String(normalized.prefix(maximumCharacterCount)) + "…"
    }
}

struct TranslationFavoritesPane: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var routeStateStore: SettingsRouteStateStore
    @EnvironmentObject private var translationStore: TranslationStore

    let onRetranslate: (TranslationFavorite) -> Void

    @SceneStorage("settings.translationFavorites.query") private var query = ""
    @SceneStorage("settings.translationFavorites.selection") private var selectedFavoriteID: String?
    @State private var pendingDeletion: TranslationFavoriteSummary?
    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreFeedback =
        TranslationFavoriteLoadMoreFeedbackState()
    @StateObject private var notificationState = BlocksNotificationPresentationState()

    init(onRetranslate: @escaping (TranslationFavorite) -> Void = { _ in }) {
        self.onRetranslate = onRetranslate
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                favoriteLayout(availableWidth: proxy.size.width)

                if notificationState.current != nil {
                    BlocksNotificationHost(state: notificationState)
                    .padding(12)
                    .zIndex(10)
                }
            }
            .frame(
                maxWidth: SettingsContentLayoutProfile.content.maximumWidth,
                maxHeight: .infinity
            )
        }
        .task {
            translationStore.refreshFavorites(query: query)
            selectFirstFavoriteIfNeeded()
        }
        .onDisappear {
            searchTask?.cancel()
            notificationState.shutdown()
        }
        .onChange(of: query) { _, value in
            loadMoreFeedback.reset()
            scheduleSearch(value)
        }
        .onChange(of: translationStore.favoriteSummaries.map(\.id)) { _, _ in
            loadMoreFeedback.summariesDidChange(
                currentCount: translationStore.favoriteSummaries.count
            )
            selectFirstFavoriteIfNeeded()
        }
        .onChange(of: translationStore.favoriteHasMore) { _, hasMore in
            if !hasMore {
                loadMoreFeedback.reset()
            }
        }
        .onChange(of: selectedFavoriteID) { _, favoriteID in
            loadMoreFeedback.reset()
            guard let favoriteID else {
                return
            }
            translationStore.loadFavorite(id: favoriteID)
        }
        .confirmationDialog(
            L10n.string("translation.favorite.deleteConfirmation"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button(L10n.string("translation.favorite.delete"), role: .destructive) {
                deletePendingFavorite()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(deletionConfirmationSummary)
                .accessibilityLabel(pendingDeletion?.sourceText ?? "")
        }
    }

    @ViewBuilder
    private func favoriteLayout(availableWidth: CGFloat) -> some View {
        switch TranslationFavoritesLayoutMode.resolve(
            availableWidth: availableWidth,
            hasFavorites: !translationStore.favoriteSummaries.isEmpty
        ) {
        case .singlePane:
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .columns:
            HSplitView {
                sidebar
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
                stableDetail
                    .frame(
                        minWidth: 400,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        case .stacked:
            VSplitView {
                sidebar
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        minHeight: 210,
                        idealHeight: 280
                    )
                stableDetail
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        minHeight: 240,
                        maxHeight: .infinity
                    )
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.string("translation.favorite.searchPlaceholder"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .accessibilityIdentifier("translation.favorites.search")
                if !query.isEmpty {
                    BlocksCompactIconButton(
                        systemImage: "xmark.circle.fill",
                        label: L10n.string(
                            "translation.favorite.clearSearch"
                        ),
                        density: .micro
                    ) {
                        query = ""
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.control
            )
            .padding(10)

            Divider()

            if translationStore.isLoadingFavorites,
               translationStore.favoriteSummaries.isEmpty {
                BlocksStateView(
                    kind: .loading,
                    title: L10n.string(
                        "translation.favorite.loading"
                    )
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = translationStore.favoriteErrorMessage,
                      translationStore.favoriteSummaries.isEmpty {
                BlocksStateView(
                    kind: .error,
                    title: L10n.string(
                        "translation.favorite.loadFailed"
                    ),
                    detail: error,
                    actionTitle: L10n.string("common.retry"),
                    action: {
                        translationStore.refreshFavorites(query: query)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if translationStore.favoriteSummaries.isEmpty {
                BlocksStateView(
                    kind: .empty,
                    title:
                        query.isEmpty
                            ? L10n.string("translation.favorite.empty")
                            : L10n.string(
                                "translation.favorite.noSearchResults"
                            ),
                    detail:
                        query.isEmpty
                            ? L10n.string(
                                "translation.favorite.emptyDetail"
                            )
                            : L10n.string(
                                "translation.favorite.noSearchResultsDetail"
                            )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedFavoriteID) {
                    ForEach(translationStore.favoriteSummaries) { summary in
                        TranslationFavoriteSummaryRow(summary: summary)
                            .tag(summary.id)
                            .contextMenu {
                                Button {
                                    copy(summary.sourceText)
                                } label: {
                                    Label(
                                        L10n.string("translation.favorite.copySource"),
                                        systemImage: "doc.on.doc"
                                    )
                                }
                                Button(role: .destructive) {
                                    pendingDeletion = summary
                                } label: {
                                    Label(
                                        L10n.string("translation.favorite.delete"),
                                        systemImage: "trash"
                                    )
                                }
                            }
                    }
                    if let failure = loadMoreFailureMessage {
                        TranslationFavoriteLoadMoreFailureRow(
                            message: failure,
                            retry: loadMoreFavorites
                        )
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier(
                            "translation.favorites.loadMoreFailure"
                        )
                    }
                    if translationStore.favoriteHasMore {
                        Button(action: loadMoreFavorites) {
                            HStack {
                                Spacer()
                                if translationStore.isLoadingMoreFavorites {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label(
                                        L10n.string("translation.favorite.loadMore"),
                                        systemImage: "chevron.down.circle"
                                    )
                                }
                                Spacer()
                            }
                            .frame(minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .disabled(translationStore.isLoadingMoreFavorites)
                        .accessibilityIdentifier(
                            "translation.favorites.loadMore"
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background {
                    SettingsScrollPositionBridge(
                        restorationID: "settings.translationFavorites.list",
                        offset: routeStateStore.scrollOffsetBinding(
                            key: "settings.translationFavorites.list"
                        )
                    )
                    .frame(width: 0, height: 0)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text(
                    L10n.format(
                        "translation.favorite.count",
                        String(translationStore.favoriteSummaries.count)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(L10n.string("translation.favorite.exportMarkdown")) {
                        exportFavorites(format: .markdown)
                    }
                    Button(L10n.string("translation.favorite.exportJSON")) {
                        exportFavorites(format: .json)
                    }
                } label: {
                    Label(
                        L10n.string("translation.favorite.export"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(translationStore.favoriteTotalCount == 0)
                .accessibilityIdentifier("translation.favorites.export")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
    }

    private var loadMoreFailureMessage: String? {
        loadMoreFeedback.visibleFailure(
            isLoading: translationStore.isLoadingMoreFavorites,
            errorMessage: translationStore.favoriteErrorMessage
        )
    }

    private func loadMoreFavorites() {
        loadMoreFeedback.begin(
            currentCount: translationStore.favoriteSummaries.count
        )
        translationStore.loadMoreFavorites()
    }

    @ViewBuilder
    private var detail: some View {
        if let favorite = translationStore.selectedFavorite,
           favorite.id == selectedFavoriteID {
            TranslationFavoriteDetail(
                favorite: favorite,
                scrollOffset: routeStateStore.scrollOffsetBinding(
                    key: "settings.translationFavorites.detail.\(favorite.id)"
                ),
                copySource: { copy(favorite.sourceText) },
                copyResult: copy,
                retranslate: { retranslate(favorite) },
                delete: {
                    pendingDeletion = translationStore.favoriteSummaries.first {
                        $0.id == favorite.id
                    }
                }
            )
        } else if translationStore.isLoadingFavoriteDetail,
                  selectedFavoriteID != nil {
            BlocksStateView(
                kind: .loading,
                title: L10n.string("translation.favorite.loading")
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = translationStore.favoriteErrorMessage {
            BlocksStateView(
                kind: .error,
                title: L10n.string(
                    "translation.favorite.loadFailed"
                ),
                detail: error,
                actionTitle: L10n.string("common.retry"),
                action: {
                    guard let selectedFavoriteID else { return }
                    translationStore.loadFavorite(id: selectedFavoriteID)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BlocksStateView(
                kind: .empty,
                title: L10n.string("translation.favorite.select"),
                detail: L10n.string(
                    "translation.favorite.selectDetail"
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var stableDetail: some View {
        ZStack {
            detail
                .id(detailPresentationID)
                .transition(.opacity)
        }
        .blocksAnimation(.selection, value: detailPresentationID)
    }

    private var detailPresentationID: String {
        if let favorite = translationStore.selectedFavorite,
           favorite.id == selectedFavoriteID {
            return "favorite:\(favorite.id)"
        }
        if translationStore.isLoadingFavoriteDetail,
           let selectedFavoriteID {
            return "loading:\(selectedFavoriteID)"
        }
        if translationStore.favoriteErrorMessage != nil {
            return "error:\(selectedFavoriteID ?? "none")"
        }
        return "empty"
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            translationStore.refreshFavorites(query: value)
        }
    }

    private func selectFirstFavoriteIfNeeded() {
        let ids = translationStore.favoriteSummaries.map(\.id)
        if let selectedFavoriteID, ids.contains(selectedFavoriteID) {
            return
        }
        selectedFavoriteID = ids.first
    }

    private func copy(_ text: String) {
        Task { @MainActor in
            let outcome = await appModel.copyTranslationText(text)
            let level: BlocksNotificationLevel
            let titleKey: String
            switch outcome {
            case .copiedAndRecorded:
                level = .success
                titleKey = "translation.favorite.copySucceeded"
            case .copiedWithoutHistory:
                level = .warning
                titleKey =
                    "translation.notification.copiedHistoryUnavailable"
            case .failed:
                level = .error
                titleKey = "translation.favorite.copyFailed"
            }
            notificationState.present(
                BlocksNotificationDescriptor(
                    level: level,
                    title: L10n.string(titleKey),
                    presentationStyle:
                        level == .success
                            ? .compactConfirmation
                            : .standard,
                    systemImage:
                        level == .success ? "checkmark" : nil
                )
            )
        }
    }

    private func retranslate(_ favorite: TranslationFavorite) {
        onRetranslate(favorite)
    }

    private func deletePendingFavorite() {
        guard let pendingDeletion else { return }
        let deletingID = pendingDeletion.id
        self.pendingDeletion = nil
        Task {
            guard await translationStore.deleteFavorite(id: deletingID) else {
                notificationState.present(
                    BlocksNotificationDescriptor(
                        level: .error,
                        title: L10n.string(
                            "translation.favorite.deleteFailed"
                        ),
                        detail: translationStore.favoriteErrorMessage
                    )
                )
                return
            }
            selectFirstFavoriteIfNeeded()
        }
    }

    private var deletionConfirmationSummary: String {
        guard let source = pendingDeletion?.sourceText else { return "" }
        let normalized = source
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 160 else { return normalized }
        return String(normalized.prefix(160)) + "…"
    }

    private func exportFavorites(format: TranslationFavoriteExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.defaultFileName
        panel.allowedContentTypes = [format.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let data = try await (format == .json
                    ? translationStore.exportFavoritesJSON()
                    : translationStore.exportFavoritesMarkdown())
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url, options: .atomic)
                }.value
                notificationState.present(
                    BlocksNotificationDescriptor(
                        level: .success,
                        title: L10n.string(
                            "translation.favorite.exportSucceeded"
                        ),
                        presentationStyle: .compactConfirmation,
                        systemImage: "checkmark"
                    )
                )
            } catch {
                notificationState.present(
                    BlocksNotificationDescriptor(
                        level: .error,
                        title: L10n.string(
                            "translation.favorite.exportFailed"
                        ),
                        detail:
                            TranslationFavoriteErrorPresentation.userMessage
                    )
                )
            }
        }
    }
}

private struct TranslationFavoriteLoadMoreFailureRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("translation.favorite.loadMoreFailed"))
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(L10n.string("common.retry"), action: retry)
                .buttonStyle(.borderless)
        }
        .padding(8)
        .blocksSurface(
            .interactive,
            cornerRadius: BlocksVisualTokens.CornerRadius.control
        )
        .accessibilityElement(children: .contain)
    }
}

private struct TranslationFavoriteSummaryRow: View {
    let summary: TranslationFavoriteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summary.sourceText)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let result = summary.firstTranslatedText, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                Text(languageDirection)
                Text("·")
                Text(
                    L10n.format(
                        "translation.favorite.resultCount",
                        String(summary.resultCount)
                    )
                )
                Spacer(minLength: 4)
                Text(summary.updatedAt, style: .date)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var languageDirection: String {
        let source = summary.sourceLanguage.map {
            TranslationLanguagePreferences.localizedName(for: $0)
        } ?? L10n.string("translation.language.auto")
        let target = TranslationLanguagePreferences.localizedName(
            for: summary.targetLanguage
        )
        return "\(source) → \(target)"
    }

    private var accessibilitySummary: String {
        let source = TranslationFavoriteAccessibilitySummary.compact(
            summary.sourceText
        )
        let result = summary.firstTranslatedText.flatMap { text in
            text.isEmpty
                ? nil
                : TranslationFavoriteAccessibilitySummary.compact(text)
        } ?? L10n.string("translation.favorite.noResultPreview")
        return L10n.format(
            "translation.favorite.rowAccessibility",
            source,
            result,
            languageDirection,
            L10n.format(
                "translation.favorite.resultCount",
                String(summary.resultCount)
            )
        )
    }
}

private struct TranslationFavoriteDetail: View {
    let favorite: TranslationFavorite
    @Binding var scrollOffset: CGFloat
    let copySource: () -> Void
    let copyResult: (String) -> Void
    let retranslate: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("translation.favorite.detailTitle"))
                            .font(.title3.weight(.semibold))
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    BlocksCompactActionGroup {
                        BlocksCompactIconButton(
                            systemImage: "arrow.clockwise",
                            label: L10n.string(
                                "translation.favorite.retranslate"
                            ),
                            action: retranslate
                        )
                        BlocksCompactIconButton(
                            systemImage: "trash",
                            label: L10n.string(
                                "translation.favorite.delete"
                            ),
                            emphasis: .destructive,
                            action: delete
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.string("translation.favorite.source"))
                            .font(.headline)
                        Spacer()
                        BlocksCompactIconButton(
                            systemImage: "doc.on.doc",
                            label: L10n.string(
                                "translation.favorite.copySource"
                            ),
                            action: copySource
                        )
                    }
                    Text(favorite.sourceText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .blocksSurface(
                            .section,
                            cornerRadius: BlocksVisualTokens.CornerRadius.control
                        )
                }

                ForEach(favorite.results) { result in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                TranslationServiceName(
                                    name: result.serviceDisplayName,
                                    font: .headline
                                )
                                Text(serviceMetadata(result))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            BlocksCompactIconButton(
                                systemImage: "doc.on.doc",
                                label: L10n.string(
                                    "translation.favorite.copyResult"
                                )
                            ) {
                                copyResult(
                                    result.translatedText
                                )
                            }
                        }
                        Text(result.translatedText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .blocksSurface(.section)
                }
            }
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .background {
                SettingsScrollPositionBridge(
                    restorationID: "settings.translationFavorites.detail.\(favorite.id)",
                    offset: $scrollOffset
                )
                    .frame(width: 0, height: 0)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var metadata: String {
        let source = favorite.sourceLanguage.map {
            TranslationLanguagePreferences.localizedName(for: $0)
        } ?? L10n.string("translation.language.auto")
        let target = TranslationLanguagePreferences.localizedName(
            for: favorite.targetLanguage
        )
        return "\(source) → \(target) · \(favorite.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func serviceMetadata(_ result: TranslationFavoriteResult) -> String {
        let kind = L10n.string("translation.service.kind.\(result.serviceKind.rawValue)")
        guard let version = result.serviceVersion, !version.isEmpty else {
            return kind
        }
        return "\(kind) · \(version)"
    }
}

private enum TranslationFavoriteExportFormat {
    case markdown
    case json

    var defaultFileName: String {
        switch self {
        case .markdown:
            "Blocks-Translation-Favorites.md"
        case .json:
            "Blocks-Translation-Favorites.json"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown:
            .plainText
        case .json:
            .json
        }
    }
}
