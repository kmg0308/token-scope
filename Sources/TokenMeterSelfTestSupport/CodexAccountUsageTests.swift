import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runCodexAccountUsageTests() throws {
        try codexAccountUsageParsesFiveHourWeeklyAndResetCredits()
        try codexAccountUsageUsesAuthoritativeCreditCount()
        try codexAccountUsageKeepsUnavailableWindowsExplicit()
        try codexAccountUsageReportsRPCError()
    }

    static func codexAccountUsageParsesFiveHourWeeklyAndResetCredits() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(
            """
            {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":1783666131},"secondary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":1784252931}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"expiresAt":1785109644},{"expiresAt":1785524779}]}}}
            """.utf8
        )

        let usage = try CodexAccountUsageParser.parseRateLimitsResponse(data, fetchedAt: fetchedAt)

        try expect(usage.fiveHourWindow?.usedPercent == 31, "Codex 5-hour used percent")
        try expect(usage.fiveHourWindow?.remainingPercent == 69, "Codex 5-hour remaining percent")
        try expect(usage.sevenDayWindow?.usedPercent == 5, "Codex 7-day used percent")
        try expect(usage.sevenDayWindow?.remainingPercent == 95, "Codex 7-day remaining percent")
        try expect(usage.resetCredits?.availableCount == 2, "Codex reset-credit count")
        try expect(usage.resetCredits?.expirations.count == 2, "Codex reset-credit expirations")
        try expect(usage.fetchedAt == fetchedAt, "Codex usage fetch timestamp")
    }

    static func codexAccountUsageUsesAuthoritativeCreditCount() throws {
        let data = Data(
            """
            {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":150,"windowDurationMins":300,"resetsAt":1783666131},"secondary":{"usedPercent":-4,"windowDurationMins":10080,"resetsAt":1784252931}},"rateLimitResetCredits":{"availableCount":4,"credits":[{"expiresAt":1785109644}]}}}
            """.utf8
        )

        let usage = try CodexAccountUsageParser.parseRateLimitsResponse(data)

        try expect(usage.fiveHourWindow?.usedPercent == 100, "Codex used percent clamps high values")
        try expect(usage.sevenDayWindow?.usedPercent == 0, "Codex used percent clamps negative values")
        try expect(usage.resetCredits?.availableCount == 4, "Codex authoritative reset-credit count")
        try expect(usage.resetCredits?.expirations.count == 1, "Codex capped credit details remain partial")
    }

    static func codexAccountUsageKeepsUnavailableWindowsExplicit() throws {
        let data = Data(
            """
            {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":15,"resetsAt":1783666131},"secondary":null},"rateLimitResetCredits":null}}
            """.utf8
        )

        let usage = try CodexAccountUsageParser.parseRateLimitsResponse(data)

        try expect(usage.fiveHourWindow == nil, "Codex missing 5-hour window is explicit")
        try expect(usage.sevenDayWindow == nil, "Codex missing 7-day window is explicit")
        try expect(usage.resetCredits == nil, "Codex unavailable reset credits are explicit")
    }

    static func codexAccountUsageReportsRPCError() throws {
        let data = Data(#"{"id":2,"error":{"code":-32000,"message":"Login required"}}"#.utf8)

        do {
            _ = try CodexAccountUsageParser.parseRateLimitsResponse(data)
            throw TestFailure(message: "Codex RPC error should throw")
        } catch CodexAccountUsageError.serverError(let message) {
            try expect(message == "Login required", "Codex RPC error message")
        }
    }
}
