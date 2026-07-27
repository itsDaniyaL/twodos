import Foundation
import OSLog

/// The single entry point to the twodos REST API.
///
/// ## Envelope
/// Every endpoint answers HTTP 200 and puts the real result in the body:
/// ```json
/// { "statusCode": 200, "data": … }
/// { "statusCode": 404, "statusMessage": "…" }
/// ```
/// so `statusCode` is parsed from the body, never from `URLResponse`.
///
/// ## Token refresh
/// A single actor-serialised refresh runs before any request when the access
/// token is close to expiry, and once more if a call still comes back
/// unauthorised. Concurrent callers await the same refresh task rather than
/// each firing their own — the API revokes all sessions when it sees
/// overlapping refreshes for one platform.
actor APIClient {
    static let shared = APIClient()

    private let logger = Logger(subsystem: "app.twodos", category: "api")
    private let session: URLSession
    private let decoder: JSONDecoder
    private var refreshTask: Task<Bool, Never>?

    /// A token supplied by the host app rather than read from ``TokenStore``.
    ///
    /// The watch never signs in: the phone hands it a session over
    /// `WatchConnectivity`, and the watch deliberately holds no refresh token —
    /// two devices refreshing the same session race, and the API revokes every
    /// session when it sees that. So on watchOS this is the only token source,
    /// and a 401 is reported straight back rather than triggering a refresh.
    private var injectedToken: String?

    func setStandaloneToken(_ token: String?) {
        injectedToken = token
    }

    /// Called when the session is definitively dead so the app can sign out.
    @MainActor static var onSessionExpired: (@MainActor () -> Void)?

    // MARK: - Configuration

    /// Flip to true to talk to a server on the local network during development.
    private static let useLocalServer = false
    private static let localServer = "http://127.0.0.1:1234"

    static var baseURL: URL {
        if useLocalServer, let url = URL(string: localServer) { return url }
        #if DEBUG
        return URL(string: "https://twodos-api-staging-container.azurewebsites.net")! // TEMPX
        #else
        return URL(string: "https://twodos.app")!
        #endif
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        // The API mixes ISO-8601 with and without fractional seconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.twodosFractional.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.twodosPlain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparsable date: \(raw)")
            )
        }
    }

    // MARK: - Request plumbing

    /// `internal` rather than `private` so the test target can assert the
    /// envelope's decoding directly — it is the shape every endpoint answers in.
    struct Envelope<T: Decodable>: Decodable {
        let statusCode: Int
        let data: T?
        let statusMessage: String?
    }

    /// Endpoints that must not trigger a refresh (they *are* the auth flow).
    private static let unauthenticatedPaths: Set<String> = [
        "/api/account/login", "/api/account/login-otp", "/api/account/request-otp",
        "/api/account/register", "/api/account/refresh", "/api/account/social-login",
        "/api/account/validate-email", "/api/account/email-token",
        "/api/account/password-reset-token", "/api/account/reset-password",
        "/api/account/complete-invite", "/api/account/resend-invite"
    ]

    private func buildRequest(
        _ method: String,
        _ path: String,
        body: [String: Any?]? = nil,
        query: [String: String]? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method

        if let body {
            // Preserve explicit nulls: `doBefore: nil` is how a deadline is cleared.
            let sanitised = body.mapValues { $0 ?? NSNull() }
            request.httpBody = try JSONSerialization.data(withJSONObject: sanitised)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Where a successful response keeps its payload.
    enum PayloadLocation {
        /// The normal envelope: `{ "statusCode": 200, "data": … }`.
        case nested
        /// `GET /api/account/me` alone puts the user's fields *alongside*
        /// `statusCode` rather than under `data`, so `T` has to be decoded from
        /// the envelope's root. Decoding it as `.nested` finds no `data` key,
        /// yields nil, and fails with "success with no data" — which is exactly
        /// what happened before this existed.
        case root
    }

    /// Performs a request, decoding the payload as `T`.
    private func perform<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any?]? = nil,
        query: [String: String]? = nil,
        as type: T.Type = T.self,
        from location: PayloadLocation = .nested,
        allowRetry: Bool = true
    ) async throws(APIError) -> T {
        let needsAuth = !Self.unauthenticatedPaths.contains(path)

        // With an injected token there is nothing to refresh — see `injectedToken`.
        if needsAuth, injectedToken == nil, await TokenStore.shared.accessTokenNeedsRefresh() {
            _ = await refreshIfPossible()
        }

        var request: URLRequest
        do {
            request = try buildRequest(method, path, body: body, query: query)
        } catch {
            throw APIError.unknown
        }

        if needsAuth {
            // Written out rather than with `??` because the fallback is an
            // actor-isolated read, and `??` takes an autoclosure that cannot await.
            let token: String?
            if let injectedToken {
                token = injectedToken
            } else {
                token = await TokenStore.shared.accessToken
            }
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .timedOut, .cannotFindHost, .dataNotAllowed, .internationalRoamingOff:
                logger.warning("\(method) \(path) — offline: \(error.code.rawValue)")
                throw APIError.offline
            case .cancelled:
                throw APIError.unknown
            default:
                logger.error("\(method) \(path) — transport error: \(error.localizedDescription)")
                throw APIError.offline
            }
        } catch {
            throw APIError.unknown
        }

        // The status line is read the same way for both payload shapes; only
        // where the value comes from differs.
        let statusCode: Int
        let statusMessage: String?
        let value: T?
        do {
            switch location {
            case .nested:
                let envelope = try decoder.decode(Envelope<T>.self, from: data)
                statusCode = envelope.statusCode
                statusMessage = envelope.statusMessage
                value = envelope.data

            case .root:
                let status = try decoder.decode(BareStatus.self, from: data)
                statusCode = status.statusCode
                statusMessage = status.statusMessage
                // Only decode the payload on success: an error response carries
                // `statusMessage` where the model expects its own fields, and
                // the message is what the caller wants in that case anyway.
                value = statusCode == 200 ? try decoder.decode(T.self, from: data) : nil
            }
        } catch {
            // A 401 from the gateway may not carry the envelope at all.
            if let raw = try? decoder.decode(BareStatus.self, from: data), raw.statusCode == 401 {
                return try await handleUnauthorized(method, path, body: body, query: query,
                                                    from: location,
                                                    allowRetry: allowRetry, needsAuth: needsAuth)
            }
            logger.error("\(method) \(path) — decode failed: \(String(describing: error))")
            throw APIError.decoding("\(path): \(error)")
        }

        switch statusCode {
        case 200:
            guard let value else {
                // `Bool` and `String` results are sometimes omitted on success.
                if let empty = EmptySuccess.value(for: T.self) { return empty }
                throw APIError.decoding("\(path): success with no data")
            }
            return value

        // A 401 always means the token is bad. A 403 on an authenticated route
        // usually does too, so both go through the refresh-and-retry path.
        case 401, 403:
            guard needsAuth else { fallthrough }
            return try await handleUnauthorized(method, path, body: body, query: query,
                                                from: location,
                                                allowRetry: allowRetry, needsAuth: needsAuth)

        default:
            let message = statusMessage?.isEmpty == false
                ? statusMessage!
                : "Something went wrong. Please try again."
            logger.info("\(method) \(path) — \(statusCode): \(message)")
            throw APIError.server(message)
        }
    }

    struct BareStatus: Decodable {
        let statusCode: Int
        let statusMessage: String?
    }

    private func handleUnauthorized<T: Decodable>(
        _ method: String,
        _ path: String,
        body: [String: Any?]?,
        query: [String: String]?,
        from location: PayloadLocation,
        allowRetry: Bool,
        needsAuth: Bool
    ) async throws(APIError) -> T {
        guard needsAuth, allowRetry, injectedToken == nil, await refreshIfPossible() else {
            if needsAuth {
                await MainActor.run { Self.onSessionExpired?() }
            }
            throw APIError.unauthorized
        }
        return try await perform(method, path, body: body, query: query,
                                 as: T.self, from: location, allowRetry: false)
    }

    /// Requests with no meaningful response body.
    @discardableResult
    private func performVoid(
        _ method: String,
        _ path: String,
        body: [String: Any?]? = nil,
        query: [String: String]? = nil
    ) async throws(APIError) -> Bool {
        try await perform(method, path, body: body, query: query, as: FlexibleTrue.self).value
    }

    // MARK: - Token refresh

    /// Runs at most one refresh at a time; concurrent callers share the result.
    ///
    /// The de-duplication only works if `refreshTask` is published *before* the
    /// first suspension point. Reading the refresh token is an actor hop to
    /// `TokenStore`, so doing it out here — as an earlier version did — released
    /// this actor's isolation while `refreshTask` was still nil, and every
    /// concurrent caller sailed through the check and read the same token.
    ///
    /// That is fatal against this API, not merely wasteful: refresh tokens are
    /// single-use and rotated, and presenting a spent one is treated as theft —
    /// `403 "Security alert: token reuse detected. All sessions have been
    /// terminated."` So the token read now happens *inside* the task, and
    /// nothing between entry and the assignment below may `await`.
    private func refreshIfPossible() async -> Bool {
        if let refreshTask { return await refreshTask.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            guard await TokenStore.shared.refreshTokenIsUsable,
                  let token = await TokenStore.shared.refreshToken else { return false }
            return await self.performRefresh(using: token)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return await task.value
    }

    private func performRefresh(using refreshToken: String) async -> Bool {
        do {
            let request = try buildRequest(
                "POST", "/api/account/refresh",
                body: ["refreshToken": refreshToken, "platform": APIConstants.platform]
            )
            let (data, _) = try await session.data(for: request)
            let envelope = try decoder.decode(Envelope<AuthSession>.self, from: data)
            guard envelope.statusCode == 200, let auth = envelope.data else { return false }
            await MainActor.run { TokenStore.shared.save(auth) }
            logger.info("Session refreshed; valid until \(auth.expiresAt, privacy: .public)")
            return true
        } catch {
            logger.warning("Refresh failed: \(String(describing: error))")
            return false
        }
    }
}

