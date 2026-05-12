import Foundation
import AppKit
import SwiftUI

@MainActor
final class UpdateModel: ObservableObject {
    @Published var availability: UpdateAvailability?
    @Published var statusText = "Ready to check for updates."
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadedFile: URL?
    @Published var downloadedFileIsInstallable = false

    var updateLabel: String? {
        guard let availability, availability.isAvailable else { return nil }
        return "Update \(availability.release.version)"
    }

    func checkIfConfigured(silent: Bool = false) {
        checkLatestRelease(silent: silent)
    }

    func checkLatestRelease(silent: Bool = false) {
        guard !isChecking, !isDownloading else { return }

        isChecking = true
        if !silent {
            statusText = "Checking latest release..."
        }
        Task {
            do {
                let result = try await UpdateService.checkLatestRelease()
                availability = result
                statusText = result.isAvailable
                    ? "Version \(result.release.version) is available."
                    : upToDateStatusText()
            } catch {
                statusText = error.localizedDescription
            }
            isChecking = false
        }
    }

    func updateNow() {
        if downloadedFileIsInstallable {
            installDownloadedUpdate()
            return
        }

        if let release = availability?.release, availability?.isAvailable == true {
            downloadAndInstall(release: release)
            return
        }

        checkAndInstallLatestRelease()
    }

    func installDownloadedUpdate() {
        do {
            guard let downloadedFile else { throw UpdateServiceError.noDownloadedFile }
            statusText = "Preparing to install update..."
            try UpdateService.installDownloadedAppArchive(downloadedFile)
            NSApp.terminate(nil)
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func checkAndInstallLatestRelease() {
        guard !isChecking, !isDownloading else { return }

        isChecking = true
        statusText = "Checking latest release..."
        Task {
            do {
                let result = try await UpdateService.checkLatestRelease()
                availability = result
                isChecking = false

                if result.isAvailable {
                    downloadAndInstall(release: result.release)
                } else {
                    statusText = upToDateStatusText()
                }
            } catch {
                statusText = error.localizedDescription
                isChecking = false
            }
        }
    }

    private func downloadAndInstall(release: ReleaseInfo) {
        guard !isDownloading else { return }
        isDownloading = true
        statusText = "Downloading version \(release.version)..."
        Task {
            do {
                downloadedFile = try await UpdateService.downloadRelease(release)
                downloadedFileIsInstallable = true
                statusText = "Installing version \(release.version)..."
                isDownloading = false
                installDownloadedUpdate()
            } catch {
                statusText = error.localizedDescription
                isDownloading = false
            }
        }
    }

    private func upToDateStatusText() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return "TokenMeter is up to date. Checked at \(formatter.string(from: Date()))."
    }
}
