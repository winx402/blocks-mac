import BlocksCore
import Foundation
import Security

private struct ActionBrokerRequestHeader: Decodable, Sendable {
    let requestID: ActionRequestID
    let actionID: ActionID

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case actionID = "action_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(
            Int.self,
            forKey: .protocolVersion
        )
        guard protocolVersion
                == ActionBrokerRequest<JSONValue>.currentProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription:
                    "Unsupported action broker protocol version."
            )
        }
        requestID = try container.decode(
            ActionRequestID.self,
            forKey: .requestID
        )
        actionID = try container.decode(
            ActionID.self,
            forKey: .actionID
        )
    }
}

@MainActor
protocol ActionBrokerHosting: AnyObject {
    func revokeModule(_ module: CLIModule)
    func start(
        completion: @escaping (Result<Void, Error>) -> Void,
        onInvalidated: @escaping () -> Void
    )
    func stop()
    func pauseAndDrainForApplicationUpdate() async throws
    func resumeAfterCancelledApplicationUpdate()
    func prepareBrokerForApplicationUpdate(token: String) async throws -> Int32
    func resumeBrokerAfterCancelledApplicationUpdate(token: String) async throws
}

extension ActionBrokerHosting {
    func revokeModule(_ module: CLIModule) {}
    func pauseAndDrainForApplicationUpdate() async throws {
        throw ApplicationOperationAdmissionGate.AdmissionError.paused("Action Broker lifecycle adapter is unavailable")
    }
    func resumeAfterCancelledApplicationUpdate() {}
    func prepareBrokerForApplicationUpdate(token: String) async throws -> Int32 { throw ActionBrokerUpdateError.unsupportedPeer }
    func resumeBrokerAfterCancelledApplicationUpdate(token: String) async throws { throw ActionBrokerUpdateError.unsupportedPeer }
}

private func actionBrokerConnectionRequirement() -> String? {
    #if BLOCKS_LOCAL_DEVELOPMENT
    return BlocksLocalBuildTrust.connectionRequirement(role: "broker")
    #else
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [CFString: Any],
          let team = values[kSecCodeInfoTeamIdentifier] as? String,
          team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
    return "anchor apple generic and identifier \"app.blocks.action-broker\" and certificate leaf[subject.OU] = \"\(team)\""
    #endif
}

private final class ActionBrokerLifecycleReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { defer { self.continuation = nil }; return self.continuation }
        continuation?.resume(with: result)
    }
}

/// Keeps XPC callbacks tied to the connection that created them.  This is
/// deliberately separate from NSXPCConnection so it can be checked without
/// launching a LaunchAgent.
final class ActionBrokerHostConnectionLifecycle {
    private(set) var generation = 0
    private(set) var isListenerResumed = false
    private var completedGeneration: Int?
    private var registeredGeneration: Int?
    private var serviceResumeRequested = false

    func beginConnection() -> (generation: Int, shouldResumeListener: Bool) {
        let shouldResumeListener = !isListenerResumed
        generation &+= 1
        completedGeneration = nil
        registeredGeneration = nil
        isListenerResumed = true
        return (generation, shouldResumeListener)
    }

    func stop() -> Bool {
        let shouldSuspendListener = isListenerResumed
        generation &+= 1
        completedGeneration = nil
        isListenerResumed = false
        registeredGeneration = nil
        return shouldSuspendListener
    }

    func isCurrent(_ candidate: Int) -> Bool {
        candidate == generation && isListenerResumed
    }

    func claimCompletion(for candidate: Int) -> Bool {
        guard isCurrent(candidate), completedGeneration != candidate else {
            return false
        }
        completedGeneration = candidate
        return true
    }

    /// Keep local request admission closed while a replacement endpoint is
    /// being registered; otherwise a request through the old endpoint could
    /// be interrupted when the Broker invalidates that connection.
    func requestServiceResume() -> Bool {
        if isListenerResumed, registeredGeneration == generation { return true }
        serviceResumeRequested = true
        return false
    }

    func didRegisterTrustedHost(for candidate: Int) -> Bool {
        guard isCurrent(candidate), completedGeneration == candidate else { return false }
        registeredGeneration = candidate
        defer { serviceResumeRequested = false }
        return serviceResumeRequested
    }
}

final class ScreenshotActionHost: NSObject, NSXPCListenerDelegate, ActionBrokerHosting {
    private let screenshotStore: ScreenshotStore
    private let historyService: ScreenshotHistoryActionService
    private let translationSourceService:
        TranslationSourceManagementService
    private let pluginDevelopmentService: PluginDevelopmentService
    private let clipboardStore: ClipboardStore?
    private let moduleAccess: CLIModuleAccessPolicy
    private let clipboardManagementAccess = ClipboardManagementAccessController()
    private let listener = NSXPCListener.anonymous()
    private lazy var exportedService = ScreenshotActionHostService(
        executeHandler: { [weak self] data, file in
            await self?.execute(data, outputFile: file) ?? Self.failureData(
                requestID: nil,
                code: "app_host_unavailable",
                message: "The screenshot action host is unavailable."
            )
        },
        cancelHandler: { [weak self] requestID in
            self?.cancel(requestID: requestID) ?? false
        },
        moduleAccess: moduleAccess
    )
    private var brokerConnection: NSXPCConnection?
    #if BLOCKS_LOCAL_DEVELOPMENT
    private let localActionServer = LocalActionTransport.Server()
    #endif
    private var activeRequestID: ActionRequestID?
    private let connectionLifecycle: ActionBrokerHostConnectionLifecycle

