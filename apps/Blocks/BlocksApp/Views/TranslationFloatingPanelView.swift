import AppKit
import AVFoundation
import BlocksCore
import OSLog
import SwiftUI

enum TranslationPanelMetrics {
    static let minimumWidth: CGFloat = 420
    static let minimumHeight: CGFloat = 320
    static let passiveContentHeight: CGFloat = 124
    static let contentInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let compactIconHitTarget =
        BlocksVisualTokens.Control.compactHeight
    static let headerContentHeight = compactIconHitTarget
    static let headerVerticalPadding: CGFloat = 11
    static let headerTotalHeight =
        headerContentHeight + headerVerticalPadding * 2
    static let ocrStatusMinimumWidth: CGFloat = 72
    static let ocrStatusIdealWidth: CGFloat = 156
    static let sourceHeaderSpacing: CGFloat = 8
}

private struct TranslationPanelResultStateReader<Content: View>:
    View
{
    @ObservedObject var state: TranslationPanelResultState
    private let content:
        (TranslationResultSnapshot) -> Content

    init(
        state: TranslationPanelResultState,
        @ViewBuilder content:
            @escaping (TranslationResultSnapshot) -> Content
    ) {
        _state = ObservedObject(wrappedValue: state)
        self.content = content
    }

    var body: some View {
        content(state.result)
    }
}

struct TranslationFloatingPanelView: View {
    private static let automaticTargetTag = "__blocks_auto_target__"
    private static let selectionReadingNotificationKey =
        "translation.selection.reading"
    private static let selectionFailureNotificationKey =
        "translation.selection.failure"
    private static let operationErrorNotificationKey =
        "translation.operation.error"
    @ObservedObject var model: TranslationPanelSessionModel
    let actions: TranslationPanelActions
    @ObservedObject var notificationState:
        BlocksNotificationPresentationState
    var pluginManager: BlocksNativePluginManager?
    var pluginRuntime: BlocksPluginRuntimeCoordinator?
    @ObservedObject var resultOrderDragCoordinator:
        TranslationServiceOrderDragCoordinator
    let onExit: () -> Void
    let onClose: () -> Void

    @StateObject private var preparationController = AppleTranslationPreparationController()
    @StateObject private var speechController = TranslationSpeechController()
    @State private var collapsedServiceIDs: Set<String> = []
    @State private var sourceEditorFocused = false

    private var targetLanguageSections: TranslationLanguageMenuSections {
        TranslationLanguagePreferences.menuSections(
            available: model.supportedLanguages,
            current: model.targetLanguage
        )
    }

    private var sourceLanguageSections: TranslationLanguageMenuSections {
        TranslationLanguagePreferences.menuSections(
            available: model.supportedSourceLanguages,
            current: model.sourceLanguage
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .frame(
                    height: TranslationPanelMetrics.headerTotalHeight
                )

            Divider()

            translationContent
        }
        .frame(
            minWidth: TranslationPanelMetrics.minimumWidth,
            minHeight: TranslationPanelMetrics.minimumHeight
        )
        .background(BlocksWindowGlassConfigurator())
        .blocksSurface(
            .panel,
            cornerRadius: BlocksVisualTokens.CornerRadius.large
        )
        .background {
            ZStack {
                AppleTranslationPreparationHost(controller: preparationController)
                AppleTranslationRuntimeHost(controller: model.appleRuntimeController)
            }
        }
        .onAppear {
            model.beginSupportedLanguagesConsumer()
            if model.shouldRunOnPresentation {
                model.runImmediately()
            } else if model.inputSource == .manual {
                model.requestSourceFocus()
            }
        }
        .onExitCommand(perform: onExit)
        .onChange(of: model.runPhase) { _, phase in
            if let message = phase.accessibilityMessage {
                TranslationAccessibilityAnnouncer.announce(message)
            }
        }
        .onChange(of: model.selectionReadState, initial: true) {
            _, state in
            updateSelectionNotification(for: state)
        }
        .onChange(of: model.operationError, initial: true) {
            _, operationError in
            updateOperationErrorNotification(operationError)
        }
        .onChange(of: model.ocrState) { _, state in
            if let message = state.accessibilityMessage {
                TranslationAccessibilityAnnouncer.announce(message)
            }
        }
        .onChange(of: model.sourceText) { _, _ in
            speechController.stop()
        }
        .onChange(of: model.sourceLanguage) { _, _ in
            speechController.stop()
        }
        .onChange(of: model.targetLanguage) { _, _ in
            speechController.stop()
        }
        .onDisappear {
            model.endSupportedLanguagesConsumer()
            resultOrderDragCoordinator.endSession()
            preparationController.cancel()
            speechController.stop()
        }
    }

