import Foundation

// MARK: - From the phone's model

extension WidgetSnapshot {
    /// Builds the phone's snapshot from the full model.
    ///
    /// ## What counts as outstanding
    /// Archived lists and unanswered invites are excluded throughout — neither
    /// is work the user has agreed to, and counting them makes the headline
    /// number wrong in a way that is invisible from the Home Screen.
    ///
    /// ## Inherited deadlines
    /// An item with no deadline of its own inherits its list's. This is what
    /// makes the widget useful for the very common shape of "the list is due
    /// Friday, the items are just items" — without it those items sort as
    /// undated and a genuinely urgent list never surfaces. The row says so, so
    /// the user is not told an item has a deadline it does not have.
    static func make(
        from lists: [TodoList],
        currentUserId: String?,
        isSignedIn: Bool,
        partnerNames: [String: String] = [:],
        now: Date = .now
    ) -> WidgetSnapshot {
        guard isSignedIn else { return .empty }

        let active = lists
            .filter { !$0.archived && !$0.isPendingInvite }
            .sorted { lhs, rhs in
                // The same ordering the app's own home screen uses, so the
                // widget and the app agree about what matters.
                if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
                if lhs.favorite != rhs.favorite { return lhs.favorite }
                return (lhs.effectiveUpdatedAt ?? .distantPast) > (rhs.effectiveUpdatedAt ?? .distantPast)
            }

        var candidates: [(key: WidgetRanking.Key, todo: WidgetTodo)] = []
        var refs: [ListRef] = []
        var openCount = 0
        var overdueCount = 0
        var dueTodayCount = 0
        var listsWithWork = 0

        let calendar = Calendar.current

        for (listRank, list) in active.enumerated() {
            let open = list.todos.filter { !$0.done }

            // Recorded before the `open.isEmpty` check below: Siri must be able
            // to add an item to an empty list, which is exactly the list that
            // would otherwise be missing from this index.
            refs.append(ListRef(
                id: list.id,
                label: list.label,
                tintIndex: ListTint.all.firstIndex { $0.hex == list.tint.hex } ?? 0,
                openCount: open.count
            ))

            guard !open.isEmpty else { continue }

            listsWithWork += 1
            openCount += open.count

            let isShared = !list.isEffectivelyPersonal(currentUserId: currentUserId)
            // Only for lists that genuinely have a second person on them: a solo
            // list whose `partnerId` points back at the creator would otherwise
            // be labelled with the user's own name.
            let partnerName = isShared ? list.partnerId.flatMap({ partnerNames[$0] }) : nil
            let tintIndex = ListTint.all.firstIndex { $0.hex == list.tint.hex } ?? 0
            let placeLabel = list.hasLocation
                ? "\(list.trigger.shortTitle) at \(list.locationName ?? "a saved place")"
                : nil

            for (itemRank, todo) in open.enumerated() {
                // The item's own deadline wins; the list's is the fallback.
                let inherited = todo.doBefore == nil
                let due = todo.doBefore ?? list.doBefore

                if let due {
                    if due < now { overdueCount += 1 }
                    else if calendar.isDate(due, inSameDayAs: now) { dueTodayCount += 1 }
                }

                // Counting covers every open item; only the first few from any
                // one list compete for a row.
                guard itemRank < WidgetRanking.perList else { continue }

                candidates.append((
                    WidgetRanking.Key(dueAt: due, listRank: listRank, itemRank: itemRank, now: now),
                    WidgetTodo(
                        id: todo.id,
                        title: todo.title,
                        listId: list.id,
                        listLabel: list.label,
                        tintIndex: tintIndex,
                        dueAt: due,
                        isListDeadline: inherited && due != nil,
                        placeLabel: placeLabel,
                        isShared: isShared,
                        partnerName: partnerName
                    )
                ))
            }
        }

        return WidgetSnapshot(
            generatedAt: now,
            isSignedIn: true,
            openCount: openCount,
            overdueCount: overdueCount,
            dueTodayCount: dueTodayCount,
            listCount: listsWithWork,
            upNext: candidates
                .sorted { $0.key < $1.key }
                .prefix(WidgetRanking.capacity)
                .map(\.todo),
            lists: refs
        )
    }
}

// MARK: - From the watch's model

extension WidgetSnapshot {
    /// Builds the watch's snapshot from the payload it already holds.
    ///
    /// The watch never sees `TodoList`; it is handed ``WatchList`` over
    /// `WCSession`. That payload is already filtered and ranked by the phone, so
    /// this does less work than its counterpart above — but it produces the
    /// identical shape, which is what lets both widget bundles share every view.
    static func make(
        fromWatch lists: [WatchList],
        isSignedIn: Bool,
        now: Date = .now
    ) -> WidgetSnapshot {
        guard isSignedIn else { return .empty }

        var candidates: [(key: WidgetRanking.Key, todo: WidgetTodo)] = []
        var refs: [ListRef] = []
        var openCount = 0
        var overdueCount = 0
        var dueTodayCount = 0
        var listsWithWork = 0

        let calendar = Calendar.current

        for (listRank, list) in lists.enumerated() {
            let open = list.items.filter { !$0.done }

            refs.append(ListRef(
                id: list.id,
                label: list.label,
                tintIndex: list.tintIndex,
                openCount: open.count
            ))

            guard !open.isEmpty else { continue }

            listsWithWork += 1
            openCount += open.count

            for (itemRank, item) in open.enumerated() {
                let inherited = item.dueAt == nil
                let due = item.dueAt ?? list.dueAt

                if let due {
                    if due < now { overdueCount += 1 }
                    else if calendar.isDate(due, inSameDayAs: now) { dueTodayCount += 1 }
                }

                guard itemRank < WidgetRanking.perList else { continue }

                candidates.append((
                    WidgetRanking.Key(dueAt: due, listRank: listRank, itemRank: itemRank, now: now),
                    WidgetTodo(
                        id: item.id,
                        title: item.title,
                        listId: list.id,
                        listLabel: list.label,
                        tintIndex: list.tintIndex,
                        dueAt: due,
                        isListDeadline: inherited && due != nil,
                        placeLabel: list.locationLabel,
                        isShared: list.isShared,
                        // Already resolved by the phone before it left — the
                        // watch has no partner directory either.
                        partnerName: list.partnerName
                    )
                ))
            }
        }

        return WidgetSnapshot(
            generatedAt: now,
            isSignedIn: true,
            openCount: openCount,
            overdueCount: overdueCount,
            dueTodayCount: dueTodayCount,
            listCount: listsWithWork,
            upNext: candidates
                .sorted { $0.key < $1.key }
                .prefix(WidgetRanking.capacity)
                .map(\.todo),
            lists: refs
        )
    }
}
