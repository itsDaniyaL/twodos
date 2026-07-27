import SwiftUI

/// Search, as its own tab.
///
/// It used to be a `.searchable` field in the Lists navigation bar, which cost
/// the home screen a permanent row of chrome for something used occasionally.
/// As a tab it is always one thumb-reach away and the home app bar gets the
/// space back — and iOS 26 renders a `.search`-role tab detached from the rest,
/// so it reads as a tool rather than as a fifth destination.
///
/// The results are split by *what* matched. Searching "milk" and being handed
/// the Groceries list is right, but it does not tell you the match was an item
/// inside it rather than the name — so items say which list they belong to and
/// show their own text.
struct SearchView: View {
    @Environment(AppStore.self) private var store

    @State private var query = ""
    @State private var path = NavigationPath()
    @Namespace private var namespace

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ScreenBackground()
                content
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Lists and items")
            .navigationDestination(for: ListRoute.self) { route in
                switch route {
                case .detail(let id):
                    ListDetailView(listId: id)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Search your lists",
                message: "Find a list by name, or an item by what's written on it."
            )
        } else if matchingLists.isEmpty && matchingItems.isEmpty {
            EmptyStateView(
                icon: "questionmark.circle",
                title: "Nothing found",
                message: "No list or item matches “\(trimmedQuery)”."
            )
        } else {
            results
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: Metrics.rowSpacing) {
                if !matchingLists.isEmpty {
                    SectionLabel(title: "Lists", count: matchingLists.count)
                    ForEach(matchingLists) { list in
                        ListCard(
                            list: list,
                            partner: store.partner(id: list.partnerId),
                            currentUserId: store.currentUserId,
                            matchedID: "search-\(list.id)",
                            namespace: namespace
                        ) {
                            path.append(ListRoute.detail(list.id))
                        }
                    }
                }

                if !matchingItems.isEmpty {
                    SectionLabel(title: "Items", count: matchingItems.count)
                        .padding(.top, matchingLists.isEmpty ? 0 : 10)
                    ForEach(matchingItems) { match in
                        itemRow(match)
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 90)
            .motion(Motion.content, value: trimmedQuery)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func itemRow(_ match: ItemMatch) -> some View {
        Button {
            Haptics.light()
            path.append(ListRoute.detail(match.list.id))
        } label: {
            GlassCard(tint: match.list.tint.color, tintStrength: 0.11, interactive: true) {
                HStack(spacing: 12) {
                    Image(systemName: match.todo.done ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(match.todo.done ? Brand.success : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.todo.title)
                            .font(.subheadline.weight(.medium))
                            .strikethrough(match.todo.done, color: .secondary)
                            .foregroundStyle(match.todo.done ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(match.list.tint.color)
                                .frame(width: 10, height: 10)
                            Text(match.list.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(Metrics.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(match.todo.title), in \(match.list.label)")
        .accessibilityHint("Opens the list")
    }

    // MARK: - Data

    /// A todo plus the list it lives in, so a result can name its home.
    private struct ItemMatch: Identifiable {
        let list: TodoList
        let todo: Todo
        var id: String { "\(list.id)-\(todo.id)" }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Archived lists are searchable too — "where did that go?" is exactly when
    /// someone reaches for search, and silently excluding them answers "nowhere".
    private var searchable: [TodoList] {
        store.lists.filter { !$0.isPendingInvite }
    }

    private var matchingLists: [TodoList] {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return [] }
        return searchable.filter { $0.label.localizedCaseInsensitiveContains(needle) }
    }

    private var matchingItems: [ItemMatch] {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return [] }
        return searchable.flatMap { list in
            list.todos
                .filter { $0.title.localizedCaseInsensitiveContains(needle) }
                .map { ItemMatch(list: list, todo: $0) }
        }
    }
}
