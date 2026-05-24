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

    enum CodingKeys: String, CodingKey {
        case input
        case cachedInput
        case cacheCreation
        case cacheRead
        case output
        case reasoning
        case total
    }

    public init(
        input: Int = 0,
        cachedInput: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        total: Int? = nil
    ) {
        let normalizedInput = Self.nonnegative(input)
        let normalizedCachedInput = min(Self.nonnegative(cachedInput), normalizedInput)
        let normalizedCacheCreation = Self.nonnegative(cacheCreation)
        let normalizedCacheRead = Self.nonnegative(cacheRead)
        let normalizedOutput = Self.nonnegative(output)
        let normalizedReasoning = Self.nonnegative(reasoning)

        self.input = normalizedInput
        self.cachedInput = normalizedCachedInput
        self.cacheCreation = normalizedCacheCreation
        self.cacheRead = normalizedCacheRead
        self.output = normalizedOutput
        self.reasoning = normalizedReasoning
        self.total = if let total {
            Self.nonnegative(total)
        } else {
            Self.saturatingSum(normalizedInput, normalizedCacheCreation, normalizedCacheRead, normalizedOutput)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        let cachedInput = try container.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0
        let cacheCreation = try container.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0
        let cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        let output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        let reasoning = try container.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
        let total = try container.decodeIfPresent(Int.self, forKey: .total)
            .flatMap { $0 > 0 ? $0 : nil }

        self.init(
            input: input,
            cachedInput: cachedInput,
            cacheCreation: cacheCreation,
            cacheRead: cacheRead,
            output: output,
            reasoning: reasoning,
            total: total
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(cachedInput, forKey: .cachedInput)
        try container.encode(cacheCreation, forKey: .cacheCreation)
        try container.encode(cacheRead, forKey: .cacheRead)
        try container.encode(output, forKey: .output)
        try container.encode(reasoning, forKey: .reasoning)
        try container.encode(total, forKey: .total)
    }

    public static let zero = TokenUsage()

    public func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: Self.saturatingAdd(Self.nonnegative(input), Self.nonnegative(other.input)),
            cachedInput: Self.saturatingAdd(Self.nonnegative(cachedInput), Self.nonnegative(other.cachedInput)),
            cacheCreation: Self.saturatingAdd(Self.nonnegative(cacheCreation), Self.nonnegative(other.cacheCreation)),
            cacheRead: Self.saturatingAdd(Self.nonnegative(cacheRead), Self.nonnegative(other.cacheRead)),
            output: Self.saturatingAdd(Self.nonnegative(output), Self.nonnegative(other.output)),
            reasoning: Self.saturatingAdd(Self.nonnegative(reasoning), Self.nonnegative(other.reasoning)),
            total: Self.saturatingAdd(Self.nonnegative(total), Self.nonnegative(other.total))
        )
    }

    private static func nonnegative(_ value: Int) -> Int {
        max(0, value)
    }

    private static func saturatingSum(_ values: Int...) -> Int {
        values.reduce(0) { saturatingAdd($0, $1) }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
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
            cache = Self.saturatingAdd(cacheCreation, cacheRead)
        case .all:
            plainInput = max(0, input - cachedInput)
            cache = Self.saturatingSum(cachedInput, cacheCreation, cacheRead)
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
    public var deviceId: String
    public var deviceName: String
    public var projectPath: String
    public var sessionId: String
    public var model: String
    public var usage: TokenUsage
    public var rawFilePath: String

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case timestamp
        case deviceId
        case deviceName
        case projectPath
        case sessionId
        case model
        case usage
        case rawFilePath
    }

    public init(
        id: String,
        source: TokenSource,
        timestamp: Date,
        deviceId: String = TokenDeviceMetadata.localFallback.id,
        deviceName: String = TokenDeviceMetadata.localFallback.name,
        projectPath: String = "Unknown",
        sessionId: String = "Unknown",
        model: String = "Unknown",
        usage: TokenUsage,
        rawFilePath: String
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.deviceId = deviceId.isEmpty ? TokenDeviceMetadata.localFallback.id : deviceId
        self.deviceName = deviceName.isEmpty ? TokenDeviceMetadata.localFallback.name : deviceName
        self.projectPath = projectPath.isEmpty ? "Unknown" : projectPath
        self.sessionId = sessionId.isEmpty ? "Unknown" : sessionId
        self.model = model.isEmpty ? "Unknown" : model
        self.usage = usage
        self.rawFilePath = rawFilePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            source: try container.decode(TokenSource.self, forKey: .source),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            deviceId: try container.decodeIfPresent(String.self, forKey: .deviceId) ?? TokenDeviceMetadata.localFallback.id,
            deviceName: try container.decodeIfPresent(String.self, forKey: .deviceName) ?? TokenDeviceMetadata.localFallback.name,
            projectPath: try container.decodeIfPresent(String.self, forKey: .projectPath) ?? "Unknown",
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId) ?? "Unknown",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "Unknown",
            usage: try container.decode(TokenUsage.self, forKey: .usage),
            rawFilePath: try container.decode(String.self, forKey: .rawFilePath)
        )
    }

    public func withDevice(_ device: TokenDeviceMetadata) -> TokenEvent {
        TokenEvent(
            id: id,
            source: source,
            timestamp: timestamp,
            deviceId: device.id,
            deviceName: device.name,
            projectPath: projectPath,
            sessionId: sessionId,
            model: model,
            usage: usage,
            rawFilePath: rawFilePath
        )
    }
}

