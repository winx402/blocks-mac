import BlocksCore
import Darwin
import Dispatch
import Foundation
import Security

private final class LocalBrokerProbe: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var trusted = false
    func complete(_ result: Bool) {
        lock.lock(); trusted = result; lock.unlock()
        ready.signal()
    }
    func wait() -> Bool? {
        guard ready.wait(timeout: .now() + 2) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return trusted
    }
}

private func verifyBroker(_ proxy: BlocksActionBrokerClientXPCProtocol, connection: NSXPCConnection) -> Bool? {
    let probe = LocalBrokerProbe()
    proxy.probe?(withReply: {
        #if BLOCKS_LOCAL_DEVELOPMENT
        probe.complete(BlocksLocalBuildTrust.accepts(
            processIdentifier: connection.processIdentifier,
            userIdentifier: connection.effectiveUserIdentifier, role: "broker"
        ))
        #else
        // The pre-resume signing requirement authenticates each XPC message.
        probe.complete(connection.processIdentifier > 0 && connection.effectiveUserIdentifier == getuid())
        #endif
    })
    return probe.wait()
}

private func brokerConnectionRequirement() -> String? {
    #if BLOCKS_LOCAL_DEVELOPMENT
    return BlocksLocalBuildTrust.connectionRequirement(role: "broker")
    #else
    var own: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
          SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [CFString: Any],
          let team = values[kSecCodeInfoTeamIdentifier] as? String,
          team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
    return "anchor apple generic and identifier \"app.blocks.action-broker\" and certificate leaf[subject.OU] = \"\(team)\""
    #endif
}

func emit<T: Encodable>(_ value: T, exitCode: Int32 = 0) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(exitCode)
    } catch {
        fputs("{\"ok\":false,\"error\":{\"code\":\"json_encode_failed\",\"message\":\"Unable to encode output.\"}}\n", stderr)
        exit(1)
    }
}

struct ActionListOutput: Codable {
    let actions: [ActionDescriptor]
}

struct HelpOutput: Codable {
    let usage: String
    let actions: [String]
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

struct ScreenshotCLIParseError: Error {
    let code: String
    let message: String

    init(code: String = "invalid_arguments", message: String) {
        self.code = code
        self.message = message
    }
}

struct ActionCLIArguments<Request: Codable> {
    let request: Request
    let dryRun: Bool
    let outputPath: String?
    let allowOverwrite: Bool

    init(
        request: Request,
        dryRun: Bool,
        outputPath: String? = nil,
        allowOverwrite: Bool = false
    ) {
        self.request = request
        self.dryRun = dryRun
        self.outputPath = outputPath
        self.allowOverwrite = allowOverwrite
    }
}

struct ActionCLIDryRunResult<Request: Codable>: Codable {
    let dryRun: Bool
    let request: Request

    private enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case request
    }
}

private func optionValue(after option: String, at index: Int, in args: [String]) throws -> String {
    guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
        throw ScreenshotCLIParseError(message: "Missing value for \(option).")
    }
    return args[index + 1]
}

private func rejectDuplicate(_ option: String, seen: inout Set<String>) throws {
    guard seen.insert(option).inserted else {
        throw ScreenshotCLIParseError(message: "Duplicate option: \(option)")
    }
}

private func parseLimit(_ value: String) throws -> Int {
    guard let limit = Int(value) else {
        throw ScreenshotHistoryActionValidationError.invalidLimit
    }
    return limit
}

func parseScreenshotArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotCaptureActionInput> {
    var interaction: ScreenshotCaptureInteraction?
    var kind: ScreenshotCaptureActionKind?
    var displayScope: ScreenshotCaptureActionDisplayScope?
    var copy: Bool?
    var outputPath: String?
    var format: ScreenshotCaptureFormat = .png
    var watermark: ScreenshotCaptureWatermarkSelection = .default
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--dry-run":
            dryRun = true
            index += 1
        case "--interactive":
            guard interaction == nil else {
                throw ScreenshotCLIParseError(message: "Choose exactly one of --interactive or --no-editor.")
            }
            interaction = .interactive
            index += 1
        case "--no-editor":
            guard interaction == nil else {
                throw ScreenshotCLIParseError(message: "Choose exactly one of --interactive or --no-editor.")
            }
            interaction = .noEditor
            index += 1
        case "--kind":
            let rawValue = try optionValue(after: option, at: index, in: args)
            guard let parsed = ScreenshotCaptureActionKind(rawValue: rawValue) else {
                throw ScreenshotCLIParseError(message: "Invalid screenshot kind. Use smart, region, window, or display.")
            }
            kind = parsed
            index += 2
        case "--display-scope":
            let rawValue = try optionValue(after: option, at: index, in: args)
            switch rawValue {
            case "current":
                displayScope = .current
            case "all":
                displayScope = .all
            default:
                guard let displayID = UInt32(rawValue), displayID > 0 else {
                    throw ScreenshotCLIParseError(message: "Invalid display scope. Use current, all, or a positive display ID.")
                }
                displayScope = .displayID(displayID)
            }
            index += 2
        case "--copy":
            copy = true
            index += 1
        case "--output":
            outputPath = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--format":
            let rawValue = try optionValue(after: option, at: index, in: args)
            guard let parsed = ScreenshotCaptureFormat(rawValue: rawValue) else {
                throw ScreenshotCLIParseError(message: "Invalid screenshot format. Use png or jpeg.")
            }
            format = parsed
            index += 2
        case "--watermark":
            let rawValue = try optionValue(after: option, at: index, in: args)
            switch rawValue {
            case "default":
                watermark = .default
            case "none":
                watermark = .none
            default:
                guard let presetID = UUID(uuidString: rawValue) else {
                    throw ScreenshotCLIParseError(
                        message: "Invalid watermark. Use default, none, or a preset UUID."
                    )
                }
                watermark = .presetID(presetID)
            }
            index += 2
        default:
            throw ScreenshotCLIParseError(message: "Unknown screenshot option: \(option)")
        }
    }

    guard let interaction else {
        throw ScreenshotCLIParseError(message: "Choose exactly one of --interactive or --no-editor.")
    }
    let resolvedKind: ScreenshotCaptureActionKind
    switch interaction {
    case .interactive:
        resolvedKind = kind ?? .smart
    case .noEditor:
        guard let kind else {
            throw ScreenshotCLIParseError(message: "--no-editor requires --kind region|window|display.")
        }
        resolvedKind = kind
    }

    return ActionCLIArguments(
        request: try ScreenshotCaptureActionInput(
            kind: resolvedKind,
            interaction: interaction,
            displayScope: displayScope,
            copy: copy,
            outputPath: outputPath,
            format: format,
            watermark: watermark
        ),
        dryRun: dryRun,
        outputPath: outputPath,
        allowOverwrite: true
    )
}

func parseScrollingStatusArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotScrollingStatusActionInput> {
    var dryRun = false
    var seenOptions = Set<String>()

    for option in args {
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--dry-run":
            dryRun = true
        default:
            throw ScreenshotCLIParseError(message: "Unknown scrolling status option: \(option)")
        }
    }
    return ActionCLIArguments(
        request: ScreenshotScrollingStatusActionInput(),
        dryRun: dryRun
    )
}

func parseScrollingFinishArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotScrollingFinishActionInput> {
    var sessionID: String?
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--session-id":
            sessionID = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--dry-run":
            dryRun = true
            index += 1
        default:
            throw ScreenshotCLIParseError(message: "Unknown scrolling finish option: \(option)")
        }
    }
    return ActionCLIArguments(
        request: try ScreenshotScrollingFinishActionInput(sessionID: sessionID ?? ""),
        dryRun: dryRun
    )
}

func parseScrollingCancelArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotScrollingCancelActionInput> {
    var sessionID: String?
    var confirm = false
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--session-id":
            sessionID = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--confirm":
            confirm = true
            index += 1
        case "--dry-run":
            dryRun = true
            index += 1
        default:
            throw ScreenshotCLIParseError(message: "Unknown scrolling cancel option: \(option)")
        }
    }
    return ActionCLIArguments(
        request: try ScreenshotScrollingCancelActionInput(
            sessionID: sessionID ?? "",
            confirm: confirm
        ),
        dryRun: dryRun
    )
}

private struct HistoryPageCLIOptions {
    let cursor: String?
    let limit: Int
    let includeOCR: Bool
    let query: String?
    let dryRun: Bool
}

