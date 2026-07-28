import Foundation

/// What the widgets draw, and the only thing they ever read.
///
/// ## Why a snapshot rather than a live fetch
/// A widget extension that talks to the API needs the session token, a way to
/// renew it, and a periodic wake-up to stay current — and this API's refresh
/// tokens are single-use and rotated, so two processes racing to renew one
/// destroys every session on the account. A snapshot sidesteps all of it: the
/// app writes what it already knows to a shared container, the extension reads
/// a file. No auth in the extension, no radio, no timer.
///
/// ## Why it is pre-computed
/// Everything a widget needs to render is decided here, on the app's side of the
/// fence: which items matter, in what order, with what phrasing. The extension
/// gets a memory budget measured in tens of megabytes and is killed without
/// ceremony when it exceeds it, so it does no sorting, no filtering, and never
/// sees the full model.
///
/// ## Two devices, two snapshots
/// The phone and the watch each keep their own. App Group containers are
/// per-device — the watch cannot read the phone's — so `WatchStore` writes its
/// own copy from the payload it already receives over `WCSession`. Both use the
/// same shape so the two widget bundles share every view.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// When the app last wrote this. The widget shows its age once the data is
    /// old enough to be misleading rather than silently presenting a stale
    /// count as current.
    var generatedAt: Date

    /// False when nobody is signed in, which the widget says plainly instead of
    /// rendering a convincing set of zeroes.
    var isSignedIn: Bool

    /// Open items across every active list — the single number that answers
    /// "how much is left?".
    var openCount: Int
    var overdueCount: Int
    var dueTodayCount: Int
    /// Active lists that still have something open in them.
    var listCount: Int

    /// What to do next, already ranked. Capped at what the largest widget can
    /// show.
    var upNext: [WidgetTodo]

    /// Every active list, name and id only.
    ///
    /// Not for the widgets — for Siri. Resolving "add milk to the weekly shop"
    /// means matching spoken text against the user's list names, and an
    /// `AppEntity` query that had to reach the API would make every Shortcut
    /// wait on a round trip and fail outright with no signal. `upNext` cannot
    /// serve this: it is capped, ranked, and holds at most two items per list,
    /// so a list the user has not touched lately would simply not exist.
    var lists: [ListRef] = []

    /// One list, as little of it as a name-match needs.
    struct ListRef: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var tintIndex: Int
        var openCount: Int
    }

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        isSignedIn: false,
        openCount: 0,
        overdueCount: 0,
        dueTodayCount: 0,
        listCount: 0,
        upNext: [],
        lists: []
    )

    /// The most pressing single thing, for the surfaces that fit exactly one.
    var headline: WidgetTodo? { upNext.first }

    /// Whether there is genuinely nothing outstanding, as opposed to nothing
    /// loaded. The two look identical in a widget and mean opposite things.
    var isAllClear: Bool { isSignedIn && openCount == 0 }

    /// Old enough that presenting it as current would mislead. A widget whose
    /// app has not run for half a day is showing history.
    func isStale(asOf now: Date = .now) -> Bool {
        isSignedIn && now.timeIntervalSince(generatedAt) > 12 * 60 * 60
    }
}

/// One line in a widget: something to do, and enough context to know where it
/// came from without opening the app.
struct WidgetTodo: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// Which list it belongs to. Shown because "Buy milk" alone is ambiguous
    /// when three lists are in play, and it is the deep link target.
    var listId: String
    var listLabel: String
    /// Index into ``ListTint/all`` rather than a hex string, so the widget
    /// resolves the same dark-mode-correct colour without shipping the table.
    var tintIndex: Int
    var dueAt: Date?
    /// Whether the deadline belongs to the whole list rather than this one item,
    /// which changes how the row is phrased.
    var isListDeadline: Bool
    /// "Arrive at Tesco Metro", already phrased. Places are shown as context on
    /// the row rather than as rows of their own — a place is a condition, not a
    /// task, and it has no position in a list ordered by time.
    var placeLabel: String?
    var isShared: Bool

    /// Who the list is shared with, already resolved to a display name.
    ///
    /// Resolved on the app's side for the same reason ``WatchList`` resolves it:
    /// a widget extension has no partner directory, so sending the id would
    /// leave it holding a UUID it cannot render.
    ///
    /// Separate from `isShared` rather than replacing it, because the two answer
    /// different questions. A list can be shared with someone whose name has not
    /// loaded yet — a freshly accepted invite, or a partner list that failed to
    /// fetch — and in that case the row should still say the task is not the
    /// user's alone, just without naming anyone.
    var partnerName: String?

    init(
        id: String,
        title: String,
        listId: String,
        listLabel: String,
        tintIndex: Int,
        dueAt: Date? = nil,
        isListDeadline: Bool = false,
        placeLabel: String? = nil,
        isShared: Bool = false,
        partnerName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.listId = listId
        self.listLabel = listLabel
        self.tintIndex = tintIndex
        self.dueAt = dueAt
        self.isListDeadline = isListDeadline
        self.placeLabel = placeLabel
        self.isShared = isShared
        self.partnerName = partnerName
    }

    func isOverdue(asOf now: Date = .now) -> Bool {
        guard let dueAt else { return false }
        return dueAt < now
    }
}

