import AppKit
import SwiftUI

enum TokenMeterTheme {
    static let background = Color(red: 0.010, green: 0.012, blue: 0.016)
    static let surface = Color(red: 0.050, green: 0.058, blue: 0.070)
    static let elevatedSurface = Color(red: 0.066, green: 0.077, blue: 0.092)
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
}

struct TokenLiquidBackdrop: View {
    var body: some View {
        TokenMeterTheme.background
    }
}

struct TokenSurfaceModifier: ViewModifier {
    var elevated = false
    var radius = TokenMeterTheme.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill = elevated ? TokenMeterTheme.elevatedSurface : TokenMeterTheme.surface

        let base = content
            .background {
                shape.fill(fill)
            }
            .overlay {
                shape.stroke(elevated ? TokenMeterTheme.border : TokenMeterTheme.subtleBorder, lineWidth: 1)
            }

        base
    }
}

extension View {
    func tokenSurface(elevated: Bool = false, radius: CGFloat = TokenMeterTheme.cardRadius) -> some View {
        modifier(TokenSurfaceModifier(elevated: elevated, radius: radius))
    }
}

struct TokenControlChrome: View {
    var isActive = false
    var isPressed = false
    var isProminent = false
    var cornerRadius = TokenMeterTheme.controlRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill = fillColor

        let chrome = ZStack {
            shape.fill(fill)
            shape.stroke(strokeColor, lineWidth: 1)
        }

        chrome
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

struct TokenSmoothScrollView<Content: View>: NSViewRepresentable {
    private let content: Content
    private let onScrollActivityChanged: (Bool) -> Void

    init(
        onScrollActivityChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder content: () -> Content
    ) {
        self.onScrollActivityChanged = onScrollActivityChanged
        self.content = content()
    }

    func makeNSView(context: Context) -> TokenHostingScrollView<Content> {
        let scrollView = TokenHostingScrollView(rootView: content)
        scrollView.onScrollActivityChanged = onScrollActivityChanged
        return scrollView
    }

    func updateNSView(_ scrollView: TokenHostingScrollView<Content>, context: Context) {
        scrollView.onScrollActivityChanged = onScrollActivityChanged
        scrollView.updateRootView(content)
    }
}

final class TokenHostingScrollView<Content: View>: NSScrollView {
    private let hostingView: NSHostingView<Content>
    private var lastLaidOutWidth: CGFloat = 0
    private var cachedFittingHeight: CGFloat = 1
    private var needsFittingHeightUpdate = true
    private var isDeferringRootUpdates = false
    private var pendingRootView: Content?
    private var endScrollWorkItem: DispatchWorkItem?

    var onScrollActivityChanged: ((Bool) -> Void)?

    var rootView: Content {
        get { hostingView.rootView }
        set {
            updateRootView(newValue)
        }
    }

    func updateRootView(_ newRootView: Content) {
        if isDeferringRootUpdates {
            pendingRootView = newRootView
            return
        }

        applyRootView(newRootView)
    }

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollsDynamically = true
        usesPredominantAxisScrolling = true
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        wantsLayer = true
        layer?.drawsAsynchronously = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        contentView.drawsBackground = false
        contentView.wantsLayer = true
        contentView.layer?.drawsAsynchronously = true
        contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        hostingView.isFlipped = true
        hostingView.wantsLayer = true
        hostingView.layer?.drawsAsynchronously = true
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        documentView = hostingView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutHostingView()
    }

    override func scrollWheel(with event: NSEvent) {
        beginRootUpdateDeferral()
        super.scrollWheel(with: event)

        if event.phase == .ended || event.momentumPhase == .ended || event.phase == .cancelled {
            endRootUpdateDeferral()
        } else {
            scheduleRootUpdateDeferralEnd()
        }
    }

    @objc private func willStartLiveScroll() {
        beginRootUpdateDeferral()
    }

    @objc private func didEndLiveScroll() {
        endRootUpdateDeferral()
    }

    private func applyRootView(_ newRootView: Content) {
        hostingView.rootView = newRootView
        hostingView.invalidateIntrinsicContentSize()
        needsFittingHeightUpdate = true
        needsLayout = true
    }

    private func beginRootUpdateDeferral() {
        endScrollWorkItem?.cancel()
        endScrollWorkItem = nil

        guard !isDeferringRootUpdates else { return }
        isDeferringRootUpdates = true
        onScrollActivityChanged?(true)
    }

    private func scheduleRootUpdateDeferralEnd() {
        endScrollWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.endRootUpdateDeferral()
        }
        endScrollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func endRootUpdateDeferral() {
        endScrollWorkItem?.cancel()
        endScrollWorkItem = nil

        guard isDeferringRootUpdates else { return }
        isDeferringRootUpdates = false
        onScrollActivityChanged?(false)

        guard let pendingRootView else { return }
        self.pendingRootView = nil
        applyRootView(pendingRootView)
    }

    private func layoutHostingView() {
        let width = max(1, contentView.bounds.width)
        if abs(width - lastLaidOutWidth) > 0.5 {
            hostingView.setFrameSize(NSSize(width: width, height: max(1, hostingView.frame.height)))
            lastLaidOutWidth = width
            needsFittingHeightUpdate = true
        }

        if needsFittingHeightUpdate {
            cachedFittingHeight = max(1, hostingView.fittingSize.height)
            needsFittingHeightUpdate = false
        }

        let fittingHeight = max(contentView.bounds.height, cachedFittingHeight)
        let newFrame = NSRect(x: 0, y: 0, width: width, height: fittingHeight)
        if hostingView.frame.integral != newFrame.integral {
            hostingView.frame = newFrame
        }
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
