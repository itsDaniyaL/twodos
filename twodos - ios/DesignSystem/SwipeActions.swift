import SwiftUI

/// Swipe-from-the-right actions for rows that are not in a `List`.
///
/// ## Why this exists rather than `.swipeActions`
/// SwiftUI's own modifier only works inside `List` or `Form`. Both of this app's
/// row surfaces draw into a `LazyVStack` inside a `ScrollView` so the cards can
/// be glass and spaced — which means the `.swipeActions` modifiers written on
/// `ListCard` and `TodoRow` never ran. They were dead code in both places.
///
/// ## Why the buttons live inside the revealed strip
/// The obvious construction — buttons in a `ZStack` behind the row — is wrong
/// here. A `GlassCard` is *translucent*, so anything drawn behind it shows
/// through: the actions were faintly visible at rest, before any swipe.
///
/// So the buttons are not behind the row at all. They occupy a strip whose width
/// **is** the drag distance, clipped to it, sitting beside the row rather than
/// under it. At rest that strip is zero points wide and nothing is drawn.
///
/// ## Trailing only
/// One edge, deliberately. A leading swipe competes with the back-swipe gesture,
/// and two edges of actions is more chrome than a row this size can carry.
/// Everything else lives in the context menu.
struct SwipeAction: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var tint: Color
    /// Destructive actions sit outermost and are what a full swipe fires.
    var isDestructive: Bool = false
    var handler: () -> Void

    init(
        title: String,
        systemImage: String,
        tint: Color,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

/// The arithmetic behind the gesture, separated from the view so the thresholds
/// can be tested without a finger.
///
/// One outcome deletes something irreversibly, so "how far is far enough" is not
/// a number to leave unpinned.
struct SwipeGeometry: Equatable {
    /// Total width of the buttons when fully revealed.
    var openWidth: CGFloat
    /// How far past fully open a drag must go before it fires outright.
    var fullSwipeSlack: CGFloat = 64

    enum Outcome: Equatable {
        case closed
        case open
        /// Drag went far enough to fire the outermost destructive action.
        case fullSwipe
    }

    /// Clamps a drag. Positive values do nothing — there is nothing on the
    /// leading edge — and past fully open it resists rather than stopping dead.
    func clamp(_ proposed: CGFloat) -> CGFloat {
        guard openWidth > 0, proposed < 0 else { return 0 }
        let limit = -openWidth
        return proposed < limit ? limit + (proposed - limit) * 0.35 : proposed
    }

    /// Where the row lands when the finger lifts.
    func outcome(for proposed: CGFloat, hasFullSwipe: Bool) -> Outcome {
        guard openWidth > 0 else { return .closed }
        if hasFullSwipe, proposed < -(openWidth + fullSwipeSlack) { return .fullSwipe }
        // Halfway is the commit point, which is what `List` does and therefore
        // what the hand already expects.
        if proposed < -openWidth / 2 { return .open }
        return .closed
    }
}

/// Keeps at most one row open across the whole screen.
///
/// Without this, swiping a second row leaves the first hanging open behind it,
/// which reads as a rendering fault rather than as two open rows.
@MainActor
@Observable
final class SwipeCoordinator {
    /// Rows observe this and close themselves when it stops naming them, which
    /// is why there is no `close()` here — clearing it from outside is the same
    /// operation, spelled twice.
    var openRow: UUID?
}

private struct SwipeCoordinatorKey: EnvironmentKey {
    /// A throwaway fallback, so a container used outside a screen that provides
    /// one still works — it simply does not coordinate with anything.
    ///
    /// `assumeIsolated` because `EnvironmentKey` demands a nonisolated static
    /// while the coordinator is `@MainActor`. Environment defaults are read
    /// during view evaluation, which is already on the main actor.
    static var defaultValue: SwipeCoordinator {
        MainActor.assumeIsolated { SwipeCoordinator() }
    }
}

extension EnvironmentValues {
    var swipeCoordinator: SwipeCoordinator {
        get { self[SwipeCoordinatorKey.self] }
        set { self[SwipeCoordinatorKey.self] = newValue }
    }
}

struct SwipeActionsContainer<Content: View>: View {
    var actions: [SwipeAction]
    /// Corner radius of the content, so the revealed strip is clipped to the
    /// same shape and no square corner appears beside a rounded card.
    var radius: CGFloat = Metrics.controlRadius
    @ViewBuilder var content: Content

    @Environment(\.swipeCoordinator) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var id = UUID()
    @State private var offset: CGFloat = 0
    @State private var committed: CGFloat = 0
    /// Set once a drag is unambiguously horizontal, so a vertical scroll that
    /// wobbles never drags a row sideways.
    @State private var isHorizontal: Bool?

    /// Width of one button. Enough for a glyph and a short word without wrapping.
    private let actionWidth: CGFloat = 78
    /// Breathing room between the row and the first button.
    private let gap: CGFloat = 8

    private var openWidth: CGFloat { CGFloat(actions.count) * actionWidth }
    private var geometry: SwipeGeometry { SwipeGeometry(openWidth: openWidth) }

    /// How much of the strip is currently showing.
    private var revealed: CGFloat { max(0, -offset) }
    private var isOpen: Bool { committed != 0 }

    var body: some View {
        HStack(spacing: 0) {
            content
                .overlay {
                    // While open, a tap must close rather than activate the row.
                    // This is what `List` does, and without it the most likely
                    // tap right after a swipe does the most surprising thing.
                    if isOpen {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(.rect)
                            .onTapGesture { close() }
                    }
                }

            // The strip. Its width *is* the drag distance, so at rest it is zero
            // points wide and the buttons are not drawn at all — which is what
            // stops them showing through the glass.
            if revealed > gap {
                buttons
                    .frame(width: revealed - gap, alignment: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .padding(.leading, gap)
            }
        }
        .motion(Motion.tap, value: offset)
        .simultaneousGesture(drag)
        // VoiceOver never sees the swipe, so every action is also published as a
        // named action on the row. Without this the feature is invisible to
        // anyone not using their eyes.
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { action.handler() }
            }
        }
        .onChange(of: coordinator.openRow) { _, open in
            guard open != id, isOpen else { return }
            close()
        }
    }

    /// Laid out at full width and clipped by the strip, so the buttons slide out
    /// from behind the row's edge rather than squashing as it opens.
    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    fire(action)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                        Text(action.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(action.tint)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true) // reached through the row's own actions
            }
        }
        .frame(width: openWidth)
    }

    // MARK: - Gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if isHorizontal == nil {
                    // Decide the axis once. A vertical scroll must never drag a
                    // row sideways, and a horizontal swipe must not fight the
                    // ScrollView for the rest of the gesture.
                    isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                }
                guard isHorizontal == true else { return }
                offset = geometry.clamp(committed + directional(value.translation.width))
            }
            .onEnded { value in
                defer { isHorizontal = nil }
                guard isHorizontal == true else { return }
                settle(at: committed + directional(value.translation.width))
            }
    }

    /// Flips the sign in right-to-left layouts, so "swipe in from the trailing
    /// edge" means the same thing in Arabic as in English.
    private func directional(_ width: CGFloat) -> CGFloat {
        layoutDirection == .rightToLeft ? -width : width
    }

    private func settle(at proposed: CGFloat) {
        switch geometry.outcome(for: proposed, hasFullSwipe: fullSwipeAction != nil) {
        case .fullSwipe:
            if let action = fullSwipeAction { fire(action) }
        case .open:
            open()
        case .closed:
            close()
        }
    }

    /// Only a destructive action is worth firing without a second tap. Opening a
    /// date picker from a gesture the user may have overshot would be a
    /// surprise; deleting is the one thing the gesture is *for*.
    private var fullSwipeAction: SwipeAction? {
        actions.first { $0.isDestructive }
    }

    // MARK: - State

    private func open() {
        withAnimation(reduceMotion ? nil : Motion.tap) {
            offset = -openWidth
            committed = -openWidth
        }
        coordinator.openRow = id
        Haptics.selection()
    }

    private func close() {
        withAnimation(reduceMotion ? nil : Motion.tap) {
            offset = 0
            committed = 0
        }
        if coordinator.openRow == id { coordinator.openRow = nil }
    }

    private func fire(_ action: SwipeAction) {
        // Close first: the row is usually about to disappear, and animating it
        // out from a half-swiped position looks like a glitch.
        close()
        if action.isDestructive { Haptics.medium() } else { Haptics.light() }
        action.handler()
    }
}
