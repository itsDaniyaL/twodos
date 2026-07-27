import SwiftUI

/// Human phrasing for dates and deadlines.
///
/// Deadlines are the app's most-read piece of text, so they are written the way
/// a person would say them — "in 20 minutes", "Tomorrow, 09:00", "3 days
/// overdue" — rather than a bare timestamp the reader has to do arithmetic on.
enum Format {

    // MARK: - Deadlines

    /// A short, human deadline label.
    static func deadline(_ date: Date, reference: Date = .now) -> String {
        let calendar = Calendar.current
        let interval = date.timeIntervalSince(reference)

        if interval < 0 {
            let overdue = -interval
            if overdue < 60 { return "Just now" }
            if overdue < 3600 { return "\(Int(overdue / 60)) min overdue" }
            if calendar.isDateInToday(date) { return "Overdue · \(time(date))" }
            if calendar.isDateInYesterday(date) { return "Overdue since yesterday" }
            let days = calendar.dateComponents([.day], from: date, to: reference).day ?? 0
            if days < 30 { return "\(days) day\(days == 1 ? "" : "s") overdue" }
            return "Overdue · \(shortDate(date))"
        }

        if interval < 60 { return "Due now" }
        if interval < 3600 { return "In \(Int(interval / 60)) min" }
        if calendar.isDateInToday(date) { return "Today, \(time(date))" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow, \(time(date))" }

        let days = calendar.dateComponents([.day], from: reference, to: date).day ?? 0
        if days < 7 { return "\(weekday(date)), \(time(date))" }
        return "\(shortDate(date)), \(time(date))"
    }

    /// The colour a deadline should be drawn in. Overdue is the only state that
    /// earns red; "soon" gets amber and everything else stays neutral so the
    /// list does not look like a fire alarm.
    static func deadlineTint(_ date: Date, reference: Date = .now) -> Color {
        let interval = date.timeIntervalSince(reference)
        if interval < 0 { return Brand.danger }
        if interval < 60 * 60 * 6 { return Brand.warning }
        if interval < 60 * 60 * 48 { return Brand.info }
        return .secondary
    }

    static func deadlineIcon(_ date: Date, reference: Date = .now) -> String {
        date < reference ? "exclamationmark.circle.fill" : "clock"
    }

    // MARK: - Components

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func fullDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "2 hours ago", used in the notification feed and for last-seen.
    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Presence text for a partner.
    static func lastSeen(_ date: Date?) -> String {
        guard let date else { return "Offline" }
        if Date.now.timeIntervalSince(date) < 120 { return "Just now" }
        return "Last seen \(relative(date))"
    }

    // MARK: - Distances

    /// Geofence radius, in the reader's own units.
    static func distance(metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(
                .measurement(width: .abbreviated, usage: .road)
                .locale(.current)
            )
    }

    // MARK: - Counts

    /// "3 of 8 done", or "Empty" — never "0/0".
    static func progress(done: Int, total: Int) -> String {
        if total == 0 { return "No items yet" }
        if done == total { return "All \(total) done" }
        return "\(done) of \(total) done"
    }

    /// A spoken-form progress string for VoiceOver, which should not have to
    /// interpret a slash.
    static func progressAccessible(done: Int, total: Int) -> String {
        if total == 0 { return "Empty list" }
        return "\(done) of \(total) items completed"
    }
}
