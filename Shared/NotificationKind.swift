import Foundation

/// The kind of notification, which decides its category and therefore the
/// actions offered on long-press.
///
/// ## Why this is shared
/// The phone registers these category identifiers; the watch matches on them to
/// pick a glyph and colour for its long-look interface. Both sides had the same
/// four string literals typed out separately, which is a drift waiting to
/// happen — a typo on either side shows the wrong thing on a real notification
/// and nothing catches it at build time.
enum NotificationKind: String, CaseIterable, Sendable {
    case deadline, alarm, geofence, social

    /// The `UNNotificationCategory` identifier. The wire format between the two
    /// devices, so these strings are fixed.
    var identifier: String {
        switch self {
        case .deadline: "TWODOS_DEADLINE"
        case .alarm: "TWODOS_ALARM"
        case .geofence: "TWODOS_GEOFENCE"
        case .social: "TWODOS_SOCIAL"
        }
    }

    /// Resolves an incoming category identifier.
    ///
    /// Falls back to `.deadline` rather than failing: an unrecognised category
    /// is far more likely to be a newer phone build than something novel, and
    /// drawing it as a deadline is right in that case and harmless otherwise.
    init(identifier: String) {
        self = Self.allCases.first { $0.identifier == identifier } ?? .deadline
    }
}
