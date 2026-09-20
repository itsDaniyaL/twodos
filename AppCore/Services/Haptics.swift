#if canImport(UIKit)
import UIKit
#endif

/// Haptic feedback, kept behind one small surface so the vocabulary stays
/// consistent: a tick feels the same everywhere in the app.
///
/// The generators are prepared lazily and reused — creating one per tap adds a
/// noticeable lag before the first buzz.
///
/// ## On the Mac
/// Every call is a no-op. A Mac has no Taptic Engine to speak of — the trackpad
/// does, but it is driven by AppKit for its own force-click gestures and is not
/// a general feedback channel, and an iMac has nothing at all. The alternative
/// to shimming here would be an `#if os(macOS)` around all 28 call sites, which
/// would put a platform check in the middle of every button in the app to
/// express "and on the Mac, do nothing".
///
/// This means a Mac action confirms *visually* or not at all, which is the
/// macOS convention anyway: feedback comes from the thing on screen changing,
/// not from the hardware.
@MainActor
enum Haptics {
    #if canImport(UIKit)
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    /// Adding an item, a light confirmation.
    static func light() {
        #if canImport(UIKit)
        impactLight.impactOccurred()
        #endif
    }

    /// A more substantial action: opening a sheet, dropping a map pin.
    static func medium() {
        #if canImport(UIKit)
        impactMedium.impactOccurred()
        #endif
    }

    /// Moving between discrete options — segmented controls, colour swatches.
    static func selection() {
        #if canImport(UIKit)
        selectionGenerator.selectionChanged()
        #endif
    }

    /// Completing a todo, accepting an invite.
    static func success() {
        #if canImport(UIKit)
        notificationGenerator.notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        notificationGenerator.notificationOccurred(.warning)
        #endif
    }

    /// A failed action. Paired with a visible message — a buzz alone tells the
    /// user something went wrong but not what.
    static func error() {
        #if canImport(UIKit)
        notificationGenerator.notificationOccurred(.error)
        #endif
    }

    /// Warms the generators so the first haptic of a session is not late.
    static func prepare() {
        #if canImport(UIKit)
        impactLight.prepare()
        selectionGenerator.prepare()
        #endif
    }
}
