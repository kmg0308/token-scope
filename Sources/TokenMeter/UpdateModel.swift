import Foundation
import AppKit
import SwiftUI

@MainActor
final class UpdateModel: ObservableObject {
    @Published var availability: UpdateAvailability?
    @Published var statusText = "Set a GitHub repository to enable update checks."
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadedFile: URL?
    @Published var downloadedFileIsInstallable = false

    var repositoryText: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "githubRepository") ?? ""
            if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
            return UpdateService.defaultRepositoryText()
        }
        set { UserDefaults.standard.set(newValue, forKey: "githubRepository") }
    }

    var hasRepository: Bool {
        UpdateService.parseRepository(repositoryText) != nil
    }

    var updateLabel: String? {
        guard let availability, availability.isAvailable else { return nil }
        return "Update \(availability.release.version)"
    }

    func checkIfConfigured(silent: Bool = false) {
        guard hasRepository else { return }
        checkLatestRelease(silent: silent)
    }

    func checkLatestRelease(silent: Bool = false) {
        guard !isChecking, !isDownloading else { return }
        guard let repository = UpdateService.parseRepository(repositoryText) else {
            statusText = "Set a valid GitHub repository first."
            availability = nil
            return
        }

        isChecking = true
        if !silent {
            statusText = "Checking latest release..."
        }
        Task {
            do {
                let result = try await UpdateService.checkLatestRelease(repository: repository)
                availability = result
                statusText = result.isAvailable
                    ? "Version \(result.release.version) is available."
                    : "TokenMeter is up to date."
            } catch {
                statusText = error.localizedDescription
            }
            isChecking = false
        }
    }

    func updateNow(repositoryText newRepositoryText: String? = nil) {
        if let newRepositoryText {
            repositoryText = newRepositoryText
        }

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
            try UpdateService.installDownloadedAppArchive(downloadedFile)
            NSApp.terminate(nil)
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func checkAndInstallLatestRelease() {
        guard !isChecking, !isDownloading else { return }
        guard let repository = UpdateService.parseRepository(repositoryText) else {
            statusText = "Set a valid GitHub repository first."
            availability = nil
            return
        }

        isChecking = true
        statusText = "Checking latest release..."
        Task {
            do {
                let result = try await UpdateService.checkLatestRelease(repository: repository)
                availability = result
                isChecking = false

                if result.isAvailable {
                    downloadAndInstall(release: result.release)
                } else {
                    statusText = "TokenMeter is up to date."
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
}
