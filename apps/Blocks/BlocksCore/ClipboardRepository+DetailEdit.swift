import Foundation

/// Closed set of callers permitted to perform the transactional detail edit.
/// The command retains its persisted string representation, but repository
/// authorization must never accept an arbitrary caller-provided purpose.
public enum ClipboardDetailEditSavePurpose: String, CaseIterable, Sendable {
    case detailEditSave
    case pluginRecordUpdate
}

public extension ClipboardRepository {
    func loadDetailReadModel(recordID: String) throws -> ClipboardDetailReadModel {
        guard let record = try loadRecord(recordID: recordID) else {
            throw ClipboardDetailSaveFailure.recordNotFound
        }
        let contentState = try loadContentState(recordID: recordID)
        let searchState = try loadDetailSearchState(recordID: recordID)
        let preview = try loadPreviewSnapshot(recordID: recordID) ?? ClipboardContentPreviewSnapshot(
            recordID: record.id,
            revision: ClipboardSearchDocumentBuilder.revision(for: record),
            title: bounded(record.summary, limit: 120),
            body: bounded(record.summary, limit: 500),
            badge: record.kind.rawValue,
            contentKind: record.kind,
            ocrState: .notRequired,
            isTruncated: record.summary.count > 500
        )
        let metadata = try metadataSnapshot(
            record: record,
            contentRevision: contentState.revision,
            contentUpdatedAt: contentState.updatedAt,
            searchState: searchState
        )
        let editability = editability(record: record)
        let trimmedCustomTitle = record.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleIsCustom = trimmedCustomTitle?.isEmpty == false
        let title = titleIsCustom ? trimmedCustomTitle! : record.kind.rawValue
        return ClipboardDetailReadModel(
            recordID: record.id,
            contentRevision: contentState.revision,
            captureIdentityRevision: ClipboardSearchDocumentBuilder.revision(for: record),
            kind: record.kind,
            title: title,
            titleIsCustom: titleIsCustom,
            boundedPreview: ClipboardBoundedPreview(
                title: title,
                body: preview.body,
                badge: preview.badge,
                isTruncated: preview.isTruncated
            ),
            metadata: metadata,
            editability: editability,
            ocrState: searchState?.ocrState ?? .notRequired,
            ocrTextSource: searchState?.ocrTextSource ?? .none,
            updatedAt: searchState?.updatedAt ?? contentState.updatedAt,
            contentUpdatedAt: contentState.updatedAt
        )
    }

    func readDetailEditablePayload(recordID: String, purpose: String) throws -> ClipboardRecorderPayload? {
        guard purpose == "detailEditRead" || purpose == "detailFullValueRead" else {
            return nil
        }
        return try readPayload(recordID: recordID)
    }

    func readDetailMetadataFullValue(recordID: String, itemID: String, purpose: String) throws -> String? {
        guard purpose == "detailFullValueRead" else {
            return nil
        }
        guard let record = try loadRecord(recordID: recordID) else {
            throw ClipboardDetailSaveFailure.recordNotFound
        }
        switch itemID {
        case "source":
            return record.sourceApp?.localizedName ?? "Unknown source"
        case "created":
            return isoString(record.createdAt)
        case "lastCopied":
            return try isoString(loadLastCopiedAt(recordID: recordID))
        case "updated":
            return try isoString(loadContentState(recordID: recordID).updatedAt)
        case "url":
            let payload = try readPayload(recordID: recordID)
            return payload?.urlString ?? payload?.text
        case "fileURL":
            let payload = try readPayload(recordID: recordID)
            return payload?.urlString ?? payload?.text ?? record.summary
        case "bundleIdentifier":
            return record.sourceApp?.bundleIdentifier
        case "bundlePathSummary":
            return record.sourceApp?.bundlePathSummary
        case "bundlePathHash":
            return record.sourceApp?.bundlePathHash
        case "signatureHash":
            return record.signatureSHA256
        default:
            return nil
        }
    }