// MARK: - Account

extension APIClient {
    func signIn(email: String, password: String) async throws(APIError) -> AuthSession {
        try await perform("POST", "/api/account/login",
                          body: ["email": email, "password": password, "platform": APIConstants.platform])
    }

    func requestOTP(email: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/request-otp", body: ["email": email])
    }

    func signInWithOTP(email: String, otp: String) async throws(APIError) -> AuthSession {
        try await perform("POST", "/api/account/login-otp",
                          body: ["email": email, "otp": otp, "platform": APIConstants.platform])
    }

    func signInWithApple(identityToken: String, name: String?) async throws(APIError) -> AuthSession {
        var body: [String: Any?] = [
            "provider": "apple",
            "token": identityToken,
            "platform": APIConstants.platform
        ]
        // Apple only supplies the name on the very first authorisation, so it is
        // forwarded when present and omitted otherwise.
        if let name, !name.isEmpty { body["name"] = name }
        return try await perform("POST", "/api/account/social-login", body: body)
    }

    func register(name: String, email: String, password: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/register",
                              body: ["name": name, "email": email, "password": password])
    }

    func verifyEmail(email: String, token: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/account/validate-email",
                              body: ["email": email, "token": token])
    }

    func requestEmailToken(email: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/email-token", body: ["email": email])
    }

    func requestInviteToken(email: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/resend-invite", body: ["email": email])
    }

    func completeInvite(email: String, token: String, password: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/complete-invite",
                              body: ["email": email, "token": token, "password": password])
    }

    func requestPasswordReset(email: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/account/password-reset-token", body: ["email": email])
    }

    func resetPassword(email: String, token: String, password: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/account/reset-password",
                              body: ["email": email, "token": token, "password": password])
    }

    func changePassword(email: String, current: String, new: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/account/change-password",
                              body: ["email": email, "currentPassword": current, "newPassword": new])
    }

    func signOut() async {
        _ = try? await performVoid("POST", "/api/account/logout")
    }

    /// `GET /api/account/me` is the one endpoint that returns the user at the
    /// envelope's top level rather than inside `data`, hence `from: .root`.
    func currentUser() async throws(APIError) -> CurrentUser {
        try await perform("GET", "/api/account/me", as: CurrentUser.self, from: .root)
    }

    func updateName(_ name: String) async throws(APIError) -> Bool {
        try await performVoid("PATCH", "/api/account/me", body: ["name": name])
    }

    func partners() async throws(APIError) -> [Partner] {
        try await perform("GET", "/api/account/partners", as: FlexibleArray<Partner>.self).values
    }

    func account(id: String) async throws(APIError) -> Partner {
        try await perform("GET", "/api/account/id/\(id)")
    }

    func socialLinks() async throws(APIError) -> [SocialLink] {
        try await perform("GET", "/api/account/social-links")
    }

    func unlinkSocial(provider: String) async throws(APIError) -> Bool {
        try await performVoid("DELETE", "/api/account/social-links/\(provider)")
    }

    func requestAccountDeletion(email: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/request-deletion", body: ["email": email])
    }

    func completeAccountDeletion(email: String, token: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/account/complete-deletion",
                              body: ["email": email, "token": token])
    }
}

