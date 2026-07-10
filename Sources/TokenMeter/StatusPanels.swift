import SwiftUI
import TokenMeterCore

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

struct CodexAccountUsagePanel: View {
    let usage: CodexAccountUsage?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.accent)
                Text("Codex limits")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.primaryText)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text(usage == nil ? "Checking account" : "Refreshing")
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TokenMeterTheme.warning)
                    Text(usage == nil ? errorMessage : "Could not refresh")
                        .foregroundStyle(TokenMeterTheme.warning)
                        .lineLimit(1)
                        .help(errorMessage)
                } else if let fetchedAt = usage?.fetchedAt {
                    Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(TokenMeterTheme.tertiaryText)
                }
            }
            .font(.system(size: 11))

            HStack(alignment: .top, spacing: 0) {
                limitCell(title: "5 hour", window: usage?.fiveHourWindow)

                panelDivider

                limitCell(title: "7 day", window: usage?.sevenDayWindow)

                panelDivider

                resetCreditCell
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .tokenSurface()
    }

    private func limitCell(title: String, window: CodexRateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenMeterTheme.tertiaryText)

            if let window {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(window.remainingPercent)% left")
                        .font(.system(size: 21, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(TokenMeterTheme.primaryText)
                    Text("\(window.usedPercent)% used")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                }

                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(limitTint(for: window.remainingPercent))
                    .frame(maxWidth: 240)

                Text(resetText(window.resetsAt))
                    .font(.system(size: 11))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .lineLimit(1)
            } else {
                unavailableValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetCreditCell: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RESET CREDITS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(TokenMeterTheme.tertiaryText)

            if let credits = usage?.resetCredits {
                Text("\(credits.availableCount) available")
                    .font(.system(size: 21, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(TokenMeterTheme.primaryText)

                if credits.availableCount == 0 {
                    Text("No reset credits available")
                        .font(.system(size: 11))
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                } else if credits.expirations.isEmpty {
                    Text("Expiration details unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(
                            Array(credits.expirations.prefix(credits.availableCount).enumerated()),
                            id: \.offset
                        ) { index, expiration in
                            Text("Credit \(index + 1) \(expirationText(expiration))")
                                .lineLimit(1)
                        }

                        let missingExpirationCount = max(
                            0,
                            credits.availableCount - credits.expirations.count
                        )
                        if missingExpirationCount > 0 {
                            Text(
                                "\(missingExpirationCount) expiration "
                                    + (missingExpirationCount == 1 ? "is" : "dates are")
                                    + " unavailable"
                            )
                            .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                }
            } else {
                unavailableValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableValue: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("—")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.tertiaryText)
            Text(isLoading ? "Waiting for Codex" : "Not provided by Codex")
                .font(.system(size: 11))
                .foregroundStyle(TokenMeterTheme.secondaryText)
        }
    }

    private var panelDivider: some View {
        Divider()
            .padding(.horizontal, 18)
    }

    private func limitTint(for remainingPercent: Int) -> Color {
        if remainingPercent <= 10 {
            return TokenMeterTheme.warning
        }
        if remainingPercent <= 30 {
            return TokenMeterTheme.violet
        }
        return TokenMeterTheme.accent
    }

    private func resetText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Resets today at \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "Resets tomorrow at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Resets \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }

    private func expirationText(_ date: Date) -> String {
        "expires \(date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
    }
}

struct DataSourceStatusPanel: View {
    let statuses: [ScanSourceStatus]
    let hasEvents: Bool
    let isScanning: Bool
    let cleanupStatusText: String?
    let isCleaningSessions: Bool
    let canCleanSessions: Bool
    let previewCleanup: () -> Void
    let archiveOldSessions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if statuses.isEmpty {
                Text(emptyMessage)
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

            if canCleanSessions || cleanupStatusText != nil {
                Divider()
                cleanupActions
            }
        }
        .tokenSurface()
    }

    private var cleanupActions: some View {
        HStack(spacing: 10) {
            if let cleanupStatusText {
                Text(cleanupStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                previewCleanup()
            } label: {
                Label("Preview Cleanup", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(TokenPillButtonStyle())
            .disabled(!canCleanSessions || isScanning || isCleaningSessions)

            Button {
                archiveOldSessions()
            } label: {
                Label("Archive Old Sessions", systemImage: "archivebox")
            }
            .buttonStyle(TokenPillButtonStyle(prominent: true))
            .disabled(!canCleanSessions || isScanning || isCleaningSessions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyMessage: String {
        if hasEvents && isScanning {
            return "Refreshing source details"
        }
        if hasEvents {
            return "Source details are not available for cached data"
        }
        return "Waiting for scan result"
    }
}

struct SyncFolderPanel: View {
    let status: SyncFolderStatus
    let configuredPath: String?
    let canUseICloud: Bool
    let useICloud: () -> Void
    let chooseFolder: () -> Void
    let turnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(statusTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TokenMeterTheme.primaryText)
                        if let lastSyncedAt = status.lastSyncedAt {
                            Text("Synced \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11))
                                .foregroundStyle(TokenMeterTheme.tertiaryText)
                        }
                    }

                    Text(pathText)
                        .font(.system(size: 11))
                        .foregroundStyle(TokenMeterTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityValue(configuredPath ?? "")
                }

                Spacer()

                HStack(spacing: 8) {
                    if status.isConfigured {
                        syncPill("Files", status.deviceFileCount)
                        syncPill("Synced", status.importedEventCount)
                        syncPill("Exported", status.exportedEventCount)
                        if status.parseErrorCount > 0 {
                            syncPill("Errors", status.parseErrorCount, tint: TokenMeterTheme.warning)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button {
                    useICloud()
                } label: {
                    Label("Use iCloud Drive", systemImage: "icloud")
                }
                .buttonStyle(TokenPillButtonStyle())
                .disabled(!canUseICloud)

                Button {
                    chooseFolder()
                } label: {
                    Label(status.isConfigured ? "Change" : "Choose Folder", systemImage: "folder")
                }
                .buttonStyle(TokenPillButtonStyle())

                if status.isConfigured {
                    Button {
                        turnOff()
                    } label: {
                        Label("Turn Off", systemImage: "xmark.circle")
                    }
                    .buttonStyle(TokenPillButtonStyle())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .tokenSurface()
    }

    private var statusTitle: String {
        if !status.isConfigured {
            return "Off"
        }
        if !status.exists {
            return "Missing folder"
        }
        if status.exportError != nil || status.parseErrorCount > 0 {
            return "Needs attention"
        }
        return "Active"
    }

    private var pathText: String {
        guard let configuredPath, !configuredPath.isEmpty else {
            return "No folder selected"
        }
        return abbreviatedPath(configuredPath)
    }

    private var statusIcon: String {
        if !status.isConfigured {
            return "icloud.slash"
        }
        if !status.exists || status.exportError != nil || status.parseErrorCount > 0 {
            return "exclamationmark.triangle"
        }
        return "checkmark.icloud"
    }

    private var statusColor: Color {
        if !status.isConfigured {
            return TokenMeterTheme.tertiaryText
        }
        if !status.exists || status.exportError != nil || status.parseErrorCount > 0 {
            return TokenMeterTheme.warning
        }
        return TokenMeterTheme.positive
    }

    private func syncPill(_ title: String, _ value: Int, tint: Color = TokenMeterTheme.secondaryText) -> some View {
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
            TokenControlChrome(cornerRadius: TokenMeterTheme.compactControlRadius)
        }
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
                    .accessibilityValue(status.path)
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
            TokenControlChrome(cornerRadius: TokenMeterTheme.compactControlRadius)
        }
    }
}
