import Foundation
import SwiftUI
import TokenMeterCore

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

@MainActor
final class DashboardModel: ObservableObject {
    @Published var scanResult = ScanResult()
    @Published var selectedSection: DashboardSection = .all
    @Published var range: TimeRangePreset = .last30Days
    @Published var bucket: BucketInterval = .day
    @Published var projectFilter = "All Projects"
    @Published var modelFilter = "All Models"
    @Published var isScanning = false
    @Published var errorMessage: String?

    private let scanner = TokenLogScanner()

    init() {
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        let windowStart = scanWindowStart(for: range)
        let maxFiles = maxFilesPerSource(for: range)
        let maxBytes = maxFileBytes(for: range)

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                self.scanner.scan(modifiedAfter: windowStart, maxFilesPerSource: maxFiles, maxFileBytes: maxBytes)
            }.value
            scanResult = result
            normalizeFilters()
            isScanning = false
        }
    }

    func normalizeFilters() {
        let validBuckets = BucketInterval.dashboardCases(for: range)
        if !validBuckets.contains(bucket) {
            bucket = validBuckets.first ?? .day
        }
        if !projectOptions.contains(projectFilter) {
            projectFilter = "All Projects"
        }
        if !modelOptions.contains(modelFilter) {
            modelFilter = "All Models"
        }
    }

    var filteredEvents: [TokenEvent] {
        Aggregation.filter(
            events: scanResult.events,
            source: selectedSection.sourceFilter,
            range: range,
            project: projectFilter,
            model: modelFilter
        )
    }

    func filteredEvents(source: TokenSource) -> [TokenEvent] {
        Aggregation.filter(
            events: scanResult.events,
            source: source,
            range: range,
            project: projectFilter,
            model: modelFilter
        )
    }

    var totalUsage: TokenUsage {
        Aggregation.totalUsage(events: filteredEvents)
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
        ["All Projects"] + Set(scanResult.events.map(\.projectPath)).sorted()
    }

    var modelOptions: [String] {
        ["All Models"] + Set(scanResult.events.map(\.model)).sorted()
    }

    var todayUsage: TokenUsage {
        let events = Aggregation.filter(
            events: scanResult.events,
            source: .all,
            range: .today,
            project: nil,
            model: nil
        )
        return Aggregation.totalUsage(events: events)
    }

    private func scanWindowStart(for range: TimeRangePreset) -> Date? {
        let interval = range.interval()
        switch range {
        case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last12Hours, .last24Hours, .last7Days, .last30Days:
            return interval.start
        case .last3Months, .last6Months, .last12Months:
            return interval.start
        case .all:
            return nil
        }
    }

    private func maxFilesPerSource(for range: TimeRangePreset) -> Int? {
        switch range {
        case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last12Hours, .last24Hours:
            return 40
        case .last7Days:
            return 120
        case .last30Days:
            return 240
        case .last3Months, .last6Months, .last12Months:
            return 500
        case .all:
            return 700
        }
    }

    private func maxFileBytes(for range: TimeRangePreset) -> Int? {
        switch range {
        case .today, .yesterday, .last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last12Hours, .last24Hours:
            return 25 * 1_024 * 1_024
        case .last7Days, .last30Days:
            return 50 * 1_024 * 1_024
        case .last3Months, .last6Months, .last12Months, .all:
            return 75 * 1_024 * 1_024
        }
    }
}
