import Foundation
import SwiftUI
import OSLog

/// The app's single source of truth for session and content.
///
/// Every mutation follows the same shape: apply an optimistic local change so
/// the UI responds on the same frame as the tap, call the API, then reconcile
/// with the server's answer. If the call fails the optimistic change is rolled
/// back and the error surfaces. This is the main behavioural upgrade over the
/// Flutter app, which awaited a round trip and a full list re-fetch before
/// showing a checkbox as ticked.
@MainActor
@Observable
final class AppStore {

    private let logger = Logger(subsystem: "app.twodos", category: "store")
    private let api = APIClient.shared
    private let notifications = NotificationService.shared
    private let location = LocationService.shared
    private let watch = PhoneConnectivityService.shared

    // MARK: - Session

    enum Phase: Equatable {
        case launching
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .launching
    private(set) var user: CurrentUser?
    /// Set when the session ended on its own rather than by the user's choice,
    /// so the sign-in screen can explain why they are looking at it.
    private(set) var sessionExpired = false

    // MARK: - Content

    private(set) var lists: [TodoList] = []
    private(set) var partners: [Partner] = []
    private(set) var alarms: [Alarm] = []
    private(set) var notificationFeed: [AppNotification] = []
    private(set) var blockedUserIds: Set<String> = []
    private(set) var socialLinks: [SocialLink] = []

    private(set) var hasLoadedLists = false
    private(set) var isRefreshing = false

    // MARK: - Realtime

    private(set) var isSocketConnected = false
    /// partnerId → online
    private(set) var presence: [String: Bool] = [:]
    /// partnerId → last seen
    private(set) var lastSeen: [String: Date] = [:]
    /// listId → set of partner ids currently typing
    private(set) var typing: [String: Set<String>] = [:]
    private var typingTimers: [String: Task<Void, Never>] = [:]

    // MARK: - Navigation intents

    /// Set when a notification tap or a socket event should open a list.
    var pendingListToOpen: String?

    // MARK: - Transient UI

    /// The most recent error worth showing. Screens read and clear it.
    var banner: BannerMessage?

    struct BannerMessage: Identifiable, Equatable {
        let id = UUID()
        var kind: InlineBanner.Kind
        var title: String
        var message: String?
    }

    // MARK: - Preferences

