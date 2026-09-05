import BlocksCore
import Darwin
import Foundation
import Security

final class BlocksNativePluginXPCExecutionClient:
    BlocksNativePluginExecuting,
    @unchecked Sendable
{
    typealias ConnectionFactory = @Sendable () -> NSXPCConnection
    typealias MetadataResolver = @Sendable (
        _ pluginID: String
    ) async throws -> BlocksNativePluginMetadata
    typealias HostOperationHandler = @Sendable (
        BlocksPluginHostOperationRequest
    ) -> BlocksPluginHostOperationResponse
    typealias NetworkAuditHandler = @Sendable (
        _ pluginID: String,
        _ entry: [String: JSONValue]
    ) -> Void
    typealias PreExecuteProbe = @Sendable () -> Void

    private let networkBroker: BlocksNativePluginNetworkBroker
    private let connectionFactory: ConnectionFactory
    private let metadataResolver: MetadataResolver
    private let timeoutSeconds: Double
    private let hostOperationHandler: HostOperationHandler
    private let networkAuditHandler: NetworkAuditHandler
    private let preExecuteProbe: PreExecuteProbe
    private let connectionLock = NSLock()
    private var activeConnections:
        [String: [UUID: SendablePluginXPCConnection]] = [:]

    init(
        timeoutSeconds: Double = 30,
        metadataResolver: @escaping MetadataResolver,
        secretResolver: @escaping BlocksNativePluginNetworkBroker.SecretResolver,
        hostOperationHandler: @escaping HostOperationHandler = { request in
            BlocksPluginHostOperationResponse(
                requestID: request.requestID,
                ok: false,
                errorCode: "host_operation_unavailable",
                errorMessage: "The plugin host operation is unavailable."
            )
        },
        networkAuditHandler: @escaping NetworkAuditHandler = { _, _ in },
        connectionFactory: @escaping ConnectionFactory = {
            NSXPCConnection(serviceName: BlocksNativePluginXPC.serviceName)
        },
        preExecuteProbe: @escaping PreExecuteProbe = {}
    ) {
        self.timeoutSeconds = min(max(timeoutSeconds, 1), 60)
        networkBroker = BlocksNativePluginNetworkBroker(
            secretResolver: secretResolver
        )
        self.metadataResolver = metadataResolver
        self.hostOperationHandler = hostOperationHandler
        self.networkAuditHandler = networkAuditHandler
        self.connectionFactory = connectionFactory
        self.preExecuteProbe = preExecuteProbe
    }

    convenience init(
        repository: BlocksNativePluginMetadataRepository,
        timeoutSeconds: Double = 30,
        secretResolver: @escaping BlocksNativePluginNetworkBroker.SecretResolver,
        hostOperationHandler: @escaping HostOperationHandler = { request in
            BlocksPluginHostOperationResponse(
                requestID: request.requestID,
                ok: false,
                errorCode: "host_operation_unavailable",
                errorMessage: "The plugin host operation is unavailable."
            )
        },
        networkAuditHandler: @escaping NetworkAuditHandler = { _, _ in },
        connectionFactory: @escaping ConnectionFactory = {
            NSXPCConnection(serviceName: BlocksNativePluginXPC.serviceName)
        }
    ) {
        self.init(
            timeoutSeconds: timeoutSeconds,
            metadataResolver: { pluginID in
                try repository.metadata(id: pluginID)
            },
            secretResolver: secretResolver,
            hostOperationHandler: hostOperationHandler,
            networkAuditHandler: networkAuditHandler,
            connectionFactory: connectionFactory
        )
    }

    func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata requestedMetadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        try await execute(
            package: package,
            metadata: requestedMetadata,
            invocation: invocation,
            allowDisabled: false,
            progress: progress
        )
    }

    func executeConnectionTest(
        package: BlocksNativePluginValidatedPackage,
        metadata requestedMetadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        try await execute(
            package: package,
            metadata: requestedMetadata,
            invocation: invocation,
            allowDisabled: true,
            progress: progress
        )
    }

    func executePlatform(
        package: BlocksNativePluginValidatedPackage,
        metadata requestedMetadata: BlocksNativePluginMetadata,
        invocation: BlocksPluginRuntimeInvocation,
        timeoutSeconds requestedTimeout: Double,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksPluginRuntimeResult {
        let metadata = try await resolveAuthoritativeMetadata(
            pluginID: requestedMetadata.id,
            package: package,
            platformInvocation: invocation
        )
        try Task.checkCancellation()
        guard package.manifest.schemaVersion >= 4,
              package.manifest.platform != nil else {
            throw BlocksNativePluginExecutionError.capabilityUnavailable
        }
        let executionLimit = min(max(requestedTimeout, 0.05), 60)
        let request = BlocksPluginRunnerRequest(
            manifest: package.manifest,
            entrySource: package.entrySource,
            invocation: invocation,
            executionTimeLimitSeconds: executionLimit
        )
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= 10 * 1_048_576 else {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "request_too_large",
                message: "The plugin runner request is too large."
            )
        }

        let connection = connectionFactory()
        let sendableConnection = SendablePluginXPCConnection(connection)
        connection.remoteObjectInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerXPCProtocol.self
        )
        let replyState = PluginExecutionReplyState()
        let preparationState = PluginRunnerPreparationState()
        connection.interruptionHandler = {
            preparationState.resolve(.failure(
                BlocksNativePluginExecutionError.executionFailed(
                    code: "runner_interrupted",
                    message: "The isolated plugin runner was interrupted."
                )
            ))
            replyState.resolve(.failure(BlocksNativePluginExecutionError.executionFailed(
                code: "runner_interrupted",
                message: "The isolated plugin runner was interrupted."
            )))
        }
        connection.invalidationHandler = {
            preparationState.resolve(.failure(
                BlocksNativePluginExecutionError.executionFailed(
                    code: "runner_invalidated",
                    message: "The isolated plugin runner connection was invalidated."
                )
            ))
            replyState.resolve(.failure(BlocksNativePluginExecutionError.executionFailed(
                code: "runner_invalidated",
                message: "The isolated plugin runner connection was invalidated."
            )))
        }
        register(sendableConnection, pluginID: metadata.id, requestID: invocation.requestID)
        connection.resume()
        defer {
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            unregister(pluginID: metadata.id, requestID: invocation.requestID)
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            preparationState.resolve(.failure(
                BlocksNativePluginExecutionError.executionFailed(
                    code: "runner_connection_failed",
                    message: String(error.localizedDescription.prefix(512))
                )
            ))
            replyState.resolve(.failure(BlocksNativePluginExecutionError.executionFailed(
                code: "runner_connection_failed",
                message: String(error.localizedDescription.prefix(512))
            )))
        }) as? BlocksNativePluginRunnerXPCProtocol else {
            throw BlocksNativePluginExecutionError.runnerUnavailable
        }
        try await prepareRunner(
            proxy: proxy,
            requestID: invocation.requestID,
            connection: sendableConnection,
            state: preparationState
        )
        try Task.checkCancellation()
        let currentMetadata = try await resolveAuthoritativeMetadata(
            pluginID: metadata.id,
            package: package,
            platformInvocation: invocation
        )
        try Task.checkCancellation()
        let approvedMethods = Set(
            currentMetadata.approvedPermissions.compactMap { token -> BlocksNativePluginHTTPMethod? in
                guard token.hasPrefix("method:") else { return nil }
                return BlocksNativePluginHTTPMethod(rawValue: String(token.dropFirst("method:".count)))
            }
        )
        let approvedSecretIDs = Set(
            currentMetadata.approvedPermissions.compactMap { token -> String? in
                guard token.hasPrefix("secret:") else { return nil }
                return String(token.dropFirst("secret:".count))
            }
        )
        let host = BlocksNativePluginInvocationHost(
            pluginID: currentMetadata.id,
            manifest: package.manifest,
            approvedDomains: Set(currentMetadata.approvedDomains),
            approvedMethods: approvedMethods,
            approvedSecretIDs: approvedSecretIDs,
            networkBroker: networkBroker,
            hostOperationHandler: hostOperationHandler,
            networkAuditHandler: networkAuditHandler,
            progress: progress
        )
        try Task.checkCancellation()
        host.start()
        defer { host.shutdown() }
        try Task.checkCancellation()
        preExecuteProbe()
        proxy.executePlatform(requestData, hostEndpoint: host.endpoint) { data in
            replyState.resolve(.success(data))
        }
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(executionLimit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            replyState.resolve(.failure(BlocksNativePluginExecutionError.executionFailed(
                code: "runner_timeout",
                message: "The plugin exceeded the execution time limit."
            )))
            sendableConnection.connection.invalidate()
        }
        defer { timeoutTask.cancel() }
        let responseData = try await withTaskCancellationHandler {
            try await replyState.value()
        } onCancel: {
            replyState.resolve(.failure(CancellationError()))
            proxy.cancel(invocation.requestID.uuidString) { _ in }
            sendableConnection.connection.invalidate()
        }
        guard responseData.count <= 3 * 1_048_576,
              let response = try? JSONDecoder().decode(
                  BlocksPluginRunnerResponse.self,
                  from: responseData
              ),
              response.requestID == invocation.requestID else {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "invalid_runner_response",
                message: "The isolated plugin runner returned an invalid response."
            )
        }
        switch response.status {
        case .completed:
            guard let result = response.result else {
                throw BlocksNativePluginExecutionError.executionFailed(
                    code: "missing_plugin_output",
                    message: "The plugin completed without a result."
                )
            }
            return result
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw BlocksNativePluginExecutionError.executionFailed(
                code: response.errorCode ?? "plugin_execution_failed",
                message: response.errorMessage ?? "The plugin failed."
            )
        }
    }

    private func execute(
        package: BlocksNativePluginValidatedPackage,
        metadata requestedMetadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation,
        allowDisabled: Bool,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) async throws -> BlocksNativePluginOutput {
        if allowDisabled {
            guard invocation.configuration["connection_test"]
                    == .bool(true) else {
                throw BlocksNativePluginExecutionError.executionFailed(
                    code: "invalid_connection_test",
                    message:
                        "Disabled plugins may only execute an explicit connection test."
                )
            }
        }
        let requestedMetadataID = requestedMetadata.id
        let initialMetadata = try await resolveAuthoritativeMetadata(
            pluginID: requestedMetadataID,
            package: package,
            invocation: invocation,
            allowDisabled: allowDisabled
        )
        try Task.checkCancellation()
        try Self.validateDataPermissions(
            package: package,
            metadata: initialMetadata,
            invocation: invocation
        )
        let requiredCapability: BlocksNativePluginCapability = switch invocation.kind {
        case .translation: .translation
        case .ocr: .ocr
        }
        guard package.manifest.capabilities.contains(requiredCapability) else {
            throw BlocksNativePluginExecutionError.capabilityUnavailable
        }

        let request = BlocksNativePluginRunnerRequest(
            manifest: package.manifest,
            entrySource: package.entrySource,
            invocation: invocation,
            executionTimeLimitSeconds: timeoutSeconds
        )
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= 10 * 1_048_576 else {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "request_too_large",
                message: "The plugin runner request is too large."
            )
        }

        let connection = connectionFactory()
        let sendableConnection = SendablePluginXPCConnection(connection)
        connection.remoteObjectInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerXPCProtocol.self
        )
        let replyState = PluginExecutionReplyState()
        let preparationState = PluginRunnerPreparationState()
        connection.interruptionHandler = {
            preparationState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_interrupted",
                        message: "The isolated plugin runner was interrupted."
                    )
                )
            )
            replyState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_interrupted",
                        message: "The isolated plugin runner was interrupted."
                    )
                )
            )
        }
        connection.invalidationHandler = {
            preparationState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_invalidated",
                        message: "The isolated plugin runner connection was invalidated."
                    )
                )
            )
            replyState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_invalidated",
                        message: "The isolated plugin runner connection was invalidated."
                    )
                )
            )
        }
        register(
            sendableConnection,
            pluginID: initialMetadata.id,
            requestID: invocation.requestID
        )
        connection.resume()
        var isRegistered = true
        defer {
            if isRegistered {
                connection.invalidationHandler = nil
                connection.interruptionHandler = nil
                connection.invalidate()
                unregister(
                    pluginID: initialMetadata.id,
                    requestID: invocation.requestID
                )
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            preparationState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_connection_failed",
                        message: String(error.localizedDescription.prefix(512))
                    )
                )
            )
            replyState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_connection_failed",
                        message: String(error.localizedDescription.prefix(512))
                    )
                )
            )
        }) as? BlocksNativePluginRunnerXPCProtocol else {
            connection.invalidate()
            throw BlocksNativePluginExecutionError.runnerUnavailable
        }
        try await prepareRunner(
            proxy: proxy,
            requestID: invocation.requestID,
            connection: sendableConnection,
            state: preparationState
        )
        try Task.checkCancellation()

        // Re-read after registration and immediately before execution. This
        // closes the window where disable/uninstall commits after the initial
        // check but before the XPC connection becomes cancellable.
        let authoritativeMetadata = try await resolveAuthoritativeMetadata(
            pluginID: requestedMetadataID,
            package: package,
            invocation: invocation,
            allowDisabled: allowDisabled
        )
        try Task.checkCancellation()
        try Self.validateDataPermissions(
            package: package,
            metadata: authoritativeMetadata,
            invocation: invocation
        )
        let approvedMethods = Set(
            authoritativeMetadata.approvedPermissions.compactMap {
                token -> BlocksNativePluginHTTPMethod? in
                guard token.hasPrefix("method:") else { return nil }
                return BlocksNativePluginHTTPMethod(
                    rawValue: String(token.dropFirst("method:".count))
                )
            }
        )
        let approvedSecretIDs = Set(
            authoritativeMetadata.approvedPermissions.compactMap {
                token -> String? in
                guard token.hasPrefix("secret:") else { return nil }
                return String(token.dropFirst("secret:".count))
            }
        )
        let host = BlocksNativePluginInvocationHost(
            pluginID: authoritativeMetadata.id,
            manifest: package.manifest,
            approvedDomains: Set(authoritativeMetadata.approvedDomains),
            approvedMethods: approvedMethods,
            approvedSecretIDs: approvedSecretIDs,
            networkBroker: networkBroker,
            hostOperationHandler: hostOperationHandler,
            networkAuditHandler: networkAuditHandler,
            progress: progress
        )
        try Task.checkCancellation()
        host.start()
        defer { host.shutdown() }

        try Task.checkCancellation()
        preExecuteProbe()
        proxy.execute(requestData, hostEndpoint: host.endpoint) { data in
            replyState.resolve(.success(data))
        }
        let timeoutTask = Task.detached { [timeoutSeconds] in
            let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            replyState.resolve(
                .failure(
                    BlocksNativePluginExecutionError.executionFailed(
                        code: "runner_timeout",
                        message: "The plugin exceeded the execution time limit."
                    )
                )
            )
            sendableConnection.connection.invalidate()
        }
        defer {
            timeoutTask.cancel()
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            unregister(
                pluginID: authoritativeMetadata.id,
                requestID: invocation.requestID
            )
            isRegistered = false
        }

        let responseData: Data
        do {
            responseData = try await withTaskCancellationHandler {
                try await replyState.value()
            } onCancel: {
                replyState.resolve(.failure(CancellationError()))
                proxy.cancel(invocation.requestID.uuidString) { _ in }
                sendableConnection.connection.invalidate()
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        guard responseData.count <= 3 * 1_048_576,
              let response = try? JSONDecoder().decode(
                  BlocksNativePluginRunnerResponse.self,
                  from: responseData
              ),
              response.requestID == invocation.requestID else {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "invalid_runner_response",
                message: "The isolated plugin runner returned an invalid response."
            )
        }
        switch response.status {
        case .completed:
            guard let output = response.output else {
                throw BlocksNativePluginExecutionError.executionFailed(
                    code: "missing_plugin_output",
                    message: "The plugin completed without an output."
                )
            }
            return output
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw BlocksNativePluginExecutionError.executionFailed(
                code: response.errorCode ?? "plugin_execution_failed",
                message: response.errorMessage ?? "The plugin failed."
            )
        }
    }

    private func resolveAuthoritativeMetadata(
        pluginID: String,
        package: BlocksNativePluginValidatedPackage,
        invocation: BlocksNativePluginInvocation,
        allowDisabled: Bool
    ) async throws -> BlocksNativePluginMetadata {
        let metadata: BlocksNativePluginMetadata
        do {
            metadata = try await metadataResolver(pluginID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BlocksNativePluginExecutionError.pluginDisabled
        }
        guard metadata.id == package.manifest.id,
              invocation.pluginID == metadata.id else {
            throw BlocksNativePluginExecutionError.packageHashMismatch
        }
        guard metadata.approvalStatus == .approved else {
            throw BlocksNativePluginExecutionError.pluginNotApproved
        }
        guard !metadata.safetyDisabled,
              metadata.isEnabled || allowDisabled else {
            throw BlocksNativePluginExecutionError.pluginDisabled
        }
        guard metadata.packageHash == package.packageSHA256 else {
            throw BlocksNativePluginExecutionError.packageHashMismatch
        }
        return metadata
    }

    private func prepareRunner(
        proxy: BlocksNativePluginRunnerXPCProtocol,
        requestID: UUID,
        connection: SendablePluginXPCConnection,
        state: PluginRunnerPreparationState
    ) async throws {
        proxy.prepareInvocation(requestID.uuidString) { accepted in
            if accepted {
                state.resolve(.success(()))
            } else {
                state.resolve(.failure(
                    BlocksNativePluginExecutionError.runnerUnavailable
                ))
            }
        }
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            state.resolve(.failure(
                BlocksNativePluginExecutionError.executionFailed(
                    code: "runner_start_timeout",
                    message: "The isolated plugin runner did not start in time."
                )
            ))
            connection.connection.invalidate()
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await state.value()
        } onCancel: {
            state.resolve(.failure(CancellationError()))
            connection.connection.invalidate()
        }
    }

    private func resolveAuthoritativeMetadata(
        pluginID: String,
        package: BlocksNativePluginValidatedPackage,
        platformInvocation: BlocksPluginRuntimeInvocation
    ) async throws -> BlocksNativePluginMetadata {
        let metadata: BlocksNativePluginMetadata
        do {
            metadata = try await metadataResolver(pluginID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BlocksNativePluginExecutionError.pluginDisabled
        }
        guard metadata.id == package.manifest.id,
              platformInvocation.pluginID == metadata.id,
              metadata.packageHash == package.packageSHA256 else {
            throw BlocksNativePluginExecutionError.packageHashMismatch
        }
        guard metadata.approvalStatus == .approved else {
            throw BlocksNativePluginExecutionError.pluginNotApproved
        }
        guard metadata.isEnabled, !metadata.safetyDisabled else {
            throw BlocksNativePluginExecutionError.pluginDisabled
        }
        return metadata
    }

    private static func validateDataPermissions(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        invocation: BlocksNativePluginInvocation
    ) throws {
        guard package.manifest.schemaVersion >= 3 else {
            return
        }
        let needsScreenshotData: Bool
        switch invocation.kind {
        case .ocr:
            needsScreenshotData = true
        case .translation:
            if case let .array(attachments)? =
                invocation.input["attachments"] {
                needsScreenshotData = !attachments.isEmpty
            } else {
                needsScreenshotData = false
            }
        }
        guard needsScreenshotData else { return }
        let permission =
            BlocksNativePluginDataPermission.screenshotImage
        let token = "data:\(permission.rawValue)"
        guard package.manifest.permissions.data.contains(permission),
              metadata.approvedPermissions.contains(token) else {
            throw BlocksNativePluginExecutionError.executionFailed(
                code: "plugin_data_permission_missing",
                message:
                    "The plugin is not approved to receive screenshot data."
            )
        }
    }

    func cancelExecutions(pluginID: String) {
        connectionLock.lock()
        let connections = activeConnections.removeValue(forKey: pluginID)?
            .values
            .map(\.connection) ?? []
        connectionLock.unlock()
        connections.forEach { $0.invalidate() }
    }

    private func register(
        _ connection: SendablePluginXPCConnection,
        pluginID: String,
        requestID: UUID
    ) {
        connectionLock.lock()
        activeConnections[pluginID, default: [:]][requestID] = connection
        connectionLock.unlock()
    }

    private func unregister(pluginID: String, requestID: UUID) {
        connectionLock.lock()
        activeConnections[pluginID]?.removeValue(forKey: requestID)
        if activeConnections[pluginID]?.isEmpty == true {
            activeConnections.removeValue(forKey: pluginID)
        }
        connectionLock.unlock()
    }
}

