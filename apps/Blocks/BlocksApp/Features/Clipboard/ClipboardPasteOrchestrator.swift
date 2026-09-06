import AppKit
import BlocksCore

struct ClipboardPluginContentEventInput {
    let payload: [String: JSONValue]
    let resources: [BlocksPluginResourceReference]
    let resourceStagingFailed: Bool
}

enum ClipboardPluginEventContract {
    static func contentInput(
        record: ClipboardRecorderRecord,
        payload sourcePayload: ClipboardRecorderPayload?,
        stageTextResource: @Sendable (
            String,
            BlocksPluginResourceKind,
            String?,
            [String: JSONValue]
        ) async -> BlocksPluginResourceReference?
    ) async -> ClipboardPluginContentEventInput {
        var payload: [String: JSONValue] = [
            "record_id": .string(record.id),
            "kind": .string(record.kind.rawValue),
            "signature": .string(record.signatureSHA256_12),
            "source_bundle_id": .string(
                record.sourceApp?.bundleIdentifier ?? ""
            ),
            "created_at": .double(record.createdAt.timeIntervalSince1970),
        ]
        guard let sourcePayload else {
            return .init(payload: payload, resources: [], resourceStagingFailed: false)
        }
        let text = sourcePayload.text ?? sourcePayload.urlString
        guard let text else {
            return .init(payload: payload, resources: [], resourceStagingFailed: false)
        }

        var references: [BlocksPluginResourceReference] = []
        var stagedByteCount: Int64?
        if let reference = await stageTextResource(
            text,
            .text,
            "text/plain; charset=utf-8",
            [
                "record_id": .string(record.id),
                "encoding": .string("utf-8"),
            ]
        ) {
            references.append(reference)
            stagedByteCount = reference.byteCount
            payload["content_resource_id"] = .string(reference.id)
            payload["content_byte_count"] = .int(Int(reference.byteCount ?? 0))
        } else {
            return .init(payload: payload, resources: [], resourceStagingFailed: true)
        }
        // Small text remains directly mutable. Large text is never truncated:
        // plugins read the complete value through the cancellable resource.
        if let stagedByteCount, stagedByteCount <= 256 * 1_024 {
            payload["text"] = .string(text)
            payload["plain_text"] = .string(text)
        }
        return .init(
            payload: payload,
            resources: references,
            resourceStagingFailed: false
        )
    }
}

extension ClipboardFeatureCoordinator {
    /// A permission refresh is not a new paste gesture. Never replay an old
    /// target after the user has visited System Settings or another window.
    func pastePermissionStateDidRefresh(requestToken: UUID? = nil) {
        guard autoPasteCoordinator.hasEventPostingAccess,
              let pending = pendingPasteRequest,
              requestToken == nil || requestToken == pending.token else { return }
        pendingPasteRequest = nil
        notificationCoordinator.presentationState.dismiss(deduplicationKey: "clipboard.paste.permission")
        recordStatus(
            .ready,
            title: "status.clipboardPastePermissionReady.title",
            detail: L10n.string("status.clipboardPastePermissionReady.detail")
        )
    }

    // Retained for an explicitly requested retry; permission observers must
    // only call pastePermissionStateDidRefresh instead.
    func retryPendingPasteIfPossible() {
        retryPendingPasteIfPossible(requestToken: pendingPasteRequest?.token)
    }

    private func retryPendingPasteIfPossible(requestToken: UUID?) {
        guard autoPasteCoordinator.hasEventPostingAccess, let request = pendingPasteRequest,
              requestToken == nil || request.token == requestToken else {
            return
        }
        guard pastePluginLifecycleIsCurrent(request) else {
            pendingPasteRequest = nil
            return
        }
        pendingPasteRequest = nil
        guard clipboardStore.resolveRecord(recordID: request.recordID) != nil else {
            recordNotFoundStatus()
            return
        }
        let retryRequest = request.retryingAfterAccessibilityGrant()
        startPaste(retryRequest)
    }