    @MainActor func revokeModule(_ module: CLIModule) {
        exportedService.revokeModule(module) { [weak self] requestID in
            _ = self?.cancel(requestID: requestID)
        }
    }

    @MainActor func pauseAndDrainForApplicationUpdate() async throws {
        try exportedService.pauseForApplicationUpdate()
    }

    @MainActor func resumeAfterCancelledApplicationUpdate() {
        #if BLOCKS_LOCAL_DEVELOPMENT
        exportedService.resumeAfterCancelledApplicationUpdate()
        #else
        if connectionLifecycle.requestServiceResume() {
            exportedService.resumeAfterCancelledApplicationUpdate()
        }
        #endif
    }

    @MainActor func prepareBrokerForApplicationUpdate(token: String) async throws -> Int32 {
        let connection = try await authenticatedLifecycleConnection()
        defer { connection.invalidate() }
        try await lifecycleCommand(connection: connection, token: token, preparing: true)
        let processID = connection.processIdentifier
        guard processID > 0 else { throw ActionBrokerUpdateError.untrustedPeer }
        return processID
    }

    @MainActor func resumeBrokerAfterCancelledApplicationUpdate(token: String) async throws {
        let connection = try await authenticatedLifecycleConnection()
        defer { connection.invalidate() }
        try await lifecycleCommand(connection: connection, token: token, preparing: false)
    }

