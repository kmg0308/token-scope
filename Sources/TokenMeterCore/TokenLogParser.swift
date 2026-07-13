import CryptoKit
import Foundation

public enum TokenLogParser {
    enum IncrementalParseError: Error {
        case requiresFullFile
    }

    public static func parseCodexFile(
        at url: URL,
        startOffset: Int64 = 0,
        isCancelled: () -> Bool = { false }
    ) throws -> [TokenEvent] {
        var events: [TokenEvent] = []
        var projectPath = "Unknown"
        var model = "Unknown"
        var previousTotal: TokenUsage?
        var forkedSessionId: String?
        var isSkippingInheritedForkHistory = false
        let sessionId = sessionIdFromFileName(url.lastPathComponent)

        try forEachJSONLine(in: url, startOffset: startOffset, isCancelled: isCancelled) { index, object in
            guard let payload = object["payload"] as? [String: Any] else { return }

            if startOffset == 0,
               index == 0,
               object["type"] as? String == "session_meta",
               nonEmptyString(payload["forked_from_id"]) != nil,
               let currentSessionId = nonEmptyString(payload["id"]) {
                forkedSessionId = currentSessionId
                isSkippingInheritedForkHistory = true
            } else if isSkippingInheritedForkHistory,
                      let forkedSessionId,
                      startsTaskAtOrAfterSession(payload: payload, sessionId: forkedSessionId) {
                isSkippingInheritedForkHistory = false
                previousTotal = nil
            }

            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                projectPath = cwd
            }
            if let payloadModel = payload["model"] as? String, !payloadModel.isEmpty {
                model = payloadModel
            }

            let totalDict = nestedDict(payload, ["info", "total_token_usage"])
            let lastDict = nestedDict(payload, ["info", "last_token_usage"])
            guard totalDict != nil || lastDict != nil else { return }
            guard !isSkippingInheritedForkHistory else { return }

            guard let timestamp = dateParser.parse(object["timestamp"] as? String)
                ?? dateParser.parse(payload["timestamp"] as? String) else {
                if let totalDict {
                    previousTotal = codexUsage(from: totalDict)
                }
                return
            }

            let usage: TokenUsage?
            if let totalDict {
                let currentTotal = codexUsage(from: totalDict)
                if let previousTotal {
                    usage = deltaUsage(current: currentTotal, previous: previousTotal)
                } else if let lastDict {
                    usage = codexUsage(from: lastDict)
                } else {
                    if startOffset > 0 {
                        throw IncrementalParseError.requiresFullFile
                    }
                    usage = currentTotal
                }
                previousTotal = currentTotal
            } else if let lastDict {
                usage = codexUsage(from: lastDict)
            } else {
                usage = nil
            }

            guard let usage, usage.total > 0 else { return }
            let id = stableID(parts: ["codex", url.path, "\(index)", "\(Int(timestamp.timeIntervalSince1970))", "\(usage.total)"])
            events.append(TokenEvent(
                id: id,
                source: .codex,
                timestamp: timestamp,
                projectPath: projectPath,
                sessionId: sessionId,
                model: model,
                usage: usage,
                rawFilePath: url.path
            ))
        }

