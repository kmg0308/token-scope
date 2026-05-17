import SwiftUI
import TokenMeterCore

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var updates: UpdateModel
    @State private var showingFilters = false
    @State private var showingDetails = false
    @AppStorage("showFullTokenNumbers") private var showFullTokenNumbers = false

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(TokenMeterTheme.subtleBorder)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if updates.updateLabel != nil {
                        UpdateAvailableBanner()
                    }

                    mainSummary

                    if let notice = dashboardNotice {
                        DashboardNoticeView(notice: notice)
                    }

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

                    dataSourcesBlock

                    dataFooter
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
        }
        .foregroundStyle(TokenMeterTheme.primaryText)
        .background {
            LinearGradient(
                colors: [TokenMeterTheme.backgroundTop, TokenMeterTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $updates.isSheetPresented) {
            UpdateSheetView()
                .environmentObject(updates)
        }
        .onReceive(refreshTimer) { _ in
            model.refresh()
        }
        .onChange(of: model.range) { _ in
            model.normalizeFilters()
            model.refresh(restartInProgress: true)
        }
        .onChange(of: model.selectedSection) { _ in
            model.normalizeFilters()
        }
        .task {
            updates.startAutoChecks()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TokenMeterTheme.elevatedSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(TokenMeterTheme.border, lineWidth: 1)
                        }
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TokenMeterTheme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenMeter")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(TokenMeterTheme.primaryText)
                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                }
            }

            Spacer()

            SectionSelector(selection: $model.selectedSection)
                .frame(width: 372)

            Button {
                model.refresh(restartInProgress: true)
            } label: {
                if model.isScanning {
                    ProgressView().scaleEffect(0.58)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh")
            .buttonStyle(TokenIconButtonStyle())

            Button {
                updates.isSheetPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: updates.updateLabel == nil ? "arrow.down.circle" : "arrow.down.circle.fill")
                    Text(updates.updateLabel == nil ? "Updates" : "Update")
                }
            }
            .buttonStyle(TokenPillButtonStyle(prominent: updates.updateLabel != nil))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
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
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.range.rawValue)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(TokenMeterTheme.control)
                }

                Spacer()

                Button {
                    showFullTokenNumbers.toggle()
                } label: {
                    Image(systemName: showFullTokenNumbers ? "number.circle.fill" : "number.circle")
                }
                .buttonStyle(TokenCompactIconButtonStyle(selected: showFullTokenNumbers))
                .help("Show exact token counts with separators")

                if model.isScanning {
                    HStack(spacing: 7) {
                        ProgressView()
                            .scaleEffect(0.58)
                        Text("Scanning")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(TokenFormatters.tokens(usage.total, format: numberFormat))
                    .font(.system(size: showFullTokenNumbers ? 44 : 56, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .foregroundStyle(TokenMeterTheme.primaryText)
                Text("tokens")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
            }

            summaryLine
            comparisonLine
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tokenSurface(elevated: true)
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
        .foregroundStyle(TokenMeterTheme.secondaryText)
    }

    private var comparisonLine: some View {
        HStack(spacing: 18) {
            inlineMetric(
                "Previous",
                TokenFormatters.tokens(model.previousTotalUsage.total, format: numberFormat)
            )
            inlineMetric("Change", comparisonText, color: comparisonColor)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(TokenMeterTheme.secondaryText)
        .help("Compared with the previous matching time period")
    }

    private var comparisonText: String {
        let current = model.totalUsage.total
        let previous = model.previousTotalUsage.total
        let delta = current - previous

        if previous == 0 {
            if current == 0 {
                return "0%"
            }
            return "New"
        }

        let percentage = Double(delta) / Double(previous) * 100
        let sign = percentage > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.0f", percentage))%"
    }

    private var comparisonColor: Color? {
        let current = model.totalUsage.total
        let previous = model.previousTotalUsage.total
        if current > previous {
            return TokenMeterTheme.warning
        }
        if current < previous {
            return TokenMeterTheme.positive
        }
        return nil
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
                .foregroundStyle(TokenMeterTheme.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            Capsule(style: .continuous)
                .fill(TokenMeterTheme.control)
        }
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Text("Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.primaryText)
                Spacer()

                HStack(alignment: .center, spacing: 8) {
                    rangePicker
                    bucketPicker
                }
            }

            TokenBarChart(buckets: chartBuckets, range: model.range, bucketInterval: model.bucket, mode: chartMode, numberFormat: numberFormat)
                .frame(height: 280)
        }
    }

    private var rangePicker: some View {
        Menu {
            Section("Recent") {
                ForEach(recentRangePresets) { preset in
                    menuSelectionButton(preset.rawValue, isSelected: model.range == preset) {
                        model.range = preset
                    }
                }
            }

            Section("Days") {
                ForEach(dayRangePresets) { preset in
                    menuSelectionButton(preset.rawValue, isSelected: model.range == preset) {
                        model.range = preset
                    }
                }
            }

            Section("Months") {
                ForEach(monthRangePresets) { preset in
                    menuSelectionButton(preset.rawValue, isSelected: model.range == preset) {
                        model.range = preset
                    }
                }
            }
        } label: {
            TokenMenuLabel(icon: "calendar", title: model.range.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Time range")
    }

    private var bucketPicker: some View {
        Menu {
            Section("Recommended") {
                menuSelectionButton("Auto", isSelected: model.bucketSelection == .automatic) {
                    model.bucketSelection = .automatic
                }
            }

            Section("Minutes") {
                ForEach(minuteBucketIntervals) { interval in
                    menuSelectionButton(interval.displayName, isSelected: model.bucketSelection == .concrete(interval)) {
                        model.bucketSelection = .concrete(interval)
                    }
                }
            }

            Section("Larger") {
                ForEach(largerBucketIntervals) { interval in
                    menuSelectionButton(interval.displayName, isSelected: model.bucketSelection == .concrete(interval)) {
                        model.bucketSelection = .concrete(interval)
                    }
                }
            }
        } label: {
            TokenMenuLabel(icon: "chart.bar.xaxis", title: model.bucketSelection.displayName(for: model.range))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Chart grouping")
    }

    private var recentRangePresets: [TimeRangePreset] {
        [.last30Minutes, .last1Hour, .last3Hours, .last6Hours, .last12Hours, .last24Hours]
    }

    private var dayRangePresets: [TimeRangePreset] {
        [.today, .last7Days, .last30Days]
    }

    private var monthRangePresets: [TimeRangePreset] {
        [.last3Months, .last6Months, .last12Months]
    }

    private var minuteBucketIntervals: [BucketInterval] {
        [.minute, .fiveMinutes, .tenMinutes, .twentyMinutes, .thirtyMinutes]
    }

    private var largerBucketIntervals: [BucketInterval] {
        [.hour, .day, .week, .month]
    }

    @ViewBuilder
    private func menuSelectionButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var chartBuckets: [TimeBucket] {
        switch model.selectedSection {
        case .all:
            model.timeBuckets
        case .codex:
            Aggregation.buckets(events: model.filteredEvents(source: .codex), bucket: model.bucket)
        case .claude:
            Aggregation.buckets(events: model.filteredEvents(source: .claude), bucket: model.bucket)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.primaryText)

            ComponentBreakdown(usage: usage, source: model.selectedSection.sourceFilter, numberFormat: numberFormat)
        }
    }

    private var filters: some View {
        HStack(spacing: 18) {
            Menu {
                ForEach(model.projectOptions, id: \.self) { project in
                    menuSelectionButton(shortProject(project), isSelected: model.projectFilter == project) {
                        model.projectFilter = project
                        model.normalizeFilters()
                    }
                }
            } label: {
                TokenFilterMenuLabel(title: "Project", value: shortProject(model.projectFilter), width: 290)
            }
            .menuStyle(.borderlessButton)

            Menu {
                ForEach(model.modelOptions, id: \.self) { modelName in
                    menuSelectionButton(modelName, isSelected: model.modelFilter == modelName) {
                        model.modelFilter = modelName
                        model.normalizeFilters()
                    }
                }
            } label: {
                TokenFilterMenuLabel(title: "Model", value: model.modelFilter, width: 290)
            }
            .menuStyle(.borderlessButton)

            Spacer()
        }
        .padding(14)
        .tokenSurface()
    }

    private var details: some View {
        ResponsiveDetails(
            projectRows: model.projectRows,
            modelRows: model.modelRows,
            sessionRows: model.sessionRows,
            numberFormat: numberFormat
        )
    }

    private var dataSourcesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data Sources")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.primaryText)

            DataSourceStatusPanel(statuses: model.scanResult.sourceStatuses)
        }
    }

    private var dataFooter: some View {
        HStack(spacing: 14) {
            footerItem("Codex files", model.scanResult.codexFileCount)
            footerItem("Claude files", model.scanResult.claudeFileCount)
            footerItem("Events", model.scanResult.events.count)
            footerItem("Errors", model.scanResult.parseErrorCount)
            Spacer()
            Text("Scanned \(model.scanResult.scannedAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(TokenMeterTheme.tertiaryText)
        }
        .font(.system(size: 11))
        .padding(.top, 2)
    }

    private func footerItem(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(TokenMeterTheme.tertiaryText)
            Text(TokenFormatters.integer(value))
                .monospacedDigit()
                .foregroundStyle(TokenMeterTheme.secondaryText)
        }
    }

    private var dashboardNotice: DashboardNotice? {
        let totalFiles = model.scanResult.sourceStatuses.map(\.totalFileCount).reduce(0, +)
        let scannedFiles = model.scanResult.sourceStatuses.map(\.scannedFileCount).reduce(0, +)

        if model.isScanning && model.scanResult.events.isEmpty {
            return DashboardNotice(
                icon: "arrow.triangle.2.circlepath",
                title: "Scanning local logs",
                message: "TokenMeter is reading Codex and Claude Code JSONL files.",
                tint: TokenMeterTheme.accent
            )
        }

        if !model.isScanning && totalFiles == 0 {
            return DashboardNotice(
                icon: "folder.badge.questionmark",
                title: "No local token logs found",
                message: "No JSONL files were found in the Codex or Claude Code log folders.",
                tint: TokenMeterTheme.warning
            )
        }

        if !model.isScanning && scannedFiles > 0 && model.scanResult.events.isEmpty {
            return DashboardNotice(
                icon: "exclamationmark.triangle",
                title: "No usable token events found",
                message: model.scanResult.parseErrorCount > 0
                    ? "Some files could not be parsed, and no token usage records were found."
                    : "Files were found, but they did not contain recognized token usage records.",
                tint: TokenMeterTheme.warning
            )
        }

        if !model.isScanning && model.filteredEvents.isEmpty && !model.scanResult.events.isEmpty {
            return DashboardNotice(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching events",
                message: "The current section, time range, project, or model selection has no token events.",
                tint: TokenMeterTheme.secondaryText
            )
        }

        if model.scanResult.parseErrorCount > 0 {
            return DashboardNotice(
                icon: "exclamationmark.triangle",
                title: "Some files were skipped",
                message: "Displayed totals may be incomplete because \(model.scanResult.parseErrorCount) file(s) could not be parsed.",
                tint: TokenMeterTheme.warning
            )
        }

        return nil
    }
}

struct SectionSelector: View {
    @Binding var selection: DashboardSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashboardSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.black.opacity(0.88) : TokenMeterTheme.secondaryText)
                .background {
                    Capsule(style: .continuous)
                        .fill(selection == section ? TokenMeterTheme.primaryText : Color.clear)
                }
                .contentShape(Capsule(style: .continuous))
            }
        }
        .padding(3)
        .frame(height: TokenMeterTheme.buttonHeight)
        .background {
            Capsule(style: .continuous)
                .fill(TokenMeterTheme.control)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(TokenMeterTheme.border, lineWidth: 1)
        }
    }
}

