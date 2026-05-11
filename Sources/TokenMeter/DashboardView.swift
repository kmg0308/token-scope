import SwiftUI
import TokenMeterCore

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var updates: UpdateModel
    @State private var showingUpdates = false
    @State private var showingFilters = false
    @State private var showingDetails = false
    @AppStorage("showFullTokenNumbers") private var showFullTokenNumbers = false

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let updateCheckTimer = Timer.publish(every: 6 * 60 * 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if updates.updateLabel != nil {
                        UpdateAvailableBanner(showingUpdates: $showingUpdates)
                    }

                    mainSummary

                    chartBlock

                    breakdownBlock

                    CollapsibleSection("Filters", isExpanded: $showingFilters) {
                        filters
                            .padding(.top, 8)
                    }

                    CollapsibleSection("Details", isExpanded: $showingDetails) {
                        details
                            .padding(.top, 10)
                    }

                    dataFooter
                }
                .padding(22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingUpdates) {
            UpdateSheetView()
                .environmentObject(updates)
                .frame(width: 460)
        }
        .onReceive(refreshTimer) { _ in
            model.refresh()
        }
        .onReceive(updateCheckTimer) { _ in
            updates.checkIfConfigured(silent: true)
        }
        .onChange(of: model.range) { _ in
            model.normalizeFilters()
            model.refresh()
        }
        .task {
            updates.checkIfConfigured(silent: true)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenMeter")
                    .font(.system(size: 17, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("View", selection: $model.selectedSection) {
                ForEach(DashboardSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            Button {
                model.refresh()
            } label: {
                if model.isScanning {
                    ProgressView().scaleEffect(0.58)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh")
            .frame(width: 32)

            Button {
                showingUpdates = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: updates.updateLabel == nil ? "arrow.down.circle" : "arrow.down.circle.fill")
                    Text(updates.updateLabel == nil ? "Updates" : "Update")
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        switch model.selectedSection {
        case .all:
            "Combined local usage"
        case .codex:
            "Codex local sessions"
        case .claude:
            "Claude Code local sessions"
        }
    }

    private var numberFormat: TokenNumberFormat {
        showFullTokenNumbers ? .full : .compact
    }

    private var mainSummary: some View {
        let usage = model.totalUsage
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.range.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 9) {
                Text(TokenFormatters.tokens(usage.total, format: numberFormat))
                    .font(.system(size: showFullTokenNumbers ? 42 : 52, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            summaryLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryLine: some View {
        HStack(spacing: 18) {
            switch model.selectedSection {
            case .all:
                inlineMetric(
                    "Codex",
                    TokenFormatters.tokens(Aggregation.totalUsage(events: model.filteredEvents(source: .codex)).total, format: numberFormat),
                    color: sourceColor(.codex)
                )
                inlineMetric(
                    "Claude Code",
                    TokenFormatters.tokens(Aggregation.totalUsage(events: model.filteredEvents(source: .claude)).total, format: numberFormat),
                    color: sourceColor(.claude)
                )
                inlineMetric("Sessions", TokenFormatters.integer(model.sessionCount))
            case .codex, .claude:
                inlineMetric("Sessions", TokenFormatters.integer(model.sessionCount))
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func inlineMetric(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(title)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Text("Usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()

                HStack(alignment: .center, spacing: 8) {
                    Picker("Range", selection: $model.range) {
                        ForEach(TimeRangePreset.dashboardCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Picker("Bucket", selection: $model.bucket) {
                        ForEach(BucketInterval.dashboardCases(for: model.range)) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Toggle("Full numbers", isOn: $showFullTokenNumbers)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("Show exact token counts with separators")
                }
            }

            TokenBarChart(buckets: chartBuckets, range: model.range, bucketInterval: model.bucket, mode: chartMode, numberFormat: numberFormat)
                .frame(height: 280)
        }
    }

    private var chartBuckets: [TimeBucket] {
        switch model.selectedSection {
        case .all:
            model.timeBuckets
        case .codex:
            Aggregation.buckets(events: model.filteredEvents(source: .codex), range: model.range, bucket: model.bucket)
        case .claude:
            Aggregation.buckets(events: model.filteredEvents(source: .claude), range: model.range, bucket: model.bucket)
        }
    }

    private var chartMode: ChartMode {
        switch model.selectedSection {
        case .all:
            .bySource
        case .codex:
            .byTokenKind(.codex)
        case .claude:
            .byTokenKind(.claude)
        }
    }

    private var breakdownBlock: some View {
        let usage = model.totalUsage

        return VStack(alignment: .leading, spacing: 10) {
            Text("Breakdown")
                .font(.system(size: 13, weight: .semibold))

            ComponentBreakdown(usage: usage, source: model.selectedSection.sourceFilter, numberFormat: numberFormat)
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Project", selection: $model.projectFilter) {
                ForEach(model.projectOptions, id: \.self) { project in
                    Text(shortProject(project)).tag(project)
                }
            }
            .frame(width: 260)

            Picker("Model", selection: $model.modelFilter) {
                ForEach(model.modelOptions, id: \.self) { modelName in
                    Text(modelName).tag(modelName)
                }
            }
            .frame(width: 260)

            Spacer()
        }
    }

    private var details: some View {
        ResponsiveDetails(
            projectRows: model.projectRows,
            modelRows: model.modelRows,
            sessionRows: model.sessionRows,
            numberFormat: numberFormat
        )
    }

    private var dataFooter: some View {
        HStack(spacing: 14) {
            footerItem("Codex files", model.scanResult.codexFileCount)
            footerItem("Claude files", model.scanResult.claudeFileCount)
            footerItem("Events", model.scanResult.events.count)
            footerItem("Errors", model.scanResult.parseErrorCount)
            Spacer()
            Text("Scanned \(model.scanResult.scannedAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.top, 2)
    }

    private func footerItem(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(TokenFormatters.integer(value))
                .monospacedDigit()
        }
    }
}

struct UpdateAvailableBanner: View {
    @EnvironmentObject private var updates: UpdateModel
    @Binding var showingUpdates: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
            Text(updates.statusText)
                .font(.system(size: 13))
            Spacer()
            Button(updates.isDownloading ? "Updating..." : "Update Now") {
                updates.updateNow()
            }
            .disabled(updates.isChecking || updates.isDownloading)
            Button("Details") {
                showingUpdates = true
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}

struct ComponentBreakdown: View {
    let usage: TokenUsage
    let source: TokenSource
    let numberFormat: TokenNumberFormat

    var body: some View {
        let components = usage.displayComponents(source: source)
        let total = max(1, components.map(\.value).reduce(0, +))

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(components, id: \.kind) { component in
                        Rectangle()
                            .fill(componentColor(component.kind))
                            .frame(width: proxy.size.width * CGFloat(component.value) / CGFloat(total))
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            HStack(spacing: 16) {
                ForEach(components, id: \.kind) { component in
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(componentColor(component.kind))
                            .frame(width: 10, height: 8)
                        Text(component.kind.rawValue)
                            .foregroundStyle(.secondary)
                        Text(TokenFormatters.tokens(component.value, format: numberFormat))
                            .monospacedDigit()
                    }
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

func shortProject(_ path: String) -> String {
    if path == "All Projects" || path == "Unknown" {
        return path
    }
    return URL(fileURLWithPath: path).lastPathComponent
}
