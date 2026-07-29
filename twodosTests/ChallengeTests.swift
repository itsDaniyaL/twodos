import Foundation
import Testing
@testable import twodos___ios

/// The scoreboard.
///
/// Everything here is read straight off the wire shape `ChallengeService.describe`
/// produces, decoded with the app's own decoder — the scoreboard is the one
/// surface where being wrong is loudly, personally wrong, so a hand-built
/// fixture that happens to compile proves nothing about the field names.
@Suite("Challenges")
struct ChallengeTests {

    private let me = "user-me"
    private let them = "user-them"

    private func challenge(
        status: String = "CHALLENGE::STATUS::ACTIVE",
        deadline: String = "2026-12-31T21:00:00.000Z",
        winnerId: String? = nil,
        endReason: String? = nil,
        scores: [String: Int] = ["user-me": 0, "user-them": 0],
        todoIds: [String] = ["todo-1", "todo-2"]
    ) throws -> Challenge {
        let payload: [String: Any] = [
            "id": "challenge-1",
            "listId": "list-1",
            "createdBy": me,
            "status": status,
            "deadline": deadline,
            "acceptedAt": NSNull(),
            "endedAt": NSNull(),
            "winnerId": winnerId as Any? ?? NSNull(),
            "endReason": endReason as Any? ?? NSNull(),
            "scores": scores,
            "todoIds": todoIds,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try APIDecodingTests.decoder().decode(Challenge.self, from: data)
    }

    // MARK: - The wire shape

    @Test("A challenge decodes from what the API actually sends")
    func decodesLiveShape() throws {
        let live = try challenge(scores: ["user-me": 2, "user-them": 5])
        #expect(live.id == "challenge-1")
        #expect(live.status == .active)
        #expect(live.createdBy == me)
        #expect(live.todoIds.count == 2)
        #expect(live.score(for: me) == 2)
    }

    @Test("An unrecognised status does not throw")
    func unknownStatusFallsBack() throws {
        // A status the client has never heard of must not take the whole list
        // screen down with it — a server that adds one should cost the user a
        // slightly wrong label, nothing more.
        let live = try challenge(status: "CHALLENGE::STATUS::HIBERNATING")
        #expect(live.status == .pending)
    }

    // MARK: - Reading the score

    @Test("Both sides are readable, whichever side you are on")
    func scoresBothWays() throws {
        let live = try challenge(scores: [me: 3, them: 1])
        #expect(live.score(for: me) == 3)
        #expect(live.opponentScore(against: me) == 1)
        #expect(live.score(for: them) == 1)
        #expect(live.opponentScore(against: them) == 3)
    }

    @Test("A missing user scores zero rather than crashing")
    func absentUserScoresZero() throws {
        // The scoreboard is drawn before the profile has necessarily loaded, so
        // `currentUserId` can genuinely be nil at first paint.
        let live = try challenge(scores: [me: 4, them: 2])
        #expect(live.score(for: nil) == 0)
        #expect(live.score(for: "user-stranger") == 0)
    }

    @Test("Zero-all is a real scoreboard, not a missing one")
    func zeroAllIsDrawable() throws {
        let live = try challenge(scores: [me: 0, them: 0])
        #expect(live.score(for: me) == 0)
        #expect(live.opponentScore(against: me) == 0)
    }

    // MARK: - Liveness

    @Test("Pending and active are live; everything else is over")
    func liveness() throws {
        #expect(try challenge(status: "CHALLENGE::STATUS::PENDING").isLive)
        #expect(try challenge(status: "CHALLENGE::STATUS::ACTIVE").isLive)
        #expect(try !challenge(status: "CHALLENGE::STATUS::COMPLETE").isLive)
        #expect(try !challenge(status: "CHALLENGE::STATUS::DECLINED").isLive)
        #expect(try !challenge(status: "CHALLENGE::STATUS::CANCELLED").isLive)
    }

    @Test("Only an accepted challenge is running")
    func onlyAcceptedRuns() throws {
        // Task rows badge on `isRunning`. Flagging tasks for a challenge nobody
        // has agreed to yet would mark work as competitive before it is.
        #expect(try !challenge(status: "CHALLENGE::STATUS::PENDING").isRunning)
        #expect(try challenge(status: "CHALLENGE::STATUS::ACTIVE").isRunning)
    }

    @Test("A past deadline reads as expired")
    func expiry() throws {
        #expect(try challenge(deadline: "2020-01-01T09:00:00.000Z").hasExpired)
        #expect(try !challenge(deadline: "2099-01-01T09:00:00.000Z").hasExpired)
    }

    // MARK: - Live updates

    @Test("A scored event replaces the numbers and nothing else")
    func scoringKeepsEverythingElse() throws {
        let live = try challenge(scores: [me: 1, them: 1])
        let after = Challenge(from: live, scores: [me: 1, them: 2])

        #expect(after.score(for: them) == 2)
        #expect(after.id == live.id)
        #expect(after.status == live.status)
        #expect(after.deadline == live.deadline)
        #expect(after.todoIds == live.todoIds)
    }

    @Test("Ending on the deadline completes it with a winner")
    func endingWithAWinner() throws {
        let finished = try challenge(scores: [me: 1, them: 1]).ended(
            winnerId: them,
            scores: [me: 2, them: 5],
            endReason: "CHALLENGE::END::DEADLINE"
        )
        #expect(finished.status == .complete)
        #expect(finished.winnerId == them)
        #expect(finished.score(for: them) == 5)
        #expect(!finished.isLive)
        #expect(!finished.isDraw)
    }

    @Test("Level scores at the end are a draw")
    func levelIsADraw() throws {
        let finished = try challenge().ended(
            winnerId: nil,
            scores: [me: 3, them: 3],
            endReason: "CHALLENGE::END::DEADLINE"
        )
        #expect(finished.isDraw)
    }

    @Test("A cancellation is not a draw")
    func cancellationIsNotADraw() throws {
        // Both end with no winner, so status is the only thing telling them
        // apart — and calling a walk-out "a draw" would be a small lie told at
        // the exact moment somebody quit.
        let called = try challenge().ended(
            winnerId: nil,
            scores: [me: 4, them: 0],
            endReason: "CHALLENGE::END::CANCELLED"
        )
        #expect(called.status == .cancelled)
        #expect(!called.isDraw)
        #expect(!called.isLive)
    }

    @Test("A declined challenge says so instead of disappearing")
    func decliningIsVisible() throws {
        // The person who sent it has to be told. Refetching would answer null,
        // because the endpoint only returns live challenges.
        let refused = try challenge(status: "CHALLENGE::STATUS::PENDING").declined()
        #expect(refused.status == .declined)
        #expect(!refused.isLive)
        #expect(!refused.isDraw)
    }

    @Test("Finishing everything early ends it as a completed challenge")
    func earlyFinishCompletes() throws {
        let finished = try challenge().ended(
            winnerId: me,
            scores: [me: 2, them: 0],
            endReason: "CHALLENGE::END::EARLY_FINISH"
        )
        #expect(finished.status == .complete)
        #expect(finished.winnerId == me)
    }
}
