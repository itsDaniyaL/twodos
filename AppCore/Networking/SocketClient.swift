import Foundation
import OSLog

/// A minimal Socket.IO v4 client built directly on `URLSessionWebSocketTask`.
///
/// The Flutter app pulls in `socket_io_client`; this replaces it with roughly
/// 250 lines of protocol handling so the native app ships with zero third-party
/// code. Only the subset twodos actually uses is implemented.
///
/// ## Wire format
/// Socket.IO layers two protocols. Engine.IO frames carry a single-digit type:
/// ```
/// 0  open       — server hello, carries { sid, pingInterval, pingTimeout }
/// 2  ping       — server heartbeat, must be answered with 3
/// 3  pong
/// 4  message    — payload is a Socket.IO packet
/// ```
/// Inside a `4` message, the Socket.IO packet type is the next digit:
/// ```
/// 0  CONNECT     — client sends 40{"token":"…"} to authenticate
/// 1  DISCONNECT
/// 2  EVENT       — 42["EVENT_NAME", {payload}]
/// 4  CONNECT_ERROR
/// ```
/// So a list update arrives as the text frame:
/// `42["LIST::ITEM_ADDED",{"listId":"…","actorId":"…"}]`
///
/// ## Authentication, and why the token is fetched rather than remembered
/// `connect` takes a provider, not a token. Access tokens live one hour and the
/// socket authenticates once per connection, so a string held from sign-in is
/// expired by the first reconnect an hour later. The server refuses it, and an
/// earlier version answered that refusal by reconnecting at once with the same
/// string — a tight loop of rejected handshakes, while collaboration silently
/// stopped. Asking for a token per attempt, and telling the provider which one
/// was refused, is what lets a reconnect succeed.
///
/// ## Reconnection
/// Exponential backoff with jitter, capped at 30s, reset on a successful
/// connect. ``reconnectNow()`` jumps the queue for the two cases where waiting
/// is pointless because something just changed for the better: the app came to
/// the foreground, or the network came back.
///
/// The socket is a nice-to-have — every event it delivers can also be
/// recovered by a refresh — so it never blocks the UI or surfaces an error, it
/// just quietly keeps trying. Events sent while it was down are not replayed by
/// the server, which is why a *resumed* connection is reported separately: it is
/// the owner's cue to re-read everything.
actor SocketClient {
    static let shared = SocketClient()

    /// Supplies a token to authenticate with. The argument is the token the
    /// server just refused, if any — "do not hand me this one again".
    typealias TokenProvider = @Sendable (_ rejected: String?) async -> String?

    private let logger = Logger(subsystem: "app.twodos", category: "socket")

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var tokenProvider: TokenProvider?
    private var pingTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isStopped = true
    /// Retrying is suspended while the app is in the background. Distinct from
    /// `isStopped`, which means signed out: a paused socket is still wanted and
    /// comes back on ``reconnectNow()``.
    private var isPaused = false
    private var handler: (@Sendable (SocketEvent) -> Void)?

    /// Which connection attempt is current. A replaced socket still delivers
    /// its receive failure afterwards; without this, that late failure
    /// schedules a reconnect on top of the live one.
    private var generation = 0
    /// The token the current attempt authenticated with, so a refusal can name it.
    private var currentToken: String?
    /// Set when a handshake is refused, so the next attempt renews the token.
    private var rejectedToken: String?
    /// Consecutive refused handshakes. A session the server will not accept
    /// even with a renewed token is not going to start working on a timer.
    private var authFailures = 0
    private static let maxAuthFailures = 3
    /// Whether this session has ever completed a handshake — drives `.resumed`.
    private var hasConnectedBefore = false
    private var isHandshakeComplete = false
    /// When the last frame of any kind arrived. A socket the app was suspended
    /// under looks connected and is usually dead; this is how to tell.
    private var lastFrameAt: Date = .distantPast
    /// When the current attempt began, while it has not yet completed its
    /// handshake. Launch connects and the foreground callback lands a moment
    /// later; without this the second would throw away the first mid-handshake.
    private var attemptStartedAt: Date?

    private init() {}

    // MARK: - Lifecycle

    /// Opens the connection and begins delivering events to `handler`.
    func connect(tokenProvider: @escaping TokenProvider, handler: @escaping @Sendable (SocketEvent) -> Void) {
        self.tokenProvider = tokenProvider
        self.handler = handler
        isStopped = false
        isPaused = false
        reconnectAttempt = 0
        authFailures = 0
        rejectedToken = nil
        hasConnectedBefore = false
        reopen()
    }

    /// Whether a session has asked for a socket. False while signed out, and
    /// before the first ``connect(tokenProvider:handler:)`` of an offline launch.
    var isStarted: Bool { !isStopped }

    /// Reconnects now rather than when the backoff expires.
    ///
    /// A connection that is demonstrably alive — a frame arrived within the
    /// heartbeat window — is left alone, so calling this on every foreground or
    /// network change costs nothing when nothing is wrong.
    ///
    /// `unpausing: false` is for triggers that can fire while the app is in
    /// the background — a network change during a geofence wake, say — and
    /// must not undo ``pause()``.
    func reconnectNow(unpausing: Bool = true) {
        guard !isStopped else { return }
        if isPaused, !unpausing { return }
        isPaused = false
        if isHandshakeComplete, Date.now.timeIntervalSince(lastFrameAt) < pingDeadline {
            return
        }
        if !isHandshakeComplete, let attemptStartedAt, Date.now.timeIntervalSince(attemptStartedAt) < 10 {
            return
        }
        reconnectAttempt = 0
        // Something just changed for the better; a session refused three times
        // earlier deserves one more try now.
        authFailures = 0
        reopen()
    }

    /// Lets the connection go while the app is in the background, without
    /// ending the session. iOS suspends the process anyway; what this prevents
    /// is a backoff timer firing on the way back and racing ``reconnectNow()``.
    func pause() {
        guard !isStopped else { return }
        isPaused = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if isHandshakeComplete { handler?(.connectionChanged(false)) }
        teardown()
    }

    func disconnect() {
        isStopped = true
        handler = nil
        tokenProvider = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        logger.info("Disconnected.")
    }

    private func teardown() {
        generation += 1
        isHandshakeComplete = false
        attemptStartedAt = nil
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Connection

    /// Drops whatever is there and starts a fresh attempt.
    private func reopen() {
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        attemptStartedAt = .now
        let attempt = generation
        Task { await self.openSocket(attempt: attempt) }
    }

    private func openSocket(attempt: Int) async {
        guard !isStopped, !isPaused, attempt == generation, let tokenProvider else { return }

        let token = await tokenProvider(rejectedToken)
        // The provider may have refreshed over the network; the world can have
        // moved on in the meantime.
        guard !isStopped, !isPaused, attempt == generation else { return }
        guard let token else {
            logger.info("No usable token; waiting.")
            scheduleReconnect()
            return
        }
        currentToken = token

        var components = URLComponents(url: APIClient.baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket")
        ]
        guard let url = components.url else { return }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)

        self.session = session
        self.task = task
        task.resume()

        logger.info("Opening \(url.absoluteString, privacy: .public)")

        // Announce ourselves. The server reads `handshake.auth.token` and
        // expects the bare token — no "Bearer" prefix.
        send(raw: "40" + (jsonString(["token": token]) ?? "{}"))

        Task { await self.receiveLoop(attempt: attempt) }
    }

    private func scheduleReconnect() {
        guard !isStopped, !isPaused else { return }
        reconnectAttempt += 1
        let base = min(pow(1.6, Double(reconnectAttempt)), 30)
        let jitter = Double.random(in: 0...0.4) * base
        let delay = min(base + jitter, 30)
        logger.info("Reconnecting in \(String(format: "%.1f", delay))s (attempt \(self.reconnectAttempt))")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.reopenIfNeeded()
        }
    }

    private func reopenIfNeeded() {
        guard !isStopped, !isPaused else { return }
        reopen()
    }

    // MARK: - Receiving

    private func receiveLoop(attempt: Int) async {
        guard let task, attempt == generation else { return }
        do {
            while !isStopped, attempt == generation {
                let message = try await task.receive()
                guard attempt == generation else { return }
                lastFrameAt = .now
                switch message {
                case .string(let text):
                    handle(frame: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(frame: text) }
                @unknown default:
                    break
                }
            }
        } catch {
            // A socket that was replaced or paused fails on its way out; that
            // failure is not news.
            guard !isStopped, !isPaused, attempt == generation else { return }
            logger.warning("Receive failed: \(error.localizedDescription)")
            handler?(.connectionChanged(false))
            teardown()
            scheduleReconnect()
        }
    }

    private func handle(frame: String) {
        guard let first = frame.first else { return }
        let payload = String(frame.dropFirst())

        switch first {
        case "0": // Engine.IO open
            handleOpen(payload)

        case "2": // Server ping
            send(raw: "3")
            armPingTimeout()

        case "4": // Socket.IO packet
            handleSocketPacket(payload)

        default:
            break
        }
    }

    private func handleOpen(_ payload: String) {
        // { "sid": …, "pingInterval": 25000, "pingTimeout": 20000 }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let interval = (json["pingInterval"] as? Double ?? 25_000) / 1000
        let timeout = (json["pingTimeout"] as? Double ?? 20_000) / 1000
        pingDeadline = interval + timeout
        armPingTimeout()
    }

    private var pingDeadline: TimeInterval = 45

    /// If the server's heartbeat stops arriving the TCP connection may be a
    /// zombie — `receive()` will not throw, so nothing else would notice.
    private func armPingTimeout() {
        pingTimeoutTask?.cancel()
        let deadline = pingDeadline
        pingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled, let self else { return }
            await self.handlePingTimeout()
        }
    }

    private func handlePingTimeout() {
        guard !isStopped, !isPaused else { return }
        logger.warning("Heartbeat lost — reconnecting.")
        handler?(.connectionChanged(false))
        teardown()
        scheduleReconnect()
    }

    private func handleSocketPacket(_ payload: String) {
        guard let first = payload.first else { return }
        let rest = String(payload.dropFirst())

        switch first {
        case "0": // CONNECT acknowledged
            reconnectAttempt = 0
            authFailures = 0
            rejectedToken = nil
            isHandshakeComplete = true
            logger.info("Connected.")
            handler?(.connectionChanged(true))
            // See the type note: the server did not queue anything for us
            // while we were away, so a second connection means an unknown gap.
            if hasConnectedBefore { handler?(.resumed) }
            hasConnectedBefore = true

        case "2": // EVENT
            decodeEvent(rest)

        case "1": // DISCONNECT from server
            logger.info("Server closed the session.")
            handler?(.connectionChanged(false))
            teardown()
            scheduleReconnect()

        case "4": // CONNECT_ERROR — usually an expired token
            logger.warning("Connect rejected: \(rest, privacy: .public)")
            handler?(.connectionChanged(false))
            teardown()
            // The next attempt asks for a renewed token rather than presenting
            // this one again. Backed off like any other failure, and abandoned
            // after a few — until `reconnectNow` says something has changed.
            rejectedToken = currentToken
            authFailures += 1
            if authFailures < Self.maxAuthFailures {
                scheduleReconnect()
            } else {
                logger.warning("Handshake refused \(self.authFailures) times; waiting for the app to return.")
            }

        default:
            break
        }
    }

    /// Parses `["EVENT_NAME", { … }]`.
    private func decodeEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let name = array.first as? String else { return }
        let body = array.count > 1 ? (array[1] as? [String: Any] ?? [:]) : [:]

        guard let event = SocketEvent(name: name, body: body) else {
            logger.debug("Ignoring unhandled event \(name, privacy: .public)")
            return
        }
        handler?(event)
    }

    // MARK: - Sending

    private func send(raw text: String) {
        guard let task else { return }
        task.send(.string(text)) { [logger] error in
            if let error { logger.warning("Send failed: \(error.localizedDescription)") }
        }
    }

    /// Emits a Socket.IO event.
    func emit(_ name: String, _ body: [String: Any]) {
        guard let payload = jsonString(body) else { return }
        send(raw: "42[\"\(name)\",\(payload)]")
    }

    func sendTyping(listId: String, isTyping: Bool) {
        emit("TYPING", ["listId": listId, "isTyping": isTyping])
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Events

/// The server-push events twodos acts on, already parsed.
///
/// `actorId` is carried on every list event so the receiver can ignore echoes of
/// its own writes — the REST response already updated local state, and
/// re-fetching would make the user's own edit flicker.
enum SocketEvent: Sendable {
    case connectionChanged(Bool)
    /// A connection replacing an earlier one. Events broadcast in between were
    /// not queued for us, so whatever they would have said has to be re-read.
    case resumed

    case notification([String: String])
    case listUpdated(listId: String, actorId: String?)
    case listArchived(listId: String, archived: Bool, actorId: String?)
    case inviteDeclined(listId: String, actorId: String?)
    case itemAdded(listId: String, actorId: String?)
    case itemUpdated(listId: String, actorId: String?)
    case itemAssigned(listId: String, todoId: String, assigneeId: String?, actorId: String?)
    case challengeChanged(listId: String, actorId: String?)
    case challengeDeclined(listId: String, actorId: String?)
    case challengeScored(listId: String, scores: [String: Int], actorId: String?)
    case challengeEnded(listId: String, winnerId: String?, scores: [String: Int], endReason: String?, actorId: String?)
    case itemDeleted(listId: String, actorId: String?)
    case itemsCleared(listId: String, actorId: String?)
    case itemsReordered(listId: String, actorId: String?)
    case locationTrigger(listId: String, event: String)
    case presence(userId: String, online: Bool, lastSeen: Date?)
    case typing(userId: String, listId: String, isTyping: Bool)

    init?(name: String, body: [String: Any]) {
        let listId = body["listId"] as? String
        let actorId = body["actorId"] as? String

        switch name {
        case "NOTIFICATION":
            // Flatten to `[String: String]` so the event stays `Sendable`;
            // the nested `data` object is re-encoded as a JSON string, which is
            // also how `GET /api/notifications` returns it.
            var flat: [String: String] = [:]
            for (key, value) in body {
                if let string = value as? String {
                    flat[key] = string
                } else if key == "data",
                          let json = try? JSONSerialization.data(withJSONObject: value),
                          let text = String(data: json, encoding: .utf8) {
                    flat[key] = text
                }
            }
            guard flat["id"] != nil else { return nil }
            self = .notification(flat)

        case "LIST::UPDATED":
            guard let listId else { return nil }
            self = .listUpdated(listId: listId, actorId: actorId)

        case "LIST::ARCHIVED":
            guard let listId else { return nil }
            self = .listArchived(listId: listId, archived: body["archived"] as? Bool ?? false, actorId: actorId)

        case "LIST::INVITE_DECLINED":
            guard let listId else { return nil }
            self = .inviteDeclined(listId: listId, actorId: actorId)

        case "LIST::ITEM_ADDED":
            guard let listId else { return nil }
            self = .itemAdded(listId: listId, actorId: actorId)

        case "CHALLENGE::CREATED", "CHALLENGE::ACCEPTED":
            guard let listId else { return nil }
            self = .challengeChanged(listId: listId, actorId: actorId)

        case "CHALLENGE::DECLINED":
            guard let listId else { return nil }
            self = .challengeDeclined(listId: listId, actorId: actorId)

        case "CHALLENGE::SCORED":
            // The whole scoreboard travels with the event — a scoreboard that
            // only moves on the next refresh is not a live scoreboard.
            guard let listId else { return nil }
            self = .challengeScored(
                listId: listId,
                scores: (body["scores"] as? [String: Int]) ?? [:],
                actorId: actorId
            )

        case "CHALLENGE::ENDED":
            guard let listId else { return nil }
            self = .challengeEnded(
                listId: listId,
                winnerId: body["winnerId"] as? String,
                scores: (body["scores"] as? [String: Int]) ?? [:],
                endReason: body["endReason"] as? String,
                actorId: actorId
            )

        case "LIST::ITEM_ASSIGNED":
            // The new value travels with the event, so the row updates without
            // a re-fetch. `assigneeId` is genuinely absent when unclaimed.
            guard let listId else { return nil }
            self = .itemAssigned(
                listId: listId,
                todoId: body["todoId"] as? String ?? "",
                assigneeId: body["assigneeId"] as? String,
                actorId: actorId
            )

        case "LIST::ITEM_UPDATED":
            guard let listId else { return nil }
            self = .itemUpdated(listId: listId, actorId: actorId)

        case "LIST::ITEM_DELETED":
            guard let listId else { return nil }
            self = .itemDeleted(listId: listId, actorId: actorId)

        case "LIST::ITEMS_CLEARED":
            guard let listId else { return nil }
            self = .itemsCleared(listId: listId, actorId: actorId)

        case "LIST::ITEMS_REORDERED":
            guard let listId else { return nil }
            self = .itemsReordered(listId: listId, actorId: actorId)

        case "LOCATION_TRIGGER":
            guard let listId, let event = body["event"] as? String else { return nil }
            self = .locationTrigger(listId: listId, event: event)

        case "PRESENCE":
            guard let userId = body["userId"] as? String else { return nil }
            let lastSeen = (body["lastSeen"] as? String).flatMap {
                ISO8601DateFormatter.twodosFractional.date(from: $0)
                    ?? ISO8601DateFormatter.twodosPlain.date(from: $0)
            }
            self = .presence(userId: userId, online: (body["status"] as? String) == "online", lastSeen: lastSeen)

        case "TYPING":
            guard let userId = body["userId"] as? String, let listId else { return nil }
            self = .typing(userId: userId, listId: listId, isTyping: body["isTyping"] as? Bool ?? false)

        default:
            return nil
        }
    }
}
