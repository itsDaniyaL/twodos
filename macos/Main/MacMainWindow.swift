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

                Button { Task { await store.refreshAll() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                .disabled(store.isRefreshing)
            }
        }
        .sheet(isPresented: $isCreatingList) { MacNewListSheet() }
        // The menu bar talks to the window through counters rather than
        // focused values — see `MacCommands` for why.
        .onChange(of: commands.newListRequests) { _, _ in isCreatingList = true }
        .onChange(of: commands.refreshRequests) { _, _ in Task { await store.refreshAll() } }
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
