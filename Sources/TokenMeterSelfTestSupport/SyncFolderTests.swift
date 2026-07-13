import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runSyncFolderTests() throws {
        try syncFolderMergesDeviceLedgersAndDeduplicatesLocalEvents()
        try syncFolderAppendsOnlyNewLocalEvents()
        try syncFolderImportsOnlyRequestedWindow()
        try syncFolderImportsPlainTimestampWindowPrecisely()
        try syncFolderCountsMalformedCanonicalTimestampAsParseError()
        try syncFolderWindowImportAcceptsWhitespaceFormattedJSON()
        try syncFolderNormalizesDecodedUsageValues()
        try syncFolderReusesCachedDeviceLedgers()
        try syncFolderFiltersCachedDeviceLedgersByRequestedWindow()
        try syncFolderAppendsCachedDeviceLedgerIncrementally()
        try syncFolderReadsOnlyAppendedDeviceLedgerLines()
        try syncFolderDeduplicatesAppendedDeviceLedgerRecords()
        try syncFolderCancellationSkipsPartialLocalLedgerWrite()
        try scannerMergesFreshWindowedSyncEventsWithCachedHistory()
        try scannerKeepsSyncedCodexUsageAfterLocalSessionFilesAreRemoved()
        try scannerKeepsMergedDeviceUsageAfterOneMacRemovesLocalSessionFiles()
        try scannerRebuildsMissingLocalSyncLedgerAfterCodexSessionsAreRemoved()
        try scannerDoesNotEraseExistingCodexLedgerWhenLocalSessionsAndCacheAreGone()
        try scannerRestoresMissingLocalSyncLedgerFromCachedLocalHistory()
        try scannerExcludesCachedSyncEventsWhenSyncFolderIsDisabled()
        try scannerPrunesCachedSyncEventsWhenDeviceLedgerDisappears()
        try scannerPrunesCachedSyncEventsWhenDevicesDirectoryDisappears()
        try syncFolderIgnoresJSONLDirectories()
        try syncFolderIgnoresNestedJSONLFiles()
        try scannerListsSyncedDeviceOutsideRequestedEventWindow()
    }

    static func scannerListsSyncedDeviceOutsideRequestedEventWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let remoteDevice = TokenDeviceMetadata(id: "remote-mac", name: "Hermes Mac")
        let remoteStore = TokenSyncLedgerStore(folder: syncFolder, localDevice: remoteDevice)
        let oldEvent = TokenEvent(
            id: "old-remote-event",
            source: .codex,
            timestamp: isoDate("2026-07-01T00:00:00.000Z"),
            deviceId: remoteDevice.id,
            deviceName: remoteDevice.name,
            projectPath: "/tmp/remote",
            sessionId: "remote-session",
            model: "gpt-5.5",
            usage: TokenUsage(input: 10),
            rawFilePath: "/tmp/remote.jsonl"
        )
        _ = remoteStore.synchronize(localEvents: [oldEvent], replaceLocalLedger: true)

        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "local-mac", name: "This Mac"),
            cacheStore: try temporaryCache(in: directory.appendingPathComponent("cache"))
        )
        let recentStart = isoDate("2026-07-13T00:00:00.000Z")
        let result = scanner.scan(
            modifiedAfter: recentStart,
            eventAfter: recentStart,
            syncFolder: syncFolder
        )

        try expect(result.events.allSatisfy { $0.deviceId != remoteDevice.id }, "old remote events stay outside requested window")
        try expect(result.syncDevices.contains(remoteDevice), "synced device remains available outside requested event window")
    }

    static func syncFolderMergesDeviceLedgersAndDeduplicatesLocalEvents() throws {
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
        try expect(
            mergedA.events.first { $0.deviceId == "mac-a" }?.projectPath == "/tmp/secret-project-a",
            "local events keep full project details"
        )
        try expect(
            mergedA.events.first { $0.deviceId == "mac-b" }?.projectPath.hasPrefix("Project ") == true,
            "remote sync events keep hashed project display"
        )

        let ledgerText = try syncLedgerText(syncFolder: syncFolder)
        try expect(!ledgerText.contains("secret-project"), "sync ledger omits raw project paths")
        try expect(!ledgerText.contains(".claude"), "sync ledger omits raw log paths")
        try expect(!ledgerText.contains("session-a"), "sync ledger omits raw local session ids")
        try expect(!ledgerText.contains("session-b"), "sync ledger omits raw remote session ids")
        try expect(!ledgerText.contains("request-a"), "sync ledger omits raw local request ids")
        try expect(!ledgerText.contains("request-b"), "sync ledger omits raw remote request ids")
    }

    static func syncFolderAppendsOnlyNewLocalEvents() throws {
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

    static func syncFolderImportsOnlyRequestedWindow() throws {
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

    static func syncFolderImportsPlainTimestampWindowPrecisely() throws {
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
            timestamp: isoDate("2026-01-01T00:00:01.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/recent.jsonl"
        )

        _ = store.synchronize(localEvents: [oldEvent, recentEvent], replaceLocalLedger: true)
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        let rewritten = try String(contentsOf: ledgerURL, encoding: .utf8)
            .replacingOccurrences(
                of: "\"timestamp\":\"2026-01-01T00:00:00.000Z\"",
                with: "\"timestamp\":\"2026-01-01T00:00:00Z\""
            )
        try rewritten.write(to: ledgerURL, atomically: true, encoding: .utf8)
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: ledgerURL)

        let windowed = store.synchronize(
            localEvents: [],
            importedAfter: isoDate("2026-01-01T00:00:00.500Z")
        )
        try expect(windowed.events.map(\.id) == ["recent"], "sync import compares plain timestamps as dates")
        try expect(windowed.status.parseErrorCount == 0, "sync import accepts plain ISO timestamps")
    }

    static func scannerKeepsSyncedCodexUsageAfterLocalSessionFilesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: device)
        let codexLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "session-a.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10,
            output: 5
        )

        let initial = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: initial.events).total == 15, "initial Codex sync total")
        try expect(initial.syncStatus.exportedEventCount == 1, "initial Codex sync exports one event")

        try FileManager.default.removeItem(at: codexLog)
        let removed = scanner.scan(syncFolder: syncFolder)
        try expect(Aggregation.totalUsage(events: removed.events).total == 15, "synced Codex total survives removed local session file")
        try expect(removed.events.first?.rawFilePath.hasPrefix("sync://") == true, "removed local session is restored from sync ledger")
    }

    static func scannerKeepsMergedDeviceUsageAfterOneMacRemovesLocalSessionFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeA = directory.appendingPathComponent("home-a", isDirectory: true)
        let homeB = directory.appendingPathComponent("home-b", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let logA = try writeCodexLog(
            homeDirectory: homeA,
            fileName: "session-a.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10
        )
        try writeCodexLog(
            homeDirectory: homeB,
            fileName: "session-b.jsonl",
            timestamp: "2026-01-01T00:01:00.000Z",
            cwd: "/tmp/codex-project-b",
            input: 20
        )

        let deviceA = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let deviceB = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scannerA = TokenLogScanner(homeDirectory: homeA, localDevice: deviceA)
        let scannerB = TokenLogScanner(homeDirectory: homeB, localDevice: deviceB)

        let firstA = scannerA.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: firstA.events).total == 10, "first Mac exports local Codex total")
        let firstB = scannerB.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: firstB.events).total == 30, "second Mac sees merged Codex total")

        try FileManager.default.removeItem(at: logA)
        let mergedA = scannerA.scan(syncFolder: syncFolder)
        try expect(Aggregation.totalUsage(events: mergedA.events).total == 30, "merged Codex total survives one Mac pruning local sessions")
        try expect(Set(mergedA.events.map(\.deviceId)) == ["mac-a", "mac-b"], "merged Codex events keep both device ids")
    }

    static func scannerRebuildsMissingLocalSyncLedgerAfterCodexSessionsAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: device, cacheStore: cache)
        let codexLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "session-a.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10,
            output: 5
        )

        let initial = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: initial.events).total == 15, "initial Codex cache warms local history")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1, "initial Codex local ledger exists")

        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        try FileManager.default.removeItem(at: codexLog)
        try FileManager.default.removeItem(at: ledgerURL)

        let restored = scanner.scan(syncFolder: syncFolder)
        try expect(Aggregation.totalUsage(events: restored.events).total == 15, "Codex cache survives local session removal")
        try expect(
            try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1,
            "missing Codex local ledger is rebuilt from cached history"
        )
    }

    static func scannerDoesNotEraseExistingCodexLedgerWhenLocalSessionsAndCacheAreGone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let firstCache = try temporaryCache(in: directory.appendingPathComponent("first-cache", isDirectory: true))
        let firstScanner = TokenLogScanner(homeDirectory: home, localDevice: device, cacheStore: firstCache)
        let codexLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "session-a.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10,
            output: 5
        )

        let initial = firstScanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: initial.events).total == 15, "initial Codex ledger is exported")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1, "initial Codex ledger line exists")

        try FileManager.default.removeItem(at: codexLog)
        let emptyCache = try temporaryCache(in: directory.appendingPathComponent("empty-cache", isDirectory: true))
        let rebuiltScanner = TokenLogScanner(homeDirectory: home, localDevice: device, cacheStore: emptyCache)

        let rebuilt = rebuiltScanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(
            try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1,
            "replace sync keeps existing Codex ledger when local sessions and cache are gone"
        )
        try expect(
            Aggregation.totalUsage(events: rebuilt.events).total == 15,
            "replace sync imports existing Codex ledger instead of erasing it"
        )
    }

    static func syncFolderCountsMalformedCanonicalTimestampAsParseError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let store = TokenSyncLedgerStore(folder: syncFolder, localDevice: device)
        let event = TokenEvent(
            id: "malformed",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/malformed.jsonl"
        )

        _ = store.synchronize(localEvents: [event], replaceLocalLedger: true)
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        let rewritten = try String(contentsOf: ledgerURL, encoding: .utf8)
            .replacingOccurrences(
                of: "\"timestamp\":\"2026-01-01T00:00:00.000Z\"",
                with: "\"timestamp\":\"1026-01-01T00:00:0x.000Z\""
            )
        try rewritten.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let windowed = store.synchronize(
            localEvents: [],
            importedAfter: isoDate("2026-01-01T00:00:00.500Z")
        )
        try expect(windowed.events.isEmpty, "malformed sync timestamp imports no events")
        try expect(windowed.status.parseErrorCount == 1, "malformed sync timestamp is counted as parse error")
    }

    static func syncFolderWindowImportAcceptsWhitespaceFormattedJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        let devicesURL = syncFolder.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)

        let ledgerURL = devicesURL.appendingPathComponent("mac-b.jsonl")
        try """
        { "device_id" : "mac-b", "device_name" : "Mac B", "event_id" : "old-spaced", "model" : "claude-opus", "project_hash" : "abcdef123456", "schema_version" : 1, "session_hash" : "123456abcdef", "source" : "claude", "timestamp" : "2026-01-01T00:00:00.000Z", "usage" : { "input" : 10, "cachedInput" : 0, "cacheCreation" : 0, "cacheRead" : 0, "output" : 0, "reasoning" : 0, "total" : 10 } }
        { "device_id" : "mac-b", "device_name" : "Mac B", "event_id" : "recent-spaced", "model" : "claude-opus", "project_hash" : "abcdef123456", "schema_version" : 1, "session_hash" : "123456abcdef", "source" : "claude", "timestamp" : "2026-01-02T00:00:00.000Z", "usage" : { "input" : 20, "cachedInput" : 0, "cacheCreation" : 0, "cacheRead" : 0, "output" : 0, "reasoning" : 0, "total" : 20 } }
        """.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let store = TokenSyncLedgerStore(
            folder: syncFolder,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        )
        let windowed = store.synchronize(
            localEvents: [],
            importedAfter: isoDate("2026-01-01T12:00:00.000Z")
        )

        try expect(windowed.events.map(\.id) == ["recent-spaced"], "windowed sync accepts whitespace-formatted JSON")
        try expect(windowed.status.parseErrorCount == 0, "windowed sync does not reject decodable spaced JSON")
    }

    static func syncFolderNormalizesDecodedUsageValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        let devicesURL = syncFolder.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)

        let ledgerURL = devicesURL.appendingPathComponent("mac-b.jsonl")
        try """
        {"device_id":"mac-b","device_name":"Mac B","event_id":"malformed-usage","model":"claude-opus","project_hash":"abcdef123456","schema_version":1,"session_hash":"123456abcdef","source":"claude","timestamp":"2026-01-01T00:00:00.000Z","usage":{"input":-100,"cachedInput":-1,"cacheCreation":2,"cacheRead":3,"output":5,"reasoning":-2,"total":-1}}
        """.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: try temporaryCache(in: directory)
        )
        let result = scanner.scan(syncFolder: syncFolder)
        try expect(result.syncStatus.parseErrorCount == 0, "sync folder accepts normalizable usage values")
        try expect(result.events.count == 1, "sync folder keeps normalized usage event")
        try expect(result.events.first?.usage.input == 0, "sync folder clamps decoded input")
        try expect(result.events.first?.usage.total == 10, "sync folder recomputes invalid decoded total")
    }

    static func syncFolderReusesCachedDeviceLedgers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let store = TokenSyncLedgerStore(folder: syncFolder, localDevice: device, cacheStore: cache)
        let event = TokenEvent(
            id: "event-a",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            projectPath: "/tmp/project-a",
            sessionId: "session-a",
            model: "claude-opus",
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/a.jsonl"
        )

        _ = store.synchronize(localEvents: [event], replaceLocalLedger: true)
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        let cachedDate = isoDate("2026-01-01T00:10:00.000Z")
        try setModificationDate(cachedDate, for: ledgerURL)

        let cached = store.synchronize(localEvents: [])
        try expect(cached.events.map(\.id) == ["event-a"], "sync ledger caches valid records")

        try overwriteWithInvalidContentPreservingSizeAndDate(url: ledgerURL, date: cachedDate)
        let unchanged = store.synchronize(localEvents: [])
        try expect(unchanged.events.map(\.id) == ["event-a"], "unchanged sync ledger uses cached records")
        try expect(unchanged.status.parseErrorCount == 0, "unchanged sync ledger avoids parse errors")
    }

    static func syncFolderFiltersCachedDeviceLedgersByRequestedWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let store = TokenSyncLedgerStore(folder: syncFolder, localDevice: device, cacheStore: cache)
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
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        let cachedDate = isoDate("2026-01-02T00:10:00.000Z")
        try setModificationDate(cachedDate, for: ledgerURL)

        let cached = store.synchronize(localEvents: [])
        try expect(cached.events.map(\.id) == ["old", "recent"], "sync ledger warms timestamped cache")

        try overwriteWithInvalidContentPreservingSizeAndDate(url: ledgerURL, date: cachedDate)
        let windowed = store.synchronize(
            localEvents: [],
            importedAfter: isoDate("2026-01-01T12:00:00.000Z")
        )
        try expect(windowed.events.map(\.id) == ["recent"], "cached sync import filters old records")
        try expect(windowed.status.parseErrorCount == 0, "windowed cached sync avoids reparse errors")
    }

    static func syncFolderAppendsCachedDeviceLedgerIncrementally() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let store = TokenSyncLedgerStore(folder: syncFolder, localDevice: device, cacheStore: cache)
        let firstEvent = TokenEvent(
            id: "first",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/first.jsonl"
        )
        let secondEvent = TokenEvent(
            id: "second",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:01:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/second.jsonl"
        )

        _ = store.synchronize(localEvents: [firstEvent], replaceLocalLedger: true)
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        let cachedDate = isoDate("2026-01-01T00:10:00.000Z")
        try setModificationDate(cachedDate, for: ledgerURL)
        _ = store.synchronize(localEvents: [])

        let updated = store.synchronize(localEvents: [firstEvent, secondEvent])
        try expect(updated.status.exportedEventCount == 1, "cached sync append exports only new event")

        let appendedDate = try FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.modificationDate] as? Date
        try overwriteWithInvalidContentPreservingSizeAndDate(url: ledgerURL, date: appendedDate ?? Date())
        let cached = store.synchronize(localEvents: [])
        try expect(cached.events.map(\.id) == ["first", "second"], "cached sync append keeps prior events")
        try expect(cached.status.parseErrorCount == 0, "cached sync append avoids full reparse")
    }

    static func syncFolderReadsOnlyAppendedDeviceLedgerLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let readerDevice = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let writerDevice = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let reader = TokenSyncLedgerStore(folder: syncFolder, localDevice: readerDevice, cacheStore: cache)
        let writer = TokenSyncLedgerStore(folder: syncFolder, localDevice: writerDevice)
        let firstEvent = TokenEvent(
            id: "first",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: writerDevice.id,
            deviceName: writerDevice.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/first.jsonl"
        )
        let secondEvent = TokenEvent(
            id: "second",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:01:00.000Z"),
            deviceId: writerDevice.id,
            deviceName: writerDevice.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/second.jsonl"
        )

        _ = writer.synchronize(localEvents: [firstEvent], replaceLocalLedger: true)
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(writerDevice.id).jsonl")
        _ = reader.synchronize(localEvents: [])
        let cachedSize = try FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.size] as? NSNumber

        _ = writer.synchronize(localEvents: [firstEvent, secondEvent])
        try overwritePrefixWithInvalidContent(
            url: ledgerURL,
            byteCount: min(max((cachedSize?.intValue ?? 0) - 1, 0), 16)
        )

        let incrementallyRead = reader.synchronize(localEvents: [])
        try expect(incrementallyRead.events.map(\.id) == ["first", "second"], "grown sync ledger reuses cached prefix")
        try expect(incrementallyRead.status.parseErrorCount == 0, "grown sync ledger reads only appended lines")
    }

    static func syncFolderDeduplicatesAppendedDeviceLedgerRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let readerDevice = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let writerDevice = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let reader = TokenSyncLedgerStore(folder: syncFolder, localDevice: readerDevice, cacheStore: cache)
        let writer = TokenSyncLedgerStore(folder: syncFolder, localDevice: writerDevice)
        let event = TokenEvent(
            id: "duplicate",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: writerDevice.id,
            deviceName: writerDevice.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/duplicate.jsonl"
        )

        _ = writer.synchronize(localEvents: [event], replaceLocalLedger: true)
        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(writerDevice.id).jsonl")
        let warm = reader.synchronize(localEvents: [])
        try expect(warm.events.map(\.id) == ["duplicate"], "sync ledger warms duplicate test cache")

        let original = try String(contentsOf: ledgerURL, encoding: .utf8)
        try (original + original).write(to: ledgerURL, atomically: true, encoding: .utf8)
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: ledgerURL)

        let deduplicated = reader.synchronize(localEvents: [])
        try expect(deduplicated.events.map(\.id) == ["duplicate"], "sync ledger ignores appended duplicate records")
        try expect(Aggregation.totalUsage(events: deduplicated.events).total == 10, "duplicate sync records do not inflate totals")
        try expect(deduplicated.status.importedEventCount == 1, "duplicate sync records do not inflate import count")
        try expect(deduplicated.status.parseErrorCount == 0, "duplicate sync records are not parse errors")

        let laterDuplicate = original.replacingOccurrences(
            of: "\"timestamp\":\"2026-01-01T00:00:00.000Z\"",
            with: "\"timestamp\":\"2026-01-02T00:00:00.000Z\""
        )
        let current = try String(contentsOf: ledgerURL, encoding: .utf8)
        try (current + laterDuplicate).write(to: ledgerURL, atomically: true, encoding: .utf8)
        try setModificationDate(isoDate("2026-01-02T00:10:00.000Z"), for: ledgerURL)

        let windowed = reader.synchronize(
            localEvents: [],
            importedAfter: isoDate("2026-01-01T12:00:00.000Z")
        )
        try expect(windowed.events.isEmpty, "windowed sync ignores later duplicate records already in cache")
        try expect(windowed.status.importedEventCount == 0, "windowed duplicate sync does not inflate import count")
    }

    static func syncFolderCancellationSkipsPartialLocalLedgerWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let store = TokenSyncLedgerStore(folder: syncFolder, localDevice: device)
        let firstEvent = TokenEvent(
            id: "first",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/first.jsonl"
        )
        let secondEvent = TokenEvent(
            id: "second",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:01:00.000Z"),
            deviceId: device.id,
            deviceName: device.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/second.jsonl"
        )

        var cancellationChecks = 0
        _ = store.synchronize(localEvents: [firstEvent, secondEvent], replaceLocalLedger: true) {
            cancellationChecks += 1
            return cancellationChecks >= 3
        }

        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        try expect(!FileManager.default.fileExists(atPath: ledgerURL.path), "cancelled sync does not write a partial local ledger")
    }

    static func scannerMergesFreshWindowedSyncEventsWithCachedHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeA = directory.appendingPathComponent("home-a", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let deviceA = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let deviceB = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scannerA = TokenLogScanner(homeDirectory: homeA, localDevice: deviceA, cacheStore: cache)
        let storeB = TokenSyncLedgerStore(folder: syncFolder, localDevice: deviceB)
        let oldRemoteEvent = TokenEvent(
            id: "old-remote",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            deviceId: deviceB.id,
            deviceName: deviceB.name,
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/old-remote.jsonl"
        )
        let newRemoteEvent = TokenEvent(
            id: "new-remote",
            source: .claude,
            timestamp: isoDate("2026-01-03T00:00:00.000Z"),
            deviceId: deviceB.id,
            deviceName: deviceB.name,
            usage: TokenUsage(total: 20),
            rawFilePath: "/tmp/new-remote.jsonl"
        )

        _ = storeB.synchronize(localEvents: [oldRemoteEvent], replaceLocalLedger: true)
        let initial = scannerA.scan(syncFolder: syncFolder)
        try expect(initial.events.map(\.id) == ["old-remote"], "initial scanner sync warms remote cache")

        _ = storeB.synchronize(localEvents: [oldRemoteEvent, newRemoteEvent])
        let refreshed = scannerA.scan(
            modifiedAfter: isoDate("2026-01-02T00:00:00.000Z"),
            eventAfter: isoDate("2026-01-01T00:00:00.000Z"),
            syncFolder: syncFolder
        )
        try expect(
            refreshed.events.map(\.id) == ["old-remote", "new-remote"],
            "recent scanner sync merges freshly read remote events with cached history"
        )
        try expect(Aggregation.totalUsage(events: refreshed.events).total == 30, "recent scanner sync keeps remote total")
    }

    static func scannerRestoresMissingLocalSyncLedgerFromCachedLocalHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: device, cacheStore: cache)
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
        let recentURL = try writeClaudeLog(
            homeDirectory: home,
            fileName: "recent.jsonl",
            timestamp: "2026-01-03T00:00:00.000Z",
            cwd: "/tmp/project-a",
            sessionId: "session-b",
            requestId: "request-recent",
            input: 20
        )
        try setModificationDate(isoDate("2026-01-03T00:05:00.000Z"), for: recentURL)

        let initial = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: initial.events).total == 30, "initial local sync exports all history")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 2, "initial local ledger has all history")

        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(device.id).jsonl")
        try FileManager.default.removeItem(at: ledgerURL)

        let refreshed = scanner.scan(
            modifiedAfter: isoDate("2026-01-02T00:00:00.000Z"),
            eventAfter: isoDate("2025-12-31T00:00:00.000Z"),
            syncFolder: syncFolder
        )
        try expect(Aggregation.totalUsage(events: refreshed.events).total == 30, "recent sync still shows cached local history")
        try expect(
            try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 2,
            "missing local ledger is rebuilt from cached local history"
        )
    }

    static func scannerExcludesCachedSyncEventsWhenSyncFolderIsDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeA = directory.appendingPathComponent("home-a", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let deviceA = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let deviceB = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scannerA = TokenLogScanner(homeDirectory: homeA, localDevice: deviceA, cacheStore: cache)
        let storeB = TokenSyncLedgerStore(folder: syncFolder, localDevice: deviceB)
        let remoteEvent = TokenEvent(
            id: "remote",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/remote.jsonl"
        )

        _ = storeB.synchronize(localEvents: [remoteEvent], replaceLocalLedger: true)
        let withSync = scannerA.scan(syncFolder: syncFolder)
        try expect(withSync.events.map(\.id) == ["remote"], "sync scan warms remote cache")

        let cachedWithoutSync = scannerA.cachedResult()
        try expect(cachedWithoutSync == nil, "disabled sync cached result excludes remote events")

        let withoutSync = scannerA.scan()
        try expect(withoutSync.events.isEmpty, "disabled sync does not show cached remote events")
    }

    static func scannerPrunesCachedSyncEventsWhenDeviceLedgerDisappears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeA = directory.appendingPathComponent("home-a", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let deviceA = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let deviceB = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scannerA = TokenLogScanner(homeDirectory: homeA, localDevice: deviceA, cacheStore: cache)
        let storeB = TokenSyncLedgerStore(folder: syncFolder, localDevice: deviceB)
        let remoteEvent = TokenEvent(
            id: "removed-remote",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/removed-remote.jsonl"
        )

        _ = storeB.synchronize(localEvents: [remoteEvent], replaceLocalLedger: true)
        let withSync = scannerA.scan(syncFolder: syncFolder)
        try expect(withSync.events.map(\.id) == ["removed-remote"], "sync scan caches removable ledger")

        let ledgerURL = syncFolder
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent("\(deviceB.id).jsonl")
        try FileManager.default.removeItem(at: ledgerURL)

        let cachedAfterRemoval = scannerA.cachedResult(syncFolder: syncFolder)
        try expect(cachedAfterRemoval == nil, "cached result excludes removed sync ledger before refresh")

        let afterRemoval = scannerA.scan(syncFolder: syncFolder)
        try expect(afterRemoval.syncStatus.deviceFileCount == 0, "removed sync ledger is not counted")
        try expect(afterRemoval.events.isEmpty, "removed sync ledger is pruned from cache")
    }

    static func scannerPrunesCachedSyncEventsWhenDevicesDirectoryDisappears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeA = directory.appendingPathComponent("home-a", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let deviceA = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let deviceB = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let scannerA = TokenLogScanner(homeDirectory: homeA, localDevice: deviceA, cacheStore: cache)
        let storeB = TokenSyncLedgerStore(folder: syncFolder, localDevice: deviceB)
        let remoteEvent = TokenEvent(
            id: "removed-directory-remote",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/removed-directory-remote.jsonl"
        )

        _ = storeB.synchronize(localEvents: [remoteEvent], replaceLocalLedger: true)
        let withSync = scannerA.scan(syncFolder: syncFolder)
        try expect(withSync.events.map(\.id) == ["removed-directory-remote"], "sync scan caches removable devices directory")

        let devicesURL = syncFolder.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.removeItem(at: devicesURL)

        let cachedAfterRemoval = scannerA.cachedResult(syncFolder: syncFolder)
        try expect(cachedAfterRemoval == nil, "cached result excludes removed devices directory before refresh")

        let afterRemoval = scannerA.scan(syncFolder: syncFolder)
        try expect(afterRemoval.syncStatus.deviceFileCount == 0, "removed devices directory has no ledgers")
        try expect(afterRemoval.events.isEmpty, "removed devices directory prunes sync cache")
    }

    static func syncFolderIgnoresJSONLDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        let devices = syncFolder.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(
            at: devices.appendingPathComponent("not-a-ledger.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )

        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )
        let result = scanner.scan(syncFolder: syncFolder)
        try expect(result.syncStatus.deviceFileCount == 0, "sync folder ignores .jsonl directories")
        try expect(result.syncStatus.parseErrorCount == 0, "sync folder avoids parse errors for .jsonl directories")
        try expect(result.events.isEmpty, "sync folder keeps no directory-backed events")
    }

    static func syncFolderIgnoresNestedJSONLFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let writerDevice = TokenDeviceMetadata(id: "mac-b", name: "Mac B")
        let writer = TokenSyncLedgerStore(folder: syncFolder, localDevice: writerDevice)
        let nestedEvent = TokenEvent(
            id: "nested-remote",
            source: .claude,
            timestamp: isoDate("2026-01-01T00:00:00.000Z"),
            usage: TokenUsage(total: 10),
            rawFilePath: "/tmp/nested-remote.jsonl"
        )
        _ = writer.synchronize(localEvents: [nestedEvent], replaceLocalLedger: true)

        let devicesURL = syncFolder.appendingPathComponent("devices", isDirectory: true)
        let directLedgerURL = devicesURL.appendingPathComponent("\(writerDevice.id).jsonl")
        let nestedDirectoryURL = devicesURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: directLedgerURL,
            to: nestedDirectoryURL.appendingPathComponent("ignored.jsonl")
        )

        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: try temporaryCache(in: directory)
        )
        let result = scanner.scan(syncFolder: syncFolder)
        try expect(result.syncStatus.deviceFileCount == 0, "sync folder ignores nested .jsonl files")
        try expect(result.syncStatus.parseErrorCount == 0, "sync folder avoids parse errors for nested .jsonl files")
        try expect(result.events.isEmpty, "sync folder keeps no nested ledger events")
    }

}
