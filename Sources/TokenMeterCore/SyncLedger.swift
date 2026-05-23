import CryptoKit
import Foundation

public final class TokenSyncLedgerStore: @unchecked Sendable {
    private let folder: URL
    private let localDevice: TokenDeviceMetadata
    private let fileManager: FileManager
    private let cacheStore: TokenEventCacheStore?

    public init(
        folder: URL,
        localDevice: TokenDeviceMetadata,
        fileManager: FileManager = .default,
        cacheStore: TokenEventCacheStore? = nil
    ) {
        self.folder = folder
        self.localDevice = localDevice
        self.fileManager = fileManager
        self.cacheStore = cacheStore
    }

    public func synchronize(
        localEvents: [TokenEvent],
        replaceLocalLedger: Bool = false,
        importedAfter: Date? = nil,
        isCancelled: () -> Bool = { false }
    ) -> (events: [TokenEvent], status: SyncFolderStatus) {
        guard fileManager.fileExists(atPath: folder.path) else {
            return (
                [],
                SyncFolderStatus(path: folder.path, exists: false)
            )
        }

        var exportedEventCount = 0
        var exportError: String?

        do {
            exportedEventCount = try writeLocalLedger(
                events: localEvents,
                replaceExisting: replaceLocalLedger,
                isCancelled: isCancelled
            )
        } catch {
            exportError = error.localizedDescription
        }

        let readResult = readDeviceLedgers(importedAfter: importedAfter, isCancelled: isCancelled)
        let status = SyncFolderStatus(
            path: folder.path,
            exists: true,
            deviceFileCount: readResult.deviceFileCount,
            importedEventCount: readResult.events.count,
            exportedEventCount: exportedEventCount,
            parseErrorCount: readResult.parseErrorCount,
            exportError: exportError,
            lastSyncedAt: Date()
        )
        return (readResult.events, status)
    }

    private func writeLocalLedger(
        events: [TokenEvent],
        replaceExisting: Bool,
        isCancelled: () -> Bool
    ) throws -> Int {
        guard !isCancelled() else { return 0 }

        let devicesURL = folder.appendingPathComponent("devices", isDirectory: true)
        try fileManager.createDirectory(at: devicesURL, withIntermediateDirectories: true)
        let localLedgerURL = devicesURL.appendingPathComponent("\(safeFileName(localDevice.id)).jsonl")

        var recordsByKey: [String: SyncLedgerRecord] = [:]
        for event in events where !isCancelled() {
            let record = SyncLedgerRecord(event: event.withDevice(localDevice))
            recordsByKey[record.identityKey] = record
        }

        let records: [SyncLedgerRecord]
        if replaceExisting {
            records = sortedRecords(Array(recordsByKey.values))
            try write(records: records, to: localLedgerURL)
            cacheLedger(records: records, at: localLedgerURL)
            return records.count
        }

        guard !recordsByKey.isEmpty else { return 0 }

        let cachedKeys = cachedLedgerKeys(for: syncLedgerSnapshot(for: localLedgerURL))
        let existingKeys = cachedKeys
            ?? readIdentityKeys(from: localLedgerURL, isCancelled: isCancelled)
        records = sortedRecords(recordsByKey.values.filter { !existingKeys.contains($0.identityKey) })
        guard !records.isEmpty else { return 0 }

        try append(records: records, to: localLedgerURL)
        if cachedKeys != nil {
            appendLedgerCache(events: records.map(\.tokenEvent), at: localLedgerURL)
        }
        return records.count
    }

