import CryptoKit
import Foundation

private typealias SyncLedgerLineBytes = Slice<UnsafeBufferPointer<UInt8>>

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

        let records: [SyncLedgerRecord]
        if replaceExisting {
            records = sortedRecords(recordsByKey(for: events, isCancelled: isCancelled).map(\.value))
            guard !isCancelled() else { return 0 }
            try write(records: records, to: localLedgerURL)
            cacheLedger(records: records, at: localLedgerURL)
            return records.count
        }

        guard !events.isEmpty else { return 0 }

        let cachedKeys = cachedLedgerKeys(for: syncLedgerSnapshot(for: localLedgerURL))
        let existingKeys = cachedKeys
            ?? readIdentityKeys(from: localLedgerURL, isCancelled: isCancelled)
        guard !isCancelled() else { return 0 }
        records = sortedRecords(newRecords(from: events, excluding: existingKeys, isCancelled: isCancelled))
        guard !records.isEmpty else { return 0 }
        guard !isCancelled() else { return 0 }

        try append(records: records, to: localLedgerURL)
        if cachedKeys != nil {
            appendLedgerCache(events: records.map(\.tokenEvent), at: localLedgerURL)
        }
        return records.count
    }

    private func recordsByKey(
        for events: [TokenEvent],
        isCancelled: () -> Bool
    ) -> [String: SyncLedgerRecord] {
        var recordsByKey: [String: SyncLedgerRecord] = [:]
        for event in events {
            guard !isCancelled() else { return recordsByKey }
            let record = SyncLedgerRecord(event: event.withDevice(localDevice))
            recordsByKey[record.identityKey] = record
        }
        return recordsByKey
    }

    private func newRecords(
        from events: [TokenEvent],
        excluding existingKeys: Set<String>,
        isCancelled: () -> Bool
    ) -> [SyncLedgerRecord] {
        var pendingEventsByKey: [String: TokenEvent] = [:]
        for event in events {
            guard !isCancelled() else { return [] }
            let key = "\(localDevice.id)|\(event.id)"
            guard !existingKeys.contains(key) else { continue }
            pendingEventsByKey[key] = event
        }
        guard !isCancelled() else { return [] }
        return pendingEventsByKey.values.map { event in
            SyncLedgerRecord(event: event.withDevice(localDevice))
        }
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
            if !isCancelled() {
                try? cacheStore?.removeMissingOrigins(originKind: .syncLedger, keeping: [])
            }
            return ([], 0, 0)
        }

        let ledgerURLs: [URL]
        do {
            ledgerURLs = try fileManager.contentsOfDirectory(
                at: devicesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter(isRegularJSONLFile)
            .sorted { $0.path < $1.path }
        } catch {
            return ([], 0, 1)
        }

        var events: [TokenEvent] = []
        var fileCount = 0
        var parseErrors = 0
        var ledgerPaths = Set<String>()
        var completed = true

        for url in ledgerURLs {
            guard !isCancelled() else {
                completed = false
                break
            }
            fileCount += 1
            ledgerPaths.insert(syncLedgerSnapshot(for: url)?.path ?? url.resolvingSymlinksInPath().path)
            let result = cachedOrReadLedgerEvents(from: url, importedAfter: importedAfter, isCancelled: isCancelled)
            parseErrors += result.parseErrorCount
            events.append(contentsOf: result.events)
        }

        if completed, !isCancelled() {
            try? cacheStore?.removeMissingOrigins(originKind: .syncLedger, keeping: ledgerPaths)
        }
        return (deduplicatedEvents(events), fileCount, parseErrors)
    }

    private func isRegularJSONLFile(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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

        if let incrementalEvents = incrementallyReadLedgerEvents(
            from: url,
            snapshot: snapshot,
            importedAfter: importedAfter,
            isCancelled: isCancelled
        ) {
            return incrementalEvents
        }

        let result = readRecords(from: url, importedAfter: importedAfter, isCancelled: isCancelled)
        let events = deduplicatedEvents(result.records.map(\.tokenEvent))
        if importedAfter == nil, result.completed, result.parseErrorCount == 0 {
            cacheLedger(events: events, at: url)
        }
        return (events, result.parseErrorCount)
    }

    private func incrementallyReadLedgerEvents(
        from url: URL,
        snapshot: TokenEventCacheStore.FileSnapshot?,
        importedAfter: Date?,
        isCancelled: () -> Bool
    ) -> (events: [TokenEvent], parseErrorCount: Int)? {
        guard let snapshot,
              let base = try? cacheStore?.incrementalAppendBase(for: snapshot, originKind: .syncLedger) else {
            return nil
        }

        let baseSnapshot = TokenEventCacheStore.FileSnapshot(
            path: snapshot.path,
            source: snapshot.source,
            size: base.size,
            modifiedAt: base.modifiedAt,
            deviceId: snapshot.deviceId
        )
        guard let cachedEvents = cachedLedgerEvents(for: baseSnapshot, importedAfter: importedAfter) else {
            return nil
        }

        let result = readRecords(
            from: url,
            startOffset: base.size,
            importedAfter: importedAfter,
            isCancelled: isCancelled
        )
        guard !result.requiresFullRead else {
            return nil
        }

        let existingKeys = cachedLedgerKeys(for: baseSnapshot)
            ?? Set(cachedEvents.map(eventIdentityKey))
        let newEvents = uniqueNewEvents(
            from: result.records.map(\.tokenEvent),
            excludingKeys: existingKeys
        )
        let events = cachedEvents + newEvents
        if importedAfter == nil, result.completed, result.parseErrorCount == 0 {
            appendLedgerCache(events: newEvents, at: url)
        }
        return (events, result.parseErrorCount)
    }

    private func uniqueNewEvents(from events: [TokenEvent], excludingKeys existingKeys: Set<String>) -> [TokenEvent] {
        var seenKeys = existingKeys
        var uniqueEvents: [TokenEvent] = []
        for event in events {
            guard seenKeys.insert(eventIdentityKey(event)).inserted else { continue }
            uniqueEvents.append(event)
        }
        return uniqueEvents
    }

    private func deduplicatedEvents(_ events: [TokenEvent]) -> [TokenEvent] {
        var seenKeys = Set<String>()
        var uniqueEvents: [TokenEvent] = []
        for event in events {
            guard seenKeys.insert(eventIdentityKey(event)).inserted else { continue }
            uniqueEvents.append(event)
        }
        return uniqueEvents
    }

    private func eventIdentityKey(_ event: TokenEvent) -> String {
        "\(event.deviceId)|\(event.id)"
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
        var keys: Set<String> = []

        _ = try? forEachLedgerLine(in: url, isCancelled: isCancelled) { data in
            guard let identityKey = identityKey(from: data) else {
                return
            }
            keys.insert(identityKey)
        }
        return keys
    }

    private func readRecords(
        from url: URL,
        startOffset: Int64 = 0,
        importedAfter: Date? = nil,
        isCancelled: () -> Bool
    ) -> (records: [SyncLedgerRecord], parseErrorCount: Int, completed: Bool, requiresFullRead: Bool) {
        let decoder = Self.jsonDecoder
        var records: [SyncLedgerRecord] = []
        var parseErrors = 0
        let importedAfterText = importedAfter.map(Self.string(from:))

        do {
            let completed = try forEachLedgerLine(in: url, startOffset: startOffset, isCancelled: isCancelled) { data in
                let fastImportDecision: Bool?
                if let importedAfter, let importedAfterText {
                    fastImportDecision = timestampPassesFilter(
                        in: data,
                        importedAfter: importedAfter,
                        importedAfterText: importedAfterText
                    )
                    if fastImportDecision == false {
                        return
                    }
                } else {
                    fastImportDecision = nil
                }
                do {
                    let record = try decoder.decode(SyncLedgerRecord.self, from: Data(data))
                    if fastImportDecision == nil,
                       let importedAfter,
                       record.timestamp < importedAfter {
                        return
                    }
                    records.append(record)
                } catch {
                    parseErrors += 1
                }
            }
            return (records, parseErrors, completed, false)
        } catch SyncLedgerLineReadError.requiresFullRead {
            return ([], 0, true, true)
        } catch {
            return ([], 1, true, false)
        }
    }

    private func timestampPassesFilter(
        in data: SyncLedgerLineBytes,
        importedAfter: Date,
        importedAfterText: String
    ) -> Bool? {
        guard let timestamp = jsonStringValue(after: Self.timestampMarker, in: data) else {
            return nil
        }
        if isCanonicalLedgerTimestamp(timestamp) {
            return timestamp >= importedAfterText
        }
        guard let date = Self.date(from: timestamp) else { return nil }
        return date >= importedAfter
    }

    private func isCanonicalLedgerTimestamp(_ value: String) -> Bool {
        TokenISO8601DateCodec.isCanonicalTimestamp(value)
    }

    private func forEachLedgerLine(
        in url: URL,
        startOffset: Int64 = 0,
        isCancelled: () -> Bool,
        _ handle: (SyncLedgerLineBytes) throws -> Void
    ) throws -> Bool {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var lineStart = try lineStartOffset(in: bytes, startOffset: startOffset)
            var cursor = lineStart
            var bytesUntilCancelCheck = 0

            while cursor < bytes.count {
                bytesUntilCancelCheck += 1
                if bytesUntilCancelCheck >= 16_384 {
                    guard !isCancelled() else { return false }
                    bytesUntilCancelCheck = 0
                }
                if bytes[cursor] == 10 {
                    if lineStart < cursor {
                        try handle(bytes[lineStart..<cursor])
                    }
                    lineStart = cursor + 1
                }
                cursor += 1
            }

            guard !isCancelled() else { return false }
            if lineStart < bytes.count {
                try handle(bytes[lineStart..<bytes.count])
            }
            return true
        }
    }

    private func lineStartOffset(in data: UnsafeBufferPointer<UInt8>, startOffset: Int64) throws -> Int {
        guard startOffset > 0 else { return 0 }
        guard startOffset <= Int64(data.count) else {
            throw SyncLedgerLineReadError.requiresFullRead
        }

        let offset = Int(startOffset)
        guard offset < data.count else { return offset }
        if data[offset] == 10 {
            return offset + 1
        }
        guard offset > 0 else { return 0 }
        guard data[offset - 1] == 10 else {
            throw SyncLedgerLineReadError.requiresFullRead
        }
        return offset
    }

    private func identityKey(from data: SyncLedgerLineBytes) -> String? {
        guard let deviceId = jsonStringValue(after: Self.deviceIdMarker, in: data),
              let eventId = jsonStringValue(after: Self.eventIdMarker, in: data) else {
            return nil
        }
        return "\(deviceId)|\(eventId)"
    }

    private func jsonStringValue(after marker: [UInt8], in data: SyncLedgerLineBytes) -> String? {
        guard let markerEnd = markerEndIndex(marker, in: data) else { return nil }
        var cursor = markerEnd
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)

        while cursor < data.endIndex {
            let byte = data[cursor]
            if byte == 0x22 {
                return String(bytes: bytes, encoding: .utf8)
            }
            if byte == 0x5C {
                cursor += 1
                guard cursor < data.endIndex else { return nil }
            }
            bytes.append(data[cursor])
            cursor += 1
        }
        return nil
    }

    private func markerEndIndex(_ marker: [UInt8], in data: SyncLedgerLineBytes) -> Int? {
        guard !marker.isEmpty, data.count >= marker.count else { return nil }
        var cursor = data.startIndex
        let lastStart = data.endIndex - marker.count

        while cursor <= lastStart {
            if data[cursor] == marker[0] {
                var matched = true
                for markerOffset in 1..<marker.count where data[cursor + markerOffset] != marker[markerOffset] {
                    matched = false
                    break
                }
                if matched {
                    return cursor + marker.count
                }
            }
            cursor += 1
        }
        return nil
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
        dateCodec.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        dateCodec.date(from: value)
    }

    private static let dateCodec = TokenISO8601DateCodec()
    private static let deviceIdMarker = Array(#""device_id":""#.utf8)
    private static let eventIdMarker = Array(#""event_id":""#.utf8)
    private static let timestampMarker = Array(#""timestamp":""#.utf8)
}

private enum SyncLedgerLineReadError: Error {
    case requiresFullRead
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
