import Foundation

/// String constants the API treats as enums.
///
/// The server sends and expects these exact namespaced strings. They are kept
/// as raw values rather than plain Swift enums so an unrecognised value from a
/// newer server build degrades to "unknown" instead of failing to decode the
/// entire list.
enum APIConstants {
    enum ChallengeEndReason {
        static let earlyFinish = "CHALLENGE::END::EARLY_FINISH"
        static let deadline    = "CHALLENGE::END::DEADLINE"
        static let cancelled   = "CHALLENGE::END::CANCELLED"
    }


    enum InviteStatus {
        static let pending = "TODOS::INVITE_STATUS::PENDING"
        static let accepted = "TODOS::INVITE_STATUS::ACCEPTED"
        static let rejected = "TODOS::INVITE_STATUS::REJECTED"
    }

    enum Priority {
        static let urgent = "TODOLIST::PRIORITY::URGENT"
        static let nonUrgent = "TODOLIST::PRIORITY::NONURGENT"
    }

    enum LocationTrigger {
        static let arrive = "ARRIVE"
        static let leave = "LEAVE"
    }

    enum AlarmTarget {
        static let selfOnly = "ALARM::TARGET::SELF"
        static let partner = "ALARM::TARGET::PARTNER"
        static let both = "ALARM::TARGET::BOTH"
    }

    enum AlarmRepeat {
        static let none = "ALARM::REPEAT::NONE"
        static let daily = "ALARM::REPEAT::DAILY"
        static let weekly = "ALARM::REPEAT::WEEKLY"
        static let monthly = "ALARM::REPEAT::MONTHLY"
        static let all = [none, daily, weekly, monthly]
    }

    enum NotificationType {
        static let inviteReceived = "NOTIFICATION::INVITE_RECEIVED"
        static let inviteAccepted = "NOTIFICATION::INVITE_ACCEPTED"
        static let listDeleted = "NOTIFICATION::LIST_DELETED"
        static let alarmFired = "NOTIFICATION::ALARM_FIRED"
        static let geofence = "NOTIFICATION::GEOFENCE"
        static let system = "NOTIFICATION::SYSTEM"
    }

    enum ReportType {
        static let spam = "REPORT::TYPE::SPAM"
        static let harassment = "REPORT::TYPE::HARASSMENT"
        static let inappropriate = "REPORT::TYPE::INAPPROPRIATE_CONTENT"
        static let other = "REPORT::TYPE::OTHER"

        static let all: [(value: String, title: String)] = [
            (spam, "Spam"),
            (harassment, "Harassment"),
            (inappropriate, "Inappropriate content"),
            (other, "Something else")
        ]
    }

    /// The platform token the API ties a session to. It must be byte-identical
    /// between `login` and `refresh` — a mismatch revokes every session on the
    /// account, which is a nasty way to find out you typo'd a string.
    static let platform = "PLATFORM::IOS"
}

// MARK: - Domain-friendly wrappers

/// Priority as the UI thinks about it, decoupled from the wire format.
enum ListPriority: String, CaseIterable, Identifiable, Sendable {
    case urgent, nonUrgent

    var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .urgent: APIConstants.Priority.urgent
        case .nonUrgent: APIConstants.Priority.nonUrgent
        }
    }

    var title: String {
        switch self {
        case .urgent: String(localized: "Urgent")
        case .nonUrgent: String(localized: "Not urgent")
        }
    }

    var icon: String {
        switch self {
        case .urgent: "exclamationmark.2"
        case .nonUrgent: "tortoise"
        }
    }

    /// Sort weight, highest first.
    var weight: Int {
        switch self {
        case .urgent: 2
        case .nonUrgent: 0
        }
    }

    init?(apiValue: String?) {
        switch apiValue {
        case APIConstants.Priority.urgent: self = .urgent
        case APIConstants.Priority.nonUrgent: self = .nonUrgent
        default: return nil
        }
    }
}

/// Whether a location reminder fires on the way in or on the way out.
enum GeofenceTrigger: String, CaseIterable, Identifiable, Sendable {
    case arrive = "ARRIVE"
    case leave = "LEAVE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrive: String(localized: "When I arrive")
        case .leave: String(localized: "When I leave")
        }
    }

    var shortTitle: String {
        switch self {
        case .arrive: String(localized: "Arrive")
        case .leave: String(localized: "Leave")
        }
    }

    var icon: String {
        switch self {
        case .arrive: "figure.walk.arrival"
        case .leave: "figure.walk.departure"
        }
    }

    init(apiValue: String?) {
        self = apiValue == GeofenceTrigger.leave.rawValue ? .leave : .arrive
    }
}

/// Who a deadline's alarm should reach.
enum AlarmTarget: String, CaseIterable, Identifiable, Sendable {
    case me, partner, both

    var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .me: APIConstants.AlarmTarget.selfOnly
        case .partner: APIConstants.AlarmTarget.partner
        case .both: APIConstants.AlarmTarget.both
        }
    }

    var title: String {
        switch self {
        case .me: String(localized: "Only me")
        case .partner: String(localized: "Only my partner")
        case .both: String(localized: "Both of us")
        }
    }

    var icon: String {
        switch self {
        case .me: "person"
        case .partner: "person.badge.clock"
        case .both: "person.2"
        }
    }
}

/// How often an alarm repeats.
enum AlarmRepeat: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekly, monthly

    var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .never: APIConstants.AlarmRepeat.none
        case .daily: APIConstants.AlarmRepeat.daily
        case .weekly: APIConstants.AlarmRepeat.weekly
        case .monthly: APIConstants.AlarmRepeat.monthly
        }
    }

    var title: String {
        switch self {
        case .never: String(localized: "Once")
        case .daily: String(localized: "Every day")
        case .weekly: String(localized: "Every week")
        case .monthly: String(localized: "Every month")
        }
    }

    init(apiValue: String?) {
        switch apiValue {
        case APIConstants.AlarmRepeat.daily: self = .daily
        case APIConstants.AlarmRepeat.weekly: self = .weekly
        case APIConstants.AlarmRepeat.monthly: self = .monthly
        default: self = .never
        }
    }
}

/// How the lists screen is ordered. Persisted by raw value.
enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case lastUpdated, alphabetical, priority, created, deadline, manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastUpdated: String(localized: "Recently used")
        case .alphabetical: String(localized: "Name")
        case .priority: String(localized: "Priority")
        case .created: String(localized: "Date created")
        case .deadline: String(localized: "Deadline")
        case .manual: String(localized: "Custom order")
        }
    }

    var subtitle: String {
        switch self {
        case .lastUpdated: String(localized: "Most recently touched first")
        case .alphabetical: String(localized: "A to Z")
        case .priority: String(localized: "Urgent lists first")
        case .created: String(localized: "Newest first")
        case .deadline: String(localized: "Soonest deadline first")
        case .manual: String(localized: "The order you arranged")
        }
    }

    var icon: String {
        switch self {
        case .lastUpdated: "clock.arrow.circlepath"
        case .alphabetical: "textformat.abc"
        case .priority: "exclamationmark.2"
        case .created: "calendar"
        case .deadline: "hourglass"
        case .manual: "hand.draw"
        }
    }
}
