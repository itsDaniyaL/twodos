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
    var name: String?
    let email: String?
    var emailVerified: Bool = false
    /// How the account was first created. History, not capability — see
    /// `hasPassword` and the social links for what can sign in today.
    let authProvider: String?
    /// Whether email + password is a working way into this account. False for
    /// an account created with Google, Apple or Facebook that has never set a
    /// password; "Forgot password" is how it gets one.
    var hasPassword: Bool
    /// The profile picture, or nil for initials. Pictures only ever come from
    /// a linked provider — there is no upload — so this is nil until one is.
    var avatarUrl: String?
    /// Which linked provider the picture was taken from.
    var avatarProvider: String?
    /// The handle a partner can type to find this person, or nil if none has
    /// been claimed. Optional and permanent: nil is a supported, lasting state,
    /// and once set the server refuses to change it.
    var username: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, emailVerified, authProvider, hasPassword, avatarUrl, avatarProvider, username
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        authProvider = try c.decodeIfPresent(String.self, forKey: .authProvider)
        // A server too old to say assumes the pre-social world, where every
        // account had a password unless it was born social.
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword)
            ?? (authProvider == nil || authProvider == "email")
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        avatarProvider = try c.decodeIfPresent(String.self, forKey: .avatarProvider)
        // A server too old to know about handles simply has none, which is the
        // same state as an account that never claimed one.
        username = try c.decodeIfPresent(String.self, forKey: .username)
    }

    init(id: String?, name: String?, email: String?, emailVerified: Bool = false, authProvider: String? = nil,
         hasPassword: Bool = true, avatarUrl: String? = nil, avatarProvider: String? = nil,
         username: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.emailVerified = emailVerified
        self.authProvider = authProvider
        self.hasPassword = hasPassword
        self.avatarUrl = avatarUrl
        self.avatarProvider = avatarProvider
        self.username = username
    }

    /// The handle as it is shown — with the `@` the server never stores.
    var handle: String? {
        guard let username, !username.isEmpty else { return nil }
        return "@\(username)"
    }

    /// The picture as something an image view can load. `avatarUrl` may be
    /// a bare path when the deployment does not know its own origin.
    var avatarURL: URL? { APIClient.resolve(avatarUrl) }

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
    /// Their profile picture, or nil for initials. What tells two people's
    /// lists apart on a card.
    var avatarUrl: String?
    /// Their handle, if they have claimed one. Shorter than an address and
    /// stable across address changes, so it is the better thing to show and the
    /// better thing to reuse when sharing another list with them.
    var username: String?

    // MARK: Partner directory
    //
    // Only `GET /api/v1/account/partner-directory` sends these. The older
    // `/api/account/partners` omits them, and the defaults below describe what
    // that endpoint implies: nobody blocked, and nothing known about lists.

    /// You have blocked them.
    var blocked: Bool = false
    /// They have blocked you. `email` and `avatarUrl` arrive redacted when set.
    var blockedByThem: Bool = false
    /// At least one shared list has an *accepted* invite — "do we actually
    /// share anything". Not the same as `listCount > 0`.
    var hasLists: Bool = false
    /// Every list you are both on, at any invite status.
    var listCount: Int = 0
    var acceptedListCount: Int = 0
    var pendingListCount: Int = 0
    var lastActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, email, emailVerified, status, avatarUrl, username
        case blocked, blockedByThem, hasLists, listCount, acceptedListCount, pendingListCount, lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // Null when they have blocked you — redacted, not missing.
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        blockedByThem = try c.decodeIfPresent(Bool.self, forKey: .blockedByThem) ?? false
        hasLists = try c.decodeIfPresent(Bool.self, forKey: .hasLists) ?? false
        listCount = try c.decodeIfPresent(Int.self, forKey: .listCount) ?? 0
        acceptedListCount = try c.decodeIfPresent(Int.self, forKey: .acceptedListCount) ?? 0
        pendingListCount = try c.decodeIfPresent(Int.self, forKey: .pendingListCount) ?? 0
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
    }

    init(id: String, name: String?, email: String, emailVerified: Bool = false, status: String? = nil,
         avatarUrl: String? = nil, username: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.emailVerified = emailVerified
        self.status = status
        self.avatarUrl = avatarUrl
        self.username = username
    }

    var avatarURL: URL? { APIClient.resolve(avatarUrl) }

    /// The handle as it is shown — with the `@` the server never stores.
    var handle: String? {
        guard let username, !username.isEmpty else { return nil }
        return "@\(username)"
    }

    /// What to send as `partner` to share another list with this person.
    ///
    /// Their handle when they have one: it is shorter, and it survives them
    /// changing the address on their account, which the address obviously does
    /// not. Falls back to the address, which every account has.
    var shareReference: String { handle ?? email }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if !email.isEmpty { return email }
        // A partner who blocked you arrives with no address; their handle is
        // the one identifying thing left.
        return handle ?? String(localized: "Unknown person")
    }

    /// Who this is, in the order that tells two people apart best: the handle,
    /// then the name, then the address. Used wherever the question is "which
    /// of us is doing this", where a handle is unambiguous and a first name is
    /// not.
    var identityLabel: String {
        if let handle { return handle }
        if let name, !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return String(localized: "Unknown person")
    }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        if parts.count == 2 { return parts.map { String($0.prefix(1)) }.joined().uppercased() }
        return String(displayName.prefix(1)).uppercased()
    }

    var isAccepted: Bool { status == APIConstants.InviteStatus.accepted }
    var isPending: Bool { status == APIConstants.InviteStatus.pending }
    var isRejected: Bool { status == APIConstants.InviteStatus.rejected }
    /// A block in either direction.
    var isInBlock: Bool { blocked || blockedByThem }
}

