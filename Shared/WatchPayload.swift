import Foundation

/// The compact list shape the phone sends to the watch.
///
/// `TodoList` carries a lot the watch will never draw — invite state, colours as
/// hex, geofence coordinates, timestamps. `WCSession` application context has a
/// hard size limit, so this trims to what a 45mm screen can actually show and
/// keeps the payload small enough that a user with thirty lists still syncs.
struct WatchList: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// Index into ``ListTint/all``, rather than a hex string, so the watch
    /// resolves the same muted colour the phone uses without shipping the table.
    let tintIndex: Int
    /// Mutable so the watch can apply an optimistic tick before the API confirms.
    var items: [WatchItem]
    let dueAt: Date?
    let isShared: Bool
    let isFavorite: Bool

    /// Who the list is shared with, already resolved to a display name.
    ///
    /// The watch has no partner directory of its own, so sending the id would
    /// leave it holding a UUID it cannot render. Both of these are resolved and
    /// phrased on the phone, which keeps the watch a pure view of what it is
    /// handed — the same reason `tintIndex` is an index rather than a hex.
    var partnerName: String?
    /// Phrased for the wrist, e.g. "Arrive at Tesco Metro".
    var locationLabel: String?
    /// The partner's profile picture, as an absolute URL, or nil for none.
    ///
    /// A URL rather than bytes: the application context has a hard size
    /// ceiling and one JPEG would spend most of it. The URL is public and
    /// immutable on the server, so the watch loads it once with a plain
    /// `AsyncImage` and the system cache keeps it — the same mechanism the
    /// phone uses, and one that costs the payload thirty bytes.
    var partnerAvatarUrl: String?

    // Defaulted so a watch still running the previous build can decode a
    // payload from the newer phone rather than dropping every list.
    init(
        id: String,
        label: String,
        tintIndex: Int,
        items: [WatchItem],
        dueAt: Date?,
        isShared: Bool,
        isFavorite: Bool,
        partnerName: String? = nil,
        locationLabel: String? = nil,
        partnerAvatarUrl: String? = nil
    ) {
        self.id = id
        self.label = label
        self.tintIndex = tintIndex
        self.items = items
        self.dueAt = dueAt
        self.isShared = isShared
        self.isFavorite = isFavorite
        self.partnerName = partnerName
        self.locationLabel = locationLabel
        self.partnerAvatarUrl = partnerAvatarUrl
    }

    var partnerAvatarURL: URL? { partnerAvatarUrl.flatMap(URL.init(string:)) }

    /// Initials for the partner, for the moment before the picture loads and
    /// for partners who have none. Derived here so the watch needs no
    /// name-parsing of its own.
    var partnerInitials: String? {
        guard let partnerName else { return nil }
        let parts = partnerName.split(separator: " ").prefix(2)
        if parts.count == 2 { return parts.map { String($0.prefix(1)) }.joined().uppercased() }
        return String(partnerName.prefix(1)).uppercased()
    }

    var openCount: Int { items.count { !$0.done } }
    var doneCount: Int { items.count(where: \.done) }
    var isComplete: Bool { !items.isEmpty && openCount == 0 }

    /// Matches `TodoList.isOverdue` — a finished list is not overdue, so it
    /// neither reddens on the wrist nor sorts above live work.
    var isOverdue: Bool {
        guard !isComplete, let dueAt else { return false }
        return dueAt < .now
    }
}

struct WatchItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var done: Bool
    let dueAt: Date?
    /// The item's notes, read-only on the wrist. Capped on the phone side so a
    /// long note on every item cannot push the payload past the context limit.
    var notes: String?

    // Defaulted so a watch on the previous build still decodes a payload from a
    // phone that now sends notes — the same rule `WatchList` follows.
    init(id: String, title: String, done: Bool, dueAt: Date?, notes: String? = nil) {
        self.id = id
        self.title = title
        self.done = done
        self.dueAt = dueAt
        self.notes = notes
    }

    var isOverdue: Bool {
        guard !done, let dueAt else { return false }
        return dueAt < .now
    }
}

extension WatchItem {
    /// Enough for a watch to show what the note says; the phone has the rest.
    /// Forty items at this length is still comfortably inside the application
    /// context budget with twenty-five lists.
    static let notesLimit = 200
}

// MARK: - Building the payload

extension WatchList {
    /// `partnerNames` and `partnerAvatarURLs` for `snapshot(from:…)`, from a
    /// partners list. Shared by the phone's push and the watch's own refresh so
    /// both resolve a partner the same way. Avatar URLs are made absolute here,
    /// because the watch must not have to know the API host to draw a face.
    static func partnerLookups(_ partners: [Partner]) -> (names: [String: String], avatars: [String: String]) {
        let names = Dictionary(partners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let avatars = Dictionary(
            partners.compactMap { partner in partner.avatarURL.map { (partner.id, $0.absoluteString) } },
            uniquingKeysWith: { first, _ in first }
        )
        return (names, avatars)
    }

    /// Builds the watch payload from the phone's full model.
    ///
    /// Archived lists and lists with an unanswered invite are dropped: neither
    /// is actionable from the wrist, and both would be noise in a short list.
    static func snapshot(
        from lists: [TodoList],
        currentUserId: String?,
        partnerNames: [String: String] = [:],
        partnerAvatarURLs: [String: String] = [:]
    ) -> [WatchList] {
        lists
            .filter { !$0.archived && !($0.isPendingInvite && $0.createdBy != currentUserId) }
            .sorted { lhs, rhs in
                // Same ordering logic the phone's "Recently used" uses, so the
                // two devices agree on what belongs at the top.
                if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
                if lhs.favorite != rhs.favorite { return lhs.favorite }
                return (lhs.effectiveUpdatedAt ?? .distantPast) > (rhs.effectiveUpdatedAt ?? .distantPast)
            }
            .prefix(25)
            .map { list in
                WatchList(
                    id: list.id,
                    label: list.label,
                    tintIndex: ListTint.all.firstIndex { $0.hex == list.tint.hex } ?? 0,
                    // Open items first, and cap the tail: nobody scrolls to item
                    // 60 on a watch, and the payload has a size ceiling.
                    items: list.todos
                        .sorted { !$0.done && $1.done }
                        .prefix(40)
                        .map {
                            WatchItem(
                                id: $0.id,
                                title: $0.title,
                                done: $0.done,
                                dueAt: $0.doBefore,
                                notes: $0.notes.map { String($0.prefix(WatchItem.notesLimit)) }
                            )
                        },
                    dueAt: list.doBefore,
                    isShared: !list.isEffectivelyPersonal(currentUserId: currentUserId),
                    isFavorite: list.favorite,
                    partnerName: list.isEffectivelyPersonal(currentUserId: currentUserId)
                        ? nil
                        : list.partnerId.flatMap { partnerNames[$0] },
                    locationLabel: list.hasLocation
                        ? "\(list.trigger.shortTitle) at \(list.locationName ?? "a saved place")"
                        : nil,
                    partnerAvatarUrl: list.isEffectivelyPersonal(currentUserId: currentUserId)
                        ? nil
                        : list.partnerId.flatMap { partnerAvatarURLs[$0] }
                )
            }
    }
}
