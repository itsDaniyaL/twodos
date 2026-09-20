import SwiftUI

/// The middle column: every list, grouped the way iOS groups them.
///
/// A `List` with real selection rather than the iOS card grid. Cards suit a
/// thumb reaching across a phone; a desktop list is scannable, keyboard
/// navigable with the arrow keys for free, and lets the selected row stay
/// visibly selected while the detail column changes — which is the whole point
/// of a three-column window.
struct MacListsPane: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: String?
    var query: String

    @State private var isCreatingList = false

    var body: some View {
        Group {
            if !store.hasLoadedLists {
                MacLoadingView(message: "Loading your lists…")
            } else if visibleLists.isEmpty && store.pendingInvites.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    if !store.pendingInvites.isEmpty && query.isEmpty {
                        Section("Invitations") {
                            ForEach(store.pendingInvites) { list in
                                MacInviteRow(list: list)
                            }
                        }
                    }

                    Section(query.isEmpty ? "Lists" : "Results") {
                        ForEach(visibleLists) { list in
                            MacListRow(list: list).tag(list.id)
                        }
                    }

                    if !store.archivedLists.isEmpty && query.isEmpty {
                        Section("Archived") {
                            ForEach(store.archivedLists) { list in
                                MacListRow(list: list).tag(list.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Lists")
        .sheet(isPresented: $isCreatingList) { MacNewListSheet() }
    }

    /// Matches a list by its own name or by anything written in it, so a search
    /// finds "milk" in a list called "Tesco".
    private var visibleLists: [TodoList] {
        guard !query.isEmpty else { return store.activeLists }
        let needle = query.lowercased()
        return store.activeLists.filter { list in
            list.label.lowercased().contains(needle)
                || list.todos.contains { $0.title.lowercased().contains(needle) }
        }
    }

    private var emptyState: some View {
        MacEmptyState(
            illustration: query.isEmpty ? .handsBright : nil,
            icon: query.isEmpty ? nil : "magnifyingglass",
            title: query.isEmpty ? "No lists yet" : "Nothing matches",
            message: query.isEmpty
                ? "Start one for yourself, or share it with somebody and you'll both see every change straight away."
                : "No list or task matches “\(query)”.",
            actionTitle: query.isEmpty ? "New List" : nil,
            action: query.isEmpty ? { isCreatingList = true } : nil
        )
    }
}

/// One list.
struct MacListRow: View {
    @Environment(AppStore.self) private var store
    let list: TodoList

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(list.tint.color)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if list.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Brand.lime)
                            .accessibilityLabel("Favourite")
                    }
                    Text(list.label).lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if let partner = store.partner(id: partnerId) {
                MacAvatar(partner: partner, size: 22)
            }
        }
        .padding(.vertical, 3)
        // Everything the iOS swipe actions offer, because a mouse cannot
        // swipe — this is the Mac's entire route to these commands.
        .contextMenu {
            Button(list.favorite ? "Remove from Favourites" : "Add to Favourites") {
                Task { await store.toggleFavorite(id: list.id) }
            }
            Button(list.archived ? "Unarchive" : "Archive") {
                Task { await store.archiveList(id: list.id, archived: !list.archived) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await store.deleteList(id: list.id) }
            }
        }
    }

    private var partnerId: String? {
        guard list.hasPartner else { return nil }
        return list.partnerId == store.currentUserId ? list.createdBy : list.partnerId
    }

    private var subtitle: String {
        guard list.totalCount > 0 else { return "Empty" }
        return "\(list.completedCount) of \(list.totalCount) done"
    }
}

/// A list somebody has offered to share, which has to be answered before it
/// becomes a list at all.
struct MacInviteRow: View {
    @Environment(AppStore.self) private var store
    let list: TodoList

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .foregroundStyle(Brand.info)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(list.label).lineLimit(1)
                Text(invitedBy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button("Join") { Task { await store.respondToInvite(listId: list.id, accept: true) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Decline") { Task { await store.respondToInvite(listId: list.id, accept: false) } }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private var invitedBy: String {
        guard let partner = store.partner(id: list.createdBy) else { return "Shared with you" }
        return "From \(partner.displayName)"
    }
}

/// Initials, or the picture when the person has one.
struct MacAvatar: View {
    let partner: Partner
    var size: CGFloat = 24

    var body: some View {
        AsyncImage(url: partner.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .overlay {
                    Text(partner.initials)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .help(partner.displayName)
        .accessibilityLabel(partner.displayName)
    }
}