private func parseHistoryPageOptions(_ args: [String], requiresQuery: Bool) throws -> HistoryPageCLIOptions {
    var cursor: String?
    var limit = ScreenshotHistoryQueryActionInput.defaultLimit
    var includeOCR = false
    var query: String?
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--cursor":
            cursor = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--limit":
            limit = try parseLimit(optionValue(after: option, at: index, in: args))
            index += 2
        case "--include-ocr":
            includeOCR = true
            index += 1
        case "--query" where requiresQuery:
            query = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--dry-run":
            dryRun = true
            index += 1
        default:
            throw ScreenshotCLIParseError(message: "Unknown history option: \(option)")
        }
    }
    if requiresQuery, query == nil {
        throw ScreenshotHistoryActionValidationError.invalidQuery
    }
    return HistoryPageCLIOptions(
        cursor: cursor,
        limit: limit,
        includeOCR: includeOCR,
        query: query,
        dryRun: dryRun
    )
}

func parseHistoryQueryArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotHistoryQueryActionInput> {
    let options = try parseHistoryPageOptions(args, requiresQuery: false)
    return ActionCLIArguments(
        request: try ScreenshotHistoryQueryActionInput(
            cursor: options.cursor,
            limit: options.limit,
            includeOCR: options.includeOCR
        ),
        dryRun: options.dryRun
    )
}

func parseHistorySearchArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotHistorySearchActionInput> {
    let options = try parseHistoryPageOptions(args, requiresQuery: true)
    return ActionCLIArguments(
        request: try ScreenshotHistorySearchActionInput(
            query: options.query ?? "",
            cursor: options.cursor,
            limit: options.limit,
            includeOCR: options.includeOCR
        ),
        dryRun: options.dryRun
    )
}

func parseOCRStatusArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotOCRStatusActionInput> {
    var recordIDs = [String]()
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        switch option {
        case "--record-id":
            recordIDs.append(try optionValue(after: option, at: index, in: args))
            index += 2
        case "--dry-run":
            try rejectDuplicate(option, seen: &seenOptions)
            dryRun = true
            index += 1
        default:
            throw ScreenshotCLIParseError(message: "Unknown OCR status option: \(option)")
        }
    }
    return ActionCLIArguments(
        request: try ScreenshotOCRStatusActionInput(recordIDs: recordIDs),
        dryRun: dryRun
    )
}

func parseOCRRetryArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotOCRRetryActionInput> {
    var recordID: String?
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--record-id":
            recordID = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--dry-run":
            dryRun = true
            index += 1
        default:
            throw ScreenshotCLIParseError(message: "Unknown OCR retry option: \(option)")
        }
    }
    return ActionCLIArguments(
        request: try ScreenshotOCRRetryActionInput(recordID: recordID ?? ""),
        dryRun: dryRun
    )
}

func parseHistoryExportArguments(_ args: [String]) throws -> ActionCLIArguments<ScreenshotHistoryExportActionInput> {
    var recordID: String?
    var format: ScreenshotCaptureFormat = .png
    var outputPath: String?
    var allowOverwrite = false
    var dryRun = false
    var seenOptions = Set<String>()
    var index = 0

    while index < args.count {
        let option = args[index]
        try rejectDuplicate(option, seen: &seenOptions)
        switch option {
        case "--record-id":
            recordID = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--format":
            let rawValue = try optionValue(after: option, at: index, in: args)
            guard let parsed = ScreenshotCaptureFormat(rawValue: rawValue) else {
                throw ScreenshotCLIParseError(code: "invalid_format", message: "Invalid export format. Use png or jpeg.")
            }
            format = parsed
            index += 2
        case "--output":
            outputPath = try optionValue(after: option, at: index, in: args)
            index += 2
        case "--overwrite":
            allowOverwrite = true
            index += 1
        case "--dry-run":
            dryRun = true
            index += 1
        default:
            throw ScreenshotCLIParseError(message: "Unknown history export option: \(option)")
        }
    }
    guard let outputPath, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ScreenshotCLIParseError(message: "History export requires --output PATH.")
    }
    return ActionCLIArguments(
        request: try ScreenshotHistoryExportActionInput(recordID: recordID ?? "", format: format),
        dryRun: dryRun,
        outputPath: outputPath,
        allowOverwrite: allowOverwrite
    )
}