    @MainActor private func authenticatedLifecycleConnection() async throws -> NSXPCConnection {
        guard let requirement = actionBrokerConnectionRequirement() else { throw ActionBrokerUpdateError.untrustedPeer }
        let connection = NSXPCConnection(machServiceName: BlocksActionBrokerXPC.machServiceName)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: BlocksActionBrokerHostXPCProtocol.self)
        connection.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let reply = ActionBrokerLifecycleReply(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer))
                } as? BlocksActionBrokerHostXPCProtocol
                guard let proxy else { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)); return }
                let invoked: Void? = proxy.probeUpdateLifecycle?(withReply: {
                    guard connection.effectiveUserIdentifier == getuid(), connection.processIdentifier > 0 else {
                        reply.finish(.failure(ActionBrokerUpdateError.untrustedPeer)); return
                    }
                    #if BLOCKS_LOCAL_DEVELOPMENT
                    guard BlocksLocalBuildTrust.accepts(processIdentifier: connection.processIdentifier,
                        userIdentifier: connection.effectiveUserIdentifier, role: "broker") else {
                        reply.finish(.failure(ActionBrokerUpdateError.untrustedPeer)); return
                    }
                    #endif
                    reply.finish(.success(()))
                })
                if invoked == nil { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)) }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer))
                }
            }
            return connection
        } catch { connection.invalidate(); throw error }
    }

    @MainActor private func lifecycleCommand(connection: NSXPCConnection, token: String, preparing: Bool) async throws {
        try Task.checkCancellation()
        guard !AppTerminationCoordinator.shared.isQuitting else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = ActionBrokerLifecycleReply(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer))
            } as? BlocksActionBrokerHostXPCProtocol
            guard let proxy else { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)); return }
            let completion: (Bool, String?) -> Void = { accepted, _ in
                reply.finish(accepted ? .success(()) : .failure(ActionBrokerUpdateError.busy))
            }
            let invoked: Void? = preparing
                ? proxy.prepareForApplicationUpdate?(token, withReply: completion)
                : proxy.resumeAfterCancelledApplicationUpdate?(token, withReply: completion)
            if invoked == nil { reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer)) }
            Task {
                try? await Task.sleep(for: .seconds(2))
                reply.finish(.failure(ActionBrokerUpdateError.unsupportedPeer))
            }
        }
    }

    @MainActor init(
        screenshotStore: ScreenshotStore,
        historyService: ScreenshotHistoryActionService,
        translationSourceService: TranslationSourceManagementService,
        pluginDevelopmentService: PluginDevelopmentService,
        clipboardStore: ClipboardStore? = nil,
        moduleAccess: CLIModuleAccessPolicy? = nil,
        connectionLifecycle: ActionBrokerHostConnectionLifecycle = .init()
    ) {
        self.screenshotStore = screenshotStore
        self.historyService = historyService
        self.translationSourceService = translationSourceService
        self.pluginDevelopmentService = pluginDevelopmentService
        self.clipboardStore = clipboardStore
        self.moduleAccess = moduleAccess ?? CLIModuleAccessPolicy()
        self.connectionLifecycle = connectionLifecycle
        super.init()
        listener.delegate = self
        #if BLOCKS_LOCAL_DEVELOPMENT
        exportedService.setIntegrationEnabled(false)
        _ = startLocalActionServer()
        #endif
    }

    #if BLOCKS_LOCAL_DEVELOPMENT
    @MainActor private func startLocalActionServer() -> Bool {
        let service = exportedService
        return localActionServer.start { operation, data, outputFile, reply in
            switch operation {
            case .probe: reply(Data("ready".utf8))
            case .list: service.listActions(withReply: reply)
            case .submit: service.execute(data, outputFile: outputFile, withReply: reply)
            case .cancel:
                guard let requestID = Self.cancellationRequestID(from: data) else {
                    reply(Data("false".utf8)); return
                }
                service.cancel(requestID) { cancelled in
                    reply(Data((cancelled ? "true" : "false").utf8))
                }
            }
        }
    }
    #endif

    nonisolated static func cancellationRequestID(from data: Data) -> String? {
        guard let rawValue = String(data: data, encoding: .utf8),
              let requestID = ActionRequestID(rawValue: rawValue) else { return nil }
        return requestID.rawValue
    }

    deinit {
        #if BLOCKS_LOCAL_DEVELOPMENT
        localActionServer.stop()
        #endif
    }

    @MainActor func start(
        completion: @escaping (Result<Void, Error>) -> Void,
        onInvalidated: @escaping () -> Void
    ) {
        #if BLOCKS_LOCAL_DEVELOPMENT
        exportedService.setIntegrationEnabled(true)
        let started = startLocalActionServer()
        if started {
            exportedService.resumeAfterCancelledApplicationUpdate()
            completion(.success(()))
        } else {
            exportedService.setIntegrationEnabled(false)
            completion(.failure(ScreenshotActionHostError.brokerProxyUnavailable))
        }
        return
        #else
        exportedService.setIntegrationEnabled(true)
        let previousConnection = brokerConnection
        let connectionStart = connectionLifecycle.beginConnection()
        let generation = connectionStart.generation
        if connectionStart.shouldResumeListener {
            listener.resume()
        }
        previousConnection?.invalidate()
        let connection = NSXPCConnection(machServiceName: BlocksActionBrokerXPC.machServiceName)
        guard let requirement = actionBrokerConnectionRequirement() else {
            completion(.failure(ActionBrokerUpdateError.untrustedPeer))
            return
        }
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: BlocksActionBrokerHostXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionLifecycle.isCurrent(generation) else {
                    return
                }
                self.brokerConnection = nil
                if self.connectionLifecycle.claimCompletion(for: generation) {
                    completion(.failure(ScreenshotActionHostError.connectionInvalidated))
                }
                onInvalidated()
            }
        }
        connection.resume()
        brokerConnection = connection
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionLifecycle.isCurrent(generation) else {
                    return
                }
                if self.connectionLifecycle.claimCompletion(for: generation) {
                    completion(.failure(error))
                } else {
                    self.brokerConnection = nil
                    onInvalidated()
                }
            }
        } as? BlocksActionBrokerHostXPCProtocol
        guard let proxy else {
            guard connectionLifecycle.claimCompletion(for: generation) else { return }
            completion(.failure(ScreenshotActionHostError.brokerProxyUnavailable))
            return
        }
        proxy.registerHost(listener.endpoint) { accepted, message in
            #if BLOCKS_LOCAL_DEVELOPMENT
            let trustedBroker = BlocksLocalBuildTrust.accepts(
                processIdentifier: connection.processIdentifier,
                userIdentifier: connection.effectiveUserIdentifier,
                role: "broker"
            )
            #else
            let trustedBroker = connection.processIdentifier > 0 && connection.effectiveUserIdentifier == getuid()
            #endif
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionLifecycle.claimCompletion(for: generation) else {
                    return
                }
                if accepted && trustedBroker,
                   self.connectionLifecycle.didRegisterTrustedHost(for: generation) {
                    self.exportedService.resumeAfterCancelledApplicationUpdate()
                }
                (accepted && trustedBroker)
                    ? completion(.success(()))
                    : completion(.failure(ScreenshotActionHostError.registrationRejected(message)))
            }
        }
        #endif
    }

    @MainActor func stop() {
        for module in CLIModule.allCases { revokeModule(module) }
        exportedService.setIntegrationEnabled(false)
        // The private development endpoint remains bound while disabled, so
        // authenticated clients receive integration_disabled instead of hanging.
        let shouldSuspendListener = connectionLifecycle.stop()
        brokerConnection?.invalidate()
        brokerConnection = nil
        if shouldSuspendListener {
            listener.suspend()
        }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier == getuid() else { return false }
        guard let requirement = actionBrokerConnectionRequirement() else { return false }
        newConnection.setCodeSigningRequirement(requirement)
        #if BLOCKS_LOCAL_DEVELOPMENT
        guard BlocksLocalBuildTrust.accepts(
            processIdentifier: newConnection.processIdentifier,
            userIdentifier: newConnection.effectiveUserIdentifier,
            role: "broker"
        ) else { return false }
        #endif
        newConnection.exportedInterface = NSXPCInterface(with: BlocksActionHostXPCProtocol.self)
        newConnection.exportedObject = exportedService
        newConnection.resume()
        return true
    }

    @MainActor private func execute(_ data: Data, outputFile: FileHandle?) async -> Data {
        let envelope: ActionBrokerRequestHeader
        do {
            envelope = try await Self.decode(
                ActionBrokerRequestHeader.self,
                from: data
            )
        } catch {
            return Self.failureData(
                requestID: nil,
                code: "invalid_request",
                message: "The action request could not be decoded."
            )
        }
        guard moduleAccess.allows(envelope.actionID) else {
            return Self.failureData(requestID: envelope.requestID, actionID: envelope.actionID,
                code: "module_disabled", message: "Enable this CLI module in Blocks settings.")
        }
        switch envelope.actionID {
        case BlocksAction.screenshotCapture.actionID:
            return await executeCapture(data, outputFile: outputFile)
        case BlocksAction.screenshotHistoryQuery.actionID:
            return await executeTyped(
                data,
                action: .screenshotHistoryQuery,
                handler: { [historyService] input, _ in
                    try await historyService.query(input)
                }
            )
        case BlocksAction.screenshotHistorySearch.actionID:
            return await executeTyped(
                data,
                action: .screenshotHistorySearch,
                handler: { [historyService] input, _ in
                    try await historyService.search(input)
                }
            )
        case BlocksAction.screenshotOCRStatus.actionID:
            return await executeTyped(
                data,
                action: .screenshotOCRStatus,
                handler: { [historyService] input, _ in
                    try await historyService.status(input)
                }
            )
        case BlocksAction.screenshotOCRRetry.actionID:
            return await executeTyped(
                data,
                action: .screenshotOCRRetry,
                handler: { [historyService] input, _ in
                    try await historyService.retry(input)
                }
            )
        case BlocksAction.screenshotHistoryExport.actionID:
            return await executeTyped(
                data,
                action: .screenshotHistoryExport,
                handler: { [historyService] input, _ in
                    try await historyService.export(input, outputFile: outputFile)
                }
            )
        case BlocksAction.screenshotScrollingStatus.actionID:
            return await executeTyped(
                data,
                action: .screenshotScrollingStatus,
                handler: { [screenshotStore] (
                    _: ScreenshotScrollingStatusActionInput,
                    _: ActionRequestID
                ) in
                    await screenshotStore.scrollingStatusAction()
                }
            )
        case BlocksAction.screenshotScrollingFinish.actionID:
            return await executeTyped(
                data,
                action: .screenshotScrollingFinish,
                handler: { [screenshotStore] input, _ in
                    await screenshotStore.finishScrollingAction(input)
                }
            )
        case BlocksAction.screenshotScrollingCancel.actionID:
            return await executeTyped(
                data,
                action: .screenshotScrollingCancel,
                handler: { [screenshotStore] input, _ in
                    await screenshotStore.cancelScrollingAction(input)
                }
            )
        case BlocksAction.clipboardManage.actionID:
            return await executeTyped(
                data, action: .clipboardManage,
                handler: { [clipboardStore, clipboardManagementAccess, moduleAccess] (input: ClipboardManagementActionInput, _: ActionRequestID) in
                    guard let clipboardStore else { throw ClipboardManagementError("repository_unavailable") }
                    let revision = moduleAccess.revision(for: .clipboard)
                    return try await clipboardManagementAccess.execute(input) {
                        guard moduleAccess.isEnabled(.clipboard),
                              moduleAccess.revision(for: .clipboard) == revision else {
                            throw ClipboardManagementError("module_disabled")
                        }
                        try Task.checkCancellation()
                        return try await clipboardStore.executeManagement($0)
                    }
                }
            )
        case BlocksAction.translationSourceManage.actionID:
            return await executeTyped(
                data,
                action: .translationSourceManage,
                handler: { [translationSourceService] (
                    input: TranslationSourceManagementActionInput,
                    requestID: ActionRequestID
                ) in
                    try await translationSourceService.execute(
                        input,
                        requestID: requestID
                    )
                }
            )
        case BlocksAction.pluginManage.actionID:
            return await executeTyped(
                data,
                action: .pluginManage,
                handler: { [pluginDevelopmentService] (
                    input: PluginDevelopmentActionInput,
                    requestID: ActionRequestID
                ) in
                    try await pluginDevelopmentService.execute(
                        input,
                        requestID: requestID
                    )
                }
            )
        default:
            return Self.failureData(
                requestID: envelope.requestID,
                actionID: envelope.actionID,
                code: "unsupported_action",
                message: "The requested action is not registered."
            )
        }
    }

    @MainActor private func executeCapture(
        _ data: Data,
        outputFile: FileHandle?
    ) async -> Data {
        let request: ActionBrokerRequest<ScreenshotCaptureActionInput>
        do {
            request = try await Self.decode(
                ActionBrokerRequest<ScreenshotCaptureActionInput>.self,
                from: data
            )
        } catch {
            return Self.failureData(
                requestID: nil,
                code: "invalid_request",
                message: "The capture request could not be decoded."
            )
        }
        guard activeRequestID == nil else {
            return Self.failureData(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "action_in_progress",
                message: "Another screenshot session is already active."
            )
        }

        activeRequestID = request.requestID
        defer { activeRequestID = nil }
        do {
            guard moduleAccess.allows(request.actionID) else {
                return Self.failureData(requestID: request.requestID, actionID: request.actionID,
                    code: "module_disabled", message: "Enable this CLI module in Blocks settings.")
            }
            try Task.checkCancellation()
            let result = try await screenshotStore.executeAction(request.payload, outputFile: outputFile)
            return Self.encode(.completed(
                requestID: request.requestID,
                actionID: request.actionID,
                result: result
            ))
        } catch ScreenshotActionExecutionError.cancelled {
            return Self.encode(ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.cancelled(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "user_cancelled",
                message: "The screenshot session was cancelled."
            ))
        } catch ScreenshotActionExecutionError.sessionInProgress {
            return Self.failureData(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "action_in_progress",
                message: "Another screenshot session is already active."
            )
        } catch ScreenshotActionExecutionError.featureDisabled {
            return Self.failureData(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "feature_disabled",
                message: "Screenshot capture is disabled in Blocks settings."
            )
        } catch is CancellationError {
            return Self.encode(ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.cancelled(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "request_cancelled",
                message: "The screenshot request was cancelled."
            ))
        } catch {
            return Self.encode(ActionBrokerTerminalResponse<ScreenshotCaptureActionResult>.failed(
                requestID: request.requestID,
                actionID: request.actionID,
                error: ActionBrokerError(
                    category: .execution,
                    code: "capture_failed",
                    message: "The screenshot capture failed.",
                    retryable: false
                )
            ))
        }
    }

    @MainActor private func executeTyped<
        Input: Codable & Sendable,
        Result: Codable & Sendable
    >(
        _ data: Data,
        action: BlocksAction,
        handler: (Input, ActionRequestID) async throws -> Result
    ) async -> Data {
        let request: ActionBrokerRequest<Input>
        do {
            request = try await Self.decode(
                ActionBrokerRequest<Input>.self,
                from: data
            )
        } catch let error as ScreenshotHistoryActionValidationError {
            return Self.failureData(
                requestID: nil,
                actionID: action.actionID,
                code: error.code,
                message: error.message
            )
        } catch let error as ScreenshotScrollingActionValidationError {
            return Self.failureData(
                requestID: nil,
                actionID: action.actionID,
                code: error.code,
                message: error.message
            )
        } catch {
            return Self.failureData(
                requestID: nil,
                actionID: action.actionID,
                code: "invalid_request",
                message: "The action request could not be decoded."
            )
        }
        guard request.actionID == action.actionID else {
            return Self.failureData(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "action_mismatch",
                message: "The request payload does not match the action."
            )
        }
        do {
            guard moduleAccess.allows(request.actionID) else {
                return Self.failureData(requestID: request.requestID, actionID: request.actionID,
                    code: "module_disabled", message: "Enable this CLI module in Blocks settings.")
            }
            try Task.checkCancellation()
            let result = try await handler(
                request.payload,
                request.requestID
            )
            let terminal = ActionBrokerTerminalResponse.completed(
                requestID: request.requestID,
                actionID: request.actionID,
                result: result
            )
            // Large migration documents must not be serialized on the UI
            // thread. Host update admission is held until this reply completes.
            if action == .clipboardManage,
               let input = request.payload as? ClipboardManagementActionInput,
               var managementResult = result as? ClipboardManagementResult {
                while true {
                    let moduleEnabled = moduleAccess.isEnabled(.clipboard)
                    if !moduleEnabled, !input.isMutating || input.dryRun { throw ClipboardManagementError("module_disabled") }
                    let allowed = moduleEnabled && ((UserDefaults.standard.object(forKey: "clipboard.agent.summaryAccess") as? Bool) ?? true)
                    managementResult = try ClipboardManagementAccessController.prepareForDelivery(
                        managementResult, input: input, summaryAllowed: allowed)
                    let response = ActionBrokerTerminalResponse.completed(
                        requestID: request.requestID, actionID: request.actionID, result: managementResult)
                    let encoded = await Task.detached(priority: .utility) { Self.encode(response) }.value
                    let currentModuleEnabled = moduleAccess.isEnabled(.clipboard)
                    if !currentModuleEnabled, !input.isMutating || input.dryRun { throw ClipboardManagementError("module_disabled") }
                    let currentAllowed = currentModuleEnabled && ((UserDefaults.standard.object(forKey: "clipboard.agent.summaryAccess") as? Bool) ?? true)
                    managementResult = try ClipboardManagementAccessController.prepareForDelivery(
                        managementResult, input: input, summaryAllowed: currentAllowed)
                    // No await between this final check and handing the bytes
                    // to the host service. A revoked summary is re-encoded.
                    if allowed && !currentAllowed { continue }
                    return encoded
                }
            }
            return Self.encode(terminal)
        } catch let error as ClipboardManagementError {
            return Self.encode(ActionBrokerTerminalResponse<Result>.failed(
                requestID: request.requestID, actionID: action.actionID,
                error: ActionBrokerError(category: .invalidRequest, code: error.code,
                                         message: error.code == "full_content_requires_visible_window"
                                            ? "Open a Blocks window, then retry and confirm the requested clipboard scope."
                                            : error.localizedDescription, retryable: false)
            ))
        } catch let error as ScreenshotHistoryActionServiceError {
            return Self.encode(ActionBrokerTerminalResponse<Result>.failed(
                requestID: request.requestID,
                actionID: request.actionID,
                error: ActionBrokerError(
                    category: error == .invalidCursor ? .invalidRequest : .execution,
                    code: error.code,
                    message: Self.serviceErrorMessage(error),
                    retryable: false
                )
            ))
        } catch let error as TranslationSourceManagementServiceError {
            return Self.encode(ActionBrokerTerminalResponse<Result>.failed(
                requestID: request.requestID,
                actionID: request.actionID,
                error: ActionBrokerError(
                    category: .invalidRequest,
                    code: error.code,
                    message: error.localizedDescription,
                    retryable: false
                )
            ))
        } catch let error as BlocksNativePluginManagerError {
            return Self.encode(ActionBrokerTerminalResponse<Result>.failed(
                requestID: request.requestID,
                actionID: request.actionID,
                error: ActionBrokerError(
                    category: .invalidRequest,
                    code: error.code,
                    message:
                        error.localizedDescription,
                    retryable: error == .operationInProgress
                )
            ))
        } catch is CancellationError {
            return Self.encode(ActionBrokerTerminalResponse<Result>.cancelled(
                requestID: request.requestID,
                actionID: request.actionID,
                code: "request_cancelled",
                message: "The action request was cancelled."
            ))
        } catch {
            return Self.encode(ActionBrokerTerminalResponse<Result>.failed(
                requestID: request.requestID,
                actionID: request.actionID,
                error: ActionBrokerError(
                    category: .execution,
                    code: "action_failed",
                    message: "The action failed.",
                    retryable: false
                )
            ))
        }
    }

    nonisolated private static func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from data: Data
    ) async throws -> Value {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(type, from: data)
        }.value
    }

    @MainActor private func cancel(requestID: String) -> Bool {
        let translationCancellationRequested =
            translationSourceService.cancelActionRequest(requestID)
        let pluginCancellationRequested =
            pluginDevelopmentService.cancel(requestID)
        guard activeRequestID?.rawValue == requestID else {
            return translationCancellationRequested
                || pluginCancellationRequested
        }
        screenshotStore.cancelCurrentActionRequest()
        return true
    }

    private static func failureData(
        requestID: ActionRequestID?,
        actionID: ActionID = BlocksAction.screenshotCapture.actionID,
        code: String,
        message: String
    ) -> Data {
        encode(ActionBrokerTerminalResponse<JSONValue>.failed(
            requestID: requestID ?? ActionRequestID.make(),
            actionID: actionID,
            error: ActionBrokerError(
                category: .invalidRequest,
                code: code,
                message: message,
                retryable: false
            )
        ))
    }

    nonisolated private static func encode<Result: Codable>(_ response: ActionBrokerTerminalResponse<Result>) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    private static func serviceErrorMessage(_ error: ScreenshotHistoryActionServiceError) -> String {
        switch error {
        case .invalidCursor: "The cursor is invalid for this query."
        case .repositoryUnavailable: "Screenshot history is unavailable."
        case .recordNotFound: "The screenshot record was not found."
        case .notImage: "The requested record is not an image."
        case .ocrLocked: "OCR is locked by a user edit."
        case .alreadyRunning: "OCR is already running for this screenshot."
        case .retryRejected: "OCR retry could not be queued."
        case .outputFileRequired: "An output file is required."
        case .exportFailed: "The screenshot could not be exported."
        }
    }
}

