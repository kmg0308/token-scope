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
        let sessionId = sessionIdFromFileName(url.lastPathComponent)
        let dateParser = DateParser()

        try forEachJSONLine(in: url, startOffset: startOffset, isCancelled: isCancelled) { index, object in
            guard let payload = object["payload"] as? [String: Any] else { return }

            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                projectPath = cwd
            }
            if let payloadModel = payload["model"] as? String, !payloadModel.isEmpty {
                model = payloadModel
            }

            let timestamp = dateParser.parse(object["timestamp"] as? String)
                ?? dateParser.parse(payload["timestamp"] as? String)
                ?? Date(timeIntervalSince1970: 0)

            let totalDict = nestedDict(payload, ["info", "total_token_usage"])
            let lastDict = nestedDict(payload, ["info", "last_token_usage"])
            guard totalDict != nil || lastDict != nil else { return }

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
        let dateParser = DateParser()

        try forEachJSONLine(in: url, startOffset: startOffset, isCancelled: isCancelled) { index, object in
            guard let message = object["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any] else { return }

            let requestId = object["requestId"] as? String
            let uuid = object["uuid"] as? String
            let dedupeKey = requestId ?? uuid ?? "\(url.path)#\(index)"
            if seenRequests.contains(dedupeKey) { return }
            seenRequests.insert(dedupeKey)

            let timestamp = dateParser.parse(object["timestamp"] as? String) ?? Date(timeIntervalSince1970: 0)
            let model = (message["model"] as? String) ?? "Unknown"
            let projectPath = (object["cwd"] as? String) ?? "Unknown"
            let sessionId = (object["sessionId"] as? String) ?? sessionIdFromFileName(url.lastPathComponent)

            let usage = TokenUsage(
                input: intValue(usageDict["input_tokens"]),
                cacheCreation: intValue(usageDict["cache_creation_input_tokens"]),
                cacheRead: intValue(usageDict["cache_read_input_tokens"]),
                output: intValue(usageDict["output_tokens"])
            )
            guard usage.total > 0 else { return }

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
        TokenUsage(
            input: intValue(dict["input_tokens"]),
            cachedInput: intValue(dict["cached_input_tokens"]),
            output: intValue(dict["output_tokens"]),
            reasoning: intValue(dict["reasoning_output_tokens"]),
            total: intValue(dict["total_tokens"])
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
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let startIndex = try lineStartIndex(in: data, startOffset: startOffset)
        var logicalLineIndex = logicalLineCount(in: data, before: startIndex)
        var lineStart = startIndex
        var cursor = startIndex

        while cursor < data.endIndex, !isCancelled() {
            if data[cursor] == 10 {
                try processJSONLine(data, range: lineStart..<cursor, lineIndex: &logicalLineIndex, handle)
                lineStart = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }

        if !isCancelled() {
            try processJSONLine(data, range: lineStart..<data.endIndex, lineIndex: &logicalLineIndex, handle)
        }
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
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private final class DateParser {
        private let fractionalFormatter: ISO8601DateFormatter
        private let plainFormatter: ISO8601DateFormatter

        init() {
            fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plainFormatter = ISO8601DateFormatter()
            plainFormatter.formatOptions = [.withInternetDateTime]
        }

        func parse(_ string: String?) -> Date? {
            guard let string else { return nil }
            return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
        }
    }

    private static func sessionIdFromFileName(_ fileName: String) -> String {
        fileName.replacingOccurrences(of: ".jsonl", with: "")
    }

    private static func stableID(parts: [String]) -> String {
        let rawValue = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
