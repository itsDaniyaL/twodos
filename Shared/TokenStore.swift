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

    /// The keychain group the iOS widget extension can also read.
    ///
    /// **Only the access token goes here.** It is a bearer token that expires in
    /// an hour, so the worst a compromised extension could do is act as the user
    /// until it lapses.
    ///
    /// The refresh token deliberately stays outside this group. This API treats
    /// a spent refresh token as an attack and destroys *every session on the
    /// account* when one is replayed, so two processes able to present the same
    /// one is not a risk worth taking for a checkbox on the Home Screen. The
    /// extension can act while the token is fresh and queues the change when it
    /// is not — it can never renew.
    /// The team prefix is spelled out because `$(AppIdentifierPrefix)` is a
    /// build-setting variable — it expands inside the entitlements plist, never
    /// in Swift source. `DEVELOPMENT_TEAM` is already fixed in the project file,
    /// so this is no more hardcoded than the bundle identifier is.
    private static let sharedGroup = "V2Y9RFPG3D.com.afzaalahmadzeeshan.ios.twodos.shared"

    /// Which keychain group an item belongs in. Splitting on the account name
    /// keeps the rule in one place rather than at each call site.
    private static func accessGroup(for account: String) -> String? {
        account == Key.accessToken ? sharedGroup : nil
    }

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
        baseQuery(account, group: Self.accessGroup(for: account))
    }

    private func baseQuery(_ account: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private func read(_ account: String) -> String? {
        if let value = read(account, in: Self.accessGroup(for: account)) { return value }

        // Migration. Before the widget could tick items off, every token lived
        // in the app's private keychain with no access group — and a query that
        // names a group will not find an item stored without one. Without this
        // fallback, shipping the shared group would have signed out every
        // existing user on upgrade.
        guard Self.accessGroup(for: account) != nil,
              let legacy = read(account, in: nil)
        else { return nil }

        write(account, legacy)          // now in the shared group
        SecItemDelete(baseQuery(account, group: nil) as CFDictionary)
        return legacy
    }

    private func read(_ account: String, in group: String?) -> String? {
        var q = baseQuery(account, group: group)
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
