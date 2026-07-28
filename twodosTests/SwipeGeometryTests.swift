import Foundation
import Testing
@testable import twodos___ios

/// The thresholds behind swipe-to-reveal on item rows.
///
/// One of the outcomes deletes an item outright, so "how far is far enough" is
/// not a number to leave unpinned. The rest of the gesture is a view and needs a
/// finger; this is the part that does not.
@Suite("Swipe geometry")
struct SwipeGeometryTests {

    /// Two buttons — Delete and Remind — which is what `TodoRow` uses.
    private let geometry = SwipeGeometry(openWidth: 156)

    private func outcome(_ offset: CGFloat, destructive: Bool = true) -> SwipeGeometry.Outcome {
        geometry.outcome(for: offset, hasFullSwipe: destructive)
    }

    // MARK: - Opening

    @Test("A short drag springs back rather than leaving the row ajar")
    func shortDragCloses() {
        #expect(outcome(-20) == .closed)
    }

    @Test("Past halfway commits, which is where the hand already expects it")
    func halfwayCommits() {
        #expect(outcome(-79) == .open)
    }

    @Test("Just short of halfway does not commit")
    func justShortDoesNotCommit() {
        #expect(outcome(-77) == .closed)
    }

    // MARK: - Full swipe

    @Test("A hard throw past the buttons deletes outright")
    func fullSwipeFires() {
        // 156 open + 64 slack.
        #expect(outcome(-221) == .fullSwipe)
    }

    @Test("Fully open is not far enough to delete by itself")
    func openIsNotDelete() {
        // Reaching the end of the buttons must reveal them, never fire them —
        // otherwise the gesture that shows you the options also destroys the
        // item.
        #expect(outcome(-156) == .open)
        #expect(outcome(-210) == .open)
    }

    @Test("Without a destructive action, a hard throw only opens")
    func noDestructiveMeansNoFullSwipe() {
        #expect(outcome(-400, destructive: false) == .open)
    }

    // MARK: - The leading edge does nothing

    @Test("Dragging the wrong way does not move the row")
    func leadingEdgeIsInert() {
        // There are no leading actions by design: that edge competes with the
        // back-swipe gesture, and two edges is more chrome than a row can carry.
        #expect(geometry.clamp(120) == 0)
        #expect(outcome(120) == .closed)
    }

    @Test("A row with no actions never opens")
    func noActionsNeverOpens() {
        let empty = SwipeGeometry(openWidth: 0)
        #expect(empty.clamp(-200) == 0)
        #expect(empty.outcome(for: -200, hasFullSwipe: true) == .closed)
    }

    // MARK: - Rubber banding

    @Test("A drag inside the buttons tracks the finger exactly")
    func tracksFingerWhileOpening() {
        #expect(geometry.clamp(-100) == -100)
    }

    @Test("Past fully open it resists instead of stopping dead")
    func resistsPastOpen() {
        let stretched = geometry.clamp(-256) // 100pt beyond open
        #expect(stretched < -156, "Must still move — a hard stop feels broken")
        #expect(stretched > -256, "But not one-for-one, or there is no sense of a limit")
    }

    @Test("Zero is zero")
    func restingStateIsStable() {
        #expect(geometry.clamp(0) == 0)
        #expect(outcome(0) == .closed)
    }
}
