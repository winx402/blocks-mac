import AppKit
import BlocksCore
import Darwin
import Foundation
import Security

private actor ActionHostRouter {
    private struct RegisteredHost {
        let connection: NSXPCConnection
        let processID: pid_t
    }

    private var registeredHost: RegisteredHost?

    func register(endpoint: NSXPCListenerEndpoint, processID: pid_t) {
        registeredHost?.connection.invalidate()
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BlocksActionHostXPCProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { await self?.clear(connection) }
        }
        connection.resume()
        registeredHost = RegisteredHost(connection: connection, processID: processID)
    }

    func waitForHost(timeout: Duration = .seconds(8)) async -> NSXPCConnection? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let connection = liveHostConnection() { return connection }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return liveHostConnection()
    }

    private func clear(_ connection: NSXPCConnection?) {
        guard registeredHost?.connection === connection else { return }
        registeredHost = nil
    }

    private func liveHostConnection() -> NSXPCConnection? {
        guard let registeredHost else { return nil }
        if kill(registeredHost.processID, 0) == 0 || errno == EPERM {
            return registeredHost.connection
        }
        registeredHost.connection.invalidate()
        self.registeredHost = nil
        return nil
    }
}

private final class BrokerConnectionService: NSObject, BlocksActionBrokerHostXPCProtocol, BlocksActionBrokerClientXPCProtocol {
    private let router: ActionHostRouter
    private let hostProcessID: pid_t?

    init(router: ActionHostRouter, hostProcessID: pid_t?) {
        self.router = router
        self.hostProcessID = hostProcessID
    }

    func registerHost(
        _ endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard let hostProcessID else {
            reply(false, "Only the Blocks App can register an action host.")
            return
        }
        Task {
            await router.register(endpoint: endpoint, processID: hostProcessID)
            reply(true, nil)
        }
    }

    func submit(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    ) {
        let once = ReplyOnce(reply)
        Task {
            if await router.waitForHost(timeout: .zero) == nil {
                launchMainApp()
            }
            guard let host = await router.waitForHost() else {
                once.send(Self.failure(
                    requestData: requestData,
                    code: "app_host_unavailable",
                    message: "Blocks did not register its action host within 8 seconds."
                ))
                return
            }
            let proxy = host.remoteObjectProxyWithErrorHandler { error in
                once.send(Self.failure(
                    requestData: requestData,
                    code: "app_host_connection_failed",
                    message: error.localizedDescription
                ))
            } as? BlocksActionHostXPCProtocol
            guard let proxy else {
                once.send(Self.failure(
                    requestData: requestData,
                    code: "app_host_proxy_unavailable",
                    message: "The Blocks action host proxy is unavailable."
                ))
                return
            }
            proxy.execute(requestData, outputFile: outputFile) { data in
                once.send(data)
            }
        }
    }

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        let once = BooleanReplyOnce(reply)
        Task {
            guard let host = await router.waitForHost(timeout: .zero) else {
                once.send(false)
                return
            }
            let proxy = host.remoteObjectProxyWithErrorHandler { _ in
                once.send(false)
            } as? BlocksActionHostXPCProtocol
            guard let proxy else {
                once.send(false)
                return
            }
            proxy.cancel(requestID) { cancelled in
                once.send(cancelled)
            }
        }
    }

    private func launchMainApp() {
        guard let appURL = Self.embeddedMainAppURL()
            ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: BlocksActionBrokerXPC.appBundleIdentifier
            ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private static func embeddedMainAppURL() -> URL? {
        guard let executablePath = CommandLine.arguments.first else { return nil }
        let appURL = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard Bundle(url: appURL)?.bundleIdentifier == BlocksActionBrokerXPC.appBundleIdentifier else {
            return nil
        }
        return appURL
    }

    private static func failure(requestData: Data, code: String, message: String) -> Data {
        let request = try? JSONDecoder().decode(ActionBrokerRequest<JSONValue>.self, from: requestData)
        let response = ActionBrokerTerminalResponse<JSONValue>.failed(
            requestID: request?.requestID ?? ActionRequestID.make(),
            actionID: request?.actionID ?? ActionID(rawValue: "invalid.request")!,
            error: ActionBrokerError(
                category: .availability,
                code: code,
                message: message,
                retryable: true
            )
        )
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data) -> Void)?

    init(_ reply: @escaping (Data) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data) {
        lock.lock()
        let callback = reply
        reply = nil
        lock.unlock()
        callback?(data)
    }
}

private final class BooleanReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Bool) -> Void)?

    init(_ reply: @escaping (Bool) -> Void) {
        self.reply = reply
    }

    func send(_ value: Bool) {
        lock.lock()
        let callback = reply
        reply = nil
        lock.unlock()
        callback?(value)
    }
}

private final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let router = ActionHostRouter()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let role = BlocksPeerIdentityValidator.role(for: connection) else { return false }
        let hostProcessID: pid_t?
        switch role {
        case .appHost:
            connection.exportedInterface = NSXPCInterface(with: BlocksActionBrokerHostXPCProtocol.self)
            hostProcessID = connection.processIdentifier
        case .client:
            connection.exportedInterface = NSXPCInterface(with: BlocksActionBrokerClientXPCProtocol.self)
            hostProcessID = nil
        }
        connection.exportedObject = BrokerConnectionService(
            router: router,
            hostProcessID: hostProcessID
        )
        connection.resume()
        return true
    }
}

private enum BlocksPeerIdentityValidator {
    enum PeerRole {
        case appHost
        case client
    }

    static func role(for connection: NSXPCConnection) -> PeerRole? {
        guard connection.effectiveUserIdentifier == getuid(),
              connection.processIdentifier > 0 else {
            return nil
        }
        guard let peer = signingInfo(pid: connection.processIdentifier),
              let own = signingInfo(pid: getpid()),
              !own.teamID.isEmpty,
              peer.teamID == own.teamID else {
            return nil
        }
        switch peer.identifier {
        case BlocksActionBrokerXPC.appBundleIdentifier:
            return .appHost
        case "app.blocks.cli", "blocks":
            return .client
        default:
            return nil
        }
    }

    private static func signingInfo(pid: pid_t) -> (teamID: String, identifier: String)? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return nil
        }
        guard SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any],
              let teamID = values[kSecCodeInfoTeamIdentifier] as? String,
              let identifier = values[kSecCodeInfoIdentifier] as? String else {
            return nil
        }
        return (teamID, identifier)
    }
}

private let delegate = BrokerListenerDelegate()
private let listener = NSXPCListener(machServiceName: BlocksActionBrokerXPC.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
