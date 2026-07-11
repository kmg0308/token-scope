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
            CountdownText.until(now.addingTimeInterval(7 * 86_400 + 61), now: now) == "168h 01m 01s",
            "countdown keeps weekly durations in hours"
        )
        try expect(
            CountdownText.until(now.addingTimeInterval(-1), now: now) == "00h 00m 00s",
            "countdown clamps elapsed resets to zero"
        )
    }
}
