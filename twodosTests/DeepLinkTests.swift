import Foundation
import Testing
@testable import twodos___ios

/// The `twodos://` contract, tested from both ends.
///
/// A widget emits these URLs from a different process; the app parses them. If
/// the two ever disagree the symptom is a widget that simply does nothing when
/// tapped — no crash, no log, nothing to notice until a user complains. So the
/// round trip is pinned here.
@Suite("Deep links")
struct DeepLinkTests {

    @Test("Every link the widgets emit parses back to itself")
    func roundTrips() {
        let links: [DeepLink] = [
            .list(id: "abc123"),
            .list(id: "550e8400-e29b-41d4-a716-446655440000"),
            .lists
        ]
        for link in links {
            #expect(DeepLink(url: link.url) == link, "Failed round trip for \(link)")
        }
    }

    @Test("The scheme is the one registered in both apps' Info.plist")
    func usesRegisteredScheme() {
        #expect(DeepLink.list(id: "x").url.scheme == "twodos")
        #expect(DeepLink.scheme == "twodos")
    }

    @Test("Both host and triple-slash spellings are accepted")
    func toleratesBothShapes() {
        #expect(DeepLink(url: URL(string: "twodos://list/abc")!) == .list(id: "abc"))
        #expect(DeepLink(url: URL(string: "twodos:///list/abc")!) == .list(id: "abc"))
        #expect(DeepLink(url: URL(string: "twodos://lists")!) == .lists)
    }

    @Test("Case in the host does not decide whether a tap works")
    func hostIsCaseInsensitive() {
        #expect(DeepLink(url: URL(string: "twodos://LIST/abc")!) == .list(id: "abc"))
        #expect(DeepLink(url: URL(string: "TWODOS://list/abc")!) == .list(id: "abc"))
    }

    @Test("A list id is preserved verbatim, case included")
    func preservesIdentifierCase() {
        // List ids come from the server and are compared with `==` against the
        // model, so lowercasing one here would silently open nothing.
        #expect(DeepLink(url: URL(string: "twodos://list/AbC-123")!) == .list(id: "AbC-123"))
    }

    @Test("Anything that is not ours is rejected rather than guessed at")
    func rejectsForeignURLs() {
        let rejected = [
            "https://twodos.app/list/abc",
            "twodos://",
            "twodos://list",
            "twodos://list/",
            "twodos://nonsense/abc",
            "otherapp://list/abc"
        ]
        for raw in rejected {
            #expect(DeepLink(url: URL(string: raw)!) == nil, "Should not have parsed \(raw)")
        }
    }
}
