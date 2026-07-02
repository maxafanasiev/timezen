import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.lockEnabled && !state.isUnlocked {
            LockView()
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
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

/// Full-screen lock shown when biometric/passcode protection is enabled.
struct LockView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Timezen is locked").font(.title3.weight(.semibold))
            Button {
                Task { await state.unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await state.unlock() }   // prompt automatically on appear
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: Int = MainTabView.initialTab

    var body: some View {
        if horizontalSizeClass == .regular {
            sidebarLayout        // iPad / large: sidebar + detail
        } else {
            tabLayout            // iPhone: bottom tab bar
        }
    }

    private var tabLayout: some View {
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

    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Label("Timer", systemImage: "timer").tag(0)
                Label("Dashboard", systemImage: "chart.bar.xaxis").tag(1)
                Label("Settings", systemImage: "gearshape").tag(2)
            }
            .navigationTitle("Timezen")
        } detail: {
            switch selection {
            case 1: DashboardView()
            case 2: SettingsView()
            default: HomeView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarSelection: Binding<Int?> {
        Binding(get: { selection }, set: { if let value = $0 { selection = value } })
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