private enum OutputDestinationKind {
    case missing
    case regularFile(OutputDestinationIdentity)
}

private struct OutputDestinationIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t

    init(metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        fileType = metadata.st_mode & mode_t(S_IFMT)
    }
}

private struct PreparedOutputDestination {
    let url: URL
    let temporaryURL: URL
    let file: FileHandle
    let existingIdentity: OutputDestinationIdentity?
    private var isClosed = false

    init(
        url: URL,
        temporaryURL: URL,
        file: FileHandle,
        existingIdentity: OutputDestinationIdentity?
    ) {
        self.url = url
        self.temporaryURL = temporaryURL
        self.file = file
        self.existingIdentity = existingIdentity
    }

    mutating func finish(success: Bool) throws {
        guard !isClosed else { return }
        isClosed = true
        if success {
            do {
                try file.synchronize()
                try file.close()
                if let existingIdentity {
                    // This narrows, but cannot atomically close, the lstat-to-replace TOCTOU window.
                    try recheckOutputDestination(at: url.path, matches: existingIdentity)
                    _ = try FileManager.default.replaceItemAt(
                        url,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: url)
                }
            } catch let error as ScreenshotCLIParseError {
                try? file.close()
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            } catch {
                try? file.close()
                try? FileManager.default.removeItem(at: temporaryURL)
                throw ScreenshotCLIParseError(
                    code: "output_finalize_failed",
                    message: "Unable to finalize output file."
                )
            }
        } else {
            try? file.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}

private func outputDestinationKind(at path: String) throws -> OutputDestinationKind {
    var metadata = stat()
    let result = path.withCString { lstat($0, &metadata) }
    if result == 0 {
        let kind = metadata.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK) {
            throw ScreenshotCLIParseError(
                code: "output_symlink_rejected",
                message: "Output destination must not be a symbolic link."
            )
        }
        guard kind == mode_t(S_IFREG) else {
            throw ScreenshotCLIParseError(
                code: "output_not_regular_file",
                message: "Output destination must be a regular file."
            )
        }
        return .regularFile(OutputDestinationIdentity(metadata: metadata))
    }
    guard errno == ENOENT else {
        throw ScreenshotCLIParseError(
            code: "output_unavailable",
            message: "Unable to inspect output destination."
        )
    }
    return .missing
}

private func recheckOutputDestination(
    at path: String,
    matches expectedIdentity: OutputDestinationIdentity
) throws {
    var metadata = stat()
    let result = path.withCString { lstat($0, &metadata) }
    guard result == 0, OutputDestinationIdentity(metadata: metadata) == expectedIdentity else {
        throw ScreenshotCLIParseError(
            code: "output_destination_changed",
            message: "Output destination changed before finalization."
        )
    }
}

private func makeOutputOpenError() -> ScreenshotCLIParseError {
    switch errno {
    case ELOOP:
        ScreenshotCLIParseError(
            code: "output_symlink_rejected",
            message: "Output destination must not be a symbolic link."
        )
    case EEXIST:
        ScreenshotCLIParseError(
            code: "output_exists",
            message: "Output destination already exists; pass --overwrite to replace it."
        )
    case ENOENT, ENOTDIR:
        ScreenshotCLIParseError(
            code: "output_directory_unavailable",
            message: "Output directory does not exist."
        )
    default:
        ScreenshotCLIParseError(
            code: "output_create_failed",
            message: "Unable to create or open output destination."
        )
    }
}

private func prepareOutputDestination(
    path: String,
    allowOverwrite: Bool
) throws -> PreparedOutputDestination {
    let kind = try outputDestinationKind(at: path)
    let existingIdentity: OutputDestinationIdentity?
    switch kind {
    case .missing:
        existingIdentity = nil
    case let .regularFile(identity):
        existingIdentity = identity
    }
    if existingIdentity != nil, !allowOverwrite {
        throw ScreenshotCLIParseError(
            code: "output_exists",
            message: "Output destination already exists; pass --overwrite to replace it."
        )
    }

    let url = URL(fileURLWithPath: path)
    let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
        ".blocks-export-\(UUID().uuidString).tmp",
        isDirectory: false
    )
    let descriptor = temporaryURL.path.withCString {
        Darwin.open(
            $0,
            O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
            mode_t(S_IRUSR | S_IWUSR)
        )
    }
    guard descriptor >= 0 else {
        throw makeOutputOpenError()
    }
    if fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) != 0 {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: temporaryURL)
        throw ScreenshotCLIParseError(
            code: "output_create_failed",
            message: "Unable to secure output destination."
        )
    }
    return PreparedOutputDestination(
        url: url,
        temporaryURL: temporaryURL,
        file: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false),
        existingIdentity: existingIdentity
    )
}

