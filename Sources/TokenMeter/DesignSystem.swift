import SwiftUI

enum TokenMeterTheme {
    static let background = Color(red: 0.010, green: 0.012, blue: 0.016)
    static let backgroundTop = Color(red: 0.026, green: 0.031, blue: 0.038)
    static let backgroundInk = Color(red: 0.004, green: 0.006, blue: 0.009)
    static let surface = Color(red: 0.050, green: 0.058, blue: 0.070)
    static let elevatedSurface = Color(red: 0.066, green: 0.077, blue: 0.092)
    static let surfaceFallback = Color(red: 0.050, green: 0.058, blue: 0.070)
    static let elevatedSurfaceFallback = Color(red: 0.066, green: 0.077, blue: 0.092)
    static let control = Color(red: 0.074, green: 0.086, blue: 0.102)
    static let controlHover = Color(red: 0.100, green: 0.118, blue: 0.140)
    static let selectedControl = Color(red: 0.090, green: 0.145, blue: 0.170)
    static let border = Color.white.opacity(0.105)
    static let subtleBorder = Color.white.opacity(0.065)
    static let highlightBorder = Color.white.opacity(0.16)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let accent = Color(red: 0.42, green: 0.78, blue: 0.96)
    static let accentFill = Color(red: 0.125, green: 0.360, blue: 0.480)
    static let accentFillPressed = Color(red: 0.095, green: 0.290, blue: 0.390)
    static let mint = Color(red: 0.46, green: 0.88, blue: 0.68)
    static let violet = Color(red: 0.50, green: 0.46, blue: 0.84)
    static let positive = Color(red: 0.38, green: 0.88, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.73, blue: 0.32)

    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 10
    static let compactControlRadius: CGFloat = 8
    static let buttonHeight: CGFloat = 34
    static let compactButtonHeight: CGFloat = 30
    static let iconButtonSize: CGFloat = 34
    static let compactIconButtonSize: CGFloat = 30

    static let backgroundGradient = LinearGradient(
        colors: [backgroundTop, background, backgroundInk],
        startPoint: .top,
        endPoint: .bottom
    )
}

struct TokenLiquidBackdrop: View {
    var body: some View {
        TokenMeterTheme.backgroundGradient
    }
}

struct TokenSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var elevated = false
    var radius = TokenMeterTheme.cardRadius
    var glass = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill = reduceTransparency
            ? (elevated ? TokenMeterTheme.elevatedSurfaceFallback : TokenMeterTheme.surfaceFallback)
            : (elevated ? TokenMeterTheme.elevatedSurface : TokenMeterTheme.surface)

        let base = content
            .background {
                ZStack {
                    if glass, !reduceTransparency {
                        shape.fill(.thinMaterial)
                    }
                    shape.fill(fill)
                }
            }
            .overlay {
                shape.stroke(elevated ? TokenMeterTheme.border : TokenMeterTheme.subtleBorder, lineWidth: 1)
            }
            .overlay {
                shape.stroke(Color.white.opacity(elevated ? 0.055 : 0.035), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(elevated ? (glass ? 0.30 : 0.18) : 0.08), radius: elevated ? (glass ? 16 : 7) : 3, x: 0, y: elevated ? (glass ? 9 : 4) : 1)
            .clipShape(shape)

        #if compiler(>=6.3)
        if #available(macOS 26.0, *), glass, elevated, !reduceTransparency {
            base.glassEffect(.regular.tint(Color.white.opacity(0.025)), in: shape)
        } else {
            base
        }
        #else
        base
        #endif
    }
}

extension View {
    func tokenSurface(elevated: Bool = false, radius: CGFloat = TokenMeterTheme.cardRadius, glass: Bool = false) -> some View {
        modifier(TokenSurfaceModifier(elevated: elevated, radius: radius, glass: glass))
    }
}

struct TokenControlChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var isActive = false
    var isPressed = false
    var isProminent = false
    var cornerRadius = TokenMeterTheme.controlRadius
    var glassTint: Color?
    var usesGlassEffect = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill = fillColor

        let chrome = ZStack {
            shape.fill(fill)
            shape.stroke(strokeColor, lineWidth: 1)
            shape.stroke(Color.white.opacity(isProminent ? 0.08 : 0.04), lineWidth: 1)
        }

        let shadowColor = isProminent ? TokenMeterTheme.accent.opacity(0.22) : Color.black.opacity(0.16)

        #if compiler(>=6.3)
        if #available(macOS 26.0, *), !reduceTransparency, usesGlassEffect {
            ZStack {
                chrome
            }
            .glassEffect(.regular.tint(glassTint ?? (isProminent ? TokenMeterTheme.accent : nil)).interactive(), in: shape)
            .shadow(color: shadowColor, radius: isProminent ? 10 : 6, x: 0, y: isProminent ? 4 : 2)
        } else {
            chrome
                .shadow(color: shadowColor, radius: isProminent ? 8 : 3, x: 0, y: isProminent ? 3 : 1)
        }
        #else
        chrome
            .shadow(color: shadowColor, radius: isProminent ? 8 : 3, x: 0, y: isProminent ? 3 : 1)
        #endif
    }

    private var fillColor: Color {
        if isProminent {
            return isPressed ? TokenMeterTheme.accentFillPressed : TokenMeterTheme.accentFill
        }
        if isActive {
            return TokenMeterTheme.selectedControl.opacity(isPressed ? 0.86 : 1)
        }
        return (isPressed ? TokenMeterTheme.controlHover : TokenMeterTheme.control)
    }

    private var strokeColor: Color {
        if isProminent {
            return TokenMeterTheme.accent.opacity(isPressed ? 0.50 : 0.36)
        }
        if isActive {
            return TokenMeterTheme.accent.opacity(0.24)
        }
        return isPressed ? TokenMeterTheme.highlightBorder : TokenMeterTheme.subtleBorder
    }
}

struct TokenPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, prominent ? 15 : 12)
            .frame(height: TokenMeterTheme.buttonHeight)
            .background {
                TokenControlChrome(
                    isPressed: configuration.isPressed,
                    isProminent: prominent,
                    cornerRadius: prominent ? TokenMeterTheme.buttonHeight / 2 : TokenMeterTheme.controlRadius
                )
            }
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var foregroundColor: Color {
        TokenMeterTheme.primaryText
    }
}

struct TokenCompactIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? TokenMeterTheme.primaryText : TokenMeterTheme.secondaryText)
            .frame(width: TokenMeterTheme.compactIconButtonSize, height: TokenMeterTheme.compactIconButtonSize)
            .background {
                TokenControlChrome(
                    isPressed: configuration.isPressed,
                    isProminent: selected,
                    cornerRadius: TokenMeterTheme.compactControlRadius
                )
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
            .foregroundStyle(TokenMeterTheme.primaryText)
            .frame(width: TokenMeterTheme.iconButtonSize, height: TokenMeterTheme.iconButtonSize)
            .background {
                TokenControlChrome(
                    isPressed: configuration.isPressed,
                    isProminent: prominent,
                    cornerRadius: TokenMeterTheme.controlRadius
                )
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
            TokenControlChrome()
        }
    }
}

struct TokenFilterMenuLabel: View {
    let title: String
    let value: String
    var width: CGFloat = 320

    var body: some View {
        HStack(spacing: 8) {
            Text("\(title.uppercased())  \(value)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TokenMeterTheme.tertiaryText)
        }
        .padding(.horizontal, 11)
        .frame(width: width, height: TokenMeterTheme.buttonHeight)
        .background {
            TokenControlChrome()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
