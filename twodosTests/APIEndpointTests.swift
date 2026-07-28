import Foundation
import Testing
@testable import twodos___ios

/// Live integration tests against a real twodos deployment.
///
/// These hit the network, so they are **disabled by default** — a unit suite
/// that fails because the office wifi dropped trains people to ignore red.
/// Enable by setting `TWODOS_TEST_BASE_URL` (and, for the authenticated suite,
/// `TWODOS_TEST_EMAIL` / `TWODOS_TEST_PASSWORD`) in the scheme's Test action.
///
/// **Point these at staging.** They register accounts, create lists and delete
/// them again; running them against production would leave real debris in a
/// real database.
///
/// What they are for: the app's decoding is only correct relative to what the
/// server actually sends, and this API's shapes are inconsistent enough that
/// the only honest check is to ask it. Every assertion below is about a
/// *shape* the client depends on, not about business logic.
@Suite("API endpoints (live)", .enabled(if: LiveAPI.isConfigured))
struct APIEndpointTests {

    // MARK: - Unauthenticated

    @Test("Login rejects bad credentials with a 401 envelope and a message")
    func loginRejectsBadCredentials() async throws {
        let body = try await LiveAPI.post("/api/account/login", [
            "email": "definitely-not-a-user@example.invalid",
            "password": "wrong",
            "platform": APIConstants.platform
        ])

        #expect(body["statusCode"] as? Int == 401)
        // The client shows this verbatim, so it must exist and be non-empty.
        let message = try #require(body["statusMessage"] as? String)
        #expect(!message.isEmpty)
    }

    /// The envelope is the whole reason `APIClient` ignores `URLResponse`.
    @Test("Every response is HTTP 200 with the real status in the body")
    func envelopeAlwaysReturns200() async throws {
        let (body, http) = try await LiveAPI.postRaw("/api/account/login", [
            "email": "definitely-not-a-user@example.invalid",
            "password": "wrong",
            "platform": APIConstants.platform
        ])

        #expect(http.statusCode == 200)
        #expect(body["statusCode"] as? Int == 401)
    }

    @Test("An unauthenticated /me is a 401 envelope, not a user")
    func meRequiresAuth() async throws {
        let body = try await LiveAPI.get("/api/account/me", token: nil)
        #expect(body["statusCode"] as? Int == 401)
    }

    @Test("A garbage bearer token is rejected the same way as none at all")
    func garbageTokenRejected() async throws {
        let body = try await LiveAPI.get("/api/account/me", token: "00000000-0000-0000-0000-000000000000")
        #expect(body["statusCode"] as? Int == 401)
    }

    @Test("A spent refresh token is refused")
    func invalidRefreshTokenRefused() async throws {
        let body = try await LiveAPI.post("/api/account/refresh", [
            "refreshToken": "00000000-0000-0000-0000-000000000000",
            "platform": APIConstants.platform
        ])
        #expect(body["statusCode"] as? Int == 401)
    }

    // MARK: - Authenticated

    @Test("Login issues a session the client can decode", .enabled(if: LiveAPI.hasCredentials))
    func loginIssuesDecodableSession() async throws {
        let data = try await LiveAPI.loginRaw()
        let session = try APIDecodingTests.decoder().decode(AuthSession.self, from: data)

        #expect(!session.token.isEmpty)
        #expect(session.expiresAt > .now)
        // Password login must return a refresh token; OTP login is the one that
        // does not, and a session without one silently cannot be renewed.
        #expect(session.refreshToken != nil)
    }

