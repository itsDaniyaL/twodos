import WidgetKit
import SwiftUI

@main
struct TwodosWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchUpNextWidget()
        WatchStatusWidget()
    }
}

// MARK: - Up next

/// The rectangular complication: the one thing most worth knowing, named.
///
/// A watch face has room for one complication of this size, so it carries the
/// item rather than the count — a number the user cannot act on is worth less
/// on the wrist than a task they can.
struct WatchUpNextWidget: Widget {
    let kind = "twodos.watch.UpNext"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            AccessoryRectangularContent(snapshot: entry.snapshot, now: entry.date)
                .containerBackground(.clear, for: .widget)
                .widgetURL(WatchDestination.of(entry.snapshot))
        }
        .configurationDisplayName("Up next")
        .description("The most pressing thing outstanding.")
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - Status

/// Every small corner of a watch face: circular, inline, and the curved corner.
struct WatchStatusWidget: Widget {
    let kind = "twodos.watch.Status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            WatchStatusView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(WatchDestination.of(entry.snapshot))
        }
        .configurationDisplayName("Outstanding")
        .description("How much is left, at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            AccessoryInlineContent(snapshot: entry.snapshot, now: entry.date)
        case .accessoryCorner:
            AccessoryCornerContent(snapshot: entry.snapshot, now: entry.date)
        default:
            AccessoryCircularContent(snapshot: entry.snapshot, now: entry.date)
        }
    }
}

/// Where a tap on a complication lands.
///
/// Every watch family is too small to aim a tap within, so all of them share one
/// destination: the list behind the headline item, or the lists screen when
/// there is nothing outstanding to point at.
enum WatchDestination {
    static func of(_ snapshot: WidgetSnapshot) -> URL {
        guard snapshot.isSignedIn, let todo = snapshot.headline else {
            return DeepLink.lists.url
        }
        return DeepLink.list(id: todo.listId).url
    }
}

// MARK: - Previews

#Preview("Rectangular", as: .accessoryRectangular) {
    WatchUpNextWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
    SnapshotEntry(date: .now, snapshot: .empty)
}

#Preview("Circular", as: .accessoryCircular) {
    WatchStatusWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview("Corner", as: .accessoryCorner) {
    WatchStatusWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
