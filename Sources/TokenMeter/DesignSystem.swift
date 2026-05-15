import SwiftUI

enum TokenMeterTheme {
    static let background = Color(red: 0.015, green: 0.016, blue: 0.018)
    static let backgroundTop = Color(red: 0.035, green: 0.038, blue: 0.044)
    static let surface = Color.white.opacity(0.055)
    static let elevatedSurface = Color.white.opacity(0.085)
    static let control = Color.white.opacity(0.10)
    static let controlHover = Color.white.opacity(0.15)
    static let border = Color.white.opacity(0.115)
    static let subtleBorder = Color.white.opacity(0.075)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let accent = Color(red: 0.52, green: 0.86, blue: 1.0)
    static let positive = Color(red: 0.38, green: 0.88, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.73, blue: 0.32)

    static let cardRadius: CGFloat = 8
    static let buttonHeight: CGFloat = 36
    static let compactButtonHeight: CGFloat = 28
    static let iconButtonSize: CGFloat = 36
    static let compactIconButtonSize: CGFloat = 28
}

struct TokenSurfaceModifier: ViewModifier {
    var elevated = false

    func body(content: Content) -> some View {
        content
            .background(elevated ? TokenMeterTheme.elevatedSurface : TokenMeterTheme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: TokenMeterTheme.cardRadius, style: .continuous)
                    .stroke(elevated ? TokenMeterTheme.border : TokenMeterTheme.subtleBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: TokenMeterTheme.cardRadius, style: .continuous))
    }
}

extension View {
    func tokenSurface(elevated: Bool = false) -> some View {
        modifier(TokenSurfaceModifier(elevated: elevated))
    }
}

struct TokenPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, prominent ? 14 : 12)
            .frame(minHeight: TokenMeterTheme.buttonHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(prominent ? Color.clear : TokenMeterTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var foregroundColor: Color {
        prominent ? Color.black.opacity(0.90) : TokenMeterTheme.primaryText
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if prominent {
            return TokenMeterTheme.accent.opacity(isPressed ? 0.82 : 1)
        }
        return (isPressed ? TokenMeterTheme.controlHover : TokenMeterTheme.control)
    }
}

struct TokenCompactIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? Color.black.opacity(0.90) : TokenMeterTheme.secondaryText)
            .frame(width: TokenMeterTheme.compactIconButtonSize, height: TokenMeterTheme.compactIconButtonSize)
            .background {
                Circle()
                    .fill(selected ? TokenMeterTheme.accent.opacity(configuration.isPressed ? 0.82 : 1) : TokenMeterTheme.control)
            }
            .overlay {
                Circle()
                    .stroke(selected ? Color.clear : TokenMeterTheme.subtleBorder, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct TokenIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.90) : TokenMeterTheme.primaryText)
            .frame(width: TokenMeterTheme.iconButtonSize, height: TokenMeterTheme.iconButtonSize)
            .background {
                Circle()
                    .fill(prominent ? TokenMeterTheme.accent.opacity(configuration.isPressed ? 0.82 : 1) : TokenMeterTheme.control)
            }
            .overlay {
                Circle()
                    .stroke(prominent ? Color.clear : TokenMeterTheme.border, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
    }
}

struct TokenMenuLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TokenMeterTheme.tertiaryText)
        }
        .foregroundStyle(TokenMeterTheme.primaryText)
        .padding(.horizontal, 11)
        .frame(height: TokenMeterTheme.buttonHeight)
        .background {
            Capsule(style: .continuous)
                .fill(TokenMeterTheme.control)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(TokenMeterTheme.border, lineWidth: 1)
        }
    }
}

struct TokenFilterMenuLabel: View {
    let title: String
    let value: String
    var width: CGFloat = 240

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.tertiaryText)
                .textCase(.uppercase)
                .frame(width: 58, alignment: .leading)

            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TokenMeterTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TokenMeterTheme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: TokenMeterTheme.buttonHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(TokenMeterTheme.control)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(TokenMeterTheme.border, lineWidth: 1)
            }
        }
    }
}
