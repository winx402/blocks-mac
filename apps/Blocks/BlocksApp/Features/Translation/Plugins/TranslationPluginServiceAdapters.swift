import BlocksCore
import CoreGraphics
import CryptoKit
import Foundation

enum TranslationAttachmentDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
final class TranslationUnavailablePersistedPluginServiceAdapter:
    TranslationServiceAdapter
{
    private let serviceID: String

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    var descriptor: TranslationServiceDescriptor {
        TranslationServiceDescriptor(
            id: serviceID,
            displayName: String(serviceID.dropFirst("plugin:".count)),
            kind: .plugin,
            availability: .disabled,
            supportsStreaming: false
        )
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: TranslationServiceAdapterError.unavailable(
                    code: "plugin_runner_unavailable",
                    message: L10n.string(
                        "translation.error.pluginRunnerUnavailable"
                    )
                )
            )
        }
    }
}

@MainActor
final class TranslationUnavailablePluginServiceAdapter:
    TranslationServiceAdapter
{
    private let metadata: BlocksNativePluginMetadata
    private let errorCode: String
    private let message: String

    init(
        metadata: BlocksNativePluginMetadata,
        errorCode: String,
        message: String
    ) {
        self.metadata = metadata
        self.errorCode = errorCode
        self.message = message
    }

    var descriptor: TranslationServiceDescriptor {
        TranslationServiceDescriptor(
            id: "plugin:\(metadata.id)",
            displayName: metadata.displayName,
            kind: .plugin,
            version: metadata.packageVersion,
            availability: .disabled,
            supportsStreaming: false
        )
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        let error = TranslationServiceAdapterError.unavailable(
            code: errorCode,
            message: message
        )
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

@MainActor
final class TranslationPluginServiceAdapter: TranslationServiceAdapter {
    private let package: BlocksNativePluginValidatedPackage
    private let metadata: BlocksNativePluginMetadata
    private let executor: any BlocksNativePluginExecuting
    private let configuration: [String: JSONValue]

    init(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        executor: any BlocksNativePluginExecuting,
        configuration: [String: JSONValue] = [:]
    ) {
        self.package = package
        self.metadata = metadata
        self.executor = executor
        self.configuration = configuration
    }

    var descriptor: TranslationServiceDescriptor {
        TranslationServiceDescriptor(
            id: "plugin:\(metadata.id)",
            displayName: metadata.displayName,
            kind: .plugin,
            version: metadata.packageVersion,
            availability: metadata.isEnabled && metadata.approvalStatus == .approved
                ? .available
                : .disabled,
            supportsStreaming: package.manifest.schemaVersion < 3,
            supportedSourceLanguages:
                package.manifest.translation?.supportedSourceLanguages ?? [],
            supportedTargetLanguages:
                package.manifest.translation?.supportedTargetLanguages ?? []
        )
    }

    var requiresExplicitSourceLanguage: Bool {
        package.manifest.translationRequiresExplicitSourceLanguage
    }

    var acceptedInputs: Set<TranslationSourceAcceptedInput> {
        Set(package.manifest.effectiveTranslationAcceptedInputs)
    }

    func translate(
        _ request: TranslationServiceRequest
    ) -> AsyncThrowingStream<TranslationServiceEvent, Error> {
        let package = package
        let metadata = metadata
        let executor = executor
        let configuration = configuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let inputTask = Task.detached(
                        priority: .userInitiated
                    ) {
                        try Task.checkCancellation()
                        return try Self.invocationInput(
                            request,
                            manifest: package.manifest,
                            approvedPermissions:
                                Set(metadata.approvedPermissions)
                        )
                    }
                    let invocationInput =
                        try await withTaskCancellationHandler {
                            try await inputTask.value
                        } onCancel: {
                            inputTask.cancel()
                        }
                    try Task.checkCancellation()
                    let invocation = BlocksNativePluginInvocation(
                        requestID: request.invocation.id,
                        pluginID: metadata.id,
                        kind: .translation,
                        input: invocationInput,
                        configuration: configuration.merging(
                            [
                                "session_id":
                                    .string(request.sessionID),
                            ]
                        ) { persisted, _ in persisted }
                    )
                    let output = try await executor.execute(
                        package: package,
                        metadata: metadata,
                        invocation: invocation,
                        progress: { progress in
                            switch progress.kind {
                            case .partialText:
                                guard package.manifest.schemaVersion < 3,
                                      let text = progress.text,
                                      !text.isEmpty else {
                                    return
                                }
                                continuation.yield(.partial(text))
                            case .status:
                                guard let code = progress.code else {
                                    return
                                }
                                continuation.yield(
                                    .source(
                                        .status(
                                            TranslationSourceStatus(
                                                code: code,
                                                message: progress.text,
                                                fraction: progress.fraction
                                            )
                                        )
                                    )
                                )
                            case .diagnostics:
                                guard let code = progress.code else {
                                    return
                                }
                                continuation.yield(
                                    .source(
                                        .diagnostics(
                                            TranslationSourceDiagnostics(
                                                code: code,
                                                message: progress.text,
                                                metadata:
                                                    progress.metadata
                                            )
                                        )
                                    )
                                )
                            case .progress:
                                break
                            }
                        }
                    )
                    try Task.checkCancellation()
                    switch output.status {
                    case .completed:
                        let text = output.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        guard !text.isEmpty else {
                            throw TranslationServiceAdapterError.failed(
                                code: "plugin_empty_output",
                                message: L10n.string(
                                    "translation.error.pluginEmptyOutput"
                                )
                            )
                        }
                        continuation.yield(
                            .source(
                                .completed(
                                    TranslationSourceOutput(
                                        text: text,
                                        detectedSourceLanguage:
                                            Self.detectedLanguage(
                                                output.metadata[
                                                    "detected_source_language"
                                                ]
                                            ),
                                        warnings: Self.stringArray(
                                            output.metadata["warnings"]
                                        ),
                                        metadata: output.metadata
                                    )
                                )
                            )
                        )
                    case .failed:
                        continuation.yield(
                            .source(
                                .failed(
                                    TranslationSourceFailure(
                                        code:
                                            output.errorCode
                                            ?? "plugin_execution_failed",
                                        message:
                                            output.errorMessage
                                            ?? L10n.string(
                                                "translation.error.pluginFailed"
                                            ),
                                        isRetryable:
                                            output.isRetryable
                                    )
                                )
                            )
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as BlocksNativePluginExecutionError {
                    continuation.finish(
                        throwing: TranslationServiceAdapterError.failed(
                            code: TranslationPluginServiceErrorMapper.code(
                                for: error
                            ),
                            message: error.localizedDescription
                        )
                    )
                } catch {
                    continuation.finish(
                        throwing: TranslationServiceAdapterError.failed(
                            code: "plugin_execution_failed",
                            message: String(error.localizedDescription.prefix(512))
                        )
                    )
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated static func invocationInput(
        _ request: TranslationServiceRequest,
        manifest: BlocksNativePluginManifest,
        approvedPermissions: Set<String>
    ) throws -> [String: JSONValue] {
        let sourceLanguage: JSONValue = request.direction.source
            .map { .string($0.rawValue) }
            ?? .null
        guard manifest.schemaVersion >= 3 else {
            return [
                "text": .string(request.input.text),
                "source_language": sourceLanguage,
                "target_language":
                    .string(request.direction.target.rawValue),
                "input_source":
                    .string(request.input.source.rawValue),
            ]
        }

        let accepted = Set(
            manifest.effectiveTranslationAcceptedInputs
        )
        let contextFields = Set(
            manifest.effectiveTranslationContextFields
        )
        var input: [String: JSONValue] = [
            "source_language": sourceLanguage,
            "target_language":
                .string(request.direction.target.rawValue),
        ]
        if accepted.contains(.text) {
            input["text"] = .string(request.input.text)
        }

        var context: [String: JSONValue] = [:]
        if contextFields.contains(.inputSource) {
            context["input_source"] =
                .string(request.invocation.context.inputSource.rawValue)
        }
        if contextFields.contains(.sourceApplicationBundleID),
           let bundleID =
                request.invocation.context.sourceApplicationBundleID {
            context["source_application_bundle_id"] =
                .string(bundleID)
        }
        if contextFields.contains(.ocrSummary),
           let summary = request.invocation.context.ocrSummary {
            context["ocr_summary"] = .object([
                "line_count": .int(summary.lineCount),
            ])
        }
        if !context.isEmpty {
            input["context"] = .object(context)
        }

        if accepted.contains(.screenshotImage) {
            guard manifest.permissions.data.contains(
                .screenshotImage
            ),
            approvedPermissions.contains(
                "data:\(BlocksNativePluginDataPermission.screenshotImage.rawValue)"
            ) else {
                throw TranslationServiceAdapterError
                    .invalidConfiguration(
                        code: "plugin_data_permission_missing",
                        message: L10n.string(
                            "translation.error.pluginFailed"
                        )
                    )
            }
            let attachments = try request.attachments.compactMap {
                payload -> JSONValue? in
                guard payload.descriptor.kind == .screenshotImage else {
                    return nil
                }
                try validateScreenshotAttachment(payload)
                return .object([
                    "id": .string(payload.descriptor.id),
                    "kind":
                        .string(payload.descriptor.kind.rawValue),
                    "media_type":
                        .string(payload.descriptor.mediaType),
                    "byte_count":
                        .int(payload.descriptor.byteCount),
                    "pixel_width":
                        payload.descriptor.pixelWidth
                            .map(JSONValue.int) ?? .null,
                    "pixel_height":
                        payload.descriptor.pixelHeight
                            .map(JSONValue.int) ?? .null,
                    "sha256":
                        payload.descriptor.sha256
                            .map(JSONValue.string) ?? .null,
                    "data_base64":
                        .string(
                            payload.base64EncodedData
                                ?? payload.data.base64EncodedString()
                        ),
                ])
            }
            if !attachments.isEmpty {
                input["attachments"] = .array(attachments)
            }
        }

        let hasText = accepted.contains(.text)
            && !request.input.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        let hasAttachment: Bool
        if case let .array(values) = input["attachments"] {
            hasAttachment = !values.isEmpty
        } else {
            hasAttachment = false
        }
        guard hasText || hasAttachment else {
            throw TranslationServiceAdapterError.failed(
                code: "plugin_input_unavailable",
                message: L10n.string(
                    "translation.error.pluginFailed"
                )
            )
        }
        return input
    }

    nonisolated private static func validateScreenshotAttachment(
        _ payload: TranslationSourceAttachmentPayload
    ) throws {
        let descriptor = payload.descriptor
        guard descriptor.byteCount == payload.data.count,
              descriptor.byteCount > 0,
              descriptor.byteCount
                <= TranslationPluginImageEncoder
                    .maximumEncodedImageBytes,
              descriptor.mediaType == "image/jpeg",
              let width = descriptor.pixelWidth,
              let height = descriptor.pixelHeight,
              width > 0,
              height > 0,
              max(width, height)
                <= TranslationPluginImageEncoder
                    .maximumImageDimension else {
            throw TranslationServiceAdapterError.failed(
                code: "plugin_translation_image_invalid",
                message: L10n.string(
                    "translation.error.pluginOCRImageEncodingFailed"
                )
            )
        }
    }

    private static func detectedLanguage(
        _ value: JSONValue?
    ) -> TranslationLanguageTag? {
        guard case let .some(.string(rawValue)) = value else {
            return nil
        }
        return TranslationLanguageTag(rawValue)
    }

    private static func stringArray(
        _ value: JSONValue?
    ) -> [String] {
        guard case let .some(.array(values)) = value else {
            return []
        }
        var result: [String] = []
        var remainingCharacters = 4_096
        for value in values.prefix(32) {
            guard case let .string(rawValue) = value else { continue }
            let normalized = rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty,
                  remainingCharacters > 0 else {
                continue
            }
            let bounded = String(
                normalized.prefix(min(512, remainingCharacters))
            )
            result.append(bounded)
            remainingCharacters -= bounded.count
        }
        return result
    }

}

enum TranslationPluginImageEncoder {
    static let maximumEncodedImageBytes =
        TranslationSourceImageEncoder.maximumEncodedImageBytes
    static let maximumImageDimension =
        TranslationSourceImageEncoder.maximumImageDimension

    struct EncodedImage: Sendable {
        let data: Data
        let mediaType: String
        let pixelWidth: Int
        let pixelHeight: Int
        let base64EncodedData: String
    }

    static func encode(_ source: CGImage) throws -> EncodedImage {
        do {
            let encoded = try TranslationSourceImageEncoder
                .encode(source)
            return EncodedImage(
                data: encoded.data,
                mediaType: encoded.mediaType,
                pixelWidth: encoded.pixelWidth,
                pixelHeight: encoded.pixelHeight,
                base64EncodedData:
                    encoded.data.base64EncodedString()
            )
        } catch {
            throw TranslationServiceAdapterError.failed(
                code: "plugin_ocr_image_encoding_failed",
                message: L10n.string(
                    "translation.error.pluginOCRImageEncodingFailed"
                )
            )
        }
    }
}

extension TranslationSourceAttachmentPayload {
    static func screenshotImage(
        from capture: TranslationScreenshotCapture
    ) async throws -> TranslationSourceAttachmentPayload {
        let encodeTask = Task.detached(
            priority: .userInitiated
        ) {
            try Task.checkCancellation()
            return try TranslationPluginImageEncoder.encode(
                capture.cgImage
            )
        }
        let encoded = try await withTaskCancellationHandler {
            let value = try await encodeTask.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            encodeTask.cancel()
        }
        return TranslationSourceAttachmentPayload(
            descriptor: TranslationSourceAttachmentDescriptor(
                kind: .screenshotImage,
                mediaType: encoded.mediaType,
                byteCount: encoded.data.count,
                pixelWidth: encoded.pixelWidth,
                pixelHeight: encoded.pixelHeight,
                sha256: TranslationAttachmentDigest.sha256Hex(
                    encoded.data
                )
            ),
            data: encoded.data,
            base64EncodedData: encoded.base64EncodedData
        )
    }
}

final class PluginOCRServiceAdapter:
    TranslationScreenshotOCRProviding,
    @unchecked Sendable
{
    let pluginID: String
    let displayName: String

    private let package: BlocksNativePluginValidatedPackage
    private let metadata: BlocksNativePluginMetadata
    private let executor: any BlocksNativePluginExecuting
    private let configuration: [String: JSONValue]

    init(
        package: BlocksNativePluginValidatedPackage,
        metadata: BlocksNativePluginMetadata,
        executor: any BlocksNativePluginExecuting,
        configuration: [String: JSONValue] = [:]
    ) {
        pluginID = metadata.id
        displayName = metadata.displayName
        self.package = package
        self.metadata = metadata
        self.executor = executor
        self.configuration = configuration
    }

    func recognizeText(
        in capture: TranslationScreenshotCapture,
        requestToken: LocalVisionOCRRequestToken
    ) async throws -> TranslationScreenshotOCRSnapshot {
        try requestToken.checkCancellation()
        if package.manifest.schemaVersion >= 3 {
            let screenshotPermission =
                "data:\(BlocksNativePluginDataPermission.screenshotImage.rawValue)"
            guard package.manifest.permissions.data.contains(
                .screenshotImage
            ),
            metadata.approvedPermissions.contains(
                screenshotPermission
            ) else {
                throw TranslationServiceAdapterError
                    .invalidConfiguration(
                        code: "plugin_data_permission_missing",
                        message: L10n.string(
                            "translation.error.pluginFailed"
                        )
                    )
            }
        }
        let task = Task {
            let encoded = try await Task.detached(priority: .userInitiated) {
                try TranslationPluginImageEncoder.encode(
                    capture.cgImage
                )
            }.value
            try Task.checkCancellation()
            try requestToken.checkCancellation()
            let invocation = BlocksNativePluginInvocation(
                pluginID: metadata.id,
                kind: .ocr,
                input: [
                    "image_base64":
                        .string(encoded.base64EncodedData),
                    "media_type": .string(encoded.mediaType),
                    "pixel_width": .int(encoded.pixelWidth),
                    "pixel_height": .int(encoded.pixelHeight),
                ],
                configuration: configuration
            )
            let output = try await executor.execute(
                package: package,
                metadata: metadata,
                invocation: invocation,
                progress: { _ in }
            )
            try Task.checkCancellation()
            try requestToken.checkCancellation()
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw TranslationServiceAdapterError.failed(
                    code: "plugin_ocr_empty_output",
                    message: L10n.string("translation.screenshot.noText")
                )
            }
            return TranslationScreenshotOCRSnapshot(
                text: text,
                lineCount: Self.intMetadata(
                    output.metadata["line_count"],
                    fallback: max(1, text.split(separator: "\n").count)
                ),
                meanConfidence: Self.floatMetadata(
                    output.metadata["mean_confidence"],
                    fallback: 1
                )
            )
        }
        let cancellationRegistration = requestToken.addCancellationHandler {
            task.cancel()
        }
        defer {
            if let cancellationRegistration {
                requestToken.removeCancellationHandler(cancellationRegistration)
            }
        }
        do {
            return try await task.value
        } catch let error as BlocksNativePluginExecutionError {
            throw TranslationServiceAdapterError.failed(
                code: TranslationPluginServiceErrorMapper.code(for: error),
                message: error.localizedDescription
            )
        }
    }

    private static func intMetadata(
        _ value: JSONValue?,
        fallback: Int
    ) -> Int {
        if case let .some(.int(value)) = value {
            return max(0, value)
        }
        return fallback
    }

    private static func floatMetadata(
        _ value: JSONValue?,
        fallback: Float
    ) -> Float {
        switch value {
        case let .some(.double(value)):
            return Float(min(max(value, 0), 1))
        case let .some(.int(value)):
            return Float(min(max(value, 0), 1))
        default:
            return fallback
        }
    }
}

enum TranslationPluginServiceErrorMapper {
    static func code(
        for error: BlocksNativePluginExecutionError
    ) -> String {
        switch error {
        case .runnerUnavailable:
            return "plugin_runner_unavailable"
        case .pluginNotApproved:
            return "plugin_not_approved"
        case .pluginDisabled:
            return "plugin_disabled"
        case .packageHashMismatch:
            return "plugin_package_changed"
        case .capabilityUnavailable:
            return "plugin_capability_unavailable"
        case let .executionFailed(code, _):
            return code
        }
    }
}
