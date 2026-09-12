import AuthenticationServices
import SwiftUI

/// The social buttons plus everything it takes to turn a tap on one into a
/// signed-in session.
///
/// `SocialSignInButtons` only draws; this owns the flow — Apple's native sheet,
/// the browser round-trip for Google and Facebook, the call to the API, and
/// the busy state that keeps the buttons from being tapped twice. It exists so
/// the welcome screen and the sign-in screen offer the same buttons with the
/// same behaviour, from one implementation, rather than each carrying its own
/// copy of the Apple credential unpacking.
///
/// Which buttons appear is the *server's* decision, delivered by
/// `/api/v1/client-config` and cached on `AppStore.socialAuth`: a provider
/// whose credentials are not configured simply never draws a button, instead
/// of drawing one that fails after the user has already committed to it. When
/// no provider is available this renders nothing at all, so the host screen
/// should gate any separator on `hasProviders`.
///
/// Apple is only ever offered on iOS — the native sheet is the whole point,
/// and this section is compiled into the iOS target alone. The watch never
/// signs in, and Android takes the server's web bridge instead.
struct SocialSignInSection: View {
    /// True while a sign-in is in flight. Shared with the host so it can
    /// disable its own controls for the duration.
    @Binding var isAuthenticating: Bool
    /// Every failure worth telling the user about arrives here; cancellations
    /// are swallowed before they get this far.
    var onError: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var social = SocialSignInService()

    var body: some View {
        SocialSignInButtons(
            providers: providers,
            isBusy: isAuthenticating,
            onApple: handleApple,
            onProvider: signIn(with:)
        )
    }

    private var providers: [SocialProvider] {
        store.socialAuth?.availableProviders ?? []
    }

    // MARK: - Apple sign-in

    /// Apple hands us an identity token which the API verifies server-side.
    /// The display name only arrives on the *first* authorisation, so it is
    /// forwarded when present — after that Apple omits it forever.
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else {
                onError("Apple didn't return a usable credential. Try email instead.")
                return
            }

            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")

            authenticate { try await store.signInWithApple(identityToken: token, name: name.isEmpty ? nil : name) }

        case .failure(let error):
            // The user cancelling is not an error worth reporting.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            onError("Apple sign-in didn't complete. Try email instead.")
        }
    }

    /// Google and Facebook: fetch a token through the system browser, then hand
    /// it to the same endpoint Apple's token goes to.
    private func signIn(with provider: SocialProvider) {
        guard let config = store.socialAuth else { return }

        authenticate {
            let result = try await social.token(for: provider, config: config)
            try await store.signInWithSocial(
                provider: provider, token: result.token, name: result.name
            )
        }
    }

    /// Runs a sign-in, keeping the buttons disabled for its duration and
    /// funnelling every outcome to one place.
    ///
    /// Cancellation is swallowed rather than reported: a user who dismissed the
    /// browser does not need an alert telling them what they just chose.
    private func authenticate(_ work: @escaping () async throws -> Void) {
        isAuthenticating = true
        Task {
            defer { isAuthenticating = false }
            do {
                try await work()
                Haptics.success()
            } catch let failure as SocialSignInService.Failure {
                if !failure.isCancellation {
                    onError(failure.errorDescription ?? "That sign-in didn't complete. Please try again.")
                    Haptics.error()
                }
            } catch {
                onError(error.userMessage)
                Haptics.error()
            }
        }
    }
}

extension AppStore {
    /// Whether any social provider is currently on offer — what a host screen
    /// checks before drawing the "or" rule between the social buttons and the
    /// email form.
    var hasSocialProviders: Bool {
        !(socialAuth?.availableProviders ?? []).isEmpty
    }
}
