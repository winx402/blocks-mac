import AppKit
import BlocksCore
import Darwin
import Foundation
import OSLog
import Security

private actor ActionHostRouter {
    private struct RegisteredHost {
        let connection: NSXPCConnection
        let processID: pid_t
        let token: ActionBrokerEndpointLifecycle.Token
    }

    private var registeredHost: RegisteredHost?
    private var lifecycle = ActionBrokerEndpointLifecycle()
    private var routeLeases: [ActionBrokerEndpointLifecycle.Token: ActionBrokerRouteLeaseLifecycle] = [:]
    private var retiredHosts: [ActionBrokerEndpointLifecycle.Token: RegisteredHost] = [:]

    func register(endpoint: NSXPCListenerEndpoint, processID: pid_t, ownerID: UUID) {
        if let old = registeredHost { clear(token: old.token) }
        let candidate = lifecycle.register(ownerID: ownerID)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BlocksActionHostXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { await self?.clear(token: candidate) }
        }
        connection.interruptionHandler = { [weak self] in
            Task { await self?.clear(token: candidate) }
        }
        connection.resume()
        registeredHost = RegisteredHost(connection: connection, processID: processID, token: candidate)
        routeLeases[candidate] = .init()
    }

    func probeReadiness(ownerID: UUID) async -> Bool {
        guard let current = registeredHost, current.token.ownerID == ownerID,
              liveHostConnection() != nil else { return false }
        let result: Bool? = await withCheckedContinuation { continuation in
            let reply = HostReadinessReply(continuation)
            let proxy = current.connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(nil) }
                as? BlocksActionHostXPCProtocol
            guard let proxy else { reply.finish(nil); return }
            let invoked: Void? = proxy.probeReadiness?(withReply: { reply.finish($0) })
            if invoked == nil { reply.finish(nil) }
            Task {
                try? await Task.sleep(for: .seconds(1))
                reply.finish(nil)
            }
        }
        guard lifecycle.isCurrent(current.token), current.token.ownerID == ownerID else { return false }
        // A responsive paused Host is not a dead transport. In particular,
        // update preparation must not destroy a working reverse connection.
        guard let result else { clear(token: current.token); return false }
        return result
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

    func acquireHost(timeout: Duration = .seconds(8)) async -> ActionHostRouteLease? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if liveHostConnection() != nil, let host = registeredHost,
               var leases = routeLeases[host.token], let lease = leases.acquire() {
                routeLeases[host.token] = leases
                // Selecting the connection and retaining its reply lease are
                // one actor operation, with no intervening suspension.
                return ActionHostRouteLease(connection: host.connection) { [weak self] in
                    Task { await self?.release(token: host.token, lease: lease) }
                }
            }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        } while true
    }

    private func release(token: ActionBrokerEndpointLifecycle.Token, lease: UUID) {
        guard var leases = routeLeases[token] else { return }
        leases.release(lease)
        routeLeases[token] = leases
        disposeRetiredRouteIfIdle(token)
    }

    private func disposeRetiredRouteIfIdle(_ token: ActionBrokerEndpointLifecycle.Token) {
        guard routeLeases[token]?.mayInvalidate == true else { return }
        let host = retiredHosts.removeValue(forKey: token)
        routeLeases.removeValue(forKey: token)
        host?.connection.invalidate()
    }

    func clear(_ connection: NSXPCConnection?) {
        if let host = registeredHost, host.connection === connection { clear(token: host.token); return }
        if let host = retiredHosts.values.first(where: { $0.connection === connection }) { clear(token: host.token) }
    }

    private func clear(token: ActionBrokerEndpointLifecycle.Token) {
        let host: RegisteredHost?
        if registeredHost?.token == token {
            host = registeredHost
            registeredHost = nil
            lifecycle.clear(token)
        } else { host = retiredHosts[token] }
        guard let host, var leases = routeLeases[token] else { return }
        leases.retire()
        routeLeases[token] = leases
        retiredHosts[token] = host
        disposeRetiredRouteIfIdle(token)
    }

    private func liveHostConnection() -> NSXPCConnection? {
        guard let registeredHost else { return nil }
        if kill(registeredHost.processID, 0) == 0 || errno == EPERM {
            return registeredHost.connection
        }
        clear(token: registeredHost.token)
        return nil
    }
}

