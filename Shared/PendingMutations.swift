import Foundation

/// Changes made while there was no way to send them.
///
/// ## Why this exists
/// Every write in the app is optimistic: the UI moves on the same frame as the
/// tap, then the server is told. Until now a failure rolled that change back and
/// showed a banner — which is right for a rejected request and wrong for a
/// tunnel. A user ticking things off on the Underground watched their work
/// undo itself one row at a time.
///
/// So an *offline* failure no longer rolls back. The change is kept, recorded
/// here, and replayed when there is a network again.
///
/// ## Why the log is collapsed rather than replayed verbatim
/// A literal journal replays every keystroke: add, rename, rename, rename. What
/// matters is the state the user ended up with, not the path they took — and
/// each extra entry is another request that can fail. So mutations fold into
/// each other as they arrive, and the queue holds intentions, not history.
///
/// The rules are all one idea: **the most recent statement about a thing is the
/// only one worth sending.**
struct PendingMutation: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: Kind
    /// When the user acted, not when it was sent.
    var at: Date = .now

    enum Kind: Codable, Equatable, Sendable {
        /// `localId` is the placeholder the app invented; the server has never
        /// seen it and will assign its own on replay.
        case addTodo(listId: String, localId: String, title: String)
        case setDone(listId: String, todoId: String, done: Bool)
        case renameTodo(listId: String, todoId: String, title: String)
        case deleteTodo(listId: String, todoId: String)
    }

    /// The item this mutation is about, whether real or still local.
    var targetId: String {
        switch kind {
        case .addTodo(_, let localId, _): localId
        case .setDone(_, let todoId, _): todoId
        case .renameTodo(_, let todoId, _): todoId
        case .deleteTodo(_, let todoId): todoId
        }
    }

    var listId: String {
        switch kind {
        case .addTodo(let listId, _, _): listId
        case .setDone(let listId, _, _): listId
        case .renameTodo(let listId, _, _): listId
        case .deleteTodo(let listId, _): listId
        }
    }

    /// Whether this is an item the server has never heard of.
    var isLocalAddition: Bool {
        if case .addTodo = kind { return true }
        return false
    }
}

enum PendingMutationLog {

    /// Enough for a long commute. Past this the app has been offline for so long
    /// that a full reconcile is a better answer than a longer queue.
    static let capacity = 200

    // MARK: - The rules

    /// Folds a new mutation into the queue.
    ///
    /// Pure, because this is where the subtle cases live and they are far easier
    /// to get right with tests than with a phone in a tunnel.
    static func appending(_ new: PendingMutation, to log: [PendingMutation]) -> [PendingMutation] {
        var out = log
        let target = new.targetId

        switch new.kind {
        case .addTodo:
            out.append(new)

        case .setDone(_, _, _):
            // Ticking something the server has never seen cannot be expressed:
            // there is no id to address. The local state already shows it ticked
            // and the post-replay refresh will reconcile, so the intent is kept
            // on screen even though it cannot be sent.
            guard !out.contains(where: { $0.isLocalAddition && $0.targetId == target }) else { return out }
            out.removeAll { if case .setDone(_, let id, _) = $0.kind { return id == target } else { return false } }
            out.append(new)

        case .renameTodo(let listId, _, let title):
            // Renaming a pending addition rewrites the addition. Queueing a
            // rename against an id the server will never issue would guarantee a
            // failed request on replay.
            if let index = out.firstIndex(where: { $0.isLocalAddition && $0.targetId == target }) {
                out[index].kind = .addTodo(listId: listId, localId: target, title: title)
                return out
            }
            out.removeAll { if case .renameTodo(_, let id, _) = $0.kind { return id == target } else { return false } }
            out.append(new)

        case .deleteTodo:
            let wasNeverSent = out.contains { $0.isLocalAddition && $0.targetId == target }
            // Everything queued about this item is moot now.
            out.removeAll { $0.targetId == target }
            // An item created and deleted while offline never existed as far as
            // the server is concerned. Sending a delete for it would 404.
            if wasNeverSent { return out }
            out.append(new)
        }

        // Oldest first, so trimming drops the stalest intent.
        return Array(out.suffix(capacity))
    }

    /// Puts failed entries back, without resurrecting anything superseded since.
    static func restoring(
        _ failed: [PendingMutation],
        into current: [PendingMutation]
    ) -> [PendingMutation] {
        guard !failed.isEmpty else { return current }
        let superseded = Set(current.map(\.targetId))
        let restored = failed.filter { !superseded.contains($0.targetId) }
        return Array((restored + current).suffix(capacity))
    }

    // MARK: - Storage

    static func load() -> [PendingMutation] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode([PendingMutation].self, from: data)
        else { return [] }
        return log
    }

    static func enqueue(_ mutation: PendingMutation) {
        save(appending(mutation, to: load()))
    }

    /// Hands the queue over and empties it in one step, so a change arriving
    /// mid-drain is not silently discarded.
    static func drain() -> [PendingMutation] {
        let log = load()
        guard !log.isEmpty else { return [] }
        save([])
        return log
    }

    static func requeue(_ failed: [PendingMutation]) {
        guard !failed.isEmpty else { return }
        save(restoring(failed, into: load()))
    }

    static func clear() { save([]) }

    private static func save(_ log: [PendingMutation]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// In the App Group, so the widget's ticks land in the same queue the app
    /// replays — one log, not two that have to agree.
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroup)?
            .appending(path: "pending-mutations.json")
    }
}
