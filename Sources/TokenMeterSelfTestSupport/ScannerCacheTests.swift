import Foundation
import SQLite3
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runScannerCacheTests() throws {
        try scannerIncludesAllRecentClaudeFiles()
        try scannerIgnoresJSONLDirectories()
        try scannerReportsInvalidSourceRoot()
        try scannerReusesCachedLocalFilesUntilTheyChange()
        try scannerReturnsCachedResultBeforeRefresh()
        try scannerCachedResultRestoresSyncStatus()
        try scannerKeepsCodexCacheWhenLocalSessionFileIsRemoved()
        try scannerPrunesClaudeCacheWhenLocalLogFileIsRemoved()
        try scannerAppendsGrowingLocalFileFromCache()
        try scannerIgnoresIncrementalClaudeDuplicateRequests()
        try scannerFallsBackToFullParseWhenGrowingFileModificationDateRegresses()
        try scannerKeepsCachedHistoryDuringRecentRefresh()
        try scannerCancelledEnumerationKeepsExistingCache()
        try scannerCancellationDuringFileParseReturnsNoPartialEvents()
        try scannerIgnoresOutdatedCacheForRemovedCodexFiles()
        try scannerRebuildsExistingOutdatedFileOnlyOnce()
    }

    static func scannerRebuildsExistingOutdatedFileOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("cache.sqlite")
        let cache = try TokenEventCacheStore(databaseURL: cacheURL)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )
        let logURL = try writeCodexLog(
            homeDirectory: home,
            fileName: "existing-outdated.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10
        )
        try setModificationDate(isoDate("2026-01-01T00:05:00.000Z"), for: logURL)
        _ = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try setCachedParserVersion(3, databaseURL: cacheURL, originPath: logURL.resolvingSymlinksInPath().path)

        try writeCodexLog(
            homeDirectory: home,
            fileName: "existing-outdated.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 20
        )
        try setModificationDate(isoDate("2026-01-01T00:05:00.000Z"), for: logURL)
        let rebuilt = scanner.scan(
            modifiedAfter: isoDate("2026-02-01T00:00:00.000Z"),
            eventAfter: isoDate("2026-02-01T00:00:00.000Z")
        )
        try expect(Aggregation.totalUsage(events: rebuilt.events).total == 20, "existing outdated file is reparsed outside the recent window")

        try FileManager.default.removeItem(at: logURL)
        let recent = scanner.scan(
            modifiedAfter: isoDate("2026-02-01T00:00:00.000Z"),
            eventAfter: isoDate("2026-02-01T00:00:00.000Z")
        )
        try expect(recent.events.isEmpty, "rebuilt file does not trigger another all-history refresh")
    }

    static func scannerIgnoresOutdatedCacheForRemovedCodexFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("cache.sqlite")
        let cache = try TokenEventCacheStore(databaseURL: cacheURL)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )
        let logURL = try writeCodexLog(
            homeDirectory: home,
            fileName: "removed-outdated.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10
        )

        let initial = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: initial.events).total == 10, "initial outdated-cache fixture total")
        try FileManager.default.removeItem(at: logURL)
        try setCachedParserVersion(3, databaseURL: cacheURL, originPath: logURL.resolvingSymlinksInPath().path)

        let recent = scanner.scan(
            modifiedAfter: isoDate("2026-02-01T00:00:00.000Z"),
            eventAfter: isoDate("2026-02-01T00:00:00.000Z")
        )
        try expect(recent.events.isEmpty, "removed outdated Codex cache does not force an all-history refresh")
    }

    private static func setCachedParserVersion(
        _ version: Int32,
        databaseURL: URL,
        originPath: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw TestFailure(message: "open cache database for parser-version fixture")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE origin_files SET parser_version = ? WHERE origin_kind = 'local_log' AND origin_path = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
            let statement else {
            throw TestFailure(message: "prepare parser-version fixture")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, version)
        sqlite3_bind_text(
            statement,
            2,
            originPath,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestFailure(message: "write parser-version fixture")
        }
    }

    static func scannerIncludesAllRecentClaudeFiles() throws {
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
        try expect(result.sourceStatuses.count == 4, "scanner reports every source root")
        let claudeStatus = result.sourceStatuses.first { $0.label == "Claude projects" }
        try expect(claudeStatus?.exists == true, "scanner reports Claude root exists")
        try expect(claudeStatus?.totalFileCount == 45, "scanner reports Claude total files")
        try expect(claudeStatus?.scannedFileCount == 45, "scanner reports Claude scanned files")
    }

    static func scannerIgnoresJSONLDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let projectDirectory = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory.appendingPathComponent("not-a-file.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeClaudeLog(
            homeDirectory: home,
            fileName: "real.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )

        let scanner = TokenLogScanner(homeDirectory: home)
        let result = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        let claudeStatus = result.sourceStatuses.first { $0.label == "Claude projects" }
        try expect(claudeStatus?.totalFileCount == 1, "scanner ignores .jsonl directories")
        try expect(result.parseErrorCount == 0, "scanner avoids parse errors for .jsonl directories")
        try expect(Aggregation.totalUsage(events: result.events).total == 10, "scanner keeps real JSONL file")
    }

    static func scannerReportsInvalidSourceRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claudeParent = directory
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeParent, withIntermediateDirectories: true)
        try "not a directory".write(
            to: claudeParent.appendingPathComponent("projects"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = TokenLogScanner(homeDirectory: directory)
        let result = scanner.scan()
        let claudeStatus = result.sourceStatuses.first { $0.label == "Claude projects" }
        try expect(claudeStatus?.exists == true, "invalid source root reports existing path")
        try expect(claudeStatus?.totalFileCount == 0, "invalid source root has no files")
        try expect(claudeStatus?.parseErrorCount == 1, "invalid source root reports an error")
        try expect(result.parseErrorCount == 1, "invalid source root contributes to total errors")
    }

    static func scannerReusesCachedLocalFilesUntilTheyChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: device, cacheStore: cache)
        let logURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "cached.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )
        let cachedDate = isoDate("2026-01-01T00:10:00.000Z")
        try setModificationDate(cachedDate, for: logURL)

        let first = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: first.events).total == 10, "initial cached scan total")

        try overwriteWithInvalidContentPreservingSizeAndDate(url: logURL, date: cachedDate)
        let unchanged = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: unchanged.events).total == 10, "unchanged file uses cached events")
        try expect(unchanged.parseErrorCount == 0, "unchanged cached file avoids reparse errors")

        _ = try writeClaudeLog(
            homeDirectory: home,
            fileName: "cached.jsonl",
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-b",
            input: 25
        )
        try setModificationDate(isoDate("2026-01-01T00:20:00.000Z"), for: logURL)
        let changed = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: changed.events).total == 25, "changed file is reparsed")
    }

    static func scannerKeepsCachedHistoryDuringRecentRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        let oldURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "old.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-old",
            input: 10
        )
        try setModificationDate(isoDate("2026-01-01T00:05:00.000Z"), for: oldURL)

        let initial = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: initial.events).total == 10, "initial history cache total")

        let recentURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "recent.jsonl",
            timestamp: "2026-01-03T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-b",
            requestId: "request-recent",
            input: 5
        )
        try setModificationDate(isoDate("2026-01-03T00:05:00.000Z"), for: recentURL)

        try overwriteWithInvalidContentPreservingSizeAndDate(
            url: oldURL,
            date: isoDate("2026-01-01T00:05:00.000Z")
        )
        let refreshed = scanner.scan(
            modifiedAfter: isoDate("2026-01-02T00:00:00.000Z"),
            eventAfter: isoDate("2025-12-31T00:00:00.000Z")
        )
        try expect(Aggregation.totalUsage(events: refreshed.events).total == 15, "recent refresh keeps cached history")
        try expect(refreshed.parseErrorCount == 0, "recent refresh does not reparse old cached files")
        try expect(refreshed.claudeFileCount == 2, "recent refresh reports cached and freshly scanned Claude files")
        let claudeStatus = refreshed.sourceStatuses.first { $0.label == "Claude projects" }
        try expect(claudeStatus?.scannedFileCount == 2, "recent refresh source status includes cached history files")
    }

    static func scannerCancelledEnumerationKeepsExistingCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        let removedURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "removed.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-removed",
            input: 10
        )
        try writeClaudeLog(
            homeDirectory: home,
            fileName: "kept.jsonl",
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-b",
            requestId: "request-kept",
            input: 20
        )

        let initial = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: initial.events).total == 30, "initial cache before cancelled enumeration")

        try FileManager.default.removeItem(at: removedURL)
        var cancellationChecks = 0
        _ = scanner.scan(isCancelled: {
            cancellationChecks += 1
            return cancellationChecks >= 2
        })

        let cached = scanner.cachedResult(eventAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: cached?.events ?? []).total == 30, "cancelled enumeration does not prune cached files")
    }

    static func scannerCancellationDuringFileParseReturnsNoPartialEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let projectDirectory = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let logURL = projectDirectory.appendingPathComponent("cancelled-parse.jsonl")
        let content = (0..<1_000)
            .map { claudeLogLine(requestId: "cancel-\($0)", input: 1) }
            .joined(separator: "\n") + "\n"
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        var cancellationChecks = 0
        let result = scanner.scan(isCancelled: {
            cancellationChecks += 1
            return cancellationChecks >= 18
        })

        try expect(result.events.isEmpty, "cancelled file parse returns no partial scan result")
        try expect(scanner.cachedResult() == nil, "cancelled file parse does not warm partial cache")
    }

    static func scannerReturnsCachedResultBeforeRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        try writeClaudeLog(
            homeDirectory: home,
            fileName: "cached-result.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )

        _ = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        let cached = scanner.cachedResult(eventAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(cached != nil, "scanner returns cached dashboard result")
        try expect(Aggregation.totalUsage(events: cached?.events ?? []).total == 10, "cached dashboard result keeps totals")
        try expect(cached?.claudeFileCount == 1, "cached dashboard result restores Claude file count")
        try expect(cached?.codexFileCount == 0, "cached dashboard result keeps empty Codex file count")
        let claudeStatus = cached?.sourceStatuses.first { $0.label == "Claude projects" }
        try expect(claudeStatus?.exists == true, "cached dashboard result reports Claude root")
        try expect(claudeStatus?.scannedFileCount == 1, "cached dashboard result restores Claude source status")
    }

    static func scannerCachedResultRestoresSyncStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let localDevice = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let remoteDevice = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: localDevice, cacheStore: cache)
        let remoteStore = TokenSyncLedgerStore(folder: syncFolder, localDevice: remoteDevice, cacheStore: cache)
        let oldRemoteEvent = TokenEvent(
            id: "old-remote",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: remoteDevice.id,
            deviceName: remoteDevice.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/old-remote.jsonl"
        )
        let recentRemoteEvent = TokenEvent(
            id: "recent-remote",
            source: .claude,
            timestamp: isoDate("2026-01-02T00:00:00.000Z"),
            deviceId: remoteDevice.id,
            deviceName: remoteDevice.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/recent-remote.jsonl"
        )

        _ = remoteStore.synchronize(localEvents: [oldRemoteEvent, recentRemoteEvent], replaceLocalLedger: true)
        let warmed = scanner.scan(syncFolder: syncFolder)
        try expect(warmed.syncStatus.deviceFileCount == 1, "sync scan counts cached status ledger file")
        try expect(warmed.syncStatus.importedEventCount == 2, "sync scan counts imported remote events")

        let cached = scanner.cachedResult(syncFolder: syncFolder)
        try expect(cached?.events.map(\.id) == ["old-remote", "recent-remote"], "cached sync result keeps remote events")
        try expect(cached?.syncStatus.exists == true, "cached sync status keeps folder existence")
        try expect(cached?.syncStatus.deviceFileCount == 1, "cached sync status restores ledger file count")
        try expect(cached?.syncStatus.importedEventCount == 2, "cached sync status restores imported event count")

        let windowed = scanner.cachedResult(
            eventAfter: isoDate("2026-01-01T12:00:00.000Z"),
            syncFolder: syncFolder
        )
        try expect(windowed?.events.map(\.id) == ["recent-remote"], "windowed cached sync result filters old events")
        try expect(windowed?.syncStatus.importedEventCount == 1, "windowed cached sync status counts the same event window")
    }

    static func scannerKeepsCodexCacheWhenLocalSessionFileIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )
        let logURL = try writeCodexLog(
            homeDirectory: home,
            fileName: "cached-codex.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10,
            output: 5
        )

        let initial = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: initial.events).total == 15, "initial Codex cache total")

        try FileManager.default.removeItem(at: logURL)
        let refreshed = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: refreshed.events).total == 15, "removed Codex session remains available from cache")
        try expect(refreshed.codexFileCount == 1, "removed Codex cache still contributes to source status")

        let cached = scanner.cachedResult(eventAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: cached?.events ?? []).total == 15, "cached dashboard result keeps removed Codex usage")
    }

    static func scannerPrunesClaudeCacheWhenLocalLogFileIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )
        let logURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "removed-claude.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )

        let initial = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: initial.events).total == 10, "initial Claude cache total")

        try FileManager.default.removeItem(at: logURL)
        let refreshed = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(refreshed.events.isEmpty, "removed Claude log is pruned from cache")
        try expect(refreshed.claudeFileCount == 0, "removed Claude cache does not contribute to source status")
    }

    static func scannerAppendsGrowingLocalFileFromCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        let logURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "growing.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )
        try setModificationDate(isoDate("2026-01-01T00:05:00.000Z"), for: logURL)

        let first = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: first.events).total == 10, "initial growing file total")

        try appendClaudeLogLine(
            to: logURL,
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-b",
            input: 25
        )
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: logURL)

        let grown = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: grown.events).total == 35, "growing file keeps cached events and appends new ones")
        try expect(grown.parseErrorCount == 0, "growing file avoids parse errors")

        let cached = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: cached.events).total == 35, "growing file refreshed cache is reusable")
    }

    static func scannerIgnoresIncrementalClaudeDuplicateRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        let logURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "duplicate-growing.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 10
        )
        try setModificationDate(isoDate("2026-01-01T00:05:00.000Z"), for: logURL)

        let first = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: first.events).total == 10, "initial duplicate-growing total")

        try appendClaudeLogLine(
            to: logURL,
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-a",
            requestId: "request-a",
            input: 90
        )
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: logURL)

        let grown = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: grown.events).total == 10, "incremental scan keeps first Claude request")
        try expect(grown.parseErrorCount == 0, "incremental duplicate scan avoids parse errors")

        let cached = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: cached.events).total == 10, "incremental duplicate cache remains deduped")
    }

    static func scannerFallsBackToFullParseWhenGrowingFileModificationDateRegresses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )

        let projectDirectory = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let logURL = projectDirectory.appendingPathComponent("replaced-growing.jsonl")
        try (claudeLogLine(requestId: "old-a", input: 10) + "\n").write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )
        try setModificationDate(isoDate("2026-01-02T00:00:00.000Z"), for: logURL)

        let first = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(Aggregation.totalUsage(events: first.events).total == 10, "initial replaced-growing total")

        let replacement = [
            claudeLogLine(requestId: "new-a", input: 20),
            claudeLogLine(requestId: "new-b", input: 30)
        ].joined(separator: "\n") + "\n"
        try replacement.write(to: logURL, atomically: true, encoding: .utf8)
        try setModificationDate(isoDate("2026-01-01T00:00:00.000Z"), for: logURL)

        let replaced = scanner.scan(modifiedAfter: isoDate("2025-12-31T00:00:00.000Z"))
        try expect(
            replaced.events.map(\.id).count == 2,
            "mtime-regressed growing file is fully reparsed instead of mixing stale cache"
        )
        try expect(
            Aggregation.totalUsage(events: replaced.events).total == 50,
            "mtime-regressed growing file keeps replacement totals"
        )
    }

    private static func claudeLogLine(requestId: String, input: Int) -> String {
        """
        {"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"session-a","requestId":"\(requestId)","uuid":"\(requestId)-uuid","cwd":"/tmp/project-a","type":"assistant","message":{"model":"claude-opus","usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
    }
}
