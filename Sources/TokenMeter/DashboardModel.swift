import Foundation
import SwiftUI
import TokenMeterCore

struct DashboardDeviceOption: Identifiable, Hashable {
    var id: String
    var title: String
    var deviceId: String?
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

    private let defaults: UserDefaults
    private let scanner: TokenLogScanner
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let device = Self.loadLocalDevice(defaults: defaults)
        self.localDevice = device
        self.scanner = TokenLogScanner(localDevice: device)
        self.syncFolderPath = defaults.string(forKey: Self.syncFolderPathKey)
        refresh()
    }

    func refresh(restartInProgress: Bool = false, fullSync: Bool = false) {
        if isScanning {
            guard restartInProgress else { return }
            scanTask?.cancel()
        }

        scanGeneration += 1
        let generation = scanGeneration
        let scanner = scanner
        isScanning = true
        errorMessage = nil
        let windowStart = fullSync ? nil : scanWindowStart(for: range)
        let syncFolderURL = syncFolderURL

        scanTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                scanner.scan(
                    modifiedAfter: windowStart,
                    syncFolder: syncFolderURL,
                    replaceSyncLedger: fullSync,
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
            normalizeFilters()
            isScanning = false
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
        if !deviceOptions.contains(where: { $0.id == deviceFilter }) {
            deviceFilter = Self.allDevicesFilterId
        }
    }

    var bucket: BucketInterval {
        bucketSelection.resolved(for: range)
    }

    var syncFolderURL: URL? {
        guard let syncFolderPath, !syncFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: syncFolderPath)
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
        deviceOptions.first { $0.id == deviceFilter }?.title ?? "All Devices"
    }

    var deviceOptions: [DashboardDeviceOption] {
        var options = [
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
        options.append(contentsOf: remoteDevices)
        return options
    }

    var deviceCount: Int {
        Set(filteredEvents.map(\.deviceId)).count
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
        deviceFilter = Self.allDevicesFilterId
        refresh(restartInProgress: true)
    }

    var filteredEvents: [TokenEvent] {
        Aggregation.filter(
            events: scanResult.events,
            source: selectedSection.sourceFilter,
            range: range,
            project: projectFilter,
            model: modelFilter,
            deviceId: selectedDeviceId
        )
    }

    func filteredEvents(source: TokenSource) -> [TokenEvent] {
        Aggregation.filter(
            events: scanResult.events,
            source: source,
            range: range,
            project: projectFilter,
            model: modelFilter,
            deviceId: selectedDeviceId
        )
    }

    var totalUsage: TokenUsage {
        Aggregation.totalUsage(events: filteredEvents)
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
        Aggregation.totalUsage(events: previousFilteredEvents)
    }

    var timeBuckets: [TimeBucket] {
        Aggregation.buckets(events: filteredEvents, bucket: bucket)
    }

    var projectRows: [GroupedUsageRow] {
        Array(Aggregation.grouped(events: filteredEvents, by: \.projectPath).prefix(12))
    }

    var modelRows: [GroupedUsageRow] {
        Array(Aggregation.grouped(events: filteredEvents, by: \.model).prefix(12))
    }

    var sessionRows: [GroupedUsageRow] {
        Array(Aggregation.grouped(events: filteredEvents, by: \.sessionId).prefix(20))
    }

    var sessionCount: Int {
        Set(filteredEvents.map(\.sessionId)).count
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
        Aggregation.filter(
            events: scanResult.events,
            source: selectedSection.sourceFilter,
            range: range,
            project: project,
            model: model,
            deviceId: selectedDeviceId
        )
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
