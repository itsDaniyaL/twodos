import SwiftUI

/// Who is winning, pinned above the items.
///
/// The shape is deliberately the one the feature was described with —
/// `0 ← A.A | B.B → 3` — because a challenge between two people is a tug of
/// war, not a table. The arrows point away from the middle towards whoever is
/// pulling, so a glance at which side the numbers sit on tells you the story
/// before you have read either digit.
///
/// It is a header, not a card in the item stack: it stays put while the list
/// scrolls, since the whole point of a score is being able to check it without
/// losing your place.
struct ChallengeScoreboard: View {
    let challenge: Challenge
    let me: String?
    let myName: String
    let theirName: String
    let theirId: String?
    /// Nil once the challenge is running — only the pending state is answerable.
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Clears a finished result. Only offered once there is nothing left to
    /// watch — a result you cannot put away is a result that nags.
    var onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var myScore: Int { challenge.score(for: me) }
    private var theirScore: Int { challenge.score(for: theirId) }

    var body: some View {
        GlassCard(tint: tint, radius: Metrics.controlRadius) {
            VStack(spacing: 10) {
                if challenge.status == .pending {
                    pendingHeadline
                } else {
                    scoreRow
                }
                footer
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - The tug of war

    private var scoreRow: some View {
        HStack(spacing: 10) {
            side(
                name: myName,
                score: myScore,
                isLeading: myScore > theirScore,
                alignment: .leading,
                arrow: "arrow.left"
            )

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 26)

            side(
                name: theirName,
                score: theirScore,
                isLeading: theirScore > myScore,
                alignment: .trailing,
                arrow: "arrow.right"
            )
        }
        // Animated on the score itself so a point landing over the socket makes
        // the number move — the moment somebody scores is the one moment this
        // view exists for.
        .motion(reduceMotion ? Motion.fade : Motion.delight, value: myScore + theirScore)
    }

    private func side(
        name: String,
        score: Int,
        isLeading: Bool,
        alignment: HorizontalAlignment,
        arrow: String
    ) -> some View {
        // The arrow sits on the outside of each pair, so the two point away from
        // the divider in the middle.
        let scoreBlock = HStack(spacing: 5) {
            if alignment == .leading {
                Text("\(score)")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Image(systemName: arrow).font(.caption2.weight(.bold))
            } else {
                Image(systemName: arrow).font(.caption2.weight(.bold))
                Text("\(score)")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(isLeading ? tint : .secondary)

        return VStack(alignment: alignment, spacing: 1) {
            scoreBlock
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var pendingHeadline: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered.2.crossed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(iStarted
                 ? "Waiting for \(theirName) to accept"
                 : "\(theirName) challenged you")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
    }

    /// The deadline, the outcome, and whatever there is to do about it.
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            if challenge.status == .pending, !iStarted, let onAccept, let onDecline {
                Button("Decline", action: onDecline)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Accept", action: onAccept)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
            } else if challenge.isLive, let onCancel {
                Button(challenge.status == .pending ? "Withdraw" : "Call it off", action: onCancel)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
            }
        }
    }

    // MARK: - Words

    private var iStarted: Bool { challenge.createdBy == me }

    private var statusLine: LocalizedStringResource {
        switch challenge.status {
        case .pending:
            return "Ends \(Format.deadline(challenge.deadline))"
        case .active:
            // Past the deadline the server has the last word, and it may not
            // have run its sweep yet. Saying "finished" rather than a negative
            // countdown keeps the two from contradicting each other.
            return challenge.hasExpired
                ? "Time's up — counting the score"
                : "Ends \(Format.deadline(challenge.deadline))"
        case .complete:
            if challenge.isDraw { return "It's a draw — \(myScore) each" }
            return challenge.winnerId == me
                ? "You won, \(myScore)–\(theirScore)"
                : "\(theirName) won, \(theirScore)–\(myScore)"
        case .declined:
            return "\(theirName) passed on this one"
        case .cancelled:
            return "Called off"
        }
    }

    private var tint: Color {
        switch challenge.status {
        case .complete:
            if challenge.isDraw { return Brand.info }
            return challenge.winnerId == me ? Brand.success : Brand.apricot
        case .declined, .cancelled:
            return .secondary
        case .pending:
            return Brand.info
        case .active:
            // Leaning on the same colour language as deadlines: the closer the
            // finish, the warmer the card.
            return Format.deadlineTint(challenge.deadline)
        }
    }

    /// The same words as `statusLine`, as a plain string for VoiceOver, which
    /// composes them into a longer sentence.
    private var spokenStatus: String {
        switch challenge.status {
        case .pending, .active:
            return challenge.hasExpired && challenge.status == .active
                ? String(localized: "Time's up, counting the score")
                : String(localized: "Ends \(Format.deadline(challenge.deadline))")
        case .complete:
            if challenge.isDraw { return String(localized: "It's a draw") }
            return challenge.winnerId == me
                ? String(localized: "You won")
                : String(localized: "\(theirName) won")
        case .declined:
            return String(localized: "Declined")
        case .cancelled:
            return String(localized: "Called off")
        }
    }

    private var accessibilityLabel: String {
        guard challenge.status != .pending else {
            return iStarted
                ? String(localized: "Challenge sent to \(theirName), not answered yet")
                : String(localized: "\(theirName) has challenged you")
        }
        return String(
            localized: "Challenge. You \(myScore), \(theirName) \(theirScore). \(spokenStatus)"
        )
    }
}
