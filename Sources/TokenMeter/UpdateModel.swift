import Foundation
import AppKit
import SwiftUI
import TokenMeterCore

@MainActor
final class UpdateModel: ObservableObject {
    @Published var availability: UpdateAvailability?
    @Published var statusText = "Ready to check for updates."
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var isInstalling = false
    @Published var downloadedFile: URL?
    @Published var downloadedFileIsInstallable = false
    @Published var isSheetPresented = false
    private static let autoCheckIntervalNanoseconds: UInt64 = 21_600_000_000_000
    private var autoCheckTask: Task<Void, Never>?
    private var downloadedReleaseIdentity: String?
    private let statusTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    var updateLabel: String? {
        guard let availability, availability.isAvailable else { return nil }
        return "Update \(availability.release.version)"
    }

    deinit {
        autoCheckTask?.cancel()
    }

    func checkIfConfigured(silent: Bool = false) {
        checkLatestRelease(silent: silent)
    }

    func startAutoChecks() {
        guard autoCheckTask == nil else { return }

        autoCheckTask = Task { @MainActor [weak self] in
            self?.checkIfConfigured(silent: true)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoCheckIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                self?.checkIfConfigured(silent: true)
            }
        }
    }

    func checkLatestRelease(silent: Bool = false) {
        guard !isChecking, !isDownloading, !isInstalling else { return }

        isChecking = true
        if !silent {
            statusText = "Checking latest release..."
            isSheetPresented = true
        }
        Task {
            do {
                let result = try await UpdateService.checkLatestRelease()
                availability = result
                clearStaleDownloadedUpdate(for: result)
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
            guard !isInstalling else { return }
            guard let downloadedFile,
                  FileManager.default.fileExists(atPath: downloadedFile.path) else {
                clearDownloadedUpdate()
                throw UpdateServiceError.noDownloadedFile
            }
            isInstalling = true
            isSheetPresented = true
            statusText = "Installing and relaunching..."
            Task { @MainActor [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try UpdateService.installDownloadedAppArchive(downloadedFile)
                    }.value
                    NSApp.terminate(nil)
                } catch {
                    self?.statusText = error.localizedDescription
                    self?.isInstalling = false
                    self?.isSheetPresented = true
                }
            }
        } catch {
            statusText = error.localizedDescription
            isInstalling = false
            isSheetPresented = true
        }
    }

    private func checkAndInstallLatestRelease() {
        guard !isChecking, !isDownloading, !isInstalling else { return }

        isChecking = true
        statusText = "Checking latest release..."
        isSheetPresented = true
        Task {
            do {
                let result = try await UpdateService.checkLatestRelease()
                availability = result
                clearStaleDownloadedUpdate(for: result)
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
        guard !isDownloading, !isInstalling else { return }
        isDownloading = true
        isSheetPresented = true
        statusText = "Downloading version \(release.version)..."
        Task {
            do {
                downloadedFile = try await UpdateService.downloadRelease(release)
                downloadedFileIsInstallable = true
                downloadedReleaseIdentity = release.downloadIdentity
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
        "TokenMeter is up to date. Checked at \(statusTimeFormatter.string(from: Date()))."
    }

    private func clearStaleDownloadedUpdate(for availability: UpdateAvailability) {
        guard downloadedFileIsInstallable else { return }
        guard availability.isAvailable,
              downloadedReleaseIdentity == availability.release.downloadIdentity,
              let downloadedFile,
              FileManager.default.fileExists(atPath: downloadedFile.path) else {
            clearDownloadedUpdate()
            return
        }
    }

    private func clearDownloadedUpdate() {
        downloadedFile = nil
        downloadedFileIsInstallable = false
        downloadedReleaseIdentity = nil
    }
}
