import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runUpdatePolicyTests() throws {
        try updatePolicyComparesLargeVersionPartsWithoutOverflow()
        try updateAvailabilityUsesCommitOnlyForCommitTargets()
        try updatePolicyAcceptsOnlyInstallableReleaseZipNames()
        try updatePolicyValidatesTokenMeterAppBundles()
    }

    static func updatePolicyComparesLargeVersionPartsWithoutOverflow() throws {
        try expect(
            UpdateReleasePolicy.compareVersions("999999999999999999999999.0.0", "2.0.0") == .orderedDescending,
            "huge version part compares as a number instead of falling back to zero"
        )
        try expect(
            UpdateReleasePolicy.compareVersions("1.00000000000000000002", "1.2") == .orderedSame,
            "leading zeroes do not change version part value"
        )
        try expect(
            UpdateReleasePolicy.compareVersions("1.10.0", "1.2.999") == .orderedDescending,
            "multi-digit version parts compare numerically"
        )
        try expect(
            UpdateReleasePolicy.compareVersions("1.beta.0", "1.0.0") == .orderedSame,
            "non-numeric version parts keep existing zero-equivalent behavior"
        )
    }

    static func updateAvailabilityUsesCommitOnlyForCommitTargets() throws {
        let branchTarget = release(version: "1.0.0", targetCommitish: "main")
        try expect(
            !UpdateAvailability(
                currentVersion: "1.0.0",
                installedBuildCommit: "abcdef1",
                release: branchTarget
            ).isAvailable,
            "branch target does not force same-version update"
        )

        let newerVersion = release(version: "1.0.1", targetCommitish: "main")
        try expect(
            UpdateAvailability(
                currentVersion: "1.0.0",
                installedBuildCommit: "abcdef1",
                release: newerVersion
            ).isAvailable,
            "newer version still updates when release target is a branch"
        )

        let sameCommit = release(version: "1.0.0", targetCommitish: "abcdef1234567890")
        try expect(
            !UpdateAvailability(
                currentVersion: "1.0.0",
                installedBuildCommit: "abcdef1",
                release: sameCommit
            ).isAvailable,
            "same commit prefix does not update"
        )

        let shortReleaseTarget = release(version: "1.0.0", targetCommitish: "abcdef1")
        try expect(
            !UpdateAvailability(
                currentVersion: "1.0.0",
                installedBuildCommit: "abcdef1234567890",
                release: shortReleaseTarget
            ).isAvailable,
            "short release target matches full installed commit"
        )

        let upperCaseReleaseTarget = release(version: "1.0.0", targetCommitish: "ABCDEF1")
        try expect(
            !UpdateAvailability(
                currentVersion: "1.0.0",
                installedBuildCommit: "abcdef1234567890",
                release: upperCaseReleaseTarget
            ).isAvailable,
            "commit comparison ignores case"
        )

        let differentCommit = release(version: "1.0.0", targetCommitish: "1234567890abcdef")
        try expect(
            UpdateAvailability(
                currentVersion: "1.0.0",
                installedBuildCommit: "abcdef1",
                release: differentCommit
            ).isAvailable,
            "different commit target updates even when version matches"
        )
    }

    static func updatePolicyAcceptsOnlyInstallableReleaseZipNames() throws {
        let accepted = [
            "TokenMeter.zip",
            "tokenmeter.zip",
            "TokenMeter-1.2.3.zip",
            "tokenmeter-0.1.123.zip",
            "tokenmeter-2026-05-24.zip"
        ]
        for name in accepted {
            try expect(
                UpdateReleasePolicy.isInstallableTokenMeterZipAssetName(name),
                "release ZIP accepts \(name)"
            )
        }

        let rejected = [
            "source.zip",
            "tokenmeter-source.zip",
            "tokenmeter-latest.zip",
            "tokenmeter.pkg",
            "token-meter-1.2.3.zip",
            "TokenMeter.app.zip"
        ]
        for name in rejected {
            try expect(
                !UpdateReleasePolicy.isInstallableTokenMeterZipAssetName(name),
                "release ZIP rejects \(name)"
            )
        }

        try expect(
            UpdateReleasePolicy.tokenMeterZipDownloadName(version: "v1.2.3") == "TokenMeter-1.2.3.zip",
            "download ZIP name normalizes v-prefixed versions"
        )
        try expect(
            UpdateReleasePolicy.tokenMeterZipDownloadName(version: "feature/test 1") == "TokenMeter-feature-test-1.zip",
            "download ZIP name removes path separators"
        )
        try expect(
            UpdateReleasePolicy.tokenMeterZipDownloadName(version: "../") == "TokenMeter.zip",
            "download ZIP name falls back for empty sanitized versions"
        )
    }

    static func updatePolicyValidatesTokenMeterAppBundles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let validApp = try writeTokenMeterAppBundle(in: directory, name: "TokenMeter.app")
        try UpdateReleasePolicy.validateTokenMeterAppBundle(at: validApp)

        let explicitFalseFlags = try writeTokenMeterAppBundle(
            in: directory,
            name: "ExplicitFalseFlags.app",
            extraInfoPlistKeys: """
            <key>LSUIElement</key>
            <false/>
            <key>LSBackgroundOnly</key>
            <false/>
            """
        )
        try UpdateReleasePolicy.validateTokenMeterAppBundle(at: explicitFalseFlags)

        let wrongIdentity = try writeTokenMeterAppBundle(
            in: directory,
            name: "WrongIdentity.app",
            bundleIdentifier: "local.other.app"
        )
        try expectValidationError(
            .invalidBundleIdentity(bundleIdentifier: "local.other.app", executable: "TokenMeter"),
            from: wrongIdentity
        )

        let wrongName = try writeTokenMeterAppBundle(
            in: directory,
            name: "WrongName.app",
            bundleName: "TokenScope"
        )
        try expectValidationError(.invalidBundleName("TokenScope"), from: wrongName)

        let wrongPackageType = try writeTokenMeterAppBundle(
            in: directory,
            name: "WrongPackageType.app",
            packageType: "BNDL"
        )
        try expectValidationError(.invalidPackageType("BNDL"), from: wrongPackageType)

        let missingVersion = try writeTokenMeterAppBundle(
            in: directory,
            name: "MissingVersion.app",
            shortVersion: ""
        )
        try expectValidationError(.missingVersion, from: missingVersion)

        let missingBuild = try writeTokenMeterAppBundle(
            in: directory,
            name: "MissingBuild.app",
            buildVersion: "   "
        )
        try expectValidationError(.missingBuild, from: missingBuild)

        let menuBarOnly = try writeTokenMeterAppBundle(
            in: directory,
            name: "MenuBarOnly.app",
            extraInfoPlistKeys: "<key>LSUIElement</key>\n    <true/>"
        )
        try expectValidationError(.menuBarOnlyApp, from: menuBarOnly)

        let stringMenuBarOnly = try writeTokenMeterAppBundle(
            in: directory,
            name: "StringMenuBarOnly.app",
            extraInfoPlistKeys: "<key>LSUIElement</key>\n    <string>1</string>"
        )
        try expectValidationError(.menuBarOnlyApp, from: stringMenuBarOnly)

        let yesMenuBarOnly = try writeTokenMeterAppBundle(
            in: directory,
            name: "YesMenuBarOnly.app",
            extraInfoPlistKeys: "<key>LSUIElement</key>\n    <string>YES</string>"
        )
        try expectValidationError(.menuBarOnlyApp, from: yesMenuBarOnly)

        let backgroundOnly = try writeTokenMeterAppBundle(
            in: directory,
            name: "BackgroundOnly.app",
            extraInfoPlistKeys: "<key>LSBackgroundOnly</key>\n    <true/>"
        )
        try expectValidationError(.backgroundOnlyApp, from: backgroundOnly)

        let integerBackgroundOnly = try writeTokenMeterAppBundle(
            in: directory,
            name: "IntegerBackgroundOnly.app",
            extraInfoPlistKeys: "<key>LSBackgroundOnly</key>\n    <integer>1</integer>"
        )
        try expectValidationError(.backgroundOnlyApp, from: integerBackgroundOnly)

        let yesBackgroundOnly = try writeTokenMeterAppBundle(
            in: directory,
            name: "YesBackgroundOnly.app",
            extraInfoPlistKeys: "<key>LSBackgroundOnly</key>\n    <string>YES</string>"
        )
        try expectValidationError(.backgroundOnlyApp, from: yesBackgroundOnly)

        let missingExecutable = try writeTokenMeterAppBundle(
            in: directory,
            name: "MissingExecutable.app",
            writeExecutable: false
        )
        try expectValidationError(.missingExecutable, from: missingExecutable)
    }

    private static func writeTokenMeterAppBundle(
        in directory: URL,
        name: String,
        bundleName: String = UpdateReleasePolicy.tokenMeterAppName,
        bundleIdentifier: String = UpdateReleasePolicy.tokenMeterBundleIdentifier,
        executableName: String = UpdateReleasePolicy.tokenMeterExecutableName,
        packageType: String = "APPL",
        shortVersion: String = "1.0.0",
        buildVersion: String = "1",
        extraInfoPlistKeys: String = "",
        writeExecutable: Bool = true
    ) throws -> URL {
        let appURL = directory.appendingPathComponent(name, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleName</key>
            <string>\(bundleName)</string>
            <key>CFBundleExecutable</key>
            <string>\(executableName)</string>
            <key>CFBundlePackageType</key>
            <string>\(packageType)</string>
            <key>CFBundleShortVersionString</key>
            <string>\(shortVersion)</string>
            <key>CFBundleVersion</key>
            <string>\(buildVersion)</string>
            \(extraInfoPlistKeys)
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        if writeExecutable {
            let executableURL = macOSURL.appendingPathComponent(executableName)
            try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }

        return appURL
    }

    private static func expectValidationError(
        _ expected: UpdateReleasePolicy.AppBundleValidationError,
        from appURL: URL
    ) throws {
        do {
            try UpdateReleasePolicy.validateTokenMeterAppBundle(at: appURL)
        } catch let error as UpdateReleasePolicy.AppBundleValidationError {
            try expect(error == expected, "expected validation error \(expected)")
            return
        }
        throw TestFailure(message: "expected validation error \(expected)")
    }
}
