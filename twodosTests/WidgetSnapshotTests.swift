import Foundation
import Testing
@testable import twodos___ios

/// The widget snapshot is the only thing the widgets ever see, and it is built
/// once in the app and read in a process that cannot be debugged easily. So the
/// rules that decide *what a user is shown at a glance* are tested here rather
/// than discovered on a Home Screen.
@Suite("Widget snapshot")
struct WidgetSnapshotTests {

    /// Fixed so "due today" and "overdue" mean the same thing on every run —
    /// a test whose fixture drifts past a deadline at midnight is worse than no
    /// test at all.
    static let now = Date(timeIntervalSince1970: 1_770_000_000) // 2026-02-02, 03:20 UTC

    private var now: Date { Self.now }

    /// Built by decoding, for the same reason ``WatchPayloadTests`` does it:
    /// `TodoList` has only a decoding init, so this exercises the path the API
    /// actually takes.
    private func list(
        id: String = "1",
        label: String = "Groceries",
        archived: Bool = false,
        inviteStatus: String? = nil,
        favorite: Bool = false,
        dueAt: Date? = nil,
        pinned: Bool = false,
        createdBy: String = "me",
        partnerId: String? = nil,
        items: [(id: String, title: String, done: Bool, dueAt: Date?)] = []
    ) -> TodoList {
        var fields: [String: Any] = [
            "id": id, "label": label, "favorite": favorite, "archived": archived,
            "color": "#4E8C6F", "createdBy": createdBy, "order": 0,
            "items": items.enumerated().map { index, item -> [String: Any] in
                var encoded: [String: Any] = [
                    "id": item.id, "title": item.title, "done": item.done, "order": index
                ]
                if let due = item.dueAt { encoded["doBefore"] = Self.iso(due) }
                return encoded
            }
        ]
        if let dueAt { fields["doBefore"] = Self.iso(dueAt) }
        if let partnerId { fields["partnerId"] = partnerId }
        if let inviteStatus {
            fields["inviteStatus"] = inviteStatus
            fields["inviteAccepted"] = inviteStatus != APIConstants.InviteStatus.pending
        }
        if pinned {
            fields["locationLat"] = 51.5074
            fields["locationLng"] = -0.1278
            fields["locationRadius"] = 200
            fields["locationTrigger"] = "ARRIVE"
            fields["locationName"] = "Tesco Metro"
        }

        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! APIDecodingTests.decoder().decode(TodoList.self, from: data)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func make(
        _ lists: [TodoList],
        partnerNames: [String: String] = [:]
    ) -> WidgetSnapshot {
        .make(
            from: lists,
            currentUserId: "me",
            isSignedIn: true,
            partnerNames: partnerNames,
            now: now
        )
    }

    private func open(_ id: String, _ title: String, dueAt: Date? = nil)
        -> (id: String, title: String, done: Bool, dueAt: Date?) {
        (id: id, title: title, done: false, dueAt: dueAt)
    }

    // MARK: - What gets in

    @Test("Signed out produces nothing, not a convincing set of zeroes")
    func signedOutIsEmpty() {
        let snapshot = WidgetSnapshot.make(
            from: [list(items: [open("i1", "Milk")])],
            currentUserId: "me",
            isSignedIn: false,
            now: now
        )
        #expect(snapshot == .empty)
        #expect(!snapshot.isAllClear, "Signed out must not read as 'all clear'")
    }

    @Test("Archived lists and unanswered invites are not the user's work")
    func excludesArchivedAndInvites() {
        let snapshot = make([
            list(id: "a", archived: true, items: [open("i1", "Archived thing")]),
            list(id: "b", inviteStatus: APIConstants.InviteStatus.pending,
                 items: [open("i2", "Invited thing")]),
            list(id: "c", items: [open("i3", "Real thing")])
        ])

        #expect(snapshot.openCount == 1)
        #expect(snapshot.listCount == 1)
        #expect(snapshot.upNext.map(\.title) == ["Real thing"])
    }

    @Test("A list with nothing open does not count as a list with work")
    func ignoresCompletedLists() {
        let snapshot = make([
            list(id: "a", items: [(id: "i1", title: "Done", done: true, dueAt: nil)]),
            list(id: "b", items: [open("i2", "Open")])
        ])

        #expect(snapshot.listCount == 1)
        #expect(snapshot.openCount == 1)
    }

    // MARK: - Ordering

    @Test("Overdue outranks upcoming, and the oldest overdue leads")
    func overdueLeadsOldestFirst() {
        let snapshot = make([
            list(id: "a", items: [open("i1", "Soon", dueAt: now.addingTimeInterval(3600))]),
            list(id: "b", items: [open("i2", "An hour late", dueAt: now.addingTimeInterval(-3600))]),
            list(id: "c", items: [open("i3", "Three days late", dueAt: now.addingTimeInterval(-3 * 86_400))])
        ])

        #expect(snapshot.upNext.map(\.title) == ["Three days late", "An hour late", "Soon"])
        #expect(snapshot.overdueCount == 2)
    }

    @Test("Undated items sort behind dated ones but still appear")
    func undatedStillSurface() {
        let snapshot = make([
            list(id: "a", items: [open("i1", "No deadline")]),
            list(id: "b", items: [open("i2", "Next week", dueAt: now.addingTimeInterval(7 * 86_400))])
        ])

        #expect(snapshot.upNext.map(\.title) == ["Next week", "No deadline"])
    }

    @Test("A user who keeps no deadlines at all still gets a populated widget")
    func noDeadlinesAnywhere() {
        let snapshot = make([
            list(id: "a", items: [open("i1", "One"), open("i2", "Two")]),
            list(id: "b", items: [open("i3", "Three")])
        ])

        #expect(!snapshot.upNext.isEmpty, "An undated backlog must not render as 'all clear'")
        #expect(snapshot.openCount == 3)
        #expect(!snapshot.isAllClear)
    }

    @Test("Favourites break the tie between undated lists")
    func favouritesLeadAmongUndated() {
        let snapshot = make([
            list(id: "a", label: "Ordinary", items: [open("i1", "Ordinary item")]),
            list(id: "b", label: "Starred", favorite: true, items: [open("i2", "Starred item")])
        ])

        #expect(snapshot.upNext.first?.title == "Starred item")
    }

    // MARK: - Fair share

    @Test("One huge list cannot fill the whole widget")
    func perListCapApplies() {
        let many = (1...10).map { open("i\($0)", "Item \($0)") }
        let snapshot = make([
            list(id: "big", label: "Big", items: many),
            list(id: "small", label: "Small", items: [open("s1", "Small item")])
        ])

        let fromBig = snapshot.upNext.filter { $0.listId == "big" }
        #expect(fromBig.count == WidgetRanking.perList)
        #expect(snapshot.upNext.contains { $0.listId == "small" },
                "The other list must still get a row")
    }

