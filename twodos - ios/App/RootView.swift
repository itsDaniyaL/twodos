import SwiftUI

/// Routes between the launch, signed-out, and signed-in states.
///
/// The transitions between them are cross-faded rather than cut, so signing in
/// does not feel like the app restarted.
struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            switch store.phase {
            case .launching:
                ZStack {
                    ScreenBackground(showsHorizon: true)
                    LoadingView(message: "Getting your lists…")
                }
                .transition(.opacity)

            case .signedOut:
                WelcomeView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))

            case .signedIn:
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .motion(Motion.surface, value: store.phase)
        .overlay(alignment: .top) {
            if store.sessionExpired && store.phase == .signedOut {
                InlineBanner(
                    kind: .warning,
                    title: "You were signed out",
                    message: "Your session expired. Sign in again to carry on.",
                    onDismiss: { store.acknowledgeSessionExpiry() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.banner)
            }
        }
        .motion(Motion.content, value: store.sessionExpired)
    }
}