    func saveDetailEdit(
        command: ClipboardDetailEditCommand,
        onCommittedDeletion: @Sendable ([String]) -> Void = { _ in }
    ) throws -> ClipboardDetailSaveResult {
        let rollbackTracker = ClipboardSidecarRollbackTracker()
        do {
            let outcome = try database.connection.transaction { () -> (result: ClipboardDetailSaveResult, deletedRecordID: String?) in
                guard let record = try loadRecord(recordID: command.recordID) else {
                    throw ClipboardDetailSaveFailure.recordNotFound
                }
            let currentState = try loadContentState(recordID: command.recordID)
            guard currentState.revision == command.expectedContentRevision else {
                throw ClipboardDetailSaveFailure.revisionConflict
            }
            guard ClipboardDetailEditSavePurpose(rawValue: command.purpose) != nil,
                  record.restorable,
                  !record.excluded,
                  !record.snapshotSkipped,
                  command.updatesPayload || command.updatesCustomTitle else {
                throw ClipboardDetailSaveFailure.notEditable
            }

            let now = command.now
            let existingPayload = try readPayload(recordID: command.recordID)
            let currentSearchDocument = try loadSearchDocument(recordID: command.recordID)
            let tagTokens = try tagTokens(recordID: command.recordID)
            var payloadForSearch = existingPayload
            var newContentRevision = currentState.revision
            var changedFields: ClipboardDetailChangedFields = [.searchDocument, .fts]
            var ocrText = currentSearchDocument?.ocrText
            var ocrState = currentSearchDocument?.ocrState ?? .notRequired
            var ocrSource = currentSearchDocument?.ocrTextSource ?? .none
            var ocrUserEditedAt = currentSearchDocument?.ocrUserEditedAt
            var ocrLockedContentRevision = currentSearchDocument?.ocrLockedContentRevision
            var summary = record.summary
            var formatSummary = record.formatSummary
            var fullSignature = record.signatureSHA256
            var shortSignature = record.signatureSHA256_12
            var customTitle = record.customTitle
            var deletedRecordID: String?

            if command.updatesCustomTitle {
                let trimmed = command.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                customTitle = trimmed.isEmpty ? nil : trimmed
                changedFields.insert(.customTitle)
            }

            if command.updatesPayload || command.updatesCustomTitle {
                newContentRevision += 1
                changedFields.insert(.contentRevision)
            }

            if command.updatesPayload {
                changedFields.insert(.summary)
                switch command.editableKind {
                case .plainText:
                    guard record.kind == .text, existingPayload != nil else {
                        throw ClipboardDetailSaveFailure.payloadMissing
                    }
                    let text = command.draft.text
                    let payload = ClipboardRecorderPayload(recordID: record.id, kind: .text, text: text)
                    try storePayload(
                        payload,
                        forRecordID: record.id,
                        rollbackTracker: rollbackTracker
                    )
                    payloadForSearch = payload
                    summary = text.isEmpty ? "Empty text" : bounded(text, limit: 500)
                    formatSummary = formatSummaryForText(record.formatSummary, text: text, kind: .text)
                    changedFields.insert(.payload)

                case .url:
                    guard record.kind == .url, existingPayload != nil else {
                        throw ClipboardDetailSaveFailure.payloadMissing
                    }
                    let validation = ClipboardDetailURLValidator().validate(command.draft.text)
                    guard case let .success(url) = validation else {
                        throw ClipboardDetailSaveFailure.invalidURL
                    }
                    let payload = ClipboardRecorderPayload(recordID: record.id, kind: .url, text: url.normalizedURLString, urlString: url.normalizedURLString)
                    try storePayload(
                        payload,
                        forRecordID: record.id,
                        rollbackTracker: rollbackTracker
                    )
                    payloadForSearch = payload
                    summary = bounded(url.normalizedURLString, limit: 500)
                    formatSummary = formatSummaryForText(record.formatSummary, text: url.normalizedURLString, kind: .url)
                    changedFields.insert(.payload)

                case .richText:
                    guard record.kind == .richText, let existingPayload else {
                        throw ClipboardDetailSaveFailure.payloadMissing
                    }
                    let result = ClipboardRichTextFidelityService().updatedPayload(original: existingPayload, draftText: command.draft.text)
                    guard result.passed, let payload = result.payload else {
                        throw ClipboardDetailSaveFailure.richTextFidelityFailed
                    }
                    try storePayload(
                        payload,
                        forRecordID: record.id,
                        rollbackTracker: rollbackTracker
                    )
                    payloadForSearch = payload
                    summary = command.draft.text.isEmpty ? "Empty text" : bounded(command.draft.text, limit: 500)
                    formatSummary = formatSummaryForText(record.formatSummary, text: command.draft.text, kind: .richText)
                    changedFields.insert(.payload)

                case .imageOCRText:
                    guard record.kind == .image else {
                        throw ClipboardDetailSaveFailure.notEditable
                    }
                    summary = command.draft.text.isEmpty ? "No text recognized" : bounded(command.draft.text, limit: 500)
                    ocrText = command.draft.text
                    ocrState = .succeeded
                    ocrSource = .userEdited
                    ocrUserEditedAt = now
                    ocrLockedContentRevision = newContentRevision
                    changedFields.insert(.ocrText)
                }
            }

            if command.updatesPayload, command.editableKind != .imageOCRText {
                guard let payload = payloadForSearch,
                      let signature = ClipboardDetailPayloadSignature.canonicalSHA256(for: payload) else {
                    throw ClipboardDetailSaveFailure.payloadMissing
                }
                fullSignature = signature
                shortSignature = String(signature.prefix(12))
                changedFields.insert(.signature)
                if let conflictID = try detailEditRecordID(signature: signature), conflictID != record.id {
                    try deleteDetailEditConflict(recordID: conflictID)
                    deletedRecordID = conflictID
                    changedFields.insert(.conflictMerged)
                }
            }

            try updateRecordContentMetadata(
                record: record,
                summary: summary,
                formatSummary: formatSummary,
                contentRevision: newContentRevision,
                contentUpdatedAt: command.updatesPayload ? now : currentState.updatedAt,
                updatedAt: now,
                customTitle: customTitle,
                signatureSHA256: fullSignature,
                signatureSHA256_12: shortSignature
            )

            let updatedRecord = recordWithUpdatedDetail(
                record,
                summary: summary,
                formatSummary: formatSummary,
                customTitle: customTitle,
                signatureSHA256: fullSignature,
                signatureSHA256_12: shortSignature
            )
            let document = ClipboardSearchDocumentBuilder().build(
                record: updatedRecord,
                payload: command.editableKind == .imageOCRText ? existingPayload : payloadForSearch,
                tags: tagTokens,
                ocrText: ocrText,
                ocrState: ocrState,
                ocrTextSource: ocrSource,
                contentRevision: newContentRevision,
                updatedAt: now
            )
            let updatedDocument = command.updatesPayload && command.editableKind == .imageOCRText
                ? document.replacingOCR(
                    text: ocrText,
                    state: ocrState,
                    source: ocrSource,
                    userEditedAt: ocrUserEditedAt,
                    lockedContentRevision: ocrLockedContentRevision,
                    contentRevision: newContentRevision,
                    updatedAt: now
                )
                : document
            try upsertSearchDocument(updatedDocument)
            let readModel = try loadDetailReadModel(recordID: record.id)
            return (
                result: ClipboardDetailSaveResult(
                    recordID: record.id,
                    newContentRevision: newContentRevision,
                    contentUpdatedAt: command.updatesPayload ? now : currentState.updatedAt,
                    updatedPreview: updatedDocument.preview,
                    updatedDetailReadModel: readModel,
                    changedFields: changedFields,
                    mutationCount: changedFields.contains(.conflictMerged) ? 2 : 1
                ),
                deletedRecordID: deletedRecordID
            )
            }
            if let deletedRecordID = outcome.deletedRecordID {
                onCommittedDeletion([deletedRecordID])
            }
            _ = try? drainSidecarCleanupOutbox()
            return outcome.result
        } catch {
            let operationError = error
            try persistRolledBackSidecarCleanup(rollbackTracker.relativePaths)
            throw operationError
        }
    }

