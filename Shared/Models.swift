import Foundation

// MARK: - Session

/// The token pair returned by every authentication endpoint.
///
/// `refreshToken` is optional because the OTP login path does not issue one —
/// a detail worth remembering, since a session started by OTP cannot be
/// silently renewed and will eventually require a fresh sign-in.
struct AuthSession: Decodable, Sendable {
    let token: String
    let expiresAt: Date
    let refreshToken: String?
    let refreshExpiresAt: Date?
}

// MARK: - Users

struct CurrentUser: Decodable, Identifiable, Equatable, Sendable {
    let id: String?
    let name: String?
    let email: String?
    var emailVerified: Bool = false
    let authProvider: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, emailVerified, authProvider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        authProvider = try c.decodeIfPresent(String.self, forKey: .authProvider)
    }

    init(id: String?, name: String?, email: String?, emailVerified: Bool = false, authProvider: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.emailVerified = emailVerified
        self.authProvider = authProvider
    }

    /// First name, or the part of the email before the `@`. Used for greetings
    /// and presence text where a full name would be too formal.
    var shortName: String {
        if let name, !name.isEmpty { return name.split(separator: " ").first.map(String.init) ?? name }
        return email?.split(separator: "@").first.map(String.init) ?? "there"
    }

    var initials: String {
        let source = name?.isEmpty == false ? name! : (email ?? "?")
        let parts = source.split(separator: " ").prefix(2)
        if parts.count == 2 {
            return parts.map { String($0.prefix(1)) }.joined().uppercased()
        }
        return String(source.prefix(1)).uppercased()
    }
}

struct Partner: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String?
    let email: String
    var emailVerified: Bool = false
    /// `TODOS::INVITE_STATUS::…`
    let status: String?

    enum CodingKeys: String, CodingKey { case id, name, email, emailVerified, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    init(id: String, name: String?, email: String, emailVerified: Bool = false, status: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.emailVerified = emailVerified
        self.status = status
    }

    var displayName: String { name?.isEmpty == false ? name! : email }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        if parts.count == 2 { return parts.map { String($0.prefix(1)) }.joined().uppercased() }
        return String(displayName.prefix(1)).uppercased()
    }

    var isAccepted: Bool { status == APIConstants.InviteStatus.accepted }
    var isPending: Bool { status == APIConstants.InviteStatus.pending }
}

struct SocialLink: Decodable, Identifiable, Equatable, Sendable {
    let provider: String
    let providerEmail: String
    let linkedAt: Date

    var id: String { provider }

    var displayName: String {
        switch provider.lowercased() {
        case "apple": "Apple"
        case "google": "Google"
        case "facebook": "Facebook"
        default: provider.capitalized
        }
    }

    var icon: String {
        switch provider.lowercased() {
        case "apple": "apple.logo"
        default: "person.badge.key"
        }
    }
}

// MARK: - Todos

