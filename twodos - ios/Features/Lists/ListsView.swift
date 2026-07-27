import SwiftUI

enum ListRoute: Hashable {
    case detail(String)
}

/// The home screen: every list, sorted the way the user asked for, with
/// pending invites surfaced above them.
struct ListsView: View {
    @Binding var path: NavigationPath
    @Environment(AppStore.self) private var store

    @State private var showingCreateSheet = false
    @State private var showingSortMenu = false
    @Namespace private var cardNamespace

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ScreenBackground()
                content
            }
            .navigationTitle("Lists")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .navigationDestination(for: ListRoute.self) { route in
                switch route {
                case .detail(let id):
                    ListDetailView(listId: id)
                        .navigationTransition(.zoom(sourceID: id, in: cardNamespace))
                }
            }
            .refreshable { await store.refreshAll() }
            .sheet(isPresented: $showingCreateSheet) {
                CreateListSheet()
            }
            .sheet(isPresented: $showingSortMenu) {
                SortSheet(selection: Binding(
                    get: { store.sortOrder },
                    set: { store.sortOrder = $0 }
                ))
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !store.hasLoadedLists {
            LoadingView(message: "Loading your lists…")
        } else if isCompletelyEmpty {
            EmptyStateView(
                icon: "checklist",
                title: "No lists yet",
                message: "Make a list for yourself, or share one with someone and you'll both see every change.",
                actionTitle: "Create your first list",
                action: { showingCreateSheet = true }
            )
        } else {
            listScroll
        }
    }

    private var listScroll: some View {
        ScrollView {
            LazyVStack(spacing: Metrics.rowSpacing) {
                invitesSection

                ForEach(displayedLists) { list in
                    ListCard(
                        list: list,
                        partner: store.partner(id: list.partnerId),
                        currentUserId: store.currentUserId,
                        matchedID: list.id,
                        namespace: cardNamespace
                    ) {
                        path.append(ListRoute.detail(list.id))
                    }
                    .transition(.rowInsertion)
                }

                if !store.archivedLists.isEmpty {
                    archivedSection
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 100)
            .motion(Motion.content, value: displayedLists.map(\.id))
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder
    private var invitesSection: some View {
        if !store.pendingInvites.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(
                    title: "Invitations",
                    count: store.pendingInvites.count,
                    icon: "envelope.badge"
                )
                ForEach(store.pendingInvites) { list in
                    InviteCard(
                        list: list,
                        fromName: store.partner(id: list.createdBy)?.displayName
                    )
                    .transition(.rowInsertion)
                }
            }
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.content) { store.showArchived.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(store.showArchived ? 90 : 0))
                    Text("Archived")
                        .font(.footnote.weight(.semibold))
                    Text("\(store.archivedLists.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived lists, \(store.archivedLists.count)")
            .accessibilityHint(store.showArchived ? "Collapses the section" : "Expands the section")

            if store.showArchived {
                ForEach(store.archivedLists) { list in
                    ListCard(
                        list: list,
                        partner: store.partner(id: list.partnerId),
                        currentUserId: store.currentUserId,
                        matchedID: list.id,
                        namespace: cardNamespace
                    ) {
                        path.append(ListRoute.detail(list.id))
                    }
                    .transition(.rowInsertion)
                }
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSortMenu = true
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort lists, currently \(store.sortOrder.title)")
        }

        // iOS 26: a spacer splits the toolbar into separate glass groups so the
        // primary action reads as distinct from the secondary one.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingCreateSheet = true
                Haptics.medium()
            } label: {
                Label("New list", systemImage: "plus")
            }
        }
    }

    // MARK: - Data

    private var isCompletelyEmpty: Bool {
        store.lists.isEmpty
    }

    /// Search moved to its own tab — see ``SearchView``.
    private var displayedLists: [TodoList] { store.activeLists }
}

// MARK: - Section label

struct SectionLabel: View {
    var title: String
    var count: Int?
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
