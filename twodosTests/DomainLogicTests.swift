import Foundation
import Testing
@testable import twodos_ios

@Suite("Geofence crossings")
struct GeofenceTransitionTests {

    /// `CLMonitor` reports *state*, not transitions, and emits an event the
    /// moment a fence is first evaluated. Mapping state straight to a crossing
    /// announced "Leaving Tesco" on every launch while standing at home.
    @Test("The first sighting of a fence is a baseline, not a crossing")
    func firstSightingIsSilent() {
        #expect(GeofenceTransition.resolve(previous: nil, current: false) == .baseline)
        #expect(GeofenceTransition.resolve(previous: nil, current: true) == .baseline)
    }

    @Test("Re-reporting the same state is not a crossing")
    func resyncIsSilent() {
        #expect(GeofenceTransition.resolve(previous: false, current: false) == .unchanged)
        #expect(GeofenceTransition.resolve(previous: true, current: true) == .unchanged)
    }

    @Test("Outside to inside arrives; inside to outside leaves")
    func genuineCrossings() {
        #expect(GeofenceTransition.resolve(previous: false, current: true) == .crossed(.arrive))
        #expect(GeofenceTransition.resolve(previous: true, current: false) == .crossed(.leave))
    }

    /// The reason the previous state is persisted rather than held in memory:
    /// the app is routinely relaunched from cold *by* the crossing it must
    /// report, so an in-memory baseline would be empty at exactly that moment
    /// and swallow the real event.
    @Test("A cold background relaunch still reports the crossing that woke it")
    func coldRelaunchStillFires() {
        let storedFromLastRun = false // was outside when the app was last alive
        #expect(GeofenceTransition.resolve(previous: storedFromLastRun, current: true) == .crossed(.arrive))
    }
}

@Suite("List colours")
struct ListTintTests {

    @Test("Every palette entry has a distinct, well-formed hex")
    func paletteIsWellFormed() {
        let hexes = ListTint.all.map(\.hex)
        #expect(Set(hexes).count == hexes.count)
        for hex in hexes {
            #expect(hex.hasPrefix("#"))
            #expect(hex.count == 7)
            #expect(UInt32(hex.dropFirst(), radix: 16) != nil)
        }
    }

    @Test("A known hex resolves to its named tint regardless of case or #")
    func resolvesKnownHex() {
        let indigo = ListTint.all[1]
        #expect(ListTint.resolve(indigo.hex).hex == indigo.hex)
        #expect(ListTint.resolve(indigo.hex.lowercased()).hex == indigo.hex)
        #expect(ListTint.resolve(String(indigo.hex.dropFirst())).hex == indigo.hex)
    }

    @Test("A missing colour falls back to the first tint rather than failing")
    func resolvesMissing() {
        #expect(ListTint.resolve(nil).hex == ListTint.all[0].hex)
        #expect(ListTint.resolve("").hex == ListTint.all[0].hex)
    }

    /// Another client may set a colour this build has never heard of. Honouring
    /// it verbatim beats snapping every unknown list to grey.
    @Test("An unknown colour from another client is honoured verbatim")
    func resolvesUnknownHex() {
        let custom = ListTint.resolve("#123456")
        #expect(custom.hex == "#123456")
        #expect(custom.name == "Custom")
    }

    /// The palette was re-tuned for the calmer reference hues. The `hex` keys
    /// are the server's identity for a colour and deliberately did *not*
    /// change, so lists already coloured keep their identity — re-keying them
    /// would drop every existing list into the `Custom` branch above and freeze
    /// it on the old tones.
    @Test("Retuning the palette did not change the server-facing keys")
    func hexKeysAreStable() {
        #expect(ListTint.all.map(\.hex) == [
            "#7A7A7A", "#504E8C", "#875353", "#9D8C57",
            "#7A588A", "#4E8C6F", "#4E6E8C", "#8C4E4E"
        ])
    }
}

@Suite("Watch payload")
struct WatchPayloadTests {

    /// Fixtures are built by decoding JSON rather than by a memberwise
    /// initialiser — `TodoList` only has a decoding init, and going through it
    /// means these tests exercise the same path the API does.
    private func list(
        id: String = "1",
        label: String = "Groceries",
        archived: Bool = false,
        inviteStatus: String? = nil,
        createdBy: String = "me",
        partnerId: String? = nil,
        locationName: String? = nil,
        pinned: Bool = false,
        favorite: Bool = false,
        items: [(id: String, title: String, done: Bool, order: Int)] = []
    ) -> TodoList {
        var fields: [String: Any] = [
            "id": id, "label": label, "favorite": favorite, "archived": archived,
            "color": "#4E8C6F", "createdBy": createdBy, "order": 0,
            "items": items.map {
                ["id": $0.id, "title": $0.title, "done": $0.done, "order": $0.order]
            }
        ]
        if let inviteStatus { fields["inviteStatus"] = inviteStatus }
        if let partnerId { fields["partnerId"] = partnerId }
        if let locationName { fields["locationName"] = locationName }
        if pinned {
            fields["locationLat"] = 51.5074
            fields["locationLng"] = -0.1278
            fields["locationRadius"] = 200
            fields["locationTrigger"] = "ARRIVE"
        }

        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! APIDecodingTests.decoder().decode(TodoList.self, from: data)
    }

