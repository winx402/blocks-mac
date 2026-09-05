import Foundation

public enum BlocksNativePluginXPC {
    public static let serviceName = "app.blocks.plugin-runner"
    public static let hostAppBundleIdentifier = "app.blocks.app"
    public static let protocolVersion = 2
}

public enum BlocksNativePluginNetworkBridgeLimits {
    /// The manifest limit is measured against raw header and body bytes, while
    /// JavaScript and Codable carry those bytes inside JSON strings. A valid
    /// UTF-8 string can expand to six times its raw size when JSON-escaped; the
    /// remaining two MiB bounds the request envelope without weakening the raw
    /// network policy limit.
    public static let maximumEncodedRequestBytes =
        BlocksNativePluginNetworkPermission.absoluteMaximumRequestBytes * 6
            + 2 * 1_048_576
}

@objc public protocol BlocksNativePluginRunnerHostXPCProtocol {
    func performNetworkRequest(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )

    func emitProgress(_ progressData: Data)

    func performHostOperation(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )
}

@objc public protocol BlocksNativePluginRunnerXPCProtocol {
    /// Completes after launchd has started the isolated runner and the service
    /// has accepted the host connection. The host starts the plugin execution
    /// budget only after this handshake, so cold-start time is not charged to
    /// plugin code.
    func prepareInvocation(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    )

    func execute(
        _ requestData: Data,
        hostEndpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Data) -> Void
    )

    func executePlatform(
        _ requestData: Data,
        hostEndpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Data) -> Void
    )

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    )
}