    /// Access tokens live exactly an hour. `TokenStore.refreshWindow` has to
    /// stay under that — when it did not, every request refreshed before
    /// sending and the rotating refresh token terminated every session.
    @Test("The access token's lifetime still exceeds the refresh window", .enabled(if: LiveAPI.hasCredentials))
    func tokenLifetimeExceedsRefreshWindow() async throws {
        let data = try await LiveAPI.loginRaw()
        let session = try APIDecodingTests.decoder().decode(AuthSession.self, from: data)
        let remaining = session.expiresAt.timeIntervalSinceNow

        #expect(remaining > TokenStore.refreshWindow,
                "A freshly issued token must not already be inside the refresh window.")
    }

    @Test("GET /api/account/me returns the user at the envelope root", .enabled(if: LiveAPI.hasCredentials))
    func meReturnsUserAtRoot() async throws {
        let token = try await LiveAPI.token()
        let (body, _) = try await LiveAPI.getRaw("/api/account/me", token: token)

        #expect(body["statusCode"] as? Int == 200)
        // The shape the client special-cases: fields beside `statusCode`, and
        // no `data` key at all. If this ever gains one, `.root` can be dropped.
        #expect(body["data"] == nil)
        #expect(body["id"] is String)
        #expect(body["email"] is String)
    }

    @Test("Collection endpoints answer with data arrays", .enabled(if: LiveAPI.hasCredentials),
          arguments: ["/api/todos", "/api/alarms", "/api/notifications", "/api/block"])
    func collectionsReturnArrays(path: String) async throws {
        let token = try await LiveAPI.token()
        let body = try await LiveAPI.get(path, token: token)

        #expect(body["statusCode"] as? Int == 200)
        #expect(body["data"] is [Any], "\(path) should answer with an array under `data`.")
    }

    @Test("Partners tolerate both documented shapes", .enabled(if: LiveAPI.hasCredentials))
    func partnersDecodeEitherShape() async throws {
        let token = try await LiveAPI.token()
        let (_, data) = try await LiveAPI.getData("/api/account/partners", token: token)

        // Whichever shape this deployment uses, the client's decoder copes.
        let envelope = try APIDecodingTests.decoder()
            .decode(APIClient.Envelope<FlexibleArray<Partner>>.self, from: data)
        #expect(envelope.statusCode == 200)
        #expect(envelope.data != nil)
    }

    /// The full lifecycle, so a shape change in any step fails loudly.
    @Test("A list can be created, read, mutated and deleted", .enabled(if: LiveAPI.hasCredentials))
    func listLifecycle() async throws {
        let token = try await LiveAPI.token()
        let label = "twodos test \(UUID().uuidString.prefix(8))"

        let created = try await LiveAPI.post("/api/todos", ["label": label, "favorite": false], token: token)
        #expect(created["statusCode"] as? Int == 200)

        let listed = try await LiveAPI.get("/api/todos", token: token)
        let lists = try #require(listed["data"] as? [[String: Any]])
        let made = try #require(lists.first { $0["label"] as? String == label })
        let id = try #require(made["id"] as? String)

        defer { Task { _ = try? await LiveAPI.delete("/api/todos/\(id)", token: token) } }

        // Colour is stored and echoed as the hex the client sends.
        let hex = ListTint.all[1].hex
        _ = try await LiveAPI.put("/api/todos/\(id)/color", ["color": hex], token: token)

        let item = try await LiveAPI.post("/api/todos/\(id)", ["title": "Bananas", "done": false], token: token)
        #expect(item["statusCode"] as? Int == 200)

        let (_, detail) = try await LiveAPI.getData("/api/todos/\(id)", token: token)
        let list = try #require(
            try APIDecodingTests.decoder().decode(APIClient.Envelope<TodoList>.self, from: detail).data
        )
        #expect(list.label == label)
        #expect(list.tint.hex.uppercased() == hex.uppercased())
        #expect(list.todos.contains { $0.title == "Bananas" })

        let deleted = try await LiveAPI.delete("/api/todos/\(id)", token: token)
        #expect(deleted["statusCode"] as? Int == 200)
    }

    @Test("A geofence survives a round trip intact", .enabled(if: LiveAPI.hasCredentials))
    func locationRoundTrip() async throws {
        let token = try await LiveAPI.token()
        let label = "twodos geo \(UUID().uuidString.prefix(8))"
        _ = try await LiveAPI.post("/api/todos", ["label": label, "favorite": false], token: token)

        let lists = try #require(try await LiveAPI.get("/api/todos", token: token)["data"] as? [[String: Any]])
        let id = try #require(lists.first { $0["label"] as? String == label }?["id"] as? String)
        defer { Task { _ = try? await LiveAPI.delete("/api/todos/\(id)", token: token) } }

        _ = try await LiveAPI.patch("/api/todos/\(id)/location", [
            "locationLat": 51.5074, "locationLng": -0.1278,
            "locationRadius": 200, "locationTrigger": GeofenceTrigger.arrive.rawValue,
            "locationName": "Tesco Metro"
        ], token: token)

        let (_, data) = try await LiveAPI.getData("/api/todos/\(id)", token: token)
        let list = try #require(
            try APIDecodingTests.decoder().decode(APIClient.Envelope<TodoList>.self, from: data).data
        )

        // Every field the geofence registration depends on must come back, or
        // `syncGeofences` silently monitors nothing.
        #expect(list.hasLocation)
        #expect(list.locationName == "Tesco Metro")
        #expect(list.locationLat != nil)
        #expect(list.locationLng != nil)
        #expect(list.locationRadius == 200)
        #expect(list.trigger == .arrive)
    }
}

