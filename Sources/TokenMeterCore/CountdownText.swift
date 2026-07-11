import Foundation

public enum CountdownText {
    public static func until(_ endDate: Date, now: Date = Date()) -> String {
        let remainingSeconds = max(0, Int(endDate.timeIntervalSince(now)))
        let hours = remainingSeconds / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        let seconds = remainingSeconds % 60

        return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
    }
}
