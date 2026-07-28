import Foundation
import WatchConnectivity
import OSLog

/// The link back to the phone.
///
/// ## What it is for
/// The watch cannot sign in — there is no keyboard worth the name and no Sign in
/// with Apple flow. So the phone owns authentication and hands the watch a
/// session over `WatchConnectivity`, using `updateApplicationContext`, which is
/// the right channel for "latest state wins" data: it survives the watch being
/// asleep, coalesces if it fires repeatedly, and does not queue up stale copies
/// the way `transferUserInfo` would.
///
/// ## What it is *not* for
/// It is not the data path. Once the watch has a token it talks to the API
/// directly, so it works on Wi-Fi or cellular with the phone switched off. The
/// phone also pushes a compact snapshot of the lists, which is purely a
/// head start so the watch has something to draw before its own fetch lands.
@MainActor
@Observable
final class WatchConnectivityBridge: NSObject {
    static let shared = WatchConnectivityBridge()

    private let logger = Logger(subsystem: "app.twodos.watch", category: "connectivity")

    /// Whether the phone has ever handed us a session.
    private(set) var hasReceivedSession = false
    /// True when the phone is reachable right now — used only to word the
    /// "sign in on your iPhone" prompt accurately.
    private(set) var isPhoneReachable = false

    /// Called when a fresh session arrives so the store can start fetching.
    var onSessionReceived: ((_ token: String, _ expiresAt: Date?) -> Void)?
    /// Called with the phone's snapshot of the lists.
    var onSnapshotReceived: (([WatchList]) -> Void)?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // Anything the phone sent while we were asleep is already waiting here.
        apply(context: session.receivedApplicationContext)
    }

    /// Asks the phone to send a fresh session and snapshot — used when the user
    /// pulls to refresh on the watch with no token yet.
    func requestSync() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([Key.request: Key.sync], replyHandler: { [weak self] reply in
            Task { @MainActor in self?.apply(context: reply) }
        }, errorHandler: { [logger] error in
            logger.warning("Sync request failed: \(error.localizedDescription)")
        })
    }

    /// Tells the phone the watch has changed something on the server.
    ///
    /// The watch talks to the API directly, so the phone has no way of knowing
    /// a tick happened — the server does not push the user their own changes,
    /// and the phone would otherwise show a stale list until it was next
    /// foregrounded or pulled. The phone refreshes and replies with a fresh
    /// snapshot, which also corrects the watch if the write raced with anything.
    ///
    /// Falls back to `transferUserInfo` when the phone is not reachable, which
    /// is most of the time — that queue is delivered whenever the phone next
    /// runs, so the notification is never simply dropped.
    func notifyMutation() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let message = [Key.request: Key.didMutate]

        guard session.isReachable else {
            session.transferUserInfo(message)
            return
        }

        session.sendMessage(message, replyHandler: { [weak self] reply in
            Task { @MainActor in self?.apply(context: reply) }
        }, errorHandler: { [logger] error in
            logger.warning("Mutation notice failed, queueing: \(error.localizedDescription)")
            session.transferUserInfo(message)
        })
    }

    // MARK: - Payload

    /// Keys shared with the phone. Kept deliberately short — application context
    /// payloads have a size limit and the snapshot is the bulky part.
    enum Key {
        static let token = "t"
        static let expiresAt = "e"
        static let lists = "l"
        static let signedOut = "o"
        // Watch → phone. Must match `WatchPayloadKey` on the phone side.
        static let request = "r"
        static let sync = "sync"
        static let didMutate = "mut"
    }

    private func apply(context: [String: Any]) {
        guard !context.isEmpty else { return }

        if context[Key.signedOut] as? Bool == true {
            logger.info("Phone signed out — clearing local session.")
            hasReceivedSession = false
            WatchSessionStore.shared.clear()
            onSnapshotReceived?([])
            return
        }

        if let token = context[Key.token] as? String, !token.isEmpty {
            let expiry = context[Key.expiresAt] as? Double
            let expiresAt = expiry.map { Date(timeIntervalSince1970: $0) }
            WatchSessionStore.shared.save(token: token, expiresAt: expiresAt)
            hasReceivedSession = true
            onSessionReceived?(token, expiresAt)
            logger.info("Session received from phone.")
        }

        if let raw = context[Key.lists] as? Data,
           let snapshot = try? JSONDecoder().decode([WatchList].self, from: raw) {
            onSnapshotReceived?(snapshot)
            logger.info("Snapshot received: \(snapshot.count) list(s).")
        }
    }
}

// MARK: - Delegate

extension WatchConnectivityBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.isPhoneReachable = reachable
            self.apply(context: context)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context: context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(context: message) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isPhoneReachable = reachable }
    }
}

// MARK: - Session storage

/// Keychain storage for the watch's copy of the token.
///
/// The watch has its own keychain — nothing is shared with the phone — so the
/// token has to be persisted here or the app would be signed out every time it
/// is relaunched out of range.
@MainActor
final class WatchSessionStore {
    static let shared = WatchSessionStore()

    private let service = "app.twodos.watch.session"
    private let account = "accessToken"
    private let expiryKey = "watch.session.expiresAt"

    private init() {}

    var token: String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        query.removeAll()
        return String(data: data, encoding: .utf8)
    }

    var expiresAt: Date? {
        UserDefaults.standard.object(forKey: expiryKey) as? Date
    }

    /// True when the phone's token has run out and only the phone can renew it.
    /// The watch deliberately does not hold a refresh token: refreshing from two
    /// devices races, and the API revokes every session when it sees that.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < .now
    }

    func save(token: String, expiresAt: Date?) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
        UserDefaults.standard.set(expiresAt, forKey: expiryKey)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }
}
