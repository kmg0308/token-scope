import SwiftUI

enum TokenMeterTheme {
    static let background = Color(red: 0.015, green: 0.016, blue: 0.018)
    static let backgroundTop = Color(red: 0.035, green: 0.038, blue: 0.044)
    static let backgroundInk = Color(red: 0.002, green: 0.006, blue: 0.007)
    static let surface = Color.white.opacity(0.048)
    static let elevatedSurface = Color.white.opacity(0.072)
    static let surfaceFallback = Color(red: 0.055, green: 0.058, blue: 0.064)
    static let elevatedSurfaceFallback = Color(red: 0.074, green: 0.078, blue: 0.088)
    static let control = Color.white.opacity(0.072)
    static let controlHover = Color.white.opacity(0.135)
    static let selectedControl = Color.white.opacity(0.18)
    static let border = Color.white.opacity(0.14)
    static let subtleBorder = Color.white.opacity(0.075)
    static let highlightBorder = Color.white.opacity(0.28)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let accent = Color(red: 0.52, green: 0.86, blue: 1.0)
    static let mint = Color(red: 0.55, green: 1.0, blue: 0.78)
    static let violet = Color(red: 0.62, green: 0.52, blue: 1.0)
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

    static let surfaceStroke = LinearGradient(
        colors: [highlightBorder, subtleBorder],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct TokenLiquidBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            TokenMeterTheme.backgroundGradient

            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        Color.clear,
                        TokenMeterTheme.accent.opacity(0.22),
                        TokenMeterTheme.mint.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 780, height: 210)
                .rotationEffect(.degrees(-10))
                .offset(x: 160, y: -230)
                .blur(radius: 26)

                LinearGradient(
                    colors: [
                        Color.clear,
                        TokenMeterTheme.violet.opacity(0.12),
                        TokenMeterTheme.accent.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 860, height: 180)
                .rotationEffect(.degrees(16))
                .offset(x: -140, y: 260)
                .blur(radius: 34)

                Canvas { context, size in
                    var diagonal = Path()
                    var x = -size.height
                    while x < size.width + size.height {
                        diagonal.move(to: CGPoint(x: x, y: 0))
                        diagonal.addLine(to: CGPoint(x: x + size.height * 0.32, y: size.height))
                        x += 46
                    }
                    context.stroke(diagonal, with: .color(Color.white.opacity(0.026)), lineWidth: 0.7)

                    var horizontal = Path()
                    var y: CGFloat = 58
                    while y < size.height {
                        horizontal.move(to: CGPoint(x: 0, y: y))
                        horizontal.addLine(to: CGPoint(x: size.width, y: y))
                        y += 58
                    }
                    context.stroke(horizontal, with: .color(TokenMeterTheme.accent.opacity(0.026)), lineWidth: 0.6)
                }
                .blendMode(.screen)
            }
        }
    }
}

struct TokenSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var elevated = false
    var radius = TokenMeterTheme.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        let base = content
            .background {
                if reduceTransparency {
                    shape.fill(elevated ? TokenMeterTheme.elevatedSurfaceFallback : TokenMeterTheme.surfaceFallback)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(elevated ? TokenMeterTheme.elevatedSurface : TokenMeterTheme.surface)
                    }
                }
            }
            .overlay {
                shape.stroke(elevated ? TokenMeterTheme.surfaceStroke : LinearGradient(
                    colors: [TokenMeterTheme.border, TokenMeterTheme.subtleBorder],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1)
            }
            .overlay {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(elevated ? 0.16 : 0.09),
                                Color.clear,
                                Color.black.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(elevated ? 0.38 : 0.20), radius: elevated ? 24 : 12, x: 0, y: elevated ? 14 : 6)
            .shadow(color: TokenMeterTheme.accent.opacity(elevated ? 0.08 : 0.03), radius: elevated ? 18 : 8, x: 0, y: 0)
            .clipShape(shape)

        if #available(macOS 26.0, *), elevated, !reduceTransparency {
            base.glassEffect(.regular.tint(Color.white.opacity(0.035)), in: shape)
        } else {
            base
        }
    }
}

extension View {
    func tokenSurface(elevated: Bool = false, radius: CGFloat = TokenMeterTheme.cardRadius) -> some View {
        modifier(TokenSurfaceModifier(elevated: elevated, radius: radius))
    }

    @ViewBuilder
    func tokenScrollEdgeGlass() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

struct TokenControlChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var isActive = false
    var isPressed = false
    var isProminent = false
    var cornerRadius = TokenMeterTheme.controlRadius
    var glassTint: Color?
    var usesGlassEffect = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill = fillColor

        let chrome = ZStack {
            shape.fill(fill)
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isProminent ? 0.28 : 0.18),
                            Color.clear,
                            Color.black.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isProminent ? 0.48 : 0.28),
                        TokenMeterTheme.subtleBorder
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }

        let shadowColor = isProminent ? TokenMeterTheme.accent.opacity(0.38) : Color.black.opacity(0.28)

        if #available(macOS 26.0, *), !reduceTransparency, usesGlassEffect {
            ZStack {
                chrome
            }
            .glassEffect(.regular.tint(glassTint ?? (isProminent ? TokenMeterTheme.accent : nil)).interactive(), in: shape)
            .shadow(color: shadowColor, radius: isProminent ? 16 : 10, x: 0, y: isProminent ? 5 : 4)
            .shadow(color: Color.white.opacity(0.06), radius: 1, x: -1, y: -1)
        } else {
            ZStack {
                if !reduceTransparency {
                    shape.fill(.ultraThinMaterial)
                }
                chrome
            }
            .shadow(color: shadowColor, radius: isProminent ? 14 : 8, x: 0, y: isProminent ? 5 : 4)
        }
    }

    private var fillColor: Color {
        if isProminent {
            return TokenMeterTheme.accent.opacity(isPressed ? 0.70 : 0.84)
        }
        if isActive {
            return TokenMeterTheme.selectedControl.opacity(isPressed ? 0.86 : 1)
        }
        return (isPressed ? TokenMeterTheme.controlHover : TokenMeterTheme.control)
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
        prominent ? Color.black.opacity(0.90) : TokenMeterTheme.primaryText
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
            .foregroundStyle(prominent ? Color.black.opacity(0.90) : TokenMeterTheme.primaryText)
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
