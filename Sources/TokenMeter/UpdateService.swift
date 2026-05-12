import Foundation

struct GitHubRepository: Equatable {
    let owner: String
    let name: String

    var apiBase: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(name)")!
    }
}

struct ReleaseInfo: Equatable {
    let version: String
    let displayName: String
    let zipURL: URL
    let htmlURL: URL?
    let targetCommitish: String
}

struct UpdateAvailability: Equatable {
    let currentVersion: String
    let release: ReleaseInfo

    var isAvailable: Bool {
        let installedCommit = UpdateService.installedBuildCommit()
        if installedCommit != "dev",
           !release.targetCommitish.isEmpty,
           !release.targetCommitish.hasPrefix(installedCommit) {
            return true
        }
        return UpdateService.compareVersions(release.version, currentVersion) == .orderedDescending
    }
}

enum UpdateServiceError: LocalizedError {
    case invalidResponse
    case noDownloadURL
    case noDownloadedFile

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .noDownloadURL:
            "No downloadable ZIP was found."
        case .noDownloadedFile:
            "Download a release ZIP first."
        }
    }
}

enum UpdateService {
    static let repository = GitHubRepository(owner: "kmg0308", name: "token-scope")

    static func checkLatestRelease() async throws -> UpdateAvailability {
        let release = try await latestRelease(repository: repository)
        return UpdateAvailability(currentVersion: installedVersion(), release: release)
    }

    static func downloadRelease(_ release: ReleaseInfo) async throws -> URL {
        try await download(url: release.zipURL, suggestedName: "TokenMeter-\(release.version).zip")
    }

    static func installDownloadedAppArchive(_ zipURL: URL) throws {
        let targetApp = Bundle.main.bundleURL
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-update-\(UUID().uuidString).zsh")

        let script = """
        #!/bin/zsh
        set -euo pipefail
        ZIP=\(shellQuote(zipURL.path))
        TARGET=\(shellQuote(targetApp.path))
        WORK="$(/usr/bin/mktemp -d)"
        HELPER="$WORK/install-root.zsh"
        cleanup() {
            /bin/rm -rf "$WORK"
        }
        trap cleanup EXIT

        /usr/bin/ditto -x -k "$ZIP" "$WORK"
        NEW_APP="$(/usr/bin/find "$WORK" -maxdepth 3 -type d -name 'TokenMeter.app' | /usr/bin/head -n 1)"
        if [[ -z "$NEW_APP" ]]; then
            /bin/echo "TokenMeter.app was not found in archive." >&2
            exit 2
        fi

        /bin/cat > "$HELPER" <<'ROOTINSTALL'
        #!/bin/zsh
        set -euo pipefail
        TARGET="$1"
        NEW_APP="$2"
        /bin/rm -rf "$TARGET"
        /usr/bin/ditto "$NEW_APP" "$TARGET"
        ROOTINSTALL
        /bin/chmod 755 "$HELPER"

        quote() {
            /usr/bin/printf "%q" "$1"
        }

        /bin/sleep 1
        if [[ -w "$(/usr/bin/dirname "$TARGET")" && ( ! -e "$TARGET" || -w "$TARGET" ) ]]; then
            /bin/zsh "$HELPER" "$TARGET" "$NEW_APP"
        else
            COMMAND="/bin/zsh $(quote "$HELPER") $(quote "$TARGET") $(quote "$NEW_APP")"
            APPLE_COMMAND="${COMMAND//\\\\/\\\\\\\\}"
            APPLE_COMMAND="${APPLE_COMMAND//\\"/\\\\\\"}"
            /usr/bin/osascript <<OSA
        do shell script "$APPLE_COMMAND" with administrator privileges
        OSA
        fi

        /usr/bin/open "$TARGET"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    static func installedBuildCommit() -> String {
        Bundle.main.object(forInfoDictionaryKey: "TSBuildCommit") as? String ?? "dev"
    }

    static func installedVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a > b { return .orderedDescending }
            if a < b { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func latestRelease(repository: GitHubRepository) async throws -> ReleaseInfo {
        let url = repository.apiBase.appendingPathComponent("releases/latest")
        let object = try await jsonObject(from: url)
        guard let dict = object as? [String: Any],
              let assets = dict["assets"] as? [[String: Any]] else {
            throw UpdateServiceError.invalidResponse
        }

        let selected = releaseZipAsset(from: assets)

        guard let selected,
              let urlString = selected["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw UpdateServiceError.noDownloadURL
        }

        let tag = (dict["tag_name"] as? String) ?? (dict["name"] as? String) ?? "0.0.0"
        let displayName = (dict["name"] as? String) ?? tag
        let htmlURL = (dict["html_url"] as? String).flatMap(URL.init(string:))
        let targetCommitish = (dict["target_commitish"] as? String) ?? ""
        return ReleaseInfo(
            version: normalizedVersion(tag),
            displayName: displayName,
            zipURL: downloadURL,
            htmlURL: htmlURL,
            targetCommitish: targetCommitish
        )
    }

    private static func jsonObject(from url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("TokenMeter", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateServiceError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func releaseZipAsset(from assets: [[String: Any]]) -> [String: Any]? {
        assets.first { asset in
            assetName(asset) == "tokenmeter.zip"
        } ?? assets.first { asset in
            let name = assetName(asset)
            return name.hasPrefix("tokenmeter-") && name.hasSuffix(".zip")
        } ?? assets.first { asset in
            let name = assetName(asset)
            return name.hasSuffix(".zip") && name.contains("tokenmeter")
        } ?? assets.first { asset in
            assetName(asset).hasSuffix(".zip")
        }
    }

    private static func assetName(_ asset: [String: Any]) -> String {
        (asset["name"] as? String ?? "").lowercased()
    }

    private static func download(url: URL, suggestedName: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("TokenMeter", forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateServiceError.invalidResponse
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let destination = downloads.appendingPathComponent(suggestedName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: tempURL, to: destination)
        return destination
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func normalizedVersion(_ string: String) -> String {
        var version = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        return version
    }

    private static func versionParts(_ string: String) -> [Int] {
        normalizedVersion(string)
            .split { character in
                character == "." || character == "-" || character == "_"
            }
            .map { Int($0) ?? 0 }
    }
}
