import Foundation

@MainActor
final class ClipboardPanelSessionModel: ObservableObject {
    @Published var query = ""
    @Published var selectedRecordID: String?
    @Published var detailRecordID: String?
    @Published private(set) var visibleRecordLimit = ClipboardPanelPagination.initialVisibleLimit
    @Published private(set) var paginationRequestInFlight = false

    func begin(query: String) {
        self.query = query
        resetPagination()
    }

    func resetPagination() {
        paginationRequestInFlight = false
        visibleRecordLimit = ClipboardPanelPagination.initialVisibleLimit
    }

    func finishHistoryRead() {
        paginationRequestInFlight = false
    }

    func beginNextPage() -> Int? {
        guard !paginationRequestInFlight else { return nil }
        paginationRequestInFlight = true
        visibleRecordLimit += ClipboardPanelPagination.pageSize
        return visibleRecordLimit
    }

    func select(_ recordID: String) {
        selectedRecordID = recordID
    }

    func clearSelection() {
        selectedRecordID = nil
    }

    func shutdown() {
        paginationRequestInFlight = false
        detailRecordID = nil
    }

}
