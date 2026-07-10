import Foundation

public struct CodexRateLimitWindow: Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMinutes: Int
    public let resetsAt: Date

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    public init(usedPercent: Int, windowDurationMinutes: Int, resetsAt: Date) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct CodexResetCreditSummary: Equatable, Sendable {
    public let availableCount: Int
    public let expirations: [Date]

    public init(availableCount: Int, expirations: [Date]) {
        self.availableCount = max(0, availableCount)
        self.expirations = expirations.sorted()
    }
}

public struct CodexAccountUsage: Equatable, Sendable {
    public let fiveHourWindow: CodexRateLimitWindow?
    public let sevenDayWindow: CodexRateLimitWindow?
    public let resetCredits: CodexResetCreditSummary?
    public let fetchedAt: Date

    public init(
        fiveHourWindow: CodexRateLimitWindow?,
        sevenDayWindow: CodexRateLimitWindow?,
        resetCredits: CodexResetCreditSummary?,
        fetchedAt: Date
    ) {
        self.fiveHourWindow = fiveHourWindow
        self.sevenDayWindow = sevenDayWindow
        self.resetCredits = resetCredits
        self.fetchedAt = fetchedAt
    }
}

public enum CodexAccountUsageError: Error, LocalizedError, Equatable {
    case executableNotFound
    case launchFailed
    case timedOut
    case connectionClosed
    case invalidResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex is not installed or could not be found."
        case .launchFailed:
            "Codex could not be started."
        case .timedOut:
            "Codex account status timed out."
        case .connectionClosed:
            "Codex closed before returning account status."
        case .invalidResponse:
            "Codex returned an account status this version cannot read."
        case .serverError(let message):
            message
        }
    }
}

public enum CodexAccountUsageParser {
    public static func parseRateLimitsResponse(
        _ data: Data,
        fetchedAt: Date = Date()
    ) throws -> CodexAccountUsage {
        let response: RPCResponse
        do {
            response = try JSONDecoder().decode(RPCResponse.self, from: data)
        } catch {
            throw CodexAccountUsageError.invalidResponse
        }

        if let error = response.error {
            throw CodexAccountUsageError.serverError(error.message)
        }
        guard let result = response.result else {
            throw CodexAccountUsageError.invalidResponse
        }

        let windows = [result.rateLimits.primary, result.rateLimits.secondary]
            .compactMap { $0 }
            .map { raw in
                CodexRateLimitWindow(
                    usedPercent: Int(raw.usedPercent.rounded()),
                    windowDurationMinutes: raw.windowDurationMins,
                    resetsAt: Date(timeIntervalSince1970: raw.resetsAt)
                )
            }
        let fiveHourWindow = windows.first { $0.windowDurationMinutes == 300 }
        let sevenDayWindow = windows.first { $0.windowDurationMinutes == 10_080 }

        let resetCredits = result.rateLimitResetCredits.map { raw in
            CodexResetCreditSummary(
                availableCount: raw.availableCount,
                expirations: (raw.credits ?? []).compactMap { credit in
                    guard let expiresAt = credit.expiresAt else { return nil }
                    return Date(timeIntervalSince1970: expiresAt)
                }
            )
        }

        return CodexAccountUsage(
            fiveHourWindow: fiveHourWindow,
            sevenDayWindow: sevenDayWindow,
            resetCredits: resetCredits,
            fetchedAt: fetchedAt
        )
    }
}

public struct CodexAccountUsageService: Sendable {
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 15) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func fetch() throws -> CodexAccountUsage {
        guard let executableURL = executableURL ?? Self.findCodexExecutable() else {
            throw CodexAccountUsageError.executableNotFound
        }

        let exchange = CodexAppServerExchange(executableURL: executableURL)
        let response = try exchange.run(timeout: timeout)
        return try CodexAccountUsageParser.parseRateLimitsResponse(response)
    }

    private static func findCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { component in
                URL(fileURLWithPath: String(component), isDirectory: true)
                    .appendingPathComponent("codex")
            })
        }

        var visited = Set<String>()
        return candidates.first { candidate in
            guard visited.insert(candidate.path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: candidate.path)
        }
    }
}

private struct RPCResponse: Decodable {
    let result: RateLimitsResult?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let message: String
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitResetCredits: ResetCredits?
}

private struct RateLimitSnapshot: Decodable {
    let primary: RawRateLimitWindow?
    let secondary: RawRateLimitWindow?
}

private struct RawRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: TimeInterval
}

private struct ResetCredits: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]?
}

private struct ResetCredit: Decodable {
    let expiresAt: TimeInterval?
}

private final class CodexAppServerExchange: @unchecked Sendable {
    private enum Phase {
        case waitingForInitialization
        case waitingForRateLimits
        case finished
    }

    private let executableURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()
    private var phase = Phase.waitingForInitialization
    private var result: Result<Data, CodexAccountUsageError>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func run(timeout: TimeInterval) throws -> Data {
        configureProcess()
        do {
            try process.run()
            try write(Self.initializeRequest)
        } catch {
            finish(.failure(.launchFailed))
        }

        let waitResult = completion.wait(timeout: .now() + max(1, timeout))
        if waitResult == .timedOut {
            finish(.failure(.timedOut))
        }

        closeConnection()
        guard let result = currentResult else {
            throw CodexAccountUsageError.connectionClosed
        }
        return try result.get()
    }

    private func configureProcess() {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.finish(.failure(.connectionClosed))
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        buffer.append(data)
        var lines = [Data]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: line),
              let id = envelope.id else {
            return
        }

        if id == 1, transition(from: .waitingForInitialization, to: .waitingForRateLimits) {
            do {
                try write(Self.rateLimitsRequest)
            } catch {
                finish(.failure(.connectionClosed))
            }
        } else if id == 2 {
            finish(.success(line))
        }
    }

    private func transition(from expected: Phase, to next: Phase) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == expected, result == nil else { return false }
        phase = next
        return true
    }

    private func finish(_ newResult: Result<Data, CodexAccountUsageError>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        phase = .finished
        lock.unlock()
        completion.signal()
    }

    private var currentResult: Result<Data, CodexAccountUsageError>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func write(_ data: Data) throws {
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func closeConnection() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private static let initializeRequest = Data(
        """
        {"method":"initialize","id":1,"params":{"clientInfo":{"name":"tokenmeter","title":"TokenMeter","version":"0.1.0"}}}
        """.utf8
    ) + Data([0x0A])

    private static let rateLimitsRequest = Data(
        """
        {"method":"initialized"}
        {"method":"account/rateLimits/read","id":2}
        """.utf8
    ) + Data([0x0A])
}

private struct RPCEnvelope: Decodable {
    let id: Int?
}
