import Foundation
import BlocksCore

enum ClipboardController {
    static func restorableCount(in records: [ClipboardRecorderRecord]) -> Int {
        records.filter(\.restorable).count
    }

    static func excludedCount(in records: [ClipboardRecorderRecord]) -> Int {
        records.filter(\.excluded).count
    }

    static func activeFilterCount(_ filterState: ClipboardFilterState) -> Int {
        [
            filterState.format != .all,
            filterState.time != .all,
            filterState.selectedTagID != nil,
            filterState.sourceFilterKey != nil
        ].filter { $0 }.count
    }

    static func sourceFilterOptions(from records: [ClipboardRecorderRecord]) -> [ClipboardSourceFilterOption] {
        let grouped = Dictionary(grouping: records, by: ClipboardSourceFilterKey.recordKey)
        return grouped.map { key, records in
            let first = records.first
            return ClipboardSourceFilterOption(
                key: key,
                bundleIdentifier: first?.sourceApp?.bundleIdentifier,
                displayName: first?.sourceDisplayName ?? L10n.string("clipboard.sourceUnknown"),
                eventCount: records.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.eventCount == rhs.eventCount {
                return lhs.displayName < rhs.displayName
            }
            return lhs.eventCount > rhs.eventCount
        }
    }

    static func ingestLiveCapture(
        _ decision: ClipboardCapturePolicyDecision,
        records: inout [ClipboardRecorderRecord],
        payloads: inout [String: ClipboardRecorderPayload]
    ) -> Bool {
        let record = decision.record
        if let existingIndex = records.firstIndex(where: {
            $0.id == record.id || $0.changeCount == record.changeCount
        }) {
            let existingRecord = records[existingIndex]
            guard existingRecord.excluded,
                  !decision.skipped,
                  let payload = decision.payload else {
                return false
            }
            payloads[payload.recordID] = payload
            records.remove(at: existingIndex)
            records.insert(record.replacing(lastCopiedAt: record.createdAt), at: 0)
            return true
        }
        if let existingIndex = records.firstIndex(where: { $0.signatureSHA256 == record.signatureSHA256 }) {
            guard !decision.skipped else {
                return false
            }
            let existingRecord = records.remove(at: existingIndex).replacing(lastCopiedAt: record.createdAt)
            records.insert(existingRecord, at: 0)
            return true
        }
        if decision.skipped {
            records.insert(record, at: 0)
            return true
        }
        guard let payload = decision.payload else {
            return false
        }
        payloads[payload.recordID] = payload
        records.insert(record, at: 0)
        return true
    }
}