// MARK: - Lists

extension APIClient {
    func lists() async throws(APIError) -> [TodoList] {
        try await perform("GET", "/api/todos")
    }

    func list(id: String) async throws(APIError) -> TodoList {
        try await perform("GET", "/api/todos/\(id)")
    }

    func createList(label: String, favorite: Bool, partnerEmail: String?) async throws(APIError) -> Bool {
        var body: [String: Any?] = ["label": label, "favorite": favorite]
        if let partnerEmail, !partnerEmail.isEmpty { body["partnerEmail"] = partnerEmail }
        return try await performVoid("POST", "/api/todos", body: body)
    }

    func updateList(id: String, label: String, favorite: Bool) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(id)", body: ["label": label, "favorite": favorite])
    }

    func deleteList(id: String) async throws(APIError) -> Bool {
        try await performVoid("DELETE", "/api/todos/\(id)")
    }

    func archiveList(id: String, archived: Bool) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(id)/archive", body: ["archive": archived])
    }

    func setListColor(id: String, hex: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(id)/color", body: ["color": hex])
    }

    func setListPriority(id: String, priority: ListPriority?) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(id)/priority", body: ["priority": priority?.apiValue])
    }

    func setListDeadline(id: String, date: Date?, target: AlarmTarget?) async throws(APIError) -> Bool {
        var body: [String: Any?] = ["deadline": date.map(ISO8601DateFormatter.twodosOut.string)]
        if let target { body["alarmTarget"] = target.apiValue }
        return try await performVoid("PUT", "/api/todos/\(id)/deadline", body: body)
    }

    func acceptInvite(listId: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(listId)/accept-invite")
    }

    func declineInvite(listId: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(listId)/decline-invite")
    }

    func clearCompleted(listId: String) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/\(listId)/clearDone")
    }
}

