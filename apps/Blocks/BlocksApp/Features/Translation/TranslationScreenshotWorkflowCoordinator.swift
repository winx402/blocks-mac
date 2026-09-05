import AppKit
import BlocksCore
import Foundation
import OSLog

@MainActor
protocol TranslationScreenshotWorkflowDelegate: AnyObject {
    func translationScreenshotWorkflowPresent(
        _ model: TranslationPanelSessionModel
    )
    func translationScreenshotWorkflowPresenter(
        for modelID: UUID
    ) -> TranslationPanelPresenter?
    func translationScreenshotWorkflowPresentFailure(
        _ status: AppStatus,
        anchor: TranslationInputAnchor?,
        deduplicationKey: String
    )
}

/// Owns screenshot-translation capture, retake, and OCR lifecycles. Panel
/// composition remains in `TranslationFeatureCoordinator`.
@MainActor
final class TranslationScreenshotWorkflowCoordinator {
    typealias AttachmentEncoder = @Sendable (
        TranslationScreenshotCapture
    ) async throws -> TranslationSourceAttachmentPayload

    private static let logger = Logger(
        subsystem: "app.blocks.app",
        category: "TranslationScreenshotAttachment"
    )

    weak var delegate: TranslationScreenshotWorkflowDelegate?

    private let translationStore: TranslationStore
    private let captureProvider:
        any TranslationScreenshotCaptureProviding
    private let localOCRProvider:
        any TranslationScreenshotOCRProviding
    private let attachmentEncoder: AttachmentEncoder
    private var ocrProvider:
        (any TranslationScreenshotOCRProviding)?
    private let ocrRegistry = TranslationOCRExecutionRegistry()
    private var retakeExecutionIDs: [UUID: UUID] = [:]
    private var retakeCaptureIDs: [UUID: UUID] = [:]
    private var activeCaptureID: UUID?

    init(
        translationStore: TranslationStore,
        captureProvider:
            any TranslationScreenshotCaptureProviding,
        ocrProvider:
            any TranslationScreenshotOCRProviding,
        usesExplicitOCRProvider: Bool,
        attachmentEncoder: AttachmentEncoder? = nil
    ) {
        self.translationStore = translationStore
        self.captureProvider = captureProvider
        localOCRProvider = ocrProvider
        self.attachmentEncoder = attachmentEncoder ?? {
            try await TranslationSourceAttachmentPayload
                .screenshotImage(from: $0)
        }
        self.ocrProvider = usesExplicitOCRProvider
            || !TranslationOCRServicePreference.prefersPlugin
            ? ocrProvider
            : nil
    }

    func setOCRProvider(
        _ provider: (any TranslationScreenshotOCRProviding)?
    ) {
        let interruptedModels = ocrRegistry.cancelAll()
        for model in interruptedModels {
            model.updateOCRFailure(
                code: "ocr_service_changed",
                message: L10n.string(
                    "translation.screenshot.ocrServiceChanged"
                )
            )
        }
        ocrProvider = provider
            ?? (
                TranslationOCRServicePreference.prefersPlugin
                    ? nil
                    : localOCRProvider
            )
    }

    func cancelAll() {
        ocrRegistry.cancelAll()
        cancelCapture()
    }

    func cancelCapture() {
        guard activeCaptureID != nil else { return }
        activeCaptureID = nil
        captureProvider.cancelCurrentCapture()
    }

    func cancelOCR(modelID: UUID) {
        ocrRegistry.cancel(modelID: modelID)
    }

    func cancelRetake(modelID: UUID) {
        guard retakeExecutionIDs.removeValue(forKey: modelID) != nil else {
            return
        }
        guard let captureID = retakeCaptureIDs.removeValue(forKey: modelID),
              activeCaptureID == captureID else {
            return
        }
        activeCaptureID = nil
        captureProvider.cancelCurrentCapture()
    }

    func captureAndPresent(
        shouldContinue: @escaping @MainActor () -> Bool
    ) async {
        let captureID = beginCapture()
        defer { finishCapture(captureID) }
        do {
            let capture = try await captureProvider.captureRegion()
            guard !Task.isCancelled,
                  activeCaptureID == captureID,
                  shouldContinue() else {
                return
            }
            let input = TranslationInput(
                source: .screenshotOCR,
                text: "",
                context: TranslationInputContext(
                    displayIdentifier:
                        capture.screen?.displayID.map(String.init),
                    anchor: TranslationInputAnchor(
                        screenRect: capture.logicalRect
                    )
                )
            )
            let model = TranslationPanelSessionModel(
                input: input,
                direction: TranslationLanguageDirection(
                    target:
                        TranslationLanguagePreferences.preferredTarget()
                ),
                translationStore: translationStore,
                usesAutomaticTarget: true,
                ocrState: .recognizing
            )
            delegate?.translationScreenshotWorkflowPresent(model)
            startOCR(capture: capture, model: model)
        } catch is CancellationError {
            return
        } catch {
            guard activeCaptureID == captureID,
                  shouldContinue() else {
                return
            }
            presentFailure(
                error,
                anchor: nil,
                deduplicationKey: "translation-screenshot-capture"
            )
        }
    }