func emitActionFailure<Result: Codable>(
    actionID: ActionID,
    requestID: ActionRequestID,
    error: ActionBrokerError,
    resultType _: Result.Type,
    exitCode: Int32
) -> Never {
    emit(
        ActionBrokerTerminalResponse<Result>.failed(
            requestID: requestID,
            actionID: actionID,
            error: error
        ),
        exitCode: exitCode
    )
}

func emitArgumentFailure<Result: Codable>(
    actionID: ActionID,
    requestID: ActionRequestID,
    error: Error,
    resultType: Result.Type
) -> Never {
    let brokerError: ActionBrokerError
    switch error {
    case let error as ScreenshotCLIParseError:
        brokerError = ActionBrokerError(
            category: .invalidRequest,
            code: error.code,
            message: error.message,
            retryable: false
        )
    case let error as ScreenshotCaptureActionValidationError:
        brokerError = ActionBrokerError(
            category: .invalidRequest,
            code: "invalid_arguments",
            message: error.message,
            retryable: false,
            details: ["validation_code": .string(error.code)]
        )
    case let error as ScreenshotHistoryActionValidationError:
        brokerError = ActionBrokerError(
            category: .invalidRequest,
            code: error.code,
            message: error.message,
            retryable: false
        )
    case let error as ScreenshotScrollingActionValidationError:
        brokerError = ActionBrokerError(
            category: .invalidRequest,
            code: error.code,
            message: error.message,
            retryable: false
        )
    default:
        brokerError = ActionBrokerError(
            category: .invalidRequest,
            code: "invalid_arguments",
            message: "Invalid screenshot arguments.",
            retryable: false
        )
    }
    emitActionFailure(
        actionID: actionID,
        requestID: requestID,
        error: brokerError,
        resultType: resultType,
        exitCode: 2
    )
}

func submitToBroker<Payload: Codable, Result: Codable>(
    _ request: ActionBrokerRequest<Payload>,
    outputFile: FileHandle?,
    timeout: TimeInterval,
    resultType _: Result.Type
) throws -> ActionBrokerTerminalResponse<Result> {
    let requestData = try JSONEncoder().encode(request)
    let connection = NSXPCConnection(machServiceName: BlocksActionBrokerXPC.machServiceName)
    guard let requirement = brokerConnectionRequirement() else {
        throw BlocksCLITransportError.localIdentityUnavailable
    }
    connection.setCodeSigningRequirement(requirement)
    connection.remoteObjectInterface = NSXPCInterface(with: BlocksActionBrokerClientXPCProtocol.self)

    let result = BrokerReplyBox<Result>()
    connection.invalidationHandler = {
        result.finish(.failure(ActionBrokerError(
            category: .availability,
            code: "broker_unavailable",
            message: "BlocksActionBroker is unavailable. Enable CLI integration in Blocks settings.",
            retryable: false,
            details: ["explicit_enable_required": .bool(true)]
        )))
    }
    connection.interruptionHandler = connection.invalidationHandler
    connection.resume()

    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
        result.finish(.failure(ActionBrokerError(
            category: .availability,
            code: "broker_unavailable",
            message: "BlocksActionBroker is unavailable. Enable CLI integration in Blocks settings.",
            retryable: false,
            details: ["explicit_enable_required": .bool(true)]
        )))
    } as? BlocksActionBrokerClientXPCProtocol
    guard let proxy else {
        connection.invalidate()
        throw BlocksCLITransportError.proxyUnavailable
    }
    guard let trustedPeer = verifyBroker(proxy, connection: connection) else {
        connection.invalidate()
        throw BlocksCLITransportError.proxyUnavailable
    }
    guard trustedPeer else {
        connection.invalidate()
        throw BlocksCLITransportError.untrustedPeer
    }
    proxy.submit(requestData, outputFile: outputFile) { data in
        do {
            result.finish(.success(try JSONDecoder().decode(
                ActionBrokerTerminalResponse<Result>.self,
                from: data
            )))
        } catch {
            result.finish(.failure(ActionBrokerError(
                category: .transport,
                code: "invalid_broker_response",
                message: "The action broker returned an invalid response.",
                retryable: false
            )))
        }
    }

    let terminal = result.wait(
        requestID: request.requestID,
        actionID: request.actionID,
        timeout: timeout
    )
    if terminal.error?.code == "broker_response_timeout" {
        let cancellation = DispatchSemaphore(value: 0)
        proxy.cancel(request.requestID.rawValue) { _ in cancellation.signal() }
        _ = cancellation.wait(timeout: .now() + 5)
    }
    connection.invalidate()
    return terminal
}

