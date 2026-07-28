import Foundation
import SwiftUI
import Testing
@testable import twodos___ios

/// The rules that keep per-item location reminders off the battery.
///
/// Once individual items can be pinned, the obvious implementation — one region
/// per item — breaks against the 20-region iOS cap and wakes the app once per
/// item at a place. The fix is that regions are keyed by *place*, so these tests
/// guard the property the whole feature rests on: **two pins at the same place
/// are one fence.**
@Suite("Place-keyed geofences")
struct PlaceFenceTests {

    private func id(_ lat: Double, _ lng: Double, radius: Double = 200) -> String {
        LocationService.placeIdentifier(lat: lat, lng: lng, radius: radius)
    }

    // MARK: - Coalescing

    @Test("Two items pinned at the identical coordinate share one fence")
    func identicalCoordinatesCoalesce() {
        // The common case: both pins came from the same map search result.
        #expect(id(51.5074, -0.1278) == id(51.5074, -0.1278))
    }

    @Test("Hand-dropped pins a few metres apart still share one fence")
    func nearbyPinsCoalesce() {
        // ~5 m apart. Two people pinning the same shop by eye should not cost
        // two regions.
        #expect(id(51.50740, -0.12780) == id(51.507404, -0.127803))
    }

    @Test("Genuinely different places stay separate")
    func distinctPlacesDoNotCoalesce() {
        // ~1 km apart.
        #expect(id(51.5074, -0.1278) != id(51.5164, -0.1300))
    }

    @Test("The same place at a different radius is a different region")
    func radiusIsPartOfIdentity() {
        // Two reminders at one shop with different radii really are two
        // different regions — merging them would fire one of them at the wrong
        // distance.
        #expect(id(51.5074, -0.1278, radius: 100) != id(51.5074, -0.1278, radius: 500))
    }

    // MARK: - Identifier safety

    @Test("Identifiers survive negative coordinates")
    func handlesSouthAndWest() {
        let southWest = id(-33.8688, -151.2093)
        #expect(!southWest.isEmpty)
        #expect(southWest != id(33.8688, 151.2093), "Hemisphere must not be lost")
    }

    @Test("Identifiers contain nothing CoreLocation might reject")
    func identifierIsSafe() {
        // `CLMonitor` rejected its own monitor name for containing dots, and the
        // failure was silent — every `add` did nothing and no fence ever fired.
        // No reason to discover the hard way whether condition identifiers are
        // validated the same way.
        let samples = [id(51.5074, -0.1278), id(-33.8688, 151.2093), id(0, 0, radius: 100)]
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        for sample in samples {
            #expect(sample.allSatisfy { allowed.contains($0) }, "Unsafe identifier: \(sample)")
        }
    }

    @Test("Identifiers are stable across calls, so a resync is not a re-register")
    func identifierIsStable() {
        // If this drifted, every sync would tear down and rebuild every region.
        #expect(id(51.5074, -0.1278) == id(51.5074, -0.1278))
    }

    // MARK: - Direction filtering

    private func target(
        _ label: String,
        trigger: GeofenceTrigger,
        listId: String = "l1",
        todoId: String? = "t1",
        shared: Bool = false
    ) -> GeofenceFact.Target {
        GeofenceFact.Target(
            listId: listId, todoId: todoId, label: label, listLabel: "Groceries",
            triggerValue: trigger.rawValue, notifiesPartner: shared
        )
    }

    @Test("Arriving somewhere that only holds 'when I leave' reminders says nothing")
    func directionIsRespected() {
        let fact = GeofenceFact(placeName: "Office", targets: [target("Drop the keys", trigger: .leave)])
        #expect(fact.targets(matching: .arrive).isEmpty)
        #expect(fact.targets(matching: .leave).count == 1)
    }

    @Test("A place can hold reminders in both directions")
    func bothDirectionsAtOnePlace() {
        let fact = GeofenceFact(placeName: "Office", targets: [
            target("Badge in", trigger: .arrive),
            target("Drop the keys", trigger: .leave)
        ])
        #expect(fact.targets(matching: .arrive).map(\.label) == ["Badge in"])
        #expect(fact.targets(matching: .leave).map(\.label) == ["Drop the keys"])
    }

