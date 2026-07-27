import Foundation
import Security

/// Session persistence.
///
/// Tokens live in the Keychain, not `UserDefaults`. The Flutter app kept the
/// access token in shared preferences, which on iOS means an unencrypted plist
/// inside the app container — readable from a filesystem backup. Everything
/// secret moves to the Keychain here, with only non-sensitive expiry timestamps
/// in `UserDefaults` so the app can decide whether to attempt a refresh without
/// paying a Keychain read on launch.
///
/// `kSecAttrAccessibleAfterFirstUnlock` is deliberate: background geofence
/// triggers need to reach the API while the phone is locked, which
/// `WhenUnlocked` would prevent.
@MainActor
final class TokenStore {
    static let shared = TokenStore()

    private let service = "app.twodos.session"
    private let defaults = UserDefaults.standard

    private enum Key {
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
        static let accessExpiry = "session.accessExpiresAt"
        static let refreshExpiry = "session.refreshExpiresAt"
        static let lastEmail = "session.lastEmail"
    }

    private init() {}

    // MARK: - Public surface

    private(set) var cachedAccessToken: String?

    var accessToken: String? {
        if let cachedAccessToken { return cachedAccessToken }
        let value = read(Key.accessToken)
        cachedAccessToken = value
        return value
    }

    var refreshToken: String? { read(Key.refreshToken) }

    var accessExpiresAt: Date? { defaults.object(forKey: Key.accessExpiry) as? Date }
    var refreshExpiresAt: Date? { defaults.object(forKey: Key.refreshExpiry) as? Date }

    /// The last email that signed in successfully. Used only to pre-fill the
    /// sign-in field — never the password, which is left entirely to the
    /// system password manager via AutoFill.
    var lastSignedInEmail: String? {
        get { defaults.string(forKey: Key.lastEmail) }
        set { defaults.set(newValue, forKey: Key.lastEmail) }
    }

    var hasSession: Bool { accessToken != nil }

    /// True when the access token is gone or within `window` of expiring.
    /// The app refreshes proactively rather than waiting for a 401, so a user
    /// coming back after a week never sees a failed request.
    ///
    /// The window must stay comfortably *below* the token's lifetime. The API
    /// issues access tokens that live exactly one hour, so a one-hour window —
    /// which is what this used to be — made this return true the instant a
    /// token was minted, and every single authenticated request refreshed
    /// before sending. Five minutes leaves the check dormant for 55 of every 60
    /// minutes, which is the intent.
    /// `nonisolated` because it is used as a default argument below, and
    /// default-argument expressions are evaluated outside the actor.
    nonisolated static let refreshWindow: TimeInterval = 5 * 60

    func accessTokenNeedsRefresh(window: TimeInterval = TokenStore.refreshWindow) -> Bool {
        guard let accessExpiresAt else { return false }
        return Date.now.addingTimeInterval(window) >= accessExpiresAt
    }

    var refreshTokenIsUsable: Bool {
        guard refreshToken != nil else { return false }
        guard let refreshExpiresAt else { return true } // no expiry recorded — try it
        return refreshExpiresAt > .now
    }

    func save(_ session: AuthSession) {
        write(Key.accessToken, session.token)
        cachedAccessToken = session.token
        defaults.set(session.expiresAt, forKey: Key.accessExpiry)
        if let refresh = session.refreshToken {
            write(Key.refreshToken, refresh)
        }
        if let refreshExpiry = session.refreshExpiresAt {
            defaults.set(refreshExpiry, forKey: Key.refreshExpiry)
        }
    }

    func clear() {
        delete(Key.accessToken)
        delete(Key.refreshToken)
        cachedAccessToken = nil
        defaults.removeObject(forKey: Key.accessExpiry)
        defaults.removeObject(forKey: Key.refreshExpiry)
    }

    // MARK: - Keychain primitives

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let q = query(account)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
