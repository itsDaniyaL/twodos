import SwiftUI

@main
struct TwodosApp: App {
    @State private var store = AppStore()
    @State private var theme = ThemeStore.shared
    @State private var notificationSettings = NotificationSettingsStore.shared
    @State private var notifications = NotificationService.shared
    @State private var location = LocationService.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // `.themed()` reads ThemeStore from the environment, so it must sit
            // *inside* the injections — modifiers applied later become
            // ancestors, and an ancestor cannot see what a descendant provides.
            RootView()
                .themed()
                .environment(store)
                .environment(theme)
                .environment(notificationSettings)
                .environment(notifications)
                .environment(location)
                .task {
                    Haptics.prepare()
                    if let t = ProcessInfo.processInfo.environment["TWODOS_DEBUG_TOKEN"] { // TEMPX
                        TokenStore.shared.save(AuthSession(token: t, expiresAt: .now.addingTimeInterval(3000), refreshToken: nil, refreshExpiresAt: nil))
                    }
                    await store.start()
                    if let l = ProcessInfo.processInfo.environment["TWODOS_OPEN_LIST"] { // TEMPX
                        try? await Task.sleep(for: .seconds(1)); store.pendingListToOpen = l
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the background is the moment to re-check
                    // permissions (the user may have changed them in Settings)
                    // and to reconcile with anything that happened while away.
                    if phase == .active {
                        Task { await store.handleForeground() }
                    }
                }
        }
    }
}
