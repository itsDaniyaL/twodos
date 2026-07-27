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
        locationLabel: String? = nil
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
    }

    var openCount: Int { items.count { !$0.done } }
    var doneCount: Int { items.count(where: \.done) }
    var isComplete: Bool { !items.isEmpty && openCount == 0 }

    var isOverdue: Bool {
        guard let dueAt else { return false }
        return dueAt < .now
    }
}

struct WatchItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var done: Bool
    let dueAt: Date?

    var isOverdue: Bool {
        guard !done, let dueAt else { return false }
        return dueAt < .now
    }
}

// MARK: - Building the payload

extension WatchList {
    /// Builds the watch payload from the phone's full model.
    ///
    /// Archived lists and lists with an unanswered invite are dropped: neither
    /// is actionable from the wrist, and both would be noise in a short list.
    static func snapshot(
        from lists: [TodoList],
        currentUserId: String?,
        partnerNames: [String: String] = [:]
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
                        .map { WatchItem(id: $0.id, title: $0.title, done: $0.done, dueAt: $0.doBefore) },
                    dueAt: list.doBefore,
                    isShared: !list.isEffectivelyPersonal(currentUserId: currentUserId),
                    isFavorite: list.favorite,
                    partnerName: list.isEffectivelyPersonal(currentUserId: currentUserId)
                        ? nil
                        : list.partnerId.flatMap { partnerNames[$0] },
                    locationLabel: list.hasLocation
                        ? "\(list.trigger.shortTitle) at \(list.locationName ?? "a saved place")"
                        : nil
                )
            }
    }
}
