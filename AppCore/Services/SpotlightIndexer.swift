import Foundation
import CoreSpotlight
import OSLog

/// Puts lists and items into system search.
///
/// "Where did I write that down?" is a question people answer from the Home
/// Screen rather than by opening apps one at a time. Indexing costs nothing at
/// rest and makes every task findable by typing part of its name — including
/// tasks in lists the user has not opened in weeks, which is exactly when they
/// cannot remember where something is.
///
/// ## What is indexed, and what is not
/// Open items and the lists that hold them. Completed items are excluded on
/// purpose: a search for "milk" that returns the milk you bought last Tuesday is
/// worse than one that returns nothing, because the user has to read the result
/// to discover it is useless.
///
/// ## Why it re-indexes as little as possible
/// `refreshLists` runs on every foreground and every pull-to-refresh. Handing
/// Core Spotlight the same few hundred items each time is real work — it writes
/// to a system database — so the whole set is digested first and skipped
/// entirely when nothing a search could match has changed.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private init() {}

    private let logger = Logger(subsystem: "app.twodos", category: "spotlight")
    private let index = CSSearchableIndex.default()

    /// Namespaces every item, so signing out can drop the lot in one call.
    private static let domain = "app.twodos.lists"

    /// What was last handed over. Compared before doing it again.
    private var lastDigest: String?

    /// Rebuilds the index if anything searchable has changed.
    func reindex(_ lists: [TodoList]) {
        let searchable = lists.filter { !$0.archived && !$0.isPendingInvite }
        let digest = Self.digest(of: searchable)
        guard digest != lastDigest else { return }
        lastDigest = digest

        let items = searchable.flatMap(Self.items(for:))
        index.indexSearchableItems(items) { [weak self] error in
            guard let error else { return }
            // A failed index is not worth telling the user about — search simply
            // will not find their tasks, and nothing they could do would help.
            self?.logger.warning("Spotlight index failed: \(error.localizedDescription)")
        }

        // Anything previously indexed and now absent — a deleted list, an item
        // ticked off — has to be removed explicitly. `indexSearchableItems` only
        // ever adds and updates.
        let wanted = Set(items.map(\.uniqueIdentifier))
        let stale = knownIdentifiers.subtracting(wanted)
        knownIdentifiers = wanted
        guard !stale.isEmpty else { return }
        index.deleteSearchableItems(withIdentifiers: Array(stale)) { _ in }
    }

    /// Everything handed to Spotlight so far this launch, so removals can be
    /// worked out without asking the system what it holds.
    private var knownIdentifiers: Set<String> = []

    /// Drops everything on sign-out. A signed-out phone must not surface the
    /// previous user's tasks in system search.
    func clear() {
        lastDigest = nil
        knownIdentifiers = []
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in }
    }

    // MARK: - Building

    private static func items(for list: TodoList) -> [CSSearchableItem] {
        var result = [searchableList(list)]
        // Open items only — see the note above about stale results.
        result.append(contentsOf: list.todos.filter { !$0.done }.map { searchableTodo($0, in: list) })
        return result
    }

    private static func searchableList(_ list: TodoList) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = list.label
        attributes.contentDescription = Format.progress(
            done: list.completedCount, total: list.totalCount
        )
        attributes.keywords = ["twodos", "list", list.label]
        if let due = list.doBefore { attributes.dueDate = due }

        return CSSearchableItem(
            uniqueIdentifier: DeepLink.list(id: list.id).url.absoluteString,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }

    private static func searchableTodo(_ todo: Todo, in list: TodoList) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = todo.title
        // Naming the list is what makes a result actionable: "Oat milk" alone
        // does not tell you where to go.
        attributes.contentDescription = list.label
        attributes.keywords = ["twodos", list.label, todo.title]
        if let due = todo.doBefore ?? list.doBefore { attributes.dueDate = due }

        return CSSearchableItem(
            // The list's link, not the item's: tapping a result should open the
            // list the item lives in, which is the only destination the app has.
            // The identifier stays unique by suffixing the item id.
            uniqueIdentifier: "\(DeepLink.list(id: list.id).url.absoluteString)#\(todo.id)",
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }

    /// Cheap stand-in for "has anything searchable changed?".
    ///
    /// Only the fields a search could match or display are included, so ticking
    /// an item — which changes `updatedAt` on the list — re-indexes, while a
    /// socket presence ping does not.
    private static func digest(of lists: [TodoList]) -> String {
        lists.map { list in
            let open = list.todos.filter { !$0.done }.map(\.title).joined(separator: "\u{1}")
            return "\(list.id)|\(list.label)|\(open)"
        }
        .joined(separator: "\u{2}")
    }

    // MARK: - Opening a result

    /// Turns a tapped search result back into a destination.
    ///
    /// The identifier is a `twodos://` URL, optionally with an item id after a
    /// `#`. Parsing it back through ``DeepLink`` means a Spotlight tap and a
    /// widget tap arrive by the same path.
    nonisolated static func deepLink(forSearchableItemID identifier: String) -> DeepLink? {
        let base = identifier.split(separator: "#", maxSplits: 1).first.map(String.init) ?? identifier
        guard let url = URL(string: base) else { return nil }
        return DeepLink(url: url)
    }
}