    func makePendingPasteRequest(
        recordID: String,
        targetContext: ClipboardPasteTargetContext?,
        panelInvocationID: UUID? = nil,
        promptForAccessibility: Bool,
        copyEventSource: ClipboardCopyEventSource = .panelPaste,
        invocationOrigin: BlocksPluginHostInvocationOrigin = .explicitUser,
        pluginLifecycleToken:
            BlocksPluginRuntimeCoordinator.HostActionLifecycleToken? = nil,
        pluginLifecycleLeaseProvider: @escaping @MainActor () ->
            BlocksPluginHostOperationAdmissionGate.Lease? = { nil },
        pluginLifecycleIsCurrent: @escaping @MainActor (
            BlocksPluginRuntimeCoordinator.HostActionLifecycleToken
        ) -> Bool = { _ in true }
    ) -> PendingPasteRequest {
        return PendingPasteRequest(
            recordID: recordID,
            copyEventSource: copyEventSource,
            invocationOrigin: invocationOrigin,
            pluginLifecycleToken: pluginLifecycleToken,
            pluginLifecycleLeaseProvider: pluginLifecycleLeaseProvider,
            pluginLifecycleIsCurrent: pluginLifecycleIsCurrent,
            targetContext: targetContext,
            panelInvocationID: panelInvocationID,
            promptForAccessibility: promptForAccessibility,
            token: UUID(),
            // The passive observer is deliberately sampled and can lag behind
            // the system pasteboard. Acquire the CAS baseline from the Broker
            // when this transaction actually starts instead of freezing the
            // observer's cached changeCount here.
            expectedPasteboardChangeCount: nil,
            preparedWriteLease: nil,
            historySyncPending: false
        )
    }

