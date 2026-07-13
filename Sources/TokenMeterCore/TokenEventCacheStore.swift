import Foundation
import SQLite3

public final class TokenEventCacheStore: @unchecked Sendable {
    static let parserVersion = 4
    private static let timestampTolerance: TimeInterval = 0.000_001

    struct FileSnapshot {
        var path: String
        var source: TokenSource?
        var size: Int64
        var modifiedAt: Date
        var deviceId: String?

        static func make(
            for url: URL,
            source: TokenSource?,
            deviceId: String?,
            fileManager: FileManager = .default
        ) -> FileSnapshot? {
            let path = url.resolvingSymlinksInPath().path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                return nil
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return FileSnapshot(
                path: path,
                source: source,
                size: size,
                modifiedAt: modifiedAt,
                deviceId: deviceId
            )
        }

        static func make(
            for url: URL,
            source: TokenSource?,
            deviceId: String?,
            size: Int64,
            modifiedAt: Date
        ) -> FileSnapshot {
            return FileSnapshot(
                path: url.resolvingSymlinksInPath().path,
                source: source,
                size: size,
                modifiedAt: modifiedAt,
                deviceId: deviceId
            )
        }
    }

    enum OriginKind: String {
        case localLog = "local_log"
        case hermesDatabase = "hermes_database"
        case syncLedger = "sync_ledger"
    }

    struct HermesCheckpoint {
        var usage: TokenUsage
        var sequence: Int
    }

    struct HermesCheckpointUpdate {
        var sessionId: String
        var usage: TokenUsage
        var sequence: Int
        var event: TokenEvent?
    }

    enum CachedFile {
        case events([TokenEvent])
        case parseError
    }

