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
        cacheStore: TokenEventCacheStore? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.localDevice = localDevice
        self.cacheStore = cacheStore ?? Self.defaultCacheStore(for: homeDirectory, fileManager: fileManager)
    }

    public func scan(
        modifiedAfter: Date? = nil,
        eventAfter: Date? = nil,
        syncFolder: URL? = nil,
        replaceSyncLedger: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> ScanResult {
        guard !isCancelled() else { return ScanResult() }
        let requiresLocalLogRebuild = (try? cacheStore?.requiresLocalLogRebuild()) ?? false
        let requiresLocalLedgerRewrite: Bool
        if let syncFolder {
            requiresLocalLedgerRewrite = TokenSyncLedgerStore(
                folder: syncFolder,
                localDevice: localDevice,
                fileManager: fileManager,
                cacheStore: cacheStore
            ).requiresLocalLedgerRewrite()
        } else {
            requiresLocalLedgerRewrite = false
        }
        let requiresFullRebuild = requiresLocalLogRebuild || requiresLocalLedgerRewrite
        let effectiveModifiedAfter = requiresFullRebuild ? nil : modifiedAfter
        let effectiveEventAfter = requiresFullRebuild ? nil : (eventAfter ?? modifiedAfter)

        let rootScanResult = scanRoots(modifiedAfter: effectiveModifiedAfter, isCancelled: isCancelled)
        guard !isCancelled() else { return ScanResult() }
        var roots = rootScanResult.roots
        if rootScanResult.completed {
            cleanupMissingLocalCacheEntries(roots: roots)
        }
        var localEvents: [TokenEvent] = []

        for index in roots.indices {
            guard !isCancelled() else { return ScanResult() }
            let source = roots[index].source
            let files = roots[index].selectedFiles
            var parseErrors = roots[index].parseErrorCount
            for file in files {
                guard !isCancelled() else { return ScanResult() }
                let result = cachedOrParsedEvents(for: file, isCancelled: isCancelled) {
                    switch source {
                    case .codex:
                        return try TokenLogParser.parseCodexFile(at: file.url, startOffset: $0, isCancelled: isCancelled)
                    case .claude:
                        return try TokenLogParser.parseClaudeFile(at: file.url, startOffset: $0, isCancelled: isCancelled)
                    case .all:
                        return []
                    }
                }
                guard !isCancelled() else { return ScanResult() }
                switch result {
                case .success(let events):
                    localEvents.append(contentsOf: events)
                case .failure:
                    parseErrors += 1
                }
            }
            roots[index].parseErrorCount = parseErrors
        }

        guard !isCancelled() else { return ScanResult() }
        let hermesOutcome = HermesTokenScanner(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            localDevice: localDevice,
            cacheStore: cacheStore
        ).scan(isCancelled: isCancelled)
        localEvents.append(contentsOf: hermesOutcome.events)

        guard !isCancelled() else { return ScanResult() }
        let syncOutcome = syncEvents(
            localEvents: localEventsForSync(freshEvents: localEvents, syncFolder: syncFolder),
            syncFolder: syncFolder,
            replaceSyncLedger: replaceSyncLedger || requiresFullRebuild,
            importedAfter: effectiveModifiedAfter,
            cacheStore: cacheStore,
            isCancelled: isCancelled
        )
        guard !isCancelled() else { return ScanResult() }
        let freshEvents = localEvents + syncOutcome.events
        let events: [TokenEvent]
        if let cachedEvents = cachedEvents(
            modifiedAfter: effectiveEventAfter,
            syncLedgerPaths: currentSyncLedgerPaths(in: syncFolder)
        ) {
            events = deduplicated(events: cachedEvents + freshEvents)
        } else {
            events = deduplicated(events: freshEvents)
        }
        let sourceStatuses = sourceStatuses(from: roots, events: events) + [
            hermesSourceStatus(outcome: hermesOutcome, events: events)
        ]
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

        return ScanResult(
            events: events,
            syncDevices: currentSyncDevices(in: syncFolder),
            codexFileCount: codexFileCount,
            claudeFileCount: claudeFileCount,
            parseErrorCount: parseErrors,
            sourceStatuses: sourceStatuses,
            syncStatus: syncOutcome.status,
            scannedAt: Date()
        )
    }

    public func cachedResult(eventAfter: Date? = nil, syncFolder: URL? = nil) -> ScanResult? {
        let syncLedgerPaths = currentSyncLedgerPaths(in: syncFolder)
        guard let events = cachedEvents(
            modifiedAfter: eventAfter,
            syncLedgerPaths: syncLedgerPaths
        ), !events.isEmpty else {
            return nil
        }
        let sourceStatuses = cachedSourceStatuses(from: events) + [cachedHermesSourceStatus(from: events)]
        let codexFileCount = sourceStatuses
            .filter { $0.source == .codex }
            .map(\.scannedFileCount)
            .reduce(0, +)
        let claudeFileCount = sourceStatuses
            .filter { $0.source == .claude }
            .map(\.scannedFileCount)
            .reduce(0, +)
        return ScanResult(
            events: events,
            syncDevices: currentSyncDevices(in: syncFolder),
            codexFileCount: codexFileCount,
            claudeFileCount: claudeFileCount,
            sourceStatuses: sourceStatuses,
            syncStatus: cachedSyncStatus(
                syncFolder: syncFolder,
                syncLedgerPaths: syncLedgerPaths,
                eventAfter: eventAfter
            ),
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

    private func cachedEvents(modifiedAfter: Date?, syncLedgerPaths: Set<String>?) -> [TokenEvent]? {
        try? cacheStore?.events(
            modifiedAfter: modifiedAfter,
            syncLedgerPaths: syncLedgerPaths
        )
    }

    private func currentSyncLedgerPaths(in syncFolder: URL?) -> Set<String>? {
        guard let syncFolder,
              fileManager.fileExists(atPath: syncFolder.path) else {
            return nil
        }

        let devicesURL = syncFolder.appendingPathComponent("devices", isDirectory: true)
        return Set(syncLedgerFileURLs(in: devicesURL).compactMap { url in
            TokenEventCacheStore.FileSnapshot.make(
                for: url,
                source: nil,
                deviceId: nil,
                fileManager: fileManager
            )?.path
        })
    }

    private func currentSyncDevices(in syncFolder: URL?) -> [TokenDeviceMetadata] {
        guard let syncFolder,
              fileManager.fileExists(atPath: syncFolder.path) else {
            return []
        }

        let devicesURL = syncFolder.appendingPathComponent("devices", isDirectory: true)
        var devicesById: [String: TokenDeviceMetadata] = [:]
        for url in syncLedgerFileURLs(in: devicesURL) {
            let fallbackId = url.deletingPathExtension().lastPathComponent
            let device = firstSyncDeviceRecord(in: url)
                ?? TokenDeviceMetadata(id: fallbackId, name: fallbackId)
            devicesById[device.id] = device
        }
        return devicesById.values.sorted {
            if $0.name != $1.name {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    private func firstSyncDeviceRecord(in url: URL) -> TokenDeviceMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1_024),
              !data.isEmpty else {
            return nil
        }

        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).prefix(16) {
            guard let record = try? decoder.decode(SyncDeviceRecord.self, from: Data(line)),
                  !record.deviceId.isEmpty else {
                continue
            }
            return TokenDeviceMetadata(id: record.deviceId, name: record.deviceName)
        }
        return nil
    }

    private func syncLedgerFileURLs(in devicesURL: URL) -> [URL] {
        guard fileManager.fileExists(atPath: devicesURL.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: devicesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls
            .filter(isRegularJSONLFile)
            .sorted { $0.path < $1.path }
    }

    private func scanRoots(
        modifiedAfter: Date?,
        isCancelled: () -> Bool
    ) -> (roots: [RootScan], completed: Bool) {
        var roots: [RootScan] = []
        var completed = true

        for root in codexRoots() + [claudeRoot()] {
            guard !isCancelled() else {
                completed = false
                break
            }
            let enumeration = jsonlFiles(under: root.url, source: root.source, isCancelled: isCancelled)
            completed = completed && enumeration.completed
            let allFiles = enumeration.files
            let selected = selectedFiles(allFiles, modifiedAfter: modifiedAfter)
            roots.append(RootScan(
                source: root.source,
                label: root.label,
                url: root.url,
                exists: fileManager.fileExists(atPath: root.url.path),
                totalFiles: allFiles.count,
                selectedFiles: selected,
                allFilePaths: allFiles.map(\.cachePath),
                parseErrorCount: enumeration.errorCount
            ))
        }

        return (roots, completed)
    }

    private func cleanupMissingLocalCacheEntries(roots: [RootScan]) {
        guard let cacheStore else { return }
        let paths = Set(roots.flatMap(\.allFilePaths))
        try? cacheStore.removeMissingOrigins(
            originKind: .localLog,
            keeping: paths,
            pruningSources: [.claude]
        )
    }

    private func cachedSyncStatus(
        syncFolder: URL?,
        syncLedgerPaths: Set<String>?,
        eventAfter: Date?
    ) -> SyncFolderStatus {
        guard let syncFolder else { return .disabled }
        let exists = fileManager.fileExists(atPath: syncFolder.path)
        guard exists else {
            return SyncFolderStatus(path: syncFolder.path, exists: false)
        }

        let paths = syncLedgerPaths ?? []
        let importedEventCount = (try? cacheStore?.eventRecordCount(
            originKind: .syncLedger,
            paths: paths,
            modifiedAfter: eventAfter
        )) ?? 0
        return SyncFolderStatus(
            path: syncFolder.path,
            exists: true,
            deviceFileCount: paths.count,
            importedEventCount: importedEventCount
        )
    }

    private func cachedSourceStatuses(from events: [TokenEvent]) -> [ScanSourceStatus] {
        (codexRoots() + [claudeRoot()]).map { root in
            let paths = cachedLocalPaths(from: events, under: root)
            return ScanSourceStatus(
                source: root.source,
                label: root.label,
                path: root.url.path,
                exists: fileManager.fileExists(atPath: root.url.path),
                totalFileCount: paths.count,
                scannedFileCount: paths.count,
                parseErrorCount: 0
            )
        }
    }

    private func hermesSourceStatus(outcome: HermesScanOutcome, events: [TokenEvent]) -> ScanSourceStatus {
        return ScanSourceStatus(
            source: .codex,
            label: "Hermes Agent",
            path: hermesDatabaseURL.path,
            exists: outcome.databaseExists,
            totalFileCount: outcome.databaseExists ? 1 : 0,
            scannedFileCount: outcome.databaseExists && outcome.parseErrorCount == 0 ? 1 : 0,
            parseErrorCount: outcome.parseErrorCount
        )
    }

    private func cachedHermesSourceStatus(from events: [TokenEvent]) -> ScanSourceStatus {
        let hasCachedEvents = events.contains(where: isHermesEvent)
        let databaseExists = fileManager.fileExists(atPath: hermesDatabaseURL.path)
        return ScanSourceStatus(
            source: .codex,
            label: "Hermes Agent",
            path: hermesDatabaseURL.path,
            exists: databaseExists,
            totalFileCount: databaseExists ? 1 : 0,
            scannedFileCount: hasCachedEvents ? 1 : 0
        )
    }

    private var hermesDatabaseURL: URL {
        homeDirectory.appendingPathComponent(".hermes/state.db")
    }

    private func isHermesEvent(_ event: TokenEvent) -> Bool {
        event.rawFilePath.hasPrefix("hermes://")
    }

    private func sourceStatuses(from roots: [RootScan], events: [TokenEvent]) -> [ScanSourceStatus] {
        roots.map { root in
            let contributingCachedFileCount = cachedLocalPaths(from: events, under: root.logRoot).count
            let scannedFileCount = max(root.selectedFiles.count, contributingCachedFileCount)
            return ScanSourceStatus(
                source: root.source,
                label: root.label,
                path: root.url.path,
                exists: root.exists,
                totalFileCount: max(root.totalFiles, scannedFileCount),
                scannedFileCount: scannedFileCount,
                parseErrorCount: root.parseErrorCount
            )
        }
    }

    private func cachedLocalPaths(from events: [TokenEvent], under root: LogRoot) -> Set<String> {
        Set(events.compactMap { event in
            guard event.source == root.source,
                  eventHasLocalDetails(event),
                  rawPath(event.rawFilePath, isUnder: root.url) else {
                return nil
            }
            return event.rawFilePath
        })
    }

    private func rawPath(_ path: String, isUnder root: URL) -> Bool {
        rootPathCandidates(for: root).contains { rootPath in
            path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    private func rootPathCandidates(for root: URL) -> Set<String> {
        var paths = Set([
            root.path,
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().path
        ])

        for path in Array(paths) {
            if path.hasPrefix("/var/") {
                paths.insert("/private" + path)
            } else if path.hasPrefix("/private/var/") {
                paths.insert(String(path.dropFirst("/private".count)))
            }
        }
        return paths
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

    private struct SyncDeviceRecord: Decodable {
        var deviceId: String
        var deviceName: String

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case deviceName = "device_name"
        }
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

        var logRoot: LogRoot {
            LogRoot(source: source, label: label, url: url)
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
        jsonlFileURLs(under: root, isCancelled: { false }).urls
    }

    private func jsonlFileURLs(
        under root: URL,
        isCancelled: () -> Bool
    ) -> (urls: [URL], completed: Bool) {
        guard fileManager.fileExists(atPath: root.path) else { return ([], true) }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], false)
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard !isCancelled() else { return (files, false) }
            if isRegularJSONLFile(url) {
                files.append(url)
            }
        }
        return (files, true)
    }

    private func isRegularJSONLFile(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func jsonlFiles(
        under root: URL,
        source: TokenSource,
        isCancelled: () -> Bool
    ) -> (files: [LogFile], completed: Bool, errorCount: Int) {
        guard fileManager.fileExists(atPath: root.path) else { return ([], true, 0) }
        guard isDirectory(root) else { return ([], false, 1) }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], false, 1)
        }

        var files: [LogFile] = []
        for case let url as URL in enumerator {
            guard !isCancelled() else { return (files, false, 0) }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            let snapshot = TokenEventCacheStore.FileSnapshot.make(
                for: url,
                source: source,
                deviceId: nil,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: modifiedAt
            )
            files.append(LogFile(
                url: url,
                cachePath: snapshot.path,
                source: source,
                size: snapshot.size,
                modificationDate: snapshot.modifiedAt
            ))
        }
        return (files, !isCancelled(), 0)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
        parse: (Int64) throws -> [TokenEvent]
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

        if let appended = appendCachedEventsIfPossible(for: snapshot, isCancelled: isCancelled, parse: parse) {
            return appended
        }

        do {
            let events = try parse(0).map { $0.withDevice(localDevice) }
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

    private func appendCachedEventsIfPossible(
        for snapshot: TokenEventCacheStore.FileSnapshot,
        isCancelled: () -> Bool,
        parse: (Int64) throws -> [TokenEvent]
    ) -> FileEventResult? {
        guard let cacheStore,
              let base = try? cacheStore.incrementalAppendBase(for: snapshot, originKind: .localLog) else {
            return nil
        }

        let baseSnapshot = TokenEventCacheStore.FileSnapshot(
            path: snapshot.path,
            source: snapshot.source,
            size: base.size,
            modifiedAt: base.modifiedAt,
            deviceId: snapshot.deviceId
        )
        guard case .events(let cachedEvents) = try? cacheStore.cachedEvents(for: baseSnapshot, originKind: .localLog) else {
            return nil
        }

        do {
            let newEvents = try parse(base.size).map { $0.withDevice(localDevice) }
            guard !isCancelled() else { return .success(cachedEvents) }
            let existingKeys = Set(cachedEvents.map { "\($0.deviceId)|\($0.id)" })
            let uniqueNewEvents = newEvents.filter { !existingKeys.contains("\($0.deviceId)|\($0.id)") }
            try? cacheStore.appendEvents(uniqueNewEvents, for: snapshot, originKind: .localLog)
            return .success(cachedEvents + uniqueNewEvents)
        } catch TokenLogParser.IncrementalParseError.requiresFullFile {
            return nil
        } catch {
            return nil
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

    private func localEventsForSync(freshEvents: [TokenEvent], syncFolder: URL?) -> [TokenEvent] {
        guard syncFolder != nil else { return freshEvents }
        guard let cachedLocalEvents = cachedEvents(modifiedAfter: nil, syncLedgerPaths: nil) else {
            return freshEvents
        }
        return deduplicated(events: cachedLocalEvents + freshEvents)
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

    private static func defaultCacheStore(for homeDirectory: URL, fileManager: FileManager) -> TokenEventCacheStore? {
        let requestedHome = homeDirectory.resolvingSymlinksInPath().path
        let defaultHome = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard requestedHome == defaultHome else { return nil }
        return TokenEventCacheStore.defaultStore(fileManager: fileManager)
    }
}
