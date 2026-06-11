import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runAggregationTests() throws {
        try tokenUsageDisplayComponentsAvoidDoubleCounting()
        try tokenUsageClampsComponentsBeforeComputingTotal()
        try tokenUsageClampsCachedInputToInput()
        try tokenUsageDisplayComponentsSaturateCacheBuckets()
        try tokenUsageAdditionSaturatesInsteadOfOverflowing()
        try tokenUsageDecodingNormalizesStoredValues()
        try tokenEventDecodingNormalizesStoredStrings()
        try tokenFormatterHandlesMinimumInteger()
        try relativeDayRangesIncludeToday()
        try previousRangesMatchCurrentDuration()
        try rangeFilteringUsesExclusiveEndBoundary()
        try filledBucketsExcludeExclusiveEndBoundary()
        try filledBucketsKeepAllRangeSingleDataPoint()
        try dashboardRangesExposeShortOptions()
        try fiveMinuteBucketsRoundDown()
        try aggregationAllRangeUsesEarliestTimestampWhenEventsAreUnsorted()
        try aggregationAllRangeIncludesFutureEventsWithoutReversedInterval()
        try aggregationAllRangeUsesProvidedDataSpan()
        try aggregationAllRangeDoesNotAppendEmptyTimeForSingleDataPoint()
        try aggregationTreatsDashboardLabelsAsLiteralFilters()
        try aggregationGroupedRowsUseStableTieBreakers()
        try aggregationNormalizesDependentFiltersWithoutDroppingValidChoices()
        try dashboardBucketOptionsStayReadable()
    }

    static func tokenUsageDisplayComponentsAvoidDoubleCounting() throws {
        let usage = TokenUsage(
            input: 100,
            cachedInput: 40,
            cacheCreation: 10,
            cacheRead: 20,
            output: 50,
            reasoning: 15
        )
        let components = Dictionary(
            uniqueKeysWithValues: usage.displayComponents(source: .all).map { ($0.kind, $0.value) }
        )

        try expect(components[.input] == 60, "display components subtract cached Codex input")
        try expect(components[.cache] == 70, "display components merge all cache buckets")
        try expect(components[.output] == 35, "display components subtract reasoning output")
        try expect(components[.reasoning] == 15, "display components keep reasoning visible")
        try expect(components.values.reduce(0, +) == usage.total, "display components sum to total")
    }

    static func tokenUsageClampsComponentsBeforeComputingTotal() throws {
        let usage = TokenUsage(input: -100, cacheCreation: 2, cacheRead: 3, output: 5)

        try expect(usage.input == 0, "TokenUsage clamps negative input")
        try expect(usage.total == 10, "TokenUsage computes implicit total from normalized components")
    }

    static func tokenUsageClampsCachedInputToInput() throws {
        let usage = TokenUsage(input: 10, cachedInput: 50, output: 5)
        let components = Dictionary(
            uniqueKeysWithValues: usage.displayComponents(source: .codex).map { ($0.kind, $0.value) }
        )

        try expect(usage.cachedInput == 10, "TokenUsage clamps cached input to input")
        try expect(components[.input] == nil, "TokenUsage does not create negative plain input")
        try expect(components[.cache] == 10, "TokenUsage keeps cache within total input")
        try expect(components[.output] == 5, "TokenUsage keeps output component")
    }

    static func tokenUsageDisplayComponentsSaturateCacheBuckets() throws {
        let usage = TokenUsage(
            input: Int.max,
            cachedInput: Int.max,
            cacheCreation: Int.max,
            cacheRead: Int.max
        )
        let cache = usage.displayComponents(source: .all).first { $0.kind == .cache }?.value

        try expect(cache == Int.max, "TokenUsage display cache component saturates")
    }

    static func tokenUsageAdditionSaturatesInsteadOfOverflowing() throws {
        let computedTotal = TokenUsage(input: Int.max, output: 1)
        let addedTotal = TokenUsage(total: Int.max).adding(TokenUsage(total: 1))

        try expect(computedTotal.total == Int.max, "TokenUsage implicit total saturates")
        try expect(addedTotal.total == Int.max, "TokenUsage added total saturates")
    }

    static func tokenUsageDecodingNormalizesStoredValues() throws {
        let data = """
        {"input":-100,"cachedInput":-1,"cacheCreation":2,"cacheRead":3,"output":5,"reasoning":-2,"total":-1}
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(TokenUsage.self, from: data)
        try expect(usage.input == 0, "decoded TokenUsage clamps input")
        try expect(usage.cachedInput == 0, "decoded TokenUsage clamps cached input")
        try expect(usage.reasoning == 0, "decoded TokenUsage clamps reasoning")
        try expect(usage.total == 10, "decoded TokenUsage recomputes invalid stored total")
    }

    static func tokenEventDecodingNormalizesStoredStrings() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let original = TokenEvent(
            id: "cached-empty-strings",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: "mac-a",
            deviceName: "Mac A",
            projectPath: "/tmp/project",
            sessionId: "session-a",
            model: "claude-opus",
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/cached-empty-strings.jsonl"
        )
        let originalData = try encoder.encode(original)
        var object = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] ?? [:]
        object["deviceId"] = ""
        object["deviceName"] = ""
        object["projectPath"] = ""
        object["sessionId"] = ""
        object["model"] = ""
        object["usage"] = [
            "input": -100,
            "cachedInput": 0,
            "cacheCreation": 0,
            "cacheRead": 0,
            "output": 5,
            "reasoning": 0,
            "total": -1
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try decoder.decode(TokenEvent.self, from: data)
        try expect(decoded.deviceId == TokenDeviceMetadata.localFallback.id, "decoded TokenEvent restores empty device id")
        try expect(decoded.deviceName == TokenDeviceMetadata.localFallback.name, "decoded TokenEvent restores empty device name")
        try expect(decoded.projectPath == "Unknown", "decoded TokenEvent restores empty project")
        try expect(decoded.sessionId == "Unknown", "decoded TokenEvent restores empty session")
        try expect(decoded.model == "Unknown", "decoded TokenEvent restores empty model")
        try expect(decoded.usage.total == 5, "decoded TokenEvent normalizes nested usage")
    }

    static func tokenFormatterHandlesMinimumInteger() throws {
        let compact = TokenFormatters.compactTokens(Int.min)
        let full = TokenFormatters.integer(Int.min)

        try expect(compact.hasPrefix("-"), "compact formatter keeps negative sign for Int.min")
        try expect(compact.hasSuffix("B"), "compact formatter abbreviates Int.min without overflowing")
        try expect(!full.isEmpty, "full formatter handles Int.min")
    }

    static func relativeDayRangesIncludeToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(year: 2026, month: 5, day: 11, hour: 17, minute: 37, calendar: calendar)

        let sevenDays = TimeRangePreset.last7Days.interval(now: now, calendar: calendar)
        try expect(sevenDays.start == date(year: 2026, month: 5, day: 5, hour: 0, minute: 0, calendar: calendar), "7d start includes today")
        try expect(sevenDays.end == now, "7d end")

        let thirtyDays = TimeRangePreset.last30Days.interval(now: now, calendar: calendar)
        try expect(thirtyDays.start == date(year: 2026, month: 4, day: 12, hour: 0, minute: 0, calendar: calendar), "30d start includes today")
        try expect(thirtyDays.end == now, "30d end")

        let twelveHours = TimeRangePreset.last12Hours.interval(now: now, calendar: calendar)
        try expect(twelveHours.start == date(year: 2026, month: 5, day: 11, hour: 5, minute: 37, calendar: calendar), "12h start")
        try expect(twelveHours.end == now, "12h end")

        let thirtyMinutes = TimeRangePreset.last30Minutes.interval(now: now, calendar: calendar)
        try expect(thirtyMinutes.start == date(year: 2026, month: 5, day: 11, hour: 17, minute: 7, calendar: calendar), "30m start")
        try expect(thirtyMinutes.end == now, "30m end")

        let oneHour = TimeRangePreset.last1Hour.interval(now: now, calendar: calendar)
        try expect(oneHour.start == date(year: 2026, month: 5, day: 11, hour: 16, minute: 37, calendar: calendar), "1h start")
        try expect(oneHour.end == now, "1h end")

        let threeHours = TimeRangePreset.last3Hours.interval(now: now, calendar: calendar)
        try expect(threeHours.start == date(year: 2026, month: 5, day: 11, hour: 14, minute: 37, calendar: calendar), "3h start")
        try expect(threeHours.end == now, "3h end")

        let sixHours = TimeRangePreset.last6Hours.interval(now: now, calendar: calendar)
        try expect(sixHours.start == date(year: 2026, month: 5, day: 11, hour: 11, minute: 37, calendar: calendar), "6h start")
        try expect(sixHours.end == now, "6h end")

        let eightHours = TimeRangePreset.last8Hours.interval(now: now, calendar: calendar)
        try expect(eightHours.start == date(year: 2026, month: 5, day: 11, hour: 9, minute: 37, calendar: calendar), "8h start")
        try expect(eightHours.end == now, "8h end")
    }

    static func previousRangesMatchCurrentDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(year: 2026, month: 5, day: 11, hour: 17, minute: 37, calendar: calendar)

        let previous24Hours = TimeRangePreset.last24Hours.previousInterval(now: now, calendar: calendar)
        try expect(previous24Hours.start == date(year: 2026, month: 5, day: 9, hour: 17, minute: 37, calendar: calendar), "previous 24h start")
        try expect(previous24Hours.end == date(year: 2026, month: 5, day: 10, hour: 17, minute: 37, calendar: calendar), "previous 24h end")

        let previousToday = TimeRangePreset.today.previousInterval(now: now, calendar: calendar)
        try expect(previousToday.start == date(year: 2026, month: 5, day: 10, hour: 0, minute: 0, calendar: calendar), "previous today start")
        try expect(previousToday.end == date(year: 2026, month: 5, day: 10, hour: 17, minute: 37, calendar: calendar), "previous today end")
    }

    static func rangeFilteringUsesExclusiveEndBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = date(year: 2026, month: 5, day: 11, hour: 0, minute: 0, calendar: calendar)
        let beforeMidnight = event(
            id: "before-midnight",
            timestamp: midnight.addingTimeInterval(-1),
            total: 10
        )
        let atMidnight = event(
            id: "at-midnight",
            timestamp: midnight,
            total: 20
        )
        let events = [beforeMidnight, atMidnight]

        let yesterdayEvents = Aggregation.filter(
            events: events,
            source: .all,
            range: .yesterday,
            project: nil,
            model: nil,
            now: date(year: 2026, month: 5, day: 11, hour: 12, minute: 0, calendar: calendar),
            calendar: calendar
        )
        let todayEvents = Aggregation.filter(
            events: events,
            source: .all,
            range: .today,
            project: nil,
            model: nil,
            now: date(year: 2026, month: 5, day: 11, hour: 12, minute: 0, calendar: calendar),
            calendar: calendar
        )

        try expect(yesterdayEvents.map(\.id) == ["before-midnight"], "yesterday excludes today boundary")
        try expect(todayEvents.map(\.id) == ["at-midnight"], "today includes its start boundary")
    }

    static func filledBucketsExcludeExclusiveEndBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterdayStart = date(year: 2026, month: 5, day: 10, hour: 0, minute: 0, calendar: calendar)
        let todayStart = date(year: 2026, month: 5, day: 11, hour: 0, minute: 0, calendar: calendar)
        let buckets = [
            TimeBucket(start: yesterdayStart, usage: TokenUsage(total: 10), sourceUsage: [.codex: TokenUsage(total: 10)])
        ]

        let filled = Aggregation.filledBuckets(
            buckets: buckets,
            range: .yesterday,
            bucket: .day,
            interval: DateInterval(start: yesterdayStart, end: todayStart),
            maxCount: 10,
            calendar: calendar
        )

        try expect(filled.map(\.start) == [yesterdayStart], "filled chart buckets exclude the range end boundary")
    }

    static func filledBucketsKeepAllRangeSingleDataPoint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let only = date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar)
        let buckets = [
            TimeBucket(start: only, usage: TokenUsage(total: 10), sourceUsage: [.codex: TokenUsage(total: 10)])
        ]
        let interval = TimeRangePreset.all.interval(
            now: date(year: 2026, month: 1, day: 10, hour: 10, minute: 0, calendar: calendar),
            calendar: calendar,
            earliest: only,
            latest: only
        )

        let filled = Aggregation.filledBuckets(
            buckets: buckets,
            range: .all,
            bucket: .hour,
            interval: interval,
            maxCount: 10,
            calendar: calendar
        )

        try expect(filled.map(\.start) == [only], "all range keeps the only real bucket")
    }

    static func dashboardRangesExposeShortOptions() throws {
        let expected: [TimeRangePreset] = [
            .last30Minutes,
            .last1Hour,
            .last3Hours,
            .last6Hours,
            .last8Hours,
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
        try expect(TimeRangePreset.dashboardCases == expected, "dashboard ranges include short options")
    }

    static func fiveMinuteBucketsRoundDown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let events = [
            event(id: "a", timestamp: date(year: 2026, month: 5, day: 11, hour: 17, minute: 7, calendar: calendar), total: 10),
            event(id: "b", timestamp: date(year: 2026, month: 5, day: 11, hour: 17, minute: 9, calendar: calendar), total: 20),
            event(id: "c", timestamp: date(year: 2026, month: 5, day: 11, hour: 17, minute: 11, calendar: calendar), total: 30)
        ]

        let buckets = Aggregation.buckets(events: events, bucket: .fiveMinutes, calendar: calendar)
        try expect(
            buckets.map(\.start) == [
                date(year: 2026, month: 5, day: 11, hour: 17, minute: 5, calendar: calendar),
                date(year: 2026, month: 5, day: 11, hour: 17, minute: 10, calendar: calendar)
            ],
            "5m bucket starts"
        )
        try expect(buckets.map(\.usage.total) == [30, 30], "5m bucket totals")
    }

    static func aggregationAllRangeUsesEarliestTimestampWhenEventsAreUnsorted() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let early = event(
            id: "early",
            timestamp: date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar),
            total: 10
        )
        let later = event(
            id: "later",
            timestamp: date(year: 2026, month: 1, day: 2, hour: 10, minute: 0, calendar: calendar),
            total: 20
        )

        let filtered = Aggregation.filter(
            events: [later, early],
            source: .all,
            range: .all,
            project: nil,
            model: nil,
            now: date(year: 2026, month: 1, day: 3, hour: 10, minute: 0, calendar: calendar),
            calendar: calendar
        )

        try expect(filtered.map(\.id) == ["later", "early"], "all range does not depend on event ordering")
        try expect(Aggregation.totalUsage(events: filtered).total == 30, "all range includes earliest unsorted event")
    }

    static func aggregationAllRangeIncludesFutureEventsWithoutReversedInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar)
        let futureTimestamp = date(year: 2026, month: 1, day: 2, hour: 10, minute: 0, calendar: calendar)
        let future = event(
            id: "future",
            timestamp: futureTimestamp,
            total: 10
        )

        let filtered = Aggregation.filter(
            events: [future],
            source: .all,
            range: .all,
            project: nil,
            model: nil,
            now: now,
            calendar: calendar
        )
        let interval = TimeRangePreset.all.interval(now: now, calendar: calendar, earliest: futureTimestamp)
        let previous = TimeRangePreset.all.previousInterval(now: now, calendar: calendar, earliest: futureTimestamp)

        try expect(filtered.map(\.id) == ["future"], "all range includes future-dated events")
        try expect(interval.start == now, "future all interval start")
        try expect(interval.end == futureTimestamp, "future all interval end")
        try expect(previous.start == previous.end, "future all previous interval is empty")
    }

    static func aggregationAllRangeUsesProvidedDataSpan() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(year: 2026, month: 1, day: 10, hour: 10, minute: 0, calendar: calendar)
        let early = date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar)
        let late = date(year: 2026, month: 1, day: 3, hour: 10, minute: 0, calendar: calendar)
        let interval = TimeRangePreset.all.interval(now: now, calendar: calendar, earliest: early, latest: late)

        try expect(interval.start == early, "all interval uses earliest data start")
        try expect(interval.end == late, "all interval uses latest data end instead of appending empty time")
    }

    static func aggregationAllRangeDoesNotAppendEmptyTimeForSingleDataPoint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(year: 2026, month: 1, day: 10, hour: 10, minute: 0, calendar: calendar)
        let only = date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar)
        let interval = TimeRangePreset.all.interval(now: now, calendar: calendar, earliest: only, latest: only)

        try expect(interval.start == only, "single-point all interval starts at the data point")
        try expect(interval.end == only, "single-point all interval does not append empty time to now")
    }

    static func aggregationTreatsDashboardLabelsAsLiteralFilters() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar)
        let labelNamedEvent = TokenEvent(
            id: "label-named",
            source: .codex,
            timestamp: timestamp,
            projectPath: "All Projects",
            model: "All Models",
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/label-named.jsonl"
        )
        let normalEvent = TokenEvent(
            id: "normal",
            source: .codex,
            timestamp: timestamp,
            projectPath: "/tmp/project-a",
            model: "gpt-5.2-codex",
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/normal.jsonl"
        )
        let events = [labelNamedEvent, normalEvent]
        let interval = DateInterval(start: timestamp.addingTimeInterval(-1), end: timestamp.addingTimeInterval(1))

        try expect(
            Aggregation.filter(events: events, source: .all, interval: interval, project: "All Projects", model: nil).map(\.id) == ["label-named"],
            "project filter treats dashboard label as a literal project"
        )
        try expect(
            Aggregation.filter(events: events, source: .all, interval: interval, project: nil, model: "All Models").map(\.id) == ["label-named"],
            "model filter treats dashboard label as a literal model"
        )
        try expect(
            Aggregation.filter(events: events, source: .all, interval: interval, project: nil, model: nil).count == 2,
            "nil filters mean all projects and models"
        )
    }

    static func aggregationGroupedRowsUseStableTieBreakers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let early = date(year: 2026, month: 1, day: 1, hour: 10, minute: 0, calendar: calendar)
        let late = date(year: 2026, month: 1, day: 2, hour: 10, minute: 0, calendar: calendar)
        let events = [
            TokenEvent(
                id: "alpha",
                source: .codex,
                timestamp: early,
                projectPath: "Alpha",
                usage: TokenUsage(total: 10),
                rawFilePath: "/tmp/alpha.jsonl"
            ),
            TokenEvent(
                id: "beta",
                source: .codex,
                timestamp: late,
                projectPath: "Beta",
                usage: TokenUsage(total: 10),
                rawFilePath: "/tmp/beta.jsonl"
            ),
            TokenEvent(
                id: "gamma",
                source: .codex,
                timestamp: early,
                projectPath: "Gamma",
                usage: TokenUsage(total: 20),
                rawFilePath: "/tmp/gamma.jsonl"
            )
        ]

        let rows = Aggregation.grouped(events: events, by: \.projectPath)
        try expect(rows.map(\.key) == ["Gamma", "Beta", "Alpha"], "grouped rows use total, recency, and name ordering")
    }

    static func aggregationNormalizesDependentFiltersWithoutDroppingValidChoices() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date(year: 2026, month: 1, day: 2, hour: 10, minute: 0, calendar: calendar)
        let timestamp = date(year: 2026, month: 1, day: 2, hour: 9, minute: 0, calendar: calendar)
        let events = [
            TokenEvent(
                id: "p1-m1",
                source: .codex,
                timestamp: timestamp,
                deviceId: "local",
                projectPath: "/tmp/project-1",
                model: "model-1",
                usage: TokenUsage(total: 10),
                rawFilePath: "/tmp/p1-m1.jsonl"
            ),
            TokenEvent(
                id: "p2-m2",
                source: .codex,
                timestamp: timestamp,
                deviceId: "remote",
                projectPath: "/tmp/project-2",
                model: "model-2",
                usage: TokenUsage(total: 20),
                rawFilePath: "/tmp/p2-m2.jsonl"
            )
        ]

        let invalidModel = Aggregation.normalizedFilters(
            events: events,
            source: .all,
            range: .last24Hours,
            project: "/tmp/project-1",
            model: "missing-model",
            now: now,
            calendar: calendar
        )
        try expect(
            invalidModel == TokenFilterSelection(project: "/tmp/project-1", model: nil),
            "invalid model does not drop still-valid project"
        )

        let mismatchedPair = Aggregation.normalizedFilters(
            events: events,
            source: .all,
            range: .last24Hours,
            project: "/tmp/project-1",
            model: "model-2",
            now: now,
            calendar: calendar
        )
        try expect(
            mismatchedPair == TokenFilterSelection(project: nil, model: "model-2"),
            "mismatched project resets before valid model"
        )

        let deviceScoped = Aggregation.normalizedFilters(
            events: events,
            source: .all,
            range: .last24Hours,
            project: "/tmp/project-2",
            model: "model-2",
            deviceId: "local",
            now: now,
            calendar: calendar
        )
        try expect(
            deviceScoped == TokenFilterSelection(project: nil, model: nil),
            "device-scoped normalization removes filters without matching events"
        )
    }

    static func dashboardBucketOptionsStayReadable() throws {
        let expected: [BucketInterval] = [
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
        try expect(
            BucketInterval.dashboardCases(for: .last12Hours) == expected,
            "short ranges expose every chart grouping"
        )
        try expect(
            BucketInterval.dashboardCases(for: .last24Hours) == expected,
            "24h range exposes every chart grouping"
        )
        try expect(
            BucketInterval.dashboardCases(for: .last12Months) == expected,
            "long ranges expose every chart grouping"
        )
    }
}
