import SwiftUI

@main
struct TimezenApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .task { await state.bootstrap() }
                .tint(.accentColor)
                .preferredColorScheme(state.appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { state.lockNow() }
                    // Coming back: pick up projects/entries changed elsewhere (web UI, other device).
                    if phase == .active { Task { await state.refreshOnForeground() } }
                }
        }
    }
}
