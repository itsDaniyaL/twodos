import Foundation
import Observation

/// User-facing notification preferences, layered on top of the system
/// permission.
///
/// These are deliberately *subtractive*: the system decides whether twodos may
/// notify at all, and these switches let the user quiet categories they do not
/// want without going to Settings and turning everything off. Every one of them
/// defaults to on, so the app behaves as expected out of the box.
@MainActor
@Observable
final class NotificationSettingsStore {
    static let shared = NotificationSettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let deadlines = "notify.deadlines"
        static let alarms = "notify.alarms"
        static let locations = "notify.locations"
        static let partnerActivity = "notify.partnerActivity"
        static let sound = "notify.sound"
        static let foreground = "notify.foreground"
        static let migrated = "notify.defaultsSeeded"
    }

    /// Deadline reminders for lists and individual items.
    var deadlineReminders: Bool {
        didSet { defaults.set(deadlineReminders, forKey: Key.deadlines) }
    }

    /// Standalone alarms created on the Alarms screen.
    var alarmAlerts: Bool {
        didSet { defaults.set(alarmAlerts, forKey: Key.alarms) }
    }

    /// Arrive/leave reminders for pinned places.
    var locationReminders: Bool {
        didSet { defaults.set(locationReminders, forKey: Key.locations) }
    }

    /// Invites accepted, items added by a partner, lists deleted.
    var partnerActivity: Bool {
        didSet { defaults.set(partnerActivity, forKey: Key.partnerActivity) }
    }

    var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.sound) }
    }

    /// Whether banners appear while twodos itself is open.
    var showWhileUsingApp: Bool {
        didSet { defaults.set(showWhileUsingApp, forKey: Key.foreground) }
    }

    /// Set when iOS asks us to open our own notification settings screen.
    var deepLinkRequested: Bool = false

    private init() {
        // `bool(forKey:)` returns false for a missing key, so first launch is
        // seeded explicitly rather than silently starting with everything off.
        if !defaults.bool(forKey: Key.migrated) {
            for key in [Key.deadlines, Key.alarms, Key.locations, Key.partnerActivity, Key.sound] {
                defaults.set(true, forKey: key)
            }
            defaults.set(true, forKey: Key.foreground)
            defaults.set(true, forKey: Key.migrated)
        }

        deadlineReminders = defaults.bool(forKey: Key.deadlines)
        alarmAlerts = defaults.bool(forKey: Key.alarms)
        locationReminders = defaults.bool(forKey: Key.locations)
        partnerActivity = defaults.bool(forKey: Key.partnerActivity)
        playSound = defaults.bool(forKey: Key.sound)
        showWhileUsingApp = defaults.bool(forKey: Key.foreground)
    }

    /// Whether a given kind of notification should be scheduled at all.
    func allows(_ kind: NotificationKind) -> Bool {
        switch kind {
        case .deadline: deadlineReminders
        case .alarm: alarmAlerts
        case .geofence: locationReminders
        case .social: partnerActivity
        }
    }
}
