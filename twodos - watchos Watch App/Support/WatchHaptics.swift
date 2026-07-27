import WatchKit

/// Watch haptics.
///
/// These carry more weight on a watch than on a phone: the screen is often out
/// of view at the moment of the tap, so the tap back *is* the confirmation. Each
/// one is chosen for what the system already trains people to expect — `.success`
/// for a completed thing, `.click` for a smaller state change, `.failure` only
/// when something genuinely did not happen.
enum WatchHaptics {
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}