// MARK: - Todos

extension APIClient {
    func createTodo(listId: String, title: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/todos/\(listId)", body: ["title": title, "done": false])
    }

    func setTodoDone(listId: String, todoId: String, done: Bool) async throws(APIError) -> Bool {
        try await performVoid("PATCH", "/api/todos/\(listId)/\(todoId)/done", body: ["done": done])
    }

    func setTodoTitle(listId: String, todoId: String, title: String) async throws(APIError) -> Bool {
        try await performVoid("PATCH", "/api/todos/\(listId)/\(todoId)/title", body: ["title": title])
    }

    func setTodoDeadline(
        listId: String,
        todoId: String,
        date: Date?,
        target: AlarmTarget? = nil
    ) async throws(APIError) -> Bool {
        // `doBefore: null` clears the deadline, so the key is always sent.
        var body: [String: Any?] = ["doBefore": date.map(ISO8601DateFormatter.twodosOut.string)]
        if let target { body["alarmTarget"] = target.apiValue }
        return try await performVoid("PUT", "/api/todos/\(listId)/\(todoId)", body: body)
    }

    func deleteTodo(listId: String, todoId: String) async throws(APIError) -> Bool {
        try await performVoid("DELETE", "/api/todos/\(listId)/\(todoId)")
    }

    func reorderTodo(listId: String, todoId: String, order: Int) async throws(APIError) -> Bool {
        try await performVoid("PUT", "/api/todos/reorder/\(listId)",
                              body: ["todoId": todoId, "order": order])
    }
}

// MARK: - Location

extension APIClient {
    func setListLocation(
        listId: String,
        name: String?,
        latitude: Double,
        longitude: Double,
        radius: Double,
        trigger: GeofenceTrigger
    ) async throws(APIError) -> Bool {
        var body: [String: Any?] = [
            "locationLat": latitude,
            "locationLng": longitude,
            "locationRadius": radius,
            "locationTrigger": trigger.rawValue
        ]
        if let name, !name.isEmpty { body["locationName"] = name }
        return try await performVoid("PATCH", "/api/todos/\(listId)/location", body: body)
    }

