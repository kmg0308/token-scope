import Foundation

public enum TokenNumberFormat {
    case compact
    case full
}

public enum TokenFormatters {
    public static func tokens(_ value: Int, format: TokenNumberFormat) -> String {
        switch format {
        case .compact:
            return compactTokens(value)
        case .full:
            return integer(value)
        }
    }

    public static func compactTokens(_ value: Int) -> String {
        let absValue = abs(value)
        if absValue >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if absValue >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absValue >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    public static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
