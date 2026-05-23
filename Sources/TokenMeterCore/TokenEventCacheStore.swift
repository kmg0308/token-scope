import Foundation
import SQLite3

public final class TokenEventCacheStore: @unchecked Sendable {
    static let parserVersion = 1

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
            return FileSnapshot(
                path: path,
                source: source,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: modifiedAt,
                deviceId: deviceId
            )
        }
    }

    enum OriginKind: String {
        case localLog = "local_log"
        case syncLedger = "sync_ledger"
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

    func incrementalAppendBase(for snapshot: FileSnapshot, originKind: OriginKind) throws -> IncrementalAppendBase? {
        try locked {
            guard let metadata = try metadata(for: snapshot, originKind: originKind),
                  metadata.parserVersion == Self.parserVersion,
                  metadata.deviceId == snapshot.deviceId,
                  metadata.source == snapshot.source,
                  !metadata.parseError,
                  metadata.size > 0,
                  snapshot.size > metadata.size else {
                return nil
            }
            return IncrementalAppendBase(
                size: metadata.size,
                modifiedAt: Date(timeIntervalSince1970: metadata.modifiedAt)
            )
        }
    }

    func events(modifiedAfter: Date? = nil) throws -> [TokenEvent] {
        try locked {
            let sql: String
            if modifiedAfter == nil {
                sql = """
                SELECT event_json, device_id, event_id, priority
                FROM event_records
                ORDER BY timestamp ASC, event_id ASC, priority ASC
                """
            } else {
                sql = """
                SELECT event_json, device_id, event_id, priority
                FROM event_records
                WHERE timestamp >= ?
                ORDER BY timestamp ASC, event_id ASC, priority ASC
                """
            }

            var statement: OpaquePointer?
            try prepare(sql, into: &statement)
            defer { sqlite3_finalize(statement) }
            if let modifiedAfter {
                sqlite3_bind_double(statement, 1, modifiedAfter.timeIntervalSince1970)
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
                try insertOriginFile(snapshot: snapshot, originKind: originKind, parseError: parseError, eventCount: events.count)
                if !parseError {
                    for event in events {
                        try insertEvent(event, originKind: originKind, originPath: snapshot.path)
                    }
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
                try upsertOriginFile(
                    snapshot: snapshot,
                    originKind: originKind,
                    parseError: false,
                    eventCount: existingCount + events.count
                )
                for event in events {
                    try insertEvent(event, originKind: originKind, originPath: snapshot.path)
                }
            }
        }
    }

    func removeMissingOrigins(originKind: OriginKind, keeping existingPaths: Set<String>) throws {
        try locked {
            let paths = try originPaths(originKind: originKind)
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
            && abs(metadata.modifiedAt - snapshot.modifiedAt.timeIntervalSince1970) < 0.000_001
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

    private func originPaths(originKind: OriginKind) throws -> [String] {
        var statement: OpaquePointer?
        try prepare(
            "SELECT origin_path FROM origin_files WHERE origin_kind = ?",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(originKind.rawValue, to: statement, at: 1)

        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            paths.append(columnString(statement, 0))
        }
        return paths
    }

    private func insertOriginFile(
        snapshot: FileSnapshot,
        originKind: OriginKind,
        parseError: Bool,
        eventCount: Int
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            """
            INSERT INTO origin_files (
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
        sqlite3_bind_int(statement, 9, Int32(eventCount))
        sqlite3_bind_double(statement, 10, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func upsertOriginFile(
        snapshot: FileSnapshot,
        originKind: OriginKind,
        parseError: Bool,
        eventCount: Int
    ) throws {
        var statement: OpaquePointer?
        try prepare(
            """
            INSERT OR REPLACE INTO origin_files (
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
        sqlite3_bind_int(statement, 9, Int32(eventCount))
        sqlite3_bind_double(statement, 10, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func insertEvent(_ event: TokenEvent, originKind: OriginKind, originPath: String) throws {
        let data = try Self.encoder.encode(event)
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
        bind(originKind.rawValue, to: statement, at: 1)
        bind(originPath, to: statement, at: 2)
        bind(event.deviceId, to: statement, at: 3)
        bind(event.id, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, event.timestamp.timeIntervalSince1970)
        bind(event.source.rawValue, to: statement, at: 6)
        sqlite3_bind_int(statement, 7, Int32(originKind == .localLog ? 2 : 1))
        _ = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 8, buffer.baseAddress, Int32(data.count), transient)
        }
        try stepDone(statement)
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
        return Int(sqlite3_column_int(statement, 0))
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
