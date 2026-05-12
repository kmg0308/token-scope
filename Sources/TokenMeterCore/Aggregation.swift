import Foundation

public enum TimeRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last12Hours = "12h"
    case last24Hours = "24h"
    case last7Days = "7d"
    case last30Days = "30d"
    case last3Months = "3m"
    case last6Months = "6m"
    case last12Months = "12m"
    case all = "All"

    public var id: String { rawValue }

    public static let dashboardCases: [TimeRangePreset] = [
        .today,
        .last12Hours,
        .last24Hours,
        .last7Days,
        .last30Days,
        .last3Months,
        .last6Months,
        .last12Months
    ]

    public func interval(now: Date = Date(), calendar: Calendar = .current, earliest: Date? = nil) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return DateInterval(start: start, end: today)
        case .last12Hours:
            return DateInterval(start: now.addingTimeInterval(-12 * 60 * 60), end: now)
        case .last24Hours:
            return DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        case .last7Days:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            return DateInterval(start: start, end: now)
        case .last30Days:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return DateInterval(start: start, end: now)
        case .last3Months:
            return DateInterval(start: calendar.date(byAdding: .month, value: -3, to: now) ?? now, end: now)
        case .last6Months:
            return DateInterval(start: calendar.date(byAdding: .month, value: -6, to: now) ?? now, end: now)
        case .last12Months:
            return DateInterval(start: calendar.date(byAdding: .month, value: -12, to: now) ?? now, end: now)
        case .all:
            return DateInterval(start: earliest ?? Date(timeIntervalSince1970: 0), end: now)
        }
    }
}

public enum BucketInterval: String, CaseIterable, Identifiable, Sendable {
    case minute = "1m"
    case hour = "1h"
    case day = "1d"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minute: "By Minute"
        case .hour: "Hourly"
        case .day: "Daily"
        }
    }

    public static func dashboardCases(for range: TimeRangePreset) -> [BucketInterval] {
        switch range {
        case .today, .last12Hours:
            [.minute, .hour, .day]
        case .yesterday, .last24Hours, .last7Days, .last30Days:
            [.hour, .day]
        case .all:
            [.day]
        case .last3Months, .last6Months, .last12Months:
            [.day]
        }
    }
}

public enum Aggregation {
    public static func filter(
        events: [TokenEvent],
        source: TokenSource,
        range: TimeRangePreset,
        project: String?,
        model: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TokenEvent] {
        let earliest = events.first?.timestamp
        let interval = range.interval(now: now, calendar: calendar, earliest: earliest)
        return events.filter { event in
            let sourceMatches = source == .all || event.source == source
            let timeMatches = event.timestamp >= interval.start && event.timestamp <= interval.end
            let projectMatches = project == nil || project == "All Projects" || event.projectPath == project
            let modelMatches = model == nil || model == "All Models" || event.model == model
            return sourceMatches && timeMatches && projectMatches && modelMatches
        }
    }

    public static func totalUsage(events: [TokenEvent]) -> TokenUsage {
        events.reduce(.zero) { $0.adding($1.usage) }
    }

    public static func buckets(
        events: [TokenEvent],
        bucket: BucketInterval,
        calendar: Calendar = .current
    ) -> [TimeBucket] {
        var grouped: [Date: [TokenSource: TokenUsage]] = [:]

        for event in events {
            let start = bucketStart(for: event.timestamp, interval: bucket, calendar: calendar)
            var sourceUsage = grouped[start, default: [:]]
            sourceUsage[event.source] = (sourceUsage[event.source] ?? .zero).adding(event.usage)
            grouped[start] = sourceUsage
        }

        return grouped.keys.sorted().map { start in
            let sourceUsage = grouped[start] ?? [:]
            let usage = sourceUsage.values.reduce(TokenUsage.zero) { $0.adding($1) }
            return TimeBucket(start: start, usage: usage, sourceUsage: sourceUsage)
        }
    }

    public static func grouped(
        events: [TokenEvent],
        by keyPath: KeyPath<TokenEvent, String>,
        source: TokenSource = .all
    ) -> [GroupedUsageRow] {
        var rows: [String: GroupedUsageRow] = [:]
        for event in events {
            let key = event[keyPath: keyPath]
            let existing = rows[key]
            rows[key] = GroupedUsageRow(
                key: key,
                source: source == .all ? event.source : source,
                usage: (existing?.usage ?? .zero).adding(event.usage),
                count: (existing?.count ?? 0) + 1,
                lastActive: max(existing?.lastActive ?? event.timestamp, event.timestamp)
            )
        }
        return rows.values.sorted { $0.usage.total > $1.usage.total }
    }

    private static func bucketStart(for date: Date, interval: BucketInterval, calendar: Calendar) -> Date {
        switch interval {
        case .minute:
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return calendar.date(from: components) ?? date
        case .hour:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: components) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}
