import Foundation
import SwiftUI
import TokenMeterCore

struct SectionSelector: View {
    let selection: DashboardSection
    let onSelect: (DashboardSection) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashboardSection.allCases) { section in
                Button {
                    onSelect(section)
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: TokenMeterTheme.compactControlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .foregroundStyle(selection == section ? TokenMeterTheme.primaryText : TokenMeterTheme.secondaryText)
                .background {
                    if selection == section {
                        TokenControlChrome(
                            isActive: true,
                            cornerRadius: TokenMeterTheme.compactControlRadius
                        )
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: TokenMeterTheme.compactControlRadius, style: .continuous))
            }
        }
        .padding(3)
        .frame(height: TokenMeterTheme.buttonHeight)
        .background {
            TokenControlChrome()
        }
    }
}

struct UpdateAvailableBanner: View {
    @EnvironmentObject private var updates: UpdateModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TokenMeterTheme.accent)
            Text(updates.statusText)
                .font(.system(size: 13))
                .foregroundStyle(TokenMeterTheme.primaryText)
            Spacer()
            Button(updateButtonTitle) {
                updates.updateNow()
            }
            .buttonStyle(TokenPillButtonStyle(prominent: true))
            .disabled(updates.isChecking || updates.isDownloading || updates.isInstalling)
            Button("Details") {
                updates.isSheetPresented = true
            }
            .buttonStyle(TokenPillButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .tokenSurface(elevated: true)
    }

    private var updateButtonTitle: String {
        if updates.isInstalling {
            return "Installing..."
        }
        if updates.isDownloading {
            return "Updating..."
        }
        return "Update Now"
    }
}

struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    private let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TokenMeterTheme.secondaryText)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TokenMeterTheme.primaryText)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background {
                    TokenControlChrome(cornerRadius: TokenMeterTheme.cardRadius)
                }
                .contentShape(RoundedRectangle(cornerRadius: TokenMeterTheme.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.horizontal, 1)
            }
        }
    }
}

struct ComponentBreakdown: View {
    let usage: TokenUsage
    let source: TokenSource
    let numberFormat: TokenNumberFormat

    var body: some View {
        let components = usage.displayComponents(source: source)
        let total = max(1, components.reduce(0.0) { $0 + Double(max(0, $1.value)) })

        VStack(alignment: .leading, spacing: 8) {
            if components.isEmpty {
                Text("No token breakdown")
                    .font(.system(size: 12))
                    .foregroundStyle(TokenMeterTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(components, id: \.kind) { component in
                            Rectangle()
                                .fill(componentColor(component.kind))
                                .frame(width: proxy.size.width * CGFloat(Double(component.value) / total))
                        }
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .frame(height: 10)

                HStack(spacing: 16) {
                    ForEach(components, id: \.kind) { component in
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(componentColor(component.kind))
                                .frame(width: 10, height: 8)
                            Text(component.kind.rawValue)
                                .foregroundStyle(TokenMeterTheme.secondaryText)
                            Text(TokenFormatters.tokens(component.value, format: numberFormat))
                                .monospacedDigit()
                                .foregroundStyle(TokenMeterTheme.primaryText)
                        }
                    }
                    Spacer()
                }
                .font(.system(size: 12))
            }
        }
        .padding(14)
        .tokenSurface()
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TokenMeterTheme.primaryText)
    }
}

func shortProject(_ path: String) -> String {
    if path == "All Projects" || path == "Unknown" {
        return path
    }
    return URL(fileURLWithPath: path).lastPathComponent
}

func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home {
        return "~"
    }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
