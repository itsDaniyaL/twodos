import Foundation
import Testing
@testable import twodos___ios

/// The category identifiers the phone registers and the watch matches on.
///
/// These are the wire format between two devices. A typo shows the wrong glyph
/// and colour on a real notification and nothing catches it at build time —
/// which is why both sides now read them from one place, and why the round trip
/// is pinned here.
@Suite("Notification categories")
struct NotificationKindTests {

    @Test("Every kind round-trips through its identifier")
    func roundTrips() {
        for kind in NotificationKind.allCases {
            #expect(NotificationKind(identifier: kind.identifier) == kind)
        }
    }

    @Test("The identifiers are the ones already in the field")
    func identifiersAreFixed() {
        // Changing any of these silently breaks the watch's long-look interface
        // for notifications sent by an older phone build.
        #expect(NotificationKind.deadline.identifier == "TWODOS_DEADLINE")
        #expect(NotificationKind.alarm.identifier == "TWODOS_ALARM")
        #expect(NotificationKind.geofence.identifier == "TWODOS_GEOFENCE")
        #expect(NotificationKind.social.identifier == "TWODOS_SOCIAL")
    }

    @Test("An unknown category falls back to deadline rather than failing")
    func unknownFallsBack() {
        // A newer phone build could send a category this watch has never heard
        // of. Drawing it as a deadline is right more often than not, and showing
        // nothing would be worse in every case.
        #expect(NotificationKind(identifier: "TWODOS_SOMETHING_NEW") == .deadline)
        #expect(NotificationKind(identifier: "") == .deadline)
    }

    @Test("Identifiers are all distinct")
    func identifiersAreUnique() {
        let ids = Set(NotificationKind.allCases.map(\.identifier))
        #expect(ids.count == NotificationKind.allCases.count)
    }
}