struct UpdateAvailableBanner: View {
    @EnvironmentObject private var updates: UpdateModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.accent)
            Text(updates.statusText)
                .font(.system(size: 13))
                .foregroundStyle(TokenMeterTheme.primaryText)
            Spacer()
            Button(updateButtonTitle) {
                updates.updateNow()
            }
            .buttonStyle(TokenPillButtonStyle(prominent: true))
            .disabled(updates.isChecking || updates.isDownloading || updates.isInstalling)
            Button("Details") {
                updates.isSheetPresented = true
            }
            .buttonStyle(TokenPillButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .tokenSurface(elevated: true)
    }

    private var updateButtonTitle: String {
        if updates.isInstalling {
            return "Installing..."
        }
        if updates.isDownloading {
            return "Updating..."
        }
        return "Update Now"
    }
}

struct DashboardNotice {
    let icon: String
    let title: String
    let message: String
    let tint: Color
}

struct DashboardNoticeView: View {
    let notice: DashboardNotice

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: notice.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(notice.tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.primaryText)
                Text(notice.message)
                    .font(.system(size: 12))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .tokenSurface()
    }
}

struct DataSourceStatusPanel: View {
    let statuses: [ScanSourceStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if statuses.isEmpty {
                Text("Waiting for scan result")
                    .font(.system(size: 12))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ForEach(statuses) { status in
                    DataSourceStatusRow(status: status)
                    if status.id != statuses.last?.id {
                        Divider()
                    }
                }
            }
        }
        .tokenSurface()
    }
}

