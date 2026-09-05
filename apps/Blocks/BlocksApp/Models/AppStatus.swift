import Foundation

enum AppStatusKind: String {
    case ready = "Ready"
    case permissionMissing = "Permission Missing"
    case running = "Running"
    case failed = "Failed"
    case placeholder = "Placeholder"
}

struct AppStatus: Identifiable {
    let id = UUID()
    var kind: AppStatusKind
    var title: String
    var detail: String
}

extension AppStatus {
    static var ready: AppStatus {
        AppStatus(
            kind: .ready,
            title: L10n.string("status.ready.title"),
            detail: L10n.string("status.ready.detail")
        )
    }
}
