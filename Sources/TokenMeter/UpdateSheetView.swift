import AppKit
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
                    versionColumn("Installed", UpdateService.installedVersion())
                    Divider()
                    versionColumn("Latest", latestVersion)
                }

                Text(updates.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text("Repository")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Text(updates.repositoryText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Link(destination: updates.repositoryURL) {
                        Image(systemName: "arrow.up.forward")
                    }
                    .buttonStyle(.borderless)
                    .help("Open GitHub")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                if let downloadedFile = updates.downloadedFile {
                    Button("Show File") {
                        NSWorkspace.shared.activateFileViewerSelecting([downloadedFile])
                    }
                }
                Spacer()
                if updates.isChecking || updates.isDownloading {
                    ProgressView()
                        .scaleEffect(0.72)
                }
                Button(primaryButtonTitle) {
                    runPrimaryAction()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryButtonDisabled)
            }
        }
        .padding(20)
        .onAppear {
            updates.checkIfConfigured(silent: true)
        }
    }

    private var latestVersion: String {
        updates.availability?.release.version ?? "Not checked"
    }

    private var statusTitle: String {
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

    private var statusColor: Color {
        updates.availability?.isAvailable == true || updates.downloadedFileIsInstallable
            ? Color.primary
            : Color.secondary
    }

    private var primaryButtonTitle: String {
        if updates.downloadedFileIsInstallable {
            return "Install and Relaunch"
        }
        if updates.isChecking {
            return "Checking..."
        }
        if updates.isDownloading {
            return "Updating..."
        }
        if updates.availability?.isAvailable == true {
            return "Update Now"
        }
        return "Check for Updates"
    }

    private var primaryButtonDisabled: Bool {
        updates.isChecking || updates.isDownloading
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

    private func runPrimaryAction() {
        if updates.downloadedFileIsInstallable {
            updates.installDownloadedUpdate()
        } else if updates.availability?.isAvailable == true {
            updates.updateNow()
        } else {
            updates.checkLatestRelease()
        }
    }
}
