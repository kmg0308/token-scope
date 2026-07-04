import Foundation

public struct CodexSessionCleanupFile: Hashable, Sendable {
    public var url: URL
    public var size: Int64
    public var eventCount: Int
    public var modifiedAt: Date

    public init(url: URL, size: Int64, eventCount: Int, modifiedAt: Date) {
        self.url = url
        self.size = size
        self.eventCount = eventCount
        self.modifiedAt = modifiedAt
    }
}

public struct CodexSessionCleanupPlan: Sendable {
    public var retentionDays: Int
    public var scannedFileCount: Int
    public var eligibleFiles: [CodexSessionCleanupFile]
    public var unsafeFileCount: Int
    public var uncachedFileCount: Int
    public var syncLedgerEventCount: Int
    public var createdAt: Date

    public init(
        retentionDays: Int,
        scannedFileCount: Int,
        eligibleFiles: [CodexSessionCleanupFile],
        unsafeFileCount: Int,
        uncachedFileCount: Int,
        syncLedgerEventCount: Int,
        createdAt: Date
    ) {
        self.retentionDays = retentionDays
        self.scannedFileCount = scannedFileCount
        self.eligibleFiles = eligibleFiles
        self.unsafeFileCount = unsafeFileCount
        self.uncachedFileCount = uncachedFileCount
        self.syncLedgerEventCount = syncLedgerEventCount
        self.createdAt = createdAt
    }

    public var eligibleFileCount: Int {
        eligibleFiles.count
    }

    public var eligibleByteCount: Int64 {
        eligibleFiles.reduce(0) { $0 + $1.size }
    }

    public var eligibleEventCount: Int {
        eligibleFiles.reduce(0) { $0 + $1.eventCount }
    }

    public var canApply: Bool {
        !eligibleFiles.isEmpty
    }
}

public struct CodexSessionCleanupResult: Sendable {
    public var plan: CodexSessionCleanupPlan
    public var archiveURL: URL
    public var archivedFileCount: Int
    public var removedFileCount: Int
    public var removedByteCount: Int64

    public init(
        plan: CodexSessionCleanupPlan,
        archiveURL: URL,
        archivedFileCount: Int,
        removedFileCount: Int,
        removedByteCount: Int64
    ) {
        self.plan = plan
        self.archiveURL = archiveURL
        self.archivedFileCount = archivedFileCount
        self.removedFileCount = removedFileCount
        self.removedByteCount = removedByteCount
    }
}

