import Foundation
import BlocksCore

enum ClipboardFormatFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case richText
    case image
    case url
    case fileURL
    case mixed
    case excluded

    var id: String { rawValue }

    init(recordKind: ClipboardRecorderItemKind) {
        switch recordKind {
        case .text:
            self = .text
        case .richText:
            self = .richText
        case .image:
            self = .image
        case .url:
            self = .url
        case .fileURL:
            self = .fileURL
        case .mixed:
            self = .mixed
        case .unknown:
            self = .all
        }
    }

    var localizedTitle: String {
        switch self {
        case .all:
            L10n.string("clipboard.filter.all")
        case .text:
            L10n.string("clipboard.kind.text")
        case .richText:
            L10n.string("clipboard.kind.richText")
        case .image:
            L10n.string("clipboard.kind.image")
        case .url:
            L10n.string("clipboard.kind.url")
        case .fileURL:
            L10n.string("clipboard.kind.fileURL")
        case .mixed:
            L10n.string("clipboard.kind.mixed")
        case .excluded:
            L10n.string("clipboard.filter.excluded")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "square.grid.2x2"
        case .text:
            "text.alignleft"
        case .richText:
            "textformat"
        case .image:
            "photo"
        case .url:
            "link"
        case .fileURL:
            "doc"
        case .mixed:
            "square.stack.3d.up"
        case .excluded:
            "eye.slash"
        }
    }

    func matches(_ record: ClipboardRecorderRecord) -> Bool {
        switch self {
        case .all:
            true
        case .excluded:
            record.excluded || record.snapshotSkipped
        case .text:
            record.kind == .text && !record.excluded
        case .richText:
            record.kind == .richText && !record.excluded
        case .image:
            record.kind == .image && !record.excluded
        case .url:
            record.kind == .url && !record.excluded
        case .fileURL:
            record.kind == .fileURL && !record.excluded
        case .mixed:
            record.kind == .mixed && !record.excluded
        }
    }
}

enum ClipboardTimeFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case yesterday
    case dayBeforeYesterday
    case recentThreeDays
    case recentWeek
    case lastWeek

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all:
            L10n.string("clipboard.filter.all")
        case .today:
            L10n.string("clipboard.filter.today")
        case .yesterday:
            L10n.string("clipboard.filter.yesterday")
        case .dayBeforeYesterday:
            L10n.string("clipboard.filter.dayBeforeYesterday")
        case .recentThreeDays:
            L10n.string("clipboard.filter.recentThreeDays")
        case .recentWeek:
            L10n.string("clipboard.filter.recentWeek")
        case .lastWeek:
            L10n.string("clipboard.filter.lastWeek")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "clock"
        case .today:
            "sun.max"
        case .yesterday:
            "1.circle"
        case .dayBeforeYesterday:
            "2.circle"
        case .recentThreeDays:
            "3.circle"
        case .recentWeek:
            "7.circle"
        case .lastWeek:
            "calendar.badge.clock"
        }
    }

    func matches(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .yesterday:
            return calendar.isDateInYesterday(date)
        case .dayBeforeYesterday:
            guard let target = calendar.date(byAdding: .day, value: -2, to: now) else {
                return false
            }
            return calendar.isDate(date, inSameDayAs: target)
        case .recentThreeDays:
            guard let cutoff = calendar.date(byAdding: .day, value: -3, to: now) else {
                return false
            }
            return date >= cutoff
        case .recentWeek:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now) else {
                return false
            }
            return date >= cutoff
        case .lastWeek:
            guard
                let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                let previousWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start),
                let previousWeek = calendar.dateInterval(of: .weekOfYear, for: previousWeekStart)
            else {
                return false
            }
            return previousWeek.contains(date)
        }
    }
}

enum ClipboardFilterGroup: String, CaseIterable, Identifiable {
    case format
    case time
    case source

    var id: String { rawValue }

    static let nonTagCases: [ClipboardFilterGroup] = [.format, .time, .source]

    var localizedTitle: String {
        switch self {
        case .format:
            L10n.string("clipboard.filter.format")
        case .time:
            L10n.string("clipboard.filter.time")
        case .source:
            L10n.string("clipboard.filter.source")
        }
    }

    var systemImage: String {
        switch self {
        case .format:
            "square.grid.2x2"
        case .time:
            "clock"
        case .source:
            "app.badge"
        }
    }
}

struct ClipboardFilterAccessibilityPresentation: Equatable {
    let label: String
    let value: String
    let help: String

    static func resolve(
        group: ClipboardFilterGroup,
        activeTitle: String?,
        isExpanded: Bool
    ) -> ClipboardFilterAccessibilityPresentation {
        ClipboardFilterAccessibilityPresentation(
            label: group.localizedTitle,
            value: activeTitle ?? L10n.string("clipboard.filter.all"),
            help: L10n.format(
                isExpanded
                    ? "clipboard.filter.accessibility.collapse"
                    : "clipboard.filter.accessibility.expand",
                group.localizedTitle
            )
        )
    }
}

enum ClipboardFilterClearDelay: String, CaseIterable, Identifiable {
    case immediately
    case seconds15
    case seconds30
    case minute1
    case never

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .immediately:
            L10n.string("clipboard.filter.clear.immediately")
        case .seconds15:
            L10n.string("clipboard.filter.clear.seconds15")
        case .seconds30:
            L10n.string("clipboard.filter.clear.seconds30")
        case .minute1:
            L10n.string("clipboard.filter.clear.minute1")
        case .never:
            L10n.string("clipboard.filter.clear.never")
        }
    }

    var delaySeconds: TimeInterval? {
        switch self {
        case .immediately:
            0
        case .seconds15:
            15
        case .seconds30:
            30
        case .minute1:
            60
        case .never:
            nil
        }
    }
}

enum ClipboardSourceFilterKey: Hashable, Identifiable {
    case bundleIdentifier(String)
    case sourceIdentity(String)

    var id: String {
        switch self {
        case .bundleIdentifier(let value):
            "bundle:\(value)"
        case .sourceIdentity(let value):
            "source:\(value)"
        }
    }

    var bundleIdentifier: String? {
        guard case .bundleIdentifier(let value) = self else {
            return nil
        }
        return value
    }

    static func recordKey(_ record: ClipboardRecorderRecord) -> ClipboardSourceFilterKey {
        if let bundleIdentifier = normalized(record.sourceApp?.bundleIdentifier) {
            return .bundleIdentifier(bundleIdentifier)
        }
        if let pathHash = normalized(record.sourceApp?.bundlePathHash) {
            return .sourceIdentity("path:\(pathHash)")
        }
        if let name = normalized(record.sourceApp?.localizedName) {
            return .sourceIdentity("name:\(name.lowercased())")
        }
        return .sourceIdentity("unknown")
    }

    func matches(_ record: ClipboardRecorderRecord) -> Bool {
        Self.recordKey(record) == self
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ClipboardFilterState: Equatable {
    var format: ClipboardFormatFilter = .all
    var time: ClipboardTimeFilter = .all
    var selectedTagID: String?
    var sourceFilterKey: ClipboardSourceFilterKey?

    var hasActiveFilters: Bool {
        format != .all || time != .all || selectedTagID != nil || sourceFilterKey != nil
    }

    mutating func clear() {
        format = .all
        time = .all
        selectedTagID = nil
        sourceFilterKey = nil
    }
}
