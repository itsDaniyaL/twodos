import SwiftUI
import WatchKit

@main
struct TwodosWatchApp: App {
    @State private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .tint(Brand.meadow)
                .task { await store.start() }
                .onOpenURL { url in
                    store.handle(deepLink: DeepLink(url: url))
                }
        }

        // One scene per category the phone registers. watchOS routes a mirrored
        // notification to whichever matches, and falls back to its own default
        // look for anything unlisted — so a new category on the phone degrades
        // to the system card rather than showing nothing.
        WKNotificationScene(controller: WatchNotificationController.self,
                            category: NotificationKind.deadline.identifier)
        WKNotificationScene(controller: WatchNotificationController.self,
                            category: NotificationKind.alarm.identifier)
        WKNotificationScene(controller: WatchNotificationController.self,
                            category: NotificationKind.geofence.identifier)
        WKNotificationScene(controller: WatchNotificationController.self,
                            category: NotificationKind.social.identifier)
    }
}

/// Routes between "the phone hasn't set us up yet" and the app proper.
struct WatchRootView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        switch store.phase {
        case .loading:
            LoadingScreen()
        case .needsPhone, .sessionExpired:
            PhoneNeededScreen(reason: store.phase)
        case .ready:
            WatchListsView()
        }
    }
}

private struct LoadingScreen: View {
    var body: some View {
        VStack(spacing: 10) {
            TwodosMark(tickStyle: AnyShapeStyle(Brand.meadow))
                .frame(width: 30, height: 30)
            ProgressView()
        }
    }
}

/// Shown when the watch has no usable session.
///
/// It says what to do and nothing else. There is no sign-in form here on
/// purpose: typing an email and password on a watch is miserable, and the phone
/// hands the session over automatically the moment it is unlocked.
private struct PhoneNeededScreen: View {
    let reason: WatchStore.Phase
    @Environment(WatchStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TwodosMark(tickStyle: AnyShapeStyle(Brand.meadow))
                    .frame(width: 34, height: 34)
                    .padding(.top, 8)

                Text(reason == .sessionExpired ? "Signed out" : "Open twodos on iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(reason == .sessionExpired
                     ? "Your session ran out. Open twodos on your iPhone to sign back in."
                     : "Sign in on your iPhone once and your lists will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try again") {
                    Task { await store.start() }
                }
                .buttonStyle(.bordered)
                .tint(Brand.meadow)
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }
}