struct DataSourceStatusRow: View {
    let status: ScanSourceStatus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(sourceColor(status.source))
                        .frame(width: 7, height: 7)
                    Text(status.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TokenMeterTheme.primaryText)
                }

                Text(abbreviatedPath(status.path))
                    .font(.system(size: 11))
                    .foregroundStyle(TokenMeterTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status.path)
            }

            Spacer()

            HStack(spacing: 10) {
                statusPill("Scanned", status.scannedFileCount)
                statusPill("Total", status.totalFileCount)
                if status.parseErrorCount > 0 {
                    statusPill("Errors", status.parseErrorCount, tint: TokenMeterTheme.warning)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusIcon: String {
        if !status.exists {
            return "xmark.circle"
        }
        if status.parseErrorCount > 0 {
            return "exclamationmark.triangle"
        }
        if status.scannedFileCount > 0 {
            return "checkmark.circle"
        }
        return "minus.circle"
    }

    private var statusColor: Color {
        if !status.exists || status.parseErrorCount > 0 {
            return TokenMeterTheme.warning
        }
        if status.scannedFileCount > 0 {
            return TokenMeterTheme.positive
        }
        return TokenMeterTheme.tertiaryText
    }

    private func statusPill(_ title: String, _ value: Int, tint: Color = TokenMeterTheme.secondaryText) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(TokenMeterTheme.tertiaryText)
            Text(TokenFormatters.integer(value))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            Capsule(style: .continuous)
                .fill(TokenMeterTheme.control)
        }
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
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TokenMeterTheme.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(TokenMeterTheme.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: TokenMeterTheme.cardRadius, style: .continuous)
                        .stroke(TokenMeterTheme.subtleBorder, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: TokenMeterTheme.cardRadius, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .padding(.horizontal, 1)
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
                            .foregroundStyle(TokenMeterTheme.secondaryText)
                        Text(TokenFormatters.tokens(component.value, format: numberFormat))
                            .monospacedDigit()
                            .foregroundStyle(TokenMeterTheme.primaryText)
                    }
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .tokenSurface()
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
            .foregroundStyle(TokenMeterTheme.primaryText)
    }
}

func shortProject(_ path: String) -> String {
    if path == "All Projects" || path == "Unknown" {
        return path
    }
    return URL(fileURLWithPath: path).lastPathComponent
}

func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