        return events
    }

    public static func parseClaudeFile(
        at url: URL,
        startOffset: Int64 = 0,
        isCancelled: () -> Bool = { false }
    ) throws -> [TokenEvent] {
        var events: [TokenEvent] = []
        var seenRequests = Set<String>()

        try forEachJSONLine(in: url, startOffset: startOffset, isCancelled: isCancelled) { index, object in
            guard let message = object["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any] else { return }

            let requestId = nonEmptyString(object["requestId"])
            let uuid = nonEmptyString(object["uuid"])
            let dedupeKey = requestId ?? uuid ?? "\(url.path)#\(index)"

            guard let timestamp = dateParser.parse(object["timestamp"] as? String) else { return }
            let model = nonEmptyString(message["model"]) ?? "Unknown"
            let projectPath = nonEmptyString(object["cwd"]) ?? "Unknown"
            let sessionId = nonEmptyString(object["sessionId"]) ?? sessionIdFromFileName(url.lastPathComponent)

            let usage = TokenUsage(
                input: intValue(usageDict["input_tokens"]),
                cacheCreation: intValue(usageDict["cache_creation_input_tokens"]),
                cacheRead: intValue(usageDict["cache_read_input_tokens"]),
                output: intValue(usageDict["output_tokens"])
            )
            guard usage.total > 0 else { return }
            if seenRequests.contains(dedupeKey) { return }
            seenRequests.insert(dedupeKey)

            let id = stableID(parts: ["claude", url.path, dedupeKey])
            events.append(TokenEvent(
                id: id,
                source: .claude,
                timestamp: timestamp,
                projectPath: projectPath,
                sessionId: sessionId,
                model: model,
                usage: usage,
                rawFilePath: url.path
            ))
        }

        return events
    }

    private static func codexUsage(from dict: [String: Any]) -> TokenUsage {
        let total = optionalIntValue(dict["total_tokens"]).flatMap { $0 > 0 ? $0 : nil }
        return TokenUsage(
            input: intValue(dict["input_tokens"]),
            cachedInput: intValue(dict["cached_input_tokens"]),
            output: intValue(dict["output_tokens"]),
            reasoning: intValue(dict["reasoning_output_tokens"]),
            total: total
        )
    }

    private static func deltaUsage(current: TokenUsage, previous: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(0, current.input - previous.input),
            cachedInput: max(0, current.cachedInput - previous.cachedInput),
            cacheCreation: max(0, current.cacheCreation - previous.cacheCreation),
            cacheRead: max(0, current.cacheRead - previous.cacheRead),
            output: max(0, current.output - previous.output),
            reasoning: max(0, current.reasoning - previous.reasoning),
            total: max(0, current.total - previous.total)
        )
    }

    private static func forEachJSONLine(
        in url: URL,
        startOffset: Int64,
        isCancelled: () -> Bool,
        _ handle: (Int, [String: Any]) throws -> Void
    ) throws {
        guard !isCancelled() else { return }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let startIndex = try lineStartIndex(in: data, startOffset: startOffset)
        var logicalLineIndex = logicalLineCount(in: data, before: startIndex)
        var lineStart = startIndex
        var cursor = startIndex
        var bytesUntilCancelCheck = 0

        while cursor < data.endIndex {
            bytesUntilCancelCheck += 1
            if bytesUntilCancelCheck >= 16_384 {
                guard !isCancelled() else { return }
                bytesUntilCancelCheck = 0
            }
            if data[cursor] == 10 {
                try processJSONLine(data, range: lineStart..<cursor, lineIndex: &logicalLineIndex, handle)
                lineStart = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }

        guard !isCancelled() else { return }
        try processJSONLine(data, range: lineStart..<data.endIndex, lineIndex: &logicalLineIndex, handle)
    }

    private static func processJSONLine(
        _ data: Data,
        range: Range<Data.Index>,
        lineIndex: inout Int,
        _ handle: (Int, [String: Any]) throws -> Void
    ) throws {
        guard !range.isEmpty else { return }
        let currentIndex = lineIndex
        lineIndex += 1

        guard let object = parseJSONObject(Data(data[range])) else { return }
        try handle(currentIndex, object)
    }

    private static func lineStartIndex(in data: Data, startOffset: Int64) throws -> Data.Index {
        guard startOffset > 0 else { return data.startIndex }
        let boundedOffset = min(Int(startOffset), data.count)
        let index = data.index(data.startIndex, offsetBy: boundedOffset)
        guard index > data.startIndex else { return data.startIndex }
        let previousIndex = data.index(before: index)
        guard data[previousIndex] == 10 else {
            throw IncrementalParseError.requiresFullFile
        }
        return index
    }

    private static func logicalLineCount(in data: Data, before endIndex: Data.Index) -> Int {
        var count = 0
        var lineStart = data.startIndex
        var cursor = data.startIndex

        while cursor < endIndex {
            if data[cursor] == 10 {
                if lineStart < cursor {
                    count += 1
                }
                lineStart = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }

        if lineStart < endIndex {
            count += 1
        }
        return count
    }

    private static func parseJSONObject(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func nestedDict(_ dict: [String: Any], _ path: [String]) -> [String: Any]? {
        var current: Any = dict
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    private static func intValue(_ value: Any?) -> Int {
        optionalIntValue(value) ?? 0
    }

    private static func optionalIntValue(_ value: Any?) -> Int? {
        if let string = value as? String { return Int(string) }
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }

        switch String(cString: number.objCType) {
        case "q", "l", "i", "s", "c":
            return Int(number.int64Value)
        case "Q", "L", "I", "S", "C":
            let value = number.uint64Value
            guard value <= UInt64(Int.max) else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func startsTaskAtOrAfterSession(payload: [String: Any], sessionId: String) -> Bool {
        guard payload["type"] as? String == "task_started",
              let taskId = nonEmptyString(payload["turn_id"]) ?? nonEmptyString(payload["id"]),
              let taskTimestamp = uuidV7Timestamp(taskId),
              let sessionTimestamp = uuidV7Timestamp(sessionId) else {
            return false
        }
        return taskTimestamp >= sessionTimestamp
    }

    private static func uuidV7Timestamp(_ value: String) -> UInt64? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        let compact = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        guard compact.count == 32,
              compact[compact.index(compact.startIndex, offsetBy: 12)] == "7" else {
            return nil
        }
        return UInt64(compact.prefix(12), radix: 16)
    }

    private static func sessionIdFromFileName(_ fileName: String) -> String {
        fileName.replacingOccurrences(of: ".jsonl", with: "")
    }

    private static func stableID(parts: [String]) -> String {
        let rawValue = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let dateParser = TokenISO8601DateCodec()
}
