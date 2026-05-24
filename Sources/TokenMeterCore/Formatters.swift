import Foundation

public enum TokenNumberFormat {
    case compact
    case full
}

public enum TokenFormatters {
    private static let integerFormatter = LockedIntegerFormatter()

    public static func tokens(_ value: Int, format: TokenNumberFormat) -> String {
        switch format {
        case .compact:
            return compactTokens(value)
        case .full:
            return integer(value)
        }
    }

    public static func compactTokens(_ value: Int) -> String {
        let doubleValue = Double(value)
        let absValue = Swift.abs(doubleValue)
        if absValue >= 1_000_000_000 {
            return String(format: "%.1fB", doubleValue / 1_000_000_000)
        }
        if absValue >= 1_000_000 {
            return String(format: "%.1fM", doubleValue / 1_000_000)
        }
        if absValue >= 1_000 {
            return String(format: "%.1fK", doubleValue / 1_000)
        }
        return "\(value)"
    }

    public static func integer(_ value: Int) -> String {
        integerFormatter.string(from: value)
    }
}

private final class LockedIntegerFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: NumberFormatter

    init() {
        formatter = NumberFormatter()
        formatter.numberStyle = .decimal
    }

    func string(from value: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

final class TokenISO8601DateCodec: @unchecked Sendable {
    private struct CanonicalTimestampParts {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        var millisecond: Int
    }

    private let lock = NSLock()
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let plainDateFormatter: ISO8601DateFormatter

    init() {
        fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        plainDateFormatter = ISO8601DateFormatter()
        plainDateFormatter.formatOptions = [.withInternetDateTime]
    }

    static func isCanonicalTimestamp(_ value: String) -> Bool {
        canonicalTimestampParts(from: value) != nil
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractionalDateFormatter.string(from: date)
    }

    func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return date(from: value)
    }

    func date(from value: String) -> Date? {
        if let date = fastCanonicalDate(from: value) {
            return date
        }
        lock.lock()
        defer { lock.unlock() }
        return fractionalDateFormatter.date(from: value) ?? plainDateFormatter.date(from: value)
    }

    private func fastCanonicalDate(from value: String) -> Date? {
        guard let parts = Self.canonicalTimestampParts(from: value) else {
            return nil
        }

        let days = Self.daysSinceUnixEpoch(year: parts.year, month: parts.month, day: parts.day)
        let seconds = days * 86_400 + parts.hour * 3_600 + parts.minute * 60 + parts.second
        return Date(timeIntervalSince1970: Double(seconds) + Double(parts.millisecond) / 1_000)
    }

    private static func canonicalTimestampParts(from value: String) -> CanonicalTimestampParts? {
        let bytes = Array(value.utf8)
        guard bytes.count == 24,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes[10] == 0x54,
              bytes[13] == 0x3A,
              bytes[16] == 0x3A,
              bytes[19] == 0x2E,
              bytes[23] == 0x5A,
              let year = number(in: bytes, at: 0, count: 4),
              let month = number(in: bytes, at: 5, count: 2),
              let day = number(in: bytes, at: 8, count: 2),
              let hour = number(in: bytes, at: 11, count: 2),
              let minute = number(in: bytes, at: 14, count: 2),
              let second = number(in: bytes, at: 17, count: 2),
              let millisecond = number(in: bytes, at: 20, count: 3),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second),
              (1...daysInMonth(year: year, month: month)).contains(day) else {
            return nil
        }

        return CanonicalTimestampParts(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            millisecond: millisecond
        )
    }

    private static func number(in bytes: [UInt8], at start: Int, count: Int) -> Int? {
        var value = 0
        for index in start..<(start + count) {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    private static func daysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int {
        var adjustedYear = year
        adjustedYear -= month <= 2 ? 1 : 0
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            return isLeapYear(year) ? 29 : 28
        default:
            return 0
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }
}
