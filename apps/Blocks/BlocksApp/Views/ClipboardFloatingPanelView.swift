import BlocksCore
import OSLog
import SwiftUI

struct ClipboardFloatingPanelView: View {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-panel-detail"
    )
    @EnvironmentObject private var clipboardStore: ClipboardStore
    let position: FloatingPanelPosition
    let actions: ClipboardPanelActions
    @ObservedObject var quickPasteHintState: ClipboardQuickPasteHintState
    @ObservedObject var pinState: ClipboardPanelPinState
    @ObservedObject var focusCoordinator: ClipboardPanelFocusCoordinator
    let keyboardRouter: ClipboardPanelKeyboardCommandRouter
    var pluginManager: BlocksNativePluginManager?
    var pluginRuntime: BlocksPluginRuntimeCoordinator?
    let onOpenMainWindow: () -> Void
    let onOpenSettings: () -> Void
    let onTogglePin: () -> Void
    let onRootEscape: () -> Void
    @StateObject private var session = ClipboardPanelSessionModel()
    @StateObject private var interactionCoordinator = ClipboardPanelInteractionCoordinator()
    @AppStorage(ClipboardPanelSettings.Keys.rememberSearch) private var rememberSearch = false
    @AppStorage(ClipboardPanelSettings.Keys.lastSearch) private var rememberedSearchQuery = ""
    @AppStorage(ClipboardPanelSettings.Keys.showActiveFilterLabels) private var showActiveFilterLabels = true
    @AppStorage(ClipboardPanelSettings.Keys.bottomCardWidth) private var bottomCardWidthValue = Double(ClipboardBottomTrayLayout.defaultBottomCardWidth)
    @AppStorage(ClipboardPanelSettings.Keys.itemFontSize) private var clipboardItemFontSizeRawValue = Double(ClipboardPanelSettings.defaultItemFontSize)
    @AppStorage(ClipboardPanelSettings.Keys.sideRowHeight) private var sideRowHeightStoredValue = Double(ClipboardSideListLayout.defaultRowHeight)
    @State private var sideRowHeightDragValue: CGFloat?
    @State private var sideRowHeightResizeDragStartHeight: CGFloat?
    @State private var activeSideRowHeightResizeHandleID: String?
    @State private var hoveredSideRowHeightResizeHandleID: String?
    @FocusState private var searchFocused: Bool

    private var searchResult: ClipboardSearchResultSet { clipboardStore.currentSearchResult }
    private var filteredRecords: [ClipboardRecorderRecord] { searchResult.records }
    private var displayFilterState: ClipboardFilterState {
        var state = clipboardStore.filterState
        state.selectedTagID = clipboardStore.tagStore.selectedTagID
        return state
    }
    private var currentQuickPasteRecordIDs: [String] { Array(filteredRecords.prefix(9).map(\.id)) }
    private var selectedRecord: ClipboardRecorderRecord? {
        if let selectedRecordID = session.selectedRecordID,
           let selected = filteredRecords.first(where: { $0.id == selectedRecordID }) {
            return selected
        }
        return filteredRecords.first
    }

    private var bottomRecordCardWidth: CGFloat { clampBottomCardWidth(CGFloat(bottomCardWidthValue)) }
    private var clipboardItemFontSize: CGFloat { ClipboardPanelSettings.clampItemFontSize(CGFloat(clipboardItemFontSizeRawValue)) }
    private var sideRowHeight: CGFloat { sideRowHeightDragValue ?? storedSideRowHeight }
    private var storedSideRowHeight: CGFloat { ClipboardSideListLayout.clampRowHeight(CGFloat(sideRowHeightStoredValue)) }

    var body: some View {
        panelLayout
            .overlayPreferenceValue(ClipboardRecordFramePreferenceKey.self) { recordFrames in
                GeometryReader { proxy in
                    ClipboardPanelDetailPresentationLayer(
                        records: filteredRecords,
                        recordFrames: recordFrames,
                        proxy: proxy,
                        presentedRecordID: session.detailRecordID,
                        panelPosition: position,
                        clipboardStore: clipboardStore,
                        itemFontSize: clipboardItemFontSize,
                        focusCoordinator: focusCoordinator,
                        keyboardRouter: keyboardRouter,
                        pluginManager: pluginManager,
                        pluginRuntime: pluginRuntime,
                        onOutsideInteraction: { _ = dismissFloatingDetail() }
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                ClipboardPanelRecordFocusAnchor(focusCoordinator: focusCoordinator)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: position == .bottom ? 720 : 340, minHeight: position == .bottom ? 260 : 420)
            .clipboardRecordRemovalConfirmation(
                isPresented: interactionCoordinator.removalConfirmationPresented,
                onConfirm: confirmPendingRecordRemoval,
                onCancel: { interactionCoordinator.cancelPendingRemoval() }
            )
            .onAppear {
                session.begin(query: rememberSearch ? rememberedSearchQuery : "")
                keyboardRouter.configure(position: position, handler: handleKeyboardCommand)
                bottomCardWidthValue = Double(bottomRecordCardWidth)
                clipboardItemFontSizeRawValue = Double(clipboardItemFontSize)
                sideRowHeightStoredValue = Double(storedSideRowHeight)
                resetSideRowHeightResize()
                hoveredSideRowHeightResizeHandleID = nil
                resetPagination()
                refreshSearchResult()
                normalizeSelection()
                backfillSparseResultIfNeeded()
                if focusCoordinator.target == .inactive {
                    focusCoordinator.focusSearch(reason: .panelOpened)
                }
                Task { @MainActor in
                    await Task.yield()
                    applyRequestedFocus()
                }
            }
            .onChange(of: session.query) { oldValue, newValue in
                interactionCoordinator.routeSearchChange(
                    oldValue: oldValue,
                    newValue: newValue,
                    isDetailDirty: clipboardStore.detailStore.isDirty,
                    restoreQuery: { session.query = $0 },
                    requestDirtyAction: { clipboardStore.detailStore.requestAction(after: $0) },
                    apply: { value in
                        if rememberSearch { rememberedSearchQuery = value }
                        resetPagination()
                        refreshSearchResult()
                        normalizeSelection()
                    }
                )
            }
            .onChange(of: rememberSearch) { _, newValue in
                if !newValue {
                    rememberedSearchQuery = ""
                }
            }
            .onChange(of: clipboardStore.searchRevision) { _, _ in
                session.finishHistoryRead()
                normalizeSelection()
                backfillSparseResultIfNeeded()
            }
            .onChange(of: quickPasteHintState.isCommandKeyPressed) { _, isPressed in
                if isPressed {
                    quickPasteHintState.captureSnapshotIfNeeded(visibleRecordIDs: currentQuickPasteRecordIDs)
                }
            }
            .onChange(of: currentQuickPasteRecordIDs) { _, recordIDs in
                quickPasteHintState.captureSnapshotIfNeeded(visibleRecordIDs: recordIDs)
            }
            .onChange(of: focusCoordinator.generation) { _, _ in
                applyRequestedFocus()
            }
            .onChange(of: clipboardStore.detailStore.navigationResolution) { _, resolution in
                synchronizeFloatingDetail(recordID: resolution.recordID)
            }
            .onChange(of: searchFocused) { _, isFocused in
                guard isFocused,
                      focusCoordinator.target != .search else {
                    return
                }
                guard dismissFloatingDetail() else {
                    searchFocused = false
                    return
                }
                focusCoordinator.focusSearch()
            }
            .onDisappear {
                keyboardRouter.reset()
                session.shutdown()
                interactionCoordinator.resetTransientState()
                resetSideRowHeightResize()
                hoveredSideRowHeightResizeHandleID = nil
            }
    }

    private var panelHeader: some View {
        ClipboardPanelHeader(
            query: $session.query,
            searchFocused: $searchFocused,
            values: ClipboardPanelHeaderValues(
                position: position,
                hasActiveFilters: displayFilterState.hasActiveFilters,
                filterState: displayFilterState,
                sourceOptions: clipboardStore.sourceFilterOptions(),
                favoriteTag: clipboardStore.tagStore.favoriteTag,
                tags: clipboardStore.tagStore.tagsForFilter,
                selectedTagID: clipboardStore.tagStore.selectedTagID,
                tagOperationErrorMessage: clipboardStore.tagStore.operationError?.localizedMessage,
                recorderPaused: clipboardStore.recorderPaused,
                isPinned: pinState.isPinned,
                activeTitle: { activeTitle(for: $0) },
                tagUseCount: { clipboardStore.tagStore.recordCount(tagID: $0) }
            ),
            actions: headerActions,
            pluginActions: clipboardPluginHeaderActions
        )
    }

    private var clipboardPluginHeaderActions: AnyView? {
        guard let pluginManager, let pluginRuntime else { return nil }
        var context: [String: JSONValue] = [
            "position": .string(position.rawValue),
        ]
        if let recordID = selectedRecord?.id {
            context["selected_record_id"] = .string(recordID)
        }
        return AnyView(
            BlocksPluginUISlotHost(
                manager: pluginManager,
                runtime: pluginRuntime,
                slot: .clipboardHeaderAction,
                context: context
            )
        )
    }

    private var headerActions: ClipboardPanelHeaderActions {
        ClipboardPanelHeaderActions(
            onSubmitSearch: pasteSelectedRecordFromKeyboard,
            onFocusSearch: handleSearchFocusRequest,
            onClearAllFilters: clearAllFiltersFromToolbar,
            onOpenSettings: {
                guard dismissFloatingDetail() else { return }
                onOpenSettings()
            },
            onTogglePin: {
                guard dismissFloatingDetail() else { return }
                onTogglePin()
            },
            onSelectFormat: toggleFormatFilter,
            onSelectTime: toggleTimeFilter,
            onSelectSource: toggleSourceFilter,
            onSelectTag: toggleTagFilter,
            onClearFilterGroup: clearFilterGroup,
            onCreateTag: { name, afterTagID in
                await clipboardStore.tagStore.createFilterTag(
                    displayName: name,
                    afterTagID: afterTagID
                )
            },
            onRenameTag: { tagID, name in
                await clipboardStore.tagStore.renameFilterTag(
                    tagID: tagID,
                    displayName: name
                )
            },
            onDeleteTag: { tagID in
                await clipboardStore.tagStore.deleteFilterTag(tagID: tagID)
            },
            onMoveTag: { tagID, afterTagID in
                await clipboardStore.tagStore.moveFilterTag(
                    tagID: tagID,
                    afterTagID: afterTagID
                )
            }
        )
    }

    private var panelLayout: some View {
        ClipboardPanelLayout(
            values: ClipboardPanelLayoutValues(
                position: position,
                emptyStatePresentation: emptyStatePresentation,
                records: filteredRecords,
                bottomRecordCardWidth: bottomRecordCardWidth,
                itemFontSize: clipboardItemFontSize,
                sideRowHeight: sideRowHeight,
                hoveredSideRowHeightResizeHandleID: hoveredSideRowHeightResizeHandleID
            ),
            actions: layoutActions,
            header: panelHeader,
            bottomRecordBuilder: recordContent.bottomRecordCard,
            sideRecordBuilder: recordContent.sideRecordRow
        )
    }

    private var recordContent: ClipboardPanelRecordContent {
        ClipboardPanelRecordContent(
            clipboardStore: clipboardStore,
            panelActions: actions,
            pluginManager: pluginManager,
            pluginRuntime: pluginRuntime,
            selectedRecordID: selectedRecord?.id,
            focusedRecordID: focusCoordinator.target.recordID.flatMap {
                focusCoordinator.isRecordFocused($0) ? $0 : nil
            },
            detailRecordID: session.detailRecordID,
            itemFontSize: clipboardItemFontSize,
            bottomCardWidth: bottomRecordCardWidth,
            quickPasteIndex: quickPasteHintState.quickPasteIndex(for:),
            panelSessionID: focusCoordinator.activeSessionID,
            onPointerPress: { onPointerPress(recordID: $0, source: $1) },
            onPrimaryActivation: { onPrimaryActivation(recordID: $0, source: $1, trigger: $2) },
            onRecordAction: { handleRecordAction($0, source: $1, trigger: $2, action: $3) },
            onRemove: requestRecordRemoval,
            onRecordAppeared: onRecordAppearedForPagination
        )
    }

    private var layoutActions: ClipboardPanelLayoutActions {
        ClipboardPanelLayoutActions(
            onBottomCardWidthChanged: setBottomCardWidth,
            onSideRowHeightResizeChanged: updateSideRowHeightResize,
            onSideRowHeightResizeEnded: finishSideRowHeightResize,
            onSideRowHeightResizeHoverChanged: setSideRowHeightResizeHandleHovered
        )
    }

    private var emptyStatePresentation: ClipboardSearchStatusPresentation {
        ClipboardSearchCoordinator.presentation(
            for: searchResult,
            repositoryUnavailable: clipboardStore.repositoryUnavailable,
            recordsAreEmpty: clipboardStore.records.isEmpty
        ) ?? ClipboardSearchStatusPresentation(
            title: displayFilterState.hasActiveFilters
                ? L10n.string("clipboard.hardening.state.filtered.title")
                : L10n.string("clipboard.hardening.state.empty.title"),
            detail: displayFilterState.hasActiveFilters
                ? L10n.string("clipboard.hardening.state.filtered.detail")
                : L10n.string("clipboard.hardening.state.empty.detail"),
            systemImage: "tray"
        )
    }
    private func activeTitle(for group: ClipboardFilterGroup) -> String? {
        guard showActiveFilterLabels else {
            return nil
        }
        return switch group {
        case .format:
            clipboardStore.filterState.format == .all ? nil : clipboardStore.filterState.format.localizedTitle
        case .time:
            clipboardStore.filterState.time == .all ? nil : clipboardStore.filterState.time.localizedTitle
        case .source:
            clipboardStore.filterState.sourceFilterKey.flatMap { sourceKey in
                clipboardStore.sourceFilterOptions().first { $0.key == sourceKey }?.displayName
            }
        }
    }
    private func normalizeSelection() {
        resetSideRowHeightResizeIfIdentityMissing()
        guard !filteredRecords.isEmpty else {
            session.clearSelection()
            _ = dismissFloatingDetail()
            clipboardStore.floatingSelectedRecordID = nil
            return
        }
        if let detailRecordID = session.detailRecordID,
           !filteredRecords.contains(where: { $0.id == detailRecordID }) {
            _ = dismissFloatingDetail()
        }
        if let selectedRecordID = session.selectedRecordID,
           filteredRecords.contains(where: { $0.id == selectedRecordID }) {
            clipboardStore.floatingSelectedRecordID = selectedRecordID
            return
        }
        selectRecord(filteredRecords[0].id)
    }
    private func refreshSearchResult() {
        clipboardStore.refreshSearchResult(
            query: session.query,
            limit: session.visibleRecordLimit
        )
    }
    private func resetPagination() {
        session.resetPagination()
    }
    private func onRecordAppearedForPagination(_ offset: Int) {
        loadNextPageIfNeeded(offset: offset)
    }
    private func backfillSparseResultIfNeeded() {
        guard filteredRecords.count < session.visibleRecordLimit,
              ClipboardPanelPagination.shouldLoadNextPage(
                visibleCount: filteredRecords.count,
                visibleLimit: session.visibleRecordLimit,
                canLoadMoreHistory: clipboardStore.canLoadMoreHistory,
                offset: max(0, filteredRecords.count - 1),
                hasActiveFilters: displayFilterState.hasActiveFilters
              ) else {
            return
        }
        loadNextPageIfNeeded(offset: max(0, filteredRecords.count - 1))
    }
    private func loadNextPageIfNeeded(offset: Int) {
        guard ClipboardPanelPagination.shouldLoadNextPage(
                visibleCount: filteredRecords.count,
                visibleLimit: session.visibleRecordLimit,
                canLoadMoreHistory: clipboardStore.canLoadMoreHistory,
                offset: offset,
                hasActiveFilters: displayFilterState.hasActiveFilters
              ),
              session.beginNextPage() != nil else {
            return
        }
        refreshSearchResult()
    }
    private func selectRecord(_ id: String) {
        session.select(id)
        clipboardStore.floatingSelectedRecordID = id
    }
    private func selectAndFocusRecord(
        _ id: String,
        reason: ClipboardPanelFocusReason = .recordSelected
    ) {
        session.select(id)
        clipboardStore.floatingSelectedRecordID = id
        focusCoordinator.focusRecord(id, reason: reason)
    }
    private func selectAdjacentRecord(delta: Int) {
        guard !filteredRecords.isEmpty else {
            session.clearSelection()
            clipboardStore.floatingSelectedRecordID = nil
            return
        }
        let currentIndex: Int
        if case .records = focusCoordinator.target,
           let selectedRecordID = session.selectedRecordID,
           let selectedIndex = filteredRecords.firstIndex(where: { $0.id == selectedRecordID }) {
            currentIndex = selectedIndex
        } else {
            currentIndex = delta >= 0 ? -1 : filteredRecords.count
        }
        let nextIndex = min(max(currentIndex + delta, 0), filteredRecords.count - 1)
        let recordID = filteredRecords[nextIndex].id
        if shouldDeferRecordTransition(to: recordID) {
            presentFloatingDetail(recordID: recordID)
            return
        }
        selectAndFocusRecord(recordID, reason: .keyboardNavigation)
    }
    private func pasteSelectedRecordFromKeyboard() {
        guard let recordID = selectedRecord?.id else {
            return
        }
        handleRecordAction(
            recordID,
            source: .keyboard,
            trigger: .keyboard,
            action: .paste
        )
    }
    private func removeSelectedRecord() {
        guard let id = selectedRecord?.id else {
            return
        }
        requestRecordRemoval(id)
    }
    private func onPrimaryActivation(
        recordID: String,
        source: ClipboardPanelActivationSource,
        trigger: ClipboardPanelActivationTrigger
    ) {
        interactionCoordinator.routeActivation(
            recordID: recordID,
            source: source,
            trigger: trigger,
            onSelect: {
                guard !shouldDeferRecordTransition(to: recordID) else {
                    presentFloatingDetail(recordID: recordID)
                    return false
                }
                selectAndFocusRecord(recordID)
                return true
            },
            onPerform: { trigger, action in
                handleRecordAction(recordID, source: source, trigger: trigger, action: action)
            }
        )
    }

    private func onPointerPress(
        recordID: String,
        source: ClipboardPanelActivationSource
    ) {
        guard !ClipboardPanelDirtyActionPolicy.requiresConfirmation(
            isDirty: clipboardStore.detailStore.isDirty,
            presentedRecordID: session.detailRecordID,
            targetRecordID: recordID,
            action: .detailOpen
        ) else {
            return
        }
        selectAndFocusRecord(recordID)
    }

    private func handleRecordAction(
        _ recordID: String,
        source: ClipboardPanelActivationSource,
        trigger: ClipboardPanelActivationTrigger,
        action: ClipboardPanelActionKind
    ) {
        let token = interactionCoordinator.recordInteraction(
            recordID: recordID,
            source: source,
            trigger: trigger,
            action: action
        )
        if ClipboardPanelDirtyActionPolicy.requiresConfirmation(
            isDirty: clipboardStore.detailStore.isDirty,
            presentedRecordID: session.detailRecordID,
            targetRecordID: recordID,
            action: action
        ) {
            clipboardStore.detailStore.requestAction {
                handleRecordAction(
                    recordID,
                    source: source,
                    trigger: trigger,
                    action: action
                )
            }
            return
        }
        selectAndFocusRecord(recordID)
        guard interactionCoordinator.isLatestInteraction(
            token: token,
            recordID: recordID,
            selectedRecordID: session.selectedRecordID
        ) else {
            return
        }

        switch action {
        case .paste:
            if session.detailRecordID != nil,
               !clipboardStore.detailStore.isDirty {
                _ = dismissFloatingDetail()
            }
            actions.pasteRecord(recordID)
        case .detailOpen:
            presentFloatingDetail(recordID: recordID)
        case .copyPlainText:
            actions.copyRecordAsPlainText(recordID)
        case .ocrRetry:
            clipboardStore.retryOCR(recordID: recordID)
        case .remove:
            requestRecordRemoval(recordID)
        }
    }

    private func shouldDeferRecordTransition(to recordID: String) -> Bool {
        guard clipboardStore.detailStore.isDirty,
              let presentedRecordID = session.detailRecordID else {
            return false
        }
        return presentedRecordID != recordID
    }
    private func requestRecordRemoval(_ recordID: String) {
        interactionCoordinator.requestRemoval(
            recordID: recordID,
            availableRecordIDs: Set(filteredRecords.map(\.id))
        )
    }
    private func confirmPendingRecordRemoval() {
        guard let recordID = interactionCoordinator.takePendingRemovalRecordID() else {
            return
        }
        clipboardStore.detailStore.requestAction {
            Task { @MainActor in
                guard await actions.deleteHistoryItem(recordID) else { return }
                normalizeSelection()
            }
        }
    }
    private func clampBottomCardWidth(_ width: CGFloat) -> CGFloat {
        ClipboardBottomTrayLayout.clampCardWidth(width)
    }
    private func setBottomCardWidth(_ width: CGFloat) {
        bottomCardWidthValue = Double(clampBottomCardWidth(width))
    }
    private func previewSideRowHeight(_ height: CGFloat) {
        let clampedHeight = ClipboardSideListLayout.clampRowHeight(height)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sideRowHeightDragValue = clampedHeight
        }
    }
    private func commitSideRowHeight(_ height: CGFloat) {
        let clampedHeight = ClipboardSideListLayout.clampRowHeight(height)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sideRowHeightDragValue = clampedHeight
            sideRowHeightStoredValue = Double(clampedHeight)
            sideRowHeightDragValue = nil
        }
    }
    private func updateSideRowHeightResize(handleID: String, currentHeight: CGFloat, translationHeight: CGFloat) {
        if activeSideRowHeightResizeHandleID != handleID {
            resetSideRowHeightResize()
            activeSideRowHeightResizeHandleID = handleID
            sideRowHeightResizeDragStartHeight = ClipboardSideListLayout.clampRowHeight(currentHeight)
        }
        let startHeight = sideRowHeightResizeDragStartHeight ?? ClipboardSideListLayout.clampRowHeight(currentHeight)
        previewSideRowHeight(startHeight + translationHeight)
    }
    private func finishSideRowHeightResize(handleID: String, currentHeight: CGFloat, translationHeight: CGFloat) {
        guard activeSideRowHeightResizeHandleID == handleID else {
            resetSideRowHeightResize()
            return
        }
        let startHeight = sideRowHeightResizeDragStartHeight ?? ClipboardSideListLayout.clampRowHeight(currentHeight)
        commitSideRowHeight(startHeight + translationHeight)
        resetSideRowHeightResize()
    }
    private func resetSideRowHeightResize() {
        sideRowHeightResizeDragStartHeight = nil
        activeSideRowHeightResizeHandleID = nil
        sideRowHeightDragValue = nil
    }
    private func resetSideRowHeightResizeIfIdentityMissing() {
        if let activeID = activeSideRowHeightResizeHandleID,
           !filteredRecords.dropLast().contains(where: { $0.id == activeID }) {
            resetSideRowHeightResize()
        }
        if let hoveredID = hoveredSideRowHeightResizeHandleID,
           !filteredRecords.dropLast().contains(where: { $0.id == hoveredID }) {
            hoveredSideRowHeightResizeHandleID = nil
        }
    }
    private func setSideRowHeightResizeHandleHovered(_ handleID: String, _ hovering: Bool) {
        if hovering {
            hoveredSideRowHeightResizeHandleID = handleID
        } else if hoveredSideRowHeightResizeHandleID == handleID {
            hoveredSideRowHeightResizeHandleID = nil
        }
    }
    private func clearAllFiltersFromToolbar() {
        guard dismissFloatingDetail() else { return }
        clipboardStore.clearFilters()
    }
    private func clearFilterGroup(_ group: ClipboardFilterGroup) {
        guard dismissFloatingDetail() else { return }
        switch group {
        case .format:
            clipboardStore.setFormatFilter(.all)
        case .time:
            clipboardStore.setTimeFilter(.all)
        case .source:
            clipboardStore.setSourceFilter(nil)
        }
    }

    private func toggleFormatFilter(_ option: ClipboardFormatFilter) {
        guard dismissFloatingDetail() else { return }
        let nextFilter: ClipboardFormatFilter = clipboardStore.filterState.format == option ? .all : option
        clipboardStore.setFormatFilter(nextFilter)
    }

    private func toggleTimeFilter(_ option: ClipboardTimeFilter) {
        guard dismissFloatingDetail() else { return }
        let nextFilter: ClipboardTimeFilter = clipboardStore.filterState.time == option ? .all : option
        clipboardStore.setTimeFilter(nextFilter)
    }

    private func toggleTagFilter(_ tagID: String?) {
        guard dismissFloatingDetail() else { return }
        let nextTagID = clipboardStore.tagStore.selectedTagID == tagID ? nil : tagID
        actions.setTagFilter(nextTagID)
    }

    private func toggleSourceFilter(_ sourceKey: ClipboardSourceFilterKey?) {
        guard dismissFloatingDetail() else { return }
        let nextSourceKey = clipboardStore.filterState.sourceFilterKey == sourceKey ? nil : sourceKey
        clipboardStore.setSourceFilter(nextSourceKey)
    }

    @discardableResult
    private func dismissFloatingDetail() -> Bool {
        guard session.detailRecordID != nil else {
            return true
        }
        let recordID = session.detailRecordID
        Self.logger.info(
            "stage=dismiss-request record=\(recordID.map { String($0.suffix(8)) } ?? "none", privacy: .public) dirty=\(clipboardStore.detailStore.isDirty, privacy: .public) busy=\(clipboardStore.detailStore.isBusy, privacy: .public)"
        )
        clipboardStore.detailStore.requestClose()
        guard !clipboardStore.detailStore.dirtyNavigation else {
            Self.logger.info(
                "stage=dismiss-deferred record=\(recordID.map { String($0.suffix(8)) } ?? "none", privacy: .public) reason=dirty-navigation"
            )
            return false
        }
        session.detailRecordID = nil
        focusCoordinator.dismissDetail(recordID: recordID)
        Self.logger.info(
            "stage=dismissed record=\(recordID.map { String($0.suffix(8)) } ?? "none", privacy: .public)"
        )
        return true
    }

    private func presentFloatingDetail(recordID: String) {
        Self.logger.info(
            "stage=open-request record=\(String(recordID.suffix(8)), privacy: .public) current=\(session.detailRecordID.map { String($0.suffix(8)) } ?? "none", privacy: .public) dirty=\(clipboardStore.detailStore.isDirty, privacy: .public) busy=\(clipboardStore.detailStore.isBusy, privacy: .public)"
        )
        if clipboardStore.detailStore.readModel?.recordID != recordID {
            clipboardStore.detailStore.requestOpen(recordID: recordID)
        }
        guard !clipboardStore.detailStore.dirtyNavigation else {
            Self.logger.info(
                "stage=open-deferred record=\(String(recordID.suffix(8)), privacy: .public) reason=dirty-navigation"
            )
            return
        }
        // The detail model loads asynchronously. Keep the panel bound to the
        // requested record instead of reusing the previous model while the new
        // request is in flight.
        session.detailRecordID = recordID
        focusCoordinator.presentDetail(recordID: recordID)
        Self.logger.info(
            "stage=open-presented record=\(String(recordID.suffix(8)), privacy: .public) sessionRecord=\(session.detailRecordID.map { String($0.suffix(8)) } ?? "none", privacy: .public)"
        )
    }

    private func synchronizeFloatingDetail(recordID: String?) {
        session.detailRecordID = recordID
        if let recordID {
            focusCoordinator.presentDetail(recordID: recordID)
        } else {
            focusCoordinator.dismissDetail(recordID: selectedRecord?.id)
        }
        Self.logger.info(
            "stage=navigation-resolved record=\(recordID.map { String($0.suffix(8)) } ?? "none", privacy: .public)"
        )
    }

    private func applyRequestedFocus() {
        let wantsSearchFocus = focusCoordinator.target == .search
        if searchFocused != wantsSearchFocus {
            searchFocused = wantsSearchFocus
        }
        guard wantsSearchFocus else {
            return
        }
        let requestedGeneration = focusCoordinator.generation
        Task { @MainActor in
            await Task.yield()
            focusCoordinator.reportEndpointResult(
                surface: .parent,
                expectedTarget: .search,
                generation: requestedGeneration,
                applied: focusCoordinator.accepts(generation: requestedGeneration)
                    && focusCoordinator.target == .search
                    && searchFocused,
                failureReason: searchFocused ? nil : "swiftui-search-focus-rejected"
            )
        }
    }

    private func handleSearchFocusRequest() {
        guard dismissFloatingDetail() else {
            applyRequestedFocus()
            return
        }
        focusCoordinator.focusSearch()
    }

    private func handleKeyboardCommand(_ command: ClipboardPanelKeyboardCommand) {
        switch command {
        case let .navigate(delta):
            selectAdjacentRecord(delta: delta)
        case .pasteSelected:
            pasteSelectedRecordFromKeyboard()
        case .deleteSelected:
            removeSelectedRecord()
        case .escape:
            handleEscapeCommand()
        case let .quickPaste(index):
            clipboardStore.detailStore.requestAction {
                actions.pasteQuickRecord(index)
            }
        case .saveDetail:
            clipboardStore.detailStore.save()
        }
    }

    private func handleEscapeCommand() {
        let step = ClipboardPanelEscapeResolver.step(
            for: ClipboardPanelEscapeContext(
                focusTarget: focusCoordinator.target,
                hasPresentedDetail: session.detailRecordID != nil,
                hasSearchQuery: !session.query.isEmpty,
                hasActiveFilters: displayFilterState.hasActiveFilters
            )
        )
        switch step {
        case .exitDetailEdit:
            clipboardStore.detailStore.cancel()
        case .closeDetail:
            _ = dismissFloatingDetail()
        case .clearSearch:
            session.query = ""
            focusCoordinator.focusSearch()
        case .clearFilters:
            clipboardStore.clearFilters()
            focusCoordinator.focusSearch()
        case .releasePanel:
            onRootEscape()
        }
    }

}
