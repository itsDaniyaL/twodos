import WidgetKit
import SwiftUI

@main
struct TwodosWidgets: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        StatusWidget()
    }
}

// MARK: - Up next

/// The main widget: what is outstanding, most pressing first.
///
/// One widget serves every rectangular family rather than shipping a "small"
/// and a "medium" separately, because they are the same information at three
/// densities — the user picks a size, not a different idea.
struct UpNextWidget: Widget {
    let kind = "twodos.UpNext"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            UpNextWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Up next")
        .description("What's outstanding, most pressing first.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular
        ])
    }
}

struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var now: Date { entry.date }

    var body: some View {
        content
            // The families that cannot aim a tap get one destination for the
            // whole widget: the headline item's list if there is one, otherwise
            // the lists screen. Rows in the larger families override this with
            // their own `Link`.
            .widgetURL(wholeWidgetDestination)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular:
            AccessoryRectangularContent(snapshot: snapshot, now: now)
        case .systemSmall:
            small
        case .systemLarge:
            rows(limit: 7)
        default:
            rows(limit: 3)
        }
    }

    private var wholeWidgetDestination: URL {
        guard snapshot.isSignedIn, let todo = snapshot.headline else {
            return DeepLink.lists.url
        }
        return DeepLink.list(id: todo.listId).url
    }

    /// The small square has room for a headline number and exactly one task, so
    /// it commits to those rather than showing three unreadably truncated rows.
    private var small: some View {
        widgetContent(snapshot, now: now, compact: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(snapshot.openCount)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(WidgetPresentation.summary(snapshot))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(snapshot.overdueCount > 0 ? Brand.danger : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let todo = snapshot.headline {
                    Divider().padding(.bottom, 6)
                    TodoRow(todo: todo, now: now, showsList: false)
                    Text(WidgetPresentation.context(todo))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 15)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func rows(limit: Int) -> some View {
        widgetContent(snapshot, now: now) {
            VStack(alignment: .leading, spacing: 6) {
                SummaryHeader(snapshot: snapshot, now: now)

                Divider()

                ForEach(snapshot.upNext.prefix(limit)) { todo in
                    // Medium and large are the only families where a tap can be
                    // aimed, so each row opens its own list. `widgetURL` on the
                    // container would make the whole thing one target and send
                    // every tap to the same place.
                    Link(destination: DeepLink.list(id: todo.listId).url) {
                        TodoRow(todo: todo, now: now)
                    }
                }

                // Says so rather than silently cutting the list off, which would
                // read as "that's everything".
                let remaining = snapshot.openCount - min(limit, snapshot.upNext.count)
                if remaining > 0 {
                    Text("+ \(remaining) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Status

/// A pure count, for the Lock Screen and for anyone who wants the smallest
/// possible reminder that the app exists.
struct StatusWidget: Widget {
    let kind = "twodos.Status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Outstanding")
        .description("How much is left, at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        content.widgetURL(destination)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            AccessoryInlineContent(snapshot: entry.snapshot, now: entry.date)
        default:
            AccessoryCircularContent(snapshot: entry.snapshot, now: entry.date)
        }
    }

    private var destination: URL {
        guard entry.snapshot.isSignedIn, let todo = entry.snapshot.headline else {
            return DeepLink.lists.url
        }
        return DeepLink.list(id: todo.listId).url
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    UpNextWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
    SnapshotEntry(date: .now, snapshot: .empty)
}

#Preview("Medium", as: .systemMedium) {
    UpNextWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview("Large", as: .systemLarge) {
    UpNextWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    UpNextWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview("Circular", as: .accessoryCircular) {
    StatusWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