    func ignoredLateVisionCompletion(recordID: String) throws -> Bool {
        guard let document = try loadSearchDocument(recordID: recordID),
              document.ocrTextSource == .userEdited || document.ocrLockedContentRevision != nil else {
            return false
        }
        return true
    }
}

private extension ClipboardRepository {
    struct ContentState {
        let revision: Int64
        let updatedAt: Date
    }

    func loadContentState(recordID: String) throws -> ContentState {
        try database.connection.withStatement(
            """
            SELECT content_revision, COALESCE(content_updated_at, updated_at, created_at)
            FROM clipboard_items
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                throw ClipboardDetailSaveFailure.recordNotFound
            }
            return ContentState(
                revision: max(1, statement.columnInt64(0)),
                updatedAt: Date(timeIntervalSince1970: statement.columnDouble(1))
            )
        }
    }

    func metadataSnapshot(
        record: ClipboardRecorderRecord,
        contentRevision: Int64,
        contentUpdatedAt: Date,
        searchState: DetailSearchState?
    ) throws -> ClipboardMetadataSnapshot {
        let tags = try ClipboardTagRepository(repository: self).loadRecordTags(recordIDs: [record.id])[record.id] ?? []
        let lastCopiedAt = try loadLastCopiedAt(recordID: record.id)
        let sourceName = record.sourceApp?.localizedName ?? "Unknown source"
        var shortItems = [
            ClipboardMetadataItem(id: "kind", title: "Type", titleKey: "clipboard.detail.type", boundedValue: record.kind.rawValue),
            ClipboardMetadataItem(id: "created", title: "Created", titleKey: "clipboard.detail.created", boundedValue: isoString(record.createdAt)),
            ClipboardMetadataItem(
                id: "lastCopied",
                title: "Last copied",
                titleKey: "clipboard.detail.lastCopied",
                boundedValue: isoString(lastCopiedAt),
                fullValueAvailable: true,
                copyPurpose: .detailFullValueRead
            ),
            ClipboardMetadataItem(id: "updated", title: "Updated", titleKey: "clipboard.detail.updated", boundedValue: isoString(contentUpdatedAt)),
            ClipboardMetadataItem(id: "revision", title: "Content revision", titleKey: "clipboard.detail.revision", boundedValue: String(contentRevision)),
            ClipboardMetadataItem(id: "source", title: "Source", titleKey: "clipboard.detail.source", boundedValue: bounded(sourceName, limit: 80), fullValueAvailable: true, category: sourceName.count > 80 ? .conditionalShort : .short, copyPurpose: .detailFullValueRead),
            ClipboardMetadataItem(id: "sourceConfidence", title: "Source confidence", titleKey: "clipboard.detail.sourceConfidence", boundedValue: record.sourceApp?.sourceAppIsCandidate == true ? "Best effort" : "Verified"),
            ClipboardMetadataItem(id: "ocr", title: "OCR", titleKey: "clipboard.detail.ocr", boundedValue: ocrMetadataValue(searchState)),
            ClipboardMetadataItem(id: "privacy", title: "Privacy", titleKey: "clipboard.detail.privacy", boundedValue: privacyMetadataValue(record)),
            ClipboardMetadataItem(id: "tags", title: "Tags", titleKey: "clipboard.detail.tags", boundedValue: String(tags.count))
        ]

        if !record.signatureSHA256_12.isEmpty {
            shortItems.append(ClipboardMetadataItem(id: "signatureShort", title: "Hash", titleKey: "clipboard.detail.hash", boundedValue: record.signatureSHA256_12))
        }

        var longItems: [ClipboardMetadataItem] = []
        if record.kind == .url, let value = optionalNonEmpty(record.summary) {
            longItems.append(longMetadataItem(
                id: "url",
                title: "URL",
                titleKey: "clipboard.detail.url",
                value: value
            ))
        }
        if record.kind == .fileURL, let value = optionalNonEmpty(record.summary) {
            longItems.append(longMetadataItem(
                id: "fileURL",
                title: "File URL",
                titleKey: "clipboard.detail.fileURL",
                value: value
            ))
        }
        if let bundleIdentifier = optionalNonEmpty(record.sourceApp?.bundleIdentifier) {
            longItems.append(longMetadataItem(id: "bundleIdentifier", title: "Bundle identifier", titleKey: "clipboard.detail.bundleIdentifier", value: bundleIdentifier))
        }
        if let bundlePathSummary = optionalNonEmpty(record.sourceApp?.bundlePathSummary) {
            longItems.append(longMetadataItem(id: "bundlePathSummary", title: "Bundle path", titleKey: "clipboard.detail.bundlePath", value: bundlePathSummary))
        }
        if let bundlePathHash = optionalNonEmpty(record.sourceApp?.bundlePathHash) {
            longItems.append(longMetadataItem(id: "bundlePathHash", title: "Bundle path hash", titleKey: "clipboard.detail.bundlePathHash", value: bundlePathHash))
        }
        if let signatureHash = optionalNonEmpty(record.signatureSHA256) {
            longItems.append(longMetadataItem(id: "signatureHash", title: "Payload hash", titleKey: "clipboard.detail.payloadHash", value: signatureHash))
        }

        return ClipboardMetadataSnapshot(items: shortItems + longItems)
    }

    func editability(record: ClipboardRecorderRecord) -> ClipboardDetailEditability {
        guard record.restorable, !record.excluded, !record.snapshotSkipped else {
            return .readOnly(reason: "record unavailable")
        }
        switch record.kind {
        case .text:
            return .editable(.plainText)
        case .url:
            return .editable(.url)
        case .richText:
            return .editable(.richText)
        case .image:
            return .editable(.imageOCRText)
        case .fileURL, .mixed, .unknown:
            return .readOnly(reason: "content type is read only")
        }
    }

    func tagTokens(recordID: String) throws -> [String] {
        let tags = try ClipboardTagRepository(repository: self).loadRecordTags(recordIDs: [recordID])[recordID] ?? []
        return tags.flatMap { [$0.displayName, $0.normalizedName] }
    }

    func updateRecordContentMetadata(
        record: ClipboardRecorderRecord,
        summary: String,
        formatSummary: ClipboardRecorderFormatSummary,
        contentRevision: Int64,
        contentUpdatedAt: Date,
        updatedAt: Date,
        customTitle: String?,
        signatureSHA256: String,
        signatureSHA256_12: String
    ) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(formatSummary)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try database.connection.withStatement(
            """
            UPDATE clipboard_items
            SET summary = ?,
                format_summary_json = ?,
                updated_at = ?,
                content_updated_at = ?,
                content_revision = ?,
                custom_title = ?,
                signature_sha256 = ?,
                signature_sha256_12 = ?
            WHERE id = ?
            """,
            bindings: [
                .string(summary),
                .string(json),
                .double(updatedAt.timeIntervalSince1970),
                .double(contentUpdatedAt.timeIntervalSince1970),
                .int64(max(1, contentRevision)),
                customTitle.map(SQLiteBinding.string) ?? .null,
                .string(signatureSHA256),
                .string(signatureSHA256_12),
                .string(record.id)
            ]
        ) { statement in
            _ = try statement.step()
        }
    }

    func recordWithUpdatedDetail(
        _ record: ClipboardRecorderRecord,
        summary: String,
        formatSummary: ClipboardRecorderFormatSummary,
        customTitle: String?,
        signatureSHA256: String,
        signatureSHA256_12: String
    ) -> ClipboardRecorderRecord {
        ClipboardRecorderRecord(
            id: record.id,
            createdAt: record.createdAt,
            changeCount: record.changeCount,
            kind: record.kind,
            formatSummary: formatSummary,
            sourceApp: record.sourceApp,
            signatureSHA256: signatureSHA256,
            signatureSHA256_12: signatureSHA256_12,
            fixtureOwned: record.fixtureOwned,
            pinned: record.pinned,
            restorable: record.restorable,
            excluded: record.excluded,
            snapshotSkipped: record.snapshotSkipped,
            customTitle: customTitle,
            lastCopiedAt: record.lastCopiedAt,
            summary: summary,
            origin: record.origin
        )
    }

    func deleteDetailEditConflict(recordID: String) throws {
        try enqueueSidecarCleanup(try sidecarPaths(recordIDs: [recordID]))
        try replaceFTS(recordID: recordID, searchText: nil)
        try database.connection.withStatement(
            "DELETE FROM clipboard_items WHERE id = ?",
            bindings: [.string(recordID)]
        ) { statement in
            _ = try statement.step()
        }
    }

    func detailEditRecordID(signature: String) throws -> String? {
        try database.connection.firstString(
            "SELECT id FROM clipboard_items WHERE signature_sha256 = ? LIMIT 1",
            bindings: [.string(signature)]
        )
    }

    func formatSummaryForText(
        _ existing: ClipboardRecorderFormatSummary,
        text: String,
        kind: ClipboardRecorderItemKind
    ) -> ClipboardRecorderFormatSummary {
        ClipboardRecorderFormatSummary(
            itemCount: existing.itemCount,
            types: existing.types.isEmpty ? [kind.rawValue] : existing.types,
            textLength: text.count,
            byteCount: text.utf8.count,
            fileCount: nil,
            urlCount: kind == .url ? 1 : existing.urlCount
        )
    }

    func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(max(1, limit - 3))) + "..."
    }

    func loadLastCopiedAt(recordID: String) throws -> Date {
        try database.connection.withStatement(
            """
            SELECT COALESCE(last_copied_at, created_at)
            FROM clipboard_items
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                throw ClipboardDetailSaveFailure.recordNotFound
            }
            return Date(timeIntervalSince1970: statement.columnDouble(0))
        }
    }

    func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func longMetadataItem(id: String, title: String, titleKey: String, value: String) -> ClipboardMetadataItem {
        ClipboardMetadataItem(
            id: id,
            title: title,
            titleKey: titleKey,
            boundedValue: bounded(value, limit: 120),
            // Long metadata may be visually truncated even when its character
            // count is below the repository's bounded-value threshold. Keep
            // the explicit full-value action available for every long field.
            fullValueAvailable: true,
            category: .long,
            copyPurpose: .detailFullValueRead
        )
    }

    func optionalNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func ocrMetadataValue(_ searchState: DetailSearchState?) -> String {
        let state = (searchState?.ocrState ?? .notRequired).rawValue
        let source = (searchState?.ocrTextSource ?? .none).rawValue
        return source == ClipboardOCRTextSource.none.rawValue ? state : "\(state) / \(source)"
    }

    func loadDetailSearchState(recordID: String) throws -> DetailSearchState? {
        try database.connection.withStatement(
            """
            SELECT ocr_status, ocr_text_source, updated_at
            FROM clipboard_search_documents
            WHERE record_id = ?
            LIMIT 1
            """,
            bindings: [.string(recordID)]
        ) { statement in
            guard try statement.step() else {
                return nil
            }
            return DetailSearchState(
                ocrState: ClipboardOCRState(rawValue: statement.columnString(0) ?? "") ?? .notRequired,
                ocrTextSource: ClipboardOCRTextSource(rawValue: statement.columnString(1) ?? "") ?? .none,
                updatedAt: Date(timeIntervalSince1970: statement.columnDouble(2))
            )
        }
    }

    func privacyMetadataValue(_ record: ClipboardRecorderRecord) -> String {
        if record.excluded {
            return "Excluded"
        }
        if record.snapshotSkipped {
            return "Snapshot skipped"
        }
        if !record.restorable {
            return "Not restorable"
        }
        return "Allowed"
    }
}

private struct DetailSearchState {
    let ocrState: ClipboardOCRState
    let ocrTextSource: ClipboardOCRTextSource
    let updatedAt: Date
}