// MARK: - Ranking

/// How `upNext` is ordered, extracted so the phone and the watch cannot drift
/// apart and so the rule can be tested without either.
///
/// The order answers "what should I be aware of right now?", which is not the
/// same as "what is due soonest":
///
/// 1. **Overdue, most overdue first.** Something three days late outranks
///    something an hour late — it is the one most likely to have been forgotten.
/// 2. **Dated, soonest first.** The ordinary case.
/// 3. **Undated, from favourite lists.** Without this a user who keeps no
///    deadlines at all — a large share of them — would see an empty widget
///    while holding forty open items.
/// 4. **Undated, by how recently the list was touched.**
enum WidgetRanking {
    /// Enough for the largest widget with room to spare, and small enough that
    /// the whole snapshot stays a few kilobytes.
    static let capacity = 12

    /// At most this many items from any one list.
    ///
    /// Without a cap, one list of thirty undated items fills every widget and
    /// the user loses all sight of the other four. Two is enough to show that a
    /// list has more than one thing in it.
    static let perList = 2

    /// A total order over the ranking rules above.
    ///
    /// Total, deliberately: `sorted(by:)` is not a stable sort in Swift, so
    /// leaving ties to be broken by input order would let the phone and the
    /// watch — which build their candidate arrays differently — disagree about
    /// what belongs at the top.
    struct Key: Comparable, Sendable {
        /// 0 overdue, 1 dated ahead, 2 undated.
        var bucket: Int
        /// `.distantFuture` for undated, so the later fields decide.
        var due: Date
        /// Position of the item's list in the app's own ordering.
        var listRank: Int
        /// Position within that list.
        var itemRank: Int

        init(dueAt: Date?, listRank: Int, itemRank: Int, now: Date) {
            if let dueAt {
                bucket = dueAt < now ? 0 : 1
                due = dueAt
            } else {
                bucket = 2
                due = .distantFuture
            }
            self.listRank = listRank
            self.itemRank = itemRank
        }

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            // Within overdue this puts the *oldest* first — three days late is
            // more likely to have been forgotten than an hour late.
            if lhs.due != rhs.due { return lhs.due < rhs.due }
            if lhs.listRank != rhs.listRank { return lhs.listRank < rhs.listRank }
            return lhs.itemRank < rhs.itemRank
        }
    }
}

// MARK: - Storage

/// Where the snapshot lives: a file in the App Group container both the app and
/// its widget extension can reach.
///
/// A file rather than `UserDefaults`, because the snapshot is a single value
/// written whole and read whole, and because a shared defaults suite invites
/// unrelated keys into a container the extension has to load in full.
enum WidgetSnapshotStore {
    /// Must match the App Group on all four targets: both apps and both widget
    /// extensions. The phone's container and the watch's are separate stores
    /// that happen to share an identifier — they are different devices.
    static let appGroup = "group.com.afzaalahmadzeeshan.ios.twodos"

    /// Anything reading this is on a UI path, so a missing or unreadable file
    /// resolves to `.empty` rather than throwing. The widget renders "not signed
    /// in" and the user opens the app, which is the correct recovery for every
    /// failure this can have.
    static func load() -> WidgetSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder.widget.decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Returns whether anything actually changed.
    ///
    /// The caller uses this to decide whether to ask WidgetKit for a reload.
    /// Reloads are a budgeted resource — spending one on a write that changed
    /// nothing costs a real refresh later in the day, which is why every write
    /// path here compares first.
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = fileURL else { return false }

        // `generatedAt` moves on every write by definition, so it is excluded
        // from the comparison — otherwise nothing would ever compare equal and
        // the check would be worthless.
        var previous = load()
        previous.generatedAt = snapshot.generatedAt
        guard previous != snapshot else { return false }

        guard let data = try? JSONEncoder.widget.encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget-snapshot.json")
    }
}

private extension JSONDecoder {
    static let widget: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

private extension JSONEncoder {
    static let widget: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
}