struct Todo: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    var listId: String
    var title: String
    var done: Bool
    var order: Int
    var doBefore: Date?
    var updatedAt: Date?

    // MARK: Per-item location
    //
    // The server has carried these since before either client existed — the
    // `Todo` table has the same five location columns as `TodoList`, and
    // `getTodos` selects every column of every included item. Neither the
    // Flutter app nor this one decoded them, so "remind me about *this one
    // thing* at the chemist" was a feature the API already supported and no
    // user could reach.

    var locationName: String?
    var locationLat: Double?
    var locationLng: Double?
    var locationRadius: Double?
    var locationTriggerValue: String?

    /// userId of whoever last edited this item; `nil` means never edited since
    /// it was created. Surfaced so a shared list can say who changed what.
    var updatedBy: String?

    /// Which challenge this task is part of, if any.
    var challengeId: String?

    /// Who actually ticked this off. Distinct from `updatedBy`, which records
    /// any edit — renaming a task is not finishing it.
    var completedBy: String?

    /// Which of the two people on the list has taken this task on.
    ///
    /// `nil` is a real state — "nobody has claimed this yet" — and the default
    /// for every shared list, not a missing value.
    var assigneeId: String?

    enum CodingKeys: String, CodingKey {
        case id, listId, title, done, order, doBefore, updatedAt, updatedBy, assigneeId
        case challengeId, completedBy
        case locationName, locationLat, locationLng, locationRadius
        case locationTriggerValue = "locationTrigger"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        listId = try c.decodeIfPresent(String.self, forKey: .listId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        doBefore = try c.decodeIfPresent(Date.self, forKey: .doBefore)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
        assigneeId = try c.decodeIfPresent(String.self, forKey: .assigneeId)
        challengeId = try c.decodeIfPresent(String.self, forKey: .challengeId)
        completedBy = try c.decodeIfPresent(String.self, forKey: .completedBy)
        locationName = try c.decodeIfPresent(String.self, forKey: .locationName)
        locationLat = try c.decodeIfPresent(Double.self, forKey: .locationLat)
        locationLng = try c.decodeIfPresent(Double.self, forKey: .locationLng)
        locationRadius = try c.decodeIfPresent(Double.self, forKey: .locationRadius)
        locationTriggerValue = try c.decodeIfPresent(String.self, forKey: .locationTriggerValue)
    }

    init(id: String, listId: String, title: String, done: Bool = false, order: Int = 0,
         doBefore: Date? = nil, updatedAt: Date? = nil, updatedBy: String? = nil,
         assigneeId: String? = nil,
         locationName: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
         locationRadius: Double? = nil, locationTriggerValue: String? = nil) {
        self.id = id
        self.listId = listId
        self.title = title
        self.done = done
        self.order = order
        self.doBefore = doBefore
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.assigneeId = assigneeId
        self.locationName = locationName
        self.locationLat = locationLat
        self.locationLng = locationLng
        self.locationRadius = locationRadius
        self.locationTriggerValue = locationTriggerValue
    }

    var isOverdue: Bool {
        guard !done, let doBefore else { return false }
        return doBefore < .now
    }

    var hasLocation: Bool { locationLat != nil && locationLng != nil }
    var trigger: GeofenceTrigger { GeofenceTrigger(apiValue: locationTriggerValue) }
}

/// A time-boxed race between the two people on a list.
///
/// Created `pending` and does nothing until the other person accepts — a
/// competition you were entered into without agreeing is not one this app runs.
struct Challenge: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let listId: String
    let createdBy: String
    private(set) var statusValue: String
    let deadline: Date
    private(set) var winnerId: String?
    private(set) var endReasonValue: String?
    /// Score keyed by user id. Both people always appear, even on zero, so the
    /// scoreboard never has to invent the missing side.
    let scores: [String: Int]
    let todoIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, listId, createdBy, deadline, winnerId, scores, todoIds
        case statusValue = "status"
        case endReasonValue = "endReason"
    }

    enum Status: String {
        case pending  = "CHALLENGE::STATUS::PENDING"
        case active   = "CHALLENGE::STATUS::ACTIVE"
        case complete = "CHALLENGE::STATUS::COMPLETE"
        case declined = "CHALLENGE::STATUS::DECLINED"
        case cancelled = "CHALLENGE::STATUS::CANCELLED"
    }

    var status: Status { Status(rawValue: statusValue) ?? .pending }

    var isLive: Bool { status == .pending || status == .active }
    var isRunning: Bool { status == .active }

    /// True when this ended level. `winnerId` is nil for a draw *and* for a
    /// cancellation, so the two are told apart by the end reason.
    var isDraw: Bool {
        status == .complete && winnerId == nil
    }

    func score(for userId: String?) -> Int {
        guard let userId else { return 0 }
        return scores[userId] ?? 0
    }

    /// The other person's score, whoever they are.
    func opponentScore(against userId: String?) -> Int {
        scores.first { $0.key != userId }?.value ?? 0
    }

    var hasExpired: Bool { deadline < .now }

    /// The same challenge, finished.
    ///
    /// Built locally from the `CHALLENGE::ENDED` payload rather than refetched,
    /// because the endpoint only returns *live* challenges — asking it for the
    /// result would answer `null` and wipe the scoreboard at the exact moment
    /// somebody won it.
    func ended(winnerId: String?, scores: [String: Int], endReason: String?) -> Challenge {
        var finished = Challenge(from: self, scores: scores)
        finished.statusValue = endReason == APIConstants.ChallengeEndReason.cancelled
            ? Status.cancelled.rawValue
            : Status.complete.rawValue
        finished.winnerId = winnerId
        finished.endReasonValue = endReason
        return finished
    }

    /// The same challenge, turned down.
    ///
    /// Like `ended`, built locally: the endpoint only returns live challenges,
    /// so refetching after a decline answers `null` and the person who sent the
    /// invitation watches it vanish without ever being told why.
    func declined() -> Challenge {
        var refused = Challenge(from: self, scores: scores)
        refused.statusValue = Status.declined.rawValue
        return refused
    }

    /// The same challenge with a fresh scoreboard.
    ///
    /// `CHALLENGE::SCORED` carries only the scores, so applying it in place
    /// avoids a round trip to learn two integers — which is exactly when the
    /// scoreboard is being watched.
    init(from other: Challenge, scores: [String: Int]) {
        self.id = other.id
        self.listId = other.listId
        self.createdBy = other.createdBy
        self.statusValue = other.statusValue
        self.deadline = other.deadline
        self.winnerId = other.winnerId
        self.endReasonValue = other.endReasonValue
        self.scores = scores
        self.todoIds = other.todoIds
    }
}

