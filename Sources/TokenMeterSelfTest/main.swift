import Foundation
import TokenMeterCore

@main
enum TokenMeterSelfTest {
    static func main() throws {
        try codexParserUsesDeltasAndSkipsRepeatedTotals()
        try claudeParserDeduplicatesRequestIDs()
        try relativeDayRangesIncludeToday()
        try previousRangesMatchCurrentDuration()
        try fiveMinuteBucketsRoundDown()
        try dashboardRangesExposeShortOptions()
        try dashboardBucketOptionsStayReadable()
        try scannerIncludesAllRecentClaudeFiles()
        try syncFolderMergesDeviceLedgersAndDeduplicatesLocalEvents()
        try syncFolderAppendsOnlyNewLocalEvents()
        try syncFolderImportsOnlyRequestedWindow()
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

    private static func previousRangesMatchCurrentDuration() throws {
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

    private static func fiveMinuteBucketsRoundDown() throws {
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

    private static func dashboardBucketOptionsStayReadable() throws {
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

    private static func scannerIncludesAllRecentClaudeFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())

        for index in 0..<45 {
            let content = """
            {"timestamp":"\(timestamp)","sessionId":"s\(index)","requestId":"r\(index)","uuid":"u\(index)","cwd":"/tmp/project","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
            """
            let url = projectDirectory.appendingPathComponent("sample-\(index).jsonl")
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        let scanner = TokenLogScanner(homeDirectory: directory)
        let result = scanner.scan(modifiedAfter: Date(timeIntervalSinceNow: -60))
        try expect(result.claudeFileCount == 45, "scanner includes every recent Claude file")
        try expect(result.events.count == 45, "scanner parses every recent Claude event")
        try expect(Aggregation.totalUsage(events: result.events).total == 45, "scanner totals every recent Claude event")
        try expect(result.sourceStatuses.count == 3, "scanner reports every source root")
        let claudeStatus = result.sourceStatuses.first { $0.label == "Claude projects" }
        try expect(claudeStatus?.exists == true, "scanner reports Claude root exists")
        try expect(claudeStatus?.totalFileCount == 45, "scanner reports Claude total files")
        try expect(claudeStatus?.scannedFileCount == 45, "scanner reports Claude scanned files")
    }

    private static func syncFolderMergesDeviceLedgersAndDeduplicatesLocalEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeA = directory.appendingPathComponent("home-a", isDirectory: true)
        let homeB = directory.appendingPathComponent("home-b", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        try writeClaudeLog(
            homeDirectory: homeA,
            fileName: "a.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/secret-project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )
        try writeClaudeLog(
            homeDirectory: homeB,
            fileName: "b.jsonl",
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/secret-project-b",
            sessionId: "session-b",
            requestId: "request-b",
            input: 20
        )

        let deviceA = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let deviceB = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scannerA = TokenLogScanner(homeDirectory: homeA, localDevice: deviceA)
        let scannerB = TokenLogScanner(homeDirectory: homeB, localDevice: deviceB)

        let firstA = scannerA.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(firstA.syncStatus.exists, "sync folder exists for first device")
        try expect(firstA.syncStatus.exportedEventCount == 1, "first device exports one event")
        try expect(Aggregation.totalUsage(events: firstA.events).total == 10, "first sync total")

        let firstB = scannerB.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(firstB.syncStatus.deviceFileCount == 2, "sync folder has both device ledgers")
        try expect(Aggregation.totalUsage(events: firstB.events).total == 30, "second device sees merged total")

        let mergedA = scannerA.scan(syncFolder: syncFolder)
        try expect(Aggregation.totalUsage(events: mergedA.events).total == 30, "local and sync ledgers dedupe")
        try expect(Set(mergedA.events.map(\.deviceId)) == ["mac-a", "mac-b"], "merged events keep device ids")

        let ledgerText = try syncLedgerText(syncFolder: syncFolder)
        try expect(!ledgerText.contains("secret-project"), "sync ledger omits raw project paths")
        try expect(!ledgerText.contains(".claude"), "sync ledger omits raw log paths")
    }

    private static func syncFolderAppendsOnlyNewLocalEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: device)

        try writeClaudeLog(
            homeDirectory: home,
            fileName: "a.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )

        let first = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(first.syncStatus.exportedEventCount == 1, "initial sync exports one record")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1, "initial ledger line count")

        let unchanged = scanner.scan(syncFolder: syncFolder)
        try expect(unchanged.syncStatus.exportedEventCount == 0, "unchanged sync appends nothing")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1, "unchanged ledger line count")

        try writeClaudeLog(
            homeDirectory: home,
            fileName: "b.jsonl",
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/project-b",
            sessionId: "session-b",
            requestId: "request-b",
            input: 5
        )

        let updated = scanner.scan(syncFolder: syncFolder)
        try expect(updated.syncStatus.exportedEventCount == 1, "second sync exports only new record")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 2, "updated ledger line count")
        try expect(Aggregation.totalUsage(events: updated.events).total == 15, "updated sync total")

        let repeated = scanner.scan(syncFolder: syncFolder)
        try expect(repeated.syncStatus.exportedEventCount == 0, "repeated sync appends nothing")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 2, "repeated ledger line count")
    }

    private static func syncFolderImportsOnlyRequestedWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let store = TokenSyncLedgerStore(folder: syncFolder, localDevice: device)
        let oldEvent = TokenEvent(
            id: "old",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/old.jsonl"
        )
        let recentEvent = TokenEvent(
            id: "recent",
            source: .claude,
            timestamp: isoDate("2026-01-02T00:00:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/recent.jsonl"
        )

        _ = store.synchronize(localEvents: [oldEvent, recentEvent], replaceLocalLedger: true)

        let windowed = store.synchronize(
            localEvents: [],
            importedAfter: isoDate("2026-01-01T12:00:00.000Z")
        )
        try expect(windowed.events.map(\.id) == ["recent"], "sync import filters old records")
        try expect(windowed.status.importedEventCount == 1, "sync import status counts windowed records")
    }

    private static func temporaryFile(_ content: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.jsonl")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func writeClaudeLog(
        homeDirectory: URL,
        fileName: String,
        timestamp: String,
        cwd: String,
        sessionId: String,
        requestId: String,
        input: Int
    ) throws {
        let projectDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let content = """
        {"timestamp":"\(timestamp)","sessionId":"\(sessionId)","requestId":"\(requestId)","uuid":"\(requestId)-uuid","cwd":"\(cwd)","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
        try content.write(to: projectDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    private static func syncLedgerText(syncFolder: URL) throws -> String {
        let devicesDirectory = syncFolder.appendingPathComponent("devices", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: devicesDirectory,
            includingPropertiesForKeys: nil
        )
        return try files
            .filter { $0.pathExtension == "jsonl" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private static func syncLedgerLineCount(syncFolder: URL, deviceId: String) throws -> Int {
        let url = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(deviceId).jsonl")
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
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

    private static func event(id: String, timestamp: Date, total: Int) -> TokenEvent {
        TokenEvent(
            id: id,
            source: .codex,
            timestamp: timestamp,
            usage: TokenUsage(total: total),
            rawFilePath: "/tmp/\(id).jsonl"
        )
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
        let result = scanner.scan(modifiedAfter: modifiedAfter)
        let elapsed = Date().timeIntervalSince(start)
        print("Real scan smoke: \(result.events.count) events, \(result.codexFileCount) Codex files, \(result.claudeFileCount) Claude files, \(String(format: "%.2f", elapsed))s")
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "Self-test failed: \(message)" }
}