    private var translationContent: some View {
        TranslationPanelContentLayout(
            inputSource: model.inputSource,
            sourceContent: { editorHeight in
                sourceSection(editorHeight: editorHeight)
            },
            languageContent: {
                languageBar
            },
            resultsContent: {
                resultsSection
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Label(sourceTitle, systemImage: sourceSystemImage)
                    .font(.headline)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                BlocksPanelWindowDragArea(
                    height: TranslationPanelMetrics.headerContentHeight
                )
            }

            BlocksCompactActionGroup {
                if let pluginManager, let pluginRuntime {
                    BlocksPluginUISlotHost(
                        manager: pluginManager,
                        runtime: pluginRuntime,
                        slot: .translationPanelAction,
                        context: [
                            "session_id": .string(model.id.uuidString),
                            "input_source": .string(
                                model.inputSource.rawValue
                            ),
                        ]
                    )
                }

                BlocksCompactIconButton(
                    systemImage: isFavorite ? "star.fill" : "star",
                    label: favoriteActionTitle,
                    isEnabled: model.canFavorite,
                    isSelected: isFavorite
                ) {
                    if isFavorite {
                        actions.openFavorites()
                    } else {
                        Task {
                            presentFavoriteResult(await model.favorite())
                        }
                    }
                }
                .accessibilityIdentifier("translation.panel.favorite")
                .accessibilityValue(
                    L10n.string(
                        isFavorite
                            ? "translation.favorite.state.saved"
                            : "translation.favorite.state.notSaved"
                    )
                )

                BlocksCompactIconButton(
                    systemImage: model.isPinned ? "pin.fill" : "pin",
                    label: pinActionTitle,
                    isSelected: model.isPinned
                ) {
                    model.isPinned.toggle()
                }
                .accessibilityIdentifier("translation.panel.pin")
                .accessibilityValue(
                    L10n.string(
                        model.isPinned
                            ? "translation.panel.pin.state.pinned"
                            : "translation.panel.pin.state.unpinned"
                    )
                )

                BlocksCompactIconButton(
                    systemImage: "gearshape",
                    label: L10n.string("menu.settings")
                ) {
                    actions.openTranslationSettings()
                }

                BlocksCompactIconButton(
                    systemImage: "xmark",
                    label: L10n.string("common.close"),
                    emphasis: .destructive,
                    action: onClose
                )
                .accessibilityIdentifier("translation.panel.close")
            }
        }
        .frame(height: TranslationPanelMetrics.headerContentHeight)
    }

    private var isFavorite: Bool {
        model.isFavorite
    }

    private var favoriteActionTitle: String {
        L10n.string(
            isFavorite
                ? "translation.favorite.open"
                : "translation.favorite.action"
        )
    }

    private var pinActionTitle: String {
        L10n.string(
            model.isPinned
                ? "translation.panel.unpin"
                : "translation.panel.pin"
        )
    }

