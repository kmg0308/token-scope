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
    case notAnAppBundle

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid response."
        case .noDownloadURL:
            "No downloadable ZIP was found."
        case .noDownloadedFile:
            "Download a release ZIP first."
        case .notAnAppBundle:
            "Updates can only install into a packaged .app build."
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
        let targetApp = installTargetAppURL()
        guard targetApp.pathExtension == "app" else {
            throw UpdateServiceError.notAnAppBundle
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-update-\(UUID().uuidString).zsh")
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/zsh
        set -euo pipefail

        APP_PID=\(currentPID)
        ZIP=\(shellQuote(zipURL.path))
        TARGET=\(shellQuote(targetApp.path))
        SCRIPT=\(shellQuote(scriptURL.path))
        LOG_DIR="$HOME/Library/Logs/TokenMeter"
        LOG="$LOG_DIR/update.log"
        WORK="$(/usr/bin/mktemp -d)"
        HELPER="$WORK/install-root.zsh"
        TARGET_PARENT="$(/usr/bin/dirname "$TARGET")"
        TARGET_NAME="$(/usr/bin/basename "$TARGET")"
        TMP_TARGET="$TARGET.new.$$"
        OLD_TARGET="$TARGET.old.$$"

        /bin/mkdir -p "$LOG_DIR"
        exec >> "$LOG" 2>&1
        /bin/echo "[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting update for $TARGET from $ZIP"

        cleanup() {
            /bin/rm -rf "$WORK" "$TMP_TARGET"
            /bin/rm -f "$SCRIPT"
        }
        trap cleanup EXIT

        /usr/bin/find "$TARGET_PARENT" -maxdepth 1 \\( -name "$TARGET_NAME.new.*" -o -name "$TARGET_NAME.old.*" -o -name ".$TARGET_NAME.old.*" \\) -exec /bin/rm -rf {} + 2>/dev/null || true

        /usr/bin/ditto -x -k "$ZIP" "$WORK"
        NEW_APP="$(/usr/bin/find "$WORK" -maxdepth 3 -type d -name 'TokenMeter.app' | /usr/bin/head -n 1)"
        if [[ -z "$NEW_APP" ]]; then
            /bin/echo "TokenMeter.app was not found in archive." >&2
            exit 2
        fi

        /bin/rm -rf "$TMP_TARGET" "$OLD_TARGET"
        /usr/bin/ditto "$NEW_APP" "$TMP_TARGET"
        /usr/bin/xattr -cr "$TMP_TARGET" 2>/dev/null || true

        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$BUNDLE_ID" != "local.tokenmeter.app" || "$EXECUTABLE" != "TokenMeter" ]]; then
            /bin/echo "Downloaded app bundle identity is invalid: $BUNDLE_ID / $EXECUTABLE" >&2
            exit 5
        fi
        if [[ ! -x "$TMP_TARGET/Contents/MacOS/TokenMeter" ]]; then
            /bin/echo "Downloaded app executable is missing." >&2
            exit 6
        fi
        if ! /usr/bin/codesign --verify --deep --strict "$TMP_TARGET" >/dev/null 2>&1; then
            /bin/echo "Downloaded app code signature is invalid." >&2
            exit 7
        fi

        /bin/cat > "$HELPER" <<'ROOTINSTALL'
        #!/bin/zsh
        set -euo pipefail
        APP_PID="$1"
        TARGET="$2"
        TMP_TARGET="$3"
        OLD_TARGET="$4"
        TARGET_PARENT="$(/usr/bin/dirname "$TARGET")"
        TARGET_NAME="$(/usr/bin/basename "$TARGET")"

        if /bin/kill -0 "$APP_PID" 2>/dev/null; then
            /bin/kill -TERM "$APP_PID" 2>/dev/null || true
        fi

        for _ in {1..50}; do
            if ! /bin/kill -0 "$APP_PID" 2>/dev/null; then
                break
            fi
            /bin/sleep 0.2
        done

        if /bin/kill -0 "$APP_PID" 2>/dev/null; then
            /bin/echo "App did not terminate after TERM; sending KILL to $APP_PID."
            /bin/kill -KILL "$APP_PID" 2>/dev/null || true
            for _ in {1..20}; do
                if ! /bin/kill -0 "$APP_PID" 2>/dev/null; then
                    break
                fi
                /bin/sleep 0.2
            done
        fi

        if /bin/kill -0 "$APP_PID" 2>/dev/null; then
            /bin/echo "App process $APP_PID is still running; aborting install." >&2
            exit 4
        fi

        if [[ -e "$TARGET" ]]; then
            /bin/mv "$TARGET" "$OLD_TARGET"
        fi

        if ! /bin/mv "$TMP_TARGET" "$TARGET"; then
            if [[ -e "$OLD_TARGET" ]]; then
                /bin/mv "$OLD_TARGET" "$TARGET"
            fi
            exit 3
        fi

        if ! /bin/rm -rf "$OLD_TARGET" 2>/dev/null; then
            HIDDEN_OLD="$TARGET_PARENT/.$TARGET_NAME.old.$$"
            /bin/mv "$OLD_TARGET" "$HIDDEN_OLD" 2>/dev/null || true
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" 2>/dev/null || true
        /usr/bin/open -n "$TARGET"
        ROOTINSTALL
        /bin/chmod 755 "$HELPER"

        if [[ -w "$TARGET_PARENT" && ( ! -e "$TARGET" || -w "$TARGET" ) ]]; then
            /bin/zsh "$HELPER" "$APP_PID" "$TARGET" "$TMP_TARGET" "$OLD_TARGET"
        else
            /usr/bin/osascript - "$HELPER" "$APP_PID" "$TARGET" "$TMP_TARGET" "$OLD_TARGET" <<'OSA'
        on run argv
            set helperPath to item 1 of argv
            set appPID to item 2 of argv
            set targetPath to item 3 of argv
            set tmpTargetPath to item 4 of argv
            set oldTargetPath to item 5 of argv
            set commandText to "/bin/zsh " & quoted form of helperPath & " " & quoted form of appPID & " " & quoted form of targetPath & " " & quoted form of tmpTargetPath & " " & quoted form of oldTargetPath
            do shell script commandText with administrator privileges
        end run
        OSA
        fi

        /bin/echo "[$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')] Update installed and relaunched."
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "/usr/bin/nohup /bin/zsh \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()
    }

    static func installedBuildCommit() -> String {
        Bundle.main.object(forInfoDictionaryKey: "TSBuildCommit") as? String ?? "dev"
    }

    static func installedVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func installTargetAppURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.path.contains("/AppTranslocation/") {
            return URL(fileURLWithPath: "/Applications/TokenMeter.app")
        }
        return bundleURL
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
