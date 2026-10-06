import Foundation

/// Who is on the other end of a shared list, and where that stands.
///
/// Built by `AppStore.counterpart(for:)`. Before this, each screen worked it
/// out for itself from whatever it had to hand, and a partner missing from the
/// partners endpoint — anyone declined or blocked — came out as "someone" or a
/// question mark. Every state here has a sentence that says what is actually
/// going on.
struct ListCounterpart: Equatable {
    enum State: Equatable {
        /// Both people are on the list.
        case accepted
        /// You shared it; they have not answered.
        case awaitingThem
        /// They shared it; you have not answered.
        case awaitingYou
        /// The invitation was turned down.
        case declined
        /// You have blocked them.
        case youBlocked
        /// They have blocked you.
        case blockedYou
    }

    /// The person, when the app knows them. Nil for an invitation to an
    /// address that has no account yet.
    let partner: Partner?
    /// Handle, then name, then address — whatever is known.
    let name: String?
    let state: State
    /// For an invitation you sent: whether anyone has an account at that
    /// address. Nil when unknown.
    var inviteeHasAccount: Bool?

    var isPending: Bool { state == .awaitingThem || state == .awaitingYou }

    /// One line describing the relationship, written to stand on its own.
    var statusText: String {
        switch state {
        case .accepted:
            return name ?? String(localized: "Your partner")
        case .awaitingThem:
            guard let name else { return String(localized: "Invite not accepted yet") }
            return String(localized: "Waiting for \(name) to accept")
        case .awaitingYou:
            guard let name else { return String(localized: "You've been invited") }
            return String(localized: "\(name) invited you")
        case .declined:
            guard let name else { return String(localized: "Invite declined") }
            return String(localized: "\(name) declined the invite")
        case .youBlocked:
            guard let name else { return String(localized: "Blocked") }
            return String(localized: "\(name) · blocked")
        case .blockedYou:
            guard let name else { return String(localized: "No longer available") }
            return String(localized: "\(name) is no longer available")
        }
    }

    /// A short badge for the state, or nil when nothing needs flagging.
    var badge: String? {
        switch state {
        case .accepted: nil
        case .awaitingThem, .awaitingYou: String(localized: "Pending")
        case .declined: String(localized: "Declined")
        case .youBlocked: String(localized: "Blocked")
        case .blockedYou: String(localized: "Unavailable")
        }
    }

    var icon: String {
        switch state {
        case .accepted: "person.2.fill"
        case .awaitingThem, .awaitingYou: "clock.badge.questionmark"
        case .declined: "person.crop.circle.badge.xmark"
        case .youBlocked, .blockedYou: "hand.raised.fill"
        }
    }
}

/// A file picked to attach, not yet uploaded.
///
/// Plain data, so the store stays free of UIKit and AppKit: each app's own
/// picker turns whatever it picked into one of these.
struct AttachmentDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    let fileName: String
    let mimeType: String
    let data: Data

    var sizeBytes: Int { data.count }
}