/// `GET /api/v1/account/partner-directory`.
///
/// `counts` is computed by the server from the same `partners` array in the
/// same response, so the two can never disagree — which is the bug the older
/// endpoint had, where the counter and the screen showed different numbers.
struct PartnerDirectory: Decodable, Sendable {
    let counts: PartnerCounts
    let partners: [Partner]
}

struct PartnerCounts: Decodable, Equatable, Sendable {
    var total: Int = 0
    var accepted: Int = 0
    var pending: Int = 0
    var rejected: Int = 0
    /// Blocked in either direction. Cuts across the status buckets.
    var blocked: Int = 0
    /// Has at least one accepted shared list. Cuts across the status buckets.
    var withLists: Int = 0

    enum CodingKeys: String, CodingKey { case total, accepted, pending, rejected, blocked, withLists }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        rejected = try c.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
        blocked = try c.decodeIfPresent(Int.self, forKey: .blocked) ?? 0
        withLists = try c.decodeIfPresent(Int.self, forKey: .withLists) ?? 0
    }
}

/// An invitation this user sent that is still unanswered —
/// `GET /api/v1/account/invites/sent`.
struct SentInvite: Decodable, Identifiable, Equatable, Sendable {
    let listId: String
    let label: String?
    let invitedAt: Date?
    let invitee: Invitee
    /// **Nil whenever the invitee already has an account** — those never
    /// expire. Never count down from a nil.
    let expiresAt: Date?
    let reminderSentAt: Date?
    var blocked: Bool = false
    var canResend: Bool = false

    var id: String { listId }

    struct Invitee: Decodable, Equatable, Sendable {
        let id: String?
        let name: String?
        let username: String?
        let email: String?
        /// False: nobody has signed up with this address yet, and the
        /// invitation will expire. True: a real account that has not answered.
        var hasAccount: Bool = false

        enum CodingKeys: String, CodingKey { case id, name, username, email, hasAccount }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            username = try c.decodeIfPresent(String.self, forKey: .username)
            email = try c.decodeIfPresent(String.self, forKey: .email)
            hasAccount = try c.decodeIfPresent(Bool.self, forKey: .hasAccount) ?? false
        }

