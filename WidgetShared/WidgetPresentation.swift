import SwiftUI
import WidgetKit

/// Phrasing and colour for the widgets.
///
/// The app's own ``Format`` is written for a screen you are looking *at*; a
/// widget is read in passing, at a glance, often at a third the size. So the
/// deadline strings here are shorter than the app's — "2d late" rather than
/// "2 days overdue" — and there is a hard rule that no label may wrap.
enum WidgetPresentation {

    // MARK: - Colour

    /// Resolves a tint index back to the app's palette.
    ///
    /// Defensive about the index because the snapshot on disk may have been
    /// written by a previous build with a different table. A colour that is
    /// merely wrong is survivable; a crash in a widget extension shows the user
    /// a blank rectangle they cannot do anything about.
    static func tint(_ index: Int) -> Color {
        guard ListTint.all.indices.contains(index) else { return ListTint.all[0].color }
        return ListTint.all[index].color
    }

    // MARK: - Deadlines

    /// A deadline in as few characters as will still carry the meaning.
    ///
    /// Widgets are laid out at fixed sizes with no scrolling, so a label that
    /// grows pushes something else out of the frame entirely. The app's
    /// full-length phrasing is kept for the app.
    static func compactDue(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let interval = date.timeIntervalSince(now)

        if interval < 0 {
            let late = -interval
            if late < 3600 { return "\(max(1, Int(late / 60)))m late" }
            if calendar.isDateInToday(date) { return "\(Int(late / 3600))h late" }
            let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
            if days < 7 { return "\(max(1, days))d late" }
            return "Late · \(Format.shortDate(date))"
        }

        if interval < 60 { return "Now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if calendar.isDateInToday(date) { return Format.time(date) }
        if calendar.isDateInTomorrow(date) { return "Tmrw \(Format.time(date))" }

        let days = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return Format.shortDate(date)
    }

    /// Overdue is the only state that earns red. Everything else stays quiet, so
    /// a glance at the Home Screen tells the user whether anything is actually
    /// wrong without them having to read a word.
    static func dueTint(_ date: Date, now: Date = .now) -> Color {
        Format.deadlineTint(date, reference: now)
    }

    // MARK: - Summary phrasing

    /// The one line that answers "how am I doing?".
    ///
    /// Ordered by what the user most needs to know: lateness first, then
    /// today's load, then the raw total. Only one of them is ever shown,
    /// because a widget that says three things says none of them.
    static func summary(_ snapshot: WidgetSnapshot) -> String {
        if !snapshot.isSignedIn { return "Sign in to twodos" }
        if snapshot.openCount == 0 { return "All clear" }
        if snapshot.overdueCount > 0 {
            return "\(snapshot.overdueCount) overdue"
        }
        if snapshot.dueTodayCount > 0 {
            return "\(snapshot.dueTodayCount) due today"
        }
        return "\(snapshot.openCount) open"
    }

    /// "Weekend trip · Sam" — where a task lives and who else is on it, as one
    /// string for the surfaces too small to lay the two out separately.
    ///
    /// The separator is a middot rather than "with", because at caption size the
    /// word costs more room than it earns and the person glyph beside it has
    /// already said what the relationship is.
    static func context(_ todo: WidgetTodo) -> String {
        guard let partner = todo.partnerName else { return todo.listLabel }
        return "\(todo.listLabel) · \(partner)"
    }

    /// Spoken form, which should never be an abbreviation.
    static func accessibleSummary(_ snapshot: WidgetSnapshot) -> String {
        guard snapshot.isSignedIn else { return "Not signed in to twodos" }
        if snapshot.openCount == 0 { return "Nothing outstanding" }
        var parts = ["\(snapshot.openCount) open item\(snapshot.openCount == 1 ? "" : "s")"]
        if snapshot.overdueCount > 0 { parts.append("\(snapshot.overdueCount) overdue") }
        if snapshot.dueTodayCount > 0 { parts.append("\(snapshot.dueTodayCount) due today") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sample data

extension WidgetSnapshot {
    /// What the widget gallery and Xcode previews show.
    ///
    /// Deliberately not "all clear": a user choosing a widget wants to see what
    /// it looks like carrying real information, and an empty preview sells
    /// nothing. The deadlines are relative to `now` so the sample never ages
    /// into a screen full of overdue rows.
    static var sample: WidgetSnapshot {
        let now = Date.now
        return WidgetSnapshot(
            generatedAt: now,
            isSignedIn: true,
            openCount: 11,
            overdueCount: 1,
            dueTodayCount: 3,
            listCount: 4,
            upNext: [
                WidgetTodo(
                    id: "1", title: "Renew the parking permit",
                    listId: "a", listLabel: "Admin", tintIndex: 2,
                    dueAt: now.addingTimeInterval(-3 * 3600)
                ),
                WidgetTodo(
                    id: "2", title: "Book the table for eight",
                    listId: "b", listLabel: "Weekend trip", tintIndex: 5,
                    dueAt: now.addingTimeInterval(4 * 3600),
                    isShared: true, partnerName: "Sam"
                ),
                WidgetTodo(
                    id: "3", title: "Oat milk, bread, coffee",
                    listId: "c", listLabel: "Groceries", tintIndex: 1,
                    dueAt: now.addingTimeInterval(26 * 3600), isListDeadline: true,
                    placeLabel: "Arrive at Tesco Metro"
                ),
                WidgetTodo(
                    id: "4", title: "Reply to the landlord",
                    listId: "a", listLabel: "Admin", tintIndex: 2,
                    dueAt: now.addingTimeInterval(3 * 86_400)
                ),
                WidgetTodo(
                    id: "5", title: "Pick up the dry cleaning",
                    listId: "d", listLabel: "Errands", tintIndex: 6,
                    // A second, different collaborator: the whole point of
                    // naming them is telling two shared lists apart, which a
                    // sample with only one name would not demonstrate.
                    isShared: true, partnerName: "Alex"
                ),
                WidgetTodo(
                    id: "6", title: "Send the invoice",
                    listId: "a", listLabel: "Admin", tintIndex: 2
                ),
                WidgetTodo(
                    id: "7", title: "Water the plants",
                    listId: "d", listLabel: "Errands", tintIndex: 6
                )
            ]
        )
    }

    /// The placeholder WidgetKit renders while the real one loads. Same shape,
    /// no real content — redaction handles the rest.
    static var placeholder: WidgetSnapshot { sample }
}