    private func sourceSection(editorHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(
                spacing: TranslationPanelMetrics.sourceHeaderSpacing
            ) {
                Text(L10n.string("translation.panel.source"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()

                if model.inputSource == .screenshotOCR {
                    ocrInlineStatus
                        .frame(
                            minWidth:
                                TranslationPanelMetrics
                                    .ocrStatusMinimumWidth,
                            idealWidth:
                                TranslationPanelMetrics
                                    .ocrStatusIdealWidth,
                            maxWidth:
                                TranslationPanelMetrics
                                    .ocrStatusIdealWidth,
                            alignment: .leading
                        )
                        .layoutPriority(0)
                }

                Spacer(minLength: 4)

                if model.inputSource == .screenshotOCR {
                    BlocksCompactIconButton(
                        systemImage: "viewfinder",
                        label: L10n.string(
                            "translation.screenshot.retake"
                        )
                    ) {
                        actions.retakeScreenshot()
                    }
                    .accessibilityIdentifier("translation.panel.retake")
                }

                if !model.sourceText.isEmpty {
                    Text(
                        TranslationLocalizedFormat.characterCount(
                            model.sourceText.count
                        )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            .frame(
                height:
                    TranslationPanelSourceLayout
                        .sourceHeaderHeight
            )

            ZStack(alignment: .topLeading) {
                TranslationSourceTextEditor(
                    text: model.sourceText,
                    focusRequest: model.sourceFocusRequest,
                    onTextChange: {
                        model.updateSourceTextFromUser($0)
                    },
                    onFocusChange: {
                        sourceEditorFocused = $0
                    }
                )
                    .frame(height: editorHeight)
                    .accessibilityLabel(
                        L10n.string("translation.panel.sourceEditor")
                    )
                    .accessibilityIdentifier(
                        "translation.panel.sourceEditor"
                    )

                if model.sourceText.isEmpty {
                    Text(L10n.string("translation.panel.emptyInput"))
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 13)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .blocksSurface(
                .interactive,
                cornerRadius: BlocksVisualTokens.CornerRadius.section,
                isActive: sourceEditorFocused
            )
            .blocksInteractionChrome(
                sourceEditorFocused ? .focused : .idle,
                cornerRadius: BlocksVisualTokens.CornerRadius.section
            )
        }
    }

    private func selectionFailureMessage(
        _ reason: AXSelectionReadFailureReason
    ) -> String {
        switch reason {
        case .accessibilityPermissionDenied:
            L10n.string("translation.selection.permission.detail")
        case .agentUnavailable:
            L10n.string("translation.selection.agentUnavailable")
        case .agentInstallationConflict:
            L10n.string("translation.selectionHelper.error.installationConflict")
        case .agentRequiresApproval:
            L10n.string("translation.selection.agentRequiresApproval")
        case .agentVersionOutdated:
            L10n.string("translation.selectionHelper.error.outdated")
        case .agentConnectionFailed:
            L10n.string("translation.selection.agentConnectionFailed")
        case .targetExited:
            L10n.string("translation.selection.targetExited")
        case .timedOut:
            L10n.string("translation.selection.timedOut")
        case .selectionTooLarge:
            L10n.string("translation.selection.selectionTooLarge")
        case .passwordField:
            L10n.string("translation.selection.password")
        case .cancelled:
            L10n.string("translation.selection.unavailable")
        case .noFrontmostApplication,
             .blocksIsFrontmost,
             .focusedElementUnavailable,
             .selectionUnavailable,
             .emptySelection:
            L10n.string("translation.selection.unavailable")
        }
    }

    private var languageBar: some View {
        HStack(spacing: 10) {
            Picker(
                L10n.string("translation.panel.sourceLanguage"),
                selection: Binding(
                    get: { model.sourceLanguage?.rawValue ?? "" },
                    set: {
                        model.updateSourceLanguage(
                            $0.isEmpty ? nil : TranslationLanguageTag($0)
                        )
                    }
                )
            ) {
                Text(L10n.string("language.auto")).tag("")
                if !sourceLanguageSections.common.isEmpty {
                    Section(
                        L10n.string("translation.language.common")
                    ) {
                        ForEach(
                            sourceLanguageSections.common,
                            id: \.rawValue
                        ) { language in
                            Text(
                                TranslationLanguagePreferences
                                    .localizedName(for: language)
                            )
                            .tag(language.rawValue)
                        }
                    }
                }
                if !sourceLanguageSections.all.isEmpty {
                    Section(L10n.string("translation.language.all")) {
                        ForEach(
                            sourceLanguageSections.all,
                            id: \.rawValue
                        ) { language in
                            Text(
                                TranslationLanguagePreferences
                                    .localizedName(for: language)
                            )
                            .tag(language.rawValue)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("translation.panel.sourceLanguage")

            BlocksCompactIconButton(
                systemImage: "arrow.left.arrow.right",
                label: L10n.string(
                    "translation.panel.swapLanguages"
                ),
                isEnabled: model.sourceLanguage != nil,
                density: .micro
            ) {
                model.swapLanguagesAndRun()
            }

            Picker(
                L10n.string("translation.panel.targetLanguage"),
                selection: Binding(
                    get: {
                        model.usesAutomaticTarget
                            ? Self.automaticTargetTag
                            : model.targetLanguage.rawValue
                    },
                    set: { value in
                        if value == Self.automaticTargetTag {
                            model.enableAutomaticTarget()
                            return
                        }
                        guard let target = TranslationLanguageTag(value) else { return }
                        model.updateTargetLanguage(target)
                    }
                )
            ) {
                Text(L10n.string("translation.language.automaticTarget"))
                    .tag(Self.automaticTargetTag)
                if !targetLanguageSections.common.isEmpty {
                    Section(
                        L10n.string("translation.language.common")
                    ) {
                        ForEach(
                            targetLanguageSections.common,
                            id: \.rawValue
                        ) { language in
                            Text(
                                TranslationLanguagePreferences
                                    .localizedName(for: language)
                            )
                            .tag(language.rawValue)
                        }
                    }
                }
                if !targetLanguageSections.all.isEmpty {
                    Section(L10n.string("translation.language.all")) {
                        ForEach(
                            targetLanguageSections.all,
                            id: \.rawValue
                        ) { language in
                            Text(
                                TranslationLanguagePreferences
                                    .localizedName(for: language)
                            )
                            .tag(language.rawValue)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("translation.panel.targetLanguage")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(height: TranslationPanelSourceLayout.languageBarHeight)
        .blocksSurface(
            .interactive,
            cornerRadius: BlocksVisualTokens.CornerRadius.control
        )
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let snapshot = model.snapshot,
           !model.resultStates.isEmpty {
            let resultStates = model.resultStates
            LazyVStack(spacing: BlocksVisualTokens.Spacing.sm) {
                ForEach(
                    Array(resultStates.enumerated()),
                    id: \.element.id
                ) { index, resultState in
                    TranslationPanelResultStateReader(
                        state: resultState
                    ) { result in
                        resultCard(
                            result,
                            index: index,
                            resultCount: resultStates.count,
                            snapshot: snapshot
                        )
                    }
                }
            }
        } else if model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BlocksStateView(
                kind: .empty,
                title: L10n.string("translation.panel.emptyInput"),
                detail: L10n.string(
                    "translation.panel.emptyInputDetail"
                )
            )
            .frame(
                maxWidth: .infinity,
                minHeight: TranslationPanelMetrics.passiveContentHeight
            )
        } else if model.runPhase == .debouncing {
            translationActivity(
                L10n.string("translation.status.debouncing")
            )
        } else if model.runPhase == .running {
            translationActivity(
                L10n.string("translation.status.running")
            )
        } else if model.runPhase == .noServices {
            BlocksStateView(
                kind: .information,
                title: L10n.string(
                    "translation.service.noneEnabled"
                ),
                detail: L10n.string(
                    "translation.service.noneEnabledDetail"
                ),
                actionTitle: L10n.string("menu.settings"),
                action: actions.openTranslationSettings
            )
            .frame(
                maxWidth: .infinity,
                minHeight: TranslationPanelMetrics.passiveContentHeight
            )
        } else {
            Color.clear
                .frame(
                    maxWidth: .infinity,
                    minHeight: TranslationPanelMetrics.passiveContentHeight
                )
        }
    }

    private func resultCard(
        _ result: TranslationResultSnapshot,
        index: Int,
        resultCount: Int,
        snapshot: TranslationSessionSnapshot
    ) -> some View {
        let recovery = TranslationResultRecoveryPolicy.resolve(
            errorCode: result.errorCode
        )
        let prepareLanguage: (() -> Void)?
        if recovery.shouldDownloadLanguage {
            prepareLanguage = {
                prepareAppleLanguage(
                    for: snapshot,
                    serviceID: result.service.id
                )
            }
        } else {
            prepareLanguage = nil
        }
        let openSettings: (() -> Void)?
        if recovery.shouldOpenSettings {
            openSettings = {
                actions.openTranslationSettings()
            }
        } else {
            openSettings = nil
        }

        return TranslationResultCard(
            result: result,
            isCollapsed: collapsedServiceIDs.contains(result.service.id),
            isSpeaking: speechController.isSpeaking(resultID: result.id),
            isPreparingLanguage:
                recovery.shouldDownloadLanguage
                    && preparationController.isPreparing,
            canRetry: result.isRetryable ?? recovery.canRetry,
            onToggleCollapsed: {
                if collapsedServiceIDs.contains(result.service.id) {
                    collapsedServiceIDs.remove(result.service.id)
                } else {
                    collapsedServiceIDs.insert(result.service.id)
                }
            },
            onCopy: {
                await copyResultText(result.translatedText)
            },
            onSpeak: {
                speechController.toggleSpeaking(
                    resultID: result.id,
                    text: result.translatedText,
                    language: snapshot.direction.target
                )
            },
            onRetry: {
                model.retry(serviceID: result.service.id)
            },
            onCancel: {
                speechController.stop()
                model.cancel(serviceID: result.service.id)
            },
            onPrepareAppleLanguage: prepareLanguage,
            onOpenSettings: openSettings,
            canMoveUp: index > 0,
            canMoveDown: index < resultCount - 1,
            onMoveUp: {
                model.moveResultServiceUp(result.service.id)
            },
            onMoveDown: {
                model.moveResultServiceDown(result.service.id)
            },
            onPerformDrop: { target in
                model.moveResultService(
                    serviceID: target.sourceServiceID,
                    relativeTo: target.destinationServiceID,
                    placement: target.placement
                )
            },
            dragCoordinator: resultOrderDragCoordinator,
            activeDropPlacement:
                resultOrderDragCoordinator.target?
                    .destinationServiceID
                    == result.service.id
                    ? resultOrderDragCoordinator.target?.placement
                    : nil,
            isBeingDragged:
                resultOrderDragCoordinator.activeServiceID
                    == result.service.id,
            pluginDetail: translationPluginResultDetail(result)
        )
    }

    private func translationPluginResultDetail(
        _ result: TranslationResultSnapshot
    ) -> AnyView? {
        guard let pluginManager, let pluginRuntime else { return nil }
        return AnyView(
            BlocksPluginUISlotHost(
                manager: pluginManager,
                runtime: pluginRuntime,
                slot: .translationResultDetail,
                context: [
                    "session_id": .string(model.id.uuidString),
                    "service_id": .string(result.service.id),
                    "state": .string(result.state.rawValue),
                ],
                protectedContext: [
                    "source_text": .string(model.sourceText),
                    "translated_text": .string(result.translatedText),
                ],
                requiredDataPermission: .translationContent
            )
        )
    }

    @MainActor
    private func copyResultText(_ text: String) async -> Bool {
        let outcome = await actions.copyText(text)
        switch outcome {
        case .copiedAndRecorded:
            return true
        case .copiedWithoutHistory:
            notificationState.present(
                BlocksNotificationDescriptor(
                    level: .warning,
                    title: L10n.string(
                        "translation.notification.copiedHistoryUnavailable"
                    )
                )
            )
            return true
        case .failed:
            notificationState.present(
                BlocksNotificationDescriptor(
                    level: .error,
                    title: L10n.string(
                        "translation.notification.copyFailed"
                    )
                )
            )
            return false
        }
    }

    private func translationActivity(_ title: String) -> some View {
        BlocksStateView(kind: .loading, title: title)
        .frame(
            maxWidth: .infinity,
            minHeight: TranslationPanelMetrics.passiveContentHeight
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var ocrInlineStatus: some View {
        switch model.ocrState {
        case .notApplicable:
            Color.clear
                .frame(height: TranslationPanelMetrics.compactIconHitTarget)
                .accessibilityHidden(true)
        case .recognizing:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("translation.screenshot.recognizing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        case let .recognized(lineCount, _):
            let summary = TranslationLocalizedFormat.ocrLines(lineCount)
            Label(
                summary,
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(summary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
        case let .failed(_, message):
            Label(
                message,
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
            .accessibilityLabel(message)
        }
    }

    private var sourceTitle: String {
        switch model.inputSource {
        case .manual:
            L10n.string("translation.source.manual")
        case .selection:
            L10n.string("translation.source.selection")
        case .screenshotOCR:
            L10n.string("translation.source.screenshot")
        case .clipboardRecord:
            L10n.string("translation.source.clipboard")
        }
    }

    private var sourceSystemImage: String {
        switch model.inputSource {
        case .manual: "text.cursor"
        case .selection: "selection.pin.in.out"
        case .screenshotOCR: "viewfinder"
        case .clipboardRecord: "doc.on.clipboard"
        }
    }

    private func prepareAppleLanguage(
        for snapshot: TranslationSessionSnapshot,
        serviceID: String
    ) {
        preparationController.prepare(
            input: snapshot.input,
            direction: snapshot.direction
        ) { result in
            guard model.snapshot?.id == snapshot.id else {
                return
            }
            switch result {
            case .success:
                model.retry(serviceID: serviceID)
            case let .failure(error) where error is CancellationError:
                return
            case let .failure(error):
                Logger(
                    subsystem: "app.blocks.app",
                    category: "TranslationPanel"
                ).error(
                    "Apple language preparation failed: \(String(describing: error), privacy: .public)"
                )
                notificationState.present(
                    BlocksNotificationDescriptor(
                        level: .error,
                        title:
                            TranslationErrorPresentation.notificationTitle(
                                for: error
                            ),
                        detail: TranslationErrorPresentation.message(for: error)
                    )
                )
            }
        }
    }

    private func presentFavoriteResult(_ succeeded: Bool) {
        notificationState.present(
            BlocksNotificationDescriptor(
                level: succeeded ? .success : .error,
                title: L10n.string(
                    succeeded
                        ? "translation.notification.favorited"
                        : "translation.notification.favoriteFailed"
                ),
                detail: succeeded ? nil : model.operationError,
                presentationStyle:
                    succeeded ? .compactConfirmation : .standard,
                systemImage: succeeded ? "star.fill" : nil
            )
        )
    }

    private func updateSelectionNotification(
        for state: TranslationSelectionReadState
    ) {
        switch state {
        case .reading:
            notificationState.dismiss(
                deduplicationKey:
                    Self.selectionFailureNotificationKey
            )
            notificationState.present(
                BlocksNotificationDescriptor(
                    level: .info,
                    title: L10n.string(
                        "translation.selection.reading"
                    ),
                    showsIndeterminateProgress: true,
                    dismissPolicy: .manual,
                    deduplicationKey:
                        Self.selectionReadingNotificationKey
                )
            )
        case .notApplicable, .selected:
            notificationState.dismiss(
                deduplicationKey:
                    Self.selectionReadingNotificationKey
            )
            notificationState.dismiss(
                deduplicationKey:
                    Self.selectionFailureNotificationKey
            )
        case let .unavailable(reason):
            notificationState.dismiss(
                deduplicationKey:
                    Self.selectionReadingNotificationKey
            )
            if TranslationSelectionFailurePresentation
                .isSilentManualInput(reason) {
                notificationState.dismiss(
                    deduplicationKey:
                        Self.selectionFailureNotificationKey
                )
            } else {
                notificationState.present(
                    BlocksNotificationDescriptor(
                        level: .warning,
                        title: L10n.string(
                            "translation.panel.operationFailed"
                        ),
                        detail: selectionFailureMessage(reason),
                        deduplicationKey:
                            Self.selectionFailureNotificationKey
                    )
                )
            }
        }
    }

    private func updateOperationErrorNotification(
        _ operationError: String?
    ) {
        guard let operationError,
              !operationError.isEmpty else {
            notificationState.dismiss(
                deduplicationKey:
                    Self.operationErrorNotificationKey
            )
            return
        }
        notificationState.present(
            BlocksNotificationDescriptor(
                level: .warning,
                title: L10n.string(
                    "translation.panel.operationFailed"
                ),
                detail: operationError,
                deduplicationKey:
                    Self.operationErrorNotificationKey
            )
        )
    }

}
