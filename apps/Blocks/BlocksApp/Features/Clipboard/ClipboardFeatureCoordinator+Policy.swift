import Foundation

extension ClipboardFeatureCoordinator {
    @discardableResult
    func previewCleanupPolicy(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) -> Bool {
        return clipboardStore.requestPolicyPreview(
            cleanupMode: cleanupMode,
            retentionPolicy: retentionPolicy,
            maxItems: maxItems,
            preserveFavorite: preserveFavorite,
            completion: { [weak self] result in
                guard let self else { return }
                if case .committed = result {
                    let defaults = UserDefaults.standard
                    defaults.set(cleanupMode.rawValue, forKey: "clipboard.policy.cleanupMode")
                    defaults.set(retentionPolicy.rawValue, forKey: "clipboard.policy.retention")
                    defaults.set(max(1, maxItems), forKey: "clipboard.policy.maxItems")
                    defaults.set(preserveFavorite, forKey: "clipboard.policy.preserveFavorite")
                    self.recordStatus(
                        .ready,
                        title: "status.clipboardPolicyApplied.title",
                        detail: L10n.format(
                            "status.clipboardPolicyApplied.detail",
                            self.clipboardStore.records.count,
                            self.clipboardStore.records.count,
                            self.privacyStore.restrictedRuleCount
                        )
                    )
                }
                completion(result)
            }
        )
    }

    func cancelCleanupPolicyPreview() {
        clipboardStore.cancelPolicyPreview()
    }

    func confirmCleanupPolicy(
        token: ClipboardPolicyConfirmationToken,
        completion: @escaping @MainActor (ClipboardPolicyConfirmationResult) -> Void
    ) {
        let previousCount = clipboardStore.records.count
        clipboardStore.confirmPolicyApplication(token: token) { [weak self] result in
            guard let self else { return }
            if case let .committed(visibleRecordCount) = result {
                let defaults = UserDefaults.standard
                defaults.set(token.cleanupMode.rawValue, forKey: "clipboard.policy.cleanupMode")
                defaults.set(token.retentionPolicy.rawValue, forKey: "clipboard.policy.retention")
                defaults.set(token.maxItems, forKey: "clipboard.policy.maxItems")
                defaults.set(token.preserveFavorite, forKey: "clipboard.policy.preserveFavorite")
                self.recordStatus(
                    .ready,
                    title: "status.clipboardPolicyApplied.title",
                    detail: L10n.format(
                        "status.clipboardPolicyApplied.detail",
                        previousCount,
                        visibleRecordCount ?? self.clipboardStore.records.count,
                        self.privacyStore.restrictedRuleCount
                    )
                )
            } else if case .failed = result {
                self.recordStatus(.failed, title: "status.clipboardPolicyApplyFailed.title", detail: L10n.string("status.clipboardPolicyApplyFailed.detail"))
            }
            completion(result)
        }
    }

    func policySummary(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool
    ) -> String {
        let favoriteSummary = preserveFavorite
            ? L10n.string("clipboard.policy.favorite.preserved")
            : L10n.string("clipboard.policy.favorite.notPreserved")
        switch cleanupMode {
        case .time:
            if let dayCount = retentionPolicy.dayCount {
                return L10n.format("clipboard.policy.summary.time", dayCount, favoriteSummary)
            }
            return L10n.format("clipboard.policy.summary.time.forever", favoriteSummary)
        case .count:
            return L10n.format("clipboard.policy.summary.count", max(1, maxItems), favoriteSummary)
        }
    }

    #if DEBUG
    @discardableResult
    func applyCleanupPolicy(
        cleanupMode: ClipboardCleanupMode,
        retentionPolicy: ClipboardRetentionPolicy,
        maxItems: Int,
        preserveFavorite: Bool,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> Bool {
        let previousCount = clipboardStore.records.count
        return clipboardStore.requestPolicyApplication(
            cleanupMode: cleanupMode,
            retentionPolicy: retentionPolicy,
            maxItems: maxItems,
            preserveFavorite: preserveFavorite
        ) { [weak self] result, visibleRecordCount in
            guard let self else { return }
            switch result {
            case .success:
                let defaults = UserDefaults.standard
                defaults.set(cleanupMode.rawValue, forKey: "clipboard.policy.cleanupMode")
                defaults.set(retentionPolicy.rawValue, forKey: "clipboard.policy.retention")
                defaults.set(max(1, maxItems), forKey: "clipboard.policy.maxItems")
                defaults.set(preserveFavorite, forKey: "clipboard.policy.preserveFavorite")
                self.recordStatus(
                    .ready,
                    title: "status.clipboardPolicyApplied.title",
                    detail: L10n.format(
                        "status.clipboardPolicyApplied.detail",
                        previousCount,
                        visibleRecordCount ?? self.clipboardStore.records.count,
                        self.privacyStore.restrictedRuleCount
                    )
                )
                completion(true)
            case .failure:
                self.recordStatus(
                    .failed,
                    title: "status.clipboardPolicyApplyFailed.title",
                    detail: L10n.string("status.clipboardPolicyApplyFailed.detail")
                )
                completion(false)
            }
        }
    }
    #endif

    func clearUnfavoritedSummaries() {
        clipboardStore.requestClearUnfavorited { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(deletedCount, remainingCount):
                self.recordStatus(
                    .ready,
                    title: "status.clipboardUnfavoritedCleared.title",
                    detail: L10n.format(
                        "status.clipboardUnfavoritedCleared.detail",
                        deletedCount,
                        remainingCount
                    )
                )
            case .failure(.repository):
                self.recordStatus(
                    .failed,
                    title: "clipboard.hardening.state.unavailable.title",
                    detail: L10n.string("clipboard.hardening.state.unavailable.detail")
                )
            case .failure(.injected), .rejectedWhileBusy:
                self.recordStatus(
                    .failed,
                    title: "clipboard.policy.clearUnfavorited",
                    detail: L10n.string("status.clipboardPolicyApplyFailed.detail")
                )
            }
        }
    }

    var policyRetentionPolicy: ClipboardRetentionPolicy {
        let rawValue = UserDefaults.standard.string(forKey: "clipboard.policy.retention")
            ?? ClipboardRetentionPolicy.days30.rawValue
        return ClipboardRetentionPolicy(rawValue: rawValue) ?? .days30
    }

    var policyCleanupMode: ClipboardCleanupMode {
        let rawValue = UserDefaults.standard.string(forKey: "clipboard.policy.cleanupMode")
            ?? ClipboardCleanupMode.count.rawValue
        return ClipboardCleanupMode(rawValue: rawValue) ?? .count
    }

    var policyMaxItems: Int {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "clipboard.policy.maxItems") == nil
            ? 500
            : max(1, defaults.integer(forKey: "clipboard.policy.maxItems"))
    }

    var policyPreserveFavorite: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "clipboard.policy.preserveFavorite") == nil
            ? true
            : defaults.bool(forKey: "clipboard.policy.preserveFavorite")
    }
}
