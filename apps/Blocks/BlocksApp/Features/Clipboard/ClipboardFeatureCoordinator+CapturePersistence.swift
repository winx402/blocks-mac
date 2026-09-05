import AppKit
import BlocksCore
import Combine
import OSLog

// Privacy admission, coalescing and persistence share the coordinator's state.
@MainActor
extension ClipboardFeatureCoordinator {
    func ingestLiveCapture(_ snapshot: ClipboardLiveCaptureSnapshot) {
        guard featureAvailabilityStore.clipboardEnabled else { return }
        Self.transactionLogger.info(
            "stage=external-capture record=\(snapshot.record.id, privacy: .public) kind=\(snapshot.record.kind.rawValue, privacy: .public) signature12=\(snapshot.record.signatureSHA256_12, privacy: .public) changeCount=\(snapshot.record.changeCount) createdAt=\(snapshot.record.createdAt.timeIntervalSince1970) sourceBundle=\(snapshot.record.sourceApp?.bundleIdentifier ?? "none", privacy: .public) sourceCandidate=\(snapshot.record.sourceApp?.sourceAppIsCandidate == true)"
        )
        pendingPasteRequest = nil
        invalidatePasteTransaction(stage: "external-capture")
        guard liveCaptureTask == nil else {
            latestPendingLiveCapture = snapshot
            Self.transactionLogger.debug(
                "stage=capture-persistence-coalesced inFlight=1 pending=1"
            )
            return
        }
        startLiveCapturePersistence(snapshot)
    }

