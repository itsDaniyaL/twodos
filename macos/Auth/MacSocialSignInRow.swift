import SwiftUI
import AuthenticationServices

/// Continue with Apple, Google or Facebook.
///
/// All three run the same flows as iOS — `ASWebAuthenticationSession` for
/// Google and Facebook, Apple's own sheet for Apple — and all three work on the
/// Mac unchanged. The only platform difference is the presentation anchor,
/// which `SocialSignInService` resolves to an `NSWindow` here.
///
/// Which buttons appear is the server's call, read from `client-config`: a
/// provider with no credentials configured reports itself disabled, and a
/// button that cannot complete costs more trust than a missing one costs
/// convenience.
struct MacSocialSignInRow: View {
    @Environment(AppStore.self) private var store
    @State private var social = SocialSignInService()

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            if let config = store.socialAuth, hasAnyProvider(config) {
                HStack(spacing: 8) {
                    Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                }

                if config.apple?.enabled == true {
                    button("Continue with Apple", systemImage: "apple.logo") { await signInWithApple() }
                }
                if config.google?.enabled == true {
                    button("Continue with Google", systemImage: "globe") { await signIn(with: .google) }
                }
                if config.facebook?.enabled == true {
                    button("Continue with Facebook", systemImage: "person.2.fill") { await signIn(with: .facebook) }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Brand.danger)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .task { await store.refreshSocialAuthConfig() }
    }

    /// Nothing to draw when the operator has every provider switched off — the
    /// divider and the "or" would then introduce an empty space.
    private func hasAnyProvider(_ config: SocialAuthConfig) -> Bool {
        config.apple?.enabled == true
            || config.google?.enabled == true
            || config.facebook?.enabled == true
    }

    private func button(_ title: String, systemImage: String, run: @escaping () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isAuthenticating)
    }

    private func signIn(with provider: SocialProvider) async {
        guard let config = store.socialAuth else { return }
        await authenticate {
            let result = try await social.token(for: provider, config: config)
            try await store.signInWithSocial(provider: provider, token: result.token, name: result.name)
        }
    }

    private func signInWithApple() async {
        await authenticate {
            let result = try await social.appleIdentityToken()
            try await store.signInWithApple(identityToken: result.token, name: result.name)
        }
    }

    /// Cancellation is swallowed rather than reported: somebody who closed the
    /// browser window does not need to be told what they just chose.
    private func authenticate(_ work: () async throws -> Void) async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }
        do {
            try await work()
        } catch is CancellationError {
            return
        } catch {
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            errorMessage = error.userMessage
        }
    }
}
