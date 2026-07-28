import WidgetKit
import SwiftUI

/// One rendering of the widget, at one moment.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot

    /// The items still worth showing at `date`, recomputed per entry so a row
    /// does not linger after it has been dealt with in the app.
    var upNext: [WidgetTodo] { snapshot.upNext }
}

/// Feeds every widget in both bundles from the file the app writes.
///
/// ## Where the timeline comes from
/// The content only changes when the app writes a new snapshot, and the app
/// asks for a reload when it does — so the timeline is not really about new
/// data. It is about *time passing*: an item due at 14:00 must start looking
/// overdue at 14:01 without the app having run in between.
///
/// So entries are placed at the deadlines themselves. Each one is the moment a
/// row changes how it reads, and between them there is nothing to redraw. This
/// is far cheaper than a fixed short interval and far more accurate than a long
/// one — a widget refreshing every fifteen minutes is both wasteful and, for the
/// fourteen minutes after a deadline passes, wrong.
struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder)
    }

    /// The widget gallery asks for this. It gets the sample rather than the
    /// user's real lists, which would otherwise be on display in a picker the
    /// user is scrolling past other people's widgets in.
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? WidgetSnapshot.sample : WidgetSnapshotStore.load()
        completion(SnapshotEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let now = Date.now

        var dates: [Date] = [now]

        // A moment just past each upcoming deadline, so the row flips to
        // "overdue" on time rather than at the next arbitrary refresh.
        for todo in snapshot.upNext {
            guard let due = todo.dueAt, due > now else { continue }
            dates.append(due.addingTimeInterval(1))
        }

        // Midnight, because "Today" and "Tomorrow" are wrong the instant the
        // date changes and nothing else would catch it.
        if let midnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) {
            dates.append(midnight)
        }

        // A backstop so a widget whose app has not run in days eventually
        // notices it is stale and says so.
        dates.append(now.addingTimeInterval(6 * 60 * 60))

        let entries = dates
            .filter { $0 >= now }
            .sorted()
            .prefix(12)
            .map { SnapshotEntry(date: $0, snapshot: snapshot) }

        completion(Timeline(
            entries: Array(entries),
            // The app drives real content changes with an explicit reload; this
            // only decides when to ask again for the time-based ones.
            policy: .after(dates.max() ?? now.addingTimeInterval(6 * 60 * 60))
        ))
    }
}
