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
                    await store.start()
                }
                .onOpenURL { url in
                    // A widget tap. The intent goes through the same
                    // `pendingListToOpen` channel a notification tap uses, so
                    // there is one path into a list rather than two that have to
                    // be kept behaving alike.
                    store.handle(deepLink: DeepLink(url: url))
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the background is the moment to re-check
                    // permissions (the user may have changed them in Settings)
                    // and to reconcile with anything that happened while away.
                    if phase == .active {
                        Task { await store.handleForeground() }
                    } else {
                        // A suspended app's timer may never fire, and a deletion
                        // the user watched happen must not quietly come back.
                        Task { await store.commitPendingDeletion() }
                    }
                }
        }
    }
}