extension BlocksNativePluginXPCExecutionClient {
    private static let networkAuditAllowedHeaderNames: Set<String> = [
        "accept",
        "accept-language",
        "cache-control",
        "content-encoding",
        "content-length",
        "content-type",
        "date",
        "etag",
        "expires",
        "if-modified-since",
        "if-none-match",
        "last-modified",
        "retry-after",
        "user-agent",
        "vary",
    ]

    static func pluginNetworkAuditBodyValue(_ body: Data?) -> JSONValue {
        guard let body else { return .null }
        return .object([
            "byte_count": .int(body.count),
        ])
    }

    static func decodeNetworkBridgeRequest(
        _ requestData: Data
    ) -> BlocksNativePluginNetworkRequest? {
        guard requestData.count <= BlocksNativePluginNetworkBridgeLimits
                .maximumEncodedRequestBytes else {
            return nil
        }
        return try? JSONDecoder().decode(
            BlocksNativePluginNetworkRequest.self,
            from: requestData
        )
    }

    static func networkRequestEntry(
        _ request: BlocksNativePluginNetworkRequest
    ) -> [String: JSONValue] {
        [
            "category": .string("network"),
            "stage": .string("request"),
            "request_id": .string(request.requestID.uuidString),
            "url": networkAuditURLValue(request.url),
            "method": .string(request.method.rawValue),
            "headers": networkAuditHeaderValue(request.headers),
            "body": pluginNetworkAuditBodyValue(request.body),
        ]
    }

