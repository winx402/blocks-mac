import BlocksCore
import Darwin
import Foundation
import JavaScriptCore

enum BlocksNativePluginRunnerError: Error, LocalizedError, Equatable {
    case invalidRequest
    case unsupportedProtocolVersion
    case pluginIdentityMismatch
    case capabilityNotDeclared
    case entrySourceTooLarge
    case inputTooLarge
    case contextCreationFailed
    case scriptException(String)
    case entryFunctionMissing(String)
    case asynchronousResultNotSupported
    case invalidOutput
    case outputTooLarge
    case networkRequestInvalid(String)
    case networkRequestFailed(String)
    case networkBudgetExceeded
    case progressInvalid
    case progressBudgetExceeded
    case hostOperationInvalid
    case hostOperationFailed(String)
    case platformResultInvalid
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The plugin runner request is invalid."
        case .unsupportedProtocolVersion:
            return "The plugin host and runner protocol versions do not match."
        case .pluginIdentityMismatch:
            return "The plugin invocation does not match the manifest."
        case .capabilityNotDeclared:
            return "The plugin did not declare the requested capability."
        case .entrySourceTooLarge:
            return "The plugin entry source is too large."
        case .inputTooLarge:
            return "The plugin input is too large."
        case .contextCreationFailed:
            return "JavaScriptCore could not create an isolated context."
        case let .scriptException(message):
            return "The plugin script failed: \(message)"
        case let .entryFunctionMissing(function):
            return "The plugin does not define \(function)(input, context)."
        case .asynchronousResultNotSupported:
            return "Plugin entry functions must return a value, not a Promise."
        case .invalidOutput:
            return "The plugin returned an invalid output."
        case .outputTooLarge:
            return "The plugin output is too large."
        case let .networkRequestInvalid(message):
            return "The plugin network request is invalid: \(message)"
        case let .networkRequestFailed(message):
            return "The plugin network request failed: \(message)"
        case .networkBudgetExceeded:
            return "The plugin exceeded the per-invocation network request budget."
        case .progressInvalid:
            return "The plugin emitted an invalid progress event."
        case .progressBudgetExceeded:
            return "The plugin exceeded the progress event budget."
        case .hostOperationInvalid:
            return "The plugin supplied an invalid host operation."
        case let .hostOperationFailed(message):
            return "The plugin host operation failed: \(message)"
        case .platformResultInvalid:
            return "The plugin returned an invalid platform result."
        case .cancelled:
            return "The plugin invocation was cancelled."
        }
    }
}

final class BlocksNativePluginJavaScriptRunner: @unchecked Sendable {
    typealias NetworkBroker = @Sendable (
        BlocksNativePluginNetworkRequest
    ) throws -> BlocksNativePluginNetworkResponse
    typealias ProgressSink = @Sendable (BlocksNativePluginProgress) -> Void
    typealias HostOperationBroker = @Sendable (
        BlocksPluginHostOperationRequest
    ) throws -> BlocksPluginHostOperationResponse

    static let maximumEntrySourceBytes = 4 * 1_048_576
    static let maximumInputBytes = 4 * 1_048_576
    static let maximumOutputBytes = 2 * 1_048_576
    static let maximumProgressTextCharacters = 16_384

    private let networkPolicy: BlocksNativePluginNetworkPolicy
    private let networkBroker: NetworkBroker
    private let progressSink: ProgressSink
    private let hostOperationBroker: HostOperationBroker
    private let cancellationLock = NSLock()
    private var cancelledRequestIDs = Set<UUID>()

    init(
        networkPolicy: BlocksNativePluginNetworkPolicy = .init(),
        networkBroker: @escaping NetworkBroker,
        progressSink: @escaping ProgressSink = { _ in },
        hostOperationBroker: @escaping HostOperationBroker = { request in
            BlocksPluginHostOperationResponse(
                requestID: request.requestID,
                ok: false,
                errorCode: "host_operation_unavailable",
                errorMessage: "The plugin host operation bridge is unavailable."
            )
        }
    ) {
        self.networkPolicy = networkPolicy
        self.networkBroker = networkBroker
        self.progressSink = progressSink
        self.hostOperationBroker = hostOperationBroker
    }

    func execute(_ request: BlocksNativePluginRunnerRequest) -> BlocksNativePluginRunnerResponse {
        do {
            let output = try run(request)
            return BlocksNativePluginRunnerResponse(
                requestID: request.invocation.requestID,
                status: .completed,
                output: output
            )
        } catch BlocksNativePluginRunnerError.cancelled {
            return BlocksNativePluginRunnerResponse(
                requestID: request.invocation.requestID,
                status: .cancelled,
                errorCode: "cancelled",
                errorMessage: BlocksNativePluginRunnerError.cancelled.localizedDescription
            )
        } catch {
            return BlocksNativePluginRunnerResponse(
                requestID: request.invocation.requestID,
                status: .failed,
                errorCode: Self.errorCode(for: error),
                errorMessage: Self.responseErrorMessage(error)
            )
        }
    }

