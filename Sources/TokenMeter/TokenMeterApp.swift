import SwiftUI
import TokenMeterCore

@main
struct TokenMeterApp: App {
    @StateObject private var model = DashboardModel()
    @StateObject private var updates = UpdateModel()

    var body: some Scene {
        WindowGroup("TokenMeter", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .environmentObject(updates)
                .preferredColorScheme(.dark)
                .tint(TokenMeterTheme.accent)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Data") {
                Button("Refresh") {
                    model.refresh(restartInProgress: true)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
