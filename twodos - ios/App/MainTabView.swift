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
        .onChange(of: store.pendingListToOpen) { _, listId in
            // A notification tap or deep link asked for a specific list.
            guard let listId else { return }
            selection = .lists
            listsPath = NavigationPath()
            listsPath.append(ListRoute.detail(listId))
            store.pendingListToOpen = nil
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
