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

    private func add(_ localId: String, _ title: String, notes: String? = nil, list: String = "l1") -> PendingMutation {
        PendingMutation(kind: .addTodo(listId: list, localId: localId, title: title, notes: notes))
    }
    private func notes(_ id: String, _ value: String?, list: String = "l1") -> PendingMutation {
        PendingMutation(kind: .setNotes(listId: list, todoId: id, notes: value))
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
        let log = fold([add("local-1", "Milk", notes: "Semi-skimmed"), rename("local-1", "Oat milk")])
        #expect(log.count == 1)
        if case .addTodo(_, let localId, let title, let notes) = log[0].kind {
            #expect(localId == "local-1")
            #expect(title == "Oat milk", "The add should carry the final name")
            #expect(notes == "Semi-skimmed", "A rename must not drop the notes the add was carrying")
        } else {
            Issue.record("Expected the rename to fold into the add")
        }
    }

    @Test("Adding notes to a pending addition rewrites the addition")
    func notesFoldIntoAdd() {
        let log = fold([add("local-1", "Milk"), notes("local-1", "The barista one")])
        #expect(log.count == 1)
        if case .addTodo(_, let localId, let title, let notes) = log[0].kind {
            #expect(localId == "local-1")
            #expect(title == "Milk", "Notes must not touch the title")
            #expect(notes == "The barista one")
        } else {
            Issue.record("Expected the notes to fold into the add")
        }
    }

    @Test("Editing notes repeatedly queues only the final text, and clearing counts")
    func lastNotesWin() {
        let log = fold([notes("t1", "a"), notes("t1", "ab"), notes("t1", nil)])
        #expect(log.count == 1)
        if case .setNotes(_, _, let value) = log[0].kind { #expect(value == nil) }
        else { Issue.record("Expected a setNotes") }
    }

    @Test("Notes and a rename on the same real item are both kept")
    func notesAndRenameCoexist() {
        // They go to different endpoints, so neither is a stale version of the
        // other.
        let log = fold([rename("t1", "Milk"), notes("t1", "Oat")])
        #expect(log.count == 2)
    }

    @Test("An old log without the notes field still decodes")
    func legacyAddDecodes() throws {
        // The queue is on disk across app updates. An entry written before
        // additions carried notes must not become a corrupt log.
        let legacy = Data("""
        [{"id":"0B3A0C3E-2E7C-4E7B-9C7E-3D7C2B1A0F11","at":0,
          "kind":{"addTodo":{"listId":"l1","localId":"local-1","title":"Milk"}}}]
        """.utf8)
        let log = try JSONDecoder().decode([PendingMutation].self, from: legacy)
        #expect(log.count == 1)
        if case .addTodo(_, _, let title, let notes) = log[0].kind {
            #expect(title == "Milk")
            #expect(notes == nil)
        } else {
            Issue.record("Expected an addTodo")
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
