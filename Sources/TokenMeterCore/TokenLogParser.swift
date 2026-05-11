import Foundation

public enum TokenLogParser {
    public static func parseCodexFile(at url: URL) throws -> [TokenEvent] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var events: [TokenEvent] = []
        var projectPath = "Unknown"
        var model = "Unknown"
        var previousTotal: TokenUsage?
        let sessionId = sessionIdFromFileName(url.lastPathComponent)

        for (index, line) in lines.enumerated() {
            guard let object = parseJSONObject(String(line)) else { continue }
            guard let payload = object["payload"] as? [String: Any] else { continue }

            if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                projectPath = cwd
            }
            if let payloadModel = payload["model"] as? String, !payloadModel.isEmpty {
                model = payloadModel
            }

            let timestamp = parseDate(object["timestamp"] as? String)
                ?? parseDate(payload["timestamp"] as? String)
                ?? Date(timeIntervalSince1970: 0)

            let totalDict = nestedDict(payload, ["info", "total_token_usage"])
            let lastDict = nestedDict(payload, ["info", "last_token_usage"])
            guard totalDict != nil || lastDict != nil else { continue }

            let usage: TokenUsage?
            if let totalDict {
                let currentTotal = codexUsage(from: totalDict)
                if let previousTotal {
                    usage = deltaUsage(current: currentTotal, previous: previousTotal)
                } else if let lastDict {
                    usage = codexUsage(from: lastDict)
                } else {
                    usage = currentTotal
                }
                previousTotal = currentTotal
            } else if let lastDict {
                usage = codexUsage(from: lastDict)
            } else {
                usage = nil
            }

            guard let usage, usage.total > 0 else { continue }
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

    public static func parseClaudeFile(at url: URL) throws -> [TokenEvent] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        var events: [TokenEvent] = []
        var seenRequests = Set<String>()

        for (index, line) in lines.enumerated() {
            guard let object = parseJSONObject(String(line)) else { continue }
            guard let message = object["message"] as? [String: Any],
                  let usageDict = message["usage"] as? [String: Any] else { continue }

            let requestId = object["requestId"] as? String
            let uuid = object["uuid"] as? String
            let dedupeKey = requestId ?? uuid ?? "\(url.path)#\(index)"
            if seenRequests.contains(dedupeKey) { continue }
            seenRequests.insert(dedupeKey)

            let timestamp = parseDate(object["timestamp"] as? String) ?? Date(timeIntervalSince1970: 0)
            let model = (message["model"] as? String) ?? "Unknown"
            let projectPath = (object["cwd"] as? String) ?? "Unknown"
            let sessionId = (object["sessionId"] as? String) ?? sessionIdFromFileName(url.lastPathComponent)

            let usage = TokenUsage(
                input: intValue(usageDict["input_tokens"]),
                cacheCreation: intValue(usageDict["cache_creation_input_tokens"]),
                cacheRead: intValue(usageDict["cache_read_input_tokens"]),
                output: intValue(usageDict["output_tokens"])
            )
            guard usage.total > 0 else { continue }

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

    private static func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
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

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func sessionIdFromFileName(_ fileName: String) -> String {
        fileName.replacingOccurrences(of: ".jsonl", with: "")
    }

    private static func stableID(parts: [String]) -> String {
        parts.joined(separator: "|")
    }
}
