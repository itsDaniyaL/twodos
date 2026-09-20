import SwiftUI

/// The three drawings the app owns, in the three places iOS uses them.
///
/// ## Why a type rather than `Image("…")` at each site
/// A name typed at the call site is a string that can rot: rename the asset and
/// the build still succeeds, showing an empty frame at runtime. Naming them
/// once here makes the compiler the thing that notices.
///
/// ## Why they are sized here too
/// An illustration that is 320pt on a phone is a postage stamp on a 27-inch
/// display and a wall on a small window. Each case carries the size it wants
/// for a desktop window, so no screen has to guess.
enum Illustration: String {
    /// Two hands meeting — the welcome screen, before anyone has signed in.
    case highFive = "IllustrationHighFive"
    /// A brighter pair — the empty lists state, where nothing exists yet.
    case handsBright = "IllustrationHandsBright"
    /// Hands with a spark — completing an invitation somebody else started.
    case handsSpark = "IllustrationHandsSpark"

    var defaultHeight: CGFloat {
        switch self {
        case .highFive: 200
        case .handsBright: 168
        case .handsSpark: 176
        }
    }
}

extension Illustration: View {
    var body: some View {
        Image(rawValue)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: defaultHeight)
            // Purely decorative: every screen that shows one also states its
            // message in text directly underneath, so describing the drawing
            // to VoiceOver would read the same thing twice.
            .accessibilityHidden(true)
    }
}