final class ScreenshotActionHostService: NSObject, BlocksActionHostXPCProtocol {
    private let applicationUpdateGate = ApplicationOperationAdmissionGate(name: "Action Broker requests")

    func pauseForApplicationUpdate() throws { try applicationUpdateGate.pauseIfIdle() }
    func resumeAfterCancelledApplicationUpdate() { applicationUpdateGate.resume() }
    typealias Handler = @MainActor (Data, FileHandle?) async -> Data
    typealias CancelHandler = @MainActor (String) async -> Bool
    private let handler: Handler
    private let cancelHandler: CancelHandler
    private let moduleAccess: CLIModuleAccessPolicy?
    @MainActor private var integrationEnabled = true
    private let lock = NSLock()
    private var executions: [String: Execution] = [:]

    init(
        executeHandler: @escaping Handler,
        cancelHandler: @escaping CancelHandler,
        moduleAccess: CLIModuleAccessPolicy? = nil
    ) {
        handler = executeHandler
        self.cancelHandler = cancelHandler
        self.moduleAccess = moduleAccess
    }

    func listActions(withReply reply: @escaping (Data) -> Void) {
        guard let lease = applicationUpdateGate.begin() else {
            reply(CLIActionListResponse.failure("application_update_preparing", "Blocks is preparing to update.")); return
        }
        Task { @MainActor in
            defer { lease.release() }
            guard integrationEnabled else {
                reply(CLIActionListResponse.failure("integration_disabled", "CLI integration is disabled.")); return
            }
            guard let moduleAccess else {
                reply(CLIActionListResponse.failure("module_policy_unavailable", "Module authorization is unavailable.")); return
            }
            reply((try? JSONEncoder().encode(CLIActionListResponse(actions: moduleAccess.actions))) ?? Data())
        }
    }

