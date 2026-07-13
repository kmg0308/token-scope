import Foundation

public enum CountdownText {
    public static func until(_ endDate: Date, now: Date = Date()) -> String {
        let remainingSeconds = max(0, Int(endDate.timeIntervalSince(now)))
        let days = remainingSeconds / 86_400
        let hours = (remainingSeconds % 86_400) / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        let seconds = remainingSeconds % 60

        if days > 0 {
            return String(format: "%dd %02dh %02dm %02ds", days, hours, minutes, seconds)
        }

        return String(format: "%02dh %02dm %02ds", hours, minutes, seconds)
    }
}
