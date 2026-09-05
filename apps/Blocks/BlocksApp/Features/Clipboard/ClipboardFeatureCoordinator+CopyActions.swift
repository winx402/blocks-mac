import BlocksCore
import Foundation
import OSLog

@MainActor
extension ClipboardFeatureCoordinator {
    func copyRecordAsPlainText(recordID: String) {
        invalidatePlainTextCopy()
        let owner = UUID()
        plainTextCopyTaskOwner = owner
        plainTextCopyTask = Task { @MainActor [weak self] in
            await self?.copyRecordAsPlainTextAsync(
                recordID: recordID,
                owner: owner
            )
        }
    }

    func copyExplicitText(
        _ text: String,
        source: ClipboardCopyEventSource
    ) async -> ClipboardExplicitTextCopyOutcome {
        let captureGeneration = captureLiveCaptureGeneration()
        let privacyCaptureAdmissionToken = privacyStore.captureAdmissionToken
        let operationID = UUID()
        let recordID =
            "clip_explicit_\(Int(Date().timeIntervalSince1970 * 1_000))_"
            + String(operationID.uuidString.prefix(8)).lowercased()
        let signature = ClipboardExplicitTextSnapshotFactory.signature(
            for: text
        )
        let lease: ClipboardPasteboardWriteLease
        do {
            lease = try await autoPasteCoordinator.writePlainText(
                text,
                origin: ClipboardPasteboardWriteOrigin(
                    operationID: operationID,
                    recordID: recordID,
                    signatureSHA256: signature
                )
            )
        } catch {
            Self.transactionLogger.error(
                "stage=explicit-text-copy-write-failed source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public)"
            )
            return .failed
        }

        guard await autoPasteCoordinator.validate(lease) else {
            Self.transactionLogger.warning(
                "stage=explicit-text-copy-overwritten source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public) changeCount=\(lease.changeCount)"
            )
            return .failed
        }

        guard isClipboardFeatureEnabled,
              !clipboardStore.recorderPaused,
              privacyStore.canCaptureClipboard else {
            Self.transactionLogger.info(
                "stage=explicit-text-copy-history-skipped source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public) featureEnabled=\(self.isClipboardFeatureEnabled) paused=\(self.clipboardStore.recorderPaused) privacyAvailable=\(self.privacyStore.canCaptureClipboard)"
            )
            return .copiedWithoutHistory
        }
        guard let snapshot = ClipboardExplicitTextSnapshotFactory.make(
            text: text,
            recordID: recordID,
            changeCount: lease.changeCount
        ) else {
            return .copiedWithoutHistory
        }
        await clipboardStore.waitForCleanupMutationToSettle()
        guard !Task.isCancelled else { return .copiedWithoutHistory }
        let capturePolicy = ClipboardCapturePolicy(
            paused: clipboardStore.recorderPaused,
            privacyPolicyAvailable: privacyStore.canCaptureClipboard,
            privacySnapshot: privacyStore.policySnapshot
        )
        guard isClipboardFeatureEnabled,
              !capturePolicy.paused,
              capturePolicy.privacyPolicyAvailable else {
            Self.transactionLogger.info(
                "stage=explicit-text-copy-history-skipped source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public) featureEnabled=\(self.isClipboardFeatureEnabled) paused=\(capturePolicy.paused) privacyAvailable=\(capturePolicy.privacyPolicyAvailable)"
            )
            return .copiedWithoutHistory
        }
        guard let privacyCaptureAdmissionToken else {
            Self.transactionLogger.info(
                "stage=explicit-text-copy-history-skipped source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public) outcome=privacy-unavailable"
            )
            return .copiedWithoutHistory
        }
        let privacyCaptureAuthorizationGeneration =
            privacyCaptureAdmissionToken.generation
        let result = await ingestExplicitTextLiveCapture(
            snapshot,
            capturePolicy: capturePolicy,
            captureGeneration: captureGeneration,
            privacyCaptureAdmissionToken: privacyCaptureAdmissionToken,
            causationID: operationID
        )
        guard explicitTextCaptureAdmissionIsCurrent(
            privacyCaptureAuthorizationGeneration: privacyCaptureAuthorizationGeneration,
            captureGeneration: captureGeneration
        ) else {
            return .copiedWithoutHistory
        }
        guard result.succeeded, let record = result.record else {
            Self.transactionLogger.error(
                "stage=explicit-text-copy-history-failed source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public)"
            )
            return .copiedWithoutHistory
        }
        let recency = await clipboardStore.commitCopyEvent(
            recordID: record.id,
            source: source,
            causationID: operationID
        )
        Self.transactionLogger.info(
            "stage=explicit-text-copy-finished source=\(source.rawValue, privacy: .public) operation=\(operationID.uuidString, privacy: .public) record=\(record.id, privacy: .public) duplicate=\(result.duplicate) persisted=\(recency.persisted)"
        )
        return recency.persisted && !clipboardStore.repositoryUnavailable
            ? .copiedAndRecorded
            : .copiedWithoutHistory
    }

