import SwiftUI
import TokenMeterCore

func sourceColor(_ source: TokenSource) -> Color {
    switch source {
    case .codex:
        return Color(red: 0.39, green: 0.72, blue: 1.0)
    case .claude:
        return Color(red: 1.0, green: 0.56, blue: 0.25)
    case .all:
        return Color(red: 0.58, green: 0.62, blue: 0.68)
    }
}

func componentColor(_ kind: TokenComponentKind) -> Color {
    switch kind {
    case .input:
        return Color(red: 0.39, green: 0.72, blue: 1.0)
    case .cache:
        return Color(red: 0.30, green: 0.86, blue: 0.72)
    case .output:
        return Color(red: 1.0, green: 0.76, blue: 0.30)
    case .reasoning:
        return Color(red: 0.72, green: 0.53, blue: 1.0)
    }
}
