import Foundation

public enum BlocksActionBrokerXPC {
    public static let launchAgentLabel = "app.blocks.action-broker"
    public static let machServiceName = "app.blocks.action-broker.xpc"
    public static let launchAgentPlistName = "app.blocks.action-broker.plist"
    public static let appBundleIdentifier = "app.blocks.app"
}

@objc public protocol BlocksActionBrokerHostXPCProtocol {
    func registerHost(
        _ endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}

@objc public protocol BlocksActionBrokerClientXPCProtocol {
    func submit(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    )

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    )
}

@objc public protocol BlocksActionHostXPCProtocol {
    func execute(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    )

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    )
}
