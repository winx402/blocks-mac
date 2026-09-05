import AppKit
import OSLog
import SwiftUI

enum ClipboardPanelActivationSource: String {
    case bottomCard
    case sideRow
    case keyboard
    case contextMenu
    case toolbar
}

enum ClipboardPanelActionKind: String, Equatable {
    case paste
    case detailOpen
    case copyPlainText
    case ocrRetry
    case remove
}

struct ClipboardPanelInteractionEvent: Equatable {
    let recordID: String
    let source: ClipboardPanelActivationSource
    let trigger: ClipboardPanelActivationTrigger
    let action: ClipboardPanelActionKind
    let token: Int
}

enum ClipboardPanelPagination {
    static let pageSize = 24
    static let initialPageCount = 2
    static let initialVisibleLimit = pageSize * initialPageCount
    static let paginationTriggerDistance = 6

    static func shouldLoadNextPage(
        visibleCount: Int,
        visibleLimit: Int,
        canLoadMoreHistory: Bool,
        offset: Int,
        hasActiveFilters: Bool
    ) -> Bool {
        if visibleCount == 0 {
            return hasActiveFilters && canLoadMoreHistory
        }
        guard offset >= visibleCount - paginationTriggerDistance else {
            return false
        }
        return visibleCount >= visibleLimit || canLoadMoreHistory
    }
}

enum ClipboardPanelActivationDecision: Equatable {
    case selectAndOpenDetail
    case perform(ClipboardPanelActionKind)

    static func resolve(_ trigger: ClipboardPanelActivationTrigger) -> Self {
        switch trigger {
        case .singleClick:
            return .selectAndOpenDetail
        case .doubleClick:
            return .perform(.paste)
        case .keyboard, .contextMenu, .button:
            return .perform(.detailOpen)
        }
    }
}

enum ClipboardPanelDirtyActionPolicy {
    static func requiresConfirmation(
        isDirty: Bool,
        presentedRecordID: String?,
        targetRecordID: String,
        action: ClipboardPanelActionKind
    ) -> Bool {
        guard isDirty else {
            return false
        }
        if action == .paste {
            return true
        }
        guard let presentedRecordID else {
            return false
        }
        return presentedRecordID != targetRecordID
    }
}

@MainActor
final class ClipboardPanelInteractionCoordinator: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.blocks",
        category: "clipboard-interaction"
    )
    @Published private(set) var pendingRemovalRecordID: String?

    private var ignoredSearchQuery: String?
    private(set) var latestInteractionToken = 0
    private(set) var panelInteractionEvents: [ClipboardPanelInteractionEvent] = []

    var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { self.pendingRemovalRecordID != nil },
            set: { isPresented in
                if !isPresented {
                    self.pendingRemovalRecordID = nil
                }
            }
        )
    }

    func requestRemoval(recordID: String, availableRecordIDs: Set<String>) {
        guard availableRecordIDs.contains(recordID) else {
            return
        }
        pendingRemovalRecordID = recordID
    }

    func takePendingRemovalRecordID() -> String? {
        defer { pendingRemovalRecordID = nil }
        return pendingRemovalRecordID
    }

    func cancelPendingRemoval() {
        pendingRemovalRecordID = nil
    }

    func routeActivation(
        recordID: String,
        source: ClipboardPanelActivationSource,
        trigger: ClipboardPanelActivationTrigger,
        onSelect: @escaping @MainActor () -> Bool,
        onPerform: @escaping @MainActor (ClipboardPanelActivationTrigger, ClipboardPanelActionKind) -> Void
    ) {
        switch ClipboardPanelActivationDecision.resolve(trigger) {
        case .selectAndOpenDetail:
            guard onSelect() else {
                return
            }
            onPerform(.singleClick, .detailOpen)
        case let .perform(action):
            onPerform(trigger, action)
        }
    }

    func routeSearchChange(
        oldValue: String,
        newValue: String,
        isDetailDirty: Bool,
        restoreQuery: @escaping @MainActor (String) -> Void,
        requestDirtyAction: @escaping @MainActor (@escaping () -> Void) -> Void,
        apply: @escaping @MainActor (String) -> Void
    ) {
        if ignoredSearchQuery == newValue {
            ignoredSearchQuery = nil
            return
        }
        guard isDetailDirty else {
            apply(newValue)
            return
        }
        ignoredSearchQuery = oldValue
        restoreQuery(oldValue)
        requestDirtyAction { [weak self] in
            self?.ignoredSearchQuery = newValue
            restoreQuery(newValue)
            apply(newValue)
        }
    }

    func resetTransientState() {
        ignoredSearchQuery = nil
        pendingRemovalRecordID = nil
    }

    func recordInteraction(
        recordID: String,
        source: ClipboardPanelActivationSource,
        trigger: ClipboardPanelActivationTrigger,
        action: ClipboardPanelActionKind
    ) -> Int {
        latestInteractionToken += 1
        let event = ClipboardPanelInteractionEvent(
            recordID: recordID,
            source: source,
            trigger: trigger,
            action: action,
            token: latestInteractionToken
        )
        panelInteractionEvents.append(event)
        Self.logger.info(
            "token=\(event.token) source=\(event.source.rawValue, privacy: .public) trigger=\(event.trigger.rawValue, privacy: .public) action=\(event.action.rawValue, privacy: .public) record=\(String(event.recordID.suffix(8)), privacy: .public)"
        )
        if panelInteractionEvents.count > 30 {
            panelInteractionEvents.removeFirst(panelInteractionEvents.count - 30)
        }
        return event.token
    }

    func isLatestInteraction(token: Int, recordID: String, selectedRecordID: String?) -> Bool {
        token == latestInteractionToken && selectedRecordID == recordID
    }

}

extension View {
    func clipboardRecordRemovalConfirmation(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            L10n.string("clipboard.deleteHistoryItem.confirmTitle"),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("clipboard.deleteHistoryItem"), role: .destructive, action: onConfirm)
            Button(L10n.string("common.cancel"), role: .cancel, action: onCancel)
        } message: {
            Text(L10n.string("clipboard.deleteHistoryItem.confirmMessage"))
        }
    }
}
