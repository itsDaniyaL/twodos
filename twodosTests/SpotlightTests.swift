import Foundation
import Testing
@testable import twodos___ios

/// Turning a tapped Spotlight result back into a destination.
///
/// This fails silently when it is wrong: the result appears in search, the user
/// taps it, and the app opens on whatever screen it was already showing. There
/// is nothing to see in a log and nothing for the user to report beyond "search
/// doesn't work properly".
@Suite("Spotlight results")
struct SpotlightTests {

    private func link(_ identifier: String) -> DeepLink? {
        SpotlightIndexer.deepLink(forSearchableItemID: identifier)
    }

    @Test("A list result opens that list")
    func listResultResolves() {
        let id = DeepLink.list(id: "abc123").url.absoluteString
        #expect(link(id) == .list(id: "abc123"))
    }

    @Test("An item result opens the list the item lives in")
    func itemResultResolvesToItsList() {
        // Items are indexed as the list's URL with the item id appended, because
        // opening a list is the only destination the app has — there is no
        // screen for a single item.
        let id = "\(DeepLink.list(id: "abc123").url.absoluteString)#todo-42"
        #expect(link(id) == .list(id: "abc123"))
    }

    @Test("The item suffix does not leak into the list id")
    func suffixIsStripped() {
        let resolved = link("twodos://list/abc123#todo-42")
        // If the `#` were kept, the id would not match any list and the tap
        // would open nothing.
        #expect(resolved == .list(id: "abc123"))
        #expect(resolved != .list(id: "abc123#todo-42"))
    }

    @Test("An id containing more than one hash still resolves")
    func multipleHashesAreSafe() {
        // Server ids are UUIDs today, but nothing in the identifier format
        // guarantees an item id has no `#` in it.
        #expect(link("twodos://list/abc#todo#weird") == .list(id: "abc"))
    }

    @Test("A stale identifier from an older build is rejected, not guessed at")
    func rubbishIsRejected() {
        #expect(link("not-a-url at all") == nil)
        #expect(link("https://twodos.app/list/abc") == nil)
        #expect(link("") == nil)
    }
}