    private func sortedRecords(_ records: [SyncLedgerRecord]) -> [SyncLedgerRecord] {
        records.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.eventId < $1.eventId
            }
            return $0.timestamp < $1.timestamp
        }
    }

    private func write(records: [SyncLedgerRecord], to url: URL) throws {
        let encoder = Self.jsonEncoder
        let lines = try records.map { record in
            let data = try encoder.encode(record)
            return String(decoding: data, as: UTF8.self)
        }
        let data = (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).data(using: .utf8) ?? Data()
        try data.write(to: url, options: [.atomic])
    }

    private func append(records: [SyncLedgerRecord], to url: URL) throws {
        let encoder = Self.jsonEncoder
        let lines = try records.map { record in
            let data = try encoder.encode(record)
            return String(decoding: data, as: UTF8.self)
        }
        guard !lines.isEmpty else { return }

        if !fileManager.fileExists(atPath: url.path) {
            let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
            try data.write(to: url, options: [.atomic])
            return
        }

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
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        try handle.write(contentsOf: data)
    }

    private func readDeviceLedgers(
        importedAfter: Date?,
        isCancelled: () -> Bool
    ) -> (events: [TokenEvent], deviceFileCount: Int, parseErrorCount: Int) {
        let devicesURL = folder.appendingPathComponent("devices", isDirectory: true)
        guard fileManager.fileExists(atPath: devicesURL.path) else {
            try? cacheStore?.removeMissingOrigins(originKind: .syncLedger, keeping: [])
            return ([], 0, 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: devicesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], 0, 1)
        }

        var events: [TokenEvent] = []
        var fileCount = 0
        var parseErrors = 0
        var ledgerPaths = Set<String>()

        for case let url as URL in enumerator where !isCancelled() && url.pathExtension == "jsonl" {
            fileCount += 1
            ledgerPaths.insert(syncLedgerSnapshot(for: url)?.path ?? url.resolvingSymlinksInPath().path)
            let result = cachedOrReadLedgerEvents(from: url, importedAfter: importedAfter, isCancelled: isCancelled)
            parseErrors += result.parseErrorCount
            events.append(contentsOf: result.events)
        }

        try? cacheStore?.removeMissingOrigins(originKind: .syncLedger, keeping: ledgerPaths)
        return (events, fileCount, parseErrors)
    }

    private func cachedOrReadLedgerEvents(
        from url: URL,
        importedAfter: Date?,
        isCancelled: () -> Bool
    ) -> (events: [TokenEvent], parseErrorCount: Int) {
        let snapshot = syncLedgerSnapshot(for: url)
        if let cachedEvents = cachedLedgerEvents(for: snapshot, importedAfter: importedAfter) {
            return (cachedEvents, 0)
        }

        let result = readRecords(from: url, importedAfter: importedAfter, isCancelled: isCancelled)
        let events = result.records.map(\.tokenEvent)
        if importedAfter == nil, result.parseErrorCount == 0 {
            cacheLedger(events: events, at: url)
        }
        return (events, result.parseErrorCount)
    }

    private func cachedLedgerEvents(
        for snapshot: TokenEventCacheStore.FileSnapshot?,
        importedAfter: Date? = nil
    ) -> [TokenEvent]? {
        guard let snapshot,
              let cached = try? cacheStore?.cachedEvents(
                for: snapshot,
                originKind: .syncLedger,
                modifiedAfter: importedAfter
              ) else {
            return nil
        }
        if case .events(let events) = cached {
            return events
        }
        return nil
    }

    private func cachedLedgerKeys(for snapshot: TokenEventCacheStore.FileSnapshot?) -> Set<String>? {
        guard let snapshot else { return nil }
        return try? cacheStore?.cachedEventKeys(for: snapshot, originKind: .syncLedger)
    }

    private func cacheLedger(records: [SyncLedgerRecord], at url: URL) {
        cacheLedger(events: records.map(\.tokenEvent), at: url)
    }

    private func cacheLedger(events: [TokenEvent], at url: URL) {
        guard let snapshot = syncLedgerSnapshot(for: url) else { return }
        try? cacheStore?.replaceEvents(events, for: snapshot, originKind: .syncLedger)
    }

    private func appendLedgerCache(events: [TokenEvent], at url: URL) {
        guard let snapshot = syncLedgerSnapshot(for: url) else { return }
        try? cacheStore?.appendEvents(events, for: snapshot, originKind: .syncLedger)
    }

    private func syncLedgerSnapshot(for url: URL) -> TokenEventCacheStore.FileSnapshot? {
        TokenEventCacheStore.FileSnapshot.make(
            for: url,
            source: nil,
            deviceId: nil,
            fileManager: fileManager
        )
    }

    private func readIdentityKeys(from url: URL, isCancelled: () -> Bool) -> Set<String> {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let decoder = Self.jsonDecoder
        var keys: Set<String> = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) where !isCancelled() {
            guard let data = String(line).data(using: .utf8),
                  let identity = try? decoder.decode(SyncLedgerIdentity.self, from: data) else {
                continue
            }
            keys.insert(identity.identityKey)
        }
        return keys
    }

    private func readRecords(
        from url: URL,
        importedAfter: Date? = nil,
        isCancelled: () -> Bool
    ) -> (records: [SyncLedgerRecord], parseErrorCount: Int) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], 1)
        }

        let decoder = Self.jsonDecoder
        var records: [SyncLedgerRecord] = []
        var parseErrors = 0

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) where !isCancelled() {
            guard let data = String(line).data(using: .utf8) else {
                parseErrors += 1
                continue
            }

            if let importedAfter {
                do {
                    let timestamp = try decoder.decode(SyncLedgerTimestamp.self, from: data).timestamp
                    guard timestamp >= importedAfter else { continue }
                } catch {
                    parseErrors += 1
                    continue
                }
            }

            do {
                let record = try decoder.decode(SyncLedgerRecord.self, from: data)
                records.append(record)
            } catch {
                parseErrors += 1
            }
        }

        return (records, parseErrors)
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "device" : name
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TokenSyncLedgerStore.string(from: date))
        }
        return encoder
    }

    private static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = TokenSyncLedgerStore.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
        }
        return decoder
    }

    private static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct SyncLedgerIdentity: Decodable {
    var deviceId: String
    var eventId: String

    var identityKey: String {
        "\(deviceId)|\(eventId)"
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case eventId = "event_id"
    }
}