    func clearListLocation(listId: String) async throws(APIError) -> Bool {
        try await performVoid("PATCH", "/api/todos/\(listId)/location",
                              body: ["locationLat": nil, "locationLng": nil,
                                     "locationRadius": nil, "locationTrigger": nil,
                                     "locationName": nil])
    }

    func fireLocationTrigger(listId: String, event: GeofenceTrigger) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/todos/\(listId)/location-trigger",
                              body: ["event": event.rawValue])
    }
}

// MARK: - Alarms

extension APIClient {
    func alarms() async throws(APIError) -> [Alarm] {
        try await perform("GET", "/api/alarms")
    }

    func createAlarm(
        at date: Date,
        label: String?,
        repeatRule: AlarmRepeat,
        listId: String?,
        todoId: String?,
        target: AlarmTarget?
    ) async throws(APIError) -> Alarm {
        var body: [String: Any?] = [
            "alarmAt": ISO8601DateFormatter.twodosOut.string(from: date),
            "label": label ?? "",
            "repeat": repeatRule.apiValue
        ]
        if let listId { body["listId"] = listId }
        if let todoId { body["todoId"] = todoId }
        if let target { body["target"] = target.apiValue }
        return try await perform("POST", "/api/alarms", body: body)
    }

    func deleteAlarm(id: String) async throws(APIError) -> Bool {
        try await performVoid("DELETE", "/api/alarms/\(id)")
    }

    func snoozeAlarm(id: String, minutes: Int) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/alarms/\(id)/snooze", body: ["minutes": minutes])
    }
}

// MARK: - Notifications, blocking, reports

extension APIClient {
    func notifications(unreadOnly: Bool = false) async throws(APIError) -> [AppNotification] {
        try await perform("GET", "/api/notifications",
                          query: unreadOnly ? ["unread": "true"] : nil)
    }

    func markNotificationRead(id: String) async throws(APIError) -> Bool {
        try await performVoid("PATCH", "/api/notifications/\(id)/read")
    }

    func markAllNotificationsRead() async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/notifications/read-all")
    }

    func blockedUserIds() async throws(APIError) -> [String] {
        try await perform("GET", "/api/block")
    }

    func block(userId: String) async throws(APIError) -> Bool {
        try await performVoid("POST", "/api/block/\(userId)")
    }

    func unblock(userId: String) async throws(APIError) -> Bool {
        try await performVoid("DELETE", "/api/block/\(userId)")
    }

    func report(userId: String, type: String, details: String?) async throws(APIError) -> Bool {
        var body: [String: Any?] = ["reportedId": userId, "reportType": type]
        if let details, !details.isEmpty { body["description"] = details }
        return try await performVoid("POST", "/api/reports", body: body)
    }
}

// MARK: - Decoding helpers

/// Accepts `true`, `"OK"`, a message string, or an object — every "it worked"
/// shape the API uses — and normalises them to `true`.
struct FlexibleTrue: Decodable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool; return }
        if (try? container.decode(String.self)) != nil { value = true; return }
        value = true
    }
}

/// `GET /api/account/partners` returns a bare array on some deployments and
/// `{ "partners": [...] }` on others. Both are accepted.
struct FlexibleArray<Element: Decodable>: Decodable {
    let values: [Element]
    init(from decoder: Decoder) throws {
        if let array = try? [Element](from: decoder) { values = array; return }
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys {
            if let array = try? container.decode([Element].self, forKey: key) {
                values = array
                return
            }
        }
        values = []
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Supplies a default for endpoints that answer 200 with no `data` at all.
enum EmptySuccess {
    static func value<T>(for type: T.Type) -> T? {
        if T.self == FlexibleTrue.self { return FlexibleTrue.trueValue as? T }
        return nil
    }
}

extension FlexibleTrue {
    static let trueValue: FlexibleTrue = {
        // Decoding `true` can never fail, so the force-unwrap is safe here.
        try! JSONDecoder().decode(FlexibleTrue.self, from: Data("true".utf8))
    }()
}

extension ISO8601DateFormatter {
    static let twodosFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let twodosPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// What the app sends. Always UTC, matching the Flutter client's
    /// `toUtc().toIso8601String()` so both clients agree on deadline instants.
    static let twodosOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