    @MainActor func revokeModule(_ module: CLIModule, invalidate: ((String) -> Void)? = nil) {
        let revoked = lock.withLock {
            executions.values.filter { $0.module == module }.map { execution in
                execution.isCancelled = true
                execution.isRevoked = true
                return (execution.requestID, execution.task)
            }
        }
        for (requestID, task) in revoked {
            // Production invalidates Store/service request tokens synchronously
            // before task cancellation can unwind an awaited side effect.
            invalidate?(requestID)
            task?.cancel()
            if invalidate == nil { Task { @MainActor in _ = await cancelHandler(requestID) } }
        }
    }

    @MainActor func setIntegrationEnabled(_ enabled: Bool) {
        integrationEnabled = enabled
        if !enabled { for module in CLIModule.allCases { revokeModule(module) } }
    }

    func execute(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    ) {
        // Bound parsing before even decoding the header. All binary import
        // data is inline; no caller-controlled path reaches the sandboxed App.
        guard requestData.count <= ClipboardManagementLimits.maxDocumentBytes + 4 * 1024 * 1024 else {
            reply((try? JSONEncoder().encode(ActionBrokerTerminalResponse<JSONValue>.failed(
                requestID: .make(), actionID: ActionID(rawValue: "unknown")!,
                error: ActionBrokerError(category: .invalidRequest, code: "request_too_large",
                                         message: "The action request exceeds the size limit.", retryable: false)
            ))) ?? Data())
            return
        }
        let requestHeader = try? JSONDecoder().decode(
            ActionBrokerRequestHeader.self,
            from: requestData
        )
        let requestID = requestHeader?.requestID.rawValue ?? UUID().uuidString
        guard let lease = applicationUpdateGate.begin() else {
            if let requestHeader {
                reply((try? JSONEncoder().encode(
                    ActionBrokerTerminalResponse<JSONValue>.failed(
                        requestID: requestHeader.requestID, actionID: requestHeader.actionID,
                        error: ActionBrokerError(category: .invalidRequest, code: "application_update_preparing",
                            message: "Blocks is preparing to update. Retry after it restarts.", retryable: true)
                    )
                )) ?? Data())
            } else { reply(Data()) }
            return
        }
        let execution = Execution(requestID: requestID, module: requestHeader.flatMap { CLIModule.module(for: $0.actionID) })
        lock.lock()
        let isDuplicate = requestHeader != nil && executions[requestID] != nil
        if !isDuplicate {
            executions[requestID] = execution
        }
        lock.unlock()
        if isDuplicate, let requestHeader {
            reply(Self.duplicateRequestIDFailure(
                requestID: requestHeader.requestID,
                actionID: requestHeader.actionID
            ))
            return
        }
        let task = Task { @MainActor [weak self, execution] in
            defer { lease.release() }
            defer { self?.remove(execution) }
            guard let self else { return }
            guard self.integrationEnabled else {
                if let requestHeader { reply(Self.moduleDisabledFailure(requestHeader)) }
                else { reply(Data()) }
                return
            }
            if let moduleAccess = self.moduleAccess, let requestHeader,
               !moduleAccess.allows(requestHeader.actionID) || self.wasRevoked(execution) {
                reply(Self.moduleDisabledFailure(requestHeader))
                return
            }
            let response = await self.handler(requestData, outputFile)
            if let moduleAccess = self.moduleAccess, let requestHeader,
               (!moduleAccess.allows(requestHeader.actionID) || self.wasRevoked(execution) || !self.integrationEnabled),
               Self.requiresAuthorizedDelivery(requestData, actionID: requestHeader.actionID) {
                reply(Self.moduleDisabledFailure(requestHeader))
                return
            }
            reply(response)
        }
        lock.lock()
        execution.task = task
        let shouldCancel = execution.isCancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    /// Reads must still be authorized at delivery. Mutations retain their
    /// actual outcome: revocation cannot claim a committed write rolled back.
    private static func requiresAuthorizedDelivery(_ data: Data, actionID: ActionID) -> Bool {
        switch BlocksAction(rawValue: actionID.rawValue) {
        case .screenshotHistoryQuery, .screenshotHistorySearch, .screenshotOCRStatus, .screenshotScrollingStatus:
            return true
        case .clipboardManage, .translationSourceManage, .pluginManage:
            struct Scope: Decodable {
                struct Payload: Decodable {
                    let operation: String
                    let dryRun: Bool?
                    enum CodingKeys: String, CodingKey { case operation; case dryRun = "dry_run" }
                }
                let payload: Payload
            }
            guard let scope = try? JSONDecoder().decode(Scope.self, from: data) else { return true }
            if scope.payload.dryRun == true { return true }
            switch BlocksAction(rawValue: actionID.rawValue) {
            case .clipboardManage: return ["list", "search", "pinboard_list", "show", "export"].contains(scope.payload.operation)
            case .translationSourceManage: return ["list", "scaffold", "validate_package", "inspect_package", "inspect_installed", "export_redacted"].contains(scope.payload.operation)
            case .pluginManage: return ["list", "inspect", "catalog_list", "show_logs"].contains(scope.payload.operation)
            default: return true
            }
        default: return false
        }
    }

    private static func moduleDisabledFailure(_ header: ActionBrokerRequestHeader) -> Data {
        (try? JSONEncoder().encode(ActionBrokerTerminalResponse<JSONValue>.failed(
            requestID: header.requestID, actionID: header.actionID,
            error: ActionBrokerError(category: .invalidRequest, code: "module_disabled",
                message: "Enable this CLI module in Blocks settings.", retryable: false,
                details: ["module": .string(CLIModule.module(for: header.actionID)?.rawValue ?? "unknown")])
        ))) ?? Data()
    }

    private static func duplicateRequestIDFailure(
        requestID: ActionRequestID,
        actionID: ActionID
    ) -> Data {
        (try? JSONEncoder().encode(
            ActionBrokerTerminalResponse<JSONValue>.failed(
                requestID: requestID,
                actionID: actionID,
                error: ActionBrokerError(
                    category: .invalidRequest,
                    code: "duplicate_request_id",
                    message: "An action request with this request ID is already running.",
                    retryable: false
                )
            )
        )) ?? Data()
    }

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let lease = applicationUpdateGate.begin() else { reply(false); return }
        let execution = markCancelled(requestID: requestID)
        Task { @MainActor [weak self] in
            defer { lease.release() }
            guard let self else {
                reply(execution != nil)
                return
            }
            let cancellationRequested = await self.cancelHandler(requestID)
            // The host cancellation handler first invalidates the matching
            // Store request token and revokes pending sink admissions. Only
            // then may task cancellation unwind the request body.
            execution?.task?.cancel()
            if let execution,
               let task = await self.waitForTask(execution) {
                await task.value
            }
            reply(cancellationRequested || execution != nil)
        }
    }