    @Test("Archived lists never reach the wrist")
    func dropsArchived() {
        let snapshot = WatchList.snapshot(
            from: [list(id: "a", archived: true), list(id: "b")],
            currentUserId: "me"
        )
        #expect(snapshot.map(\.id) == ["b"])
    }

    @Test("An invitation someone else sent is not actionable from the wrist")
    func dropsUnansweredInvites() {
        let invited = list(
            id: "a",
            inviteStatus: APIConstants.InviteStatus.pending,
            createdBy: "someone-else",
            partnerId: "me"
        )
        let snapshot = WatchList.snapshot(from: [invited, list(id: "b")], currentUserId: "me")
        #expect(snapshot.map(\.id) == ["b"])
    }

    @Test("The partner is sent as a name, because the watch has no directory")
    func resolvesPartnerName() {
        let shared = list(id: "a", partnerId: "p1")
        let snapshot = WatchList.snapshot(
            from: [shared],
            currentUserId: "me",
            partnerNames: ["p1": "Sam Okafor"]
        )
        #expect(snapshot.first?.isShared == true)
        #expect(snapshot.first?.partnerName == "Sam Okafor")
    }

    @Test("A personal list carries no partner name even if an id lingers")
    func personalListHasNoPartnerName() {
        let personal = list(id: "a", partnerId: "me")
        let snapshot = WatchList.snapshot(
            from: [personal],
            currentUserId: "me",
            partnerNames: ["me": "Myself"]
        )
        #expect(snapshot.first?.partnerName == nil)
    }

    @Test("The place is phrased on the phone, ready to draw")
    func buildsLocationLabel() {
        let pinned = list(id: "a", locationName: "Tesco Metro", pinned: true)
        let snapshot = WatchList.snapshot(from: [pinned], currentUserId: "me")
        #expect(snapshot.first?.locationLabel == "Arrive at Tesco Metro")
    }

    @Test("A list with no place set sends no label")
    func noLocationNoLabel() {
        let snapshot = WatchList.snapshot(from: [list(id: "a")], currentUserId: "me")
        #expect(snapshot.first?.locationLabel == nil)
    }

    @Test("The tint survives the trip as an index into the shared palette")
    func tintIndexRoundTrips() {
        let snapshot = WatchList.snapshot(from: [list(id: "a")], currentUserId: "me")
        let index = try? #require(snapshot.first?.tintIndex)
        #expect(ListTint.all[index ?? -1].hex == "#4E8C6F")
    }

    @Test("Open items sort ahead of completed ones")
    func openItemsFirst() {
        let items = [
            (id: "1", title: "done", done: true, order: 0),
            (id: "2", title: "open", done: false, order: 1)
        ]
        let snapshot = WatchList.snapshot(from: [list(id: "a", items: items)], currentUserId: "me")
        #expect(snapshot.first?.items.first?.title == "open")
        #expect(snapshot.first?.openCount == 1)
        #expect(snapshot.first?.doneCount == 1)
    }

    /// A watch on the previous build must still decode a payload from a newer
    /// phone rather than dropping every list, which is why the added fields are
    /// optional with defaults.
    @Test("A payload without the newer fields still decodes")
    func decodesLegacyPayload() throws {
        let json = """
        {"id":"1","label":"Groceries","tintIndex":0,"items":[],"dueAt":null,\
        "isShared":false,"isFavorite":false}
        """
        let list = try JSONDecoder().decode(WatchList.self, from: Data(json.utf8))
        #expect(list.partnerName == nil)
        #expect(list.locationLabel == nil)
    }
}

@Suite("Errors surfaced to the user")
struct APIErrorTests {

    @Test("Offline is the only retryable failure worth a button")
    func retryability() {
        #expect(APIError.offline.isRetryable)
        #expect(APIError.unknown.isRetryable)
        #expect(!APIError.unauthorized.isRetryable)
        #expect(!APIError.server("nope").isRetryable)
    }

    @Test("A server message is shown verbatim, because the API writes decent ones")
    func serverMessagePassesThrough() {
        #expect(APIError.server("That email is already in use.").errorDescription
                == "That email is already in use.")
    }

    @Test("The invite-completion hint keys off the message the API actually sends")
    func detectsInviteHint() {
        let invited = APIError.server("This email was invited to the platform.")
        #expect(invited.suggestsInviteCompletion)
        #expect(!APIError.server("The username or password is incorrect.").suggestsInviteCompletion)
    }

    /// The verification hint cannot fire for a bad-credentials 401 — the API
    /// returns byte-identical responses for "wrong password" and "email not
    /// verified", which is why the sign-in screen offers the route after *any*
    /// failure rather than trying to detect it.
    @Test("An unverified account is indistinguishable from a wrong password")
    func cannotDetectUnverifiedEmail() {
        let asReturnedForBoth = APIError.server("The username or password is incorrect.")
        #expect(!asReturnedForBoth.suggestsEmailVerification)
    }
}
