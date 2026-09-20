import Foundation

/// The wire-format rules for the two things a person types that the server also
/// checks: an email address, and a handle.
///
/// They live in `Shared/` rather than beside the form that uses them because
/// `PartnerReference` needs them and is itself shared, and because they are not
/// presentation — they are the shape the API accepts. `Validate` in the iOS
/// target wraps these to add the sentences a form shows; the predicates
/// themselves exist once, here.
enum EmailRule {
    /// Deliberately permissive: the server is the real authority, and an
    /// over-strict pattern rejects addresses that are perfectly valid.
    static func looksLikeAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }
}

/// The server's handle rule, `^[a-z][a-z0-9_]{2,23}$`, checked here too.
///
/// Duplicating a server rule in a client is usually how the two drift apart,
/// and it is worth it exactly once: the endpoints that would answer live —
/// `GET /account/username-available` and `GET /users/by-username/{handle}` —
/// both sit behind the auth rate limiter, ten calls per quarter of an hour, so
/// asking either per keystroke would lock the user out mid-word. The rule is
/// also fixed: a handle that is valid today cannot stop being valid. And every
/// call that matters is still checked server-side, so the worst a stale copy
/// here can do is refuse something the server would have taken.
///
/// Mirrors `src/services/UsernamesService.ts`.
enum UsernameRules {
    static let text = "3 to 24 characters, starting with a letter. Lowercase letters, numbers and underscores only."

    /// Trimmed and lowercased — handles are compared in exactly one case.
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Which rule was broken, or nil when none was.
    ///
    /// Each message names the one thing to fix. Restating all four rules makes
    /// somebody work out for themselves which part they got wrong.
    static func problem(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Choose a username." }
        guard trimmed == trimmed.lowercased() else { return "Usernames are lowercase." }
        guard trimmed.count >= 3 else { return "Use at least 3 characters." }
        guard trimmed.count <= 24 else { return "Use at most 24 characters." }
        guard trimmed.first?.isLetter == true else { return "Start with a letter." }
        guard trimmed.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil else {
            return "Letters, numbers and underscores only."
        }
        return nil
    }

    static func isValid(_ value: String) -> Bool { problem(value) == nil }
}

/// The password rule, shared for the same reason the other two are: the Mac
/// sign-up form needs it and lives in a target that cannot see `Validate`.
///
/// The bounds are the client's own — the server has its own limits and is the
/// authority — so this is about telling somebody what is missing *before* a
/// round trip, not about deciding what is acceptable.
enum PasswordRule {
    static let text = "At least 8 characters, with a number and a symbol."

    /// Which requirement is unmet, or nil when none is.
    static func problem(_ value: String) -> String? {
        guard !value.isEmpty else { return "Enter a password." }
        guard value.count >= 8 else { return "Use at least 8 characters." }
        guard value.rangeOfCharacter(from: .decimalDigits) != nil else {
            return "Include at least one number."
        }
        guard value.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil else {
            return "Include at least one symbol."
        }
        return nil
    }

    static func isValid(_ value: String) -> Bool { problem(value) == nil }
}