    static func networkResponseEntry(
        _ response: BlocksNativePluginNetworkResponse
    ) -> [String: JSONValue] {
        [
            "category": .string("network"),
            "stage": .string("response"),
            "request_id": .string(response.requestID.uuidString),
            "status_code": .int(response.statusCode),
            "headers": networkAuditHeaderValue(response.headers),
            "body": pluginNetworkAuditBodyValue(response.body),
        ]
    }

    private static func networkAuditHeaderValue(
        _ headers: [String: String]
    ) -> JSONValue {
        let normalizedNames = Set(headers.keys.map { $0.lowercased() })
        let allowedNames = normalizedNames
            .filter(networkAuditAllowedHeaderNames.contains)
            .sorted()
        return .object([
            "names": .array(allowedNames.map(JSONValue.string)),
            "custom_header_count": .int(
                normalizedNames.subtracting(networkAuditAllowedHeaderNames)
                    .count
            ),
        ])
    }

    private static func networkAuditURLValue(_ value: String) -> JSONValue {
        let components = URLComponents(string: value)
        let pathSegments = components?.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) ?? []
        return .object([
            "host": .string(components?.host ?? ""),
            "path_present": .bool(!pathSegments.isEmpty),
            "path_segment_count": .int(pathSegments.count),
        ])
    }
}

