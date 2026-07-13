import Foundation
import SQLite3
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runHermesScannerTests() throws {
        try scannerImportsHermesCodexUsageAsStableDeltas()
        try scannerRebuildsHermesCacheWithoutSyncDuplication()
        try scannerToleratesMissingHermesDatabaseAndSchemaDrift()
        try scannerReadsHermesSchemaWithOptionalColumnsMissing()
        try scannerTimestampsUnlocatedDeltasAtObservationTime()
        try scannerClampsInvalidHermesCounters()
        try scannerSurvivesLockedHermesDatabase()
    }

    static func scannerImportsHermesCodexUsageAsStableDeltas() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let database = try HermesTestDatabase(homeDirectory: home)
        try database.createExpectedSchema()

        let endedAt = isoDate("2026-07-13T01:00:00.000Z").timeIntervalSince1970
        let activeMessageAt = isoDate("2026-07-13T02:00:00.000Z").timeIntervalSince1970
        try database.execute(
            """
            INSERT INTO sessions VALUES
              ('ended', 'cli', 'gpt-5.5', 1783900000, \(endedAt), 100, 40, 20, 5, 10, '/tmp/ended', 'openai-codex'),
              ('active', 'telegram', 'gpt-5.5', 1783901000, NULL, 50, 20, 10, 0, 5, '/tmp/active', 'openai-codex'),
              ('other', 'cli', 'other-model', 1783902000, \(endedAt), 999, 999, 999, 999, 999, '/tmp/other', 'openrouter'),
              ('empty', 'cli', 'gpt-5.5', 1783903000, \(endedAt), 0, 0, 0, 0, 0, '/tmp/empty', 'openai-codex');
            INSERT INTO messages (session_id, timestamp, token_count) VALUES
              ('ended', \(endedAt - 60), NULL),
              ('active', \(activeMessageAt), NULL);
            """
        )

        let device = TokenDeviceMetadata(id: "mac-hermes", name: "Hermes Mac")
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: device,
            cacheStore: try temporaryCache(in: directory)
        )

        let first = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        let firstUsage = Aggregation.totalUsage(events: first.events)
        try expect(first.events.count == 2, "Hermes imports only nonzero openai-codex sessions")
        try expect(firstUsage.input == 150, "Hermes input excludes separate cache buckets")
        try expect(firstUsage.cacheRead == 30, "Hermes cache reads counted once")
        try expect(firstUsage.cacheCreation == 5, "Hermes cache writes counted once")
        try expect(firstUsage.output == 60, "Hermes output includes reasoning")
        try expect(firstUsage.reasoning == 15, "Hermes reasoning retained as output subset")
        try expect(firstUsage.total == 245, "Hermes canonical total excludes duplicate reasoning")
        try expect(
            firstUsage.displayComponents(source: .codex).reduce(0) { $0 + $1.value } == firstUsage.total,
            "Codex component display matches Hermes total"
        )
        try expect(first.events.allSatisfy { $0.source == .codex }, "Hermes usage joins Codex source")
        try expect(first.events.allSatisfy { $0.deviceId == device.id }, "Hermes usage uses local device")
        try expect(first.events.allSatisfy { $0.rawFilePath.hasPrefix("hermes://") }, "Hermes origins remain distinguishable")
        try expect(first.events.first { $0.sessionId == "ended" }?.timestamp == Date(timeIntervalSince1970: endedAt), "ended_at wins baseline timestamp")
        try expect(first.events.first { $0.sessionId == "active" }?.timestamp == Date(timeIntervalSince1970: activeMessageAt), "message activity timestamps active baseline")
        try expect(first.sourceStatuses.contains { $0.label == "Hermes Agent" && $0.scannedFileCount == 1 }, "Hermes database scan status is visible")
        try expect(first.syncStatus.exportedEventCount == 2, "Hermes baselines export to local sync ledger")
        let cached = scanner.cachedResult()
        try expect(Aggregation.totalUsage(events: cached?.events ?? []).total == 245, "cached dashboard result includes Hermes usage")
        try expect(cached?.sourceStatuses.contains { $0.label == "Hermes Agent" && $0.scannedFileCount == 1 } == true, "cached dashboard reports Hermes source")

        let codexOnThisMac = Aggregation.filter(
            events: first.events,
            source: .codex,
            interval: DateInterval(
                start: isoDate("2026-07-13T00:00:00.000Z"),
                end: isoDate("2026-07-14T00:00:00.000Z")
            ),
            project: nil,
            model: nil,
            deviceId: device.id
        )
        try expect(codexOnThisMac.count == 2, "Hermes appears in Codex time and device filters")
        try expect(Aggregation.filter(events: first.events, source: .all, range: .all, project: nil, model: nil, deviceId: device.id).count == 2, "Hermes appears in All device filter")
        try expect(Set(codexOnThisMac.map(\.sessionId)).count == 2, "Hermes session count is preserved")
        try expect(Set(codexOnThisMac.map(\.deviceId)).count == 1, "Hermes device count is preserved")

        let unchanged = scanner.scan(syncFolder: syncFolder)
        try expect(unchanged.events.count == 2, "unchanged Hermes scan is idempotent")
        try expect(Aggregation.totalUsage(events: unchanged.events).total == 245, "unchanged Hermes totals do not grow")
        try expect(unchanged.syncStatus.exportedEventCount == 0, "unchanged Hermes scan does not append sync records")

        let deltaAt = isoDate("2026-07-13T03:00:00.000Z").timeIntervalSince1970
        try database.execute(
            """
            UPDATE sessions SET input_tokens = 70, output_tokens = 30,
              cache_read_tokens = 15, cache_write_tokens = 2, reasoning_tokens = 7
              WHERE id = 'active';
            INSERT INTO messages (session_id, timestamp, token_count) VALUES ('active', \(deltaAt), NULL);
            """
        )
        let grown = scanner.scan(syncFolder: syncFolder)
        try expect(grown.events.count == 3, "active Hermes growth creates one delta event")
        try expect(Aggregation.totalUsage(events: grown.events).total == 282, "active Hermes growth adds only the 37-token delta")
        let delta = grown.events.first { $0.timestamp == Date(timeIntervalSince1970: deltaAt) }
        try expect(delta?.usage.total == 37, "Hermes delta uses latest activity timestamp")
        try expect(delta?.usage.reasoning == 2, "Hermes reasoning delta remains an output subset")
        try expect(grown.syncStatus.exportedEventCount == 1, "Hermes delta appends one sync record")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 3, "Hermes sync ledger retains baselines and delta")
        let ledgerText = try syncLedgerText(syncFolder: syncFolder)
        try expect(!ledgerText.contains("/tmp/"), "Hermes sync ledger omits raw project paths")
        try expect(!ledgerText.contains("hermes://"), "Hermes sync ledger omits raw database origins")

        let resetAt = isoDate("2026-07-13T04:00:00.000Z").timeIntervalSince1970
        try database.execute(
            """
            UPDATE sessions SET input_tokens = 1, output_tokens = 0,
              cache_read_tokens = 0, cache_write_tokens = 0, reasoning_tokens = 0
              WHERE id = 'active';
            INSERT INTO messages (session_id, timestamp, token_count) VALUES ('active', \(resetAt), NULL);
            """
        )
        let reset = scanner.scan(syncFolder: syncFolder)
        try expect(reset.events.count == 3, "counter reset creates no negative or duplicate event")
        try expect(Aggregation.totalUsage(events: reset.events).total == 282, "counter reset preserves prior usage")

        let resumedAt = isoDate("2026-07-13T05:00:00.000Z").timeIntervalSince1970
        try database.execute(
            """
            UPDATE sessions SET input_tokens = 3 WHERE id = 'active';
            INSERT INTO messages (session_id, timestamp, token_count) VALUES ('active', \(resumedAt), NULL);
            """
        )
        let resumed = scanner.scan(syncFolder: syncFolder)
        try expect(resumed.events.count == 4, "post-reset growth creates a fresh delta")
        try expect(Aggregation.totalUsage(events: resumed.events).total == 284, "post-reset growth starts from reset checkpoint")
    }

    static func scannerToleratesMissingHermesDatabaseAndSchemaDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingHome = directory.appendingPathComponent("missing-home", isDirectory: true)
        let missing = TokenLogScanner(homeDirectory: missingHome, cacheStore: try temporaryCache(in: directory.appendingPathComponent("missing-cache"))).scan()
        try expect(missing.events.isEmpty, "missing Hermes database is harmless")

        let driftHome = directory.appendingPathComponent("drift-home", isDirectory: true)
        let driftDatabase = try HermesTestDatabase(homeDirectory: driftHome)
        try driftDatabase.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT);")
        let drift = TokenLogScanner(homeDirectory: driftHome, cacheStore: try temporaryCache(in: directory.appendingPathComponent("drift-cache"))).scan()
        try expect(drift.events.isEmpty, "Hermes schema drift is harmless")
        try expect(drift.parseErrorCount == 1, "Hermes schema drift is reported without crashing")
    }

    static func scannerRebuildsHermesCacheWithoutSyncDuplication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
        let database = try HermesTestDatabase(homeDirectory: home)
        try database.createExpectedSchema()
        try database.execute(
            """
            INSERT INTO sessions VALUES
              ('rebuild', 'cli', 'gpt-test', 1700000000, 1700000100,
               10, 5, 2, 1, 3, NULL, 'openai-codex');
            """
        )
        let device = TokenDeviceMetadata(id: "rebuild-mac", name: "Rebuild Mac")
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: device,
            cacheStore: try temporaryCache(in: directory.appendingPathComponent("cache"))
        )
        _ = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try database.execute(
            """
            UPDATE sessions SET input_tokens = 15, output_tokens = 7,
              cache_read_tokens = 3, cache_write_tokens = 2, reasoning_tokens = 4
              WHERE id = 'rebuild';
            """
        )
        let grown = scanner.scan(syncFolder: syncFolder)
        let expectedTotal = Aggregation.totalUsage(events: grown.events).total
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 2, "Hermes growth creates a second ledger delta before rebuild")

        try scanner.clearCache()
        let rebuilt = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: rebuilt.events).total == expectedTotal, "Hermes cache rebuild preserves total usage")
        try expect(try syncLedgerLineCount(syncFolder: syncFolder, deviceId: device.id) == 1, "full cache rebuild replaces old Hermes deltas with one cumulative baseline")
    }

    static func scannerReadsHermesSchemaWithOptionalColumnsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let database = try HermesTestDatabase(homeDirectory: home)
        try database.execute(
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, billing_provider TEXT, started_at REAL,
              input_tokens INTEGER
            );
            INSERT INTO sessions VALUES ('minimal', 'openai-codex', 1783900000, 12);
            """
        )
        let result = TokenLogScanner(
            homeDirectory: home,
            cacheStore: try temporaryCache(in: directory.appendingPathComponent("cache"))
        ).scan()
        try expect(result.parseErrorCount == 0, "missing optional Hermes columns do not fail the scan")
        try expect(result.events.count == 1, "minimal compatible Hermes schema imports usage")
        try expect(result.events.first?.usage.total == 12, "minimal Hermes schema defaults absent counters to zero")
    }

    static func scannerTimestampsUnlocatedDeltasAtObservationTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let database = try HermesTestDatabase(homeDirectory: home)
        try database.execute(
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, billing_provider TEXT, started_at REAL,
              input_tokens INTEGER
            );
            INSERT INTO sessions VALUES ('active', 'openai-codex', 1700000000, 10);
            """
        )
        let scanner = TokenLogScanner(
            homeDirectory: home,
            cacheStore: try temporaryCache(in: directory.appendingPathComponent("cache"))
        )
        _ = scanner.scan()

        try database.execute("UPDATE sessions SET input_tokens = 15 WHERE id = 'active';")
        let observedAfter = Date()
        let result = scanner.scan()
        let delta = result.events.first { $0.usage.input == 5 }
        try expect(delta != nil, "Hermes growth without message timestamps still creates a delta")
        try expect(
            (delta?.timestamp ?? .distantPast) >= observedAfter.addingTimeInterval(-1),
            "Hermes delta without persisted activity time uses observation time instead of stale started_at"
        )
    }

    static func scannerClampsInvalidHermesCounters() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let database = try HermesTestDatabase(homeDirectory: home)
        try database.createExpectedSchema()
        try database.execute(
            """
            INSERT INTO sessions VALUES
              ('limits', 'cli', 'gpt-test', 1700000000, 1700000100,
               -5, 9223372036854775807, 9223372036854775807,
               9223372036854775807, 9223372036854775807,
               NULL, 'openai-codex');
            """
        )
        let result = TokenLogScanner(
            homeDirectory: home,
            cacheStore: try temporaryCache(in: directory.appendingPathComponent("cache"))
        ).scan()
        try expect(result.events.first != nil, "large Hermes counters should import")
        let usage = result.events.first?.usage ?? .zero
        try expect(usage.input == 0, "negative Hermes counters clamp to zero")
        try expect(usage.output == Int.max, "Hermes counters clamp to platform integer bounds")
        try expect(usage.reasoning == usage.output, "Hermes reasoning remains bounded by output")
        try expect(usage.total == Int.max, "Hermes total saturates instead of overflowing")
    }

    static func scannerSurvivesLockedHermesDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let database = try HermesTestDatabase(homeDirectory: home)
        try database.createExpectedSchema()
        try database.execute(
            """
            PRAGMA wal_checkpoint(TRUNCATE);
            PRAGMA journal_mode = DELETE;
            BEGIN EXCLUSIVE;
            """
        )
        defer { try? database.execute("ROLLBACK;") }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = TokenLogScanner(
            homeDirectory: home,
            cacheStore: try temporaryCache(in: directory.appendingPathComponent("cache"))
        ).scan()
        let elapsed = clock.now - startedAt
        try expect(result.events.isEmpty, "locked Hermes database returns no partial events")
        try expect(result.parseErrorCount == 1, "locked Hermes database reports one source error")
        try expect(elapsed < .seconds(8), "Hermes database lock returns within the configured timeout")
    }
}

private final class HermesTestDatabase {
    private var database: OpaquePointer?

    init(homeDirectory: URL) throws {
        let directory = homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.db")
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "HermesTestDatabase", code: 1)
        }
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    deinit {
        sqlite3_close(database)
    }

    func createExpectedSchema() throws {
        try execute(
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL,
              ended_at REAL, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
              reasoning_tokens INTEGER DEFAULT 0, cwd TEXT, billing_provider TEXT
            );
            CREATE TABLE messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
              timestamp REAL NOT NULL, token_count INTEGER
            );
            """
        )
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(error)
            throw NSError(domain: "HermesTestDatabase", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
