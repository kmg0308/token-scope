import Foundation
import TokenMeterCore

@main
enum TokenMeterSelfTest {
    static func main() throws {
        try codexParserUsesDeltasAndSkipsRepeatedTotals()
        try claudeParserDeduplicatesRequestIDs()
        try relativeDayRangesIncludeToday()
        try dashboardRangesExposeShortOptions()
        try dashboardBucketOptionsStayReadable()
        if CommandLine.arguments.contains("--real-scan") {
            runRealScanSmokeTest()
        }
        print("TokenMeterSelfTest passed")
    }

    private static func codexParserUsesDeltasAndSkipsRepeatedTotals() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"session_meta","cwd":"/tmp/project","model":"gpt-5.2-codex"}}
        {"timestamp":"2026-01-01T00:00:01.000Z","payload":{"info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}
        {"timestamp":"2026-01-01T00:00:02.000Z","payload":{"info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12},"last_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}
        {"timestamp":"2026-01-01T00:00:03.000Z","payload":{"info":{"total_token_usage":{"input_tokens":18,"cached_input_tokens":8,"output_tokens":4,"reasoning_output_tokens":1,"total_tokens":22},"last_token_usage":{"input_tokens":8,"cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":10}}}}
        """)

        let events = try TokenLogParser.parseCodexFile(at: url)
        try expect(events.count == 2, "Codex event count")
        try expect(events.map(\.usage.total) == [12, 10], "Codex deltas")
        try expect(events.first?.projectPath == "/tmp/project", "Codex project")
        try expect(events.first?.model == "gpt-5.2-codex", "Codex model")
    }

    private static func claudeParserDeduplicatesRequestIDs() throws {
        let url = temporaryFile("""
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s1","requestId":"r1","uuid":"u1","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}
        {"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"s1","requestId":"r1","uuid":"u2","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}
        {"timestamp":"2026-01-01T00:00:02.000Z","sessionId":"s1","requestId":"r2","uuid":"u3","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":5,"output_tokens":5}}}
        """)

        let events = try TokenLogParser.parseClaudeFile(at: url)
        try expect(events.count == 2, "Claude event count")
        try expect(events.map(\.usage.total) == [10, 20], "Claude totals")
        try expect(events.first?.source == .claude, "Claude source")
    }

    private static func relativeDayRangesIncludeToday() throws {
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
    }

    private static func dashboardRangesExposeShortOptions() throws {
        let expected: [TimeRangePreset] = [
            .last30Minutes,
            .last1Hour,
            .last3Hours,
            .last6Hours,
            .last12Hours,
            .last24Hours,
            .today,
            .last7Days,
            .last30Days,
            .last3Months,
            .last6Months,
            .last12Months
        ]
        try expect(TimeRangePreset.dashboardCases == expected, "dashboard ranges include short options")
    }

    private static func dashboardBucketOptionsStayReadable() throws {
        let expected: [BucketInterval] = [
            .minute,
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

    private static func temporaryFile(_ content: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.jsonl")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private static func expect(_ condition: Bool, _ name: String) throws {
        if !condition {
            throw TestFailure(message: name)
        }
    }

    private static func runRealScanSmokeTest() {
        let start = Date()
        let scanner = TokenLogScanner()
        let modifiedAfter = Calendar.current.startOfDay(for: Date())
        let result = scanner.scan(modifiedAfter: modifiedAfter, maxFilesPerSource: 40, maxFileBytes: 25 * 1_024 * 1_024)
        let elapsed = Date().timeIntervalSince(start)
        print("Real scan smoke: \(result.events.count) events, \(result.codexFileCount) Codex files, \(result.claudeFileCount) Claude files, \(String(format: "%.2f", elapsed))s")
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "Self-test failed: \(message)" }
}
