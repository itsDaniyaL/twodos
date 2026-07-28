import Foundation
import Testing
@testable import twodos___ios

/// What the Live Activity says while the user is standing in a shop.
///
/// It is read at arm's length, one-handed, often without unlocking — so the
/// arithmetic behind "how much is left" has to be right at a glance. A card
/// showing a full progress bar above two unticked items is worse than no card.
@Suite("Place visit activity")
struct LiveActivityTests {

    private func state(
        remaining: [String],
        done: Int,
        total: Int
    ) -> PlaceVisitAttributes.ContentState {
        PlaceVisitAttributes.ContentState(remaining: remaining, doneCount: done, totalCount: total)
    }

    // MARK: - Progress

    @Test("Progress reflects how far through the visit the user is")
    func progressIsProportional() {
        #expect(state(remaining: ["a", "b"], done: 2, total: 4).progress == 0.5)
        #expect(state(remaining: [], done: 4, total: 4).progress == 1)
        #expect(state(remaining: ["a"], done: 0, total: 1).progress == 0)
    }

    @Test("An empty list does not divide by zero")
    func emptyListIsSafe() {
        // A place can be pinned to a list before anything is added to it.
        #expect(state(remaining: [], done: 0, total: 0).progress == 0)
    }

    @Test("Progress never exceeds one")
    func progressIsClamped() {
        // Counts can disagree briefly — a tick applied locally while a refresh
        // is in flight. A progress bar past its end reads as broken.
        #expect(state(remaining: [], done: 6, total: 4).progress == 1)
    }

    // MARK: - Completion

    @Test("Everything ticked reads as complete")
    func completionIsDetected() {
        #expect(state(remaining: [], done: 3, total: 3).isComplete)
    }

    @Test("An empty list is not 'complete'")
    func emptyIsNotComplete() {
        // Otherwise a place pinned to an empty list would start an Activity that
        // immediately announces it is finished.
        #expect(!state(remaining: [], done: 0, total: 0).isComplete)
    }

    @Test("Anything left means not complete")
    func remainingMeansIncomplete() {
        #expect(!state(remaining: ["Oat milk"], done: 2, total: 3).isComplete)
    }

    // MARK: - Overflow

    @Test("More items than the card can name are counted, not dropped")
    func overflowIsCounted() {
        // Ten outstanding, four shown: the card must account for the other six
        // rather than stopping at four and reading as "that's everything".
        let s = state(remaining: ["a", "b", "c", "d"], done: 0, total: 10)
        #expect(s.overflow == 6)
    }

    @Test("Nothing hidden means no overflow")
    func noOverflowWhenAllShown() {
        #expect(state(remaining: ["a", "b"], done: 1, total: 3).overflow == 0)
    }

    @Test("Overflow never goes negative")
    func overflowIsFloored() {
        // Same transient disagreement as above: the snapshot can hold more
        // titles than the counts admit to.
        #expect(state(remaining: ["a", "b", "c"], done: 2, total: 3).overflow == 0)
    }

    @Test("The card names at most four things")
    func titleCapIsSmall() {
        // Four is what the expanded Dynamic Island shows without shrinking the
        // text. Past that a count reads faster than a list.
        #expect(PlaceVisitAttributes.maxTitles == 4)
    }
}