private final class ActionHostRouteLease: @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var release: (() -> Void)?
    init(connection: NSXPCConnection, release: @escaping () -> Void) { self.connection = connection; self.release = release }
    func finish() {
        let release = lock.withLock { defer { self.release = nil }; return self.release }
        release?()
    }
    deinit { finish() }
}

private final class HostReadinessReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?
    init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }
    func finish(_ result: Bool?) {
        let continuation = lock.withLock { defer { self.continuation = nil }; return self.continuation }
        continuation?.resume(returning: result)
    }
}

private final class BrokerConnectionService: NSObject, BlocksActionBrokerHostXPCProtocol, BlocksActionBrokerClientXPCProtocol {
    func probeRegisteredHostReadiness(withReply reply: @escaping (Bool) -> Void) {
        guard hostProcessID != nil, updateAdmission.isAcceptingOperations else { reply(false); return }
        Task {
            let ready = await router.probeReadiness(ownerID: registrationOwnerID)
            reply(ready && updateAdmission.isAcceptingOperations)
        }
    }
    func probe(withReply reply: @escaping () -> Void) { reply() }
    func probeUpdateLifecycle(withReply reply: @escaping () -> Void) {
        guard hostProcessID != nil else { return }
        reply()
    }

    func prepareForApplicationUpdate(_ token: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard hostProcessID != nil else { reply(false, ActionBrokerUpdateError.untrustedPeer.wireCode); return }
        do { try updateAdmission.prepare(token: token); reply(true, nil) }
        catch { reply(false, ((error as? ActionBrokerUpdateError) ?? .preparationRejected).wireCode) }
    }

    func resumeAfterCancelledApplicationUpdate(_ token: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard hostProcessID != nil else { reply(false, ActionBrokerUpdateError.untrustedPeer.wireCode); return }
        do { try updateAdmission.resume(token: token); reply(true, nil) }
        catch { reply(false, ((error as? ActionBrokerUpdateError) ?? .preparationRejected).wireCode) }
    }

    private let router: ActionHostRouter
    private let hostProcessID: pid_t?
    private let updateAdmission: ActionBrokerUpdateAdmission
    private let registrationOwnerID = UUID()

    init(router: ActionHostRouter, hostProcessID: pid_t?, updateAdmission: ActionBrokerUpdateAdmission) {
        self.router = router
        self.hostProcessID = hostProcessID
        self.updateAdmission = updateAdmission
    }

    func registerHost(
        _ endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard let hostProcessID else {
            reply(false, "Only the Blocks App can register an action host.")
            return
        }
        guard let lease = updateAdmission.begin() else { reply(false, "Action Broker is preparing to update."); return }
        Task {
            defer { lease.release() }
            await router.register(endpoint: endpoint, processID: hostProcessID, ownerID: registrationOwnerID)
            reply(true, nil)
        }
    }

    func submit(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard let lease = updateAdmission.begin() else {
            reply(Self.failure(requestData: requestData, code: "application_update_preparing", message: "Blocks is preparing to update. Retry after it restarts."))
            return
        }
        let once = ReplyOnce { data in defer { lease.release() }; reply(data) }
        Task {
            if await router.waitForHost(timeout: .zero) == nil {
                launchMainApp()
            }
            guard let route = await router.acquireHost() else {
                once.send(Self.failure(
                    requestData: requestData,
                    code: "app_host_unavailable",
                    message: "Blocks did not register its action host within 8 seconds."
                ))
                return
            }
            let host = route.connection
            let routeReply = ReplyOnce { data in defer { route.finish() }; once.send(data) }
            let proxy = host.remoteObjectProxyWithErrorHandler { error in
                Task { await self.router.clear(host) }
                routeReply.send(Self.failure(
                    requestData: requestData,
                    code: "app_host_connection_failed",
                    message: error.localizedDescription
                ))
            } as? BlocksActionHostXPCProtocol
            guard let proxy else {
                routeReply.send(Self.failure(
                    requestData: requestData,
                    code: "app_host_proxy_unavailable",
                    message: "The Blocks action host proxy is unavailable."
                ))
                return
            }
            proxy.execute(requestData, outputFile: outputFile) { data in
                routeReply.send(data)
            }
        }
    }

