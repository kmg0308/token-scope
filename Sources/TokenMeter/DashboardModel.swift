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
        case .last6Hours:
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
    @Published var selectedSection: DashboardSection = .all
    @Published var range: TimeRangePreset = .last24Hours
    @Published var bucketSelection: DashboardBucketSelection = .automatic
    @Published var projectFilter = "All Projects"
    @Published var modelFilter = "All Models"
    @Published var deviceFilter = DashboardModel.allDevicesFilterId
    @Published var syncFolderPath: String?
    @Published var isScanning = false
    @Published var errorMessage: String?

    let localDevice: TokenDeviceMetadata

    private static let allDevicesFilterId = "all-devices"
    private static let deviceIdKey = "tokenMeter.localDeviceId"
    private static let syncFolderPathKey = "tokenMeter.syncFolderPath"
    private static let postScrollRefreshDelayNanoseconds: UInt64 = 1_200_000_000

    private let defaults: UserDefaults
    private let scanner: TokenLogScanner
    private var scanTask: Task<Void, Never>?
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
    private var deviceOptionsCache: (revision: Int, syncFolderPath: String?, options: [DashboardDeviceOption])?

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
        } else {
            refresh()
        }
    }

    func refresh(restartInProgress: Bool = false, fullSync: Bool = false) {
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
        guard !isScrollActive else {
            refreshAfterScroll = true
            return
        }
        refreshRecentChanges()
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
        normalizeFilters()
        if needsDataExpansion(for: range) {
            refresh(restartInProgress: true)
        }
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
        let validBuckets = BucketInterval.dashboardCases(for: range)
        if case .concrete(let interval) = bucketSelection, !validBuckets.contains(interval) {
            bucketSelection = .automatic
        }
        if !projectOptions.contains(projectFilter) {
            projectFilter = "All Projects"
        }
        if !modelOptions.contains(modelFilter) {
            modelFilter = "All Models"
        }
        let availableDeviceOptions = deviceOptions
        if !availableDeviceOptions.contains(where: { $0.id == deviceFilter }) {
            deviceFilter = availableDeviceOptions.first?.id ?? Self.allDevicesFilterId
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
        let remoteDevices = Dictionary(grouping: scanResult.events, by: \.deviceId)
            .compactMap { deviceId, events -> DashboardDeviceOption? in
                guard deviceId != localDevice.id else { return nil }
                let name = events.last?.deviceName ?? deviceId
                return DashboardDeviceOption(id: deviceId, title: name, deviceId: deviceId)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        configuredOptions.append(contentsOf: remoteDevices)
        options = configuredOptions
        deviceOptionsCache = (eventRevision, syncFolderPath, options)
        return options
    }

    var deviceCount: Int {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: projectFilter, model: modelFilter)
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

    var filteredEvents: [TokenEvent] {
        filteredEvents(source: selectedSection.sourceFilter)
    }

    func filteredEvents(source: TokenSource) -> [TokenEvent] {
        cachedFilteredEvents(
            source: source,
            project: projectFilter,
            model: modelFilter
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
        let key = eventFilterKey(source: source, project: projectFilter, model: modelFilter)
        if let cached = totalUsageCache[key] {
            return cached
        }
        let usage = Aggregation.totalUsage(events: cachedFilteredEvents(source: source, project: projectFilter, model: modelFilter))
        totalUsageCache[key] = usage
        return usage
    }

    var previousFilteredEvents: [TokenEvent] {
        let interval = range.previousInterval(earliest: scanResult.events.first?.timestamp)
        return Aggregation.filter(
            events: scanResult.events,
            source: selectedSection.sourceFilter,
            interval: interval,
            project: projectFilter,
            model: modelFilter,
            deviceId: selectedDeviceId
        )
    }

    var previousTotalUsage: TokenUsage {
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: projectFilter, model: modelFilter)
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
        let filter = eventFilterKey(source: source, project: projectFilter, model: modelFilter)
        let key = BucketCacheKey(filter: filter, bucket: bucket)
        if let cached = bucketCache[key] {
            return cached
        }
        let buckets = Aggregation.buckets(
            events: cachedFilteredEvents(source: source, project: projectFilter, model: modelFilter),
            bucket: bucket
        )
        bucketCache[key] = buckets
        return buckets
    }

    var projectRows: [GroupedUsageRow] {
        let key = GroupedRowsCacheKey(
            filter: eventFilterKey(source: selectedSection.sourceFilter, project: projectFilter, model: modelFilter),
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
            filter: eventFilterKey(source: selectedSection.sourceFilter, project: projectFilter, model: modelFilter),
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
            filter: eventFilterKey(source: selectedSection.sourceFilter, project: projectFilter, model: modelFilter),
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
        let key = eventFilterKey(source: selectedSection.sourceFilter, project: projectFilter, model: modelFilter)
        if let cached = sessionCountCache[key] {
            return cached
        }
        let count = Set(filteredEvents.map(\.sessionId)).count
        sessionCountCache[key] = count
        return count
    }

    var projectOptions: [String] {
        ["All Projects"] + Set(optionEvents(project: nil, model: modelFilter).map(\.projectPath)).sorted()
    }

    var modelOptions: [String] {
        ["All Models"] + Set(optionEvents(project: projectFilter, model: nil).map(\.model)).sorted()
    }

    var todayUsage: TokenUsage {
        let events = Aggregation.filter(
            events: scanResult.events,
            source: .all,
            range: .today,
            project: nil,
            model: nil,
            deviceId: selectedDeviceId
        )
        return Aggregation.totalUsage(events: events)
    }

    private func optionEvents(project: String?, model: String?) -> [TokenEvent] {
        cachedFilteredEvents(
            source: selectedSection.sourceFilter,
            project: project,
            model: model
        )
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
        deviceOptionsCache = nil
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
        case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last12Hours, .last24Hours, .last7Days, .last30Days:
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
}
