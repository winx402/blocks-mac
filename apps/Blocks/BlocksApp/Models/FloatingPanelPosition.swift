import Foundation

enum FloatingPanelPosition: String, CaseIterable, Identifiable {
    case bottom
    case left
    case right

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .bottom:
            L10n.string("clipboard.panel.position.bottom")
        case .left:
            L10n.string("clipboard.panel.position.left")
        case .right:
            L10n.string("clipboard.panel.position.right")
        }
    }
}
