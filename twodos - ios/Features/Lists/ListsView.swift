import SwiftUI

enum ListRoute: Hashable {
    case detail(String)
}

/// The home screen: every list, sorted the way the user asked for, with
/// pending invites surfaced above them.
struct ListsView: View {
    @Binding var path: [ListRoute]
    @Environment(AppStore.self) private var store
    /// iPad and a landscape iPhone Pro Max get a sidebar; everything else keeps
    /// the stack. Read rather than assumed, so a Slide Over window — which is
    /// compact on an iPad — gets the phone layout it actually has room for.
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showingCreateSheet = false
    @State private var showingSortMenu = false
    @Namespace private var cardNamespace

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        // ## Why the sheets live here and not in each layout
        // They used to be attached to `stackLayout` only. Both layouts share
        // `toolbar`, so on iPad the Sort and New list buttons set their flags
        // and nothing presented — the buttons looked live, took the tap, and did
        // nothing. "Create your first list" in the empty state was dead for the
        // same reason.
        //
        // Attaching them to the branch instead of to the thing that owns the
        // state is what made that possible, so the fix is structural: there is
        // now one place to attach a presentation, and it cannot be reached by
        // one layout and missed by the other.
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

    /// iPad: lists on the left, the open list beside them.
    ///
    /// This is the whole reason to treat a tablet differently. A shared list is
    /// something two people edit while talking about it, and the tablet is the
    /// device that is usually on the table between them — losing sight of every
    /// other list the moment you open one is exactly the wrong trade there.
    private var splitLayout: some View {
        NavigationSplitView {
            ZStack {
                ScreenBackground()
                content
            }
            .navigationTitle("Lists")
            .toolbar { toolbar }
        } detail: {
            if case .detail(let id) = path.last {
                ListDetailView(listId: id) { path = [] }
            } else {
                ZStack {
                    ScreenBackground()
                    EmptyStateView(
                        icon: "sidebar.left",
                        title: "Pick a list",
                        message: "Choose one on the left, or make a new one."
                    )
                }
            }
        }
    }

    private var stackLayout: some View {
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
                        namespace: cardNamespace,
                        isSelected: isShowingInDetail(list.id)
                    ) {
                        open(list.id)
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
        // On the scroll view rather than on the stack's container, so the
        // sidebar column pulls to refresh too. It only worked on iPhone before.
        .refreshable { await store.refreshAll() }
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
                        namespace: cardNamespace,
                        isSelected: isShowingInDetail(list.id)
                    ) {
                        open(list.id)
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

    /// Opening a list means the same thing in both layouts: it becomes the last
    /// thing on the path. The stack pushes it; the split view shows it.
    private func open(_ listId: String) {
        path = [.detail(listId)]
    }

    /// Only ever true in the split layout. On the phone the pushed screen covers
    /// the sidebar, so marking a card behind it would be marking something
    /// nobody can see.
    private func isShowingInDetail(_ listId: String) -> Bool {
        guard sizeClass == .regular, case .detail(let open) = path.last else { return false }
        return open == listId
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
    var title: LocalizedStringKey
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