private final class BlocksNativePluginInvocationHost:
    NSObject,
    NSXPCListenerDelegate,
    BlocksNativePluginRunnerHostXPCProtocol,
    @unchecked Sendable
{
    let endpoint: NSXPCListenerEndpoint

    private let listener: NSXPCListener
    private let pluginID: String
    private let manifest: BlocksNativePluginManifest
    private let approvedDomains: Set<String>
    private let approvedMethods: Set<BlocksNativePluginHTTPMethod>
    private let approvedSecretIDs: Set<String>
    private let networkBroker: BlocksNativePluginNetworkBroker
    private let progressCoalescer: BlocksNativePluginProgressCoalescer
    private let hostOperationHandler:
        BlocksNativePluginXPCExecutionClient.HostOperationHandler
    private let networkAuditHandler:
        BlocksNativePluginXPCExecutionClient.NetworkAuditHandler
    private let connectionLock = NSLock()
    private var acceptedConnections: [NSXPCConnection] = []
    private let networkTaskLock = NSLock()
    private var networkTasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    init(
        pluginID: String,
        manifest: BlocksNativePluginManifest,
        approvedDomains: Set<String>,
        approvedMethods: Set<BlocksNativePluginHTTPMethod>,
        approvedSecretIDs: Set<String>,
        networkBroker: BlocksNativePluginNetworkBroker,
        hostOperationHandler: @escaping
            BlocksNativePluginXPCExecutionClient.HostOperationHandler,
        networkAuditHandler: @escaping
            BlocksNativePluginXPCExecutionClient.NetworkAuditHandler,
        progress: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) {
        listener = NSXPCListener.anonymous()
        endpoint = listener.endpoint
        self.pluginID = pluginID
        self.manifest = manifest
        self.approvedDomains = approvedDomains
        self.approvedMethods = approvedMethods
        self.approvedSecretIDs = approvedSecretIDs
        self.networkBroker = networkBroker
        self.hostOperationHandler = hostOperationHandler
        self.networkAuditHandler = networkAuditHandler
        progressCoalescer = BlocksNativePluginProgressCoalescer(
            delivery: progress
        )
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
    }

    func shutdown() {
        progressCoalescer.finish(flushPending: true)
        listener.suspend()
        connectionLock.lock()
        let connections = acceptedConnections
        acceptedConnections.removeAll()
        connectionLock.unlock()
        connections.forEach { $0.invalidate() }
        networkTaskLock.lock()
        isClosed = true
        let tasks = networkTasks.values
        networkTasks.removeAll()
        networkTaskLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard BlocksNativePluginRunnerPeerValidator.isExpectedRunner(
            newConnection
        ) else {
            newConnection.invalidate()
            return false
        }
        connectionLock.lock()
        guard acceptedConnections.isEmpty else {
            connectionLock.unlock()
            newConnection.invalidate()
            return false
        }
        acceptedConnections.append(newConnection)
        connectionLock.unlock()
        newConnection.exportedInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerHostXPCProtocol.self
        )
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.connectionLock.lock()
            self.acceptedConnections.removeAll { $0 === newConnection }
            self.connectionLock.unlock()
        }
        newConnection.resume()
        return true
    }

    func performNetworkRequest(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        let replyState = PluginNetworkReplyState(reply: reply)
        guard let request = BlocksNativePluginXPCExecutionClient
            .decodeNetworkBridgeRequest(requestData) else {
            replyState.resolve(
                data: nil,
                error: "The plugin supplied an invalid network request."
            )
            return
        }
        let startGate = PluginNetworkTaskStartGate()
        let task = Task { [weak self] in
            await startGate.wait()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            defer {
                self.removeNetworkTask(requestID: request.requestID)
            }
            do {
                self.networkAuditHandler(
                    self.pluginID,
                    BlocksNativePluginXPCExecutionClient.networkRequestEntry(request)
                )
                let response = try await self.networkBroker.perform(
                    request: request,
                    manifest: self.manifest,
                    approvedDomains: self.approvedDomains,
                    approvedMethods: self.approvedMethods,
                    approvedSecretIDs: self.approvedSecretIDs
                )
                self.networkAuditHandler(
                    self.pluginID,
                    BlocksNativePluginXPCExecutionClient.networkResponseEntry(response)
                )
                replyState.resolve(
                    data: try JSONEncoder().encode(response),
                    error: nil
                )
            } catch {
                self.networkAuditHandler(
                    self.pluginID,
                    [
                        "category": .string("network"),
                        "stage": .string("failed"),
                        "request_id": .string(request.requestID.uuidString),
                    ]
                )
                replyState.resolve(
                    data: nil,
                    error: String(error.localizedDescription.prefix(512))
                )
            }
        }
        networkTaskLock.lock()
        if isClosed {
            networkTaskLock.unlock()
            task.cancel()
            startGate.open()
            replyState.resolve(
                data: nil,
                error: "The plugin invocation is no longer active."
            )
            return
        }
        networkTasks[request.requestID] = task
        networkTaskLock.unlock()
        startGate.open()
    }

    func emitProgress(_ progressData: Data) {
        guard progressData.count <= 64 * 1_024,
              let event = try? JSONDecoder().decode(
                  BlocksNativePluginProgress.self,
                  from: progressData
              ) else {
            return
        }
        progressCoalescer.submit(event)
    }

    func performHostOperation(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        let response: BlocksPluginHostOperationResponse
        if requestData.count <= 3 * 1_048_576,
           let request = try? JSONDecoder().decode(
               BlocksPluginHostOperationRequest.self,
               from: requestData
           ),
           request.pluginID == pluginID {
            response = hostOperationHandler(request)
        } else {
            response = BlocksPluginHostOperationResponse(
                requestID: (try? JSONDecoder().decode(
                    BlocksPluginHostOperationRequest.self,
                    from: requestData
                ).requestID) ?? UUID(),
                ok: false,
                errorCode: "invalid_host_operation",
                errorMessage: "The plugin supplied an invalid host operation."
            )
        }
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }

    private func removeNetworkTask(requestID: UUID) {
        networkTaskLock.lock()
        networkTasks.removeValue(forKey: requestID)
        networkTaskLock.unlock()
    }

}