private final class BrokerReplyBox<Result: Codable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var outcome: Swift.Result<ActionBrokerTerminalResponse<Result>, ActionBrokerError>?

    func finish(_ result: Swift.Result<ActionBrokerTerminalResponse<Result>, ActionBrokerError>) {
        condition.lock()
        guard outcome == nil else {
            condition.unlock()
            return
        }
        outcome = result
        condition.broadcast()
        condition.unlock()
    }

    func wait(
        requestID: ActionRequestID,
        actionID: ActionID,
        timeout: TimeInterval
    ) -> ActionBrokerTerminalResponse<Result> {
        condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil, condition.wait(until: deadline) {}
        let result = outcome ?? .failure(ActionBrokerError(
            category: .transport,
            code: "broker_response_timeout",
            message: "The action broker did not return a terminal response before the deadline.",
            retryable: true
        ))
        condition.unlock()
        switch result {
        case let .success(response):
            return response
        case let .failure(error):
            return .failed(requestID: requestID, actionID: actionID, error: error)
        }
    }
}

/// Typed setup failures before a broker terminal response exists. In
/// particular, a failed identity probe must not be presented as a disabled
/// integration: it can indicate a rejected or untrusted peer.
enum BlocksCLITransportError: Error {
    case proxyUnavailable
    case localIdentityUnavailable
    case untrustedPeer

    var brokerError: ActionBrokerError {
        switch self {
        case .proxyUnavailable:
            return ActionBrokerError(
                category: .availability,
                code: "broker_unavailable",
                message: "BlocksActionBroker is unavailable. Enable CLI integration in Blocks settings.",
                retryable: false,
                details: ["explicit_enable_required": .bool(true)]
            )
        case .localIdentityUnavailable:
            return ActionBrokerError(
                category: .permission,
                code: "cli_identity_unavailable",
                message: "The Blocks CLI signing identity could not be verified.",
                retryable: false
            )
        case .untrustedPeer:
            return ActionBrokerError(
                category: .permission,
                code: "broker_identity_untrusted",
                message: "The BlocksActionBroker identity could not be verified.",
                retryable: false
            )
        }
    }

    var exitCode: Int32 {
        switch self {
        case .proxyUnavailable: return 5
        case .localIdentityUnavailable, .untrustedPeer: return 4
        }
    }
}

