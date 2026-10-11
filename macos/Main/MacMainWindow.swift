import SwiftUI

/// The signed-in window.
///
/// Three columns, the shape Mail and Notes use: what kind of thing you are
/// looking at, which one, and the thing itself. iOS puts the first of those in
/// a tab bar across the bottom, which is right for a thumb and wrong for a
/// window — a sidebar is always visible, so moving between sections costs no
/// navigation and the app never hides where you are.
///
/// Search is in the toolbar rather than being a fifth section, because on a Mac
/// ⌘F focuses a field; it does not take you somewhere.
struct MacMainWindow: View {
    @Environment(AppStore.self) private var store
    @Environment(MacCommands.self) private var commands

    @State private var section: MacSection? = .lists
    @State private var selectedListId: String?
    @State private var query = ""
    @State private var isCreatingList = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// Set only by Refresh, never by the store's background refreshes, so the
    /// toolbar spins for the thing the user asked for and nothing else.
    @State private var isRefreshingWindow = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(section: $section)
                .navigationSplitViewColumnWidth(
                    min: MacMetrics.sidebarMin,
                    ideal: MacMetrics.sidebarIdeal,
                    max: 320
                )
        } content: {
            content
                .navigationSplitViewColumnWidth(min: MacMetrics.contentMin, ideal: 460)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: MacMetrics.detailMin, ideal: 520)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search lists and tasks")
        .toolbar {
            ToolbarItemGroup {
                Button { isCreatingList = true } label: {
                    Label("New List", systemImage: "plus")
                }
                .help("New list (⌘N)")

                Button { Task { await refreshVisible() } } label: { refreshLabel }
                    .help("Refresh (⌘R)")
                    .disabled(isRefreshingWindow)
            }
        }
        .sheet(isPresented: $isCreatingList) { MacNewListSheet() }
        // The menu bar talks to the window through counters rather than
        // focused values — see `MacCommands` for why.
        .onChange(of: commands.newListRequests) { _, _ in isCreatingList = true }
        .onChange(of: commands.refreshRequests) { _, _ in Task { await refreshVisible() } }
        .onChange(of: commands.focusSearchRequests) { _, _ in searchFocused = true }
        .onChange(of: commands.sectionRequest) { _, request in
            guard let request else { return }
            section = request.section
        }
        // Keeps "New Item" in the File menu enabled only when there is a list
        // to put one in.
        .onChange(of: selectedListId, initial: true) { _, id in commands.openListId = id }
        .onChange(of: store.pendingListToOpen) { _, id in
            guard let id else { return }
            section = .lists
            selectedListId = id
            store.pendingListToOpen = nil
        }
    }

    /// A small spinner in the button's own place while it works, the way
    /// Mail's Get Mail button does — a greyed-out arrow alone does not say
    /// anything is happening.
    @ViewBuilder
    private var refreshLabel: some View {
        if isRefreshingWindow {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Refreshing")
        } else {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    /// Refreshes what the window is showing, the way ⌘R does in Mail.
    ///
    /// `refreshAll` covers lists, partners, the activity feed and sent
    /// invites — but not alarms, blocked people, or the challenge on the open
    /// list, so the section on screen decides what comes along with it. iOS's
    /// ⌘R makes the same choice per tab.
    private func refreshVisible() async {
        guard !isRefreshingWindow else { return }
        isRefreshingWindow = true
        defer { isRefreshingWindow = false }

        async let everything: Void = store.refreshAll()
        switch section {
        case .alarms:
            await store.refreshAlarms()
        case .partners:
            await store.refreshBlockedUsers()
        case .lists:
            if let id = selectedListId {
                // Errors reported for the open list: this refresh was asked for.
                async let items: Void = store.refreshList(id: id, reportErrors: true)
                async let challenge: Void = store.refreshChallenge(listId: id)
                _ = await (items, challenge)
            }
        case .activity, nil:
            break
        }
        await everything
    }

    @ViewBuilder
    private var content: some View {
        switch section ?? .lists {
        case .lists:    MacListsPane(selection: $selectedListId, query: query)
        case .alarms:   MacAlarmsPane()
        case .activity: MacActivityPane()
        case .partners: MacPartnersPane()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if section == .lists, let id = selectedListId, let list = store.list(id: id) {
            MacListDetailPane(list: list)
        } else if section == .lists {
            MacEmptyState(
                icon: "sidebar.squares.left",
                title: "No list selected",
                message: "Pick a list on the left, or press ⌘N to start a new one."
            )
        } else {
            // The other three sections are self-contained: their content column
            // *is* the thing, so a third column would be an empty panel taking
            // a third of the window.
            MacEmptyState(
                icon: section?.icon ?? "checklist",
                title: section?.title ?? "",
                message: "Select an item to see more."
            )
        }
    }
}

/// The section list.
///
/// Badged the way Mail badges unread counts, because "you have things waiting"
/// is the one piece of state worth carrying into a collapsed sidebar.
struct MacSidebar: View {
    @Environment(AppStore.self) private var store
    @Binding var section: MacSection?

    var body: some View {
        List(selection: $section) {
            Section("twodos") {
                ForEach(MacSection.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("twodos")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacAccountFooter()
        }
    }

    private func badge(for section: MacSection) -> Int {
        switch section {
        case .lists:    store.pendingInvites.count
        case .alarms:   store.upcomingAlarms.count
        case .activity: store.unreadNotificationCount
        case .partners: 0
        }
    }
}

/// Who is signed in, pinned under the sections, the way Music and the App
/// Store show the account at the foot of their sidebars.
///
/// Settings still lives behind ⌘, — this is the visible way in for anyone who
/// has not learned that, and clicking your own name opens it on Account.
struct MacAccountFooter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MacSettingsTab.storageKey) private var settingsTab: MacSettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    open(.account)
                } label: {
                    HStack(spacing: 8) {
                        avatar
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if let detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Your profile and account")

                Button {
                    open(.general)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func open(_ tab: MacSettingsTab) {
        settingsTab = tab
        openSettings()
    }

    private var displayName: String {
        if let name = store.user?.name, !name.isEmpty { return name }
        return store.user?.email ?? String(localized: "Account")
    }

    /// The handle when there is one, otherwise the email — whichever the name
    /// line is not already showing.
    private var detail: String? {
        if let handle = store.user?.handle { return handle }
        guard let email = store.user?.email, email != displayName else { return nil }
        return email
    }

    private var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var avatar: some View {
        AsyncImage(url: store.user?.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .overlay {
                    Text(initials)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
        }
        .frame(width: 26, height: 26)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
