import AppKit
import BlocksCore

protocol AppIconProviding {
    func iconState(for app: PrivacyAppInstance) -> PrivacyAppIconState
}

struct SystemAppIconProvider: AppIconProviding {
    private static var iconCache: [String: NSImage] = [:]
    private static var failedIconKeys: Set<String> = []

    func iconState(for app: PrivacyAppInstance) -> PrivacyAppIconState {
        guard !app.canonicalPath.isEmpty else {
            return .unsupported
        }
        return Self.icon(for: app) == nil ? .failed : .loaded
    }

    static func icon(for app: PrivacyAppInstance) -> NSImage? {
        guard !app.canonicalPath.isEmpty else {
            return nil
        }
        if let cached = iconCache[app.pathHash] {
            return cached
        }
        if failedIconKeys.contains(app.pathHash) {
            return nil
        }
        guard FileManager.default.fileExists(atPath: app.canonicalPath) else {
            failedIconKeys.insert(app.pathHash)
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: app.canonicalPath)
        guard icon.isValid else {
            failedIconKeys.insert(app.pathHash)
            return nil
        }
        icon.size = NSSize(width: 28, height: 28)
        iconCache[app.pathHash] = icon
        return icon
    }
}

struct FakeAppIconProvider: AppIconProviding {
    let statesByPathHash: [String: PrivacyAppIconState]

    init(statesByPathHash: [String: PrivacyAppIconState] = [:]) {
        self.statesByPathHash = statesByPathHash
    }

    func iconState(for app: PrivacyAppInstance) -> PrivacyAppIconState {
        statesByPathHash[app.pathHash] ?? .loaded
    }
}