func executeAction<Payload: Codable, Result: Codable>(
    action: BlocksAction,
    requestID: ActionRequestID,
    arguments: ActionCLIArguments<Payload>,
    timeout: TimeInterval,
    resultType: Result.Type
) -> Never {
    let actionID = action.actionID
    if arguments.dryRun {
        emit(ActionBrokerTerminalResponse.completed(
            requestID: requestID,
            actionID: actionID,
            result: ActionCLIDryRunResult(dryRun: true, request: arguments.request)
        ))
    }

    var destination: PreparedOutputDestination?
    do {
        if let outputPath = arguments.outputPath {
            destination = try prepareOutputDestination(
                path: outputPath,
                allowOverwrite: arguments.allowOverwrite
            )
        }
        let request = ActionBrokerRequest(
            requestID: requestID,
            actionID: actionID,
            payload: arguments.request
        )
        let response = try submitToBroker(
            request,
            outputFile: destination?.file,
            timeout: timeout,
            resultType: resultType
        )
        try destination?.finish(success: response.status == .completed)
        emit(response, exitCode: response.status == .completed ? 0 : 1)
    } catch let error as ScreenshotCLIParseError {
        try? destination?.finish(success: false)
        emitActionFailure(
            actionID: actionID,
            requestID: requestID,
            error: ActionBrokerError(
                category: .invalidRequest,
                code: error.code,
                message: error.message,
                retryable: false
            ),
            resultType: resultType,
            exitCode: 2
        )
    } catch let error as BlocksCLITransportError {
        try? destination?.finish(success: false)
        emitActionFailure(
            actionID: actionID,
            requestID: requestID,
            error: error.brokerError,
            resultType: resultType,
            exitCode: error.exitCode
        )
    } catch {
        try? destination?.finish(success: false)
        emitActionFailure(
            actionID: actionID,
            requestID: requestID,
            error: ActionBrokerError(
                category: .availability,
                code: "broker_unavailable",
                message: "BlocksActionBroker is unavailable. Enable CLI integration in Blocks settings.",
                retryable: false,
                details: ["explicit_enable_required": .bool(true)]
            ),
            resultType: resultType,
            exitCode: 1
        )
    }
}

private let usage = """
blocks list | blocks run ACTION [options] | blocks privacy subjects|policy|action ... | blocks plugin COMMAND ... | blocks translation-source COMMAND ...
capture: blocks run blocks.screenshot.capture [--dry-run] (--interactive [--kind smart] | --no-editor --kind region|window|display) [--display-scope current|all|DISPLAY_ID] [--copy] [--output PATH] [--format png|jpeg] [--watermark default|none|PRESET_UUID]
history: blocks run blocks.screenshot.history.query [--cursor CURSOR] [--limit 1...100] [--include-ocr] [--dry-run]
search: blocks run blocks.screenshot.history.search --query QUERY [--cursor CURSOR] [--limit 1...100] [--include-ocr] [--dry-run]
ocr: blocks run blocks.screenshot.ocr.status --record-id ID [--record-id ID ...] [--dry-run] | blocks run blocks.screenshot.ocr.retry --record-id ID [--dry-run]
export: blocks run blocks.screenshot.history.export --record-id ID --output PATH [--format png|jpeg] [--overwrite] [--dry-run]
scrolling: blocks run blocks.screenshot.scrolling.status [--dry-run] | blocks run blocks.screenshot.scrolling.finish --session-id ID [--dry-run] | blocks run blocks.screenshot.scrolling.cancel --session-id ID --confirm [--dry-run]
translation sources: blocks translation-source --help
feedback: blocks feedback --help
"""

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args == ["--help"] || args == ["help"] {
    emit(HelpOutput(
        usage: usage,
        actions: ActionRegistry.actions.map(\.actionID.rawValue) + [
            "privacy.subjects.list",
            "privacy.subjects.resolve",
            "privacy.policy.get",
            "privacy.policy.set",
            "privacy.action.blocked",
        ]
    ))
}

