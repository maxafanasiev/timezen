import SwiftUI

@main
struct TimezenApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .task { await state.bootstrap() }
                .tint(.accentColor)
                .preferredColorScheme(state.appearance.colorScheme)
        }
    }
}
