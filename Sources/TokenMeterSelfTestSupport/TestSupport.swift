import Foundation
import TokenMeterCore

public enum TokenMeterSelfTest {
    public static func runAll(includeRealScan: Bool = false) throws {
        try runParserTests()
        try runAggregationTests()
        try runUpdatePolicyTests()
        try runScannerCacheTests()
        try runSyncFolderTests()
        try runCodexSessionCleanupTests()
        if includeRealScan {
            runRealScanSmokeTest()
        }
    }
}

extension TokenMeterSelfTest {
    static func temporaryFile(_ content: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.jsonl")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    static func writeClaudeLog(
        homeDirectory: URL,
        fileName: String,
        timestamp: String,
        cwd: String,
        sessionId: String,
        requestId: String,
        input: Int
    ) throws -> URL {
        let projectDirectory = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let content = """
        {"timestamp":"\(timestamp)","sessionId":"\(sessionId)","requestId":"\(requestId)","uuid":"\(requestId)-uuid","cwd":"\(cwd)","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
        let url = projectDirectory.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    static func writeCodexLog(
        homeDirectory: URL,
        fileName: String,
        timestamp: String,
        cwd: String,
        model: String = "gpt-5.5",
        input: Int,
        output: Int = 0,
        reasoning: Int = 0
    ) throws -> URL {
        let sessionDirectory = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
            .appendingPathComponent("01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let total = input + output
        let content = """
        {"timestamp":"\(timestamp)","payload":{"type":"session_meta","cwd":"\(cwd)","model":"\(model)"}}
        {"timestamp":"\(timestamp)","payload":{"info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)}}}}
        """
        let url = sessionDirectory.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func appendClaudeLogLine(
        to url: URL,
        timestamp: String,
        cwd: String,
        sessionId: String,
        requestId: String,
        input: Int
    ) throws {
        let line = """
        {"timestamp":"\(timestamp)","sessionId":"\(sessionId)","requestId":"\(requestId)","uuid":"\(requestId)-uuid","cwd":"\(cwd)","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """ + "\n"
        let handle = try FileHandle(forUpdating: url)
        defer {
            try? handle.close()
        }
        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.seek(toOffset: endOffset - 1)
            let lastByte = handle.readDataToEndOfFile()
            if lastByte != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    static func temporaryCache(in directory: URL) throws -> TokenEventCacheStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try TokenEventCacheStore(databaseURL: directory.appendingPathComponent("cache.sqlite"))
    }

    static func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    static func overwriteWithInvalidContentPreservingSizeAndDate(url: URL, date: Date) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        let byteCount = size?.intValue ?? 0
        let invalid = String(repeating: "x", count: byteCount)
        try invalid.write(to: url, atomically: true, encoding: .utf8)
        try setModificationDate(date, for: url)
    }

    static func overwritePrefixWithInvalidContent(url: URL, byteCount: Int) throws {
        var data = try Data(contentsOf: url)
        let clampedByteCount = min(max(byteCount, 0), data.count)
        guard clampedByteCount > 0 else { return }
        let endIndex = data.index(data.startIndex, offsetBy: clampedByteCount)
        data.replaceSubrange(
            data.startIndex..<endIndex,
            with: Data(repeating: 0x78, count: clampedByteCount)
        )
        try data.write(to: url, options: [.atomic])
    }

    static func syncLedgerText(syncFolder: URL) throws -> String {
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

    static func syncLedgerLineCount(syncFolder: URL, deviceId: String) throws -> Int {
        let url = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(deviceId).jsonl")
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    static func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }

    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, calendar: Calendar) -> Date {
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

    static func event(id: String, timestamp: Date, total: Int) -> TokenEvent {
        TokenEvent(
            id: id,
            source: .codex,
            timestamp: timestamp,
            usage: TokenUsage(total: total),
            rawFilePath: "/tmp/\(id).jsonl"
        )
    }

    static func release(version: String, targetCommitish: String) -> ReleaseInfo {
        ReleaseInfo(
            version: version,
            displayName: version,
            zipURL: URL(string: "https://example.com/TokenMeter-\(version).zip")!,
            htmlURL: nil,
            targetCommitish: targetCommitish
        )
    }

    static func expect(_ condition: Bool, _ name: String) throws {
        if !condition {
            throw TestFailure(message: name)
        }
    }

    static func runRealScanSmokeTest() {
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