    func executePlatform(_ request: BlocksPluginRunnerRequest) -> BlocksPluginRunnerResponse {
        do {
            return BlocksPluginRunnerResponse(
                requestID: request.invocation.requestID,
                status: .completed,
                result: try runPlatform(request)
            )
        } catch BlocksNativePluginRunnerError.cancelled {
            return BlocksPluginRunnerResponse(
                requestID: request.invocation.requestID,
                status: .cancelled,
                errorCode: "cancelled",
                errorMessage: BlocksNativePluginRunnerError.cancelled.localizedDescription
            )
        } catch {
            return BlocksPluginRunnerResponse(
                requestID: request.invocation.requestID,
                status: .failed,
                errorCode: Self.errorCode(for: error),
                errorMessage: Self.responseErrorMessage(error)
            )
        }
    }

    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        cancellationLock.lock()
        let inserted = cancelledRequestIDs.insert(requestID).inserted
        cancellationLock.unlock()
        return inserted
    }

    func clearCancellation(requestID: UUID) {
        cancellationLock.lock()
        cancelledRequestIDs.remove(requestID)
        cancellationLock.unlock()
    }

    private func run(_ request: BlocksNativePluginRunnerRequest) throws -> BlocksNativePluginOutput {
        defer { clearCancellation(requestID: request.invocation.requestID) }
        try checkCancellation(request.invocation.requestID)

        guard request.protocolVersion == BlocksNativePluginXPC.protocolVersion else {
            throw BlocksNativePluginRunnerError.unsupportedProtocolVersion
        }
        guard request.executionTimeLimitSeconds.isFinite,
              (1...60).contains(request.executionTimeLimitSeconds) else {
            throw BlocksNativePluginRunnerError.invalidRequest
        }
        try BlocksNativePluginPackageValidator().validate(manifest: request.manifest)
        guard request.manifest.id == request.invocation.pluginID else {
            throw BlocksNativePluginRunnerError.pluginIdentityMismatch
        }
        let requiredCapability: BlocksNativePluginCapability
        let entryFunction: String
        switch request.invocation.kind {
        case .translation:
            requiredCapability = .translation
            entryFunction = "translate"
        case .ocr:
            requiredCapability = .ocr
            entryFunction = "ocr"
        }
        guard request.manifest.capabilities.contains(requiredCapability) else {
            throw BlocksNativePluginRunnerError.capabilityNotDeclared
        }
        guard request.entrySource.utf8.count <= Self.maximumEntrySourceBytes else {
            throw BlocksNativePluginRunnerError.entrySourceTooLarge
        }

        let invocationData = try JSONEncoder().encode(request.invocation)
        guard invocationData.count <= Self.maximumInputBytes,
              let invocationJSON = String(data: invocationData, encoding: .utf8) else {
            throw BlocksNativePluginRunnerError.inputTooLarge
        }
        guard let context = JSContext() else {
            throw BlocksNativePluginRunnerError.contextCreationFailed
        }

        let requestID = request.invocation.requestID
        let manifest = request.manifest
        let networkBudget = LockedPluginNetworkBudget()
        let progressBudget = LockedPluginProgressBudget()
        let networkBridge: @convention(block) (String) -> String = { [weak self] requestJSON in
            guard let self else {
                return Self.bridgeFailureJSON(
                    code: "runner_unavailable",
                    message: "The plugin runner is unavailable."
                )
            }
            do {
                try self.checkCancellation(requestID)
                let networkRequest = try Self.decodeNetworkRequest(requestJSON)
                try networkBudget.consume(bytes: networkRequest.body?.count ?? 0)
                _ = try self.networkPolicy.validate(networkRequest, manifest: manifest)
                let response = try self.networkBroker(networkRequest)
                try self.networkPolicy.validateResponseSize(response.body.count)
                try self.checkCancellation(requestID)
                return try Self.bridgeSuccessJSON(response: response)
            } catch {
                return Self.bridgeFailureJSON(
                    code: Self.errorCode(for: error),
                    message: Self.boundedErrorMessage(error.localizedDescription)
                )
            }
        }
        let progressBridge: @convention(block) (String) -> String = { [weak self] progressJSON in
            guard let self else {
                return Self.bridgeFailureJSON(
                    code: "runner_unavailable",
                    message: "The plugin runner is unavailable."
                )
            }
            do {
                try self.checkCancellation(requestID)
                try progressBudget.consume(bytes: progressJSON.utf8.count)
                let progress = try Self.decodeProgress(
                    progressJSON,
                    requestID: requestID,
                    manifest: manifest,
                    invocationKind: request.invocation.kind
                )
                self.progressSink(progress)
                return #"{"ok":true}"#
            } catch {
                return Self.bridgeFailureJSON(
                    code: Self.errorCode(for: error),
                    message: Self.boundedErrorMessage(error.localizedDescription)
                )
            }
        }
        context.setObject(networkBridge, forKeyedSubscript: "__blocksNetworkBridge" as NSString)
        context.setObject(progressBridge, forKeyedSubscript: "__blocksProgressBridge" as NSString)
        context.setObject(invocationJSON, forKeyedSubscript: "__blocksInvocationJSON" as NSString)

        let bootstrap = """
        (() => {
          "use strict";
          const invocation = JSON.parse(__blocksInvocationJSON);
          const bridgeResult = (raw) => {
            const result = JSON.parse(raw);
            if (!result.ok) {
              throw new Error(result.error && result.error.message
                ? result.error.message
                : "Blocks host operation failed.");
            }
            return result.value;
          };
          const blocks = Object.freeze({
            request: (request) => bridgeResult(__blocksNetworkBridge(JSON.stringify(request))),
            progress: (event) => bridgeResult(__blocksProgressBridge(JSON.stringify(event))),
          });
          Object.defineProperty(globalThis, "blocks", {
            value: blocks,
            writable: false,
            configurable: false,
            enumerable: true,
          });
          Object.defineProperty(globalThis, "__blocksInvocation", {
            value: Object.freeze(invocation),
            writable: false,
            configurable: false,
            enumerable: false,
          });
          [
            "fetch", "XMLHttpRequest", "WebSocket", "EventSource", "Worker",
            "SharedWorker", "require", "process", "Deno", "Bun"
          ].forEach((name) => {
            try {
              Object.defineProperty(globalThis, name, {
                value: undefined,
                writable: false,
                configurable: false,
              });
            } catch (_) {}
          });
          try { delete globalThis.__blocksInvocationJSON; } catch (_) {}
        })();
        """
        try evaluate(bootstrap, in: context)
        try checkCancellation(requestID)
        try evaluate(request.entrySource, in: context)
        try checkCancellation(requestID)

        let invocation = """
        (() => {
          "use strict";
          const entry = globalThis[\(Self.javaScriptStringLiteral(entryFunction))];
          if (typeof entry !== "function") {
            throw new Error("__BLOCKS_ENTRY_MISSING__:\(entryFunction)");
          }
          const result = entry(
            __blocksInvocation.input,
            Object.freeze({
              requestID: __blocksInvocation.requestID,
              configuration: __blocksInvocation.configuration,
              capability: __blocksInvocation.kind,
            })
          );
          if (result && typeof result.then === "function") {
            throw new Error("__BLOCKS_ASYNC_RESULT__");
          }
          return JSON.stringify(result);
        })();
        """
        context.exception = nil
        let result = context.evaluateScript(invocation)
        if progressBudget.hasExceededBudget {
            throw BlocksNativePluginRunnerError.progressBudgetExceeded
        }
        if let exception = context.exception {
            let summary = exception.toString() ?? "Unknown JavaScript exception."
            let stack = exception.objectForKeyedSubscript("stack")?.toString()
            let message = [summary, stack]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if message.contains("__BLOCKS_ENTRY_MISSING__") {
                throw BlocksNativePluginRunnerError.entryFunctionMissing(entryFunction)
            }
            if message.contains("__BLOCKS_ASYNC_RESULT__") {
                throw BlocksNativePluginRunnerError.asynchronousResultNotSupported
            }
            throw BlocksNativePluginRunnerError.scriptException(Self.boundedErrorMessage(message))
        }
        try progressBudget.checkWithinBudget()
        guard let resultJSON = result?.toString(),
              let outputData = resultJSON.data(using: .utf8) else {
            throw BlocksNativePluginRunnerError.invalidOutput
        }
        guard outputData.count <= Self.maximumOutputBytes else {
            throw BlocksNativePluginRunnerError.outputTooLarge
        }
        try checkCancellation(requestID)
        return try Self.decodeOutput(
            outputData,
            manifest: request.manifest,
            invocationKind: request.invocation.kind
        )
    }

    private func runPlatform(
        _ request: BlocksPluginRunnerRequest
    ) throws -> BlocksPluginRuntimeResult {
        let invocation = request.invocation
        let requestID = invocation.requestID
        defer { clearCancellation(requestID: requestID) }
        try checkCancellation(requestID)
        guard request.protocolVersion == BlocksNativePluginXPC.protocolVersion,
              request.executionTimeLimitSeconds.isFinite,
              (0.05...60).contains(request.executionTimeLimitSeconds),
              request.manifest.schemaVersion >= 4,
              request.manifest.id == invocation.pluginID,
              request.manifest.platform != nil else {
            throw BlocksNativePluginRunnerError.invalidRequest
        }
        try BlocksNativePluginPackageValidator().validate(manifest: request.manifest)
        guard request.entrySource.utf8.count <= Self.maximumEntrySourceBytes else {
            throw BlocksNativePluginRunnerError.entrySourceTooLarge
        }
        let invocationData = try JSONEncoder().encode(invocation)
        guard invocationData.count <= Self.maximumInputBytes,
              let invocationJSON = String(data: invocationData, encoding: .utf8),
              let context = JSContext() else {
            throw BlocksNativePluginRunnerError.inputTooLarge
        }

        let manifest = request.manifest
        let networkBudget = LockedPluginNetworkBudget()
        let progressBudget = LockedPluginProgressBudget()
        let networkBridge: @convention(block) (String) -> String = { [weak self] requestJSON in
            guard let self else {
                return Self.bridgeFailureJSON(code: "runner_unavailable", message: "The plugin runner is unavailable.")
            }
            do {
                try self.checkCancellation(requestID)
                let networkRequest = try Self.decodeNetworkRequest(requestJSON)
                try networkBudget.consume(bytes: networkRequest.body?.count ?? 0)
                _ = try self.networkPolicy.validate(networkRequest, manifest: manifest)
                let response = try self.networkBroker(networkRequest)
                try self.networkPolicy.validateResponseSize(response.body.count)
                try self.checkCancellation(requestID)
                return try Self.bridgeSuccessJSON(response: response)
            } catch {
                return Self.bridgeFailureJSON(
                    code: Self.errorCode(for: error),
                    message: Self.boundedErrorMessage(error.localizedDescription)
                )
            }
        }
        let progressBridge: @convention(block) (String) -> String = { [weak self] progressJSON in
            guard let self else {
                return Self.bridgeFailureJSON(code: "runner_unavailable", message: "The plugin runner is unavailable.")
            }
            do {
                try self.checkCancellation(requestID)
                try progressBudget.consume(bytes: progressJSON.utf8.count)
                let event = try Self.decodeGenericProgress(progressJSON, requestID: requestID)
                self.progressSink(event)
                return #"{"ok":true}"#
            } catch {
                return Self.bridgeFailureJSON(
                    code: Self.errorCode(for: error),
                    message: Self.boundedErrorMessage(error.localizedDescription)
                )
            }
        }
        let hostBridge: @convention(block) (String) -> String = { [weak self] operationJSON in
            guard let self else {
                return Self.bridgeFailureJSON(code: "runner_unavailable", message: "The plugin runner is unavailable.")
            }
            do {
                try self.checkCancellation(requestID)
                let operation = try Self.decodeHostOperation(
                    operationJSON,
                    pluginID: invocation.pluginID
                )
                let response = try self.hostOperationBroker(operation)
                try self.checkCancellation(requestID)
                return try Self.bridgeHostOperationJSON(response)
            } catch {
                return Self.bridgeFailureJSON(
                    code: Self.errorCode(for: error),
                    message: Self.boundedErrorMessage(error.localizedDescription)
                )
            }
        }

        context.setObject(networkBridge, forKeyedSubscript: "__blocksNetworkBridge" as NSString)
        context.setObject(progressBridge, forKeyedSubscript: "__blocksProgressBridge" as NSString)
        context.setObject(hostBridge, forKeyedSubscript: "__blocksHostBridge" as NSString)
        context.setObject(invocationJSON, forKeyedSubscript: "__blocksPlatformInvocationJSON" as NSString)
        let bootstrap = """
        (() => {
          "use strict";
          const invocation = JSON.parse(__blocksPlatformInvocationJSON);
          const bridgeResult = (raw) => {
            const result = JSON.parse(raw);
            if (!result.ok) {
              const error = new Error(result.error && result.error.message
                ? result.error.message : "Blocks host operation failed.");
              error.code = result.error && result.error.code;
              throw error;
            }
            return result.value;
          };
          const blocks = Object.freeze({
            request: (value) => bridgeResult(__blocksNetworkBridge(JSON.stringify(value))),
            progress: (value) => bridgeResult(__blocksProgressBridge(JSON.stringify(value))),
            invoke: (operation, input = {}) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation, input }))),
            storage: Object.freeze({
              get: (namespace, key) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "storage.get", input: { namespace, key } }))),
              put: (namespace, key, value, expectedRevision = null) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "storage.put", input: { namespace, key, value, expected_revision: expectedRevision } }))),
              queue: Object.freeze({
                enqueue: (namespace, key, value, expectedRevision = null) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "storage.queue.enqueue", input: { namespace, key, value, expected_revision: expectedRevision } }))),
                dequeue: (namespace, key, expectedRevision = null) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "storage.queue.dequeue", input: { namespace, key, expected_revision: expectedRevision } }))),
              }),
            }),
            sharedState: Object.freeze({
              get: (ownerPluginID, namespace, key) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "shared.get", input: { owner_plugin_id: ownerPluginID, namespace, key } }))),
              put: (ownerPluginID, namespace, key, schemaVersion, value, expectedRevision = null) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "shared.put", input: { owner_plugin_id: ownerPluginID, namespace, key, schema_version: schemaVersion, value, expected_revision: expectedRevision } }))),
            }),
            resource: Object.freeze({
              read: (resourceID, offset, length) => bridgeResult(__blocksHostBridge(JSON.stringify({ operation: "resource.read", input: { resource_id: resourceID, offset, length } }))),
            }),
          });
          Object.defineProperty(globalThis, "blocks", { value: blocks, writable: false, configurable: false });
          Object.defineProperty(globalThis, "__blocksInvocation", { value: Object.freeze(invocation), writable: false, configurable: false });
          ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "Worker", "SharedWorker", "require", "process", "Deno", "Bun"].forEach((name) => {
            try { Object.defineProperty(globalThis, name, { value: undefined, writable: false, configurable: false }); } catch (_) {}
          });
          try { delete globalThis.__blocksPlatformInvocationJSON; } catch (_) {}
        })();
        """
        try evaluate(bootstrap, in: context)
        try evaluate(request.entrySource, in: context)
        try checkCancellation(requestID)
        let call = """
        (() => {
          "use strict";
          const entry = globalThis[\(Self.javaScriptStringLiteral(invocation.entryFunction))];
          if (typeof entry !== "function") {
            throw new Error("__BLOCKS_ENTRY_MISSING__:\(invocation.entryFunction)");
          }
          const result = entry(
            __blocksInvocation.event || __blocksInvocation.input,
            Object.freeze({
              requestID: __blocksInvocation.requestID,
              configuration: __blocksInvocation.configuration,
              kind: __blocksInvocation.kind,
              input: __blocksInvocation.input,
            })
          );
          if (result && typeof result.then === "function") {
            throw new Error("__BLOCKS_ASYNC_RESULT__");
          }
          return JSON.stringify(result === undefined ? {} : result);
        })();
        """
        context.exception = nil
        let result = context.evaluateScript(call)
        if let exception = context.exception {
            let message = exception.toString() ?? "Unknown JavaScript exception."
            if message.contains("__BLOCKS_ENTRY_MISSING__") {
                throw BlocksNativePluginRunnerError.entryFunctionMissing(invocation.entryFunction)
            }
            if message.contains("__BLOCKS_ASYNC_RESULT__") {
                throw BlocksNativePluginRunnerError.asynchronousResultNotSupported
            }
            throw BlocksNativePluginRunnerError.scriptException(Self.boundedErrorMessage(message))
        }
        try progressBudget.checkWithinBudget()
        guard let resultJSON = result?.toString(),
              let outputData = resultJSON.data(using: .utf8),
              outputData.count <= Self.maximumOutputBytes else {
            throw BlocksNativePluginRunnerError.outputTooLarge
        }
        try checkCancellation(requestID)
        switch invocation.kind {
        case .hook:
            let hook = try JSONDecoder().decode(BlocksPluginHookResult.self, from: outputData)
            if let event = invocation.event,
               !event.phase.canMutateTransaction,
               (hook.disposition == .block || !hook.mutations.isEmpty) {
                throw BlocksNativePluginRunnerError.platformResultInvalid
            }
            return BlocksPluginRuntimeResult(
                hook: hook,
                uiStatePatches: hook.uiStatePatches,
                diagnostics: hook.diagnostics
            )
        case .action, .uiAction, .schedule:
            if let decoded = try? JSONDecoder().decode(BlocksPluginRuntimeResult.self, from: outputData) {
                return decoded
            }
            guard let output = try? JSONDecoder().decode([String: JSONValue].self, from: outputData) else {
                throw BlocksNativePluginRunnerError.platformResultInvalid
            }
            return BlocksPluginRuntimeResult(output: output)
        }
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.exception = nil
        context.evaluateScript(script)
        if let exception = context.exception {
            throw BlocksNativePluginRunnerError.scriptException(
                Self.boundedErrorMessage(exception.toString() ?? "Unknown JavaScript exception.")
            )
        }
    }

    private func checkCancellation(_ requestID: UUID) throws {
        cancellationLock.lock()
        let isCancelled = cancelledRequestIDs.contains(requestID)
        cancellationLock.unlock()
        if isCancelled {
            throw BlocksNativePluginRunnerError.cancelled
        }
    }

    private static func decodeNetworkRequest(
        _ json: String
    ) throws -> BlocksNativePluginNetworkRequest {
        guard let data = json.data(using: .utf8),
              data.count <= BlocksNativePluginNetworkBridgeLimits
                .maximumEncodedRequestBytes else {
            throw BlocksNativePluginRunnerError.networkRequestInvalid("Invalid request JSON.")
        }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any],
              let url = object["url"] as? String,
              let rawMethod = (object["method"] as? String)?.uppercased(),
              let method = BlocksNativePluginHTTPMethod(rawValue: rawMethod) else {
            throw BlocksNativePluginRunnerError.networkRequestInvalid(
                "url and a supported method are required."
            )
        }
        let headers = object["headers"] as? [String: String] ?? [:]
        let body: Data?
        if let bodyText = object["body"] as? String {
            body = Data(bodyText.utf8)
        } else if let base64 = object["bodyBase64"] as? String {
            body = Data(base64Encoded: base64)
        } else {
            body = nil
        }
        if object["bodyBase64"] != nil, body == nil {
            throw BlocksNativePluginRunnerError.networkRequestInvalid(
                "bodyBase64 is not valid Base64."
            )
        }
        let timeout = object["timeoutSeconds"] as? Double
            ?? (object["timeoutSeconds"] as? NSNumber)?.doubleValue
            ?? 15
        return BlocksNativePluginNetworkRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            timeoutSeconds: timeout
        )
    }

    private static func decodeProgress(
        _ json: String,
        requestID: UUID,
        manifest: BlocksNativePluginManifest,
        invocationKind: BlocksNativePluginInvocationKind
    ) throws -> BlocksNativePluginProgress {
        guard let data = json.data(using: .utf8), data.count <= 64 * 1_024 else {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any],
              let rawKind = object["kind"] as? String,
              let kind = BlocksNativePluginProgressKind(rawValue: rawKind) else {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let fraction = (object["fraction"] as? NSNumber)?.doubleValue
        if let fraction, !(0...1).contains(fraction) {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        guard progressKindIsAllowed(
            kind,
            manifest: manifest,
            invocationKind: invocationKind
        ) else {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let code = object["code"] as? String
        if let code,
           !isValidEventCode(code) {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        if kind == .status || kind == .diagnostics {
            guard code != nil else {
                throw BlocksNativePluginRunnerError.progressInvalid
            }
        }
        let text = object["text"] as? String
        if let text, text.count > maximumProgressTextCharacters {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let metadata: [String: JSONValue]
        if let rawMetadata = object["metadata"] {
            guard JSONSerialization.isValidJSONObject(rawMetadata),
                  let metadataData = try? JSONSerialization.data(
                    withJSONObject: rawMetadata
                  ),
                  metadataData.count <= 32 * 1_024,
                  let decoded = try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: metadataData
                  ) else {
                throw BlocksNativePluginRunnerError.progressInvalid
            }
            metadata = decoded
        } else {
            metadata = [:]
        }
        return BlocksNativePluginProgress(
            requestID: requestID,
            kind: kind,
            code: code,
            fraction: fraction,
            text: text,
            metadata: metadata
        )
    }

    private static func decodeGenericProgress(
        _ json: String,
        requestID: UUID
    ) throws -> BlocksNativePluginProgress {
        guard let data = json.data(using: .utf8), data.count <= 64 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawKind = object["kind"] as? String,
              let kind = BlocksNativePluginProgressKind(rawValue: rawKind) else {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let fraction = (object["fraction"] as? NSNumber)?.doubleValue
        if let fraction, !(0...1).contains(fraction) {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let code = object["code"] as? String
        if let code, !isValidEventCode(code) {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let text = object["text"] as? String
        if let text, text.count > maximumProgressTextCharacters {
            throw BlocksNativePluginRunnerError.progressInvalid
        }
        let metadata: [String: JSONValue]
        if let rawMetadata = object["metadata"] {
            guard JSONSerialization.isValidJSONObject(rawMetadata),
                  let encoded = try? JSONSerialization.data(withJSONObject: rawMetadata),
                  encoded.count <= 32 * 1_024,
                  let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: encoded) else {
                throw BlocksNativePluginRunnerError.progressInvalid
            }
            metadata = decoded
        } else {
            metadata = [:]
        }
        return BlocksNativePluginProgress(
            requestID: requestID,
            kind: kind,
            code: code,
            fraction: fraction,
            text: text,
            metadata: metadata
        )
    }

    private static func decodeHostOperation(
        _ json: String,
        pluginID: String
    ) throws -> BlocksPluginHostOperationRequest {
        guard let data = json.data(using: .utf8), data.count <= 2 * 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = object["operation"] as? String,
              isValidEventCode(operation) else {
            throw BlocksNativePluginRunnerError.hostOperationInvalid
        }
        let input: [String: JSONValue]
        if let rawInput = object["input"] {
            guard JSONSerialization.isValidJSONObject(rawInput),
                  let inputData = try? JSONSerialization.data(withJSONObject: rawInput),
                  let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: inputData) else {
                throw BlocksNativePluginRunnerError.hostOperationInvalid
            }
            input = decoded
        } else {
            input = [:]
        }
        return BlocksPluginHostOperationRequest(
            pluginID: pluginID,
            operation: operation,
            input: input
        )
    }

    private static func decodeOutput(
        _ data: Data,
        manifest: BlocksNativePluginManifest,
        invocationKind: BlocksNativePluginInvocationKind
    ) throws -> BlocksNativePluginOutput {
        if let text = try? JSONDecoder().decode(String.self, from: data) {
            guard manifest.schemaVersion < 3
                    || invocationKind != .translation else {
                // Schema v3 translation sources must return the explicit
                // terminal envelope. A bare string cannot carry a terminal
                // status and would make failed/completed states ambiguous.
                throw BlocksNativePluginRunnerError.invalidOutput
            }
            let normalized = text.trimmingCharacters(in: .newlines)
            guard !normalized.isEmpty else {
                throw BlocksNativePluginRunnerError.invalidOutput
            }
            return BlocksNativePluginOutput(text: normalized)
        }
        if manifest.schemaVersion < 3 {
            struct LegacyOutput: Decodable {
                let text: String
                let metadata: [String: JSONValue]?
            }
            guard let legacy = try? JSONDecoder().decode(
                LegacyOutput.self,
                from: data
            ) else {
                throw BlocksNativePluginRunnerError.invalidOutput
            }
            let normalized = legacy.text.trimmingCharacters(
                in: .newlines
            )
            guard !normalized.isEmpty else {
                throw BlocksNativePluginRunnerError.invalidOutput
            }
            return BlocksNativePluginOutput(
                text: normalized,
                metadata: legacy.metadata ?? [:]
            )
        }
        if invocationKind == .translation {
            guard let rawObject = try? JSONSerialization.jsonObject(
                    with: data
                  ),
                  let object = rawObject as? [String: Any],
                  object["status"] is String else {
                // BlocksNativePluginOutput preserves decode compatibility by
                // defaulting a missing status to completed. The v3 wire
                // contract is intentionally stricter: plugin authors must
                // declare the terminal state instead of relying on that
                // in-memory compatibility default.
                throw BlocksNativePluginRunnerError.invalidOutput
            }
        }
        let output: BlocksNativePluginOutput
        do {
            output = try JSONDecoder().decode(BlocksNativePluginOutput.self, from: data)
        } catch {
            throw BlocksNativePluginRunnerError.invalidOutput
        }
        switch output.status {
        case .completed:
            guard !output.text.trimmingCharacters(in: .newlines).isEmpty,
                  output.errorCode == nil,
                  output.errorMessage == nil else {
                throw BlocksNativePluginRunnerError.invalidOutput
            }
        case .failed:
            guard manifest.schemaVersion >= 3,
                  invocationKind == .translation,
                  let code = output.errorCode,
                  isValidEventCode(code),
                  let message = output.errorMessage?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty,
                  message.count <= 2_048,
                  output.text.isEmpty else {
                throw BlocksNativePluginRunnerError.invalidOutput
            }
        }
        return output
    }

    private static func progressKindIsAllowed(
        _ kind: BlocksNativePluginProgressKind,
        manifest: BlocksNativePluginManifest,
        invocationKind: BlocksNativePluginInvocationKind
    ) -> Bool {
        guard invocationKind == .translation else {
            return kind == .progress || kind == .partialText
        }
        if manifest.schemaVersion < 3 {
            return kind == .progress || kind == .partialText
        }
        guard manifest.translationSupportsStatus else { return false }
        return kind == .status || kind == .diagnostics
    }

    private static func isValidEventCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 46
                || $0 == 95
        }
    }

    private static func bridgeSuccessJSON(
        response: BlocksNativePluginNetworkResponse
    ) throws -> String {
        var value: [String: Any] = [
            "requestID": response.requestID.uuidString,
            "statusCode": response.statusCode,
            "headers": response.headers,
        ]
        if let bodyText = String(data: response.body, encoding: .utf8) {
            value["body"] = bodyText
            value["bodyBase64"] = NSNull()
            value["bodyEncoding"] = "utf8"
        } else {
            value["body"] = NSNull()
            value["bodyBase64"] = response.body.base64EncodedString()
            value["bodyEncoding"] = "base64"
        }
        let object: [String: Any] = ["ok": true, "value": value]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func bridgeFailureJSON(code: String, message: String) -> String {
        let object: [String: Any] = [
            "ok": false,
            "error": ["code": code, "message": boundedErrorMessage(message)],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return #"{"ok":false,"error":{"code":"bridge_failure","message":"Host bridge failed."}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func bridgeHostOperationJSON(
        _ response: BlocksPluginHostOperationResponse
    ) throws -> String {
        if response.ok {
            let valueData = try JSONEncoder().encode(response.value ?? .null)
            // Host operations intentionally use JSON scalars for values such
            // as a missing storage entry (`null`) or a boolean result.  The
            // default JSONSerialization parser only accepts object/array
            // roots, which made the first `storage.get` in a fresh plugin
            // fail before the plugin could initialize its state.
            let value = try JSONSerialization.jsonObject(
                with: valueData,
                options: [.fragmentsAllowed]
            )
            let object: [String: Any] = ["ok": true, "value": value]
            return String(
                decoding: try JSONSerialization.data(withJSONObject: object),
                as: UTF8.self
            )
        }
        return bridgeFailureJSON(
            code: response.errorCode ?? "host_operation_failed",
            message: response.errorMessage ?? "The host operation failed."
        )
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorCode(for error: Error) -> String {
        if let error = error as? BlocksNativePluginRunnerError {
            switch error {
            case .cancelled:
                return "cancelled"
            case .networkRequestInvalid:
                return "network_request_invalid"
            case .networkRequestFailed:
                return "network_request_failed"
            case .networkBudgetExceeded:
                return "network_budget_exceeded"
            case .progressBudgetExceeded:
                return "progress_budget_exceeded"
            case .hostOperationInvalid:
                return "host_operation_invalid"
            case .hostOperationFailed:
                return "host_operation_failed"
            case .platformResultInvalid:
                return "platform_result_invalid"
            case .scriptException:
                return "script_exception"
            case .entryFunctionMissing:
                return "entry_function_missing"
            case .asynchronousResultNotSupported:
                return "async_result_not_supported"
            case .invalidOutput, .outputTooLarge:
                return "invalid_output"
            default:
                return "invalid_plugin"
            }
        }
        if error is BlocksNativePluginNetworkPolicyError {
            return "network_policy_denied"
        }
        return "plugin_execution_failed"
    }

    private static func boundedErrorMessage(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: " ")
        return String(normalized.prefix(512))
    }

    private static func responseErrorMessage(_ error: Error) -> String {
        if case let BlocksNativePluginRunnerError.scriptException(message) = error {
            return String(message.prefix(16_384))
        }
        return boundedErrorMessage(error.localizedDescription)
    }
}

final class BlocksNativePluginRunnerXPCService: NSObject, BlocksNativePluginRunnerXPCProtocol {
    private let executionQueue = DispatchQueue(
        label: "app.blocks.plugin-runner.execution",
        qos: .userInitiated
    )
    private let watchdogQueue = DispatchQueue(
        label: "app.blocks.plugin-runner.watchdog",
        qos: .userInitiated
    )
    private let runnerLock = NSLock()
    private var activeRunners: [UUID: BlocksNativePluginJavaScriptRunner] = [:]
    private var watchdogs: [UUID: DispatchWorkItem] = [:]
    private let fatalTimeoutHandler: @Sendable () -> Void

    override convenience init() {
        self.init(fatalTimeoutHandler: {
            _exit(124)
        })
    }

    init(fatalTimeoutHandler: @escaping @Sendable () -> Void) {
        self.fatalTimeoutHandler = fatalTimeoutHandler
        super.init()
    }

    func prepareInvocation(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        reply(UUID(uuidString: requestID) != nil)
    }

    func execute(
        _ requestData: Data,
        hostEndpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard requestData.count <= 12 * 1_048_576,
              let request = try? JSONDecoder().decode(
                  BlocksNativePluginRunnerRequest.self,
                  from: requestData
              ),
              request.protocolVersion == BlocksNativePluginXPC.protocolVersion,
              request.executionTimeLimitSeconds.isFinite,
              (1...60).contains(request.executionTimeLimitSeconds) else {
            let response = BlocksNativePluginRunnerResponse(
                requestID: UUID(),
                status: .failed,
                errorCode: "invalid_request",
                errorMessage: BlocksNativePluginRunnerError.invalidRequest.localizedDescription
            )
            reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }

        let hostConnection = NSXPCConnection(listenerEndpoint: hostEndpoint)
        hostConnection.remoteObjectInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerHostXPCProtocol.self
        )
        hostConnection.resume()
        let sendableHostConnection = SendableXPCConnection(hostConnection)

        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { networkRequest in
                try Self.performNetworkRequest(
                    networkRequest,
                    over: sendableHostConnection.connection
                )
            },
            progressSink: { progress in
                guard let data = try? JSONEncoder().encode(progress) else { return }
                let proxy = sendableHostConnection.connection
                    .remoteObjectProxyWithErrorHandler { _ in }
                    as? BlocksNativePluginRunnerHostXPCProtocol
                proxy?.emitProgress(data)
            }
        )
        let requestID = request.invocation.requestID
        runnerLock.lock()
        guard activeRunners[requestID] == nil else {
            runnerLock.unlock()
            hostConnection.invalidate()
            let response = BlocksNativePluginRunnerResponse(
                requestID: requestID,
                status: .failed,
                errorCode: "duplicate_request",
                errorMessage: "The plugin runner is already processing this request."
            )
            reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }
        activeRunners[requestID] = runner
        runnerLock.unlock()

        executionQueue.async { [weak self] in
            guard let self else {
                hostConnection.invalidate()
                return
            }
            let watchdog = DispatchWorkItem { [weak self] in
                self?.terminateProcessIfRequestIsStillActive(requestID)
            }
            self.runnerLock.lock()
            guard self.activeRunners[requestID] === runner else {
                self.runnerLock.unlock()
                hostConnection.invalidate()
                return
            }
            self.watchdogs[requestID] = watchdog
            self.runnerLock.unlock()
            self.watchdogQueue.asyncAfter(
                deadline: .now() + request.executionTimeLimitSeconds + 0.5,
                execute: watchdog
            )
            let response = runner.execute(request)
            self.finishRequest(requestID)
            hostConnection.invalidate()
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    func executePlatform(
        _ requestData: Data,
        hostEndpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard requestData.count <= 12 * 1_048_576,
              let request = try? JSONDecoder().decode(
                  BlocksPluginRunnerRequest.self,
                  from: requestData
              ),
              request.protocolVersion == BlocksNativePluginXPC.protocolVersion,
              request.executionTimeLimitSeconds.isFinite,
              (0.05...60).contains(request.executionTimeLimitSeconds) else {
            let response = BlocksPluginRunnerResponse(
                requestID: UUID(),
                status: .failed,
                errorCode: "invalid_request",
                errorMessage: BlocksNativePluginRunnerError.invalidRequest.localizedDescription
            )
            reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }

        let hostConnection = NSXPCConnection(listenerEndpoint: hostEndpoint)
        hostConnection.remoteObjectInterface = NSXPCInterface(
            with: BlocksNativePluginRunnerHostXPCProtocol.self
        )
        hostConnection.resume()
        let sendableHostConnection = SendableXPCConnection(hostConnection)
        let runner = BlocksNativePluginJavaScriptRunner(
            networkBroker: { networkRequest in
                try Self.performNetworkRequest(
                    networkRequest,
                    over: sendableHostConnection.connection
                )
            },
            progressSink: { progress in
                guard let data = try? JSONEncoder().encode(progress) else { return }
                let proxy = sendableHostConnection.connection
                    .remoteObjectProxyWithErrorHandler { _ in }
                    as? BlocksNativePluginRunnerHostXPCProtocol
                proxy?.emitProgress(data)
            },
            hostOperationBroker: { operation in
                try Self.performHostOperation(
                    operation,
                    over: sendableHostConnection.connection
                )
            }
        )
        let requestID = request.invocation.requestID
        runnerLock.lock()
        guard activeRunners[requestID] == nil else {
            runnerLock.unlock()
            hostConnection.invalidate()
            let response = BlocksPluginRunnerResponse(
                requestID: requestID,
                status: .failed,
                errorCode: "duplicate_request",
                errorMessage: "The plugin runner is already processing this request."
            )
            reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }
        activeRunners[requestID] = runner
        runnerLock.unlock()

        executionQueue.async { [weak self] in
            guard let self else {
                hostConnection.invalidate()
                return
            }
            let watchdog = DispatchWorkItem { [weak self] in
                self?.terminateProcessIfRequestIsStillActive(requestID)
            }
            self.runnerLock.lock()
            guard self.activeRunners[requestID] === runner else {
                self.runnerLock.unlock()
                hostConnection.invalidate()
                return
            }
            self.watchdogs[requestID] = watchdog
            self.runnerLock.unlock()
            self.watchdogQueue.asyncAfter(
                deadline: .now() + request.executionTimeLimitSeconds + 0.5,
                execute: watchdog
            )
            let response = runner.executePlatform(request)
            self.finishRequest(requestID)
            hostConnection.invalidate()
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    func cancel(
        _ requestID: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let requestID = UUID(uuidString: requestID) else {
            reply(false)
            return
        }
        runnerLock.lock()
        let runner = activeRunners[requestID]
        runnerLock.unlock()
        reply(runner?.cancel(requestID: requestID) ?? false)
    }

    func cancelAll() {
        runnerLock.lock()
        let runners = activeRunners
        runnerLock.unlock()
        for (requestID, runner) in runners {
            _ = runner.cancel(requestID: requestID)
        }
    }

    private func finishRequest(_ requestID: UUID) {
        runnerLock.lock()
        activeRunners.removeValue(forKey: requestID)
        let watchdog = watchdogs.removeValue(forKey: requestID)
        runnerLock.unlock()
        watchdog?.cancel()
    }

    private func terminateProcessIfRequestIsStillActive(_ requestID: UUID) {
        runnerLock.lock()
        let isActive = activeRunners[requestID] != nil
        runnerLock.unlock()
        guard isActive else { return }
        fatalTimeoutHandler()
    }

    private static func performNetworkRequest(
        _ request: BlocksNativePluginNetworkRequest,
        over connection: NSXPCConnection
    ) throws -> BlocksNativePluginNetworkResponse {
        guard let requestData = try? JSONEncoder().encode(request) else {
            throw BlocksNativePluginRunnerError.networkRequestInvalid(
                "The request could not be encoded."
            )
        }
        let result = LockedNetworkResult()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            result.complete(error: error.localizedDescription)
        } as? BlocksNativePluginRunnerHostXPCProtocol
        guard let proxy else {
            throw BlocksNativePluginRunnerError.networkRequestFailed(
                "The host network broker is unavailable."
            )
        }
        proxy.performNetworkRequest(requestData) { responseData, errorMessage in
            result.complete(data: responseData, error: errorMessage)
        }

        let waitResult = result.semaphore.wait(
            timeout: .now() + min(max(request.timeoutSeconds + 5, 6), 65)
        )
        guard waitResult == .success else {
            throw BlocksNativePluginRunnerError.networkRequestFailed(
                "The host network broker timed out."
            )
        }
        let snapshot = result.snapshot()
        if let error = snapshot.error {
            throw BlocksNativePluginRunnerError.networkRequestFailed(error)
        }
        guard let data = snapshot.data,
              data.count <= 12 * 1_048_576,
              let response = try? JSONDecoder().decode(
                  BlocksNativePluginNetworkResponse.self,
                  from: data
              ),
              response.requestID == request.requestID else {
            throw BlocksNativePluginRunnerError.networkRequestFailed(
                "The host network broker returned an invalid response."
            )
        }
        return response
    }

    private static func performHostOperation(
        _ request: BlocksPluginHostOperationRequest,
        over connection: NSXPCConnection
    ) throws -> BlocksPluginHostOperationResponse {
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= 3 * 1_048_576 else {
            throw BlocksNativePluginRunnerError.hostOperationInvalid
        }
        let result = LockedNetworkResult()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            result.complete(error: error.localizedDescription)
        } as? BlocksNativePluginRunnerHostXPCProtocol
        guard let proxy else {
            throw BlocksNativePluginRunnerError.hostOperationFailed(
                "The host operation bridge is unavailable."
            )
        }
        proxy.performHostOperation(requestData) { data in
            result.complete(data: data)
        }
        guard result.semaphore.wait(timeout: .now() + 10) == .success else {
            throw BlocksNativePluginRunnerError.hostOperationFailed(
                "The host operation timed out."
            )
        }
        let snapshot = result.snapshot()
        if let error = snapshot.error {
            throw BlocksNativePluginRunnerError.hostOperationFailed(error)
        }
        guard let data = snapshot.data,
              data.count <= 4 * 1_048_576,
              let response = try? JSONDecoder().decode(
                  BlocksPluginHostOperationResponse.self,
                  from: data
              ),
              response.requestID == request.requestID else {
            throw BlocksNativePluginRunnerError.hostOperationFailed(
                "The host returned an invalid operation response."
            )
        }
        return response
    }
}

private final class SendableXPCConnection: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private final class LockedPluginNetworkBudget: @unchecked Sendable {
    private static let maximumRequestCount = 8
    private static let maximumAggregateBodyBytes = 16 * 1_048_576

    private let lock = NSLock()
    private var requestCount = 0
    private var aggregateBodyBytes = 0

    func consume(bytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard requestCount < Self.maximumRequestCount,
              bytes >= 0,
              aggregateBodyBytes <= Self.maximumAggregateBodyBytes - bytes else {
            throw BlocksNativePluginRunnerError.networkBudgetExceeded
        }
        requestCount += 1
        aggregateBodyBytes += bytes
    }
}

enum BlocksNativePluginProgressBudgetLimits {
    static let maximumEventCount = 512
    static let maximumAggregateBytes = 1_048_576
    static let maximumEventsPerSecond = 120
}

final class LockedPluginProgressBudget: @unchecked Sendable {
    typealias TimeProvider = @Sendable () -> TimeInterval

    private let lock = NSLock()
    private let timeProvider: TimeProvider
    private var eventCount = 0
    private var aggregateBytes = 0
    private var recentEventTimes: [TimeInterval] = []
    private var lastObservedTime: TimeInterval?
    private var exceededBudget = false

    init(
        timeProvider: @escaping TimeProvider = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.timeProvider = timeProvider
    }

    var hasExceededBudget: Bool {
        lock.lock()
        let value = exceededBudget
        lock.unlock()
        return value
    }

    func consume(bytes: Int) throws {
        let sampledTime = timeProvider()
        lock.lock()
        defer { lock.unlock() }

        guard !exceededBudget, bytes >= 0, sampledTime.isFinite else {
            exceededBudget = true
            throw BlocksNativePluginRunnerError.progressBudgetExceeded
        }
        let now = max(sampledTime, lastObservedTime ?? sampledTime)
        lastObservedTime = now
        recentEventTimes.removeAll { now - $0 >= 1 }
        guard eventCount < BlocksNativePluginProgressBudgetLimits.maximumEventCount,
              aggregateBytes
                <= BlocksNativePluginProgressBudgetLimits.maximumAggregateBytes - bytes,
              recentEventTimes.count
                < BlocksNativePluginProgressBudgetLimits.maximumEventsPerSecond else {
            exceededBudget = true
            throw BlocksNativePluginRunnerError.progressBudgetExceeded
        }
        eventCount += 1
        aggregateBytes += bytes
        recentEventTimes.append(now)
    }

    func checkWithinBudget() throws {
        guard !hasExceededBudget else {
            throw BlocksNativePluginRunnerError.progressBudgetExceeded
        }
    }
}

private final class LockedNetworkResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didComplete = false
    private var responseData: Data?
    private var errorMessage: String?

    func complete(data: Data? = nil, error: String? = nil) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        responseData = data
        errorMessage = error
        lock.unlock()
        semaphore.signal()
    }

    func snapshot() -> (data: Data?, error: String?) {
        lock.lock()
        let snapshot = (responseData, errorMessage)
        lock.unlock()
        return snapshot
    }
}