/// Who should have a task after the next tap.
///
/// A cycle rather than a picker: a list has exactly two people on it, and a
/// two-option menu costs more taps than it saves.
///
/// Pure and separate from the view because the solo case is easy to get wrong —
/// a list with no partner must go straight from mine back to unclaimed rather
/// than to a person who is not there.
enum AssigneeCycle {
    static func next(current: String?, me: String, partner: String?) -> String? {
        // A partner id equal to your own is how the API represents a solo list.
        let other = partner.flatMap { $0 == me ? nil : $0 }

        switch current {
        case nil:  return me
        case me:   return other      // nil on a solo list, which unclaims
        default:   return nil
        }
    }
}

struct TodoList: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    var label: String
    var favorite: Bool
    var archived: Bool
    var colorHex: String?
    var priorityValue: String?
    var doBefore: Date?
    var createdBy: String
    var partnerId: String?
    var inviteAccepted: Bool
    var inviteStatus: String?
    var todos: [Todo]
    var order: Int
    var createdAt: Date?
    var updatedAt: Date?
    var inviteExpiresAt: Date?
    var locationName: String?
    var locationTriggerValue: String?
    var locationLat: Double?
    var locationLng: Double?
    var locationRadius: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, favorite, archived, createdBy, partnerId, inviteAccepted
        case inviteStatus, order, createdAt, updatedAt, inviteExpiresAt
        case locationName, locationLat, locationLng, locationRadius
        case colorHex = "color"
        case priorityValue = "priority"
        case doBefore
        case locationTriggerValue = "locationTrigger"
        case items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Untitled"
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        priorityValue = try c.decodeIfPresent(String.self, forKey: .priorityValue)
        doBefore = try c.decodeIfPresent(Date.self, forKey: .doBefore)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        partnerId = try c.decodeIfPresent(String.self, forKey: .partnerId)
        inviteAccepted = try c.decodeIfPresent(Bool.self, forKey: .inviteAccepted) ?? true
        inviteStatus = try c.decodeIfPresent(String.self, forKey: .inviteStatus)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        inviteExpiresAt = try c.decodeIfPresent(Date.self, forKey: .inviteExpiresAt)
        locationName = try c.decodeIfPresent(String.self, forKey: .locationName)
        locationTriggerValue = try c.decodeIfPresent(String.self, forKey: .locationTriggerValue)
        locationLat = try c.decodeIfPresent(Double.self, forKey: .locationLat)
        locationLng = try c.decodeIfPresent(Double.self, forKey: .locationLng)
        locationRadius = try c.decodeIfPresent(Double.self, forKey: .locationRadius)
        todos = (try c.decodeIfPresent([Todo].self, forKey: .items) ?? [])
            .sorted { $0.order < $1.order }
    }

    // MARK: Derived

    var priority: ListPriority? { ListPriority(apiValue: priorityValue) }
    var tint: ListTint { ListTint.resolve(colorHex) }
    var trigger: GeofenceTrigger { GeofenceTrigger(apiValue: locationTriggerValue) }

    var hasPartner: Bool { !(partnerId ?? "").isEmpty }
    var hasLocation: Bool { locationLat != nil && locationLng != nil }
    var isPendingInvite: Bool { inviteStatus == APIConstants.InviteStatus.pending && !inviteAccepted }

    var completedCount: Int { todos.count(where: \.done) }
    var totalCount: Int { todos.count }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    var isComplete: Bool { totalCount > 0 && completedCount == totalCount }

    /// A finished list is never overdue, however long ago its deadline was.
    ///
    /// `Todo.isOverdue` has always guarded on `done`; this one did not, so a
    /// list whose every item was ticked off went on calling itself overdue —
    /// nagging in the detail view, colouring its chip red, and sorting itself
    /// above live work on both the phone and the watch. A deadline describes
    /// when the work was due, and there is no work left.
    var isOverdue: Bool {
        guard !isComplete, let doBefore else { return false }
        return doBefore < .now
    }

    /// Latest change across the list and every item in it, so that ticking off a
    /// single todo floats the whole list back to the top of "Recently used".
    var effectiveUpdatedAt: Date? {
        var latest = updatedAt
        for todo in todos {
            if let t = todo.updatedAt, latest == nil || t > latest! { latest = t }
        }
        return latest
    }

    /// A list is "effectively personal" when there is no real second person on
    /// it — either no partner at all, or the partner record points back at the
    /// creator, which the API does for solo lists.
    func isEffectivelyPersonal(currentUserId: String?) -> Bool {
        if !hasPartner { return true }
        if partnerId == createdBy { return true }
        if partnerId == currentUserId && createdBy == currentUserId { return true }
        return false
    }
}