    struct IncrementalAppendBase {
        var size: Int64
        var modifiedAt: Date
    }

    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            throw CacheError(message: "Could not open token cache at \(databaseURL.path)")
        }

        sqlite3_busy_timeout(database, 5_000)
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    public static func defaultStore(fileManager: FileManager = .default) -> TokenEventCacheStore? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = appSupport.appendingPathComponent("TokenMeter", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("TokenMeter.sqlite")
        return try? TokenEventCacheStore(databaseURL: databaseURL)
    }

    func cachedEvents(
        for snapshot: FileSnapshot,
        originKind: OriginKind,
        modifiedAfter: Date? = nil
    ) throws -> CachedFile? {
        try locked {
            guard let metadata = try metadata(for: snapshot, originKind: originKind),
                  metadataMatches(metadata, snapshot: snapshot) else {
                return nil
            }
            if metadata.parseError {
                return .parseError
            }
            return .events(try eventsForOrigin(originKind: originKind, path: snapshot.path, modifiedAfter: modifiedAfter))
        }
    }

    func cachedEventKeys(for snapshot: FileSnapshot, originKind: OriginKind) throws -> Set<String>? {
        try locked {
            guard let metadata = try metadata(for: snapshot, originKind: originKind),
                  metadataMatches(metadata, snapshot: snapshot),
                  !metadata.parseError else {
                return nil
            }

            var statement: OpaquePointer?
            try prepare(
                """
                SELECT device_id, event_id
                FROM event_records
                WHERE origin_kind = ? AND origin_path = ?
                """,
                into: &statement
            )
            defer { sqlite3_finalize(statement) }
            bind(originKind.rawValue, to: statement, at: 1)
            bind(snapshot.path, to: statement, at: 2)

            var keys = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                let deviceId = columnString(statement, 0)
                let eventId = columnString(statement, 1)
                keys.insert("\(deviceId)|\(eventId)")
            }
            return keys
        }
    }

    func codexLocalLogEventKeys(originPath: String) throws -> Set<String>? {
        try locked {
            var metadataStatement: OpaquePointer?
            try prepare(
                """
                SELECT parse_error
                FROM origin_files
                WHERE origin_kind = ? AND origin_path = ? AND source = ?
                """,
                into: &metadataStatement
            )
            defer { sqlite3_finalize(metadataStatement) }
            bind(OriginKind.localLog.rawValue, to: metadataStatement, at: 1)
            bind(originPath, to: metadataStatement, at: 2)
            bind(TokenSource.codex.rawValue, to: metadataStatement, at: 3)
            guard sqlite3_step(metadataStatement) == SQLITE_ROW else {
                return nil
            }
            guard sqlite3_column_int(metadataStatement, 0) == 0 else {
                return nil
            }

            return try eventKeys(originKind: .localLog, originPath: originPath, source: .codex)
        }
    }

    func syncLedgerEventKeys() throws -> Set<String> {
        try locked {
            try eventKeys(originKind: .syncLedger, originPath: nil, source: nil)
        }
    }

    func incrementalAppendBase(for snapshot: FileSnapshot, originKind: OriginKind) throws -> IncrementalAppendBase? {
        try locked {
            guard let metadata = try metadata(for: snapshot, originKind: originKind),
                  metadata.parserVersion == Self.parserVersion,
                  metadata.deviceId == snapshot.deviceId,
                  metadata.source == snapshot.source,
                  !metadata.parseError,
                  metadata.size > 0,
                  snapshot.modifiedAt.timeIntervalSince1970 + Self.timestampTolerance >= metadata.modifiedAt,
                  snapshot.size > metadata.size else {
                return nil
            }
            return IncrementalAppendBase(
                size: metadata.size,
                modifiedAt: Date(timeIntervalSince1970: metadata.modifiedAt)
            )
        }
    }

    func requiresLocalLogRebuild() throws -> Bool {
        try locked {
            var statement: OpaquePointer?
            try prepare(
                """
                SELECT 1
                FROM origin_files
                WHERE origin_kind = ? AND parser_version != ?
                LIMIT 1
                """,
                into: &statement
            )
            defer { sqlite3_finalize(statement) }
            bind(OriginKind.localLog.rawValue, to: statement, at: 1)
            sqlite3_bind_int(statement, 2, Int32(Self.parserVersion))
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func events(modifiedAfter: Date? = nil, syncLedgerPaths: Set<String>? = nil) throws -> [TokenEvent] {
        try locked {
            let query = eventsQuery(modifiedAfter: modifiedAfter, syncLedgerPaths: syncLedgerPaths)

            var statement: OpaquePointer?
            try prepare(query.sql, into: &statement)
            defer { sqlite3_finalize(statement) }

            for (index, value) in query.bindings.enumerated() {
                let bindingIndex = Int32(index + 1)
                switch value {
                case .double(let double):
                    sqlite3_bind_double(statement, bindingIndex, double)
                case .string(let string):
                    bind(string, to: statement, at: bindingIndex)
                }
            }

            var eventsByKey: [String: (event: TokenEvent, priority: Int)] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let bytes = sqlite3_column_blob(statement, 0)
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard let bytes, count > 0 else { continue }

                let deviceId = columnString(statement, 1)
                let eventId = columnString(statement, 2)
                let priority = Int(sqlite3_column_int(statement, 3))
                let data = Data(bytes: bytes, count: count)
                guard let event = try? Self.decoder.decode(TokenEvent.self, from: data) else {
                    continue
                }

                let key = "\(deviceId)|\(eventId)"
                if let existing = eventsByKey[key], existing.priority > priority {
                    continue
                }
                eventsByKey[key] = (event, priority)
            }

            return eventsByKey.values.map(\.event).sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.id < $1.id
                }
                return $0.timestamp < $1.timestamp
            }
        }
    }

    func eventRecordCount(
        originKind: OriginKind,
        paths: Set<String>,
        modifiedAfter: Date? = nil
    ) throws -> Int {
        try locked {
            guard !paths.isEmpty else { return 0 }
            let sortedPaths = paths.sorted()
            let placeholders = Array(repeating: "?", count: sortedPaths.count).joined(separator: ", ")
            let timestampClause = modifiedAfter == nil ? "" : " AND timestamp >= ?"
            var statement: OpaquePointer?
            try prepare(
                """
                SELECT COUNT(DISTINCT device_id || char(31) || event_id)
                FROM event_records
                WHERE origin_kind = ? AND origin_path IN (\(placeholders))\(timestampClause)
                """,
                into: &statement
            )
            defer { sqlite3_finalize(statement) }
            bind(originKind.rawValue, to: statement, at: 1)
            for (index, path) in sortedPaths.enumerated() {
                bind(path, to: statement, at: Int32(index + 2))
            }
            if let modifiedAfter {
                sqlite3_bind_double(statement, Int32(sortedPaths.count + 2), modifiedAfter.timeIntervalSince1970)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return Int(clamping: sqlite3_column_int64(statement, 0))
        }
    }

    private func eventsQuery(modifiedAfter: Date?, syncLedgerPaths: Set<String>?) -> SQLQuery {
        var clauses: [String] = ["origin_kind = ?", "origin_kind = ?"]
        var bindings: [SQLBinding] = [
            .string(OriginKind.localLog.rawValue),
            .string(OriginKind.hermesDatabase.rawValue)
        ]

        if let syncLedgerPaths, !syncLedgerPaths.isEmpty {
            let paths = syncLedgerPaths.sorted()
            let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
            clauses.append("(origin_kind = ? AND origin_path IN (\(placeholders)))")
            bindings.append(.string(OriginKind.syncLedger.rawValue))
            bindings.append(contentsOf: paths.map(SQLBinding.string))
        }

        var whereClause = "WHERE (\(clauses.joined(separator: " OR ")))"
        if let modifiedAfter {
            whereClause += " AND timestamp >= ?"
            bindings.append(.double(modifiedAfter.timeIntervalSince1970))
        }

        return SQLQuery(
            sql: """
            SELECT event_json, device_id, event_id, priority
            FROM event_records
            \(whereClause)
            ORDER BY timestamp ASC, event_id ASC, priority ASC
            """,
            bindings: bindings
        )
    }

    func replaceEvents(
        _ events: [TokenEvent],
        for snapshot: FileSnapshot,
        originKind: OriginKind,
        parseError: Bool = false
    ) throws {
        try locked {
            try transaction {
                try deleteOrigin(originKind: originKind, path: snapshot.path)
                try deleteOriginFile(originKind: originKind, path: snapshot.path)
                try saveOriginFile(
                    snapshot: snapshot,
                    originKind: originKind,
                    parseError: parseError,
                    eventCount: events.count,
                    replaceExisting: false
                )
                if !parseError {
                    try insertEvents(events, originKind: originKind, originPath: snapshot.path)
                }
            }
        }
    }

    func appendEvents(
        _ events: [TokenEvent],
        for snapshot: FileSnapshot,
        originKind: OriginKind
    ) throws {
        try locked {
            try transaction {
                let existingCount = try eventCount(originKind: originKind, path: snapshot.path)
                try saveOriginFile(
                    snapshot: snapshot,
                    originKind: originKind,
                    parseError: false,
                    eventCount: existingCount + events.count,
                    replaceExisting: true
                )
                try insertEvents(events, originKind: originKind, originPath: snapshot.path)
            }
        }
    }

    func removeMissingOrigins(
        originKind: OriginKind,
        keeping existingPaths: Set<String>,
        pruningSources: Set<TokenSource>? = nil
    ) throws {
        try locked {
            let paths = try originPaths(originKind: originKind, pruningSources: pruningSources)
            let missingPaths = paths.filter { !existingPaths.contains($0) }
            guard !missingPaths.isEmpty else { return }

            try transaction {
                for path in missingPaths {
                    try deleteOrigin(originKind: originKind, path: path)
                    try deleteOriginFile(originKind: originKind, path: path)
                }
            }
        }
    }

    func clear() throws {
        try locked {
            try transaction {
                try execute("DELETE FROM event_records")
                try execute("DELETE FROM origin_files")
                try execute("DELETE FROM hermes_checkpoints")
            }
        }
    }

    private func migrate() throws {
        try locked {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS origin_files (
                    origin_kind TEXT NOT NULL,
                    origin_path TEXT NOT NULL,
                    source TEXT,
                    file_size INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    parser_version INTEGER NOT NULL,
                    device_id TEXT,
                    parse_error INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    first_event_at REAL,
                    last_event_at REAL,
                    scanned_at REAL NOT NULL,
                    PRIMARY KEY (origin_kind, origin_path)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS event_records (
                    origin_kind TEXT NOT NULL,
                    origin_path TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    event_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    source TEXT NOT NULL,
                    priority INTEGER NOT NULL,
                    event_json BLOB NOT NULL,
                    PRIMARY KEY (origin_kind, origin_path, device_id, event_id)
                )
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_records_origin
                ON event_records(origin_kind, origin_path)
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_records_origin_time
                ON event_records(origin_kind, origin_path, timestamp, event_id)
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_records_timestamp
                ON event_records(timestamp)
                """
            )
            try execute(
                """
                CREATE INDEX IF NOT EXISTS idx_event_records_identity
                ON event_records(device_id, event_id, priority)
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS hermes_checkpoints (
                    origin_path TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_tokens INTEGER NOT NULL,
                    event_sequence INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (origin_path, device_id, session_id)
                )
                """
            )
        }
    }

    func hermesCheckpoints(originPath: String, deviceId: String) throws -> [String: HermesCheckpoint] {
        try locked {
            var statement: OpaquePointer?
            try prepare(
                """
                SELECT session_id, input_tokens, cache_write_tokens, cache_read_tokens,
                       output_tokens, reasoning_tokens, event_sequence
                FROM hermes_checkpoints
                WHERE origin_path = ? AND device_id = ?
                """,
                into: &statement
            )
            defer { sqlite3_finalize(statement) }
            bind(originPath, to: statement, at: 1)
            bind(deviceId, to: statement, at: 2)

            var result: [String: HermesCheckpoint] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let sessionId = columnString(statement, 0)
                result[sessionId] = HermesCheckpoint(
                    usage: TokenUsage(
                        input: Int(clamping: sqlite3_column_int64(statement, 1)),
                        cacheCreation: Int(clamping: sqlite3_column_int64(statement, 2)),
                        cacheRead: Int(clamping: sqlite3_column_int64(statement, 3)),
                        output: Int(clamping: sqlite3_column_int64(statement, 4)),
                        reasoning: Int(clamping: sqlite3_column_int64(statement, 5))
                    ),
                    sequence: Int(clamping: sqlite3_column_int64(statement, 6))
                )
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw CacheError(message: lastErrorMessage)
            }
            return result
        }
    }

    func applyHermesUpdates(
        _ updates: [HermesCheckpointUpdate],
        originPath: String,
        deviceId: String
    ) throws {
        guard !updates.isEmpty else { return }
        try locked {
            try transaction {
                var statement: OpaquePointer?
                try prepare(
                    """
                    INSERT INTO hermes_checkpoints (
                        origin_path, device_id, session_id, input_tokens,
                        cache_write_tokens, cache_read_tokens, output_tokens,
                        reasoning_tokens, event_sequence, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(origin_path, device_id, session_id) DO UPDATE SET
                        input_tokens = excluded.input_tokens,
                        cache_write_tokens = excluded.cache_write_tokens,
                        cache_read_tokens = excluded.cache_read_tokens,
                        output_tokens = excluded.output_tokens,
                        reasoning_tokens = excluded.reasoning_tokens,
                        event_sequence = excluded.event_sequence,
                        updated_at = excluded.updated_at
                    """,
                    into: &statement
                )
                defer { sqlite3_finalize(statement) }

                for update in updates {
                    if let event = update.event {
                        try insertEvents([event], originKind: .hermesDatabase, originPath: originPath)
                    }
                    bind(originPath, to: statement, at: 1)
                    bind(deviceId, to: statement, at: 2)
                    bind(update.sessionId, to: statement, at: 3)
                    sqlite3_bind_int64(statement, 4, Int64(clamping: update.usage.input))
                    sqlite3_bind_int64(statement, 5, Int64(clamping: update.usage.cacheCreation))
                    sqlite3_bind_int64(statement, 6, Int64(clamping: update.usage.cacheRead))
                    sqlite3_bind_int64(statement, 7, Int64(clamping: update.usage.output))
                    sqlite3_bind_int64(statement, 8, Int64(clamping: update.usage.reasoning))
                    sqlite3_bind_int64(statement, 9, Int64(clamping: update.sequence))
                    sqlite3_bind_double(statement, 10, Date().timeIntervalSince1970)
                    try stepDone(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }
    }

    private struct FileMetadata {
        var size: Int64
        var modifiedAt: TimeInterval
        var parserVersion: Int
        var deviceId: String?
        var source: TokenSource?
        var parseError: Bool
    }

    private func metadata(for snapshot: FileSnapshot, originKind: OriginKind) throws -> FileMetadata? {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT file_size, modified_at, parser_version, device_id, source, parse_error
            FROM origin_files
            WHERE origin_kind = ? AND origin_path = ?
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)
        bind(snapshot.path, to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return FileMetadata(
            size: sqlite3_column_int64(statement, 0),
            modifiedAt: sqlite3_column_double(statement, 1),
            parserVersion: Int(sqlite3_column_int(statement, 2)),
            deviceId: nullableColumnString(statement, 3),
            source: nullableColumnString(statement, 4).flatMap(TokenSource.init(rawValue:)),
            parseError: sqlite3_column_int(statement, 5) != 0
        )
    }

    private func metadataMatches(_ metadata: FileMetadata, snapshot: FileSnapshot) -> Bool {
        metadata.size == snapshot.size
            && abs(metadata.modifiedAt - snapshot.modifiedAt.timeIntervalSince1970) < Self.timestampTolerance
            && metadata.parserVersion == Self.parserVersion
            && metadata.deviceId == snapshot.deviceId
            && metadata.source == snapshot.source
    }

    private func eventsForOrigin(
        originKind: OriginKind,
        path: String,
        modifiedAfter: Date? = nil
    ) throws -> [TokenEvent] {
        let sql: String
        if modifiedAfter == nil {
            sql = """
            SELECT event_json
            FROM event_records
            WHERE origin_kind = ? AND origin_path = ?
            ORDER BY timestamp ASC, event_id ASC
            """
        } else {
            sql = """
            SELECT event_json
            FROM event_records
            WHERE origin_kind = ? AND origin_path = ? AND timestamp >= ?
            ORDER BY timestamp ASC, event_id ASC
            """
        }

        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)
        bind(path, to: statement, at: 2)
        if let modifiedAfter {
            sqlite3_bind_double(statement, 3, modifiedAfter.timeIntervalSince1970)
        }

        var events: [TokenEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bytes = sqlite3_column_blob(statement, 0)
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes, count > 0 else { continue }
            let data = Data(bytes: bytes, count: count)
            if let event = try? Self.decoder.decode(TokenEvent.self, from: data) {
                events.append(event)
            }
        }
        return events
    }

    private func eventKeys(
        originKind: OriginKind,
        originPath: String?,
        source: TokenSource?
    ) throws -> Set<String> {
        var clauses = ["origin_kind = ?"]
        var bindings = [originKind.rawValue]
        if let originPath {
            clauses.append("origin_path = ?")
            bindings.append(originPath)
        }
        if let source {
            clauses.append("source = ?")
            bindings.append(source.rawValue)
        }

        var statement: OpaquePointer?
        try prepare(
            """
            SELECT device_id, event_id
            FROM event_records
            WHERE \(clauses.joined(separator: " AND "))
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            bind(binding, to: statement, at: Int32(index + 1))
        }

        var keys = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let deviceId = columnString(statement, 0)
            let eventId = columnString(statement, 1)
            keys.insert("\(deviceId)|\(eventId)")
        }
        return keys
    }

    private func originPaths(originKind: OriginKind, pruningSources: Set<TokenSource>?) throws -> [String] {
        var statement: OpaquePointer?
        try prepare(
            "SELECT origin_path, source FROM origin_files WHERE origin_kind = ?",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)

        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pruningSources {
                guard let source = nullableColumnString(statement, 1).flatMap(TokenSource.init(rawValue:)),
                      pruningSources.contains(source) else {
                    continue
                }
            }
            paths.append(columnString(statement, 0))
        }
        return paths
    }

    private func saveOriginFile(
        snapshot: FileSnapshot,
        originKind: OriginKind,
        parseError: Bool,
        eventCount: Int,
        replaceExisting: Bool
    ) throws {
        let insertClause = replaceExisting ? "INSERT OR REPLACE INTO" : "INSERT INTO"
        var statement: OpaquePointer?
        try prepare(
            """
            \(insertClause) origin_files (
                origin_kind, origin_path, source, file_size, modified_at,
                parser_version, device_id, parse_error, event_count,
                first_event_at, last_event_at, scanned_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)
        bind(snapshot.path, to: statement, at: 2)
        bind(snapshot.source?.rawValue, to: statement, at: 3)
        sqlite3_bind_int64(statement, 4, snapshot.size)
        sqlite3_bind_double(statement, 5, snapshot.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 6, Int32(Self.parserVersion))
        bind(snapshot.deviceId, to: statement, at: 7)
        sqlite3_bind_int(statement, 8, parseError ? 1 : 0)
        sqlite3_bind_int64(statement, 9, Int64(eventCount))
        sqlite3_bind_double(statement, 10, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func insertEvents(_ events: [TokenEvent], originKind: OriginKind, originPath: String) throws {
        guard !events.isEmpty else { return }
        var statement: OpaquePointer?
        try prepare(
            """
            INSERT OR REPLACE INTO event_records (
                origin_kind, origin_path, device_id, event_id,
                timestamp, source, priority, event_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }

        for event in events {
            let data = try Self.encoder.encode(event)
            bind(originKind.rawValue, to: statement, at: 1)
            bind(originPath, to: statement, at: 2)
            bind(event.deviceId, to: statement, at: 3)
            bind(event.id, to: statement, at: 4)
            sqlite3_bind_double(statement, 5, event.timestamp.timeIntervalSince1970)
            bind(event.source.rawValue, to: statement, at: 6)
            sqlite3_bind_int(statement, 7, Int32(originKind == .syncLedger ? 1 : 2))
            _ = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 8, buffer.baseAddress, Int32(data.count), transient)
            }
            try stepDone(statement)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    private func deleteOrigin(originKind: OriginKind, path: String) throws {
        var statement: OpaquePointer?
        try prepare(
            "DELETE FROM event_records WHERE origin_kind = ? AND origin_path = ?",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)
        bind(path, to: statement, at: 2)
        try stepDone(statement)
    }

    private func deleteOriginFile(originKind: OriginKind, path: String) throws {
        var statement: OpaquePointer?
        try prepare(
            "DELETE FROM origin_files WHERE origin_kind = ? AND origin_path = ?",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)
        bind(path, to: statement, at: 2)
        try stepDone(statement)
    }

    private func eventCount(originKind: OriginKind, path: String) throws -> Int {
        var statement: OpaquePointer?
        try prepare(
            "SELECT COUNT(*) FROM event_records WHERE origin_kind = ? AND origin_path = ?",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)
        bind(path, to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(clamping: sqlite3_column_int64(statement, 0))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw CacheError(message: message)
        }
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CacheError(message: lastErrorMessage)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CacheError(message: lastErrorMessage)
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func nullableColumnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnString(statement, index)
    }

    private var lastErrorMessage: String {
        guard let database else { return "SQLite database is closed" }
        return String(cString: sqlite3_errmsg(database))
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private struct CacheError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

private struct SQLQuery {
    var sql: String
    var bindings: [SQLBinding]
}

private enum SQLBinding {
    case double(Double)
    case string(String)
}