    // MARK: - One place, one notification

    private func crossing(_ targets: [GeofenceFact.Target], place: String? = "Tesco Metro") -> GeofenceCrossing {
        GeofenceCrossing(placeId: "p_1_1_200", placeName: place, trigger: .arrive, targets: targets)
    }

    @Test("A single item is named")
    func singleItemIsNamed() {
        let body = AppStore.crossingBody(crossing([target("Oat milk", trigger: .arrive)]))
        #expect(body == "Oat milk · Groceries")
    }

    @Test("A whole-list reminder does not repeat its own name")
    func listReminderDoesNotRepeatItself() {
        let body = AppStore.crossingBody(crossing([
            target("Groceries", trigger: .arrive, todoId: nil)
        ]))
        #expect(body == "Groceries")
    }

    @Test("Four items at one shop is one notification, not four")
    func manyItemsCollapseToACount() {
        let body = AppStore.crossingBody(crossing([
            target("Oat milk", trigger: .arrive),
            target("Bread", trigger: .arrive),
            target("Coffee", trigger: .arrive),
            target("Washing up liquid", trigger: .arrive)
        ]))
        // Listing four titles on a banner is unreadable; the count is the point.
        #expect(body == "4 things to do · Groceries")
    }

    @Test("Items from different lists at one place say so")
    func spansMultipleLists() {
        let body = AppStore.crossingBody(crossing([
            target("Oat milk", trigger: .arrive, listId: "l1"),
            target("Stamps", trigger: .arrive, listId: "l2")
        ]))
        #expect(body == "2 things to do across 2 lists")
    }

    @Test("The partner is told once for the crossing, not once per item")
    func partnerNotifiedPerList() {
        let event = crossing([
            target("Oat milk", trigger: .arrive, listId: "l1", shared: true),
            target("Bread", trigger: .arrive, listId: "l1", shared: true),
            target("Stamps", trigger: .arrive, listId: "l2", shared: false)
        ])
        #expect(event.notifiesPartner)

        // What `handleGeofenceCrossing` iterates: one call per *shared list*.
        let listsToTell = Set(event.targets.filter(\.notifiesPartner).map(\.listId))
        #expect(listsToTell == ["l1"], "Two items on one shared list is one API call")
    }

    @Test("A crossing with nothing shared stays entirely offline")
    func personalCrossingMakesNoCall() {
        let event = crossing([target("Oat milk", trigger: .arrive)])
        #expect(!event.notifiesPartner)
    }

    @Test("A tap on the notification opens the first target's list")
    func tapOpensAList() {
        let event = crossing([
            target("Oat milk", trigger: .arrive, listId: "l1"),
            target("Stamps", trigger: .arrive, listId: "l2")
        ])
        #expect(event.primaryListId == "l1")
    }
}

/// The in-app text-size control, which until now wrote a value into the
/// environment that nothing anywhere read.
@Suite("Text size")
struct TextSizeTests {

    @Test("Standard leaves the device's own setting alone")
    func standardIsIdentity() {
        for size in DynamicTypeSize.allCases {
            #expect(ThemeStore.TextSize.standard.applied(to: size) == size)
        }
    }

    @Test("Large and compact shift by one step")
    func shiftsByOneStep() {
        #expect(ThemeStore.TextSize.large.applied(to: .medium) == .large)
        #expect(ThemeStore.TextSize.compact.applied(to: .large) == .medium)
    }

    @Test("The shift stops at the ends rather than wrapping")
    func clampsAtBothEnds() {
        #expect(ThemeStore.TextSize.compact.applied(to: .xSmall) == .xSmall)
        #expect(ThemeStore.TextSize.large.applied(to: .accessibility5) == .accessibility5)
    }

    @Test("Compact never drops someone out of the accessibility sizes")
    func neverUndoesAnAccessibilitySetting() {
        // The control is a nudge on top of the system preference. Quietly
        // pulling a user below the accessibility range would be the app
        // overriding a deliberate accessibility choice.
        let shifted = ThemeStore.TextSize.compact.applied(to: .accessibility1)
        #expect(shifted.isAccessibilitySize)
        #expect(shifted == .accessibility1)
    }
}
