import SwiftUI
import AuthenticationServices

/// The first thing a signed-out user sees.
///
/// It leads with what the app is for rather than with a form, and puts the
/// social buttons above the email route because they are the fastest way to a
/// working account — one tap, no password to invent, no verification email to
/// go and find.
///
/// Which buttons appear is the *server's* decision, delivered by
/// `/api/v1/client-config` and cached on `AppStore.socialAuth`. That replaces
/// the hardcoded flag this screen used to carry: a provider whose credentials
/// are not configured now simply never draws a button, instead of drawing one
/// that fails after the user has already committed to it.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store

    @State private var path = NavigationPath()
    @State private var socialError: String?
    @State private var isAuthenticating = false
    @State private var showHero = false
    @State private var social = SocialSignInService()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ScreenBackground(showsHorizon: true)

                // No scroll view: everything fits, which is the point. If the
                // welcome screen needs scrolling it is saying too much.
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    hero
                    Spacer(minLength: 20)
                    actions
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .signIn: SignInView(path: $path)
                case .signUp: SignUpView(path: $path)
                case .verifyEmail(let email): VerifyEmailView(path: $path, email: email)
                case .otp(let email): OTPSignInView(path: $path, prefilledEmail: email)
                case .resetPassword(let email): ResetPasswordView(path: $path, prefilledEmail: email)
                case .completeInvite(let email): CompleteInviteView(path: $path, prefilledEmail: email)
                }
            }
        }
        .onAppear {
            withAnimation(Motion.content.delay(0.05)) { showHero = true }
        }
        .task {
            // Cheap, unauthenticated, and the answer decides what this screen
            // draws — so it runs before the user has looked away from the hero.
            await store.refreshSocialAuthConfig()
        }
        .alert("Couldn't sign in", isPresented: .constant(socialError != nil)) {
            Button("OK") { socialError = nil }
        } message: {
            Text(socialError ?? "")
        }
    }

    // MARK: - Sections

    /// The whole pitch: the mark, the name, one sentence.
    ///
    /// The feature list that used to live here — four cards explaining sync,
    /// geofencing, deadlines and sharing — is gone. None of it could be acted
    /// on from this screen, and a signed-out person cannot evaluate any of it;
    /// they either have an account or they don't. It now surfaces where it is
    /// actually useful: at the point each feature is first used.
    private var hero: some View {
        VStack(spacing: 10) {
            // Two people mid-high-five says "shared lists for two" faster than
            // the sentence underneath does, and it is the one moment in the app
            // with room for a picture — every screen after this is a list.
            Image("IllustrationHighFive")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .accessibilityHidden(true)

            Text("twodos")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)

            Text("Shared lists for two.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .opacity(showHero ? 1 : 0)
        .offset(y: showHero ? 0 : 12)
    }

    /// The ways in, in descending order of how many people take them.
    ///
    /// The original version offered four choices of equal visual weight, which
    /// asked the user to decide before they had any information. Sign in and
    /// sign up are the same door for most people, so they share one button that
    /// leads to a screen where switching between the two is one tap.
    ///
    /// Weight now does the explaining: filled for the route almost everyone
    /// takes, glass for the two that some people need, and a rule between the
    /// social buttons and the rest.
    private var actions: some View {
        VStack(spacing: 10) {
            SocialSignInButtons(
                providers: providers,
                isBusy: isAuthenticating,
                onApple: handleApple,
                onProvider: signIn(with:)
            )

            if !providers.isEmpty {
                AuthSeparator()
                    .padding(.vertical, 2)
            }

            // Email stays the route that always works, whatever the server has
            // configured — it is the fallback the social buttons are measured
            // against, so it never disappears.
            PrimaryButton(title: "Continue with email", icon: "envelope") {
                path.append(AuthRoute.signIn)
            }
            .disabled(isAuthenticating)

            // Invited users mostly no longer need this: tapping any social
            // button with the invited address signs them in and the invitation
            // is already waiting. It stays for the people invited at an address
            // they cannot sign in to socially — and for them it is the *only*
            // way in, which is why it is a real button rather than the footnote
            // link it used to be.
            //
            // Glass rather than filled keeps the hierarchy honest: still
            // clearly subordinate to "Continue with email", but no longer
            // something a person has to go looking for. A route that is the
            // sole option for whoever needs it should never be the quietest
            // thing on the screen.
            SecondaryButton(title: "I was invited to a list", icon: "person.2") {
                path.append(AuthRoute.completeInvite(email: nil))
            }
            .disabled(isAuthenticating)
            .padding(.top, 4)
        }
        .opacity(showHero ? 1 : 0)
        .animation(Motion.content.delay(0.25), value: showHero)
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
                socialError = "Apple didn't return a usable credential. Try email instead."
                return
            }

            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")

            authenticate { try await store.signInWithApple(identityToken: token, name: name.isEmpty ? nil : name) }

        case .failure(let error):
            // The user cancelling is not an error worth reporting.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            socialError = "Apple sign-in didn't complete. Try email instead."
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
                    socialError = failure.errorDescription
                    Haptics.error()
                }
            } catch {
                socialError = error.userMessage
                Haptics.error()
            }
        }
    }
}

// MARK: - Routes

enum AuthRoute: Hashable {
    case signIn
    case signUp
    case verifyEmail(email: String?)
    case otp(email: String?)
    case resetPassword(email: String?)
    case completeInvite(email: String?)
}
