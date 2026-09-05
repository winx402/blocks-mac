import BlocksCore
import Foundation

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
    func start(
        completion: @escaping (Result<Void, Error>) -> Void,
        onInvalidated: @escaping () -> Void
    )
    func stop()
}

/// Keeps XPC callbacks tied to the connection that created them.  This is
/// deliberately separate from NSXPCConnection so it can be checked without
/// launching a LaunchAgent.
final class ActionBrokerHostConnectionLifecycle {
    private(set) var generation = 0
    private(set) var isListenerResumed = false
    private var completedGeneration: Int?

    func beginConnection() -> (generation: Int, shouldResumeListener: Bool) {
        let shouldResumeListener = !isListenerResumed
        generation &+= 1
        completedGeneration = nil
        isListenerResumed = true
        return (generation, shouldResumeListener)
    }

    func stop() -> Bool {
        let shouldSuspendListener = isListenerResumed
        generation &+= 1
        completedGeneration = nil
        isListenerResumed = false
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
}

final class ScreenshotActionHost: NSObject, NSXPCListenerDelegate, ActionBrokerHosting {
    private let screenshotStore: ScreenshotStore
    private let historyService: ScreenshotHistoryActionService
    private let translationSourceService:
        TranslationSourceManagementService
    private let pluginDevelopmentService: PluginDevelopmentService
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
        }
    )
    private var brokerConnection: NSXPCConnection?
    private var activeRequestID: ActionRequestID?
    private let connectionLifecycle: ActionBrokerHostConnectionLifecycle

    @MainActor init(
        screenshotStore: ScreenshotStore,
        historyService: ScreenshotHistoryActionService,
        translationSourceService: TranslationSourceManagementService,
        pluginDevelopmentService: PluginDevelopmentService,
        connectionLifecycle: ActionBrokerHostConnectionLifecycle = .init()
    ) {
        self.screenshotStore = screenshotStore
        self.historyService = historyService
        self.translationSourceService = translationSourceService
        self.pluginDevelopmentService = pluginDevelopmentService
        self.connectionLifecycle = connectionLifecycle
        super.init()
        listener.delegate = self
    }

    @MainActor func start(
        completion: @escaping (Result<Void, Error>) -> Void,
        onInvalidated: @escaping () -> Void
    ) {
        let previousConnection = brokerConnection
        let connectionStart = connectionLifecycle.beginConnection()
        let generation = connectionStart.generation
        if connectionStart.shouldResumeListener {
            listener.resume()
        }
        previousConnection?.invalidate()
        let connection = NSXPCConnection(machServiceName: BlocksActionBrokerXPC.machServiceName)
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
            Task { @MainActor [weak self] in
                guard let self,
                      self.connectionLifecycle.claimCompletion(for: generation) else {
                    return
                }
                accepted
                    ? completion(.success(()))
                    : completion(.failure(ScreenshotActionHostError.registrationRejected(message)))
            }
        }
    }

    @MainActor func stop() {
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
        Result: Codable
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
            let result = try await handler(
                request.payload,
                request.requestID
            )
            return Self.encode(.completed(
                requestID: request.requestID,
                actionID: request.actionID,
                result: result
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

    private static func encode<Result: Codable>(_ response: ActionBrokerTerminalResponse<Result>) -> Data {
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
    typealias Handler = @MainActor (Data, FileHandle?) async -> Data
    typealias CancelHandler = @MainActor (String) async -> Bool
    private let handler: Handler
    private let cancelHandler: CancelHandler
    private let lock = NSLock()
    private var executions: [String: Execution] = [:]

    init(
        executeHandler: @escaping Handler,
        cancelHandler: @escaping CancelHandler
    ) {
        handler = executeHandler
        self.cancelHandler = cancelHandler
    }

    func execute(
        _ requestData: Data,
        outputFile: FileHandle?,
        withReply reply: @escaping (Data) -> Void
    ) {
        let requestHeader = try? JSONDecoder().decode(
            ActionBrokerRequestHeader.self,
            from: requestData
        )
        let requestID = requestHeader?.requestID.rawValue ?? UUID().uuidString
        let execution = Execution(requestID: requestID)
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
            defer { self?.remove(execution) }
            guard let self else { return }
            reply(await self.handler(requestData, outputFile))
        }
        lock.lock()
        execution.task = task
        let shouldCancel = execution.isCancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
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
        let execution = markCancelled(requestID: requestID)
        Task { @MainActor [weak self] in
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
        var task: Task<Void, Never>?
        var isCancelled = false

        init(requestID: String) {
            self.requestID = requestID
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
