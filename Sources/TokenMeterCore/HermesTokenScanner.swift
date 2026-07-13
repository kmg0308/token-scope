import CryptoKit
import Foundation
import SQLite3

struct HermesScanOutcome {
    var events: [TokenEvent] = []
    var databaseExists = false
    var parseErrorCount = 0
}

final class HermesTokenScanner {
    private let databaseURL: URL
    private let fileManager: FileManager
    private let localDevice: TokenDeviceMetadata
    private let cacheStore: TokenEventCacheStore?
    private var database: OpaquePointer?

    init(
        homeDirectory: URL,
        fileManager: FileManager,
        localDevice: TokenDeviceMetadata,
        cacheStore: TokenEventCacheStore?
    ) {
        self.databaseURL = homeDirectory.appendingPathComponent(".hermes/state.db")
        self.fileManager = fileManager
        self.localDevice = localDevice
        self.cacheStore = cacheStore
    }

    deinit {
        sqlite3_close(database)
    }

    func scan(isCancelled: () -> Bool) -> HermesScanOutcome {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return HermesScanOutcome()
        }
        guard !isCancelled() else { return HermesScanOutcome(databaseExists: true) }

        do {
            try openReadOnlyDatabase()
            let sessions = try readSessions()
            guard !isCancelled() else { return HermesScanOutcome(databaseExists: true) }
            let events = try importSessions(sessions, observedAt: Date())
            return HermesScanOutcome(
                events: events,
                databaseExists: true
            )
        } catch {
            return HermesScanOutcome(databaseExists: true, parseErrorCount: 1)
        }
    }

    private func openReadOnlyDatabase() throws {
        guard database == nil else { return }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            throw HermesScanError.sqlite(lastErrorMessage)
        }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw HermesScanError.sqlite(lastErrorMessage)
        }
    }

    private func readSessions() throws -> [HermesSession] {
        let sessionColumns = try columns(in: "sessions")
        guard sessionColumns.contains("id"),
              sessionColumns.contains("billing_provider"),
              sessionColumns.contains("started_at") else {
            throw HermesScanError.incompatibleSchema
        }

        let tokenColumns = [
            "input_tokens", "output_tokens", "cache_read_tokens",
            "cache_write_tokens", "reasoning_tokens"
        ]
        guard tokenColumns.contains(where: sessionColumns.contains) else {
            throw HermesScanError.incompatibleSchema
        }

        let messageColumns = (try? columns(in: "messages")) ?? []
        let canReadMessageTime = messageColumns.contains("session_id") && messageColumns.contains("timestamp")
        func expression(_ column: String, fallback: String) -> String {
            sessionColumns.contains(column) ? "s.\(column)" : fallback
        }
        let messageTime = canReadMessageTime
            ? "(SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id)"
            : "NULL"
        let positiveCounters = tokenColumns
            .filter(sessionColumns.contains)
            .map { "COALESCE(s.\($0), 0) > 0" }
            .joined(separator: " OR ")

        let sql = """
        SELECT s.id,
               \(expression("model", fallback: "NULL")),
               s.started_at,
               \(expression("ended_at", fallback: "NULL")),
               \(expression("input_tokens", fallback: "0")),
               \(expression("output_tokens", fallback: "0")),
               \(expression("cache_read_tokens", fallback: "0")),
               \(expression("cache_write_tokens", fallback: "0")),
               \(expression("reasoning_tokens", fallback: "0")),
               \(expression("cwd", fallback: "NULL")),
               \(messageTime)
        FROM sessions s
        WHERE s.billing_provider = ? AND (\(positiveCounters))
        ORDER BY s.id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HermesScanError.sqlite(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "openai-codex", -1, transient)

        var sessions: [HermesSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let startedAt = nullableDate(statement, column: 2) else { continue }
            let output = nonnegativeInteger(statement, column: 5)
            let reasoning = min(nonnegativeInteger(statement, column: 8), output)
            sessions.append(HermesSession(
                id: columnString(statement, 0),
                model: nullableColumnString(statement, 1) ?? "Unknown",
                startedAt: startedAt,
                endedAt: nullableDate(statement, column: 3),
                // Hermes CanonicalUsage stores uncached input separately from
                // cache buckets, while output already includes reasoning.
                usage: TokenUsage(
                    input: nonnegativeInteger(statement, column: 4),
                    cacheCreation: nonnegativeInteger(statement, column: 7),
                    cacheRead: nonnegativeInteger(statement, column: 6),
                    output: output,
                    reasoning: reasoning
                ),
                projectPath: nullableColumnString(statement, 9) ?? "Unknown",
                lastMessageAt: nullableDate(statement, column: 10)
            ))
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw HermesScanError.sqlite(lastErrorMessage)
        }
        return sessions
    }

    private func importSessions(_ sessions: [HermesSession], observedAt: Date) throws -> [TokenEvent] {
        let originPath = databaseURL.resolvingSymlinksInPath().path
        guard let cacheStore else {
            return sessions.map { session in
                makeEvent(
                    session: session,
                    usage: session.usage,
                    timestamp: session.baselineTimestamp,
                    sequence: usageFingerprint(session.usage)
                )
            }
        }

        let checkpoints = try cacheStore.hermesCheckpoints(
            originPath: originPath,
            deviceId: localDevice.id
        )
        var updates: [TokenEventCacheStore.HermesCheckpointUpdate] = []
        var events: [TokenEvent] = []

        for session in sessions {
            let checkpoint = checkpoints[session.id]
            let nextSequence: Int
            let eventUsage: TokenUsage?
            let timestamp: Date

            if let checkpoint {
                nextSequence = checkpoint.sequence + (session.usage == checkpoint.usage ? 0 : 1)
                if session.usage.hasCounterDecrease(comparedTo: checkpoint.usage) {
                    eventUsage = nil
                } else {
                    let delta = session.usage.subtracting(checkpoint.usage)
                    eventUsage = delta.total > 0 ? delta : nil
                }
                timestamp = session.lastActivityTimestamp(observedAt: observedAt)
            } else {
                nextSequence = 1
                eventUsage = session.usage
                timestamp = session.baselineTimestamp
            }

            let event = eventUsage.map {
                makeEvent(session: session, usage: $0, timestamp: timestamp, sequence: String(nextSequence))
            }
            if let event { events.append(event) }
            updates.append(TokenEventCacheStore.HermesCheckpointUpdate(
                sessionId: session.id,
                usage: session.usage,
                sequence: event == nil ? (checkpoint?.sequence ?? 0) : nextSequence,
                event: event
            ))
        }

        try cacheStore.applyHermesUpdates(updates, originPath: originPath, deviceId: localDevice.id)
        return events
    }

    private func makeEvent(
        session: HermesSession,
        usage: TokenUsage,
        timestamp: Date,
        sequence: String
    ) -> TokenEvent {
        let sessionHash = SHA256.hash(data: Data(session.id.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return TokenEvent(
            id: "hermes-\(sessionHash)-\(sequence)",
            source: .codex,
            timestamp: timestamp,
            deviceId: localDevice.id,
            deviceName: localDevice.name,
            projectPath: session.projectPath,
            sessionId: session.id,
            model: session.model,
            usage: usage,
            rawFilePath: "hermes://state.db/\(sessionHash)"
        )
    }

    private func columns(in table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw HermesScanError.sqlite(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(columnString(statement, 1))
        }
        return columns
    }

    private func nonnegativeInteger(_ statement: OpaquePointer?, column: Int32) -> Int {
        max(0, Int(clamping: sqlite3_column_int64(statement, column)))
    }

    private func nullableDate(_ statement: OpaquePointer?, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return normalizedDate(sqlite3_column_double(statement, column))
    }

    private func normalizedDate(_ rawValue: Double) -> Date? {
        guard rawValue.isFinite, rawValue > 0 else { return nil }
        let seconds: Double
        if rawValue > 100_000_000_000_000_000 {
            seconds = rawValue / 1_000_000_000
        } else if rawValue > 100_000_000_000_000 {
            seconds = rawValue / 1_000_000
        } else if rawValue > 100_000_000_000 {
            seconds = rawValue / 1_000
        } else {
            seconds = rawValue
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private func columnString(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func nullableColumnString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = columnString(statement, column)
        return value.isEmpty ? nil : value
    }

    private func usageFingerprint(_ usage: TokenUsage) -> String {
        "\(usage.input)-\(usage.cacheCreation)-\(usage.cacheRead)-\(usage.output)-\(usage.reasoning)"
    }

    private var lastErrorMessage: String {
        guard let database else { return "Hermes database is closed" }
        return String(cString: sqlite3_errmsg(database))
    }
}

private struct HermesSession {
    var id: String
    var model: String
    var startedAt: Date
    var endedAt: Date?
    var usage: TokenUsage
    var projectPath: String
    var lastMessageAt: Date?

    var baselineTimestamp: Date {
        endedAt ?? lastMessageAt ?? startedAt
    }

    func lastActivityTimestamp(observedAt: Date) -> Date {
        let persistedActivity = [endedAt, lastMessageAt].compactMap { $0 }.max()
        return persistedActivity ?? observedAt
    }
}

private extension TokenUsage {
    func hasCounterDecrease(comparedTo previous: TokenUsage) -> Bool {
        input < previous.input
            || cacheCreation < previous.cacheCreation
            || cacheRead < previous.cacheRead
            || output < previous.output
            || reasoning < previous.reasoning
    }

    func subtracting(_ previous: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: input - previous.input,
            cacheCreation: cacheCreation - previous.cacheCreation,
            cacheRead: cacheRead - previous.cacheRead,
            output: output - previous.output,
            reasoning: reasoning - previous.reasoning
        )
    }
}

private enum HermesScanError: Error {
    case incompatibleSchema
    case sqlite(String)
}
