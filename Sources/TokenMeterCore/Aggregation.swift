import Foundation

public enum TimeRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30Minutes = "30m"
    case last1Hour = "1h"
    case last3Hours = "3h"
    case last6Hours = "6h"
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
        .last30Minutes,
        .last1Hour,
        .last3Hours,
        .last6Hours,
        .last12Hours,
        .last24Hours,
        .today,
        .yesterday,
        .last7Days,
        .last30Days,
        .last3Months,
        .last6Months,
        .last12Months,
        .all
    ]

    public func interval(
        now: Date = Date(),
        calendar: Calendar = .current,
        earliest: Date? = nil,
        latest: Date? = nil
    ) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .yesterday:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return DateInterval(start: start, end: today)
        case .last30Minutes:
            return DateInterval(start: now.addingTimeInterval(-30 * 60), end: now)
        case .last1Hour:
            return DateInterval(start: now.addingTimeInterval(-60 * 60), end: now)
        case .last3Hours:
            return DateInterval(start: now.addingTimeInterval(-3 * 60 * 60), end: now)
        case .last6Hours:
            return DateInterval(start: now.addingTimeInterval(-6 * 60 * 60), end: now)
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
            let start = earliest ?? latest ?? Date(timeIntervalSince1970: 0)
            let end = latest ?? now
            return DateInterval(start: min(start, end), end: max(start, end))
        }
    }

    public func previousInterval(
        now: Date = Date(),
        calendar: Calendar = .current,
        earliest: Date? = nil,
        latest: Date? = nil
    ) -> DateInterval {
        let current = interval(now: now, calendar: calendar, earliest: earliest, latest: latest)

        switch self {
        case .today:
            let previousStart = calendar.date(byAdding: .day, value: -1, to: current.start) ?? current.start.addingTimeInterval(-current.duration)
            let previousEnd = calendar.date(byAdding: .second, value: Int(current.duration), to: previousStart) ?? current.start
            return DateInterval(start: previousStart, end: min(previousEnd, current.start))
        case .yesterday:
            let previousStart = calendar.date(byAdding: .day, value: -1, to: current.start) ?? current.start.addingTimeInterval(-current.duration)
            return DateInterval(start: previousStart, end: current.start)
        case .all:
            return DateInterval(start: current.start, end: current.start)
        default:
            return DateInterval(start: current.start.addingTimeInterval(-current.duration), end: current.start)
        }
    }

}

public enum BucketInterval: String, CaseIterable, Identifiable, Sendable {
    case minute = "1m"
    case fiveMinutes = "5m"
    case tenMinutes = "10m"
    case twentyMinutes = "20m"
    case thirtyMinutes = "30m"
    case hour = "1h"
    case day = "1d"
    case week = "1w"
    case month = "1mo"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minute: "1 min"
        case .fiveMinutes: "5 min"
        case .tenMinutes: "10 min"
        case .twentyMinutes: "20 min"
        case .thirtyMinutes: "30 min"
        case .hour: "Hourly"
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        }
    }

    public static let dashboardCases: [BucketInterval] = [
        .minute,
        .fiveMinutes,
        .tenMinutes,
        .twentyMinutes,
        .thirtyMinutes,
        .hour,
        .day,
        .week,
        .month
    ]

    public static func dashboardCases(for range: TimeRangePreset) -> [BucketInterval] {
        dashboardCases
    }

    public func start(for date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .minute:
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return calendar.date(from: components) ?? date
        case .fiveMinutes:
            return Self.minuteBucket(date, size: 5, calendar: calendar)
        case .tenMinutes:
            return Self.minuteBucket(date, size: 10, calendar: calendar)
        case .twentyMinutes:
            return Self.minuteBucket(date, size: 20, calendar: calendar)
        case .thirtyMinutes:
            return Self.minuteBucket(date, size: 30, calendar: calendar)
        case .hour:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            return calendar.date(from: components) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? date
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? date
        }
    }

    public func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .minute:
            return calendar.date(byAdding: .minute, value: 1, to: date)
        case .fiveMinutes:
            return calendar.date(byAdding: .minute, value: 5, to: date)
        case .tenMinutes:
            return calendar.date(byAdding: .minute, value: 10, to: date)
        case .twentyMinutes:
            return calendar.date(byAdding: .minute, value: 20, to: date)
        case .thirtyMinutes:
            return calendar.date(byAdding: .minute, value: 30, to: date)
        case .hour:
            return calendar.date(byAdding: .hour, value: 1, to: date)
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }

    private static func minuteBucket(_ date: Date, size: Int, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = ((components.minute ?? 0) / size) * size
        return calendar.date(from: components) ?? date
    }
}

public struct TokenFilterSelection: Equatable, Sendable {
    public var project: String?
    public var model: String?

    public init(project: String?, model: String?) {
        self.project = project
        self.model = model
    }
}

