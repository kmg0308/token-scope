import Foundation
import SwiftUI
import TokenMeterCore

struct DashboardDeviceOption: Identifiable, Hashable {
    var id: String
    var title: String
    var deviceId: String?
}

private struct EventFilterKey: Hashable {
    var revision: Int
    var source: TokenSource
    var range: TimeRangePreset
    var project: String?
    var model: String?
    var deviceId: String?
}

private struct BucketCacheKey: Hashable {
    var filter: EventFilterKey
    var bucket: BucketInterval
}

private enum GroupedRowsKind: Hashable {
    case project
    case model
    case session
}

private struct GroupedRowsCacheKey: Hashable {
    var filter: EventFilterKey
    var kind: GroupedRowsKind
}

private enum SessionCleanupWorkResult {
    case preview(CodexSessionCleanupPlan, ScanResult)
    case applied(CodexSessionCleanupResult, ScanResult)
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case all = "All"
    case codex = "Codex"
    case claude = "Claude Code"

    var id: String { rawValue }

    var sourceFilter: TokenSource {
        switch self {
        case .all: .all
        case .codex: .codex
        case .claude: .claude
        }
    }
}

enum DashboardBucketSelection: Hashable, Identifiable {
    case automatic
    case concrete(BucketInterval)

    var id: String {
        switch self {
        case .automatic:
            "automatic"
        case .concrete(let interval):
            interval.id
        }
    }

    func displayName(for range: TimeRangePreset) -> String {
        switch self {
        case .automatic:
            "Auto: \(resolved(for: range).displayName)"
        case .concrete(let interval):
            interval.displayName
        }
    }

    func resolved(for range: TimeRangePreset) -> BucketInterval {
        switch self {
        case .automatic:
            Self.automaticInterval(for: range)
        case .concrete(let interval):
            interval
        }
    }

