import UIKit

/// Haptic feedback, kept behind one small surface so the vocabulary stays
/// consistent: a tick feels the same everywhere in the app.
///
/// The generators are prepared lazily and reused — creating one per tap adds a
/// noticeable lag before the first buzz.
@MainActor
enum Haptics {
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    /// Adding an item, a light confirmation.
    static func light() {
        impactLight.impactOccurred()
    }

    /// A more substantial action: opening a sheet, dropping a map pin.
    static func medium() {
        impactMedium.impactOccurred()
    }

    /// Moving between discrete options — segmented controls, colour swatches.
    static func selection() {
        selectionGenerator.selectionChanged()
    }

    /// Completing a todo, accepting an invite.
    static func success() {
        notificationGenerator.notificationOccurred(.success)
    }

    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
    }

    /// A failed action. Paired with a visible message — a buzz alone tells the
    /// user something went wrong but not what.
    static func error() {
        notificationGenerator.notificationOccurred(.error)
    }

    /// Warms the generators so the first haptic of a session is not late.
    static func prepare() {
        impactLight.prepare()
        selectionGenerator.prepare()
    }
}