    var sortOrder: SortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "lists.sortOrder") }
    }

    var showArchived: Bool = false

    init() {
        sortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "lists.sortOrder") ?? "")
            ?? .lastUpdated

        APIClient.onSessionExpired = { [weak self] in
            self?.handleSessionExpiry()
        }
        notifications.onOpenList = { [weak self] listId, _ in
            self?.pendingListToOpen = listId
        }
        notifications.onSnoozeAlarm = { [weak self] alarmId, minutes in
            Task { await self?.snoozeAlarm(id: alarmId, minutes: minutes) }
        }
        notifications.onCompleteTodo = { [weak self] listId, todoId in
            Task { await self?.setTodo(listId: listId, todoId: todoId, done: true) }
        }
        location.onCrossing = { [weak self] listId, trigger in
            Task { await self?.handleGeofenceCrossing(listId: listId, trigger: trigger) }
        }

        // The watch can ask for a session directly when it launches cold.
        watch.currentPayload = { [weak self] in self?.watchPayload() ?? [:] }
        watch.activate()
    }

    // MARK: - Watch

    /// Hands the watch the current session and a compact snapshot of the lists.
    ///
    /// Called after anything that changes either. The service itself skips
    /// pushes when nothing has actually changed, so calling it liberally is
    /// cheap.
    private func syncWatch() {
        watch.push(
            token: TokenStore.shared.accessToken,
            expiresAt: TokenStore.shared.accessExpiresAt,
            lists: lists,
            currentUserId: currentUserId,
            partnerNames: partnerNames
        )
    }

    /// partnerId → display name, for the watch payload. The watch has no
    /// partner directory, so names are resolved here.
    private var partnerNames: [String: String] {
        Dictionary(partners.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private func watchPayload() -> [String: Any] {
        guard let token = TokenStore.shared.accessToken else {
            return [WatchPayloadKey.signedOut: true]
        }
        var payload: [String: Any] = [WatchPayloadKey.token: token]
        if let expiry = TokenStore.shared.accessExpiresAt {
            payload[WatchPayloadKey.expiresAt] = expiry.timeIntervalSince1970
        }
        let snapshot = WatchList.snapshot(
            from: lists,
            currentUserId: currentUserId,
            partnerNames: partnerNames
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            payload[WatchPayloadKey.lists] = data
        }
        return payload
    }

    // MARK: - Launch

    func start() async {
        await notifications.refreshAuthorization()

        guard TokenStore.shared.hasSession else {
            phase = .signedOut
            return
        }

        do {
            user = try await api.currentUser()
            phase = .signedIn
            await connectSocket()
            await refreshAll()
        } catch APIError.unauthorized {
            TokenStore.shared.clear()
            sessionExpired = true
            phase = .signedOut
        } catch {
            // Offline on a cold launch: the session is probably still good, so
            // sign the user in optimistically rather than bouncing them to the
            // welcome screen. Refreshing will retry once there is a network.
            if case APIError.offline = error {
                phase = .signedIn
                banner = BannerMessage(kind: .warning, title: "You're offline",
                                       message: "Showing what was last loaded. Pull to refresh when you're back.")
            } else {
                TokenStore.shared.clear()
                phase = .signedOut
            }
        }
    }

    /// Called when the app returns to the foreground.
    func handleForeground() async {
        await notifications.refreshAuthorization()
        guard phase == .signedIn else { return }
        if !isSocketConnected { await connectSocket() }
        await refreshAll(silently: true)
    }

    private func handleSessionExpiry() {
        guard phase == .signedIn else { return }
        logger.warning("Session expired.")
        sessionExpired = true
        Task { await signOutLocally() }
    }

    // MARK: - Authentication

    func signIn(email: String, password: String) async throws(APIError) {
        let session = try await api.signIn(email: email, password: password)
        try await establish(session: session, email: email)
    }

    func signInWithOTP(email: String, code: String) async throws(APIError) {
        let session = try await api.signInWithOTP(email: email, otp: code)
        try await establish(session: session, email: email)
    }

    func signInWithApple(identityToken: String, name: String?) async throws(APIError) {
        let session = try await api.signInWithApple(identityToken: identityToken, name: name)
        try await establish(session: session, email: nil)
    }

    private func establish(session: AuthSession, email: String?) async throws(APIError) {
        TokenStore.shared.save(session)
        if let email { TokenStore.shared.lastSignedInEmail = email }

        do {
            user = try await api.currentUser()
        } catch {
            TokenStore.shared.clear()
            throw error
        }

        sessionExpired = false
        phase = .signedIn
        syncWatch()
        await connectSocket()
        await refreshAll()
    }

    func signOut() async {
        await api.signOut()
        await signOutLocally()
    }

    private func signOutLocally() async {
        await SocketClient.shared.disconnect()
        await location.removeAllGeofences()
        notifications.cancelAll()
        TokenStore.shared.clear()

        user = nil
        lists = []
        partners = []
        alarms = []
        notificationFeed = []
        blockedUserIds = []
        socialLinks = []
        presence = [:]
        typing = [:]
        hasLoadedLists = false
        isSocketConnected = false
        phase = .signedOut
        syncWatch()
    }

    func acknowledgeSessionExpiry() { sessionExpired = false }

    // MARK: - Refresh

    func refreshAll(silently: Bool = false) async {
        guard phase == .signedIn else { return }
        if !silently { isRefreshing = true }
        defer { isRefreshing = false }

        async let listsResult: Void = refreshLists()
        async let partnersResult: Void = refreshPartners()
        async let feedResult: Void = refreshNotifications()
        _ = await (listsResult, partnersResult, feedResult)
    }

    func refreshLists() async {
        do {
            let fetched = try await api.lists()
            lists = fetched
            hasLoadedLists = true
            await location.syncGeofences(from: fetched)
            await reconcileScheduledReminders(with: fetched)
            syncWatch()
        } catch {
            report(error, whileDoing: "loading your lists")
        }
    }

    /// Refreshes one list. Used by socket events and pull-to-refresh on a
    /// detail screen — much cheaper than re-fetching everything.
    func refreshList(id: String) async {
        do {
            let fetched = try await api.list(id: id)
            if let index = lists.firstIndex(where: { $0.id == id }) {
                lists[index] = fetched
            } else {
                lists.append(fetched)
            }
            await syncReminders(for: fetched)
            syncWatch()
        } catch APIError.server {
            // The list is gone (deleted by the partner). Drop it locally.
            lists.removeAll { $0.id == id }
        } catch {
            logger.debug("refreshList(\(id, privacy: .public)) failed: \(error.localizedDescription)")
        }
    }

    func refreshPartners() async {
        do {
            partners = try await api.partners()
        } catch {
            logger.debug("refreshPartners failed: \(error.localizedDescription)")
        }
    }

    func refreshNotifications() async {
        do {
            notificationFeed = try await api.notifications()
        } catch {
            logger.debug("refreshNotifications failed: \(error.localizedDescription)")
        }
    }

    func refreshAlarms() async {
        do {
            alarms = try await api.alarms()
            await reconcileAlarmNotifications()
        } catch {
            report(error, whileDoing: "loading your alarms")
        }
    }

    func refreshBlockedUsers() async {
        do {
            blockedUserIds = Set(try await api.blockedUserIds())
        } catch {
            logger.debug("refreshBlockedUsers failed: \(error.localizedDescription)")
        }
    }

    func refreshSocialLinks() async {
        do {
            socialLinks = try await api.socialLinks()
        } catch {
            logger.debug("refreshSocialLinks failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Derived collections

    var currentUserId: String? { user?.id }

    /// Lists to show on the home screen: not archived, and not an invite the
    /// user has yet to answer (those get their own card at the top).
    var activeLists: [TodoList] {
        lists
            .filter { !$0.archived && !isUnansweredInvite($0) }
            .sorted(by: sortComparator)
    }

    var archivedLists: [TodoList] {
        lists.filter(\.archived).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Invites where *this* user is the recipient. A list the user created is
    /// theirs to open immediately, even while the partner has not accepted.
    var pendingInvites: [TodoList] {
        lists.filter(isUnansweredInvite)
    }

    private func isUnansweredInvite(_ list: TodoList) -> Bool {
        list.isPendingInvite && list.createdBy != currentUserId
    }

    var unreadNotificationCount: Int {
        notificationFeed.count { !$0.read }
    }

    var upcomingAlarms: [Alarm] {
        alarms.filter(\.isUpcoming).sorted { $0.effectiveDate < $1.effectiveDate }
    }

    var pastAlarms: [Alarm] {
        alarms.filter { !$0.isUpcoming }.sorted { $0.effectiveDate > $1.effectiveDate }
    }

    func list(id: String) -> TodoList? {
        lists.first { $0.id == id }
    }

    func partner(id: String?) -> Partner? {
        guard let id else { return nil }
        return partners.first { $0.id == id }
    }

    /// Overdue lists always float to the top regardless of the chosen sort —
    /// a missed deadline is the one thing that should interrupt the user's
    /// preferred ordering.
    private func sortComparator(_ a: TodoList, _ b: TodoList) -> Bool {
        if a.isOverdue != b.isOverdue { return a.isOverdue }
        if a.isOverdue && b.isOverdue {
            return (a.doBefore ?? .distantFuture) < (b.doBefore ?? .distantFuture)
        }
        if a.favorite != b.favorite { return a.favorite }

        switch sortOrder {
        case .lastUpdated:
            return (a.effectiveUpdatedAt ?? a.createdAt ?? .distantPast)
                > (b.effectiveUpdatedAt ?? b.createdAt ?? .distantPast)
        case .alphabetical:
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        case .priority:
            let l = a.priority?.weight ?? 1
            let r = b.priority?.weight ?? 1
            if l != r { return l > r }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        case .created:
            return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
        case .deadline:
            switch (a.doBefore, b.doBefore) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.order < b.order
            }
        case .manual:
            return a.order < b.order
        }
    }

    // MARK: - List mutations

    func createList(label: String, favorite: Bool, partnerEmail: String?) async throws(APIError) {
        _ = try await api.createList(label: label, favorite: favorite, partnerEmail: partnerEmail)
        await refreshLists()
        await refreshPartners()
    }

    func renameList(id: String, to label: String) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let previous = lists[index]
        lists[index].label = label

        do {
            _ = try await api.updateList(id: id, label: label, favorite: previous.favorite)
            await refreshList(id: id)
        } catch {
            lists[index] = previous
            report(error, whileDoing: "renaming the list")
        }
    }

    func toggleFavorite(id: String) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let previous = lists[index]
        lists[index].favorite.toggle()
        Haptics.selection()

        do {
            _ = try await api.updateList(id: id, label: previous.label, favorite: lists[index].favorite)
        } catch {
            lists[index] = previous
            report(error, whileDoing: "updating the list")
        }
    }

    func setListColor(id: String, tint: ListTint) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let previous = lists[index]
        lists[index].colorHex = tint.hex

        do {
            _ = try await api.setListColor(id: id, hex: tint.hex)
        } catch {
            lists[index] = previous
            report(error, whileDoing: "changing the colour")
        }
    }

    func setListPriority(id: String, priority: ListPriority?) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let previous = lists[index]
        lists[index].priorityValue = priority?.apiValue

        do {
            _ = try await api.setListPriority(id: id, priority: priority)
        } catch {
            lists[index] = previous
            report(error, whileDoing: "changing the priority")
        }
    }

    func setListDeadline(id: String, date: Date?, target: AlarmTarget?) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let previous = lists[index]
        lists[index].doBefore = date

        do {
            _ = try await api.setListDeadline(id: id, date: date, target: target)
            await syncReminders(for: lists[index])
        } catch {
            lists[index] = previous
            report(error, whileDoing: "setting the deadline")
        }
    }

    func archiveList(id: String, archived: Bool) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let previous = lists[index]
        lists[index].archived = archived

        do {
            _ = try await api.archiveList(id: id, archived: archived)
            if archived {
                await location.removeGeofence(listId: id)
                cancelReminders(for: previous)
            } else {
                await syncReminders(for: lists[index])
            }
            await refreshPartners()
        } catch {
            lists[index] = previous
            report(error, whileDoing: archived ? "archiving the list" : "restoring the list")
        }
    }

    func deleteList(id: String) async {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        let removed = lists.remove(at: index)

        do {
            _ = try await api.deleteList(id: id)
            cancelReminders(for: removed)
            await location.removeGeofence(listId: id)
            await refreshPartners()
        } catch {
            lists.insert(removed, at: min(index, lists.count))
            report(error, whileDoing: "deleting the list")
        }
    }

    func respondToInvite(listId: String, accept: Bool) async {
        do {
            _ = accept
                ? try await api.acceptInvite(listId: listId)
                : try await api.declineInvite(listId: listId)
            Haptics.success()
            await refreshAll()
        } catch {
            report(error, whileDoing: accept ? "accepting the invite" : "declining the invite")
        }
    }

    // MARK: - Todo mutations

    func addTodo(listId: String, title: String) async {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }

        // Insert a placeholder so the row appears instantly; the refresh below
        // swaps it for the server's version with a real id.
        let placeholder = Todo(
            id: "pending-\(UUID().uuidString)",
            listId: listId,
            title: title,
            order: (lists[index].todos.map(\.order).max() ?? 0) + 1
        )
        lists[index].todos.append(placeholder)
        Haptics.light()

        do {
            _ = try await api.createTodo(listId: listId, title: title)
            await refreshList(id: listId)
        } catch {
            lists[index].todos.removeAll { $0.id == placeholder.id }
            report(error, whileDoing: "adding the item")
        }
    }

    func setTodo(listId: String, todoId: String, done: Bool) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }),
              let todoIndex = lists[listIndex].todos.firstIndex(where: { $0.id == todoId })
        else { return }

        let previous = lists[listIndex].todos[todoIndex]
        lists[listIndex].todos[todoIndex].done = done
        done ? Haptics.success() : Haptics.light()

        if done {
            notifications.cancel(id: NotificationService.todoDeadlineID(listId: listId, todoId: todoId))
        }

        do {
            _ = try await api.setTodoDone(listId: listId, todoId: todoId, done: done)
            await refreshList(id: listId)
        } catch {
            lists[listIndex].todos[todoIndex] = previous
            report(error, whileDoing: "updating the item")
        }
    }

    func renameTodo(listId: String, todoId: String, title: String) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }),
              let todoIndex = lists[listIndex].todos.firstIndex(where: { $0.id == todoId })
        else { return }

        let previous = lists[listIndex].todos[todoIndex]
        lists[listIndex].todos[todoIndex].title = title

        do {
            _ = try await api.setTodoTitle(listId: listId, todoId: todoId, title: title)
        } catch {
            lists[listIndex].todos[todoIndex] = previous
            report(error, whileDoing: "renaming the item")
        }
    }

    func setTodoDeadline(listId: String, todoId: String, date: Date?, target: AlarmTarget? = nil) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }),
              let todoIndex = lists[listIndex].todos.firstIndex(where: { $0.id == todoId })
        else { return }

        let previous = lists[listIndex].todos[todoIndex]
        lists[listIndex].todos[todoIndex].doBefore = date

        do {
            _ = try await api.setTodoDeadline(listId: listId, todoId: todoId, date: date, target: target)
            await syncReminders(for: lists[listIndex])
        } catch {
            lists[listIndex].todos[todoIndex] = previous
            report(error, whileDoing: "setting the reminder")
        }
    }

    func deleteTodo(listId: String, todoId: String) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }),
              let todoIndex = lists[listIndex].todos.firstIndex(where: { $0.id == todoId })
        else { return }

        let removed = lists[listIndex].todos.remove(at: todoIndex)
        notifications.cancel(id: NotificationService.todoDeadlineID(listId: listId, todoId: todoId))

        do {
            _ = try await api.deleteTodo(listId: listId, todoId: todoId)
        } catch {
            lists[listIndex].todos.insert(removed, at: min(todoIndex, lists[listIndex].todos.count))
            report(error, whileDoing: "deleting the item")
        }
    }

    /// Persists a drag-reorder. The local array is already in its new order;
    /// this writes each moved item's index back to the server.
    func persistOrder(listId: String, todos: [Todo]) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }) else { return }
        let previous = lists[listIndex].todos

        for (offset, todo) in todos.enumerated() where todo.order != offset {
            do {
                _ = try await api.reorderTodo(listId: listId, todoId: todo.id, order: offset)
            } catch {
                lists[listIndex].todos = previous
                report(error, whileDoing: "reordering")
                return
            }
        }
        await refreshList(id: listId)
    }

    func clearCompleted(listId: String) async {
        guard let index = lists.firstIndex(where: { $0.id == listId }) else { return }
        let previous = lists[index].todos
        let completed = previous.filter(\.done)
        lists[index].todos.removeAll(where: \.done)

        notifications.cancel(ids: completed.map {
            NotificationService.todoDeadlineID(listId: listId, todoId: $0.id)
        })

        do {
            _ = try await api.clearCompleted(listId: listId)
            await refreshList(id: listId)
        } catch {
            lists[index].todos = previous
            report(error, whileDoing: "clearing completed items")
        }
    }

    // MARK: - Location

    func setListLocation(
        listId: String,
        name: String?,
        latitude: Double,
        longitude: Double,
        radius: Double,
        trigger: GeofenceTrigger
    ) async throws(APIError) {
        _ = try await api.setListLocation(
            listId: listId, name: name,
            latitude: latitude, longitude: longitude,
            radius: radius, trigger: trigger
        )
        await refreshList(id: listId)
        await location.syncGeofences(from: lists)
    }

    func clearListLocation(listId: String) async {
        do {
            _ = try await api.clearListLocation(listId: listId)
            await location.removeGeofence(listId: listId)
            await refreshList(id: listId)
        } catch {
            report(error, whileDoing: "removing the location")
        }
    }

    /// Fired by `CLMonitor` on a real boundary crossing, including from a
    /// background relaunch.
    private func handleGeofenceCrossing(listId: String, trigger: GeofenceTrigger) async {
        guard let list = list(id: listId), list.trigger == trigger else { return }
        guard NotificationSettingsStore.shared.locationReminders else { return }

        let place = list.locationName ?? "your saved place"
        let outstanding = list.todos.count { !$0.done }

        await notifications.showNow(
            id: NotificationService.geofenceID(listId: listId),
            title: trigger == .arrive ? "You're at \(place)" : "Leaving \(place)",
            body: outstanding > 0
                ? "\(list.label) — \(outstanding) item\(outstanding == 1 ? "" : "s") left"
                : list.label,
            category: .geofence,
            listId: listId,
            sound: NotificationSettingsStore.shared.playSound
        )

        // Tell the server so the partner is notified too.
        _ = try? await api.fireLocationTrigger(listId: listId, event: trigger)
    }

    // MARK: - Alarms

    func createAlarm(
        at date: Date,
        label: String?,
        repeatRule: AlarmRepeat,
        listId: String?,
        target: AlarmTarget?
    ) async throws(APIError) {
        let alarm = try await api.createAlarm(
            at: date, label: label, repeatRule: repeatRule,
            listId: listId, todoId: nil, target: target
        )
        alarms.append(alarm)
        await scheduleAlarmNotification(alarm)
    }

    func deleteAlarm(id: String) async {
        let index = alarms.firstIndex { $0.id == id }
        let removed = index.map { alarms.remove(at: $0) }

        do {
            _ = try await api.deleteAlarm(id: id)
            notifications.cancel(id: NotificationService.alarmID(id))
        } catch {
            if let removed, let index { alarms.insert(removed, at: min(index, alarms.count)) }
            report(error, whileDoing: "deleting the alarm")
        }
    }

    func snoozeAlarm(id: String, minutes: Int) async {
        do {
            _ = try await api.snoozeAlarm(id: id, minutes: minutes)
            await refreshAlarms()
        } catch {
            report(error, whileDoing: "snoozing the alarm")
        }
    }

    // MARK: - Notifications feed

    func markNotificationRead(id: String) async {
        guard let index = notificationFeed.firstIndex(where: { $0.id == id }),
              !notificationFeed[index].read else { return }
        notificationFeed[index].read = true

        do {
            _ = try await api.markNotificationRead(id: id)
        } catch {
            notificationFeed[index].read = false
        }
    }

    func markAllNotificationsRead() async {
        let previous = notificationFeed
        for index in notificationFeed.indices { notificationFeed[index].read = true }

        do {
            _ = try await api.markAllNotificationsRead()
        } catch {
            notificationFeed = previous
            report(error, whileDoing: "marking notifications as read")
        }
    }

    // MARK: - Partners

    func setBlocked(_ blocked: Bool, userId: String) async {
        let previous = blockedUserIds
        if blocked { blockedUserIds.insert(userId) } else { blockedUserIds.remove(userId) }

        do {
            _ = blocked ? try await api.block(userId: userId) : try await api.unblock(userId: userId)
        } catch {
            blockedUserIds = previous
            report(error, whileDoing: blocked ? "blocking" : "unblocking")
        }
    }

    func isBlocked(_ userId: String) -> Bool { blockedUserIds.contains(userId) }

    func report(userId: String, type: String, details: String?) async throws(APIError) {
        _ = try await api.report(userId: userId, type: type, details: details)
    }

    // MARK: - Account

    func updateName(_ name: String) async throws(APIError) {
        _ = try await api.updateName(name)
        if let user {
            self.user = CurrentUser(id: user.id, name: name, email: user.email,
                                    emailVerified: user.emailVerified, authProvider: user.authProvider)
        }
    }

    func changePassword(current: String, new: String) async throws(APIError) {
        guard let email = user?.email else { throw APIError.unknown }
        _ = try await api.changePassword(email: email, current: current, new: new)
    }

    func unlinkSocial(provider: String) async {
        do {
            _ = try await api.unlinkSocial(provider: provider)
            socialLinks.removeAll { $0.provider == provider }
        } catch {
            report(error, whileDoing: "unlinking \(provider)")
        }
    }

    func requestAccountDeletion(email: String) async throws(APIError) {
        _ = try await api.requestAccountDeletion(email: email)
    }

    func completeAccountDeletion(email: String, token: String) async throws(APIError) {
        _ = try await api.completeAccountDeletion(email: email, token: token)
        await signOutLocally()
    }

    // MARK: - Realtime

    private func connectSocket() async {
        guard let token = TokenStore.shared.accessToken else { return }
        await SocketClient.shared.connect(token: token) { [weak self] event in
            // The socket delivers on its own actor; hop to the main actor before
            // touching any observable state.
            Task { @MainActor [weak self] in
                self?.handle(socketEvent: event)
            }
        }
    }

    func sendTyping(listId: String, isTyping: Bool) {
        Task { await SocketClient.shared.sendTyping(listId: listId, isTyping: isTyping) }
    }

    private func handle(socketEvent event: SocketEvent) {
        switch event {
        case .connectionChanged(let connected):
            isSocketConnected = connected

        case .authRejected:
            Task {
                // The socket rejected our token; a REST call will refresh it and
                // we reconnect with the new one.
                if let token = TokenStore.shared.accessToken {
                    await SocketClient.shared.reconnect(token: token)
                }
            }

        case .notification(let payload):
            handleIncomingNotification(payload)

        case .listUpdated(let listId, let actorId),
             .itemAdded(let listId, let actorId),
             .itemUpdated(let listId, let actorId),
             .itemDeleted(let listId, let actorId),
             .itemsCleared(let listId, let actorId),
             .itemsReordered(let listId, let actorId):
            // Skip echoes of our own writes — local state is already correct and
            // re-fetching would make the user's edit visibly flicker.
            guard actorId != currentUserId else { return }
            Task { await refreshList(id: listId) }

        case .listArchived(_, _, let actorId), .inviteDeclined(_, let actorId):
            guard actorId != currentUserId else { return }
            Task { await refreshLists() }

        case .locationTrigger(let listId, let rawEvent):
            Task { await handlePartnerLocationTrigger(listId: listId, rawEvent: rawEvent) }

        case .presence(let userId, let online, let seen):
            presence[userId] = online
            if let seen { lastSeen[userId] = seen }

        case .typing(let userId, let listId, let isTyping):
            guard userId != currentUserId else { return }
            applyTyping(userId: userId, listId: listId, isTyping: isTyping)
        }
    }

    private func applyTyping(userId: String, listId: String, isTyping: Bool) {
        let key = "\(listId)|\(userId)"
        typingTimers[key]?.cancel()
        typingTimers[key] = nil

        if isTyping {
            typing[listId, default: []].insert(userId)
            // Auto-expire in case the "stopped" event never arrives.
            typingTimers[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.typing[listId]?.remove(userId)
                    if self?.typing[listId]?.isEmpty == true { self?.typing[listId] = nil }
                    self?.typingTimers[key] = nil
                }
            }
        } else {
            typing[listId]?.remove(userId)
            if typing[listId]?.isEmpty == true { typing[listId] = nil }
        }
    }

    func isPartnerTyping(inList listId: String) -> Bool {
        typing[listId]?.isEmpty == false
    }

    func isPartnerOnline(_ partnerId: String?) -> Bool {
        guard let partnerId else { return false }
        return presence[partnerId] == true
    }

    private func handleIncomingNotification(_ payload: [String: String]) {
        guard let id = payload["id"] else { return }
        guard !notificationFeed.contains(where: { $0.id == id }) else { return }

        let type = payload["type"]
        let notification = AppNotification(
            id: id,
            notificationType: type,
            title: payload["title"],
            body: payload["body"],
            dataString: payload["data"],
            read: false,
            createdAt: payload["createdAt"].flatMap {
                ISO8601DateFormatter.twodosFractional.date(from: $0)
                    ?? ISO8601DateFormatter.twodosPlain.date(from: $0)
            } ?? .now
        )
        notificationFeed.insert(notification, at: 0)

        // Refresh whatever this notification implies has changed.
        switch type {
        case APIConstants.NotificationType.inviteReceived:
            Task { await refreshLists(); await refreshPartners() }
        case APIConstants.NotificationType.inviteAccepted:
            Task {
                if let listId = notification.listId { await refreshList(id: listId) }
                await refreshPartners()
            }
        case APIConstants.NotificationType.listDeleted:
            Task { await refreshLists() }
        case APIConstants.NotificationType.alarmFired:
            Task { await refreshAlarms() }
        default:
            break
        }

        // Mirror it as a local banner so it is visible even if the app is closed.
        guard NotificationSettingsStore.shared.partnerActivity else { return }
        Task {
            await notifications.showNow(
                id: "feed.\(id)",
                title: notification.title ?? "twodos",
                body: notification.body,
                category: .social,
                listId: notification.listId,
                sound: NotificationSettingsStore.shared.playSound
            )
        }
    }

    private func handlePartnerLocationTrigger(listId: String, rawEvent: String) async {
        await refreshList(id: listId)
        guard NotificationSettingsStore.shared.locationReminders,
              let list = list(id: listId) else { return }

        let trigger = GeofenceTrigger(apiValue: rawEvent)
        let partnerName = partner(id: list.partnerId)?.displayName ?? "Your partner"
        let place = list.locationName ?? "the saved place"

        await notifications.showNow(
            id: "partner.geofence.\(listId)",
            title: trigger == .arrive ? "\(partnerName) arrived at \(place)" : "\(partnerName) left \(place)",
            body: list.label,
            category: .geofence,
            listId: listId,
            sound: NotificationSettingsStore.shared.playSound
        )
    }

    // MARK: - Reminder scheduling

    /// Brings scheduled local notifications in line with the server's state for
    /// one list. Called after any deadline change and after every list refresh,
    /// so a deadline set by the partner on their phone still rings on this one.
    private func syncReminders(for list: TodoList) async {
        let settings = NotificationSettingsStore.shared
        guard settings.deadlineReminders, notifications.isAuthorized else { return }

        let listReminderID = NotificationService.deadlineID(listId: list.id)
        if let deadline = list.doBefore, deadline > .now, !list.archived {
            await notifications.schedule(
                id: listReminderID,
                title: list.label,
                body: "This list is due now.",
                at: deadline,
                category: .deadline,
                listId: list.id,
                todoId: nil,
                sound: settings.playSound
            )
        } else {
            notifications.cancel(id: listReminderID)
        }

        for todo in list.todos {
            let id = NotificationService.todoDeadlineID(listId: list.id, todoId: todo.id)
            if let due = todo.doBefore, due > .now, !todo.done, !list.archived {
                await notifications.schedule(
                    id: id,
                    title: todo.title,
                    body: "Due now · \(list.label)",
                    at: due,
                    category: .deadline,
                    listId: list.id,
                    todoId: todo.id,
                    sound: settings.playSound
                )
            } else {
                notifications.cancel(id: id)
            }
        }
    }

    private func reconcileScheduledReminders(with lists: [TodoList]) async {
        for list in lists { await syncReminders(for: list) }
    }

    private func cancelReminders(for list: TodoList) {
        var ids = [NotificationService.deadlineID(listId: list.id)]
        ids.append(contentsOf: list.todos.map {
            NotificationService.todoDeadlineID(listId: list.id, todoId: $0.id)
        })
        notifications.cancel(ids: ids)
    }

    private func scheduleAlarmNotification(_ alarm: Alarm) async {
        let settings = NotificationSettingsStore.shared
        guard settings.alarmAlerts, notifications.isAuthorized else { return }
        await notifications.schedule(
            id: NotificationService.alarmID(alarm.id),
            title: alarm.title,
            body: alarm.listId.flatMap { list(id: $0)?.label },
            at: alarm.effectiveDate,
            repeatRule: alarm.repeatRule,
            category: .alarm,
            listId: alarm.listId,
            todoId: alarm.todoId,
            alarmId: alarm.id,
            sound: settings.playSound
        )
    }

    private func reconcileAlarmNotifications() async {
        for alarm in alarms where alarm.isUpcoming {
            await scheduleAlarmNotification(alarm)
        }
    }

    // MARK: - Errors

    /// Surfaces an error as a banner, phrased around what the user was doing.
    private func report(_ error: Error, whileDoing action: String) {
        let apiError = error as? APIError ?? .unknown
        guard apiError != .unauthorized else { return } // handled by sign-out

        logger.error("Failed \(action, privacy: .public): \(String(describing: error))")

        switch apiError {
        case .offline:
            banner = BannerMessage(kind: .warning, title: "You're offline",
                                   message: "We couldn't finish \(action). Your change was undone.")
        case .server(let message):
            banner = BannerMessage(kind: .error, title: "Couldn't finish that", message: message)
        default:
            banner = BannerMessage(kind: .error, title: "Something went wrong",
                                   message: "We couldn't finish \(action). Please try again.")
        }
        Haptics.error()
    }

    func dismissBanner() { banner = nil }

    #if DEBUG
    /// Injects fixture data for previews. Lives here rather than in the sample
    /// file because the properties it writes are `private(set)`, which Swift
    /// scopes to this file. See `AppStore+Sample.swift` for the fixtures.
    func applySample(
        user: CurrentUser?,
        lists: [TodoList],
        partners: [Partner],
        alarms: [Alarm],
        notifications: [AppNotification],
        presence: [String: Bool]
    ) {
        self.user = user
        self.lists = lists
        self.partners = partners
        self.alarms = alarms
        self.notificationFeed = notifications
        self.presence = presence
        self.hasLoadedLists = true
        self.isSocketConnected = true
        self.phase = .signedIn
    }
    #endif
}