    private func copyRecordAsPlainTextAsync(
        recordID: String,
        owner: UUID
    ) async {
        defer { finishPlainTextCopy(owner: owner) }
        guard isCurrentPlainTextCopy(owner: owner) else { return }
        guard let recordLease = clipboardStore.recordActionLease(
            recordID: recordID
        ) else {
            return
        }
        defer { clipboardStore.finishRecordActionLease(recordLease) }
        guard let record = clipboardStore.resolveRecord(recordID: recordID),
              plainTextCopyMayWrite(owner: owner, recordLease: recordLease) else {
            return
        }
        let payload = await plainTextCopyPayloadReader(recordID).payload
        guard plainTextCopyMayWrite(owner: owner, recordLease: recordLease) else {
            return
        }
        guard let text = payload?.text ?? payload?.urlString else {
            recordStatus(
                .failed,
                title: "status.clipboardPlainTextCopyFailed.title",
                detail: L10n.string("status.clipboardPlainTextCopyFailed.detail")
            )
            notificationCoordinator.plainTextCopyFailed()
            return
        }
        guard plainTextCopyMayWrite(owner: owner, recordLease: recordLease) else {
            return
        }
        let operationID = UUID()
        let lease: ClipboardPasteboardWriteLease
        do {
            lease = try await autoPasteCoordinator.writePlainText(
                text,
                origin: ClipboardPasteboardWriteOrigin(
                    operationID: operationID,
                    recordID: record.id,
                    signatureSHA256: record.signatureSHA256
                ),
                operationAllowed: { [weak self] in
                    self?.plainTextCopyMayWrite(
                        owner: owner,
                        recordLease: recordLease
                    ) == true
                },
                requiresPreparedAuthorization: true,
                recordCommitGate: clipboardStore.recordCommitGate
            )
        } catch {
            guard plainTextCopyMayWrite(
                owner: owner,
                recordLease: recordLease
            ) else { return }
            recordStatus(
                .failed,
                title: "status.clipboardPlainTextCopyFailed.title",
                detail: L10n.string("status.clipboardPlainTextCopyFailed.detail")
            )
            notificationCoordinator.plainTextCopyFailed()
            return
        }
        // The write lease is now a physical terminal fact. Keep validating and
        // recording it unless a committed record deletion invalidated its lease.
        guard clipboardStore.isCurrentRecordActionLease(recordLease) else {
            return
        }
        guard await autoPasteCoordinator.validate(lease) else {
            guard plainTextCopyMayWrite(
                owner: owner,
                recordLease: recordLease
            ) else { return }
            Self.transactionLogger.warning(
                "stage=plain-text-copy-overwritten operation=\(operationID.uuidString, privacy: .public) record=\(recordID, privacy: .public) changeCount=\(lease.changeCount)"
            )
            recordStatus(
                .failed,
                title: "status.clipboardPlainTextCopyFailed.title",
                detail: L10n.string("status.clipboardPlainTextCopyFailed.detail")
            )
            notificationCoordinator.plainTextCopyFailed()
            return
        }
        // A validated pasteboard lease is a physical terminal fact. Once it
        // exists, retain its recency while the record itself remains valid;
        // task/feature invalidation only suppresses late presentation effects.
        guard clipboardStore.isCurrentRecordActionLease(recordLease) else {
            return
        }
        let recency = await clipboardStore.commitCopyEvent(
            recordID: recordID,
            source: .plainTextCopy,
            causationID: operationID,
            shouldPublishPluginEvent: { [weak self] in
                self?.plainTextCopyMayWrite(
                    owner: owner,
                    recordLease: recordLease
                ) == true
            }
        )
        guard recency.recordFound,
              plainTextCopyMayWrite(owner: owner, recordLease: recordLease) else {
            return
        }
        recordStatus(
            .ready,
            title: "status.clipboardPlainTextCopied.title",
            detail: L10n.string("status.clipboardPlainTextCopied.detail")
        )
        notificationCoordinator.plainTextCopied()
    }

    private func isCurrentPlainTextCopy(owner: UUID) -> Bool {
        !Task.isCancelled
            && plainTextCopyTaskOwner == owner
            && isClipboardFeatureEnabled
    }

    private func plainTextCopyMayWrite(
        owner: UUID,
        recordLease: ClipboardRecordActionLease
    ) -> Bool {
        isCurrentPlainTextCopy(owner: owner)
            && clipboardStore.isCurrentRecordActionLease(recordLease)
    }

    private func finishPlainTextCopy(owner: UUID) {
        guard plainTextCopyTaskOwner == owner else { return }
        plainTextCopyTask = nil
        plainTextCopyTaskOwner = nil
    }

    func invalidatePlainTextCopy() {
        plainTextCopyTask?.cancel()
        plainTextCopyTask = nil
        plainTextCopyTaskOwner = nil
    }
}