final class PluginNetworkTaskStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

final class BlocksNativePluginProgressCoalescer: @unchecked Sendable {
    static let maximumDeliveryFrequency: Double = 30

    private let queue = DispatchQueue(
        label: "app.blocks.plugin-progress-coalescer",
        qos: .userInitiated
    )
    private let delivery: @Sendable (BlocksNativePluginProgress) -> Void
    private let minimumIntervalNanoseconds: UInt64
    private var pendingByKind:
        [BlocksNativePluginProgressKind: BlocksNativePluginProgress] = [:]
    private var nextAllowedDeliveryNanoseconds: UInt64 = 0
    private var scheduledDelivery: DispatchWorkItem?
    private var isClosed = false

    init(
        maximumDeliveryFrequency: Double =
            BlocksNativePluginProgressCoalescer.maximumDeliveryFrequency,
        delivery: @escaping @Sendable (BlocksNativePluginProgress) -> Void
    ) {
        let frequency = min(max(maximumDeliveryFrequency, 1), 60)
        minimumIntervalNanoseconds = UInt64(1_000_000_000 / frequency)
        self.delivery = delivery
    }

    func submit(_ progress: BlocksNativePluginProgress) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.pendingByKind[progress.kind] = progress
            self.scheduleDeliveryIfNeeded()
        }
    }

    func finish(flushPending: Bool) {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            scheduledDelivery?.cancel()
            scheduledDelivery = nil
            if flushPending {
                deliverPending(now: DispatchTime.now().uptimeNanoseconds)
            } else {
                pendingByKind.removeAll()
            }
        }
    }

    private func scheduleDeliveryIfNeeded() {
        guard scheduledDelivery == nil, !pendingByKind.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < nextAllowedDeliveryNanoseconds else {
            deliverPending(now: now)
            return
        }
        let delay = nextAllowedDeliveryNanoseconds - now
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            self.scheduledDelivery = nil
            self.deliverPending(now: DispatchTime.now().uptimeNanoseconds)
        }
        scheduledDelivery = workItem
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(delay)),
            execute: workItem
        )
    }

    private func deliverPending(now: UInt64) {
        let events = pendingByKind
            .sorted { lhs, rhs in
                lhs.key.rawValue < rhs.key.rawValue
            }
            .map { $0.value }
        pendingByKind.removeAll()
        guard !events.isEmpty else { return }
        nextAllowedDeliveryNanoseconds = now &+ minimumIntervalNanoseconds
        for event in events {
            delivery(event)
        }
    }
}

