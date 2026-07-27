import Foundation
import WatchConnectivity
import OSLog

/// The phone's half of the watch link.
///
/// The phone owns authentication, so it is responsible for handing the watch a
/// session and keeping it current. Everything goes through
/// `updateApplicationContext`: it is "latest state wins", it survives the watch
/// being asleep or out of range, and repeated calls coalesce rather than
/// queueing — exactly the semantics for "here is the current session and the
/// current lists".
@MainActor
@Observable
final class PhoneConnectivityService: NSObject {
    static let shared = PhoneConnectivityService()

    private let logger = Logger(subsystem: "app.twodos", category: "watch")

    /// Set by the app so the watch's explicit sync request can be answered.
    var currentPayload: (() -> [String: Any])?

    private(set) var isWatchPaired = false
    private(set) var isWatchAppInstalled = false

    /// Guards against pushing the same payload repeatedly. Application context
    /// updates are cheap but not free, and list refreshes are frequent.
    private var lastPushedHash: Int?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Pushes the current session and a compact snapshot of the lists.
    ///
    /// No-ops when there is no watch, and when nothing has changed since the
    /// last push.
    func push(
        token: String?,
        expiresAt: Date?,
        lists: [TodoList],
        currentUserId: String?,
        partnerNames: [String: String] = [:]
    ) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return }

        var payload: [String: Any] = [:]

        if let token, !token.isEmpty {
            payload[WatchPayloadKey.token] = token
            if let expiresAt {
                payload[WatchPayloadKey.expiresAt] = expiresAt.timeIntervalSince1970
            }
            let snapshot = WatchList.snapshot(
                from: lists,
                currentUserId: currentUserId,
                partnerNames: partnerNames
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                payload[WatchPayloadKey.lists] = data
            }
        } else {
            payload[WatchPayloadKey.signedOut] = true
        }

        // The token changes rarely; the lists change often. Hashing both means
        // an unchanged refresh costs nothing.
        let hash = payloadHash(payload)
        guard hash != lastPushedHash else { return }
        lastPushedHash = hash

        do {
            try session.updateApplicationContext(payload)
            logger.debug("Pushed context to watch.")
        } catch {
            logger.warning("Watch push failed: \(error.localizedDescription)")
        }
    }

    private func payloadHash(_ payload: [String: Any]) -> Int {
        var hasher = Hasher()
        hasher.combine(payload[WatchPayloadKey.token] as? String)
        hasher.combine(payload[WatchPayloadKey.signedOut] as? Bool)
        hasher.combine((payload[WatchPayloadKey.lists] as? Data)?.count)
        hasher.combine((payload[WatchPayloadKey.lists] as? Data)?.hashValue)
        return hasher.finalize()
    }
}

/// Keys shared with the watch. Short, because the application context payload
/// has a size limit and the list snapshot needs the room.
enum WatchPayloadKey {
    static let token = "t"
    static let expiresAt = "e"
    static let lists = "l"
    static let signedOut = "o"
}

// MARK: - Delegate

extension PhoneConnectivityService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isWatchPaired = paired
            self.isWatchAppInstalled = installed
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Fires when the user switches to a different paired watch. The new watch
    /// has none of our data, so the cached hash has to go or the next push will
    /// be skipped as a duplicate.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in self.lastPushedHash = nil }
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isWatchPaired = paired
            self.isWatchAppInstalled = installed
            self.lastPushedHash = nil
        }
    }

    /// The watch asking for a session directly, which happens when it launches
    /// with nothing cached.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            replyHandler(self.currentPayload?() ?? [:])
        }
    }
}