    func startPaste(_ request: PendingPasteRequest) {
        guard request.invocationOrigin.userInitiated,
              pastePluginLifecycleIsCurrent(request) else { return }
        pasteTask?.cancel()
        pendingPasteRequest = nil
        activePasteRequest = request
        let generation = pasteTransactionState.begin(token: request.token)
        Self.transactionLogger.info(
            "stage=request-start generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) source=\(request.copyEventSource.rawValue, privacy: .public) expectedChangeCount=\(request.expectedPasteboardChangeCount ?? -1) preparedWriteChangeCount=\(request.preparedWriteLease?.changeCount ?? -1) preparedBrokerGeneration=\(request.preparedWriteLease?.brokerGeneration ?? 0) targetPID=\(request.targetContext?.target.processIdentifier ?? 0) targetBundle=\(request.targetContext?.target.bundleIdentifier ?? "none", privacy: .public)"
        )
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                return
            }
            await self?.continuePasteRecord(request, generation: generation)
        }
        pasteTask = task
    }

    private func continuePasteRecord(_ request: PendingPasteRequest, generation: Int) async {
        let startedAt = Date()
        var pasteSucceeded = false
        var copyCommitted = false
        var historySyncFailed = request.historySyncPending
        defer {
            let terminalPhase: ClipboardPasteSessionPhase = (pasteSucceeded || copyCommitted) ? .completed : .failed
            _ = pasteTransactionState.transition(
                generation: generation,
                token: request.token,
                to: terminalPhase
            )
            Self.transactionLogger.info(
                "stage=session-finished generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) phase=\(terminalPhase.rawValue, privacy: .public) elapsedMS=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            if pasteTransactionIsCurrent(generation, request: request) {
                activePasteRequest = nil
                pasteTask = nil
            }
        }
        let pluginLifecycleLease = request.pluginLifecycleLeaseProvider()
        guard request.pluginLifecycleToken == nil
                || pluginLifecycleLease != nil else {
            return
        }
        defer { pluginLifecycleLease?.release() }
        guard isClipboardFeatureEnabled else {
            recordFeatureDisabledStatus()
            return
        }
        guard !Task.isCancelled,
              pasteTransactionIsCurrent(generation, request: request),
              pastePluginLifecycleIsCurrent(request) else {
            return
        }
        guard let recordActionLease = clipboardStore.recordActionLease(
            recordID: request.recordID
        ) else {
            recordNotFoundStatus()
            return
        }
        defer { clipboardStore.finishRecordActionLease(recordActionLease) }
        guard let record = clipboardStore.resolveRecord(recordID: request.recordID) else {
            recordNotFoundStatus()
            return
        }
        let causationID = UUID()
        do {
            let pasteboardLease: ClipboardPasteboardWriteLease
            let expectedChangeCount: Int
            if let preparedWriteLease = request.preparedWriteLease {
                expectedChangeCount = preparedWriteLease.changeCount
            } else if let requestChangeCount = request.expectedPasteboardChangeCount {
                expectedChangeCount = requestChangeCount
            } else {
                expectedChangeCount = try await autoPasteCoordinator.currentPasteboardChangeCount()
            }
            clipboardStore.pasteAttempt = ClipboardPasteAttempt(
                recordID: request.recordID,
                targetBundleID: request.targetContext?.target.bundleIdentifier,
                targetPID: request.targetContext?.target.processIdentifier,
                pasteboardChangeCountBefore: expectedChangeCount,
                state: .prepared,
                failureReason: nil
            )
            if let preparedWriteLease = request.preparedWriteLease {
                pasteboardLease = preparedWriteLease
                guard await autoPasteCoordinator.validate(pasteboardLease) else {
                    throw ClipboardAutoPastePartialFailure(
                        reason: .pasteboardChanged,
                        pasteboardLease: pasteboardLease
                    )
                }
                Self.transactionLogger.info(
                    "stage=copy-reused generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) writeChangeCount=\(pasteboardLease.changeCount) brokerGeneration=\(pasteboardLease.brokerGeneration)"
                )
                copyCommitted = true
                if request.historySyncPending {
                    let recency = await clipboardStore.commitCopyEvent(
                        recordID: request.recordID,
                        source: request.copyEventSource,
                        causationID: causationID,
                        shouldPublishPluginEvent: { [weak self] in
                            guard let self else { return false }
                            return self.pasteEffectsMayPublish(
                                generation: generation,
                                request: request,
                                recordActionLease: recordActionLease
                            )
                        }
                    )
                    historySyncFailed = !recency.persisted
                }
            } else {
                let payloadResult = await clipboardStore.readPayloadForAction(
                    recordID: request.recordID,
                    purpose: .paste
                )
                guard !Task.isCancelled,
                      pasteTransactionIsCurrent(generation, request: request),
                      pastePluginLifecycleIsCurrent(request) else {
                    return
                }
                let pluginInput = await pluginClipboardContentEventInput(
                    record: record,
                    payload: payloadResult.payload
                )
                defer {
                    removePluginResources(pluginInput.resources.map(\.id))
                }
                guard !Task.isCancelled,
                      pasteTransactionIsCurrent(generation, request: request),
                      pastePluginLifecycleIsCurrent(request) else {
                    Self.transactionLogger.info(
                        "stage=plugin-resource-staging generation=\(generation) kind=\(record.kind.rawValue, privacy: .public) byteCount=\(pluginInput.resources.first?.byteCount ?? 0) outcome=discarded"
                    )
                    return
                }
                let effectivePayload: ClipboardRecorderPayload?
                if pluginInput.resourceStagingFailed {
                    // Plugin infrastructure is fail-open. A temporary-file or
                    // hashing failure must never turn a valid core paste into
                    // a failed paste; skip only the pre-hook for this request.
                    Self.transactionLogger.error(
                        "stage=plugin-resource-staging generation=\(generation) kind=\(record.kind.rawValue, privacy: .public) byteCount=0 outcome=failed-open"
                    )
                    effectivePayload = payloadResult.payload
                } else {
                    Self.transactionLogger.info(
                        "stage=plugin-resource-staging generation=\(generation) kind=\(record.kind.rawValue, privacy: .public) byteCount=\(pluginInput.resources.first?.byteCount ?? 0) outcome=ready"
                    )
                    let willEvent = BlocksPluginEventEnvelope(
                        name: .clipboardWillWritePasteboard,
                        sessionID: request.token.uuidString,
                        requestID: request.token.uuidString,
                        causationID: causationID,
                        source: [
                            "trigger": .string(request.copyEventSource.rawValue),
                            "target_bundle_id": .string(
                                request.targetContext?.target.bundleIdentifier ?? ""
                            ),
                        ],
                        authorization: .init(
                            userInitiated:
                                request.invocationOrigin.userInitiated
                        ),
                        payload: pluginInput.payload,
                        resources: pluginInput.resources
                    )
                    let willResult = await dispatchPluginEvent(willEvent)
                    guard pasteEffectsMayPublish(
                        generation: generation,
                        request: request,
                        recordActionLease: recordActionLease
                    ) else {
                        return
                    }
                    guard willResult.allowed else {
                        recordStatus(
                            .failed,
                            title: "status.clipboardPasteFailed.title",
                            detail: willResult.reason
                                ?? "A plugin blocked this paste."
                        )
                        return
                    }
                    effectivePayload = applyingPluginPasteMutations(
                        from: willResult.envelope,
                        to: payloadResult.payload
                    )
                }
                Self.transactionLogger.info(
                    "stage=copy-start generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) signature12=\(record.signatureSHA256_12, privacy: .public) kind=\(record.kind.rawValue, privacy: .public) itemCount=\(record.formatSummary.itemCount) byteCount=\(record.formatSummary.byteCount ?? -1) sourceBundle=\(record.sourceApp?.bundleIdentifier ?? "none", privacy: .public) sourceCandidate=\(record.sourceApp?.sourceAppIsCandidate == true) expectedChangeCount=\(expectedChangeCount) payloadAvailable=\(payloadResult.payload != nil)"
                )
                let copyResult = try await autoPasteCoordinator.copyToPasteboard(
                    record: record,
                    payload: effectivePayload,
                    expectedPasteboardChangeCount: expectedChangeCount,
                    operationID: request.token,
                    operationAllowed: { [weak self] in
                        guard let self else { return false }
                        return self.isClipboardFeatureEnabled
                            && self.pasteTransactionIsCurrent(generation, request: request)
                            && self.pastePluginLifecycleIsCurrent(request)
                            && self.clipboardStore.isCurrentRecordActionLease(recordActionLease)
                    },
                    recordCommitGate: clipboardStore.recordCommitGate
                )
                pasteboardLease = copyResult.pasteboardLease
                // Copy completion is a physical terminal fact. Persist it
                // before evaluating whether this task may still update UI or
                // send Cmd+V; cancellation and invalidation must never erase
                // a completed pasteboard replacement from attempt/recency.
                clipboardStore.pasteAttempt?.state = .pasteboardWritten
                copyCommitted = true
                let recency = await clipboardStore.commitCopyEvent(
                    recordID: request.recordID,
                    source: request.copyEventSource,
                    causationID: causationID,
                    shouldPublishPluginEvent: { [weak self] in
                        guard let self else { return false }
                        return self.pasteEffectsMayPublish(
                            generation: generation,
                            request: request,
                            recordActionLease: recordActionLease
                        )
                    }
                )
                Self.transactionLogger.info(
                    "stage=recency-committed generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) found=\(recency.recordFound) persisted=\(recency.persisted) promotedAt=\(recency.promotedAt?.timeIntervalSince1970 ?? 0)"
                )
                if recency.recordFound, !recency.persisted {
                    historySyncFailed = true
                }
                guard copyResult.mayContinueAutomaticPaste,
                      !Task.isCancelled,
                      pasteTransactionIsCurrent(generation, request: request),
                      pastePluginLifecycleIsCurrent(request),
                      clipboardStore.isCurrentRecordActionLease(recordActionLease) else {
                    return
                }
                _ = pasteTransactionState.transition(
                    generation: generation,
                    token: request.token,
                    to: .copied
                )
                Self.transactionLogger.info(
                    "stage=copy-finished generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) signature12=\(record.signatureSHA256_12, privacy: .public) writeChangeCount=\(pasteboardLease.changeCount) elapsedMS=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                )
            }
            guard !Task.isCancelled,
                  pasteTransactionIsCurrent(generation, request: request),
                  pastePluginLifecycleIsCurrent(request),
                  clipboardStore.isCurrentRecordActionLease(recordActionLease) else {
                return
            }
            // An accessibility retry reuses the lease created after the first
            // physical write. That first attempt already released its panel;
            // requiring the now-closed invocation a second time would make the
            // authorized retry cancel itself before posting Cmd+V.
            if request.preparedWriteLease == nil,
               let panelInvocationID = request.panelInvocationID {
                guard clipboardHistoryPanelPresenter.releasePanelForPaste(
                    sessionID: request.token,
                    expectedInvocationID: panelInvocationID
                ) else {
                    invalidatePasteTransaction(stage: "panel-release-rejected")
                    return
                }
            }
            _ = pasteTransactionState.transition(
                generation: generation,
                token: request.token,
                to: .targetVerifying
            )
            Self.transactionLogger.info(
                "stage=target-verification-start generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) targetPID=\(request.targetContext?.target.processIdentifier ?? 0) targetBundle=\(request.targetContext?.target.bundleIdentifier ?? "none", privacy: .public) targetWindowID=\(request.targetContext?.windowID ?? 0) launchIdentity=\(request.targetContext?.target.launchDate != nil)"
            )
            _ = pasteTransactionState.transition(
                generation: generation,
                token: request.token,
                to: .dispatching
            )
            let result = try await autoPasteCoordinator.dispatchPaste(
                targetContext: request.targetContext,
                pasteboardLease: pasteboardLease,
                promptForAccessibility: request.promptForAccessibility,
                operationAllowed: { [weak self] in
                    guard let self else { return false }
                    return self.isClipboardFeatureEnabled
                        && self.pasteTransactionIsCurrent(generation, request: request)
                        && self.pastePluginLifecycleIsCurrent(request)
                        && self.clipboardStore.isCurrentRecordActionLease(recordActionLease)
                }
            )
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            pasteSucceeded = result.commandPosted
            clipboardStore.pasteAttempt?.state = result.commandPosted ? .pasteCommandSent : .pasteboardWritten
            Self.transactionLogger.info(
                "stage=dispatch-finished generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) commandPosted=\(result.commandPosted) elapsedMS=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            recordStatus(
                .ready,
                title: "status.clipboardPasteReady.title",
                detail: L10n.string(
                    historySyncFailed
                        ? "status.clipboardPasteReady.historySyncFailed"
                        : "status.clipboardPasteReady.detail"
                )
            )
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .clipboardDidDispatchPaste,
                    sessionID: request.token.uuidString,
                    requestID: request.token.uuidString,
                    causationID: causationID,
                    payload: [
                        "record_id": .string(record.id),
                        "command_posted": .bool(result.commandPosted),
                    ]
                )
            )
        } catch let partialFailure as ClipboardAutoPastePartialFailure {
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            Self.transactionLogger.error(
                "stage=dispatch-partial-failure generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) reason=\(String(describing: partialFailure.reason), privacy: .public) writeChangeCount=\(partialFailure.pasteboardChangeCountAfterWrite) elapsedMS=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            await handlePartialPasteFailure(
                partialFailure,
                request: request,
                generation: generation,
                historySyncPending: historySyncFailed,
                recordActionLease: recordActionLease
            )
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .clipboardPasteFailed,
                    sessionID: request.token.uuidString,
                    requestID: request.token.uuidString,
                    causationID: causationID,
                    payload: [
                        "record_id": .string(record.id),
                        "error": .string(String(describing: partialFailure.reason)),
                    ]
                )
            )
        } catch let error as ClipboardAutoPasteError {
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            Self.transactionLogger.error(
                "stage=session-error generation=\(generation) session=\(request.token.uuidString, privacy: .public) record=\(request.recordID, privacy: .public) reason=\(String(describing: error), privacy: .public) elapsedMS=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            handlePasteError(error, request: request)
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .clipboardPasteFailed,
                    sessionID: request.token.uuidString,
                    requestID: request.token.uuidString,
                    causationID: causationID,
                    payload: [
                        "record_id": .string(record.id),
                        "error": .string(String(describing: error)),
                    ]
                )
            )
        } catch {
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            clipboardStore.pasteAttempt?.state = .failed
            recordStatus(
                .failed,
                title: "status.clipboardPasteFailed.title",
                detail: error.localizedDescription
            )
            _ = await dispatchPluginEvent(
                BlocksPluginEventEnvelope(
                    name: .clipboardPasteFailed,
                    sessionID: request.token.uuidString,
                    requestID: request.token.uuidString,
                    causationID: causationID,
                    payload: [
                        "record_id": .string(record.id),
                        "error": .string(error.localizedDescription),
                    ]
                )
            )
        }
    }

    private func handlePartialPasteFailure(
        _ failure: ClipboardAutoPastePartialFailure,
        request: PendingPasteRequest,
        generation: Int,
        historySyncPending: Bool,
        recordActionLease: ClipboardRecordActionLease
    ) async {
        guard pasteEffectsMayPublish(
            generation: generation,
            request: request,
            recordActionLease: recordActionLease
        ) else {
            return
        }
        clipboardStore.pasteAttempt?.state = .pasteboardWritten
        switch failure.reason {
        case .featureDisabled:
            recordCopiedFallback(.targetApplicationUnavailable)
        case .accessibilityPermissionRequired:
            guard pastePluginLifecycleIsCurrent(request) else { return }
            guard await autoPasteCoordinator.validate(failure.pasteboardLease) else {
                guard pasteEffectsMayPublish(
                    generation: generation,
                    request: request,
                    recordActionLease: recordActionLease
                ) else {
                    return
                }
                recordPasteFailure(
                    .pasteboardChanged,
                    detail: "status.clipboardPasteRetry.detail"
                )
                return
            }
            guard pasteEffectsMayPublish(
                generation: generation,
                request: request,
                recordActionLease: recordActionLease
            ) else {
                return
            }
            pendingPasteRequest = request.waitingForAccessibilityRetry(
                lease: failure.pasteboardLease,
                historySyncPending: historySyncPending
            )
            clipboardStore.pasteAttempt?.failureReason = .notAuthorized
            presentAccessibilityAssist { [weak self, requestToken = request.token] in
                self?.pastePermissionStateDidRefresh(requestToken: requestToken)
            }
            recordStatus(
                .failed,
                title: "status.clipboardPastePermission.title",
                detail: L10n.string("status.clipboardPastePermission.detail")
            )
            notificationCoordinator.present(
                level: .warning,
                titleKey: "status.clipboardPastePermission.title",
                detail: L10n.string("status.clipboardPastePermission.detail"),
                deduplicationKey: "clipboard.paste.permission"
            )
        case .targetApplicationNotFrontmost:
            recordCopiedFallback(.targetApplicationNotFrontmost)
        case .targetApplicationUnavailable:
            recordCopiedFallback(.targetApplicationUnavailable)
        case .pasteEventFailed:
            recordCopiedFallback(.eventCreationFailed)
        case .pasteboardChanged:
            clipboardStore.pasteAttempt?.state = .failed
            recordPasteFailure(
                .pasteboardChanged,
                kind: .failed,
                title: "status.clipboardPasteFailed.title",
                detail: "status.clipboardPasteRetry.detail"
            )
        default:
            clipboardStore.pasteAttempt?.state = .failed
            recordStatus(
                .failed,
                title: "status.clipboardPasteFailed.title",
                detail: L10n.string("status.clipboardPasteRetry.detail")
            )
            notificationCoordinator.present(
                level: .error,
                titleKey: "status.clipboardPasteFailed.title",
                detail: L10n.string("status.clipboardPasteRetry.detail"),
                deduplicationKey: "clipboard.paste.failed"
            )
        }
    }

    private func pasteEffectsMayPublish(
        generation: Int,
        request: PendingPasteRequest,
        recordActionLease: ClipboardRecordActionLease
    ) -> Bool {
        !Task.isCancelled
            && pasteTransactionIsCurrent(generation, request: request)
            && pastePluginLifecycleIsCurrent(request)
            && clipboardStore.isCurrentRecordActionLease(recordActionLease)
    }

    private func handlePasteError(_ error: ClipboardAutoPasteError, request: PendingPasteRequest) {
        clipboardStore.pasteAttempt?.state = .failed
        switch error {
        case .featureDisabled:
            recordFeatureDisabledStatus()
        case .accessibilityPermissionRequired:
            pendingPasteRequest = request
            clipboardStore.pasteAttempt?.failureReason = .notAuthorized
            presentAccessibilityAssist { [weak self, requestToken = request.token] in
                self?.pastePermissionStateDidRefresh(requestToken: requestToken)
            }
            recordStatus(
                .failed,
                title: "status.clipboardPastePermission.title",
                detail: L10n.string("status.clipboardPastePermission.detail")
            )
            notificationCoordinator.present(
                level: .warning,
                titleKey: "status.clipboardPastePermission.title",
                detail: L10n.string("status.clipboardPastePermission.detail"),
                deduplicationKey: "clipboard.paste.permission"
            )
        case .recordNotRestorable:
            recordPasteFailure(
                .recordNotRestorable,
                kind: .placeholder,
                title: "status.clipboardPasteUnavailable.title",
                detail: "status.clipboardPasteUnavailable.detail"
            )
        case .payloadUnavailable:
            recordPasteFailure(.payloadUnavailable, detail: "status.clipboardPasteFailed.payloadUnavailable")
        case .unsupportedPayload:
            recordPasteFailure(.unsupportedPayload, detail: "status.clipboardPasteFailed.unsupportedPayload")
        case .targetApplicationUnavailable:
            recordPasteFailure(.targetApplicationUnavailable, detail: "status.clipboardPasteFailed.targetUnavailable")
        case .targetApplicationNotFrontmost:
            recordPasteFailure(
                .targetApplicationNotFrontmost,
                detail: "status.clipboardPasteFailed.targetUnavailable"
            )
        case .pasteEventFailed:
            recordPasteFailure(.eventCreationFailed, detail: "status.clipboardPasteFailed.eventFailed")
        case .pasteboardWriteFailed:
            recordPasteFailure(.pasteboardWriteFailed, detail: "status.clipboardPasteFailed.payloadUnavailable")
        case .pasteboardChanged:
            recordPasteFailure(.pasteboardChanged, detail: "status.clipboardPasteRetry.detail")
        case .recordNotFound:
            recordStatus(
                .failed,
                title: "status.clipboardPasteFailed.title",
                detail: error.localizedDescription
            )
        }
    }

    func recordPasteFailure(
        _ reason: ClipboardPasteFailureReason,
        kind: AppStatusKind = .failed,
        title: String = "status.clipboardPasteFailed.title",
        detail: String
    ) {
        clipboardStore.pasteAttempt?.failureReason = reason
        recordStatus(kind, title: title, detail: L10n.string(detail))
        notificationCoordinator.present(
            level: kind == .failed ? .error : .warning,
            titleKey: title,
            detail: L10n.string(detail),
            deduplicationKey: "clipboard.paste.\(reason.rawValue)"
        )
    }

    func pluginClipboardContentEventInput(
        record: ClipboardRecorderRecord,
        payload sourcePayload: ClipboardRecorderPayload?
    ) async -> ClipboardPluginContentEventInput {
        await ClipboardPluginEventContract.contentInput(
            record: record,
            payload: sourcePayload,
            stageTextResource: stagePluginTextResource
        )
    }

    func applyingPluginPasteMutations(
        from envelope: BlocksPluginEventEnvelope,
        to original: ClipboardRecorderPayload?
    ) -> ClipboardRecorderPayload? {
        guard let original else { return nil }
        guard let text = envelope.payload.string("text")
            ?? envelope.payload.string("plain_text") else {
            return original
        }
        // Text mutations are allowed only for kinds whose content contract is
        // textual. File URLs also carry text for display/search, but their
        // pasteboard representation must remain a file URL.
        let originalText: String
        switch original.kind {
        case .text, .richText, .url:
            guard let text = original.text ?? original.urlString else {
                return original
            }
            originalText = text
        case .fileURL, .image, .mixed, .unknown:
            return original
        }
        guard text != originalText else { return original }
        // A transformed rich-text/URL record becomes plain text so the
        // original secondary representation can never disagree with the
        // plugin-provided content.
        return ClipboardRecorderPayload(
            recordID: original.recordID,
            kind: .text,
            text: text
        )
    }

    private func recordCopiedFallback(_ reason: ClipboardPasteFailureReason) {
        clipboardStore.pasteAttempt?.state = .pasteboardWritten
        clipboardStore.pasteAttempt?.failureReason = reason
        recordStatus(
            .ready,
            title: "status.clipboardPasteCopiedFallback.title",
            detail: L10n.string("status.clipboardPasteCopiedFallback.detail")
        )
        notificationCoordinator.copiedWithoutAutomaticPaste(reason: reason)
    }

}