private struct SyncLedgerTimestamp: Decodable {
    var timestamp: Date
}

private struct SyncLedgerRecord: Codable, Hashable {
    var schemaVersion: Int
    var deviceId: String
    var deviceName: String
    var eventId: String
    var timestamp: Date
    var source: TokenSource
    var model: String
    var projectHash: String
    var sessionHash: String
    var usage: TokenUsage

    init(
        schemaVersion: Int = 1,
        deviceId: String,
        deviceName: String,
        eventId: String,
        timestamp: Date,
        source: TokenSource,
        model: String,
        projectHash: String,
        sessionHash: String,
        usage: TokenUsage
    ) {
        self.schemaVersion = schemaVersion
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.eventId = eventId
        self.timestamp = timestamp
        self.source = source
        self.model = model.isEmpty ? "Unknown" : model
        self.projectHash = projectHash
        self.sessionHash = sessionHash
        self.usage = usage
    }

    init(event: TokenEvent) {
        self.init(
            deviceId: event.deviceId,
            deviceName: event.deviceName,
            eventId: event.id,
            timestamp: event.timestamp,
            source: event.source,
            model: event.model,
            projectHash: Self.hash(event.projectPath),
            sessionHash: Self.hash(event.sessionId),
            usage: event.usage
        )
    }

    var identityKey: String {
        "\(deviceId)|\(eventId)"
    }

    var tokenEvent: TokenEvent {
        TokenEvent(
            id: eventId,
            source: source,
            timestamp: timestamp,
            deviceId: deviceId,
            deviceName: deviceName,
            projectPath: displayKey(prefix: "Project", hash: projectHash),
            sessionId: displayKey(prefix: "Session", hash: sessionHash),
            model: model,
            usage: usage,
            rawFilePath: "sync://\(deviceId)/\(eventId)"
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case deviceId = "device_id"
        case deviceName = "device_name"
        case eventId = "event_id"
        case timestamp
        case source
        case model
        case projectHash = "project_hash"
        case sessionHash = "session_hash"
        case usage
    }

    private static func hash(_ value: String) -> String {
        if value.isEmpty || value == "Unknown" {
            return "unknown"
        }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func displayKey(prefix: String, hash: String) -> String {
        if hash == "unknown" {
            return "Unknown"
        }
        return "\(prefix) \(String(hash.prefix(8)))"
    }
}
