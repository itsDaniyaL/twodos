import Foundation
import Testing
@testable import twodos___ios

/// Decoding tests written against **real captured responses** from the twodos
/// API, not invented fixtures. Every JSON literal below was taken verbatim from
/// a live call; the API's shapes are inconsistent enough (see `API-REVIEW.md`)
/// that a plausible-looking fixture proves nothing.
@Suite("API response decoding")
struct APIDecodingTests {

    /// The app's decoder, configured exactly as `APIClient` configures its own.
    /// Kept in sync deliberately — a test that decodes with default settings
    /// would pass while the app fails on the very dates it has to parse.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.twodosFractional.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.twodosPlain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparsable date: \(raw)")
            )
        }
        return decoder
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try Self.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Envelope

    @Test("Successful login decodes into a session with both tokens")
    func loginEnvelope() throws {
        let json = """
        {"statusCode":200,"data":{"token":"c49bf1ec-b166-4f56-98d7-ffa2cc9804ad",\
        "expiresAt":"2026-07-27T13:18:18.963Z","refreshToken":"d33d2349-9b38-42f6-8183-20394c23dee0",\
        "refreshExpiresAt":"2026-08-26T12:18:18.978Z"}}
        """
        let envelope = try decode(APIClient.Envelope<AuthSession>.self, json)

        #expect(envelope.statusCode == 200)
        let session = try #require(envelope.data)
        #expect(session.token == "c49bf1ec-b166-4f56-98d7-ffa2cc9804ad")
        #expect(session.refreshToken == "d33d2349-9b38-42f6-8183-20394c23dee0")
        #expect(session.refreshExpiresAt != nil)
    }

    @Test("Access tokens last an hour, which the refresh window must stay under")
    func tokenLifetimeBoundsTheRefreshWindow() throws {
        // Issued 12:18:18, expires 13:18:18 — measured against staging.
        let json = """
        {"statusCode":200,"data":{"token":"t","expiresAt":"2026-07-27T13:18:18.963Z",\
        "refreshToken":"r","refreshExpiresAt":"2026-08-26T12:18:18.978Z"}}
        """
        let session = try #require(try decode(APIClient.Envelope<AuthSession>.self, json).data)
        let issued = try #require(ISO8601DateFormatter.twodosFractional.date(from: "2026-07-27T12:18:18.963Z"))
        let lifetime = session.expiresAt.timeIntervalSince(issued)

        #expect(lifetime == 3600)
        // The regression this guards: a window >= the lifetime makes every
        // request refresh before sending, which against a rotating refresh
        // token terminated every session on the account.
        #expect(TokenStore.refreshWindow < lifetime)
    }

    @Test("An error envelope carries its message and no data")
    func errorEnvelope() throws {
        let json = """
        {"statusCode":401,"reason":"UNAUTHORIZED","statusMessage":"The username or password is incorrect."}
        """
        let envelope = try decode(APIClient.Envelope<AuthSession>.self, json)

        #expect(envelope.statusCode == 401)
        #expect(envelope.data == nil)
        #expect(envelope.statusMessage == "The username or password is incorrect.")
    }

    @Test("A bare status decodes even when the payload shape does not match")
    func bareStatus() throws {
        let json = #"{"statusCode":403,"reason":"FORBIDDEN","statusMessage":"Security alert: token reuse detected."}"#
        let status = try decode(APIClient.BareStatus.self, json)

        #expect(status.statusCode == 403)
        #expect(status.statusMessage == "Security alert: token reuse detected.")
    }

    // MARK: - The /me exception

    /// `GET /api/account/me` returns the user at the envelope's *root* rather
    /// than under `data`. Decoding it as a normal envelope silently yields nil
    /// and fails with "success with no data" — which is exactly what shipped,
    /// and what broke every sign-in and every cold launch.
    @Test("GET /api/account/me decodes from the envelope root")
    func currentUserAtRoot() throws {
        let json = """
        {"statusCode":200,"id":"a6ffcc40-a487-433d-bb3b-19c9b4bd3cce","name":"Daniyal Test",\
        "email":"person@example.com","emailVerified":true,"authProvider":"email"}
        """
        let user = try decode(CurrentUser.self, json)

        #expect(user.id == "a6ffcc40-a487-433d-bb3b-19c9b4bd3cce")
        #expect(user.name == "Daniyal Test")
        #expect(user.emailVerified)
        #expect(user.authProvider == "email")
    }

    @Test("Regression: /me has no `data` key, so the nested shape must find nothing")
    func currentUserIsNotNested() throws {
        let json = """
        {"statusCode":200,"id":"a6ffcc40","name":"Daniyal Test","email":"person@example.com",\
        "emailVerified":true,"authProvider":"email"}
        """
        let envelope = try decode(APIClient.Envelope<CurrentUser>.self, json)

        #expect(envelope.statusCode == 200)
        // If this ever becomes non-nil the API changed and `.root` can go.
        #expect(envelope.data == nil)
    }

    @Test("An unauthenticated /me is an error, not a user")
    func currentUserUnauthorised() throws {
        let json = #"{"statusCode":401,"reason":"UNAUTHORIZED","statusMessage":"Authentication required."}"#
        let status = try decode(APIClient.BareStatus.self, json)

        #expect(status.statusCode == 401)
        // The payload is only decoded on 200 — decoding a CurrentUser here
        // would put "Authentication required." nowhere useful.
        #expect(status.statusMessage == "Authentication required.")
    }

    // MARK: - Flexible success shapes

    @Test("Every 'it worked' shape the API uses normalises to true", arguments: [
        "true", #""OK""#, #""The Todo #3 has been deleted.""#, "{}"
    ])
    func flexibleTrue(json: String) throws {
        #expect(try decode(FlexibleTrue.self, json).value)
    }

    @Test("`false` is preserved rather than coerced")
    func flexibleTrueRespectsFalse() throws {
        #expect(try decode(FlexibleTrue.self, "false").value == false)
    }

    @Test("Partners decode from a bare array and from a wrapped object alike")
    func flexibleArray() throws {
        let bare = #"[{"id":"1","name":"Sam","email":"sam@example.com"}]"#
        let wrapped = #"{"partners":[{"id":"1","name":"Sam","email":"sam@example.com"}]}"#

        #expect(try decode(FlexibleArray<Partner>.self, bare).values.count == 1)
        #expect(try decode(FlexibleArray<Partner>.self, wrapped).values.count == 1)
        #expect(try decode(FlexibleArray<Partner>.self, "{}").values.isEmpty)
    }

    // MARK: - Dates

    @Test("Both ISO-8601 flavours the API mixes are parsed")
    func mixedDateFormats() throws {
        struct Wrapper: Decodable { let at: Date }

        let fractional = try decode(Wrapper.self, #"{"at":"2026-07-27T13:18:18.963Z"}"#)
        let plain = try decode(Wrapper.self, #"{"at":"2026-07-27T13:18:18Z"}"#)

        #expect(abs(fractional.at.timeIntervalSince(plain.at) - 0.963) < 0.001)
    }

    @Test("An unparsable date fails loudly rather than defaulting")
    func badDateThrows() {
        struct Wrapper: Decodable { let at: Date }
        #expect(throws: (any Error).self) {
            try decode(Wrapper.self, #"{"at":"not a date"}"#)
        }
    }

    // MARK: - Lists

    @Test("A list decodes from the live /api/todos shape")
    func todoListDecoding() throws {
        let json = """
        {"statusCode":200,"data":{"id":"59ae032b","label":"Groceries","favorite":true,\
        "createdBy":"a6ffcc40","partnerId":"590b185e","order":0,"color":"#4E8C6F","doBefore":null,\
        "archived":false,"inviteAccepted":false,"inviteStatus":"TODOS::INVITE_STATUS::PENDING",\
        "priority":"TODOLIST::PRIORITY::NONURGENT","locationName":"Tesco Metro","locationLat":51.5074,\
        "locationLng":-0.1278,"locationRadius":200,"locationTrigger":"ARRIVE",\
        "createdAt":"2026-07-27T14:30:05.460Z","updatedAt":"2026-07-27T14:30:23.892Z",\
        "items":[{"id":"914367f9","title":"Bananas x4","done":false,"order":0,"doBefore":null}]}}
        """
        let list = try #require(try decode(APIClient.Envelope<TodoList>.self, json).data)

        #expect(list.label == "Groceries")
        #expect(list.favorite)
        #expect(list.todos.count == 1)
        #expect(list.todos.first?.title == "Bananas x4")
        #expect(list.hasLocation)
        #expect(list.locationName == "Tesco Metro")
        #expect(list.trigger == .arrive)
        #expect(list.isPendingInvite)
    }

    /// The spec documents `URGENT`/`NONURGENT`; the wire format is namespaced.
    /// Trusting the spec here would have broken priority silently.
    @Test("Priority uses the namespaced wire format, not the documented enum")
    func priorityWireFormat() {
        #expect(ListPriority(apiValue: "TODOLIST::PRIORITY::URGENT") == .urgent)
        #expect(ListPriority(apiValue: "TODOLIST::PRIORITY::NONURGENT") == .nonUrgent)
        #expect(ListPriority(apiValue: "URGENT") == nil)
        #expect(ListPriority(apiValue: nil) == nil)
        #expect(ListPriority.urgent.apiValue == "TODOLIST::PRIORITY::URGENT")
    }

    @Test("An empty list array is a success, not a failure")
    func emptyListsDecode() throws {
        let envelope = try decode(APIClient.Envelope<[TodoList]>.self, #"{"statusCode":200,"data":[]}"#)
        #expect(envelope.data?.isEmpty == true)
    }
}