    func retakeScreenshot(
        for model: TranslationPanelSessionModel
    ) async {
        guard retakeExecutionIDs[model.id] == nil else { return }
        let executionID = UUID()
        retakeExecutionIDs[model.id] = executionID
        defer {
            if retakeExecutionIDs[model.id] == executionID {
                retakeExecutionIDs.removeValue(forKey: model.id)
            }
        }

        let presenter =
            delegate?.translationScreenshotWorkflowPresenter(
                for: model.id
            )
        let suspension = presenter?.suspendForCapture()
        let captureID = beginCapture()
        retakeCaptureIDs[model.id] = captureID
        defer { finishCapture(captureID) }
        defer {
            if retakeCaptureIDs[model.id] == captureID {
                retakeCaptureIDs.removeValue(forKey: model.id)
            }
        }
        do {
            let capture = try await captureProvider.captureRegion()
            guard isCurrentRetake(
                model: model,
                presenter: presenter,
                executionID: executionID,
                captureID: captureID
            ) else {
                return
            }
            ocrRegistry.cancel(modelID: model.id)
            let context = TranslationInputContext(
                displayIdentifier:
                    capture.screen?.displayID.map(String.init),
                anchor: TranslationInputAnchor(
                    screenRect: capture.logicalRect
                )
            )
            model.beginScreenshotRetake(context: context)
            presenter?.resumeAfterCapture(
                suspension,
                anchor: context.anchor
            )
            startOCR(capture: capture, model: model)
        } catch is CancellationError {
            guard isCurrentRetake(
                model: model,
                presenter: presenter,
                executionID: executionID,
                captureID: captureID
            ) else {
                return
            }
            presenter?.resumeAfterCapture(suspension)
        } catch {
            guard isCurrentRetake(
                model: model,
                presenter: presenter,
                executionID: executionID,
                captureID: captureID
            ) else {
                return
            }
            presenter?.resumeAfterCapture(suspension)
            presentFailure(
                error,
                anchor: model.inputContext?.anchor,
                deduplicationKey: "translation-screenshot-retake"
            )
        }
    }

    private func isCurrentRetake(
        model: TranslationPanelSessionModel,
        presenter: TranslationPanelPresenter?,
        executionID: UUID,
        captureID: UUID
    ) -> Bool {
        guard retakeExecutionIDs[model.id] == executionID,
              retakeCaptureIDs[model.id] == captureID,
              activeCaptureID == captureID else {
            return false
        }
        guard let presenter else { return true }
        return delegate?.translationScreenshotWorkflowPresenter(
            for: model.id
        ) === presenter && presenter.model === model
    }

    private func beginCapture() -> UUID {
        if activeCaptureID != nil {
            captureProvider.cancelCurrentCapture()
        }
        let id = UUID()
        activeCaptureID = id
        return id
    }

    private func finishCapture(_ id: UUID) {
        guard activeCaptureID == id else { return }
        activeCaptureID = nil
    }