switch args.first {
case "feedback":
    let feedbackArguments = Array(args.dropFirst())
    if feedbackArguments.isEmpty || feedbackArguments == ["--help"] || feedbackArguments == ["help"] {
        emit(HelpOutput(usage: feedbackUsage, actions: ["feedback.doctor", "feedback.list", "feedback.preview", "feedback.submit", "feedback.create"]))
    }
    let (feedbackOutput, feedbackExitCode) = FeedbackCLI.run(args: feedbackArguments)
    emit(feedbackOutput, exitCode: feedbackExitCode)

case "list":
    emit(ActionListOutput(actions: ActionRegistry.actions))

case "privacy":
    let (envelope, exitCode) = PrivacyCLIService.run(args: Array(args.dropFirst()))
    emit(envelope, exitCode: exitCode)

case "translation-source":
    let translationArguments = Array(args.dropFirst())
    if translationArguments.isEmpty
        || translationArguments == ["--help"]
        || translationArguments == ["help"] {
        emit(HelpOutput(
            usage: translationSourceUsage,
            actions: [
                BlocksAction.translationSourceManage.rawValue
            ]
        ))
    }
    runTranslationSourceCLI(args: translationArguments)

case "plugin":
    let pluginArguments = Array(args.dropFirst())
    if pluginArguments.isEmpty
        || pluginArguments == ["--help"]
        || pluginArguments == ["help"] {
        emit(HelpOutput(
            usage: pluginUsage,
            actions: [BlocksAction.pluginManage.rawValue]
        ))
    }
    runPluginCLI(args: pluginArguments)

case "run":
    guard args.count >= 2 else {
        emit(ActionEnvelope(
            ok: false,
            action: "unknown",
            result: [String: JSONValue](),
            error: ActionError(code: "missing_action", message: "Usage: blocks run <action> [options]")
        ), exitCode: 2)
    }
    let rawAction = args[1]
    guard let action = BlocksAction(rawValue: rawAction) else {
        emit(ActionEnvelope(
            ok: false,
            action: rawAction,
            result: [String: JSONValue](),
            error: ActionError(code: "unknown_action", message: "Unknown action.")
        ), exitCode: 1)
    }

    let requestID = ActionRequestID.make()
    let actionArguments = Array(args.dropFirst(2))
    switch action {
    case .screenshotCapture:
        do {
            let parsed = try parseScreenshotArguments(actionArguments)
            let timeout: TimeInterval = parsed.request.interaction == .interactive ? 600 : 90
            executeAction(
                action: action,
                requestID: requestID,
                arguments: parsed,
                timeout: timeout,
                resultType: ScreenshotCaptureActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotCaptureActionResult.self
            )
        }
    case .screenshotHistoryQuery:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseHistoryQueryArguments(actionArguments),
                timeout: 90,
                resultType: ScreenshotHistoryPageActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotHistoryPageActionResult.self
            )
        }
    case .screenshotHistorySearch:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseHistorySearchArguments(actionArguments),
                timeout: 90,
                resultType: ScreenshotHistoryPageActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotHistoryPageActionResult.self
            )
        }
    case .screenshotOCRStatus:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseOCRStatusArguments(actionArguments),
                timeout: 90,
                resultType: ScreenshotOCRStatusActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotOCRStatusActionResult.self
            )
        }
    case .screenshotOCRRetry:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseOCRRetryArguments(actionArguments),
                timeout: 90,
                resultType: ScreenshotOCRRetryActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotOCRRetryActionResult.self
            )
        }
    case .screenshotHistoryExport:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseHistoryExportArguments(actionArguments),
                timeout: 90,
                resultType: ScreenshotHistoryExportActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotHistoryExportActionResult.self
            )
        }
    case .screenshotScrollingStatus:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseScrollingStatusArguments(actionArguments),
                timeout: 30,
                resultType: ScreenshotScrollingStatusActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotScrollingStatusActionResult.self
            )
        }
    case .screenshotScrollingFinish:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseScrollingFinishArguments(actionArguments),
                timeout: 90,
                resultType: ScreenshotScrollingFinishActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotScrollingFinishActionResult.self
            )
        }
    case .screenshotScrollingCancel:
        do {
            executeAction(
                action: action,
                requestID: requestID,
                arguments: try parseScrollingCancelArguments(actionArguments),
                timeout: 30,
                resultType: ScreenshotScrollingCancelActionResult.self
            )
        } catch {
            emitArgumentFailure(
                actionID: action.actionID,
                requestID: requestID,
                error: error,
                resultType: ScreenshotScrollingCancelActionResult.self
            )
        }
    case .translationSourceManage:
        emitActionFailure(
            actionID: action.actionID,
            requestID: requestID,
            error: ActionBrokerError(
                category: .invalidRequest,
                code: "use_translation_source_command",
                message:
                    "Use `blocks translation-source --help` for translation source management.",
                retryable: false
            ),
            resultType:
                TranslationSourceManagementActionResult.self,
            exitCode: 2
        )
    case .pluginManage:
        emitActionFailure(
            actionID: action.actionID,
            requestID: requestID,
            error: ActionBrokerError(
                category: .invalidRequest,
                code: "use_plugin_command",
                message: "Use `blocks plugin --help` for plugin management.",
                retryable: false
            ),
            resultType: PluginDevelopmentActionResult.self,
            exitCode: 2
        )
    }

default:
    emit(ActionEnvelope(
        ok: false,
        action: "unknown",
        result: [String: JSONValue](),
        error: ActionError(code: "unknown_command", message: "Unknown command.")
    ), exitCode: 2)
}
