import SwiftUI

struct UpdateSheetView: View {
    @EnvironmentObject private var updates: UpdateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Updates")
                        .font(.system(size: 18, weight: .semibold))
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    versionColumn("Current", UpdateService.installedVersion())
                    Divider()
                    versionColumn("Available", availableVersionText)
                }

                Text(updates.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                if updates.isChecking || updates.isDownloading || updates.isInstalling {
                    ProgressView()
                        .scaleEffect(0.72)
                }
                Button("Check for Updates") {
                    updates.checkLatestRelease(silent: false)
                }
                .disabled(buttonsDisabled)

                Spacer()

                if updates.availability?.isAvailable == true || updates.downloadedFileIsInstallable {
                    Button("Install and Relaunch") {
                        updates.updateNow()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(buttonsDisabled)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            updates.checkIfConfigured(silent: true)
        }
    }

    private var statusTitle: String {
        if updates.isInstalling {
            return "Installing"
        }
        if updates.downloadedFileIsInstallable {
            return "Ready to install"
        }
        if updates.availability?.isAvailable == true {
            return "Update available"
        }
        if updates.availability != nil {
            return "Up to date"
        }
        return "Not checked"
    }

    private var availableVersionText: String {
        guard let availability = updates.availability else {
            return "Not checked"
        }
        return availability.isAvailable ? availability.release.version : "No update"
    }

    private var statusColor: Color {
        updates.availability?.isAvailable == true || updates.downloadedFileIsInstallable
            ? Color.primary
            : Color.secondary
    }

    private var buttonsDisabled: Bool {
        updates.isChecking || updates.isDownloading || updates.isInstalling
    }

    private func versionColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
