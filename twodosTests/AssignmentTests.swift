import Foundation
import Testing
@testable import twodos___ios

/// Who has a task after the next tap.
///
/// A cycle is only worth using if it is predictable, and the case that breaks
/// that is a list with nobody else on it — tapping through must not offer a
/// person who is not there.
@Suite("Assignee cycle")
struct AssignmentTests {

    private let me = "user-me"
    private let partner = "user-partner"

    private func next(_ current: String?, partner: String? = "user-partner") -> String? {
        AssigneeCycle.next(current: current, me: me, partner: partner)
    }

    @Test("Unclaimed becomes mine")
    func firstTapClaims() {
        // The common gesture by far: "I'll do this".
        #expect(next(nil) == me)
    }

    @Test("Mine becomes theirs")
    func secondTapHandsOver() {
        #expect(next(me) == partner)
    }

    @Test("Theirs becomes unclaimed")
    func thirdTapReleases() {
        #expect(next(partner) == nil)
    }

    @Test("Three taps return to where they started")
    func cycleClosesInThree() {
        var state: String? = nil
        state = next(state)
        state = next(state)
        state = next(state)
        #expect(state == nil)
    }

    // MARK: - Lists with nobody else on them

    @Test("On a solo list, mine goes straight back to unclaimed")
    func soloListSkipsThePartnerStep() {
        // There is no second person to hand it to, and offering one would be a
        // tap that appears to do nothing.
        #expect(next(me, partner: nil) == nil)
    }

    @Test("A partner id equal to your own is not a second person")
    func selfPartnerIsSolo() {
        // The API represents a solo list by pointing partnerId back at the
        // creator. Treating that as someone else would assign work to yourself
        // twice over and make the cycle appear stuck.
        #expect(next(me, partner: me) == nil)
    }

    @Test("A solo list still claims on the first tap")
    func soloListStillClaims() {
        #expect(next(nil, partner: nil) == me)
    }

    // MARK: - Unexpected state

    @Test("A task assigned to someone no longer on the list is released")
    func strangerIsReleased() {
        // Can happen after a partner is removed. Anything that is not you falls
        // to the release step, which is the safe direction.
        #expect(next("user-departed") == nil)
    }
}
