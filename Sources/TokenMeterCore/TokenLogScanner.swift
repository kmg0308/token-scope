import Foundation

public final class TokenLogScanner: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let localDevice: TokenDeviceMetadata
    private let cacheStore: TokenEventCacheStore?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        localDevice: TokenDeviceMetadata = .localFallback,
        cacheStore: TokenEventCacheStore? = TokenEventCacheStore.defaultStore()
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.localDevice = localDevice
        self.cacheStore = cacheStore
    }

    public func scan(
        modifiedAfter: Date? = nil,
        syncFolder: URL? = nil,
        replaceSyncLedger: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> ScanResult {
        guard !isCancelled() else { return ScanResult() }
        var roots = scanRoots(modifiedAfter: modifiedAfter)
        cleanupMissingLocalCacheEntries(roots: roots)
        var localEvents: [TokenEvent] = []

        for index in roots.indices {
            guard roots[index].source == .codex else { continue }
            let files = roots[index].selectedFiles
            var parseErrors = 0
            for file in files {
                guard !isCancelled() else { break }
                let result = cachedOrParsedEvents(for: file, isCancelled: isCancelled) {
                    try TokenLogParser.parseCodexFile(at: file.url, isCancelled: isCancelled)
                }
                switch result {
                case .success(let events):
                    localEvents.append(contentsOf: events)
                case .failure:
                    parseErrors += 1
                }
            }
            roots[index].parseErrorCount = parseErrors
        }

        for index in roots.indices {
            guard roots[index].source == .claude else { continue }
            let files = roots[index].selectedFiles
            var parseErrors = 0
            for file in files {
                guard !isCancelled() else { break }
                let result = cachedOrParsedEvents(for: file, isCancelled: isCancelled) {
                    try TokenLogParser.parseClaudeFile(at: file.url, isCancelled: isCancelled)
                }
                switch result {
                case .success(let events):
                    localEvents.append(contentsOf: events)
                case .failure:
                    parseErrors += 1
                }
            }
            roots[index].parseErrorCount = parseErrors
        }

        let sourceStatuses = roots.map(\.status)
        let codexFileCount = sourceStatuses
            .filter { $0.source == .codex }
            .map(\.scannedFileCount)
            .reduce(0, +)
        let claudeFileCount = sourceStatuses
            .filter { $0.source == .claude }
            .map(\.scannedFileCount)
            .reduce(0, +)
        let parseErrors = sourceStatuses
            .map(\.parseErrorCount)
            .reduce(0, +)

        let syncOutcome = syncEvents(
            localEvents: localEvents,
            syncFolder: syncFolder,
            replaceSyncLedger: replaceSyncLedger,
            importedAfter: modifiedAfter,
            cacheStore: cacheStore,
            isCancelled: isCancelled
        )
        let events = deduplicated(events: localEvents + syncOutcome.events)

        return ScanResult(
            events: events,
            codexFileCount: codexFileCount,
            claudeFileCount: claudeFileCount,
            parseErrorCount: parseErrors,
            sourceStatuses: sourceStatuses,
            syncStatus: syncOutcome.status,
            scannedAt: Date()
        )
    }

    public func findCodexFiles() -> [URL] {
        codexRoots().flatMap { jsonlFileURLs(under: $0.url) }
    }

    public func findClaudeFiles() -> [URL] {
        jsonlFileURLs(under: claudeRoot().url)
    }

    public func clearCache() throws {
        try cacheStore?.clear()
    }

    private func scanRoots(modifiedAfter: Date?) -> [RootScan] {
        (codexRoots() + [claudeRoot()]).map { root in
            let allFiles = jsonlFiles(under: root.url, source: root.source)
            let selected = selectedFiles(allFiles, modifiedAfter: modifiedAfter)
            return RootScan(
                source: root.source,
                label: root.label,
                url: root.url,
                exists: fileManager.fileExists(atPath: root.url.path),
                totalFiles: allFiles.count,
                selectedFiles: selected,
                allFilePaths: allFiles.map(\.cachePath)
            )
        }
    }

    private func cleanupMissingLocalCacheEntries(roots: [RootScan]) {
        guard let cacheStore else { return }
        let paths = Set(roots.flatMap(\.allFilePaths))
        try? cacheStore.removeMissingOrigins(originKind: .localLog, keeping: paths)
    }

    private func codexRoots() -> [LogRoot] {
        [
            LogRoot(
                source: .codex,
                label: "Codex sessions",
                url: homeDirectory.appendingPathComponent(".codex/sessions")
            ),
            LogRoot(
                source: .codex,
                label: "Codex archive",
                url: homeDirectory.appendingPathComponent(".codex/archived_sessions")
            )
        ]
    }

    private func claudeRoot() -> LogRoot {
        LogRoot(
            source: .claude,
            label: "Claude projects",
            url: homeDirectory.appendingPathComponent(".claude/projects")
        )
    }

    private struct LogRoot {
        var source: TokenSource
        var label: String
        var url: URL
    }

    private struct RootScan {
        var source: TokenSource
        var label: String
        var url: URL
        var exists: Bool
        var totalFiles: Int
        var selectedFiles: [LogFile]
        var allFilePaths: [String]
        var parseErrorCount = 0

        var status: ScanSourceStatus {
            ScanSourceStatus(
                source: source,
                label: label,
                path: url.path,
                exists: exists,
                totalFileCount: totalFiles,
                scannedFileCount: selectedFiles.count,
                parseErrorCount: parseErrorCount
            )
        }
    }

    private struct LogFile {
        var url: URL
        var cachePath: String
        var source: TokenSource
        var size: Int64
        var modificationDate: Date

        func cacheSnapshot(for device: TokenDeviceMetadata) -> TokenEventCacheStore.FileSnapshot {
            TokenEventCacheStore.FileSnapshot(
                path: cachePath,
                source: source,
                size: size,
                modifiedAt: modificationDate,
                deviceId: device.id
            )
        }
    }

    private enum FileEventResult {
        case success([TokenEvent])
        case failure
    }

    private func jsonlFileURLs(under root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private func jsonlFiles(under root: URL, source: TokenSource) -> [LogFile] {
        jsonlFileURLs(under: root).compactMap { url in
            guard let snapshot = TokenEventCacheStore.FileSnapshot.make(
                for: url,
                source: source,
                deviceId: nil,
                fileManager: fileManager
            ) else {
                return nil
            }
            return LogFile(
                url: url,
                cachePath: snapshot.path,
                source: source,
                size: snapshot.size,
                modificationDate: snapshot.modifiedAt
            )
        }
    }

    private func selectedFiles(_ files: [LogFile], modifiedAfter: Date?) -> [LogFile] {
        let filtered = files.filter { url in
            if let modifiedAfter {
                guard url.modificationDate >= modifiedAfter else { return false }
            }
            return true
        }
        return filtered.sorted {
            $0.modificationDate > $1.modificationDate
        }
    }

    private func cachedOrParsedEvents(
        for file: LogFile,
        isCancelled: () -> Bool,
        parse: () throws -> [TokenEvent]
    ) -> FileEventResult {
        let snapshot = file.cacheSnapshot(for: localDevice)
        if let cached = try? cacheStore?.cachedEvents(for: snapshot, originKind: .localLog) {
            switch cached {
            case .events(let events):
                return .success(events)
            case .parseError:
                return .failure
            }
        }

        do {
            let events = try parse().map { $0.withDevice(localDevice) }
            if !isCancelled() {
                try? cacheStore?.replaceEvents(events, for: snapshot, originKind: .localLog)
            }
            return .success(events)
        } catch {
            if !isCancelled() {
                try? cacheStore?.replaceEvents([], for: snapshot, originKind: .localLog, parseError: true)
            }
            return .failure
        }
    }

    private func syncEvents(
        localEvents: [TokenEvent],
        syncFolder: URL?,
        replaceSyncLedger: Bool,
        importedAfter: Date?,
        cacheStore: TokenEventCacheStore?,
        isCancelled: () -> Bool
    ) -> (events: [TokenEvent], status: SyncFolderStatus) {
        guard let syncFolder else {
            return ([], .disabled)
        }

        let store = TokenSyncLedgerStore(
            folder: syncFolder,
            localDevice: localDevice,
            fileManager: fileManager,
            cacheStore: cacheStore
        )
        return store.synchronize(
            localEvents: localEvents,
            replaceLocalLedger: replaceSyncLedger,
            importedAfter: importedAfter,
            isCancelled: isCancelled
        )
    }

    private func deduplicated(events: [TokenEvent]) -> [TokenEvent] {
        var eventsByKey: [String: TokenEvent] = [:]
        for event in events {
            let key = "\(event.deviceId)|\(event.id)"
            if let existing = eventsByKey[key] {
                if eventHasLocalDetails(event) || !eventHasLocalDetails(existing) {
                    eventsByKey[key] = event
                }
            } else {
                eventsByKey[key] = event
            }
        }
        return eventsByKey.values.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }
    }

    private func eventHasLocalDetails(_ event: TokenEvent) -> Bool {
        !event.rawFilePath.hasPrefix("sync://")
    }
}
