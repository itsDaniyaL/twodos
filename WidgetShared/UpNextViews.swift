import SwiftUI
import WidgetKit

// MARK: - One item

/// A single outstanding item, as it appears in every rectangular widget on both
/// platforms.
///
/// The three things on the row are ranked by what a glance needs: **what** it is
/// (the title, full weight), **when** (the only coloured element, so lateness is
/// visible before anything is read), and **where it came from** (the list, in
/// the list's own colour, quietest of the three). Anything else — who shares it,
/// which place it is pinned to — is a small glyph rather than words, because at
/// this size words are what push the title onto a second line.
struct TodoRow: View {
    let todo: WidgetTodo
    var now: Date = .now
    /// Large widgets have the room to name the list; small ones do not.
    var showsList: Bool = true

    private var isOverdue: Bool { todo.isOverdue(asOf: now) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(WidgetPresentation.tint(todo.tintIndex))
                .frame(width: 7, height: 7)
                // Baseline alignment puts a bare circle slightly too low; this
                // sits it on the text's optical centre.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }

            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if showsList {
                    contextLine
                }
            }

            Spacer(minLength: 4)

            if let due = todo.dueAt {
                Text(WidgetPresentation.compactDue(due, now: now))
                    .font(.caption2.weight(isOverdue ? .bold : .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(WidgetPresentation.dueTint(due, now: now))
                    // A list-level deadline is not this item's own deadline, and
                    // showing it as if it were would be a small lie the user
                    // cannot check from here.
                    .italic(todo.isListDeadline)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The quiet line under the title: which list, and who else is on it.
    ///
    /// The collaborator's name replaces the anonymous "shared" glyph rather than
    /// joining it. A glyph could only ever say *that* a task is shared; on a
    /// screen where several lists are shared with different people, the name is
    /// what actually lets you attribute a task without opening anything.
    ///
    /// The list label holds its width and the name gives way, because the list
    /// is what locates the task and the name only qualifies it — a truncated
    /// "Sa…" beside an intact "Weekend trip" is still more use than the reverse.
    private var contextLine: some View {
        HStack(spacing: 4) {
            Text(todo.listLabel)
                .lineLimit(1)
                .layoutPriority(1)

            if todo.isShared {
                Image(systemName: "person.2.fill")
                if let partner = todo.partnerName {
                    Text(partner).lineLimit(1)
                }
            }
            if todo.placeLabel != nil {
                Image(systemName: "mappin.and.ellipse")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var accessibilityLabel: String {
        var parts = [todo.title, "in \(todo.listLabel)"]
        if let partner = todo.partnerName {
            parts.append("shared with \(partner)")
        } else if todo.isShared {
            parts.append("shared")
        }
        if let due = todo.dueAt {
            parts.append(isOverdue
                ? "overdue since \(Format.fullDateTime(due))"
                : "due \(Format.deadline(due, reference: now))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Header

/// The count line above the rows.
///
/// The number is the largest thing in any widget that has one, because it is the
/// only part that can be read without stopping — everything below it requires
/// the user to actually look.
struct SummaryHeader: View {
    let snapshot: WidgetSnapshot
    var now: Date = .now

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(snapshot.openCount)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text("open")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if snapshot.overdueCount > 0 {
                Label("\(snapshot.overdueCount)", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Brand.danger)
                    .accessibilityLabel("\(snapshot.overdueCount) overdue")
            } else if snapshot.dueTodayCount > 0 {
                Label("\(snapshot.dueTodayCount)", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Brand.info)
                    .accessibilityLabel("\(snapshot.dueTodayCount) due today")
            }
        }
    }
}

// MARK: - States that are not a list of items

/// Shown when there is nothing to show, which is three different situations that
/// must not look alike.
///
/// "Signed out" and "all done" both produce an empty list, and a widget that
/// rendered them the same way would tell a signed-out user they were on top of
/// everything. Stale is the third: real data, too old to trust.
struct WidgetPlaceholderState: View {
    enum Kind {
        case signedOut
        case allClear
        case stale(Date)

        var icon: String {
            switch self {
            case .signedOut: "person.crop.circle.badge.questionmark"
            case .allClear: "checkmark.circle.fill"
            case .stale: "arrow.trianglehead.2.clockwise"
            }
        }

        var title: String {
            switch self {
            case .signedOut: "Not signed in"
            case .allClear: "All clear"
            case .stale: "Out of date"
            }
        }

        var message: String {
            switch self {
            case .signedOut: "Open twodos to sign in."
            case .allClear: "Nothing outstanding."
            case .stale(let since): "Last updated \(Format.relative(since))."
            }
        }

        var tint: Color {
            switch self {
            case .signedOut: .secondary
            case .allClear: Brand.success
            case .stale: Brand.warning
            }
        }
    }

    let kind: Kind
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            Image(systemName: kind.icon)
                .font(compact ? .title3 : .title)
                .foregroundStyle(kind.tint)

            Text(kind.title)
                .font(.footnote.weight(.semibold))

            if !compact {
                Text(kind.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title). \(kind.message)")
    }
}

// MARK: - Composition

/// Decides which of the three non-list states applies, if any, so every widget
/// family handles them identically rather than each remembering to.
@ViewBuilder
func widgetContent<Content: View>(
    _ snapshot: WidgetSnapshot,
    now: Date = .now,
    compact: Bool = false,
    @ViewBuilder content: () -> Content
) -> some View {
    if !snapshot.isSignedIn {
        WidgetPlaceholderState(kind: .signedOut, compact: compact)
    } else if snapshot.isStale(asOf: now) {
        WidgetPlaceholderState(kind: .stale(snapshot.generatedAt), compact: compact)
    } else if snapshot.upNext.isEmpty {
        WidgetPlaceholderState(kind: .allClear, compact: compact)
    } else {
        content()
    }
}