    private func startLiveCapturePersistence(
        _ snapshot: ClipboardLiveCaptureSnapshot
    ) {
        let taskOwner = UUID()
        let generation = liveCaptureGeneration.capture()
        guard let privacyCaptureAdmissionToken = privacyStore.captureAdmissionToken else {
            Self.transactionLogger.info(
                "stage=capture-policy-preflight record=\(snapshot.record.id, privacy: .public) outcome=privacy-unavailable"
            )
            return
        }
        let capturePolicy = ClipboardCapturePolicy(
            paused: clipboardStore.recorderPaused,
            privacyPolicyAvailable: privacyStore.canCaptureClipboard,
            privacySnapshot: privacyStore.policySnapshot
        )
        let captureDecision = capturePolicy.evaluate(
            record: snapshot.record,
            payload: snapshot.payload
        )
        guard !captureDecision.skipped else {
            Self.transactionLogger.info(
                "stage=capture-policy-preflight record=\(snapshot.record.id, privacy: .public) outcome=skipped"
            )
            return
        }
        let privacyCaptureAuthorizationGeneration = privacyCaptureAdmissionToken.generation
        liveCaptureTaskOwner = taskOwner
        liveCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishLiveCapturePersistence(owner: taskOwner) }
            guard self.liveCaptureAuthorizationIsCurrent(
                privacyCaptureAuthorizationGeneration
            ) else { return }
            let pluginInput = await self.pluginClipboardContentEventInput(
                record: snapshot.record,
                payload: snapshot.payload
            )
            defer {
                self.removePluginResources(pluginInput.resources.map(\.id))
            }
            guard self.liveCaptureAuthorizationIsCurrent(
                privacyCaptureAuthorizationGeneration
            ) else {
                Self.transactionLogger.info(
                    "stage=plugin-resource-staging generation=\(self.pasteTransactionState.generation) kind=\(snapshot.record.kind.rawValue, privacy: .public) byteCount=\(pluginInput.resources.first?.byteCount ?? 0) outcome=discarded"
                )
                return
            }
            let captureCausationID = UUID()
            let effectiveSnapshot: ClipboardLiveCaptureSnapshot
            if pluginInput.resourceStagingFailed {
                // Capture is a core data path. Plugin resource preparation is
                // fail-open so a temporary staging failure cannot discard the
                // user's clipboard history.
                Self.transactionLogger.error(
                    "stage=plugin-resource-staging generation=\(self.pasteTransactionState.generation) kind=\(snapshot.record.kind.rawValue, privacy: .public) byteCount=0 outcome=failed-open"
                )
                effectiveSnapshot = snapshot
            } else {
                Self.transactionLogger.info(
                    "stage=plugin-resource-staging generation=\(self.pasteTransactionState.generation) kind=\(snapshot.record.kind.rawValue, privacy: .public) byteCount=\(pluginInput.resources.first?.byteCount ?? 0) outcome=ready"
                )
                var willPayload = pluginInput.payload
                willPayload["change_count"] = .int(snapshot.record.changeCount)
                willPayload["summary"] = .string(snapshot.record.summary)
                willPayload["excluded"] = .bool(snapshot.record.excluded)
                let willEvent = BlocksPluginEventEnvelope(
                    name: .clipboardWillPersistCapture,
                    sessionID: snapshot.record.id,
                    causationID: captureCausationID,
                    source: [
                        "bundle_id": .string(
                            snapshot.record.sourceApp?.bundleIdentifier ?? ""
                        )
                    ],
                    payload: willPayload,
                    resources: pluginInput.resources
                )
                let willResult: BlocksPluginEventDispatchResult
                if let pluginRuntime = self.pluginRuntime {
                    willResult = await pluginRuntime.dispatchFromFeature(
                        willEvent,
                        admissionIsCurrent: { [weak self] in
                            self?.liveCaptureAuthorizationIsCurrent(
                                privacyCaptureAuthorizationGeneration
                            ) ?? false
                        }
                    )
                } else {
                    willResult = await self.dispatchPluginEvent(willEvent)
                }
                guard self.liveCaptureAuthorizationIsCurrent(
                    privacyCaptureAuthorizationGeneration
                ) else { return }
                guard willResult.allowed else {
                    Self.transactionLogger.warning(
                        "stage=capture-blocked plugin=\(willResult.blockedByPluginID ?? "unknown", privacy: .public)"
                    )
                    return
                }
                effectiveSnapshot = ClipboardLiveCaptureSnapshot(
                    record: snapshot.record.replacing(
                        excluded: willResult.envelope.payload.bool("excluded")
                            ?? snapshot.record.excluded,
                        summary: willResult.envelope.payload.string("summary")
                            ?? snapshot.record.summary
                    ),
                    payload: snapshot.payload
                )
            }
            await self.clipboardStore.waitForCleanupMutationToSettle()
            guard self.liveCaptureAuthorizationIsCurrent(
                privacyCaptureAuthorizationGeneration
            ) else { return }
            let result = await self.clipboardStore.ingestLiveCaptureAsync(
                effectiveSnapshot,
                capturePolicy: capturePolicy,
                captureDecision: captureDecision,
                cleanupMode: self.policyCleanupMode,
                retentionPolicy: self.policyRetentionPolicy,
                maxItems: self.policyMaxItems,
                preserveFavorite: self.policyPreserveFavorite,
                captureGeneration: liveCaptureGeneration,
                captureGenerationValue: generation,
                privacyCaptureAdmissionToken: privacyCaptureAdmissionToken,
                publishCommittedEffects: { [weak self] in
                    self?.liveCapturePrivacyAuthorizationIsCurrent(
                        privacyCaptureAuthorizationGeneration
                    ) ?? false
                },
                causationID: captureCausationID
            )
            guard !result.invalidated else { return }
            guard self.liveCapturePrivacyAuthorizationIsCurrent(
                privacyCaptureAuthorizationGeneration
            ) else { return }
            if !result.succeeded {
                let failedEvent = BlocksPluginEventEnvelope(
                    name: .clipboardCaptureFailed,
                    sessionID: snapshot.record.id,
                    causationID: captureCausationID,
                    payload: [
                        "record_id": .string(snapshot.record.id),
                        "error": .string("persistence_failed"),
                    ]
                )
                if let pluginRuntime = self.pluginRuntime {
                    _ = await pluginRuntime.dispatchFromFeature(
                        failedEvent,
                        admissionIsCurrent: { [weak self] in
                            self?.liveCapturePrivacyAuthorizationIsCurrent(
                                privacyCaptureAuthorizationGeneration
                            ) ?? false
                        }
                    )
                } else if self.liveCapturePrivacyAuthorizationIsCurrent(
                    privacyCaptureAuthorizationGeneration
                ) {
                    _ = await self.dispatchPluginEvent(failedEvent)
                }
                self.recordStatus(
                    .failed,
                    title: "status.clipboardPolicyApplyFailed.title",
                    detail: L10n.string("status.clipboardPolicyApplyFailed.detail")
                )
                self.notificationCoordinator.capturePersistenceFailed()
            } else if result.duplicate, self.screenSharingClipboardIsActive() {
                Self.transactionLogger.warning(
                    "stage=screen-sharing-old-signature-candidate record=\(result.record?.id ?? effectiveSnapshot.record.id, privacy: .public) signature12=\(effectiveSnapshot.record.signatureSHA256_12, privacy: .public) changeCount=\(effectiveSnapshot.record.changeCount)"
                )
            }
            if result.durablyCommitted {
                var didPayload = pluginInput.payload
                didPayload["record_id"] = .string(
                    result.record?.id ?? effectiveSnapshot.record.id
                )
                didPayload["duplicate"] = .bool(result.duplicate)
                didPayload["change_count"] = .int(
                    effectiveSnapshot.record.changeCount
                )
                didPayload["summary"] = .string(
                    effectiveSnapshot.record.summary
                )
                didPayload["excluded"] = .bool(
                    effectiveSnapshot.record.excluded
                )
                let didEvent = BlocksPluginEventEnvelope(
                    name: .clipboardDidPersistCapture,
                    sessionID: snapshot.record.id,
                    causationID: captureCausationID,
                    payload: didPayload,
                    resources: pluginInput.resources
                )
                if let pluginRuntime = self.pluginRuntime {
                    _ = await pluginRuntime.dispatchFromFeature(
                        didEvent,
                        admissionIsCurrent: { [weak self] in
                            self?.liveCapturePrivacyAuthorizationIsCurrent(
                                privacyCaptureAuthorizationGeneration
                            ) ?? false
                        }
                    )
                } else if self.liveCapturePrivacyAuthorizationIsCurrent(
                    privacyCaptureAuthorizationGeneration
                ) {
                    _ = await self.dispatchPluginEvent(didEvent)
                }
            }
        }
    }

    private func finishLiveCapturePersistence(owner: UUID) {
        guard liveCaptureTaskOwner == owner else { return }
        liveCaptureTask = nil
        liveCaptureTaskOwner = nil
        guard isClipboardFeatureEnabled,
              let pending = latestPendingLiveCapture else {
            latestPendingLiveCapture = nil
            return
        }
        latestPendingLiveCapture = nil
        startLiveCapturePersistence(pending)
    }

    func invalidateLiveCapturePersistence() {
        liveCaptureGeneration.invalidate()
        liveCaptureTask?.cancel()
        liveCaptureTask = nil
        liveCaptureTaskOwner = nil
        latestPendingLiveCapture = nil
    }

    private func liveCaptureAuthorizationIsCurrent(
        _ authorizationGeneration: Int
    ) -> Bool {
        !Task.isCancelled
            && isClipboardFeatureEnabled
            && privacyStore.canCaptureClipboard
            && privacyStore.privacyCaptureAuthorizationGeneration
                == authorizationGeneration
    }

    func captureLiveCaptureGeneration() -> UInt64 {
        liveCaptureGeneration.capture()
    }

    func ingestExplicitTextLiveCapture(
        _ snapshot: ClipboardLiveCaptureSnapshot,
        capturePolicy: ClipboardCapturePolicy,
        captureGeneration: UInt64,
        privacyCaptureAdmissionToken: PrivacyCaptureAdmissionToken,
        causationID: UUID
    ) async -> ClipboardLiveCaptureIngestResult {
        let privacyCaptureAuthorizationGeneration =
            privacyCaptureAdmissionToken.generation
        return await clipboardStore.ingestLiveCaptureAsync(
            snapshot,
            capturePolicy: capturePolicy,
            cleanupMode: policyCleanupMode,
            retentionPolicy: policyRetentionPolicy,
            maxItems: policyMaxItems,
            preserveFavorite: policyPreserveFavorite,
            captureGeneration: liveCaptureGeneration,
            captureGenerationValue: captureGeneration,
            privacyCaptureAdmissionToken: privacyCaptureAdmissionToken,
            publishCommittedEffects: { [weak self] in
                self?.explicitTextCaptureAdmissionIsCurrent(
                    privacyCaptureAuthorizationGeneration: privacyCaptureAuthorizationGeneration,
                    captureGeneration: captureGeneration
                ) == true
            },
            causationID: causationID
        )
    }

    func explicitTextCaptureAdmissionIsCurrent(
        privacyCaptureAuthorizationGeneration: Int,
        captureGeneration: UInt64
    ) -> Bool {
        liveCaptureAuthorizationIsCurrent(privacyCaptureAuthorizationGeneration)
            && liveCaptureGeneration.isCurrent(captureGeneration)
    }

    func liveCapturePrivacyAuthorizationIsCurrent(
        _ authorizationGeneration: Int
    ) -> Bool {
        privacyStore.canCaptureClipboard
            && privacyStore.privacyCaptureAuthorizationGeneration
                == authorizationGeneration
    }

}
