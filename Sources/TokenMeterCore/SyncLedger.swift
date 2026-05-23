import CryptoKit
import Foundation

public final class TokenSyncLedgerStore: @unchecked Sendable {
    private let folder: URL
    private let localDevice: TokenDeviceMetadata
    private let fileManager: FileManager

    public init(folder: URL, localDevice: TokenDeviceMetadata, fileManager: FileManager = .default) {
        self.folder = folder
        self.localDevice = localDevice
        self.fileManager = fileManager
    }

    public func synchronize(
        localEvents: [TokenEvent],
        replaceLocalLedger: Bool = false,
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

        let readResult = readDeviceLedgers(isCancelled: isCancelled)
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
        if !replaceExisting, fileManager.fileExists(atPath: localLedgerURL.path) {
            let existing = readRecords(from: localLedgerURL, isCancelled: isCancelled).records
            for record in existing {
                recordsByKey[record.identityKey] = record
            }
        }

        for event in events where !isCancelled() {
            let record = SyncLedgerRecord(event: event.withDevice(localDevice))
            recordsByKey[record.identityKey] = record
        }

        let records = recordsByKey.values.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.eventId < $1.eventId
            }
            return $0.timestamp < $1.timestamp
        }
        let encoder = Self.jsonEncoder
        let lines = try records.map { record in
            let data = try encoder.encode(record)
            return String(decoding: data, as: UTF8.self)
        }
        let data = (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).data(using: .utf8) ?? Data()
        try data.write(to: localLedgerURL, options: [.atomic])
        return events.count
    }

    private func readDeviceLedgers(isCancelled: () -> Bool) -> (events: [TokenEvent], deviceFileCount: Int, parseErrorCount: Int) {
        let devicesURL = folder.appendingPathComponent("devices", isDirectory: true)
        guard fileManager.fileExists(atPath: devicesURL.path) else {
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

        for case let url as URL in enumerator where !isCancelled() && url.pathExtension == "jsonl" {
            fileCount += 1
            let result = readRecords(from: url, isCancelled: isCancelled)
            parseErrors += result.parseErrorCount
            events.append(contentsOf: result.records.map(\.tokenEvent))
        }

        return (events, fileCount, parseErrors)
    }

    private func readRecords(from url: URL, isCancelled: () -> Bool) -> (records: [SyncLedgerRecord], parseErrorCount: Int) {
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