    func listActions(withReply reply: @escaping (Data) -> Void) {
        guard let lease = updateAdmission.begin() else {
            reply(CLIActionListResponse.failure("application_update_preparing", "Blocks is preparing to update.")); return
        }
        let once = ReplyOnce { data in defer { lease.release() }; reply(data) }
        Task {
            if await router.waitForHost(timeout: .zero) == nil { launchMainApp() }
            guard let route = await router.acquireHost() else {
                once.send(CLIActionListResponse.failure("app_host_unavailable", "Blocks did not register its action host.")); return
            }
            let host = route.connection
            let routeReply = ReplyOnce { data in defer { route.finish() }; once.send(data) }
            let proxy = host.remoteObjectProxyWithErrorHandler { _ in
                Task { await self.router.clear(host) }
                routeReply.send(CLIActionListResponse.failure("app_host_connection_failed", "The Blocks action host is unavailable."))
            } as? BlocksActionHostXPCProtocol
            guard let proxy else {
                routeReply.send(CLIActionListResponse.failure("app_host_proxy_unavailable", "The Blocks action host is unavailable.")); return
            }
            let invoked: Void? = proxy.listActions?(withReply: { routeReply.send($0) })
            if invoked == nil {
                routeReply.send(CLIActionListResponse.failure("upgrade_required", "Restart or upgrade Blocks to load its module authorization policy."))
            }
        }
    }

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let lease = updateAdmission.begin() else { reply(false); return }
        let once = BooleanReplyOnce { value in defer { lease.release() }; reply(value) }
        Task {
            guard let route = await router.acquireHost(timeout: .zero) else {
                once.send(false)
                return
            }
            let host = route.connection
            let routeReply = BooleanReplyOnce { value in defer { route.finish() }; once.send(value) }
            let proxy = host.remoteObjectProxyWithErrorHandler { _ in
                Task { await self.router.clear(host) }
                routeReply.send(false)
            } as? BlocksActionHostXPCProtocol
            guard let proxy else {
                routeReply.send(false)
                return
            }
            proxy.cancel(requestID) { cancelled in
                routeReply.send(cancelled)
            }
        }
    }

    private func launchMainApp() {
        guard let launchLease = updateAdmission.begin() else { return }
        guard let appURL = Self.embeddedMainAppURL()
            ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: BlocksActionBrokerXPC.appBundleIdentifier
            ) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in launchLease.release() }
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
    private let updateAdmission = ActionBrokerUpdateAdmission()
    #if !BLOCKS_LOCAL_DEVELOPMENT
    // Both startup and peer Security APIs stay on this bounded utility worker.
    // The running-self result, including failure, is cached before listening.
    private let identityWorker = ActionBrokerIdentityWorker<SecCode, SecStaticCode>(operations: .system)
    private let identityDiagnostics = ActionBrokerIdentityDiagnosticLimiter()
    private let identityLogger = Logger(subsystem: "app.blocks.action-broker", category: "Identity")

    func prepare(completion: @escaping @Sendable (Bool) -> Void) {
        identityWorker.prepare { [weak self] result in
            if case let .failure(failure) = result { self?.recordIdentityFailure(failure); completion(false) }
            else { completion(true) }
        }
    }

    private func recordIdentityFailure(_ failure: ActionBrokerIdentityFailure) {
        guard identityDiagnostics.shouldLog(failure) else { return }
        let status = failure.osStatus.map { String($0) } ?? "none"
        identityLogger.error("Connection identity rejected subject=\(failure.subject.rawValue, privacy: .public) stage=\(failure.stage.rawValue, privacy: .public) reason=\(failure.reason.rawValue, privacy: .public) osstatus=\(status, privacy: .public)")
    }
    #endif
    #if BLOCKS_LOCAL_DEVELOPMENT
    private let localIdentityQueue = DispatchQueue(label: "app.blocks.broker-local-identity", qos: .utility)
    private let localIdentityAdmission = ActionBrokerSecurityWorkAdmission()
    func prepare(completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
    #endif

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), connection.processIdentifier > 0 else { return false }
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard let ticket = localIdentityAdmission.reserve() else { return false }
        #else
        guard let ticket = identityWorker.reserveAuthorization() else { return false }
        #endif
        let pending = PendingBrokerConnection(connection, ticket: ticket)
        connection.invalidationHandler = { [weak pending] in pending?.cancel() }
        // Returning YES does not export or resume the connection. The SDK
        // explicitly permits deferred resume after asynchronous authentication.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { pending.cancel() }
        #if BLOCKS_LOCAL_DEVELOPMENT
        localIdentityQueue.async { [weak self] in
            defer { ticket.finish() }
            guard !ticket.isCancelled else { return }
            guard let self, let role = pending.localRole() else { pending.cancel(); return }
            guard let connection = pending.claimConnection() else { return }
            self.export(connection, isHost: role == .appHost)
        }
        #else
        identityWorker.authorizeCandidate(
            processID: connection.processIdentifier,
            effectiveUserID: connection.effectiveUserIdentifier,
            currentUserID: getuid(),
            reservation: ticket
        ) { [weak self] result in
            guard let self else { pending.cancel(); return }
            switch result {
            case let .success(authorization):
                guard let connection = pending.claimConnection() else { return }
                // Classifying a PID never grants a protocol. Bind the actual
                // connection to the exact authenticated role before exporting.
                connection.setCodeSigningRequirement(authorization.connectionRequirement)
                self.export(connection, isHost: authorization.role == .appHost)
            case let .failure(failure):
                self.recordIdentityFailure(failure)
                pending.cancel()
            }
        }
        #endif
        return true
    }

    private func export(_ connection: NSXPCConnection, isHost: Bool) {
        let hostProcessID: pid_t?
        if isHost {
            connection.exportedInterface = NSXPCInterface(with: BlocksActionBrokerHostXPCProtocol.self)
            hostProcessID = connection.processIdentifier
        } else {
            connection.exportedInterface = NSXPCInterface(with: BlocksActionBrokerClientXPCProtocol.self)
            hostProcessID = nil
        }
        connection.exportedObject = BrokerConnectionService(
            router: router,
            hostProcessID: hostProcessID,
            updateAdmission: updateAdmission
        )
        connection.resume()
    }
}