    @Test("The cap limits rows, never the counts")
    func capDoesNotDistortCounts() {
        let many = (1...10).map { open("i\($0)", "Item \($0)", dueAt: now.addingTimeInterval(-86_400)) }
        let snapshot = make([list(id: "big", items: many)])

        #expect(snapshot.upNext.count == WidgetRanking.perList)
        #expect(snapshot.openCount == 10, "The headline number counts everything, not just what is shown")
        #expect(snapshot.overdueCount == 10)
    }

    @Test("Never more rows than the largest widget can hold")
    func respectsCapacity() {
        let lists = (1...20).map {
            list(id: "l\($0)", label: "List \($0)", items: [open("i\($0)", "Item \($0)")])
        }
        #expect(make(lists).upNext.count == WidgetRanking.capacity)
    }

    // MARK: - Inherited deadlines

    @Test("An item with no deadline of its own inherits the list's, and says so")
    func inheritsListDeadline() {
        let due = now.addingTimeInterval(2 * 3600)
        let snapshot = make([list(id: "a", dueAt: due, items: [open("i1", "Book the table")])])

        let row = try! #require(snapshot.upNext.first)
        #expect(row.dueAt?.timeIntervalSince1970 == due.timeIntervalSince1970)
        #expect(row.isListDeadline, "The row must not claim the item has its own deadline")
    }

    @Test("An item's own deadline wins over its list's")
    func ownDeadlineWins() {
        let listDue = now.addingTimeInterval(5 * 86_400)
        let itemDue = now.addingTimeInterval(3600)
        let snapshot = make([
            list(id: "a", dueAt: listDue, items: [open("i1", "Urgent", dueAt: itemDue)])
        ])

        let row = try! #require(snapshot.upNext.first)
        #expect(row.dueAt?.timeIntervalSince1970 == itemDue.timeIntervalSince1970)
        #expect(!row.isListDeadline)
    }

    @Test("An inherited deadline still counts towards overdue")
    func inheritedDeadlineCounts() {
        let snapshot = make([
            list(id: "a", dueAt: now.addingTimeInterval(-86_400),
                 items: [open("i1", "One"), open("i2", "Two")])
        ])
        #expect(snapshot.overdueCount == 2)
    }

    // MARK: - Context carried onto the row

    @Test("A pinned place rides along on the row rather than becoming a row")
    func placeIsContextNotAnEntry() {
        let snapshot = make([list(id: "a", pinned: true, items: [open("i1", "Milk")])])

        #expect(snapshot.upNext.count == 1, "A place is a condition, not a task")
        #expect(snapshot.upNext.first?.placeLabel == "Arrive at Tesco Metro")
    }

    // MARK: - Collaborators

    @Test("A shared task names the person it is shared with")
    func namesTheCollaborator() {
        let snapshot = make(
            [list(id: "a", partnerId: "p1", items: [open("i1", "Book the table")])],
            partnerNames: ["p1": "Sam"]
        )

        let row = try! #require(snapshot.upNext.first)
        #expect(row.isShared)
        #expect(row.partnerName == "Sam")
    }

