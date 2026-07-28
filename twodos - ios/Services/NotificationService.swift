import Foundation
import UserNotifications
import OSLog

/// Local notifications: deadlines, alarms, geofence arrivals, and partner
/// activity while the app is closed.
///
/// ## Permission policy
/// The app never asks on launch. `requestAuthorizationIfNeeded` is called at the
/// exact moment the user does something that needs a notification to be useful —
/// setting a deadline, creating an alarm, saving a location reminder. That way
/// the system prompt arrives with obvious context, which is both what the HIG
/// asks for and what gets it accepted.
///
/// If the user has already denied, nothing re-prompts; the calling screen shows
/// an inline banner offering a jump to Settings instead.
@MainActor
@Observable
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let logger = Logger(subsystem: "app.twodos", category: "notifications")
    private let center = UNUserNotificationCenter.current()

    /// Current system-level authorisation. Refreshed on launch and on every
    /// foreground, because the user can change it in Settings behind our back.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Set by the app so a notification tap can navigate.
    var onOpenList: ((_ listId: String, _ todoId: String?) -> Void)?
    /// Set by the app so the "Snooze" action can reach the API.
    var onSnoozeAlarm: ((_ alarmId: String, _ minutes: Int) -> Void)?
    /// Set by the app so the "Mark done" action can reach the API.
    var onCompleteTodo: ((_ listId: String, _ todoId: String) -> Void)?

    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional }
    var isDenied: Bool { authorization == .denied }

    private override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    // MARK: - Categories

    private enum Category {
        static let deadline = "TWODOS_DEADLINE"
        static let alarm = "TWODOS_ALARM"
        static let geofence = "TWODOS_GEOFENCE"
        static let social = "TWODOS_SOCIAL"
    }

    private enum Action {
        static let complete = "TWODOS_COMPLETE"
        static let snooze10 = "TWODOS_SNOOZE_10"
        static let snooze60 = "TWODOS_SNOOZE_60"
        static let open = "TWODOS_OPEN"
    }

    /// Actionable notifications mean a deadline can be dismissed without ever
    /// opening the app — long-press the banner, tap "Mark done".
    private func registerCategories() {
        let complete = UNNotificationAction(
            identifier: Action.complete,
            title: "Mark done",
            options: []
        )
        let snooze10 = UNNotificationAction(
            identifier: Action.snooze10,
            title: "Snooze 10 min",
            options: []
        )
        let snooze60 = UNNotificationAction(
            identifier: Action.snooze60,
            title: "Snooze 1 hour",
            options: []
        )
        let open = UNNotificationAction(
            identifier: Action.open,
            title: "Open list",
            options: [.foreground]
        )

        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.deadline,
                                   actions: [complete, snooze10, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.alarm,
                                   actions: [snooze10, snooze60, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.geofence,
                                   actions: [open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.social,
                                   actions: [open],
                                   intentIdentifiers: [], options: [])
        ])
    }

    // MARK: - Permission

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission if the user has never been asked.
    ///
    /// Returns whether notifications can now be delivered. Callers use the
    /// result to decide whether to show the "notifications are off" banner —
    /// they should still save the user's deadline either way, because a deadline
    /// is useful in the app even if it can't ring.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorization()

        switch authorization {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound, .badge, .providesAppNotificationSettings]
                )
                await refreshAuthorization()
                logger.info("Authorization requested — granted: \(granted)")
                return granted
            } catch {
                logger.error("Authorization request failed: \(error.localizedDescription)")
                return false
            }
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedules a one-off or repeating local notification.
    ///
    /// A stable `id` is essential: rescheduling with the same identifier
    /// replaces the pending request rather than stacking duplicates, which is
    /// what keeps a partner's repeated edits from producing five alarms.
    func schedule(
        id: String,
        title: String,
        body: String?,
        at date: Date,
        repeatRule: AlarmRepeat = .never,
        category: NotificationKind,
        listId: String?,
        todoId: String?,
        alarmId: String? = nil,
        sound: Bool
    ) async {
        guard isAuthorized else { return }
        guard date > .now || repeatRule != .never else {
            logger.debug("Skipping \(id, privacy: .public) — date is in the past.")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body, !body.isEmpty { content.body = body }
        content.sound = sound ? (category == .alarm ? .defaultCritical : .default) : nil
        content.categoryIdentifier = category.identifier
        content.interruptionLevel = category == .alarm ? .timeSensitive : .active
        content.threadIdentifier = listId ?? "twodos"
        content.userInfo = [
            "listId": listId ?? "",
            "todoId": todoId ?? "",
            "alarmId": alarmId ?? ""
        ]
        // Sooner deadlines rank higher in the notification summary.
        if listId != nil {
            content.relevanceScore = date.timeIntervalSinceNow < 3600 ? 1.0 : 0.5
        }

        let trigger = makeTrigger(date: date, repeatRule: repeatRule)

        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            logger.debug("Scheduled \(id, privacy: .public) for \(date, privacy: .public)")
        } catch {
            logger.error("Failed to schedule \(id, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func makeTrigger(date: Date, repeatRule: AlarmRepeat) -> UNNotificationTrigger {
        let calendar = Calendar.current
        switch repeatRule {
        case .never:
            let interval = max(date.timeIntervalSinceNow, 1)
            return UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        case .daily:
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        case .weekly:
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            return UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        case .monthly:
            let parts = calendar.dateComponents([.day, .hour, .minute], from: date)
            return UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        }
    }

    /// Shows something immediately — used for geofence crossings and for
    /// partner activity that arrives over the socket while the app is closed.
    func showNow(
        id: String,
        title: String,
        body: String?,
        category: NotificationKind,
        listId: String?,
        sound: Bool
    ) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = sound ? .default : nil
        content.categoryIdentifier = category.identifier
        content.threadIdentifier = listId ?? "twodos"
        content.userInfo = ["listId": listId ?? "", "todoId": ""]

        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func cancel(ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    /// Sends a sample notification so the user can confirm sound and banner
    /// settings without waiting for a real deadline.
    func sendTestNotification(sound: Bool) async {
        await showNow(
            id: "twodos.test.\(UUID().uuidString)",
            title: "twodos",
            body: "This is what a reminder will look like.",
            category: .social,
            listId: nil,
            sound: sound
        )
    }

    // MARK: - Stable identifiers

    /// Deterministic ids so a reschedule replaces rather than duplicates.
    static func deadlineID(listId: String) -> String { "list.deadline.\(listId)" }
    static func todoDeadlineID(listId: String, todoId: String) -> String { "todo.deadline.\(listId).\(todoId)" }
    static func alarmID(_ alarmId: String) -> String { "alarm.\(alarmId)" }
    static func geofenceID(listId: String) -> String { "geofence.\(listId)" }
}

// MARK: - Delegate

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Foreground presentation.
    ///
    /// Banners are shown even while the app is open, because a deadline landing
    /// while you are in a different list is exactly when you need to see it. The
    /// user can turn this off in Settings if they find it noisy.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let showInForeground = await MainActor.run {
            NotificationSettingsStore.shared.showWhileUsingApp
        }
        guard showInForeground else { return [] }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let listId = info["listId"] as? String
        let todoId = info["todoId"] as? String
        let alarmId = info["alarmId"] as? String

        await MainActor.run {
            switch response.actionIdentifier {
            case "TWODOS_SNOOZE_10":
                if let alarmId, !alarmId.isEmpty { self.onSnoozeAlarm?(alarmId, 10) }
            case "TWODOS_SNOOZE_60":
                if let alarmId, !alarmId.isEmpty { self.onSnoozeAlarm?(alarmId, 60) }
            case "TWODOS_COMPLETE":
                if let listId, let todoId, !listId.isEmpty, !todoId.isEmpty {
                    self.onCompleteTodo?(listId, todoId)
                }
            default:
                // Tapping the banner itself, or the explicit "Open list" action.
                if let listId, !listId.isEmpty {
                    self.onOpenList?(listId, todoId?.isEmpty == false ? todoId : nil)
                }
            }
        }
    }

    /// Routes the in-app "Notification Settings" button that iOS shows inside
    /// Settings › Notifications › twodos straight to our own settings screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        Task { @MainActor in
            NotificationSettingsStore.shared.deepLinkRequested = true
        }
    }
}