    private func markCancelled(requestID: String) -> Execution? {
        lock.lock()
        defer { lock.unlock() }
        let execution = executions[requestID]
        execution?.isCancelled = true
        return execution
    }

    private func wasRevoked(_ execution: Execution) -> Bool {
        lock.withLock { execution.isRevoked }
    }

    private func remove(_ execution: Execution) {
        lock.lock()
        if executions[execution.requestID] === execution {
            executions[execution.requestID] = nil
        }
        lock.unlock()
    }

    private func waitForTask(_ execution: Execution) async -> Task<Void, Never>? {
        for _ in 0..<100 {
            let (task, isRegistered) = executionSnapshot(execution)
            if let task { return task }
            if !isRegistered { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func executionSnapshot(
        _ execution: Execution
    ) -> (Task<Void, Never>?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            execution.task,
            executions[execution.requestID] === execution
        )
    }

    private final class Execution: @unchecked Sendable {
        let requestID: String
        let module: CLIModule?
        var task: Task<Void, Never>?
        var isCancelled = false
        var isRevoked = false

        init(requestID: String, module: CLIModule?) {
            self.requestID = requestID
            self.module = module
        }
    }
}

private enum ScreenshotActionHostError: LocalizedError {
    case brokerProxyUnavailable
    case connectionInvalidated
    case registrationRejected(String?)

    var errorDescription: String? {
        switch self {
        case .brokerProxyUnavailable:
            "The action broker proxy is unavailable."
        case .connectionInvalidated:
            "The action broker connection was interrupted."
        case let .registrationRejected(message):
            message ?? "The action broker rejected the App host."
        }
    }
}
