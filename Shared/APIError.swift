import Foundation

/// Everything that can go wrong talking to the twodos API.
///
/// The distinction that matters to the UI is *offline vs. server said no*:
/// an offline error deserves a retry affordance, a server message deserves to
/// be shown verbatim because the API writes decent human-readable messages.
enum APIError: LocalizedError, Equatable {
    /// No usable network path, or the request timed out.
    case offline
    /// The server returned a non-200 `statusCode` in the envelope, with a message.
    case server(String)
    /// The session is no longer valid. Triggers a sign-out.
    case unauthorized
    /// The response did not match the expected shape.
    case decoding(String)
    /// Anything else.
    case unknown

    var errorDescription: String? {
        switch self {
        case .offline:
            "Can't reach twodos. Check your connection and try again."
        case .server(let message):
            message
        case .unauthorized:
            "Your session has expired. Please sign in again."
        case .decoding(let detail):
            #if DEBUG
            "Unexpected response: \(detail)"
            #else
            "Something went wrong. Please try again."
            #endif
        case .unknown:
            "Something went wrong. Please try again."
        }
    }

    /// Whether showing a "Try again" button makes sense.
    var isRetryable: Bool {
        switch self {
        case .offline, .unknown: true
        case .server, .unauthorized, .decoding: false
        }
    }

    /// The API signals "this email exists but was invited, not registered" by
    /// message text rather than a code, so the sign-up flow has to sniff it.
    var suggestsInviteCompletion: Bool {
        if case .server(let message) = self {
            return message.localizedCaseInsensitiveContains("invited to the platform")
        }
        return false
    }

    var suggestsEmailVerification: Bool {
        if case .server(let message) = self {
            return message.localizedCaseInsensitiveContains("not verified")
        }
        return false
    }
}

// MARK: - Presentation helpers

/// Screens catch errors without caring about the concrete type. These read
/// through to ``APIError`` when that is what arrived, and fall back to a safe
/// message otherwise — so a `catch` block never has to pattern-match just to
/// put a sentence on screen.
extension Error {
    /// A message that is always safe to show the user.
    var userMessage: String {
        (self as? APIError)?.errorDescription ?? "Something went wrong. Please try again."
    }

    /// The server said this address was invited rather than registered.
    var hintsAtPendingInvite: Bool {
        (self as? APIError)?.suggestsInviteCompletion ?? false
    }

    /// The server said this account's email has not been verified.
    var hintsAtUnverifiedEmail: Bool {
        (self as? APIError)?.suggestsEmailVerification ?? false
    }
}
