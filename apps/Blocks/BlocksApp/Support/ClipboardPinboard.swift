import Foundation

struct ClipboardPinboard: Identifiable, Hashable {
    static let unfiledID = "pinboard.unfiled"

    let id: String
    var name: String
    var colorName: String

    static var defaults: [ClipboardPinboard] {
        [
            ClipboardPinboard(id: unfiledID, name: L10n.string("clipboard.pinboard.unfiled"), colorName: "gray"),
            ClipboardPinboard(id: "pinboard.work", name: L10n.string("clipboard.pinboard.work"), colorName: "blue"),
            ClipboardPinboard(id: "pinboard.personal", name: L10n.string("clipboard.pinboard.personal"), colorName: "green")
        ]
    }
}

struct ClipboardPinnedItemMetadata: Equatable {
    var displayName: String?
    var pinboardID: String
}

struct ClipboardSourceFilterOption: Identifiable, Hashable {
    var id: String { key.id }
    let key: ClipboardSourceFilterKey
    let bundleIdentifier: String?
    let displayName: String
    let eventCount: Int
}
