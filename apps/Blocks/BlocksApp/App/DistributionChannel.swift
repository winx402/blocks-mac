import Foundation

enum DistributionChannel: String, CaseIterable {
    case development
    case directBeta = "direct-beta"
    case appStoreBeta = "app-store-beta"

    static var current: Self {
        #if BLOCKS_APP_STORE_BETA
        .appStoreBeta
        #elseif BLOCKS_DIRECT_BETA
        .directBeta
        #else
        .development
        #endif
    }

    var supportsCLIAndActionBroker: Bool {
        self != .appStoreBeta
    }

    var supportsSelectionHelper: Bool {
        self != .appStoreBeta
    }

    var supportsExternalPlugins: Bool {
        self != .appStoreBeta
    }

    var usesSystemManagedUpdates: Bool {
        self == .appStoreBeta
    }

    var localizedName: String {
        switch self {
        case .development:
            L10n.string("release.channel.development")
        case .directBeta:
            L10n.string("release.channel.directBeta")
        case .appStoreBeta:
            L10n.string("release.channel.appStoreBeta")
        }
    }
}

enum BlocksReleaseMetadata {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "0"
    }

    static var releaseName: String {
        configuredString(forInfoKey: "BLOCKS_RELEASE_NAME") ?? version
    }

    static var releasePageURL: URL? {
        configuredHTTPSURL(forInfoKey: "BLOCKS_RELEASE_PAGE_URL")
    }

    static var supportURL: URL? {
        configuredHTTPSURL(forInfoKey: "BLOCKS_SUPPORT_URL")
    }

    static var privacyURL: URL? {
        configuredHTTPSURL(forInfoKey: "BLOCKS_PRIVACY_URL")
    }

    private static func configuredString(forInfoKey key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key)
            as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func configuredHTTPSURL(forInfoKey key: String) -> URL? {
        guard let value = configuredString(forInfoKey: key),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}
