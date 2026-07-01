import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.phase {
        case .launching:
            LaunchView()
        case .loggedOut:
            LoginView()
        case .ready:
            MainTabView()
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
            ProgressView()
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: Int = MainTabView.initialTab

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Timer", systemImage: "timer") }
                .tag(0)

            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                .tag(1)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
    }

    /// DEBUG convenience: preselect a tab via the ST_TAB env var when driving the Simulator.
    private static var initialTab: Int {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ST_TAB"] {
        case "dashboard": return 1
        case "settings": return 2
        default: return 0
        }
        #else
        return 0
        #endif
    }
}
