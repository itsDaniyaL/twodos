import SwiftUI
import UIKit
import CoreSpotlight
import FirebaseAnalytics
import FirebaseCore

/// Exists only for the two remote-notification callbacks, and to start Firebase.
///
/// SwiftUI has no equivalent hook: `didRegisterForRemoteNotifications` is
/// delivered to the application delegate and nowhere else, so push cannot work
/// without one.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Analytics and Crashlytics only.
    ///
    /// **Not push.** Apple platforms register with APNs directly and the server
    /// sends to APNs directly — `PushService` reserves FCM for Android. Adding
    /// `FirebaseMessaging` here would put a second, competing registration path
    /// in front of the one that works.
    ///
    /// `configure()` has to run before anything reads a Firebase API, and this
    /// is the earliest hook a SwiftUI app has.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Absent in a checkout without the plist, and a missing analytics SDK is
        // not worth crashing a to-do list over.
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()

            // Analytics is linked but nothing in the app calls it, so without an
            // explicit reference the linker strips it and it silently never
            // starts — the symptom is Crashlytics reporting and Analytics
            // showing no traffic at all. One real call keeps it in.
            Analytics.setAnalyticsCollectionEnabled(true)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushRegistrationService.shared.handle(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Task { @MainActor in PushRegistrationService.shared.handle(error: error) }
    }
}

@main
struct TwodosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // A tapped Spotlight result. Routed through the same
                    // `DeepLink` channel as a widget tap so there is one way
                    // into a list, not several kept behaving alike.
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    store.handle(deepLink: SpotlightIndexer.deepLink(forSearchableItemID: id))
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
