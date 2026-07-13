import Foundation
import TokenMeterCore

extension TokenMeterSelfTest {
    static func runCountdownTextTests() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try expect(
            CountdownText.until(now.addingTimeInterval(18_125), now: now) == "05h 02m 05s",
            "countdown formats hours, minutes, and seconds"
        )
        try expect(
            CountdownText.until(now.addingTimeInterval(86_400), now: now) == "1d 00h 00m 00s",
            "countdown starts showing days at 24 hours"
        )
        try expect(
            CountdownText.until(now.addingTimeInterval(3 * 86_400 + 22 * 3_600 + 38 * 60 + 29), now: now) == "3d 22h 38m 29s",
            "countdown formats multi-day durations with days"
        )
        try expect(
            CountdownText.until(now.addingTimeInterval(-1), now: now) == "00h 00m 00s",
            "countdown clamps elapsed resets to zero"
        )
    }
}
