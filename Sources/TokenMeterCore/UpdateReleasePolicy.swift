import Foundation

public struct GitHubRepository: Equatable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var apiBase: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(name)")!
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let displayName: String
    public let zipURL: URL
    public let htmlURL: URL?
    public let targetCommitish: String

    public init(
        version: String,
        displayName: String,
        zipURL: URL,
        htmlURL: URL?,
        targetCommitish: String
    ) {
        self.version = version
        self.displayName = displayName
        self.zipURL = zipURL
        self.htmlURL = htmlURL
        self.targetCommitish = targetCommitish
    }

    public var downloadIdentity: String {
        "\(version)|\(targetCommitish)|\(zipURL.absoluteString)"
    }
}

public struct UpdateAvailability: Equatable, Sendable {
    public let currentVersion: String
    public let installedBuildCommit: String
    public let release: ReleaseInfo

    public init(currentVersion: String, installedBuildCommit: String, release: ReleaseInfo) {
        self.currentVersion = currentVersion
        self.installedBuildCommit = installedBuildCommit
        self.release = release
    }

    public var isAvailable: Bool {
        if installedBuildCommit != "dev",
           UpdateReleasePolicy.looksLikeGitCommit(release.targetCommitish),
           !UpdateReleasePolicy.commitsMatch(release.targetCommitish, installedBuildCommit) {
            return true
        }
        return UpdateReleasePolicy.compareVersions(release.version, currentVersion) == .orderedDescending
    }
}

public enum UpdateReleasePolicy {
    public enum AppBundleValidationError: Error, Equatable, CustomStringConvertible {
        case notAppBundle
        case missingInfoPlist
        case invalidBundleIdentity(bundleIdentifier: String?, executable: String?)
        case invalidBundleName(String?)
        case invalidPackageType(String?)
        case missingVersion
        case missingBuild
        case menuBarOnlyApp
        case backgroundOnlyApp
        case missingExecutable

        public var description: String {
            switch self {
            case .notAppBundle:
                return "Updates can only install an app bundle."
            case .missingInfoPlist:
                return "Downloaded app is missing Info.plist."
            case .invalidBundleIdentity(let bundleIdentifier, let executable):
                return "Downloaded app bundle identity is invalid: \(bundleIdentifier ?? "nil") / \(executable ?? "nil")."
            case .invalidBundleName(let name):
                return "Downloaded app bundle name is invalid: \(name ?? "nil")."
            case .invalidPackageType(let packageType):
                return "Downloaded app package type is invalid: \(packageType ?? "nil")."
            case .missingVersion:
                return "Downloaded app version is missing."
            case .missingBuild:
                return "Downloaded app build number is missing."
            case .menuBarOnlyApp:
                return "Downloaded app must not be a menu-bar-only app."
            case .backgroundOnlyApp:
                return "Downloaded app must not be a background-only app."
            case .missingExecutable:
                return "Downloaded app executable is missing."
            }
        }
    }

    public static let tokenMeterAppName = "TokenMeter"
    public static let tokenMeterBundleIdentifier = "local.tokenmeter.app"
    public static let tokenMeterExecutableName = "TokenMeter"

    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : "0"
            let b = index < right.count ? right[index] : "0"
            let comparison = compareVersionPart(a, b)
            if comparison != .orderedSame {
                return comparison
            }
        }
        return .orderedSame
    }

    public static func normalizedVersion(_ string: String) -> String {
        var version = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        return version
    }

    public static func looksLikeGitCommit(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (7...40).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy(\.isHexDigit)
    }

    public static func commitsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard looksLikeGitCommit(left), looksLikeGitCommit(right) else { return false }
        return left.hasPrefix(right) || right.hasPrefix(left)
    }

    public static func isInstallableTokenMeterZipAssetName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "tokenmeter.zip" {
            return true
        }

        let prefix = "tokenmeter-"
        let suffix = ".zip"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }

        let version = name.dropFirst(prefix.count).dropLast(suffix.count)
        return version.contains(where: \.isNumber)
            && version.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }

    public static func tokenMeterZipDownloadName(version: String) -> String {
        let safeVersion = safeFileComponent(normalizedVersion(version))
        guard !safeVersion.isEmpty else { return "TokenMeter.zip" }
        return "TokenMeter-\(safeVersion).zip"
    }

    public static func validateTokenMeterAppBundle(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard url.pathExtension == "app" else {
            throw AppBundleValidationError.notAppBundle
        }

        let infoPlistURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppBundleValidationError.missingInfoPlist
        }

        let bundleIdentifier = info["CFBundleIdentifier"] as? String
        let executable = info["CFBundleExecutable"] as? String
        guard bundleIdentifier == tokenMeterBundleIdentifier,
              executable == tokenMeterExecutableName else {
            throw AppBundleValidationError.invalidBundleIdentity(
                bundleIdentifier: bundleIdentifier,
                executable: executable
            )
        }
        let bundleName = info["CFBundleName"] as? String
        guard bundleName == tokenMeterAppName else {
            throw AppBundleValidationError.invalidBundleName(bundleName)
        }

        let packageType = info["CFBundlePackageType"] as? String
        guard packageType == "APPL" else {
            throw AppBundleValidationError.invalidPackageType(packageType)
        }

        if stringValue(info["CFBundleShortVersionString"]).isEmpty {
            throw AppBundleValidationError.missingVersion
        }
        if stringValue(info["CFBundleVersion"]).isEmpty {
            throw AppBundleValidationError.missingBuild
        }

        if plistFlagIsEnabled(info["LSUIElement"]) {
            throw AppBundleValidationError.menuBarOnlyApp
        }
        if plistFlagIsEnabled(info["LSBackgroundOnly"]) {
            throw AppBundleValidationError.backgroundOnlyApp
        }

        let executableURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(tokenMeterExecutableName)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppBundleValidationError.missingExecutable
        }
    }

    private static func versionParts(_ string: String) -> [String] {
        normalizedVersion(string)
            .split { character in
                character == "." || character == "-" || character == "_"
            }
            .map(String.init)
    }

    private static func compareVersionPart(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalizedNumericPart(lhs)
        let right = normalizedNumericPart(rhs)
        if left.count > right.count { return .orderedDescending }
        if left.count < right.count { return .orderedAscending }
        if left > right { return .orderedDescending }
        if left < right { return .orderedAscending }
        return .orderedSame
    }

    private static func normalizedNumericPart(_ value: String) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return "0"
        }
        let trimmed = value.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func safeFileComponent(_ string: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let characters = string.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(characters).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plistFlagIsEnabled(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "yes" || normalized == "1"
        }
        return false
    }
}
