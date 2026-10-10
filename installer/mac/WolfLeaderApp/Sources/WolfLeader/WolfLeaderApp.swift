import SwiftUI

@main
struct WolfLeaderApp: App {
    @StateObject private var themes = ThemeStore()
    @StateObject private var store = ConfigStore()

    var body: some Scene {
        WindowGroup("Wolf Leader") {
            RootView()
                .environmentObject(themes)
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
    }
}

/// Shows first-launch setup until it's done, then the main window.
/// No background here: the native sidebar is translucent glass and each screen
/// paints its own `p.background`.
struct RootView: View {
    @EnvironmentObject private var themes: ThemeStore
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let p = themes.palette(for: systemScheme)
        Group {
            if !store.config.setupComplete || store.showOnboarding {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .environment(\.palette, p)
        .preferredColorScheme(themes.themeID == .system ? nil : p.scheme)
        .tint(p.accent)
    }
}