public final class CodexSessionCleanupManager: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let cacheStore: TokenEventCacheStore?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        cacheStore: TokenEventCacheStore? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.cacheStore = cacheStore ?? Self.defaultCacheStore(for: homeDirectory, fileManager: fileManager)
    }

    public func plan(retentionDays: Int = 90, now: Date = Date()) -> CodexSessionCleanupPlan {
        let clampedRetentionDays = max(1, retentionDays)
        let cutoff = now.addingTimeInterval(-Double(clampedRetentionDays) * 24 * 60 * 60)
        let candidates = codexSessionFiles(modifiedBefore: cutoff)
        guard let cacheStore else {
            return CodexSessionCleanupPlan(
                retentionDays: clampedRetentionDays,
                scannedFileCount: candidates.count,
                eligibleFiles: [],
                unsafeFileCount: 0,
                uncachedFileCount: candidates.count,
                syncLedgerEventCount: 0,
                createdAt: now
            )
        }

        let syncKeys = (try? cacheStore.syncLedgerEventKeys()) ?? []
        var eligibleFiles: [CodexSessionCleanupFile] = []
        var unsafeFileCount = 0
        var uncachedFileCount = 0

        for candidate in candidates {
            let keys = try? cacheStore.codexLocalLogEventKeys(originPath: candidate.url.path)
            guard let keys else {
                uncachedFileCount += 1
                continue
            }
            guard keys.allSatisfy(syncKeys.contains) else {
                unsafeFileCount += 1
                continue
            }
            eligibleFiles.append(CodexSessionCleanupFile(
                url: candidate.url,
                size: candidate.size,
                eventCount: keys.count,
                modifiedAt: candidate.modifiedAt
            ))
        }

        return CodexSessionCleanupPlan(
            retentionDays: clampedRetentionDays,
            scannedFileCount: candidates.count,
            eligibleFiles: eligibleFiles.sorted { $0.url.path < $1.url.path },
            unsafeFileCount: unsafeFileCount,
            uncachedFileCount: uncachedFileCount,
            syncLedgerEventCount: syncKeys.count,
            createdAt: now
        )
    }

    public func archiveAndRemove(_ plan: CodexSessionCleanupPlan) throws -> CodexSessionCleanupResult {
        guard plan.canApply else {
            throw CleanupError(message: "No verified Codex session files are ready to archive.")
        }

        try validateUnchanged(plan.eligibleFiles)
        let archiveURL = archiveDirectory().appendingPathComponent(archiveFileName(for: plan))
        try createArchive(for: plan.eligibleFiles.map(\.url), at: archiveURL)
        let archivedFileCount = try archivedEntryCount(at: archiveURL)
        guard archivedFileCount == plan.eligibleFileCount else {
            throw CleanupError(message: "Archive verification failed before removing session files.")
        }

        try validateUnchanged(plan.eligibleFiles)
        var removedFileCount = 0
        var removedByteCount: Int64 = 0
        for file in plan.eligibleFiles {
            do {
                try fileManager.removeItem(at: file.url)
                removedFileCount += 1
                removedByteCount += file.size
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
        pruneEmptySourceDirectories()

        return CodexSessionCleanupResult(
            plan: plan,
            archiveURL: archiveURL,
            archivedFileCount: archivedFileCount,
            removedFileCount: removedFileCount,
            removedByteCount: removedByteCount
        )
    }

    private func validateUnchanged(_ files: [CodexSessionCleanupFile]) throws {
        for file in files {
            guard let current = candidateSnapshot(for: file.url) else {
                throw CleanupError(message: "Codex session changed before cleanup could finish.")
            }
            guard current.size == file.size,
                  abs(current.modifiedAt.timeIntervalSince(file.modifiedAt)) < 0.000_001 else {
                throw CleanupError(message: "Codex session changed before cleanup could finish.")
            }
        }
    }

    private func codexSessionFiles(modifiedBefore cutoff: Date) -> [CandidateFile] {
        codexRoots().flatMap { root in
            guard fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return [] as [CandidateFile]
            }

            var files: [CandidateFile] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                files.append(CandidateFile(
                    url: url.resolvingSymlinksInPath(),
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: modifiedAt
                ))
            }
            return files
        }
    }

    private func candidateSnapshot(for url: URL) -> CandidateFile? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              let modifiedAt = values.contentModificationDate else {
            return nil
        }
        return CandidateFile(
            url: resolved,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: modifiedAt
        )
    }

    private func createArchive(for urls: [URL], at archiveURL: URL) throws {
        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setPrivatePermissions(on: archiveURL.deletingLastPathComponent(), permissions: 0o700)

        let listURL = fileManager.temporaryDirectory
            .appendingPathComponent("tokenmeter-codex-cleanup-\(UUID().uuidString).list")
        defer { try? fileManager.removeItem(at: listURL) }
        let entries = try urls.map(relativePath)
        try (entries.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-C", homeDirectory.path,
            "-czf", archiveURL.path,
            "-T", listURL.path
        ]
        try run(process)
        try setPrivatePermissions(on: archiveURL, permissions: 0o600)
    }

    private func archivedEntryCount(at archiveURL: URL) throws -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", archiveURL.path]
        process.standardOutput = pipe
        try run(process)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func run(_ process: Process) throws {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CleanupError(message: "Archive command failed with status \(process.terminationStatus).")
        }
    }

    private func relativePath(for url: URL) throws -> String {
        let root = homeDirectory.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path == root || path.hasPrefix(root + "/") else {
            throw CleanupError(message: "Refusing to archive a file outside the home directory.")
        }
        return String(path.dropFirst(root.count + 1))
    }

    private func archiveDirectory() -> URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("session_archives", isDirectory: true)
    }

    private func archiveFileName(for plan: CodexSessionCleanupPlan) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "codex-sessions-older-than-\(plan.retentionDays)d-\(formatter.string(from: Date())).tar.gz"
    }

    private func pruneEmptySourceDirectories() {
        for root in codexRoots() {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let urls = (fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }) ?? []
            for url in urls.sorted(by: { $0.path.count > $1.path.count }) {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      isDirectoryEmpty(url) else {
                    continue
                }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        return contents.isEmpty
    }

    private func setPrivatePermissions(on url: URL, permissions: Int) throws {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func codexRoots() -> [URL] {
        [
            homeDirectory.appendingPathComponent(".codex/sessions"),
            homeDirectory.appendingPathComponent(".codex/archived_sessions")
        ]
    }

    private static func defaultCacheStore(for homeDirectory: URL, fileManager: FileManager) -> TokenEventCacheStore? {
        let requestedHome = homeDirectory.resolvingSymlinksInPath().path
        let defaultHome = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard requestedHome == defaultHome else { return nil }
        return TokenEventCacheStore.defaultStore(fileManager: fileManager)
    }

    private struct CandidateFile {
        var url: URL
        var size: Int64
        var modifiedAt: Date
    }

    private struct CleanupError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
