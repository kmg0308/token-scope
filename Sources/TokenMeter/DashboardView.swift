import AppKit
import SwiftUI
import TokenMeterCore

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var updates: UpdateModel
    @State private var showingSectionSelector = false
    @State private var showingFilters = false
    @State private var showingDetails = false
    @State private var showingSyncSettings = false
    @AppStorage("showFullTokenNumbers") private var showFullTokenNumbers = false

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private static let recentRangePresets: [TimeRangePreset] = [
        .last30Minutes,
        .last1Hour,
        .last3Hours,
        .last6Hours,
        .last8Hours,
        .last12Hours,
        .last24Hours
    ]
    private static let dayRangePresets: [TimeRangePreset] = [.today, .yesterday, .last7Days, .last30Days]
    private static let monthRangePresets: [TimeRangePreset] = [.last3Months, .last6Months, .last12Months]
    private static let minuteBucketIntervals: [BucketInterval] = [
        .minute,
        .fiveMinutes,
        .tenMinutes,
        .twentyMinutes,
        .thirtyMinutes
    ]
    private static let largerBucketIntervals: [BucketInterval] = [.hour, .day, .week, .month]

    var body: some View {
        VStack(spacing: 0) {
            header
            TokenSmoothScrollView(onScrollActivityChanged: model.scrollActivityChanged) {
                VStack(alignment: .leading, spacing: 18) {
                    CodexAccountUsagePanel(
                        usage: model.codexAccountUsage,
                        isLoading: model.isLoadingCodexAccountUsage,
                        errorMessage: model.codexAccountUsageError
                    )

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

                    syncSettingsSection

                    dataSourcesBlock

                    dataFooter
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 22)
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
        }
        .foregroundStyle(TokenMeterTheme.primaryText)
        .background {
            TokenLiquidBackdrop()
                .ignoresSafeArea()
        }
        .sheet(isPresented: $updates.isSheetPresented) {
            UpdateSheetView()
                .environmentObject(updates)
        }
        .onReceive(refreshTimer) { _ in
            model.refreshRecentChangesWhenIdle()
        }
        .task {
            updates.startAutoChecks()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    productIdentity
                        .fixedSize()
                    Spacer(minLength: 4)
                    headerActions
                        .fixedSize()
                }

                HStack(spacing: 10) {
                    productIdentity
                        .fixedSize()
                    Spacer(minLength: 4)
                    compactHeaderActions
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, showingSectionSelector ? 10 : 12)

            if showingSectionSelector {
                SectionSelector(selection: model.selectedSection) { section in
                    model.selectSection(section)
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showingSectionSelector = false
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(TokenMeterTheme.surface.opacity(0.88))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TokenMeterTheme.subtleBorder)
                .frame(height: 1)
        }
    }

    private var compactHeaderActions: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    showingSectionSelector.toggle()
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .accessibilityLabel(showingSectionSelector ? "Hide source filter" : "Show source filter")
            .help("\(model.selectedSection.rawValue) source filter")
            .buttonStyle(TokenIconButtonStyle())

            Button {
                model.refresh(restartInProgress: true)
            } label: {
                Image(systemName: model.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .accessibilityLabel("Refresh")
            .buttonStyle(TokenIconButtonStyle())

            Button {
                updates.isSheetPresented = true
            } label: {
                Image(systemName: updates.updateLabel == nil ? "arrow.down.circle" : "arrow.down.circle.fill")
            }
            .accessibilityLabel(updates.updateLabel == nil ? "Updates" : "Update available")
            .buttonStyle(TokenIconButtonStyle(prominent: updates.updateLabel != nil))
        }
        .fixedSize()
    }

    private var productIdentity: some View {
        HStack(spacing: 11) {
            ZStack {
                TokenControlChrome(cornerRadius: TokenMeterTheme.compactControlRadius)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.accent)
            }
            .frame(width: 32, height: 32)

            Text("TokenMeter")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.primaryText)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    showingSectionSelector.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.selectedSection.rawValue)
                    Image(systemName: showingSectionSelector ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .accessibilityLabel(showingSectionSelector ? "Hide source filter" : "Show source filter")
            .buttonStyle(TokenPillButtonStyle())

            Button {
                model.refresh(restartInProgress: true)
            } label: {
                if model.isScanning {
                    Image(systemName: "arrow.triangle.2.circlepath")
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .accessibilityLabel("Refresh")
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
    }

    private var numberFormat: TokenNumberFormat {
        showFullTokenNumbers ? .full : .compact
    }

    private var mainSummary: some View {
        let usage = model.totalUsage
        return VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    summaryContextControls
                    Spacer()
                    summaryActionControls
                }

                VStack(alignment: .leading, spacing: 8) {
                    summaryContextControls
                    summaryActionControls
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(TokenFormatters.tokens(usage.total, format: numberFormat))
                    .font(.system(size: showFullTokenNumbers ? 22 : 28, weight: .semibold))
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

    private var summaryContextControls: some View {
        HStack(spacing: 10) {
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
                TokenControlChrome(cornerRadius: TokenMeterTheme.compactControlRadius)
            }

            if model.isSyncConfigured {
                devicePicker
            }
        }
    }

    private var summaryActionControls: some View {
        HStack(spacing: 10) {
            Button {
                showFullTokenNumbers.toggle()
            } label: {
                Image(systemName: showFullTokenNumbers ? "number.circle.fill" : "number.circle")
            }
            .buttonStyle(TokenCompactIconButtonStyle(selected: showFullTokenNumbers))
            .accessibilityLabel("Show exact token counts with separators")

            if model.isScanning {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Scanning")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.secondaryText)
                .lineLimit(1)
            }
        }
    }

    private var summaryLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                summaryMetrics
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                summaryMetrics
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(TokenMeterTheme.secondaryText)
    }

    @ViewBuilder
    private var summaryMetrics: some View {
        switch model.selectedSection {
        case .all:
            inlineMetric(
                "Codex",
                TokenFormatters.tokens(model.totalUsage(source: .codex).total, format: numberFormat),
                color: sourceColor(.codex)
            )
            inlineMetric(
                "Claude Code",
                TokenFormatters.tokens(model.totalUsage(source: .claude).total, format: numberFormat),
                color: sourceColor(.claude)
            )
            inlineMetric("Sessions", TokenFormatters.integer(model.sessionCount))
        case .codex, .claude:
            inlineMetric("Sessions", TokenFormatters.integer(model.sessionCount))
        }
        if model.scanResult.syncStatus.isConfigured {
            inlineMetric("Devices", TokenFormatters.integer(model.deviceCount))
        }
    }

    private var comparisonLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                comparisonMetrics
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                comparisonMetrics
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(TokenMeterTheme.secondaryText)
    }

    @ViewBuilder
    private var comparisonMetrics: some View {
        inlineMetric(
            "Previous",
            TokenFormatters.tokens(model.previousTotalUsage.total, format: numberFormat)
        )
        inlineMetric("Change", comparisonText, color: comparisonColor)
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
            TokenControlChrome(cornerRadius: TokenMeterTheme.compactControlRadius)
        }
    }

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 14) {
                    usageTitle
                    Spacer()
                    chartControls
                }

                VStack(alignment: .leading, spacing: 8) {
                    usageTitle
                    chartControls
                }
            }

            TokenBarChart(buckets: chartBuckets, range: model.range, bucketInterval: model.bucket, mode: chartMode, numberFormat: numberFormat)
                .frame(height: 280)
        }
    }

    private var usageTitle: some View {
        Text("Usage")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TokenMeterTheme.primaryText)
    }

    private var chartControls: some View {
        HStack(alignment: .center, spacing: 8) {
            rangePicker
            bucketPicker
        }
    }

    private var rangePicker: some View {
        Menu {
            Section("Recent") {
                ForEach(Self.recentRangePresets) { preset in
                    menuSelectionButton(preset.rawValue, isSelected: model.range == preset) {
                        model.selectRange(preset)
                    }
                }
            }

            Section("Days") {
                ForEach(Self.dayRangePresets) { preset in
                    menuSelectionButton(preset.rawValue, isSelected: model.range == preset) {
                        model.selectRange(preset)
                    }
                }
            }

            Section("Months") {
                ForEach(Self.monthRangePresets) { preset in
                    menuSelectionButton(preset.rawValue, isSelected: model.range == preset) {
                        model.selectRange(preset)
                    }
                }
            }

            Section("History") {
                menuSelectionButton(TimeRangePreset.all.rawValue, isSelected: model.range == .all) {
                    model.selectRange(.all)
                }
            }
        } label: {
            TokenMenuLabel(icon: "calendar", title: model.range.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var bucketPicker: some View {
        Menu {
            Section("Recommended") {
                menuSelectionButton("Auto", isSelected: model.bucketSelection == .automatic) {
                    model.selectBucket(.automatic)
                }
            }

            Section("Minutes") {
                ForEach(Self.minuteBucketIntervals) { interval in
                    menuSelectionButton(interval.displayName, isSelected: model.bucketSelection == .concrete(interval)) {
                        model.selectBucket(.concrete(interval))
                    }
                }
            }

            Section("Larger") {
                ForEach(Self.largerBucketIntervals) { interval in
                    menuSelectionButton(interval.displayName, isSelected: model.bucketSelection == .concrete(interval)) {
                        model.selectBucket(.concrete(interval))
                    }
                }
            }
        } label: {
            TokenMenuLabel(icon: "chart.bar.xaxis", title: model.bucketSelection.displayName(for: model.range))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            model.timeBuckets(source: .codex)
        case .claude:
            model.timeBuckets(source: .claude)
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
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: 18)],
            alignment: .leading,
            spacing: 10
        ) {
            Menu {
                ForEach(model.projectOptions, id: \.self) { project in
                    menuSelectionButton(shortProject(project), isSelected: model.projectFilter == project) {
                        model.selectProject(project)
                    }
                }
            } label: {
                TokenFilterMenuLabel(title: "Project", value: shortProject(model.projectFilter), width: nil)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)

            Menu {
                ForEach(model.modelOptions, id: \.self) { modelName in
                    menuSelectionButton(modelName, isSelected: model.modelFilter == modelName) {
                        model.selectModel(modelName)
                    }
                }
            } label: {
                TokenFilterMenuLabel(title: "Model", value: model.modelFilter, width: nil)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .tokenSurface()
    }

    private var devicePicker: some View {
        Menu {
            ForEach(model.deviceOptions) { option in
                menuSelectionButton(option.title, isSelected: model.deviceFilter == option.id) {
                    model.selectDevice(option.id)
                }
            }
        } label: {
            TokenMenuLabel(icon: "desktopcomputer", title: model.selectedDeviceTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

            DataSourceStatusPanel(
                statuses: model.scanResult.sourceStatuses,
                hasEvents: !model.scanResult.events.isEmpty,
                isScanning: model.isScanning,
                cleanupStatusText: model.sessionCleanupStatusText,
                isCleaningSessions: model.isCleaningSessions,
                canCleanSessions: model.isSyncConfigured,
                previewCleanup: model.previewSessionCleanup,
                archiveOldSessions: model.archiveOldSessions
            )
        }
    }

    private var syncFolderBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync Folder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.primaryText)

            SyncFolderPanel(
                status: model.scanResult.syncStatus,
                configuredPath: model.syncFolderPath,
                canUseICloud: model.defaultICloudSyncFolderURL != nil,
                useICloud: model.useDefaultICloudSyncFolder,
                chooseFolder: chooseSyncFolder,
                turnOff: model.clearSyncFolder
            )
        }
    }

    private var dataFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                footerMetrics
                Spacer()
                scanTimestamp
            }

            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 6) {
                    footerMetrics
                }
                scanTimestamp
            }
        }
        .font(.system(size: 11))
        .padding(.top, 2)
    }

    @ViewBuilder
    private var footerMetrics: some View {
        footerItem("Codex files", model.scanResult.codexFileCount)
        footerItem("Claude files", model.scanResult.claudeFileCount)
        footerItem("Events", model.scanResult.events.count)
        if model.isSyncConfigured {
            footerItem("Devices", Set(model.scanResult.events.map(\.deviceId)).count)
        }
        footerItem("Errors", model.scanResult.parseErrorCount)
    }

    private var scanTimestamp: some View {
        Text("Scanned \(model.scanResult.scannedAt.formatted(date: .omitted, time: .shortened))")
            .foregroundStyle(TokenMeterTheme.tertiaryText)
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

        if let errorMessage = model.errorMessage {
            return DashboardNotice(
                icon: "exclamationmark.triangle",
                title: "Action failed",
                message: errorMessage,
                tint: TokenMeterTheme.warning
            )
        }

        if model.isScanning && model.scanResult.events.isEmpty {
            return DashboardNotice(
                icon: "arrow.triangle.2.circlepath",
                title: "Scanning local logs",
                message: "TokenMeter is reading Codex, Hermes Agent, and Claude Code usage data.",
                tint: TokenMeterTheme.accent
            )
        }

        if !model.isScanning && totalFiles == 0 && model.scanResult.events.isEmpty {
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
                message: noMatchingEventsMessage,
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

        if let exportError = model.scanResult.syncStatus.exportError {
            return DashboardNotice(
                icon: "exclamationmark.triangle",
                title: "Sync export failed",
                message: exportError,
                tint: TokenMeterTheme.warning
            )
        }

        if model.scanResult.syncStatus.parseErrorCount > 0 {
            return DashboardNotice(
                icon: "exclamationmark.triangle",
                title: "Some sync records were skipped",
                message: "\(model.scanResult.syncStatus.parseErrorCount) sync record(s) could not be read.",
                tint: TokenMeterTheme.warning
            )
        }

        return nil
    }

    private var noMatchingEventsMessage: String {
        if model.isSyncConfigured {
            return "The current section, time range, project, model, or device selection has no token events."
        }
        return "The current section, time range, project, or model selection has no token events."
    }

    @ViewBuilder
    private var syncSettingsSection: some View {
        if model.isSyncConfigured {
            syncFolderBlock
        } else {
            CollapsibleSection("Sync Folder", isExpanded: $showingSyncSettings) {
                syncFolderBlock
                    .padding(.top, 8)
            }
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose TokenMeter Sync Folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.setSyncFolder(url)
        }
    }
}