public enum Aggregation {
    public static func filter(
        events: [TokenEvent],
        source: TokenSource,
        range: TimeRangePreset,
        project: String?,
        model: String?,
        deviceId: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TokenEvent] {
        let interval = range == .all
            ? nil
            : range.interval(now: now, calendar: calendar, earliest: nil)
        return events.filter { event in
            let sourceMatches = source == .all || event.source == source
            let timeMatches = interval.map { contains(event.timestamp, in: $0) } ?? true
            let projectMatches = project == nil || event.projectPath == project
            let modelMatches = model == nil || event.model == model
            let deviceMatches = deviceId == nil || event.deviceId == deviceId
            return sourceMatches && timeMatches && projectMatches && modelMatches && deviceMatches
        }
    }

    public static func filter(
        events: [TokenEvent],
        source: TokenSource,
        interval: DateInterval,
        project: String?,
        model: String?,
        deviceId: String? = nil
    ) -> [TokenEvent] {
        events.filter { event in
            let sourceMatches = source == .all || event.source == source
            let timeMatches = contains(event.timestamp, in: interval)
            let projectMatches = project == nil || event.projectPath == project
            let modelMatches = model == nil || event.model == model
            let deviceMatches = deviceId == nil || event.deviceId == deviceId
            return sourceMatches && timeMatches && projectMatches && modelMatches && deviceMatches
        }
    }

    public static func totalUsage(events: [TokenEvent]) -> TokenUsage {
        events.reduce(.zero) { $0.adding($1.usage) }
    }

    public static func normalizedFilters(
        events: [TokenEvent],
        source: TokenSource,
        range: TimeRangePreset,
        project: String?,
        model: String?,
        deviceId: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TokenFilterSelection {
        let baseEvents = filter(
            events: events,
            source: source,
            range: range,
            project: nil,
            model: nil,
            deviceId: deviceId,
            now: now,
            calendar: calendar
        )
        var normalizedProject = project
        var normalizedModel = model

        if let model, !baseEvents.contains(where: { $0.model == model }) {
            normalizedModel = nil
        }
        if let project, !baseEvents.contains(where: { event in
            event.projectPath == project && (normalizedModel == nil || event.model == normalizedModel)
        }) {
            normalizedProject = nil
        }
        if let model = normalizedModel, !baseEvents.contains(where: { event in
            event.model == model && (normalizedProject == nil || event.projectPath == normalizedProject)
        }) {
            normalizedModel = nil
        }

        return TokenFilterSelection(project: normalizedProject, model: normalizedModel)
    }

    public static func buckets(
        events: [TokenEvent],
        bucket: BucketInterval,
        calendar: Calendar = .current
    ) -> [TimeBucket] {
        var grouped: [Date: [TokenSource: TokenUsage]] = [:]

        for event in events {
            let start = bucket.start(for: event.timestamp, calendar: calendar)
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

    public static func filledBuckets(
        buckets: [TimeBucket],
        range: TimeRangePreset,
        bucket: BucketInterval,
        interval rangeInterval: DateInterval,
        maxCount: Int,
        calendar: Calendar = .current
    ) -> [TimeBucket] {
        guard !buckets.isEmpty, maxCount > 0 else { return [] }

        let start = bucket.start(for: rangeInterval.start, calendar: calendar)
        let end = bucket.start(for: rangeInterval.end, calendar: calendar)
        let includeEndBucket = range == .all || end < rangeInterval.end
        var existing: [Date: TimeBucket] = [:]
        for bucket in buckets {
            existing[bucket.start] = bucket
        }

        var result: [TimeBucket] = []
        var current = start

        while shouldIncludeBucket(current, end: end, includeEndBucket: includeEndBucket),
              result.count < maxCount {
            result.append(existing[current] ?? TimeBucket(start: current, usage: .zero, sourceUsage: [:]))
            guard let next = bucket.nextStart(after: current, calendar: calendar),
                  next > current else {
                break
            }
            current = next
        }

        return result
    }

    public static func grouped(
        events: [TokenEvent],
        by keyPath: KeyPath<TokenEvent, String>
    ) -> [GroupedUsageRow] {
        var rows: [String: GroupedUsageRow] = [:]
        for event in events {
            let key = event[keyPath: keyPath]
            let existing = rows[key]
            rows[key] = GroupedUsageRow(
                key: key,
                usage: (existing?.usage ?? .zero).adding(event.usage),
                count: (existing?.count ?? 0) + 1,
                lastActive: max(existing?.lastActive ?? event.timestamp, event.timestamp)
            )
        }
        return rows.values.sorted {
            if $0.usage.total != $1.usage.total {
                return $0.usage.total > $1.usage.total
            }
            if $0.lastActive != $1.lastActive {
                return $0.lastActive > $1.lastActive
            }
            return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }
    }

    private static func contains(_ timestamp: Date, in interval: DateInterval) -> Bool {
        timestamp >= interval.start && timestamp < interval.end
    }

    private static func shouldIncludeBucket(_ current: Date, end: Date, includeEndBucket: Bool) -> Bool {
        current < end || (includeEndBucket && current == end)
    }
}
