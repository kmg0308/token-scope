import Foundation

public final class TokenLogScanner: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let localDevice: TokenDeviceMetadata

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        localDevice: TokenDeviceMetadata = .localFallback
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.localDevice = localDevice
    }

    public func scan(
        modifiedAfter: Date? = nil,
        syncFolder: URL? = nil,
        replaceSyncLedger: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> ScanResult {
        guard !isCancelled() else { return ScanResult() }
        var roots = scanRoots(modifiedAfter: modifiedAfter)
        var localEvents: [TokenEvent] = []

        for index in roots.indices {
            guard roots[index].source == .codex else { continue }
            let files = roots[index].selectedFiles
            var parseErrors = 0
            for file in files {
                guard !isCancelled() else { break }
                do {
                    let parsed = try TokenLogParser.parseCodexFile(at: file, isCancelled: isCancelled)
                    localEvents.append(contentsOf: parsed.map { $0.withDevice(localDevice) })
                } catch {
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
                do {
                    let parsed = try TokenLogParser.parseClaudeFile(at: file, isCancelled: isCancelled)
                    localEvents.append(contentsOf: parsed.map { $0.withDevice(localDevice) })
                } catch {
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
        codexRoots().flatMap { jsonlFiles(under: $0.url) }
    }

    public func findClaudeFiles() -> [URL] {
        jsonlFiles(under: claudeRoot().url)
    }

    private func scanRoots(modifiedAfter: Date?) -> [RootScan] {
        (codexRoots() + [claudeRoot()]).map { root in
            let allFiles = jsonlFiles(under: root.url)
            let selected = selectedFiles(allFiles, modifiedAfter: modifiedAfter)
            return RootScan(
                source: root.source,
                label: root.label,
                url: root.url,
                exists: fileManager.fileExists(atPath: root.url.path),
                totalFiles: allFiles.count,
                selectedFiles: selected
            )
        }
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
        var selectedFiles: [URL]
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

    private func jsonlFiles(under root: URL) -> [URL] {
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

    private func selectedFiles(_ files: [URL], modifiedAfter: Date?) -> [URL] {
        let filtered = files.filter { url in
            if let modifiedAfter {
                guard let date = modificationDate(url), date >= modifiedAfter else { return false }
            }
            return true
        }
        return filtered.sorted {
            (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast)
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func syncEvents(
        localEvents: [TokenEvent],
        syncFolder: URL?,
        replaceSyncLedger: Bool,
        importedAfter: Date?,
        isCancelled: () -> Bool
    ) -> (events: [TokenEvent], status: SyncFolderStatus) {
        guard let syncFolder else {
            return ([], .disabled)
        }

        let store = TokenSyncLedgerStore(
            folder: syncFolder,
            localDevice: localDevice,
            fileManager: fileManager
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
            eventsByKey["\(event.deviceId)|\(event.id)"] = event
        }
        return eventsByKey.values.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }
    }
}
