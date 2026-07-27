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
/// ## Reconnection
/// Exponential backoff with jitter, capped at 30s, reset on a successful
/// connect. The socket is a nice-to-have — every event it delivers can also be
/// recovered by a pull-to-refresh — so it never blocks the UI or surfaces an
/// error, it just quietly keeps trying.
actor SocketClient {
    static let shared = SocketClient()

    private let logger = Logger(subsystem: "app.twodos", category: "socket")

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var token: String?
    private var pingTimeoutTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isStopped = true
    private var handler: (@Sendable (SocketEvent) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    /// Opens the connection and begins delivering events to `handler`.
    func connect(token: String, handler: @escaping @Sendable (SocketEvent) -> Void) {
        self.token = token
        self.handler = handler
        isStopped = false
        reconnectAttempt = 0
        openSocket()
    }

    /// Swaps in a freshly refreshed token. The server validates the token during
    /// the handshake, so the only way to apply a new one is a full reconnect.
    func reconnect(token: String) {
        guard !isStopped else { return }
        self.token = token
        teardown()
        openSocket()
    }

    func disconnect() {
        isStopped = true
        handler = nil
        teardown()
        logger.info("Disconnected.")
    }

    private func teardown() {
        pingTimeoutTask?.cancel()
        pingTimeoutTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Connection

    private func openSocket() {
        guard !isStopped, let token else { return }

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

        Task { await self.receiveLoop() }
    }

    private func scheduleReconnect() {
        guard !isStopped else { return }
        reconnectAttempt += 1
        let base = min(pow(1.6, Double(reconnectAttempt)), 30)
        let jitter = Double.random(in: 0...0.4) * base
        let delay = min(base + jitter, 30)
        logger.info("Reconnecting in \(String(format: "%.1f", delay))s (attempt \(self.reconnectAttempt))")

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.reopenIfNeeded()
        }
    }

    private func reopenIfNeeded() {
        guard !isStopped else { return }
        teardown()
        openSocket()
    }

    // MARK: - Receiving

    private func receiveLoop() async {
        guard let task else { return }
        do {
            while !isStopped {
                let message = try await task.receive()
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
            guard !isStopped else { return }
            logger.warning("Receive failed: \(error.localizedDescription)")
            handler?(.connectionChanged(false))
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
        guard !isStopped else { return }
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
            logger.info("Connected.")
            handler?(.connectionChanged(true))

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
            handler?(.authRejected)
            teardown()

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
    case authRejected

    case notification([String: String])
    case listUpdated(listId: String, actorId: String?)
    case listArchived(listId: String, archived: Bool, actorId: String?)
    case inviteDeclined(listId: String, actorId: String?)
    case itemAdded(listId: String, actorId: String?)
    case itemUpdated(listId: String, actorId: String?)
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