    func startOCR(
        capture: TranslationScreenshotCapture,
        model: TranslationPanelSessionModel
    ) {
        ocrRegistry.cancel(modelID: model.id)
        guard let resolvedOCRProvider = ocrProvider else {
            model.updateOCRFailure(
                code: "ocr_service_unavailable",
                message: L10n.string(
                    "translation.plugin.runtimeUnavailable"
                )
            )
            focusSourceEditorIfPresented(for: model)
            return
        }

        let executionID = UUID()
        let token = LocalVisionOCRRequestToken()
        let needsScreenshotAttachment =
            model.needsScreenshotAttachment
        let processingRevision = model.beginScreenshotProcessing(
            expectsAttachment: needsScreenshotAttachment
        )
        ocrRegistry.begin(
            modelID: model.id,
            executionID: executionID,
            token: token,
            model: model
        )
        let task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            async let recognition: Void = self.executeRecognition(
                provider: resolvedOCRProvider,
                capture: capture,
                model: model,
                executionID: executionID,
                token: token,
                revision: processingRevision.ocr
            )
            if needsScreenshotAttachment {
                async let attachment: Void = self.executeAttachmentEncoding(
                    capture: capture,
                    model: model,
                    executionID: executionID,
                    token: token,
                    revision: processingRevision.attachment
                )
                _ = await (recognition, attachment)
            } else {
                _ = await recognition
            }
            ocrRegistry.finish(
                modelID: model.id,
                executionID: executionID
            )
        }
        ocrRegistry.installTask(
            task,
            modelID: model.id,
            executionID: executionID
        )
    }

    private func executeRecognition(
        provider: any TranslationScreenshotOCRProviding,
        capture: TranslationScreenshotCapture,
        model: TranslationPanelSessionModel,
        executionID: UUID,
        token: LocalVisionOCRRequestToken,
        revision: UInt64
    ) async {
        do {
            let result = try await provider.recognizeText(
                in: capture,
                requestToken: token
            )
            guard ocrRegistry.isCurrent(
                modelID: model.id,
                executionID: executionID,
                token: token
            ) else {
                return
            }
            let normalized = result.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty else {
                model.updateOCRFailure(
                    code: "no_text",
                    message: L10n.string(
                        "translation.screenshot.noText"
                    ),
                    revision: revision
                )
                focusSourceEditorIfCurrent(
                    for: model,
                    executionID: executionID,
                    token: token
                )
                return
            }
            model.updateOCRResult(
                text: normalized,
                lineCount: result.lineCount,
                meanConfidence: result.meanConfidence,
                revision: revision
            )
            focusSourceEditorIfCurrent(
                for: model,
                executionID: executionID,
                token: token
            )
        } catch is CancellationError {
            return
        } catch {
            guard ocrRegistry.isCurrent(
                modelID: model.id,
                executionID: executionID,
                token: token
            ) else {
                return
            }
            model.updateOCRFailure(
                code: "ocr_failed",
                message:
                    TranslationErrorPresentation.message(for: error),
                revision: revision
            )
            focusSourceEditorIfCurrent(
                for: model,
                executionID: executionID,
                token: token
            )
        }
    }

    private func focusSourceEditorIfCurrent(
        for model: TranslationPanelSessionModel,
        executionID: UUID,
        token: LocalVisionOCRRequestToken
    ) {
        guard ocrRegistry.isCurrent(
            modelID: model.id,
            executionID: executionID,
            token: token
        ) else {
            return
        }
        focusSourceEditorIfPresented(for: model)
    }

    private func focusSourceEditorIfPresented(
        for model: TranslationPanelSessionModel
    ) {
        guard let presenter = delegate?
            .translationScreenshotWorkflowPresenter(for: model.id),
              presenter.isVisible else { return }
        presenter.focusSourceEditorIfPanelIsNotKey()
    }

    private func executeAttachmentEncoding(
        capture: TranslationScreenshotCapture,
        model: TranslationPanelSessionModel,
        executionID: UUID,
        token: LocalVisionOCRRequestToken,
        revision: UInt64
    ) async {
        do {
            let attachment = try await attachmentEncoder(capture)
            guard ocrRegistry.isCurrent(
                modelID: model.id,
                executionID: executionID,
                token: token
            ) else {
                return
            }
            model.installScreenshotAttachment(
                attachment,
                revision: revision
            )
        } catch is CancellationError {
            return
        } catch {
            guard ocrRegistry.isCurrent(
                modelID: model.id,
                executionID: executionID,
                token: token
            ) else {
                return
            }
            let code = "plugin_translation_image_invalid"
            let message = TranslationErrorPresentation.message(
                code: code,
                fallback: error.localizedDescription
            )
            Self.logger.error(
                "model=\(model.id.uuidString, privacy: .public) phase=encode_failed code=\(code, privacy: .public)"
            )
            model.updateScreenshotAttachmentFailure(
                code: code,
                message: message,
                revision: revision
            )
        }
    }

#if DEBUG
    var activeOCRSessionCountForTesting: Int {
        ocrRegistry.count
    }
#endif

    private func presentFailure(
        _ error: Error,
        anchor: TranslationInputAnchor?,
        deduplicationKey: String
    ) {
        delegate?.translationScreenshotWorkflowPresentFailure(
            AppStatus(
                kind: .failed,
                title: L10n.string(
                    "translation.screenshot.failed.title"
                ),
                detail:
                    TranslationErrorPresentation.message(for: error)
            ),
            anchor: anchor,
            deduplicationKey: deduplicationKey
        )
    }
}
