import Foundation
import Testing
@testable import twodos___ios

/// Ticking an item off from the Home Screen.
///
/// The widget extension can reach the API only while the access token is still
/// fresh — it can never renew one. Either way the snapshot is updated first, so
/// this is about the widget agreeing with itself: the headline count must never
/// contradict the list printed underneath it.
///
/// What happens to a tap that could not be sent is the queue's business, and is
/// tested in ``OfflineQueueTests``.
@Suite("Interactive widget ticks")
struct InteractiveWidgetTests {

    static let now = Date(timeIntervalSince1970: 1_770_000_000)
    private var now: Date { Self.now }

    private func todo(_ id: String, list: String = "l1", dueAt: Date? = nil) -> WidgetTodo {
        WidgetTodo(id: id, title: "Item \(id)", listId: list, listLabel: "Groceries",
                   tintIndex: 0, dueAt: dueAt)
    }

    private func snapshot(
        upNext: [WidgetTodo],
        open: Int,
        overdue: Int = 0,
        dueToday: Int = 0,
        lists: [WidgetSnapshot.ListRef] = [
            .init(id: "l1", label: "Groceries", tintIndex: 0, openCount: 3)
        ]
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now, isSignedIn: true,
            openCount: open, overdueCount: overdue, dueTodayCount: dueToday,
            listCount: lists.count { $0.openCount > 0 },
            upNext: upNext, lists: lists
        )
    }

    // MARK: - The optimistic update

    @Test("A ticked item leaves the list and the count")
    func removesAndDecrements() {
        let before = snapshot(upNext: [todo("a"), todo("b")], open: 3)
        let after = before.completing(todoId: "a", listId: "l1", now: now)

        #expect(after.upNext.map(\.id) == ["b"])
        #expect(after.openCount == 2)
    }

    @Test("Ticking an overdue item stops it being counted as overdue")
    func overdueCountFollows() {
        // Otherwise the widget says "1 overdue" above a list containing nothing
        // overdue — it would be contradicting itself on screen.
        let before = snapshot(
            upNext: [todo("a", dueAt: now.addingTimeInterval(-3600))],
            open: 1, overdue: 1
        )
        let after = before.completing(todoId: "a", listId: "l1", now: now)

        #expect(after.overdueCount == 0)
        #expect(after.openCount == 0)
    }

    @Test("Ticking a due-today item stops it being counted as due today")
    func dueTodayCountFollows() {
        let before = snapshot(
            upNext: [todo("a", dueAt: now.addingTimeInterval(3600))],
            open: 1, dueToday: 1
        )
        let after = before.completing(todoId: "a", listId: "l1", now: now)

        #expect(after.dueTodayCount == 0)
    }

    @Test("Ticking an undated item leaves the deadline counts alone")
    func undatedDoesNotTouchDeadlineCounts() {
        let before = snapshot(upNext: [todo("a"), todo("b")], open: 2, overdue: 1, dueToday: 1)
        let after = before.completing(todoId: "a", listId: "l1", now: now)

        #expect(after.overdueCount == 1)
        #expect(after.dueTodayCount == 1)
    }

    @Test("Emptying a list drops it from the list count")
    func listCountFollows() {
        let before = snapshot(
            upNext: [todo("a")],
            open: 1,
            lists: [.init(id: "l1", label: "Groceries", tintIndex: 0, openCount: 1)]
        )
        let after = before.completing(todoId: "a", listId: "l1", now: now)

        #expect(after.lists.first?.openCount == 0)
        #expect(after.listCount == 0)
        #expect(after.isAllClear)
    }

    @Test("Ticking something not in the snapshot changes nothing")
    func unknownItemIsANoOp() {
        // The widget may be showing a snapshot older than the app's state.
        // Decrementing a count for a row that was never there would drift the
        // headline number away from reality with nothing to correct it.
        let before = snapshot(upNext: [todo("a")], open: 5)
        #expect(before.completing(todoId: "zzz", listId: "l1", now: now) == before)
    }

    @Test("Counts never go negative")
    func countsAreFloored() {
        // A stale snapshot can disagree with its own counts; the arithmetic must
        // not produce "-1 open".
        let before = snapshot(upNext: [todo("a", dueAt: now.addingTimeInterval(-60))],
                              open: 0, overdue: 0)
        let after = before.completing(todoId: "a", listId: "l1", now: now)

        #expect(after.openCount == 0)
        #expect(after.overdueCount == 0)
    }
}
