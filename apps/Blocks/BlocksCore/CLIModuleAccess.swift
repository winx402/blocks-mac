import Foundation

/// Only Broker-backed actions belong to these grants. Feedback and privacy
/// commands run locally in the CLI and are deliberately not represented here.
public enum CLIModule: String, CaseIterable, Codable, Sendable {
    case screenshot, clipboard, translationSources, plugins

    public var defaultsKey: String { "cli.module.\(rawValue).enabled.v1" }

    public static func module(for actionID: ActionID) -> Self? {
        guard let action = BlocksAction(rawValue: actionID.rawValue) else { return nil }
        switch action {
        case .clipboardManage: return .clipboard
        case .translationSourceManage: return .translationSources
        case .pluginManage: return .plugins
        case .screenshotCapture, .screenshotHistoryQuery, .screenshotHistorySearch,
             .screenshotOCRStatus, .screenshotOCRRetry, .screenshotHistoryExport,
             .screenshotScrollingStatus, .screenshotScrollingFinish, .screenshotScrollingCancel:
            return .screenshot
        }
    }
}

/// App-owned policy; never read CLI-process defaults to authorize an App action.
/// There is intentionally no migration from the old global service switch.
@MainActor
public final class CLIModuleAccessPolicy {
    private let defaults: UserDefaults
    private var revisions: [CLIModule: UInt64] = [:]

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func isEnabled(_ module: CLIModule) -> Bool {
        (defaults.object(forKey: module.defaultsKey) as? Bool) ?? false
    }

    public func setEnabled(_ enabled: Bool, for module: CLIModule) {
        guard isEnabled(module) != enabled else { return }
        revisions[module, default: 0] &+= 1
        defaults.set(enabled, forKey: module.defaultsKey)
    }

    public func revision(for module: CLIModule) -> UInt64 { revisions[module, default: 0] }

    public func allows(_ actionID: ActionID) -> Bool {
        CLIModule.module(for: actionID).map(isEnabled) ?? false
    }

    public var actions: [ActionDescriptor] { ActionRegistry.actions.filter { allows($0.actionID) } }
}

public struct CLIActionListResponse: Codable, Sendable {
    public let actions: [ActionDescriptor]
    public let error: ActionBrokerError?

    public init(actions: [ActionDescriptor] = [], error: ActionBrokerError? = nil) {
        self.actions = actions
        self.error = error
    }

    public static func failure(_ code: String, _ message: String) -> Data {
        (try? JSONEncoder().encode(Self(error: ActionBrokerError(
            category: .availability, code: code, message: message, retryable: false
        )))) ?? Data()
    }
}