// MARK: - Alarms

struct Alarm: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String?
    let alarmAt: Date
    let repeatValue: String?
    let listId: String?
    let todoId: String?
    let userId: String?
    var fired: Bool = false
    let firedAt: Date?
    let snoozedUntil: Date?

    enum CodingKeys: String, CodingKey {
        case id, label, alarmAt, listId, todoId, userId, fired, firedAt, snoozedUntil
        case repeatValue = "repeat"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        alarmAt = try c.decode(Date.self, forKey: .alarmAt)
        repeatValue = try c.decodeIfPresent(String.self, forKey: .repeatValue)
        listId = try c.decodeIfPresent(String.self, forKey: .listId)
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        fired = try c.decodeIfPresent(Bool.self, forKey: .fired) ?? false
        firedAt = try c.decodeIfPresent(Date.self, forKey: .firedAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
    }

    init(id: String, label: String?, alarmAt: Date, repeatRule: AlarmRepeat = .never,
         listId: String? = nil, todoId: String? = nil) {
        self.id = id
        self.label = label
        self.alarmAt = alarmAt
        self.repeatValue = repeatRule.apiValue
        self.listId = listId
        self.todoId = todoId
        self.userId = nil
        self.fired = false
        self.firedAt = nil
        self.snoozedUntil = nil
    }

    var repeatRule: AlarmRepeat { AlarmRepeat(apiValue: repeatValue) }
    var title: String { label?.isEmpty == false ? label! : "Alarm" }

    /// The time the alarm will actually ring, accounting for a snooze.
    var effectiveDate: Date {
        if let snoozedUntil, snoozedUntil > .now { return snoozedUntil }
        return alarmAt
    }

    var isUpcoming: Bool { effectiveDate > .now }
}

// MARK: - Notifications

struct AppNotification: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let notificationType: String?
    let title: String?
    let body: String?
    /// The API sends this as a JSON *string*, not an object.
    let dataString: String?
    var read: Bool
    let readAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, notificationType, title, body, read, readAt, createdAt
        case dataString = "data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        dataString = try c.decodeIfPresent(String.self, forKey: .dataString)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }

    init(id: String, notificationType: String?, title: String?, body: String?,
         dataString: String?, read: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.notificationType = notificationType
        self.title = title
        self.body = body
        self.dataString = dataString
        self.read = read
        self.readAt = nil
        self.createdAt = createdAt
    }

    var payload: [String: Any]? {
        guard let dataString, let data = dataString.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var listId: String? { payload?["listId"] as? String }
    var todoId: String? { payload?["todoId"] as? String }

    var icon: String {
        switch notificationType {
        case APIConstants.NotificationType.inviteReceived: "envelope.badge"
        case APIConstants.NotificationType.inviteAccepted: "person.2.badge.plus"
        case APIConstants.NotificationType.listDeleted: "trash"
        case APIConstants.NotificationType.alarmFired: "alarm"
        case APIConstants.NotificationType.geofence: "mappin.and.ellipse"
        default: "bell"
        }
    }

    var isInvite: Bool { notificationType == APIConstants.NotificationType.inviteReceived }
}

/// A pending invite as returned by `GET /api/account/invites`.
struct PendingInvite: Decodable, Identifiable, Sendable {
    let listId: String
    let label: String?
    let createdBy: String?
    let createdAt: Date?

    var id: String { listId }
}
