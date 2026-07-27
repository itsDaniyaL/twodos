import SwiftUI

/// One place for every animation in the app.
///
/// Named curves beat inline `.spring(response: 0.3…)` calls: the timing of a
/// checkbox and the timing of a sheet should feel related, and when they are
/// tuned from one file they stay related.
///
/// All of these respect Reduce Motion at the call site via ``Motion/respectful``.
enum Motion {
    /// The default for anything the user directly manipulated — a tap, a toggle.
    /// Fast enough to feel instant, springy enough to feel physical.
    static let tap = Animation.spring(response: 0.32, dampingFraction: 0.72)

    /// For content that appears or reflows without a direct touch: a row
    /// arriving from the socket, a section expanding.
    static let content = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Large surfaces: sheets, full-screen covers, map camera moves.
    static let surface = Animation.spring(response: 0.5, dampingFraction: 0.85)

    /// A bouncier curve for celebratory moments only — completing the last item
    /// in a list, an invite being accepted.
    static let delight = Animation.spring(response: 0.45, dampingFraction: 0.6)

    /// Cross-fades where movement would be noise.
    static let fade = Animation.easeInOut(duration: 0.22)

    /// Returns `animation` normally, or a plain quick fade when the user has
    /// asked the system to reduce motion.
    static func respectful(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

extension View {
    /// Applies an animation, automatically degrading to a fade under Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(RespectfulMotion(animation: animation, value: value))
    }
}

private struct RespectfulMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(Motion.respectful(animation, reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// Rows entering a list: they rise slightly and fade, so a partner's edit
    /// arriving over the socket reads as "something new" rather than a jump cut.
    static var rowInsertion: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        )
    }

    /// Banners and inline prompts.
    static var banner: AnyTransition {
        .move(edge: .top).combined(with: .opacity)
    }
}