private final class PluginNetworkReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private var didReply = false
    private let reply: (Data?, String?) -> Void

    init(reply: @escaping (Data?, String?) -> Void) {
        self.reply = reply
    }

    func resolve(data: Data?, error: String?) {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return
        }
        didReply = true
        lock.unlock()
        reply(data, error)
    }
}

private final class PluginExecutionReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?

    func value() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class PluginRunnerPreparationState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func value() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class SendablePluginXPCConnection: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private enum BlocksNativePluginRunnerPeerValidator {
    static func isExpectedRunner(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              connection.processIdentifier > 0,
              let expectedExecutable = expectedRunnerExecutableURL(),
              let peerExecutable = executableURL(
                  processID: connection.processIdentifier
              ),
              peerExecutable.resolvingSymlinksInPath()
                  == expectedExecutable.resolvingSymlinksInPath() else {
            return false
        }
        guard let expectedIdentity = signingIdentity(
            executableURL: expectedExecutable
        ),
              let peerIdentity = validatedSigningIdentity(
                processID: connection.processIdentifier
              ),
              peerIdentity == expectedIdentity else {
            return false
        }
        return true
    }

    private static func expectedRunnerExecutableURL() -> URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent("BlocksPluginRunner.xpc", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("BlocksPluginRunner", isDirectory: false)
            .standardizedFileURL
    }

    private static func executableURL(processID: pid_t) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
            .standardizedFileURL
    }

    private struct SigningIdentity: Equatable {
        let identifier: String?
        let teamID: String?
        let codeDirectoryHash: Data
    }

    private static func validatedSigningIdentity(
        processID: pid_t
    ) -> SigningIdentity? {
        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: processID),
        ] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &code
        ) == errSecSuccess,
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
        return signingIdentity(staticCode: staticCode)
    }

    private static func signingIdentity(
        executableURL: URL
    ) -> SigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
              ) == errSecSuccess else {
            return nil
        }
        return signingIdentity(staticCode: staticCode)
    }

    private static func signingIdentity(
        staticCode: SecStaticCode
    ) -> SigningIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        let codeDirectoryHash = values[kSecCodeInfoUnique] as? Data else {
            return nil
        }
        return SigningIdentity(
            identifier: values[kSecCodeInfoIdentifier] as? String,
            teamID: values[kSecCodeInfoTeamIdentifier] as? String,
            codeDirectoryHash: codeDirectoryHash
        )
    }
}