        /// Handle, then name, then address — the same order as
        /// `Partner.identityLabel`.
        var identityLabel: String? {
            if let username, !username.isEmpty { return "@\(username)" }
            if let name, !name.isEmpty { return name }
            if let email, !email.isEmpty { return email }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case listId, label, invitedAt, invitee, expiresAt, reminderSentAt, blocked, canResend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listId = try c.decode(String.self, forKey: .listId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        invitedAt = try c.decodeIfPresent(Date.self, forKey: .invitedAt)
        invitee = try c.decode(Invitee.self, forKey: .invitee)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        reminderSentAt = try c.decodeIfPresent(Date.self, forKey: .reminderSentAt)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        canResend = try c.decodeIfPresent(Bool.self, forKey: .canResend) ?? false
    }
}

// MARK: - Attachments

/// One file attached to a task. `items[].media` on every list payload.
///
/// The bytes are behind an **authenticated** endpoint (`url`); there is no
/// public link. The server sniffs the bytes rather than trusting what the
/// upload declared, and `kind` comes from the sniffed type.
struct TodoMedia: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let todoId: String
    let listId: String
    let uploadedBy: String?
    let fileName: String
    let declaredContentType: String?
    /// What the bytes actually are. Nil when the format was not recognised.
    let sniffedContentType: String?
    /// The declared and sniffed types disagree, or the format is unknown.
    /// Warn before previewing — a "photo.png" whose bytes are markup is the
    /// case this exists for.
    let contentTypeMismatch: Bool
    let sizeBytes: Int
    let kindValue: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, todoId, listId, uploadedBy, fileName, declaredContentType, sniffedContentType
        case contentTypeMismatch, sizeBytes, createdAt
        case kindValue = "kind"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        todoId = try c.decodeIfPresent(String.self, forKey: .todoId) ?? ""
        listId = try c.decodeIfPresent(String.self, forKey: .listId) ?? ""
        uploadedBy = try c.decodeIfPresent(String.self, forKey: .uploadedBy)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "file"
        declaredContentType = try c.decodeIfPresent(String.self, forKey: .declaredContentType)
        sniffedContentType = try c.decodeIfPresent(String.self, forKey: .sniffedContentType)
        contentTypeMismatch = try c.decodeIfPresent(Bool.self, forKey: .contentTypeMismatch) ?? false
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
        kindValue = try c.decodeIfPresent(String.self, forKey: .kindValue)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Kind: String, Sendable {
        case image = "MEDIA::KIND::IMAGE"
        case audio = "MEDIA::KIND::AUDIO"
        case video = "MEDIA::KIND::VIDEO"
        case document = "MEDIA::KIND::DOCUMENT"
        case other = "MEDIA::KIND::OTHER"
    }

    var kind: Kind { kindValue.flatMap(Kind.init(rawValue:)) ?? .other }

    /// Only an image whose bytes really are an image is drawn inline.
    var isPreviewableImage: Bool { kind == .image && !contentTypeMismatch }

    var icon: String {
        switch kind {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .document: "doc.richtext"
        case .other: "doc"
        }
    }
}

/// What is left of each attachment limit on a list. Every limit is adjustable
/// from the dashboard, so these are read from the payload and never hardcoded.
struct MediaAllowance: Decodable, Equatable, Hashable, Sendable {
    var enabled: Bool = true
    var maxFileBytes: Int = 0
    var filesPerTask: Int = 0
    var filesPerList: Int = 0
    var bytesPerList: Int = 0
    var remainingOnList: Int = 0
    var remainingBytesOnList: Int = 0

    enum CodingKeys: String, CodingKey {
        case enabled, maxFileBytes, filesPerTask, filesPerList, bytesPerList
        case remainingOnList, remainingBytesOnList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxFileBytes = try c.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? 0
        filesPerTask = try c.decodeIfPresent(Int.self, forKey: .filesPerTask) ?? 0
        filesPerList = try c.decodeIfPresent(Int.self, forKey: .filesPerList) ?? 0
        bytesPerList = try c.decodeIfPresent(Int.self, forKey: .bytesPerList) ?? 0
        remainingOnList = try c.decodeIfPresent(Int.self, forKey: .remainingOnList) ?? 0
        remainingBytesOnList = try c.decodeIfPresent(Int.self, forKey: .remainingBytesOnList) ?? 0
    }
}

struct SocialLink: Decodable, Identifiable, Equatable, Sendable {
    let provider: String
    let providerEmail: String
    let linkedAt: Date
    /// Whether this provider gave us a picture — whether "use this picture" is
    /// an option. Never true for Apple. Defaults false for an older server.
    var hasPicture: Bool = false