// MARK: - Live client

/// A deliberately tiny HTTP client. It does **not** reuse `APIClient` — these
/// tests exist to check what the server sends, and running them through the
/// same decoding layer they are meant to validate would hide exactly the
/// mismatches they are looking for.
enum LiveAPI {
    static var baseURL: URL? {
        ProcessInfo.processInfo.environment["TWODOS_TEST_BASE_URL"].flatMap(URL.init(string:))
    }
    static var isConfigured: Bool { baseURL != nil }

    static var credentials: (email: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["TWODOS_TEST_EMAIL"], let password = env["TWODOS_TEST_PASSWORD"] else {
            return nil
        }
        return (email, password)
    }
    static var hasCredentials: Bool { isConfigured && credentials != nil }

    private static let session = URLSession(configuration: .ephemeral)

    // MARK: Requests

    private static func request(
        _ method: String,
        _ path: String,
        _ body: [String: Any]?,
        token: String?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let baseURL else { throw LiveAPIError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func get(_ path: String, token: String?) async throws -> [String: Any] {
        try json(try await request("GET", path, nil, token: token).0)
    }
    static func getRaw(_ path: String, token: String?) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, http) = try await request("GET", path, nil, token: token)
        return (try json(data), http)
    }
    static func getData(_ path: String, token: String?) async throws -> ([String: Any], Data) {
        let (data, _) = try await request("GET", path, nil, token: token)
        return (try json(data), data)
    }
    static func post(_ path: String, _ body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        try json(try await request("POST", path, body, token: token).0)
    }
    static func postRaw(_ path: String, _ body: [String: Any]) async throws -> ([String: Any], HTTPURLResponse) {
        let (data, http) = try await request("POST", path, body, token: nil)
        return (try json(data), http)
    }
    static func put(_ path: String, _ body: [String: Any], token: String?) async throws -> [String: Any] {
        try json(try await request("PUT", path, body, token: token).0)
    }
    static func patch(_ path: String, _ body: [String: Any], token: String?) async throws -> [String: Any] {
        try json(try await request("PATCH", path, body, token: token).0)
    }
    static func delete(_ path: String, token: String?) async throws -> [String: Any] {
        try json(try await request("DELETE", path, nil, token: token).0)
    }

    // MARK: Session

    /// The raw `data` object from a login, for decoding as `AuthSession`.
    static func loginRaw() async throws -> Data {
        guard let credentials else { throw LiveAPIError.noCredentials }
        let (data, _) = try await request("POST", "/api/account/login", [
            "email": credentials.email,
            "password": credentials.password,
            "platform": APIConstants.platform
        ], token: nil)

        let body = try json(data)
        guard body["statusCode"] as? Int == 200, let payload = body["data"] else {
            throw LiveAPIError.loginFailed(body["statusMessage"] as? String ?? "unknown")
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// One login per test run. Logging in per test would burn through the
    /// endpoint's rate limit (10 per 15 minutes) long before the suite finished.
    private static let sharedToken = SharedToken()

    static func token() async throws -> String {
        try await sharedToken.value()
    }

    private actor SharedToken {
        private var cached: String?

        func value() async throws -> String {
            if let cached { return cached }
            let session = try JSONDecoder().decode(
                LoginPayload.self, from: try await LiveAPI.loginRaw()
            )
            cached = session.token
            return session.token
        }

        private struct LoginPayload: Decodable { let token: String }
    }
}

enum LiveAPIError: Error {
    case notConfigured
    case noCredentials
    case loginFailed(String)
}
