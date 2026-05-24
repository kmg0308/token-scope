import Foundation
import TokenMeterCore

enum UpdateServiceError: LocalizedError {
    case invalidResponse
    case noDownloadURL
    case noDownloadedFile
    case notAnAppBundle
    case invalidDownloadedArchive(String)
    case invalidDownloadedAppBundle(String)
    case invalidCodeSignature(String)

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
        case .invalidDownloadedArchive(let message):
            "Downloaded update archive is invalid: \(message)"
        case .invalidDownloadedAppBundle(let message):
            "Downloaded app bundle is invalid: \(message)"
        case .invalidCodeSignature(let message):
            "Downloaded app code signature is invalid: \(message)"
        }
    }
}

enum UpdateService {
    static let repository = GitHubRepository(owner: "kmg0308", name: "token-scope")

    static func checkLatestRelease() async throws -> UpdateAvailability {
        let release = try await latestRelease(repository: repository)
        return UpdateAvailability(
            currentVersion: installedVersion(),
            installedBuildCommit: installedBuildCommit(),
            release: release
        )
    }

    static func downloadRelease(_ release: ReleaseInfo) async throws -> URL {
        try await download(
            url: release.zipURL,
            suggestedName: UpdateReleasePolicy.tokenMeterZipDownloadName(version: release.version)
        )
    }

    static func installDownloadedAppArchive(_ zipURL: URL) throws {
        try validateDownloadedAppArchive(zipURL)
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

        plist_flag_enabled() {
            local value="${1:l}"
            [[ "$value" == "true" || "$value" == "yes" || "$value" == "1" ]]
        }

        cleanup() {
            /bin/rm -rf "$WORK" "$TMP_TARGET"
            /bin/rm -f "$SCRIPT"
        }
        trap cleanup EXIT

        /usr/bin/find "$TARGET_PARENT" -maxdepth 1 \\( -name "$TARGET_NAME.new.*" -o -name "$TARGET_NAME.old.*" -o -name ".$TARGET_NAME.old.*" \\) -exec /bin/rm -rf {} + 2>/dev/null || true

        /usr/bin/ditto -x -k "$ZIP" "$WORK"
        NEW_APP="$WORK/TokenMeter.app"
        if [[ ! -d "$NEW_APP" ]]; then
            /bin/echo "TokenMeter.app was not found in archive." >&2
            exit 2
        fi

        /bin/rm -rf "$TMP_TARGET" "$OLD_TARGET"
        /usr/bin/ditto "$NEW_APP" "$TMP_TARGET"
        /usr/bin/xattr -cr "$TMP_TARGET" 2>/dev/null || true

        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$BUNDLE_ID" != "\(UpdateReleasePolicy.tokenMeterBundleIdentifier)" || "$EXECUTABLE" != "\(UpdateReleasePolicy.tokenMeterExecutableName)" ]]; then
            /bin/echo "Downloaded app bundle identity is invalid: $BUNDLE_ID / $EXECUTABLE" >&2
            exit 5
        fi
        BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$BUNDLE_NAME" != "\(UpdateReleasePolicy.tokenMeterAppName)" ]]; then
            /bin/echo "Downloaded app bundle name is invalid: $BUNDLE_NAME" >&2
            exit 10
        fi
        PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$PACKAGE_TYPE" != "APPL" ]]; then
            /bin/echo "Downloaded app package type is invalid: $PACKAGE_TYPE" >&2
            exit 11
        fi
        SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if [[ -z "${SHORT_VERSION//[[:space:]]/}" ]]; then
            /bin/echo "Downloaded app version is missing." >&2
            exit 12
        fi
        BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if [[ -z "${BUILD_VERSION//[[:space:]]/}" ]]; then
            /bin/echo "Downloaded app build number is missing." >&2
            exit 13
        fi
        LSUI_ELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if plist_flag_enabled "$LSUI_ELEMENT"; then
            /bin/echo "Downloaded app must not be a menu-bar-only app." >&2
            exit 8
        fi
        LS_BACKGROUND_ONLY="$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$TMP_TARGET/Contents/Info.plist" 2>/dev/null || true)"
        if plist_flag_enabled "$LS_BACKGROUND_ONLY"; then
            /bin/echo "Downloaded app must not be a background-only app." >&2
            exit 9
        fi
        if [[ ! -x "$TMP_TARGET/Contents/MacOS/\(UpdateReleasePolicy.tokenMeterExecutableName)" ]]; then
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
        Bundle.main.object(forInfoDictionaryKey: "TokenMeterBuildCommit") as? String ?? "dev"
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

    private static func validateDownloadedAppArchive(_ zipURL: URL) throws {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw UpdateServiceError.noDownloadedFile
        }

        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-update-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workURL)
        }

        do {
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", zipURL.path, workURL.path]
            )
        } catch {
            throw UpdateServiceError.invalidDownloadedArchive(String(describing: error))
        }

        let appURL = workURL.appendingPathComponent("TokenMeter.app", isDirectory: true)
        do {
            try UpdateReleasePolicy.validateTokenMeterAppBundle(at: appURL)
        } catch {
            throw UpdateServiceError.invalidDownloadedAppBundle(String(describing: error))
        }

        do {
            try runProcess(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appURL.path]
            )
        } catch {
            throw UpdateServiceError.invalidCodeSignature(String(describing: error))
        }
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
            version: UpdateReleasePolicy.normalizedVersion(tag),
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
            UpdateReleasePolicy.isInstallableTokenMeterZipAssetName(assetName(asset))
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
        let destination = availableDownloadURL(in: downloads, suggestedName: suggestedName)
        try FileManager.default.copyItem(at: tempURL, to: destination)
        return destination
    }

    private static func availableDownloadURL(in directory: URL, suggestedName: String) -> URL {
        let fileName = URL(fileURLWithPath: suggestedName).lastPathComponent
        let safeName = fileName.isEmpty ? "TokenMeter.zip" : fileName
        let base = URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: safeName).pathExtension
        var candidate = directory.appendingPathComponent(safeName)
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessFailure(message: message ?? "exit \(process.terminationStatus)")
        }
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ProcessFailure: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