    enum CodingKeys: String, CodingKey { case provider, providerEmail, linkedAt, hasPicture }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        providerEmail = try c.decodeIfPresent(String.self, forKey: .providerEmail) ?? ""
        linkedAt = try c.decodeIfPresent(Date.self, forKey: .linkedAt) ?? .distantPast
        hasPicture = try c.decodeIfPresent(Bool.self, forKey: .hasPicture) ?? false
    }

    init(provider: String, providerEmail: String, linkedAt: Date, hasPicture: Bool = false) {
        self.provider = provider
        self.providerEmail = providerEmail
        self.linkedAt = linkedAt
        self.hasPicture = hasPicture
    }

    var id: String { provider }
    var socialProvider: SocialProvider? { SocialProvider(rawValue: provider.lowercased()) }

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
        case "google": "g.circle"
        case "facebook": "f.circle"
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

    /// Optional long-form detail behind the title — the wire calls it
    /// `description`, which is a name Swift already has opinions about.
    ///
    /// `nil` is the only "no notes" state that reaches this model: the server
    /// trims and stores an empty or whitespace-only value as null, so a row
    /// never has to check both. Rendered as a preview under the title and in
    /// full in the editor; a task without notes draws exactly what it did before.
    var notes: String?

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

    /// Files attached to this task, oldest first. Empty for a task without any,
    /// and for a server too old to send the field.
    var media: [TodoMedia] = []

    /// How many more files this task may hold, from the server. Nil when the
    /// server did not say, which is treated as "unknown" rather than "none".
    var mediaRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case id, listId, title, done, order, doBefore, updatedAt, updatedBy, assigneeId
        case challengeId, completedBy, media, mediaRemaining
        case notes = "description"
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
        notes = Self.normalisedNotes(try c.decodeIfPresent(String.self, forKey: .notes))
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
        assigneeId = try c.decodeIfPresent(String.self, forKey: .assigneeId)
        challengeId = try c.decodeIfPresent(String.self, forKey: .challengeId)
        completedBy = try c.decodeIfPresent(String.self, forKey: .completedBy)
        // Decoded leniently: one malformed attachment must not cost the user
        // the whole list.
        media = (try? c.decodeIfPresent([TodoMedia].self, forKey: .media)) ?? []
        mediaRemaining = try? c.decodeIfPresent(Int.self, forKey: .mediaRemaining)
        locationName = try c.decodeIfPresent(String.self, forKey: .locationName)
        locationLat = try c.decodeIfPresent(Double.self, forKey: .locationLat)
        locationLng = try c.decodeIfPresent(Double.self, forKey: .locationLng)
        locationRadius = try c.decodeIfPresent(Double.self, forKey: .locationRadius)
        locationTriggerValue = try c.decodeIfPresent(String.self, forKey: .locationTriggerValue)
    }

    init(id: String, listId: String, title: String, done: Bool = false, order: Int = 0,
         doBefore: Date? = nil, updatedAt: Date? = nil, updatedBy: String? = nil,
         assigneeId: String? = nil, notes: String? = nil,
         locationName: String? = nil, locationLat: Double? = nil, locationLng: Double? = nil,
         locationRadius: Double? = nil, locationTriggerValue: String? = nil) {
        self.id = id
        self.listId = listId
        self.title = title
        self.done = done
        self.order = order
        self.doBefore = doBefore
        self.updatedAt = updatedAt
        self.notes = Self.normalisedNotes(notes)
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

    var hasNotes: Bool { notes != nil }
    var hasMedia: Bool { !media.isEmpty }

    /// The same collapse the server applies, so a value typed here and one
    /// read back from the API compare equal and an optimistic edit never
    /// flickers when the refresh lands.
    static func normalisedNotes(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
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
    /// The list's attachment limits and what is left of them. Nil from a server
    /// that predates attachments, which the UI reads as "attachments off".
    var mediaAllowance: MediaAllowance?

    enum CodingKeys: String, CodingKey {
        case id, label, favorite, archived, createdBy, partnerId, inviteAccepted, mediaAllowance
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
        mediaAllowance = try? c.decodeIfPresent(MediaAllowance.self, forKey: .mediaAllowance)
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
    var title: String { label?.isEmpty == false ? label! : String(localized: "Alarm") }

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

// MARK: - Who a list is being shared with

/// How the server reads the `partner` field on `POST /todos`: as an address, or
/// as a handle.
///
/// Mirrors `TodosService.looksLikeUsername` — a leading `@`, or no `@` at all.
/// The client needs the same answer *before* sending, because the two are not
/// interchangeable and the difference is the whole of what the user has to be
/// told: an unknown address raises an invitation and mails it, while an unknown
/// handle can only be refused, since a handle gives the server nowhere to send
/// anything.
enum PartnerReference: Equatable {
    case email(String)
    case username(String)

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("@") || !trimmed.contains("@") {
            self = .username(trimmed.replacingOccurrences(of: "@", with: "").lowercased())
        } else {
            self = .email(trimmed)
        }
    }

    /// Whether this is something worth sending at all. The server is the
    /// authority either way; this only stops an obviously incomplete entry
    /// becoming a round trip and an error banner.
    var isPlausible: Bool {
        switch self {
        case .email(let address): EmailRule.looksLikeAddress(address)
        case .username(let handle): UsernameRules.isValid(handle)
        }
    }

    /// The exact string to put in `partner`. Handles keep their `@` so the
    /// server's own detection agrees with ours even for a handle that happens
    /// to look like one half of an address.
    var wireValue: String {
        switch self {
        case .email(let address): address
        case .username(let handle): "@\(handle)"
        }
    }
}