    private static func automaticInterval(for range: TimeRangePreset) -> BucketInterval {
        switch range {
        case .last30Minutes, .last1Hour:
            .minute
        case .last3Hours:
            .fiveMinutes
        case .last6Hours, .last8Hours:
            .tenMinutes
        case .last12Hours:
            .twentyMinutes
        case .today, .yesterday, .last24Hours:
            .hour
        case .last7Days, .last30Days:
            .day
        case .last3Months, .last6Months:
            .week
        case .last12Months, .all:
            .month
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var scanResult = ScanResult()
    @Published private(set) var selectedSection: DashboardSection = .all
    @Published private(set) var range: TimeRangePreset = .last24Hours
    @Published private(set) var bucketSelection: DashboardBucketSelection = .automatic
    @Published private(set) var projectFilter = DashboardModel.allProjectsTitle
    @Published private(set) var modelFilter = DashboardModel.allModelsTitle
    @Published private(set) var deviceFilter = DashboardModel.allDevicesFilterId
    @Published var syncFolderPath: String?
    @Published var isScanning = false
    @Published var isCleaningSessions = false
    @Published private(set) var codexAccountUsage: CodexAccountUsage?
    @Published private(set) var isLoadingCodexAccountUsage = false
    @Published private(set) var codexAccountUsageError: String?
    @Published var sessionCleanupStatusText: String?
    @Published var errorMessage: String?

    let localDevice: TokenDeviceMetadata

    private static let allDevicesFilterId = "all-devices"
    private static let allProjectsTitle = "All Projects"
    private static let allModelsTitle = "All Models"
    private static let deviceIdKey = "tokenMeter.localDeviceId"
    private static let syncFolderPathKey = "tokenMeter.syncFolderPath"
    private static let postScrollRefreshDelayNanoseconds: UInt64 = 1_200_000_000

    private let defaults: UserDefaults
    private let scanner: TokenLogScanner
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var codexAccountUsageTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var scanCanDeferForScroll = false
    private var isScrollActive = false
    private var refreshAfterScroll = false
    private var deferredRefreshTask: Task<Void, Never>?
    private var loadedEventWindowStart: Date?
    private var hasLoadedAllEvents = false
    private var eventRevision = 0
    private var filteredEventsCache: [EventFilterKey: [TokenEvent]] = [:]
    private var totalUsageCache: [EventFilterKey: TokenUsage] = [:]
    private var previousUsageCache: [EventFilterKey: TokenUsage] = [:]
    private var bucketCache: [BucketCacheKey: [TimeBucket]] = [:]
    private var sessionCountCache: [EventFilterKey: Int] = [:]
    private var deviceCountCache: [EventFilterKey: Int] = [:]
    private var groupedRowsCache: [GroupedRowsCacheKey: [GroupedUsageRow]] = [:]
    private var projectOptionsCache: [EventFilterKey: [String]] = [:]
    private var modelOptionsCache: [EventFilterKey: [String]] = [:]
    private var deviceOptionsCache: (revision: Int, syncFolderPath: String?, options: [DashboardDeviceOption])?
    private var earliestEventTimestampCache: (revision: Int, timestamp: Date?)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let device = Self.loadLocalDevice(defaults: defaults)
        self.localDevice = device
        self.scanner = TokenLogScanner(localDevice: device)
        let storedSyncFolderPath = defaults.string(forKey: Self.syncFolderPathKey)
        self.syncFolderPath = storedSyncFolderPath
        self.deviceFilter = storedSyncFolderPath?.isEmpty == false ? Self.allDevicesFilterId : device.id
        if loadCachedDashboardResult() {
            refreshAfterScroll = true
            scheduleRefreshAfterScroll()
            refreshCodexAccountUsage()
        } else {
            refresh()
        }
    }

    func refresh(restartInProgress: Bool = false, fullSync: Bool = false) {
        refreshCodexAccountUsage()
        cancelDeferredRefresh()
        let windowStart = fullSync ? nil : scanWindowStart(for: range)
        startRefresh(
            fileModifiedAfter: windowStart,
            eventAfter: windowStart,
            restartInProgress: restartInProgress,
            replaceSyncLedger: fullSync,
            canDeferForScroll: false
        )
    }

    func refreshRecentChanges() {
        let eventAfter = hasLoadedAllEvents ? nil : (loadedEventWindowStart ?? scanWindowStart(for: range))
        startRefresh(
            fileModifiedAfter: recentScanWindowStart(),
            eventAfter: eventAfter,
            restartInProgress: false,
            replaceSyncLedger: false,
            canDeferForScroll: true
        )
    }

    func refreshRecentChangesWhenIdle() {
        refreshCodexAccountUsage()
        guard !isScrollActive else {
            refreshAfterScroll = true
            return
        }
        refreshRecentChanges()
    }

    func refreshCodexAccountUsage() {
        guard codexAccountUsageTask == nil else { return }

        isLoadingCodexAccountUsage = true
        let service = CodexAccountUsageService()
        codexAccountUsageTask = Task { @MainActor [weak self] in
            let result: Result<CodexAccountUsage, CodexAccountUsageError> = await Task.detached(priority: .utility) {
                do {
                    return .success(try service.fetch())
                } catch let error as CodexAccountUsageError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidResponse)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let usage):
                codexAccountUsage = usage
                codexAccountUsageError = nil
            case .failure(let error):
                codexAccountUsageError = error.localizedDescription
            }
            isLoadingCodexAccountUsage = false
            codexAccountUsageTask = nil
        }
    }

    func scrollActivityChanged(_ isActive: Bool) {
        guard isScrollActive != isActive else { return }
        isScrollActive = isActive

        if isActive {
            if deferredRefreshTask != nil {
                refreshAfterScroll = true
            }
            cancelDeferredRefresh()
            if deferInProgressRefreshForScroll() {
                refreshAfterScroll = true
            }
            return
        }

        if refreshAfterScroll {
            refreshAfterScroll = false
            scheduleRefreshAfterScroll()
        }
    }

    func deferInProgressRefreshForScroll() -> Bool {
        guard isScanning, scanCanDeferForScroll else { return false }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        scanCanDeferForScroll = false
        isScanning = false
        return true
    }

    func rangeDidChange() {
        if needsDataExpansion(for: range) {
            normalizeBucketSelection()
            refresh(restartInProgress: true)
        } else {
            normalizeFilters()
        }
    }

    func selectSection(_ section: DashboardSection) {
        guard selectedSection != section else { return }
        selectedSection = section
        normalizeFilters()
    }

    func selectRange(_ newRange: TimeRangePreset) {
        guard range != newRange else { return }
        range = newRange
        rangeDidChange()
    }

    func selectBucket(_ selection: DashboardBucketSelection) {
        guard bucketSelection != selection else { return }
        bucketSelection = selection
        normalizeBucketSelection()
    }

    func selectProject(_ project: String) {
        guard projectFilter != project else { return }
        projectFilter = project
        normalizeFilters()
    }

    func selectModel(_ model: String) {
        guard modelFilter != model else { return }
        modelFilter = model
        normalizeFilters()
    }

    func selectDevice(_ deviceId: String) {
        guard deviceFilter != deviceId else { return }
        deviceFilter = deviceId
        normalizeFilters()
    }

    private func startRefresh(
        fileModifiedAfter: Date?,
        eventAfter: Date?,
        restartInProgress: Bool,
        replaceSyncLedger: Bool,
        canDeferForScroll: Bool
    ) {
        if isScanning {
            guard restartInProgress else { return }
            scanTask?.cancel()
        }

        scanGeneration += 1
        let generation = scanGeneration
        let scanner = scanner
        isScanning = true
        scanCanDeferForScroll = canDeferForScroll
        errorMessage = nil
        let syncFolderURL = syncFolderURL

        scanTask = Task(priority: .background) { @MainActor [weak self] in
            let worker = Task.detached(priority: .background) {
                scanner.scan(
                    modifiedAfter: fileModifiedAfter,
                    eventAfter: eventAfter,
                    syncFolder: syncFolderURL,
                    replaceSyncLedger: replaceSyncLedger,
                    isCancelled: { Task.isCancelled }
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, generation == self.scanGeneration else { return }
            scanResult = result
            markEventsChanged()
            markLoadedWindow(eventAfter: eventAfter)
            normalizeFilters()
            isScanning = false
            scanCanDeferForScroll = false
            scanTask = nil
        }
    }

    func normalizeFilters() {
        normalizeBucketSelection()
        let availableDeviceOptions = deviceOptions
        if !availableDeviceOptions.contains(where: { $0.id == deviceFilter }) {
            deviceFilter = availableDeviceOptions.first?.id ?? Self.allDevicesFilterId
        }
        let normalized = Aggregation.normalizedFilters(
            events: scanResult.events,
            source: selectedSection.sourceFilter,
            range: range,
            project: selectedProjectFilter,
            model: selectedModelFilter,
            deviceId: selectedDeviceId
        )
        if normalized.project != selectedProjectFilter {
            projectFilter = normalized.project ?? Self.allProjectsTitle
        }
        if normalized.model != selectedModelFilter {
            modelFilter = normalized.model ?? Self.allModelsTitle
        }
    }

    private func normalizeBucketSelection() {
        let validBuckets = BucketInterval.dashboardCases(for: range)
        if case .concrete(let interval) = bucketSelection, !validBuckets.contains(interval) {
            bucketSelection = .automatic
        }
    }

    var bucket: BucketInterval {
        bucketSelection.resolved(for: range)
    }

    var syncFolderURL: URL? {
        guard let syncFolderPath, !syncFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: syncFolderPath)
    }

    var isSyncConfigured: Bool {
        syncFolderURL != nil
    }

    var defaultICloudSyncFolderURL: URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        return root.appendingPathComponent("TokenMeter", isDirectory: true)
    }

    var selectedDeviceId: String? {
        deviceOptions.first { $0.id == deviceFilter }?.deviceId
    }

    var selectedDeviceTitle: String {
        deviceOptions.first { $0.id == deviceFilter }?.title ?? deviceOptions.first?.title ?? "This Mac"
    }

    var deviceOptions: [DashboardDeviceOption] {
        if let cached = deviceOptionsCache,
           cached.revision == eventRevision,
           cached.syncFolderPath == syncFolderPath {
            return cached.options
        }

        let options: [DashboardDeviceOption]
        guard isSyncConfigured else {
            options = [
                DashboardDeviceOption(id: localDevice.id, title: "This Mac", deviceId: localDevice.id)
            ]
            deviceOptionsCache = (eventRevision, syncFolderPath, options)
            return options
        }

        var configuredOptions = [
            DashboardDeviceOption(id: Self.allDevicesFilterId, title: "All Devices", deviceId: nil),
            DashboardDeviceOption(id: localDevice.id, title: "This Mac", deviceId: localDevice.id)
        ]
        var remoteDevicesById = Dictionary(
            uniqueKeysWithValues: scanResult.syncDevices
                .filter { $0.id != localDevice.id }
                .map { ($0.id, $0.name) }
        )
        for (deviceId, events) in Dictionary(grouping: scanResult.events, by: \.deviceId) {
            guard deviceId != localDevice.id else { continue }
            remoteDevicesById[deviceId] = events.last?.deviceName ?? remoteDevicesById[deviceId] ?? deviceId
        }
        let remoteDevices = remoteDevicesById.map { deviceId, name in
            DashboardDeviceOption(id: deviceId, title: name, deviceId: deviceId)
        }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        configuredOptions.append(contentsOf: remoteDevices)
        options = configuredOptions
        deviceOptionsCache = (eventRevision, syncFolderPath, options)
        return options
    }

    var deviceCount: Int {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: selectedModelFilter)
        if let cached = deviceCountCache[key] {
            return cached
        }
        let count = Set(filteredEvents.map(\.deviceId)).count
        deviceCountCache[key] = count
        return count
    }

    func useDefaultICloudSyncFolder() {
        guard let url = defaultICloudSyncFolderURL else {
            errorMessage = "iCloud Drive folder was not found on this Mac."
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            setSyncFolder(url)
        } catch {
            errorMessage = "Could not create the iCloud Drive sync folder: \(error.localizedDescription)"
        }
    }

    func setSyncFolder(_ url: URL) {
        defaults.set(url.path, forKey: Self.syncFolderPathKey)
        syncFolderPath = url.path
        deviceFilter = Self.allDevicesFilterId
        refresh(restartInProgress: true, fullSync: true)
    }

    func clearSyncFolder() {
        defaults.removeObject(forKey: Self.syncFolderPathKey)
        syncFolderPath = nil
        deviceFilter = localDevice.id
        refresh(restartInProgress: true)
    }

    func rebuildCache() {
        do {
            try scanner.clearCache()
            refresh(restartInProgress: true, fullSync: true)
        } catch {
            errorMessage = "Could not rebuild the token cache: \(error.localizedDescription)"
        }
    }

    func previewSessionCleanup() {
        startSessionCleanup(apply: false)
    }

    func archiveOldSessions() {
        startSessionCleanup(apply: true)
    }

    private func startSessionCleanup(apply: Bool) {
        guard let syncFolderURL else {
            errorMessage = "Choose a sync folder before cleaning old Codex sessions."
            return
        }
        guard !isCleaningSessions else { return }
        scanTask?.cancel()
        cleanupTask?.cancel()

        let scanner = scanner
        let actionName = apply ? "Archiving old Codex sessions" : "Checking old Codex sessions"
        isCleaningSessions = true
        isScanning = true
        scanCanDeferForScroll = false
        errorMessage = nil
        sessionCleanupStatusText = "\(actionName)..."

        cleanupTask = Task(priority: .background) { @MainActor [weak self] in
            let worker = Task.detached(priority: .background) {
                let refreshed = scanner.scan(syncFolder: syncFolderURL, replaceSyncLedger: true)
                let manager = CodexSessionCleanupManager()
                let plan = manager.plan(retentionDays: 90)
                if apply {
                    guard plan.canApply else {
                        return SessionCleanupWorkResult.preview(plan, refreshed)
                    }
                    let result = try manager.archiveAndRemove(plan)
                    let verified = scanner.scan(syncFolder: syncFolderURL, replaceSyncLedger: true)
                    return SessionCleanupWorkResult.applied(result, verified)
                }
                return SessionCleanupWorkResult.preview(plan, refreshed)
            }

            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled else { return }
                self.handleSessionCleanupResult(result)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = "Could not clean old Codex sessions: \(error.localizedDescription)"
            }

            guard let self else { return }
            self.isCleaningSessions = false
            self.isScanning = false
            self.scanCanDeferForScroll = false
            self.cleanupTask = nil
        }
    }

    private func handleSessionCleanupResult(_ result: SessionCleanupWorkResult) {
        switch result {
        case .preview(let plan, let scan):
            applyScanResult(scan, eventAfter: nil)
            sessionCleanupStatusText = cleanupPreviewText(plan)
        case .applied(let result, let scan):
            applyScanResult(scan, eventAfter: nil)
            sessionCleanupStatusText = "Archived \(result.removedFileCount) file(s), freed \(Self.byteText(result.removedByteCount))."
        }
    }

    private func cleanupPreviewText(_ plan: CodexSessionCleanupPlan) -> String {
        if plan.scannedFileCount == 0 {
            return "No Codex session files are older than \(plan.retentionDays) days."
        }
        if plan.eligibleFileCount == 0 {
            let blocked = plan.unsafeFileCount + plan.uncachedFileCount
            return "\(blocked) old file(s) are waiting for verified sync ledger records."
        }
        let ready = "\(plan.eligibleFileCount) old file(s), \(Self.byteText(plan.eligibleByteCount)) ready to archive."
        let blocked = plan.unsafeFileCount + plan.uncachedFileCount
        guard blocked > 0 else { return ready }
        return "\(ready) \(blocked) waiting."
    }

    private func applyScanResult(_ result: ScanResult, eventAfter: Date?) {
        scanResult = result
        markEventsChanged()
        markLoadedWindow(eventAfter: eventAfter)
        normalizeFilters()
    }

    var filteredEvents: [TokenEvent] {
        filteredEvents(source: selectedSection.sourceFilter)
    }

    func filteredEvents(source: TokenSource) -> [TokenEvent] {
        cachedFilteredEvents(
            source: source,
            project: selectedProjectFilter,
            model: selectedModelFilter
        )
    }

    private func cachedFilteredEvents(
        source: TokenSource,
        project: String?,
        model: String?
    ) -> [TokenEvent] {
        let key = eventFilterKey(source: source, project: project, model: model)
        if let cached = filteredEventsCache[key] {
            return cached
        }

        let events = Aggregation.filter(
            events: scanResult.events,
            source: source,
            range: range,
            project: project,
            model: model,
            deviceId: selectedDeviceId
        )
        filteredEventsCache[key] = events
        return events
    }

    private func eventFilterKey(source: TokenSource, project: String?, model: String?) -> EventFilterKey {
        EventFilterKey(
            revision: eventRevision,
            source: source,
            range: range,
            project: project,
            model: model,
            deviceId: selectedDeviceId
        )
    }

    var totalUsage: TokenUsage {
        totalUsage(source: selectedSection.sourceFilter)
    }

    func totalUsage(source: TokenSource) -> TokenUsage {
        let key = eventFilterKey(source: source, project: selectedProjectFilter, model: selectedModelFilter)
        if let cached = totalUsageCache[key] {
            return cached
        }
        let usage = Aggregation.totalUsage(events: cachedFilteredEvents(source: source, project: selectedProjectFilter, model: selectedModelFilter))
        totalUsageCache[key] = usage
        return usage
    }

    var previousFilteredEvents: [TokenEvent] {
        let interval = range.previousInterval(earliest: earliestEventTimestamp)
        return Aggregation.filter(
            events: scanResult.events,
            source: selectedSection.sourceFilter,
            interval: interval,
            project: selectedProjectFilter,
            model: selectedModelFilter,
            deviceId: selectedDeviceId
        )
    }

    var previousTotalUsage: TokenUsage {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: selectedModelFilter)
        if let cached = previousUsageCache[key] {
            return cached
        }
        let usage = Aggregation.totalUsage(events: previousFilteredEvents)
        previousUsageCache[key] = usage
        return usage
    }

    var timeBuckets: [TimeBucket] {
        timeBuckets(source: selectedSection.sourceFilter)
    }

    func timeBuckets(source: TokenSource) -> [TimeBucket] {
        let filter = eventFilterKey(source: source, project: selectedProjectFilter, model: selectedModelFilter)
        let key = BucketCacheKey(filter: filter, bucket: bucket)
        if let cached = bucketCache[key] {
            return cached
        }
        let buckets = Aggregation.buckets(
            events: cachedFilteredEvents(source: source, project: selectedProjectFilter, model: selectedModelFilter),
            bucket: bucket
        )
        bucketCache[key] = buckets
        return buckets
    }

    var projectRows: [GroupedUsageRow] {
        let key = GroupedRowsCacheKey(
            filter: eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: selectedModelFilter),
            kind: .project
        )
        if let cached = groupedRowsCache[key] {
            return cached
        }
        let rows = Array(Aggregation.grouped(events: filteredEvents, by: \.projectPath).prefix(12))
        groupedRowsCache[key] = rows
        return rows
    }

    var modelRows: [GroupedUsageRow] {
        let key = GroupedRowsCacheKey(
            filter: eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: selectedModelFilter),
            kind: .model
        )
        if let cached = groupedRowsCache[key] {
            return cached
        }
        let rows = Array(Aggregation.grouped(events: filteredEvents, by: \.model).prefix(12))
        groupedRowsCache[key] = rows
        return rows
    }

    var sessionRows: [GroupedUsageRow] {
        let key = GroupedRowsCacheKey(
            filter: eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: selectedModelFilter),
            kind: .session
        )
        if let cached = groupedRowsCache[key] {
            return cached
        }
        let rows = Array(Aggregation.grouped(events: filteredEvents, by: \.sessionId).prefix(20))
        groupedRowsCache[key] = rows
        return rows
    }

    var sessionCount: Int {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: selectedModelFilter)
        if let cached = sessionCountCache[key] {
            return cached
        }
        let count = Set(filteredEvents.map(\.sessionId)).count
        sessionCountCache[key] = count
        return count
    }

    var projectOptions: [String] {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: nil, model: selectedModelFilter)
        if let cached = projectOptionsCache[key] {
            return cached
        }
        let options = [Self.allProjectsTitle] + Set(optionEvents(project: nil, model: selectedModelFilter).map(\.projectPath)).sorted()
        projectOptionsCache[key] = options
        return options
    }

    var modelOptions: [String] {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: selectedProjectFilter, model: nil)
        if let cached = modelOptionsCache[key] {
            return cached
        }
        let options = [Self.allModelsTitle] + Set(optionEvents(project: selectedProjectFilter, model: nil).map(\.model)).sorted()
        modelOptionsCache[key] = options
        return options
    }

    private func optionEvents(project: String?, model: String?) -> [TokenEvent] {
        cachedFilteredEvents(
            source: selectedSection.sourceFilter,
            project: project,
            model: model
        )
    }

    private var selectedProjectFilter: String? {
        projectFilter == Self.allProjectsTitle ? nil : projectFilter
    }

    private var selectedModelFilter: String? {
        modelFilter == Self.allModelsTitle ? nil : modelFilter
    }

    private var earliestEventTimestamp: Date? {
        if let cached = earliestEventTimestampCache, cached.revision == eventRevision {
            return cached.timestamp
        }
        let timestamp = scanResult.events.lazy.map(\.timestamp).min()
        earliestEventTimestampCache = (eventRevision, timestamp)
        return timestamp
    }

    private func needsDataExpansion(for range: TimeRangePreset) -> Bool {
        guard !hasLoadedAllEvents else { return false }
        let requiredStart = scanWindowStart(for: range)
        guard let requiredStart else { return true }
        guard let loadedEventWindowStart else { return true }
        return requiredStart < loadedEventWindowStart
    }

    private func recentScanWindowStart() -> Date {
        TimeRangePreset.last24Hours.previousInterval().start
    }

    private func markEventsChanged() {
        eventRevision += 1
        filteredEventsCache.removeAll()
        totalUsageCache.removeAll()
        previousUsageCache.removeAll()
        bucketCache.removeAll()
        sessionCountCache.removeAll()
        deviceCountCache.removeAll()
        groupedRowsCache.removeAll()
        projectOptionsCache.removeAll()
        modelOptionsCache.removeAll()
        deviceOptionsCache = nil
        earliestEventTimestampCache = nil
    }

    private func markLoadedWindow(eventAfter: Date?) {
        guard let eventAfter else {
            hasLoadedAllEvents = true
            loadedEventWindowStart = nil
            return
        }
        guard !hasLoadedAllEvents else { return }
        loadedEventWindowStart = min(loadedEventWindowStart ?? eventAfter, eventAfter)
    }

    private func scheduleRefreshAfterScroll() {
        cancelDeferredRefresh()
        deferredRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.postScrollRefreshDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.deferredRefreshTask = nil
            guard !self.isScrollActive else {
                self.refreshAfterScroll = true
                return
            }
            self.refreshRecentChanges()
        }
    }

    private func cancelDeferredRefresh() {
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
    }

    private func loadCachedDashboardResult() -> Bool {
        let windowStart = scanWindowStart(for: range)
        guard let cachedResult = scanner.cachedResult(eventAfter: windowStart, syncFolder: syncFolderURL) else {
            return false
        }
        scanResult = cachedResult
        markEventsChanged()
        markLoadedWindow(eventAfter: windowStart)
        normalizeFilters()
        return true
    }

    private func scanWindowStart(for range: TimeRangePreset) -> Date? {
        switch range {
        case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last8Hours, .last12Hours, .last24Hours, .last7Days, .last30Days:
            return range.previousInterval().start
        case .last3Months, .last6Months, .last12Months:
            return range.previousInterval().start
        case .all:
            return nil
        }
    }

    private static func loadLocalDevice(defaults: UserDefaults) -> TokenDeviceMetadata {
        let id: String
        if let stored = defaults.string(forKey: deviceIdKey), !stored.isEmpty {
            id = stored
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: deviceIdKey)
        }

        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return TokenDeviceMetadata(id: id, name: name)
    }

    private static func byteText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
