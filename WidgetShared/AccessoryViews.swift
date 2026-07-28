import SwiftUI
import WidgetKit

/// The small surfaces: iOS Lock Screen widgets and watchOS complications.
///
/// These share one file because they are the same problem. Both are rendered
/// into a fixed, very small area; both are usually drawn in a single tint the
/// system chooses, so colour cannot be relied on to carry meaning; and both are
/// glanced at rather than read. What survives that is a number and, at most, one
/// short phrase.

// MARK: - Circular

/// A count, sized to fill the ring.
///
/// It shows *overdue* when there is any, and open otherwise. That switch is the
/// whole design: a single digit is all this surface can hold, so it has to be
/// the digit that would change what the user does next.
struct AccessoryCircularContent: View {
    let snapshot: WidgetSnapshot
    var now: Date = .now

    private var isAlarming: Bool { snapshot.overdueCount > 0 }

    private var count: Int {
        isAlarming ? snapshot.overdueCount : snapshot.openCount
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            if !snapshot.isSignedIn {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title3)
            } else if snapshot.openCount == 0 {
                Image(systemName: "checkmark")
                    .font(.title2.weight(.semibold))
            } else {
                VStack(spacing: -1) {
                    Image(systemName: isAlarming ? "exclamationmark.triangle.fill" : "checklist")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(count)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetPresentation.accessibleSummary(snapshot))
    }
}

// MARK: - Inline

/// One line, drawn in the system's font beside the time on the Lock Screen or
/// above the face on the watch. No layout of its own — one image, one string.
struct AccessoryInlineContent: View {
    let snapshot: WidgetSnapshot
    var now: Date = .now

    var body: some View {
        if !snapshot.isSignedIn {
            Label("Sign in to twodos", systemImage: "person.crop.circle.badge.questionmark")
        } else if let todo = snapshot.headline {
            // The most pressing item, named. A bare count here would waste the
            // one surface that has room for actual words.
            Label(
                todo.dueAt.map { "\(WidgetPresentation.compactDue($0, now: now)) · \(todo.title)" }
                    ?? todo.title,
                systemImage: snapshot.overdueCount > 0 ? "exclamationmark.circle.fill" : "checklist"
            )
        } else {
            Label("All clear", systemImage: "checkmark.circle")
        }
    }
}

// MARK: - Rectangular

/// Three lines: how much, what next, and where it lives.
///
/// This is the richest of the small surfaces and the only one that can carry a
/// task's actual name at a readable size, so it leads with the item rather than
/// the count — the count is already on the circular one.
struct AccessoryRectangularContent: View {
    let snapshot: WidgetSnapshot
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !snapshot.isSignedIn {
                Text("twodos").font(.headline)
                Text("Open the app to sign in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let todo = snapshot.headline {
                HStack(spacing: 3) {
                    Text(WidgetPresentation.summary(snapshot))
                        .font(.caption.weight(.semibold))
                        .widgetAccentable()
                    if let due = todo.dueAt {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(WidgetPresentation.compactDue(due, now: now))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)

                Text(todo.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                // On a watch face this is the only line with room for context,
                // so it carries the collaborator too — "Weekend trip · Sam"
                // answers "whose is this?" without a second complication.
                Text(WidgetPresentation.context(todo))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("All clear").font(.headline).widgetAccentable()
                Text("Nothing outstanding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WidgetPresentation.accessibleSummary(snapshot))
    }
}

// MARK: - Corner (watchOS)

#if os(watchOS)
/// The corner of a watch face: a glyph in the corner itself, with a curved label
/// running along the bezel. The label gets the words because it has the room;
/// the corner gets the number.
struct AccessoryCornerContent: View {
    let snapshot: WidgetSnapshot
    var now: Date = .now

    var body: some View {
        Text("\(snapshot.overdueCount > 0 ? snapshot.overdueCount : snapshot.openCount)")
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .widgetLabel {
                Text(WidgetPresentation.summary(snapshot))
            }
            .accessibilityLabel(WidgetPresentation.accessibleSummary(snapshot))
    }
}
#endif
