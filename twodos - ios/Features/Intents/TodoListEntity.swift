import AppIntents
import SwiftUI

/// A list, as Siri and Shortcuts see it.
///
/// ## Why the snapshot and not the API
/// Resolving "add milk to the weekly shop" means matching spoken words against
/// the user's list names, and it happens *while the user is waiting* — often on
/// a Watch, often with the screen off. A query that reached the network would
/// make every phrase wait on a round trip and fail outright with no signal.
///
/// The App Group snapshot is already on disk, already current, and reading it
/// costs nothing. It is the same file the widgets draw from.
struct TodoListEntity: AppEntity {
    let id: String
    let label: String
    let openCount: Int

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "List", numericFormat: "\(placeholder: .int) lists")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(label)",
            subtitle: openCount == 0
                ? "Nothing outstanding"
                : "\(openCount) open"
        )
    }

    static var defaultQuery = TodoListQuery()

    init(_ ref: WidgetSnapshot.ListRef) {
        id = ref.id
        label = ref.label
        openCount = ref.openCount
    }
}

struct TodoListQuery: EntityStringQuery {

    private func allLists() -> [TodoListEntity] {
        WidgetSnapshotStore.load().lists.map(TodoListEntity.init)
    }

    func entities(for identifiers: [String]) async throws -> [TodoListEntity] {
        let wanted = Set(identifiers)
        return allLists().filter { wanted.contains($0.id) }
    }

    /// Matching spoken or typed text against list names.
    ///
    /// Deliberately loose. Speech recognition rarely returns a list's name
    /// exactly — "weekly shop" for "Weekly Shop 🛒", "groceries" for
    /// "Groceries (Tesco)" — and an exact match would reject most of what a user
    /// actually says. Substring in either direction, case- and
    /// diacritic-insensitive, gets almost all of it.
    func entities(matching string: String) async throws -> [TodoListEntity] {
        allLists().filter { Self.matches(label: $0.label, spoken: string) }
    }

    /// Whether a spoken phrase should resolve to a list with this name.
    ///
    /// Separated out because it is the piece most likely to quietly break a
    /// Shortcut: too strict and "add milk to the weekly shop" stops working
    /// overnight, too loose and every list matches every phrase.
    ///
    /// Substring in *both* directions is the important part. Speech gives back
    /// "groceries" for a list called "Groceries (Tesco)" — the label contains
    /// the phrase — but also "the weekly shop list" for one called "Weekly
    /// Shop", where the phrase contains the label.
    static func matches(label: String, spoken: String) -> Bool {
        let needle = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty phrase means "show me everything", not "match nothing" —
        // it is what the Shortcuts picker sends before the user types.
        guard !needle.isEmpty else { return true }

        // `localizedStandardContains` is case- and diacritic-insensitive, which
        // is what makes "cafe" find "Café" and "GROCERIES" find "Groceries".
        return label.localizedStandardContains(needle)
            || needle.localizedStandardContains(label)
    }

    /// What the Shortcuts editor shows in its list picker.
    func suggestedEntities() async throws -> [TodoListEntity] {
        // Already ordered by the app's own relevance rule — overdue, then
        // favourite, then recently used — so the list someone is most likely to
        // pick is already at the top.
        allLists()
    }
}
