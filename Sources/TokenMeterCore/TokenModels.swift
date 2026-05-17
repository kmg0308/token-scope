import Foundation

public enum TokenSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var cachedInput: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var output: Int
    public var reasoning: Int
    public var total: Int

    public init(
        input: Int = 0,
        cachedInput: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        total: Int? = nil
    ) {
        self.input = max(0, input)
        self.cachedInput = max(0, cachedInput)
        self.cacheCreation = max(0, cacheCreation)
        self.cacheRead = max(0, cacheRead)
        self.output = max(0, output)
        self.reasoning = max(0, reasoning)
        self.total = max(0, total ?? (input + cacheCreation + cacheRead + output))
    }

    public static let zero = TokenUsage()

    public func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: input + other.input,
            cachedInput: cachedInput + other.cachedInput,
            cacheCreation: cacheCreation + other.cacheCreation,
            cacheRead: cacheRead + other.cacheRead,
            output: output + other.output,
            reasoning: reasoning + other.reasoning,
            total: total + other.total
        )
    }

    public func displayComponents(source: TokenSource) -> [TokenComponent] {
        let plainInput: Int
        let cache: Int
        switch source {
        case .codex:
            plainInput = max(0, input - cachedInput)
            cache = cachedInput
        case .claude:
            plainInput = input
            cache = cacheCreation + cacheRead
        case .all:
            plainInput = max(0, input - cachedInput)
            cache = cachedInput + cacheCreation + cacheRead
        }

        let visibleOutput = max(0, output - reasoning)
        return [
            TokenComponent(kind: .input, value: plainInput),
            TokenComponent(kind: .cache, value: cache),
            TokenComponent(kind: .output, value: visibleOutput),
            TokenComponent(kind: .reasoning, value: reasoning)
        ].filter { $0.value > 0 }
    }
}

public enum TokenComponentKind: String, CaseIterable, Codable, Sendable {
    case input = "Input"
    case cache = "Cache"
    case output = "Output"
    case reasoning = "Reasoning"
}

public struct TokenComponent: Hashable, Sendable {
    public var kind: TokenComponentKind
    public var value: Int
}

public struct TokenEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var source: TokenSource
    public var timestamp: Date
    public var projectPath: String
    public var sessionId: String
    public var model: String
    public var usage: TokenUsage
    public var rawFilePath: String

    public init(
        id: String,
        source: TokenSource,
        timestamp: Date,
        projectPath: String = "Unknown",
        sessionId: String = "Unknown",
        model: String = "Unknown",
        usage: TokenUsage,
        rawFilePath: String
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.projectPath = projectPath.isEmpty ? "Unknown" : projectPath
        self.sessionId = sessionId.isEmpty ? "Unknown" : sessionId
        self.model = model.isEmpty ? "Unknown" : model
        self.usage = usage
        self.rawFilePath = rawFilePath
    }
}

public struct ScanResult: Sendable {
    public var events: [TokenEvent]
    public var codexFileCount: Int
    public var claudeFileCount: Int
    public var parseErrorCount: Int
    public var sourceStatuses: [ScanSourceStatus]
    public var scannedAt: Date

    public init(
        events: [TokenEvent] = [],
        codexFileCount: Int = 0,
        claudeFileCount: Int = 0,
        parseErrorCount: Int = 0,
        sourceStatuses: [ScanSourceStatus] = [],
        scannedAt: Date = Date()
    ) {
        self.events = events
        self.codexFileCount = codexFileCount
        self.claudeFileCount = claudeFileCount
        self.parseErrorCount = parseErrorCount
        self.sourceStatuses = sourceStatuses
        self.scannedAt = scannedAt
    }
}

public struct ScanSourceStatus: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var source: TokenSource
    public var label: String
    public var path: String
    public var exists: Bool
    public var totalFileCount: Int
    public var scannedFileCount: Int
    public var parseErrorCount: Int

    public init(
        source: TokenSource,
        label: String,
        path: String,
        exists: Bool,
        totalFileCount: Int,
        scannedFileCount: Int,
        parseErrorCount: Int = 0
    ) {
        self.source = source
        self.label = label
        self.path = path
        self.exists = exists
        self.totalFileCount = totalFileCount
        self.scannedFileCount = scannedFileCount
        self.parseErrorCount = parseErrorCount
    }
}

public struct TimeBucket: Identifiable, Hashable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var usage: TokenUsage
    public var sourceUsage: [TokenSource: TokenUsage]

    public init(start: Date, usage: TokenUsage, sourceUsage: [TokenSource: TokenUsage]) {
        self.start = start
        self.usage = usage
        self.sourceUsage = sourceUsage
    }
}

public struct GroupedUsageRow: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var source: TokenSource
    public var usage: TokenUsage
    public var count: Int
    public var lastActive: Date

    public init(key: String, source: TokenSource = .all, usage: TokenUsage, count: Int, lastActive: Date) {
        self.key = key
        self.source = source
        self.usage = usage
        self.count = count
        self.lastActive = lastActive
    }
}
