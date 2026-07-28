import SwiftUI

/// The signed-in shell.
///
/// Four destinations, which is the sweet spot for a tab bar: any fewer and it
/// is not worth the chrome, any more and the labels stop being readable.
/// Alarms and Notifications used to be icons buried in the Flutter app's
/// navigation bar; giving them real tabs makes them discoverable and lets the
/// notification badge live where iOS users look for it.
struct MainTabView: View {
    @Environment(AppStore.self) private var store
    /// Requests arriving from Siri and Shortcuts, which may run before this view
    /// exists.
    @State private var intentNavigation = IntentNavigation.shared

    @State private var selection: Tabs = .lists
    /// Bumped to pop a tab's navigation stack when its tab is re-tapped.
    @State private var listsPath = NavigationPath()

    enum Tabs: Hashable {
        case lists, alarms, activity, profile, search
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Lists", systemImage: "checklist", value: Tabs.lists) {
                ListsView(path: $listsPath)
            }

            Tab("Alarms", systemImage: "alarm", value: Tabs.alarms) {
                AlarmsView()
            }

            Tab("Activity", systemImage: "bell", value: Tabs.activity) {
                ActivityView()
            }
            .badge(store.unreadNotificationCount)

            Tab("You", systemImage: "person.crop.circle", value: Tabs.profile) {
                ProfileView()
            }

            // `role: .search` is what detaches this from the other four and
            // parks it on the trailing edge — it reads as a tool applied to the
            // app rather than a fifth place to be, which is exactly what it is.
            // Declared last because the role decides placement, not the order.
            Tab(value: Tabs.search, role: .search) {
                SearchView()
            }
        }
        // iOS 26: the tab bar shrinks out of the way as content scrolls up,
        // giving the glass cards the full height of the display.
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) { globalBanner }
        .overlay(alignment: .bottom) { undoBanner }
        // "Open my shopping list" may have run before this view existed, so the
        // request is drained on appear as well as on change.
        .task(id: intentNavigation.pending) {
            guard let link = intentNavigation.take() else { return }
            store.handle(deepLink: link)
        }
        // `task(id:)` rather than `onChange`, because a cold launch from a
        // widget tap sets the intent *before* this view exists — `onChange`
        // only fires for changes it was mounted to witness, so the first and
        // most important tap of a session was the one it missed.
        .task(id: store.pendingListToOpen) {
            // A notification tap, widget tap, or Shortcut asked for a list.
            guard let listId = store.pendingListToOpen else { return }
            selection = .lists
            listsPath = NavigationPath()
            listsPath.append(ListRoute.detail(listId))
            store.pendingListToOpen = nil
        }
    }

    /// The window to take back a deletion.
    ///
    /// Sits at the bottom, above the tab bar, because that is where the thumb
    /// already is after a swipe — an undo the user has to reach to the top of
    /// the screen for is one they will not take in five seconds.
    ///
    /// It carries no dismiss button on purpose: dismissing and letting it expire
    /// do the same thing, and a second control would only make the user wonder
    /// whether one of them cancels the deletion.
    @ViewBuilder
    private var undoBanner: some View {
        if let prompt = store.undoPrompt {
            InlineBanner(
                kind: .info,
                title: prompt.title,
                message: prompt.message,
                actionTitle: "Undo",
                action: { store.undoDeletion() }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 76)
            .transition(.banner)
            .motion(Motion.content, value: prompt.id)
        }
    }

    /// App-wide errors surface here rather than as alerts, so a failed refresh
    /// never blocks what the user was doing. It dismisses itself.
    @ViewBuilder
    private var globalBanner: some View {
        if let banner = store.banner {
            InlineBanner(
                kind: banner.kind,
                title: banner.title,
                message: banner.message,
                onDismiss: { store.dismissBanner() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .transition(.banner)
            .task(id: banner.id) {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                store.dismissBanner()
            }
            .motion(Motion.content, value: banner.id)
        }
    }
}
