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

    enum CodingKeys: String, CodingKey {
        case id, listId, title, done, order, doBefore, updatedAt
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
    }

    init(id: String, listId: String, title: String, done: Bool = false, order: Int = 0,
         doBefore: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.listId = listId
        self.title = title
        self.done = done
        self.order = order
        self.doBefore = doBefore
        self.updatedAt = updatedAt
    }

    var isOverdue: Bool {
        guard !done, let doBefore else { return false }
        return doBefore < .now
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

    var isOverdue: Bool {
        guard let doBefore else { return false }
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
