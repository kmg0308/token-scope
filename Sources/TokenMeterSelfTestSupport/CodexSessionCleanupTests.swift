import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runCodexSessionCleanupTests() throws {
        try cleanupArchivesOnlyVerifiedOldCodexSessions()
        try cleanupBlocksOldCodexSessionsMissingSyncLedgerRecords()
        try cleanupRequiresCachedCodexSessionRecords()
    }

    static func cleanupArchivesOnlyVerifiedOldCodexSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let syncFolder = directory.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        let cache = try temporaryCache(in: directory)
        let device = TokenDeviceMetadata(id: "mac-a", name: "Mac A")
        let scanner = TokenLogScanner(homeDirectory: home, localDevice: device, cacheStore: cache)
        let oldLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "old-session.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10,
            output: 5
        )
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: oldLog)
        let recentLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "recent-session.jsonl",
            timestamp: "2026-07-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-b",
            input: 20
        )
        try setModificationDate(isoDate("2026-07-01T00:10:00.000Z"), for: recentLog)

        let initial = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: initial.events).total == 35, "cleanup initial total")

        let manager = CodexSessionCleanupManager(homeDirectory: home, cacheStore: cache)
        let plan = manager.plan(retentionDays: 90, now: isoDate("2026-07-04T00:00:00.000Z"))
        try expect(plan.scannedFileCount == 1, "cleanup scans only old Codex sessions")
        try expect(plan.eligibleFileCount == 1, "cleanup finds one verified old session")
        try expect(plan.eligibleEventCount == 1, "cleanup counts verified events")
        try expect(plan.unsafeFileCount == 0, "cleanup has no unsafe verified old session")
        try expect(plan.uncachedFileCount == 0, "cleanup has no uncached old session")

        let result = try manager.archiveAndRemove(plan)
        try expect(result.archivedFileCount == 1, "cleanup archives one file")
        try expect(result.removedFileCount == 1, "cleanup removes one file")
        try expect(!FileManager.default.fileExists(atPath: oldLog.path), "cleanup removes old Codex session")
        try expect(FileManager.default.fileExists(atPath: recentLog.path), "cleanup keeps recent Codex session")
        try expect(FileManager.default.fileExists(atPath: result.archiveURL.path), "cleanup creates archive")

        let after = scanner.scan(syncFolder: syncFolder, replaceSyncLedger: true)
        try expect(Aggregation.totalUsage(events: after.events).total == 35, "cleanup keeps total after removing old session")
    }

    static func cleanupBlocksOldCodexSessionsMissingSyncLedgerRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let cache = try temporaryCache(in: directory)
        let scanner = TokenLogScanner(
            homeDirectory: home,
            localDevice: TokenDeviceMetadata(id: "mac-a", name: "Mac A"),
            cacheStore: cache
        )
        let oldLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "unsynced-session.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10
        )
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: oldLog)

        _ = scanner.scan()
        let plan = CodexSessionCleanupManager(homeDirectory: home, cacheStore: cache)
            .plan(retentionDays: 90, now: isoDate("2026-07-04T00:00:00.000Z"))
        try expect(plan.eligibleFileCount == 0, "cleanup blocks unsynced session")
        try expect(plan.unsafeFileCount == 1, "cleanup counts missing sync ledger records")
        try expect(FileManager.default.fileExists(atPath: oldLog.path), "cleanup leaves unsynced session")
    }

    static func cleanupRequiresCachedCodexSessionRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let oldLog = try writeCodexLog(
            homeDirectory: home,
            fileName: "uncached-session.jsonl",
            timestamp: "2026-01-01T00:00:00.000Z",
            cwd: "/tmp/codex-project-a",
            input: 10
        )
        try setModificationDate(isoDate("2026-01-01T00:10:00.000Z"), for: oldLog)

        let plan = CodexSessionCleanupManager(homeDirectory: home)
            .plan(retentionDays: 90, now: isoDate("2026-07-04T00:00:00.000Z"))
        try expect(plan.eligibleFileCount == 0, "cleanup blocks uncached session")
        try expect(plan.uncachedFileCount == 1, "cleanup counts uncached session")
        try expect(FileManager.default.fileExists(atPath: oldLog.path), "cleanup leaves uncached session")
    }
}
