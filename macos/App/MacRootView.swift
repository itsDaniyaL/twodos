import SwiftUI

/// Routes between launching, signed out, and signed in.
///
/// The same three phases as iOS, reading the same `AppStore.phase`, so the two
/// platforms cannot disagree about whether somebody is signed in. What differs
/// is the shape each phase takes: a Mac shows the signed-out state as a
/// centred panel in the window rather than a full-bleed screen, because a
/// desktop window is not a phone and edge-to-edge artwork at 1400pt wide looks
/// like a website, not an app.
struct MacRootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.phase {
            case .launching:
                MacLoadingView(message: "Getting your lists…")

            case .signedOut:
                MacWelcomeView()

            case .signedIn:
                MacMainWindow()
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.phase)
        .overlay(alignment: .top) {
            if store.sessionExpired && store.phase == .signedOut {
                MacBanner(
                    kind: .warning,
                    title: "You were signed out",
                    message: "Your session expired. Sign in again to carry on.",
                    onDismiss: { store.acknowledgeSessionExpiry() }
                )
                .frame(maxWidth: 460)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: store.sessionExpired)
    }
}
