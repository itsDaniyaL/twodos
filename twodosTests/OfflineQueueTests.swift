import Foundation
import Testing
@testable import twodos___ios

/// What happens to changes made with no network.
///
/// The queue is written in a tunnel and replayed on a platform, so none of this
/// is observable while it is going wrong. Each rule below exists because the
/// naive version produces a request that cannot succeed — usually a write
/// against an id the server has never issued.
@Suite("Offline queue")
struct OfflineQueueTests {

    private func add(_ localId: String, _ title: String, list: String = "l1") -> PendingMutation {
        PendingMutation(kind: .addTodo(listId: list, localId: localId, title: title))
    }
    private func done(_ id: String, _ value: Bool = true, list: String = "l1") -> PendingMutation {
        PendingMutation(kind: .setDone(listId: list, todoId: id, done: value))
    }
    private func rename(_ id: String, _ title: String, list: String = "l1") -> PendingMutation {
        PendingMutation(kind: .renameTodo(listId: list, todoId: id, title: title))
    }
    private func remove(_ id: String, list: String = "l1") -> PendingMutation {
        PendingMutation(kind: .deleteTodo(listId: list, todoId: id))
    }

    private func fold(_ mutations: [PendingMutation]) -> [PendingMutation] {
        mutations.reduce(into: [PendingMutation]()) { log, next in
            log = PendingMutationLog.appending(next, to: log)
        }
    }

    // MARK: - Superseding

    @Test("Ticking the same item twice queues one final state")
    func lastTickWins() {
        let log = fold([done("t1", true), done("t1", false)])
        #expect(log.count == 1)
        if case .setDone(_, _, let value) = log[0].kind { #expect(value == false) }
        else { Issue.record("Expected a setDone") }
    }

    @Test("Renaming repeatedly queues only the final name")
    func lastNameWins() {
        let log = fold([rename("t1", "Milk"), rename("t1", "Oat milk"), rename("t1", "Oat milk 2L")])
        #expect(log.count == 1)
        if case .renameTodo(_, _, let title) = log[0].kind { #expect(title == "Oat milk 2L") }
        else { Issue.record("Expected a rename") }
    }

    @Test("Different items do not supersede each other")
    func distinctItemsCoexist() {
        let log = fold([done("t1"), done("t2"), rename("t3", "x")])
        #expect(log.count == 3)
    }

    // MARK: - Items the server has never seen

    @Test("Renaming a pending addition rewrites the addition")
    func renameFoldsIntoAdd() {
        // Queueing a rename against a local placeholder id would guarantee a
        // failed request: the server never issued that id.
        let log = fold([add("local-1", "Milk"), rename("local-1", "Oat milk")])
        #expect(log.count == 1)
        if case .addTodo(_, let localId, let title) = log[0].kind {
            #expect(localId == "local-1")
            #expect(title == "Oat milk", "The add should carry the final name")
        } else {
            Issue.record("Expected the rename to fold into the add")
        }
    }

    @Test("Adding then deleting while offline queues nothing at all")
    func addThenDeleteCancels() {
        // As far as the server is concerned the item never existed. Sending a
        // delete for it would 404.
        #expect(fold([add("local-1", "Milk"), remove("local-1")]).isEmpty)
    }

    @Test("Ticking a pending addition is not queued")
    func tickOnLocalAddIsDropped() {
        // There is no id to address it by. The local state still shows it
        // ticked; the refresh after replay reconciles.
        let log = fold([add("local-1", "Milk"), done("local-1")])
        #expect(log.count == 1)
        #expect(log[0].isLocalAddition)
    }

    @Test("A real item's tick is queued normally")
    func tickOnRealItemSurvives() {
        // Guards against the rule above being too eager.
        let log = fold([add("local-1", "Milk"), done("server-9")])
        #expect(log.count == 2)
    }

    // MARK: - Deletion clears the item's history

    @Test("Deleting an item drops everything else queued about it")
    func deleteSupersedesEverything() {
        // Renaming something and then deleting it should send one request, not
        // a rename the server will apply to a row about to disappear.
        let log = fold([rename("t1", "Milk"), done("t1"), remove("t1")])
        #expect(log.count == 1)
        if case .deleteTodo = log[0].kind {} else { Issue.record("Expected only the delete") }
    }

    @Test("Deleting one item leaves another's changes alone")
    func deleteIsTargeted() {
        let log = fold([rename("t1", "Milk"), remove("t2")])
        #expect(log.count == 2)
    }

    // MARK: - Ordering and capacity

    @Test("Order of distinct changes is preserved")
    func orderIsKept() {
        let log = fold([add("a", "A"), add("b", "B"), add("c", "C")])
        #expect(log.map(\.targetId) == ["a", "b", "c"])
    }

    @Test("An overflowing queue drops the stalest intent, not the newest")
    func trimsFromTheFront() {
        var log: [PendingMutation] = []
        for i in 0...PendingMutationLog.capacity {
            log = PendingMutationLog.appending(add("item\(i)", "Item \(i)"), to: log)
        }
        #expect(log.count == PendingMutationLog.capacity)
        #expect(log.last?.targetId == "item\(PendingMutationLog.capacity)")
        #expect(!log.contains { $0.targetId == "item0" })
    }

    // MARK: - Replay failures

    @Test("A failed replay goes back on the queue")
    func failuresAreRestored() {
        let restored = PendingMutationLog.restoring([done("t1")], into: [])
        #expect(restored.map(\.targetId) == ["t1"])
    }

    @Test("A change made during the replay wins over the failed attempt")
    func newerIntentWins() {
        // The user ticked it again while the replay was in flight. Restoring the
        // old attempt would undo what they just did.
        let merged = PendingMutationLog.restoring([done("t1", true)], into: [done("t1", false)])
        #expect(merged.count == 1)
        if case .setDone(_, _, let value) = merged[0].kind { #expect(value == false) }
        else { Issue.record("Expected the newer setDone") }
    }

    @Test("Restoring nothing leaves the queue untouched")
    func restoringEmptyIsANoOp() {
        let current = [done("t1")]
        #expect(PendingMutationLog.restoring([], into: current) == current)
    }
}