    @Test("A personal list names nobody")
    func personalListHasNoCollaborator() {
        let snapshot = make([list(id: "a", items: [open("i1", "Milk")])])

        let row = try! #require(snapshot.upNext.first)
        #expect(!row.isShared)
        #expect(row.partnerName == nil)
    }

    @Test("A solo list whose partner points back at the creator is not labelled with the user's own name")
    func doesNotLabelSelf() {
        // The API does this for solo lists — `partnerId` echoes the creator.
        // Resolving it blindly would put the user's own name on their own task.
        let snapshot = make(
            [list(id: "a", createdBy: "me", partnerId: "me", items: [open("i1", "Milk")])],
            partnerNames: ["me": "Daniyal"]
        )

        let row = try! #require(snapshot.upNext.first)
        #expect(!row.isShared)
        #expect(row.partnerName == nil, "A solo list must never be attributed to anyone")
    }

    @Test("A shared list whose partner has not loaded still reads as shared")
    func sharedWithoutAName() {
        // Partners and lists are fetched concurrently, so this is the ordinary
        // state during the first seconds of a launch.
        let snapshot = make([list(id: "a", partnerId: "p1", items: [open("i1", "Milk")])])

        let row = try! #require(snapshot.upNext.first)
        #expect(row.isShared, "The glyph must still say the task is not the user's alone")
        #expect(row.partnerName == nil)
    }

    @Test("Two collaborators stay attached to their own tasks")
    func distinguishesCollaborators() {
        let snapshot = make(
            [
                list(id: "a", label: "Trip", dueAt: now.addingTimeInterval(3600),
                     partnerId: "p1", items: [open("i1", "Book table")]),
                list(id: "b", label: "Errands", dueAt: now.addingTimeInterval(7200),
                     partnerId: "p2", items: [open("i2", "Dry cleaning")])
            ],
            partnerNames: ["p1": "Sam", "p2": "Alex"]
        )

        let byTitle: [String: String?] = Dictionary(
            uniqueKeysWithValues: snapshot.upNext.map { ($0.title, $0.partnerName) }
        )
        #expect(byTitle["Book table"] == "Sam")
        #expect(byTitle["Dry cleaning"] == "Alex")
    }

    @Test("The watch carries the name the phone already resolved")
    func watchCarriesCollaborator() {
        let watch = WidgetSnapshot.make(
            fromWatch: WatchList.snapshot(
                from: [list(id: "a", partnerId: "p1", items: [open("i1", "Book the table")])],
                currentUserId: "me",
                partnerNames: ["p1": "Sam"]
            ),
            isSignedIn: true,
            now: now
        )

        let row = try! #require(watch.upNext.first)
        #expect(row.partnerName == "Sam")
        #expect(row.isShared)
    }

    // MARK: - Staleness

    @Test("A snapshot the app has not refreshed in half a day admits it")
    func goesStale() {
        var snapshot = make([list(items: [open("i1", "Milk")])])
        #expect(!snapshot.isStale(asOf: now))

        snapshot.generatedAt = now.addingTimeInterval(-13 * 3600)
        #expect(snapshot.isStale(asOf: now))
    }

    @Test("Signed out is never merely 'stale' — it is its own state")
    func signedOutIsNotStale() {
        #expect(!WidgetSnapshot.empty.isStale(asOf: now))
    }

    // MARK: - The watch builds the same shape

    @Test("The watch's snapshot agrees with the phone's")
    func watchMatchesPhone() {
        let due = now.addingTimeInterval(-3600)
        let phone = make([
            list(id: "a", label: "Admin", dueAt: due, items: [open("i1", "Renew permit")]),
            list(id: "b", label: "Groceries", items: [open("i2", "Milk"), open("i3", "Bread")])
        ])

        let watch = WidgetSnapshot.make(
            fromWatch: WatchList.snapshot(
                from: [
                    list(id: "a", label: "Admin", dueAt: due, items: [open("i1", "Renew permit")]),
                    list(id: "b", label: "Groceries", items: [open("i2", "Milk"), open("i3", "Bread")])
                ],
                currentUserId: "me"
            ),
            isSignedIn: true,
            now: now
        )

        #expect(watch.openCount == phone.openCount)
        #expect(watch.overdueCount == phone.overdueCount)
        #expect(watch.listCount == phone.listCount)
        #expect(watch.upNext.map(\.title) == phone.upNext.map(\.title))
    }

    @Test("A signed-out watch publishes nothing")
    func watchSignedOutIsEmpty() {
        let watch = WidgetSnapshot.make(
            fromWatch: WatchList.snapshot(
                from: [list(items: [open("i1", "Milk")])],
                currentUserId: "me"
            ),
            isSignedIn: false,
            now: now
        )
        #expect(watch == .empty)
    }
}