public struct ScanResult: Sendable {
    public var events: [TokenEvent]
    public var codexFileCount: Int
    public var claudeFileCount: Int
    public var parseErrorCount: Int
    public var sourceStatuses: [ScanSourceStatus]
    public var syncStatus: SyncFolderStatus
    public var scannedAt: Date

    public init(
        events: [TokenEvent] = [],
        codexFileCount: Int = 0,
        claudeFileCount: Int = 0,
        parseErrorCount: Int = 0,
        sourceStatuses: [ScanSourceStatus] = [],
        syncStatus: SyncFolderStatus = .disabled,
        scannedAt: Date = Date()
    ) {
        self.events = events
        self.codexFileCount = codexFileCount
        self.claudeFileCount = claudeFileCount
        self.parseErrorCount = parseErrorCount
        self.sourceStatuses = sourceStatuses
        self.syncStatus = syncStatus
        self.scannedAt = scannedAt
    }
}

public struct TokenDeviceMetadata: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id.isEmpty ? Self.localFallback.id : id
        self.name = name.isEmpty ? Self.localFallback.name : name
    }

    public static let localFallback = TokenDeviceMetadata(id: "local-device", name: "This Mac")
}

public struct SyncFolderStatus: Hashable, Sendable {
    public var path: String?
    public var exists: Bool
    public var deviceFileCount: Int
    public var importedEventCount: Int
    public var exportedEventCount: Int
    public var parseErrorCount: Int
    public var exportError: String?
    public var lastSyncedAt: Date?

    public init(
        path: String?,
        exists: Bool,
        deviceFileCount: Int = 0,
        importedEventCount: Int = 0,
        exportedEventCount: Int = 0,
        parseErrorCount: Int = 0,
        exportError: String? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.path = path
        self.exists = exists
        self.deviceFileCount = deviceFileCount
        self.importedEventCount = importedEventCount
        self.exportedEventCount = exportedEventCount
        self.parseErrorCount = parseErrorCount
        self.exportError = exportError
        self.lastSyncedAt = lastSyncedAt
    }

    public var isConfigured: Bool {
        path != nil
    }

    public static let disabled = SyncFolderStatus(path: nil, exists: false)
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
    public var usage: TokenUsage
    public var count: Int
    public var lastActive: Date

    public init(key: String, usage: TokenUsage, count: Int, lastActive: Date) {
        self.key = key
        self.usage = usage
        self.count = count
        self.lastActive = lastActive
    }
}