/// Keeps the not-yet-resumed connection alive, and fences late worker results
/// after a bounded authentication wait or XPC invalidation.
private final class PendingBrokerConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let ticket: ActionBrokerSecurityWorkAdmission.Ticket
    init(_ connection: NSXPCConnection, ticket: ActionBrokerSecurityWorkAdmission.Ticket) {
        self.connection = connection
        self.ticket = ticket
    }
    func claimConnection() -> NSXPCConnection? { ticket.claimResult() ? connection : nil }
    func cancel() { if ticket.cancel() { connection.invalidate() } }
    #if BLOCKS_LOCAL_DEVELOPMENT
    func localRole() -> BlocksPeerIdentityValidator.PeerRole? {
        guard !ticket.isCancelled else { return nil }
        return BlocksPeerIdentityValidator.role(for: connection)
    }
    #endif
}

#if BLOCKS_LOCAL_DEVELOPMENT
private enum BlocksPeerIdentityValidator {
    enum PeerRole: Equatable {
        case appHost
        case client
    }

    static func role(for connection: NSXPCConnection) -> PeerRole? {
        guard connection.effectiveUserIdentifier == getuid(),
              connection.processIdentifier > 0 else {
            return nil
        }
        if BlocksLocalBuildTrust.accepts(processIdentifier: connection.processIdentifier,
                                        userIdentifier: connection.effectiveUserIdentifier, role: "app") {
            return .appHost
        }
        if BlocksLocalBuildTrust.accepts(processIdentifier: connection.processIdentifier,
                                        userIdentifier: connection.effectiveUserIdentifier, role: "cli") {
            return .client
        }
        return nil
    }
}
#endif

private let delegate = BrokerListenerDelegate()
private let listener = NSXPCListener(machServiceName: BlocksActionBrokerXPC.machServiceName)
listener.delegate = delegate
delegate.prepare { ready in
    DispatchQueue.main.async {
        guard ready else { exit(EXIT_FAILURE) }
        listener.resume()
    }
}
RunLoop.current.run()
