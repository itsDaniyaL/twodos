import SwiftUI
import AppKit
import CoreSpotlight

/// Exists for the two remote-notification callbacks, which AppKit delivers to
/// the application delegate and nowhere else.
///
/// Firebase is deliberately absent, unlike the iOS delegate: analytics on a
/// desktop build nobody has shipped yet would be measuring an empty room, and
/// the SDK is one more thing to sign and sandbox.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistrationService.shared.handle(deviceToken: deviceToken) }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Task { @MainActor in PushRegistrationService.shared.handle(error: error) }
    }

    /// Closing the last window on a Mac hides the app; it does not quit it.
    /// Returning false is the Mail and Notes behaviour, and it is what keeps
    /// the socket connected and reminders arriving while no window is open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The Mac app.
///
/// Shares every line of its state with iOS — `AppStore` and the services around
/// it live in `AppCore/`, which both targets compile — so the two cannot drift
/// in behaviour. What differs here is only the presentation, which is the part
/// that *should* differ: a Mac gets a sidebar and a menu bar, not a tab bar.
@main
struct TwodosMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    @State private var store = AppStore()
    @State private var theme = ThemeStore.shared
    @State private var notificationSettings = NotificationSettingsStore.shared
    @State private var notifications = NotificationService.shared
    @State private var location = LocationService.shared
    @State private var commands = MacCommands()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // `.themed()` reads ThemeStore from the environment, so it sits
            // *inside* the injections — a modifier applied later becomes an
            // ancestor, and an ancestor cannot see what a descendant provides.
            MacRootView()
                .themed()
                .environment(store)
                .environment(theme)
                .environment(notificationSettings)
                .environment(notifications)
                .environment(location)
                .environment(commands)
                .task { await store.start() }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    store.handle(deepLink: SpotlightIndexer.deepLink(forSearchableItemID: id))
                }
                .onOpenURL { url in
                    store.handle(deepLink: DeepLink(url: url))
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await store.handleForeground() }
                    } else {
                        Task { await store.commitPendingDeletion() }
                    }
                }
        }
        // A Mac window opens at a size the app chooses and the user then owns.
        // The minimum is what the split view needs before the sidebar and the
        // detail pane start fighting over the same pixels.
        .defaultSize(width: 1_080, height: 720)
        .windowToolbarStyle(.unified)
        .commands { MacMenuCommands(commands: commands, isSignedIn: store.phase == .signedIn) }

        // ⌘, — the Mac's preferences window. On iOS these same screens are rows
        // inside the profile tab; here they belong in the place every Mac user
        // already knows to look, which is why the sidebar has no Settings item.
        Settings {
            MacSettingsWindow()
                .themed()
                .environment(store)
                .environment(theme)
                .environment(notificationSettings)
                .environment(notifications)
        }
    }
}
