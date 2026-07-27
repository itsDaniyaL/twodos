import SwiftUI
import AuthenticationServices

/// The first thing a signed-out user sees.
///
/// It leads with what the app is for rather than with a form, and puts Sign in
/// with Apple first because it is the fastest route to a working account.
struct WelcomeView: View {
    /// Whether to offer Sign in with Apple at all.
    ///
    /// Currently off: the Sign in with Apple capability is not enabled on the
    /// App ID, so on a device build the flow fails after the user has already
    /// committed to it — a worse experience than not offering it. The entire
    /// implementation is kept intact behind this flag rather than deleted, so
    /// turning it back on is a one-word change once the portal is configured.
    static let isAppleSignInEnabled = false

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    @State private var path = NavigationPath()
    @State private var appleError: String?
    @State private var isAuthenticating = false
    @State private var showHero = false

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
        .alert("Couldn't sign in with Apple", isPresented: .constant(appleError != nil)) {
            Button("OK") { appleError = nil }
        } message: {
            Text(appleError ?? "")
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
        VStack(spacing: 12) {
            TwodosHero(size: 116)

            Text("twodos")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)

            Text("Shared lists for two.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .opacity(showHero ? 1 : 0)
        .offset(y: showHero ? 0 : 12)
    }

    /// Two ways in, and one quiet link for the rarer case.
    ///
    /// The old version offered four choices of equal visual weight, which asked
    /// the user to make a decision before they had any information. Sign in and
    /// sign up are the same door for most people, so they now share one button
    /// that leads to a screen where switching between the two is one tap.
    private var actions: some View {
        VStack(spacing: 10) {
            // Sign in with Apple is hidden for now: the capability is not yet
            // enabled on the App ID, so the button cannot complete on a device
            // build. Flip `isAppleSignInEnabled` once the portal is configured —
            // the credential handling below is finished and still wired up.
            if Self.isAppleSignInEnabled {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(appleButtonStyle)
                .frame(height: 50)
                .clipShape(.rect(cornerRadius: Metrics.controlRadius))
                .disabled(isAuthenticating)
                .opacity(isAuthenticating ? 0.6 : 1)
            }

            // Email is the only route while Apple is hidden, so it leads.
            PrimaryButton(title: "Continue with email", icon: "envelope") {
                path.append(AuthRoute.signIn)
            }

            Button("I was invited to a list") {
                path.append(AuthRoute.completeInvite(email: nil))
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .opacity(showHero ? 1 : 0)
        .animation(Motion.content.delay(0.25), value: showHero)
    }

    /// Apple's button should read as a system control, so it follows the
    /// system appearance rather than being pinned to black.
    private var appleButtonStyle: SignInWithAppleButton.Style {
        colorScheme == .dark ? .white : .black
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
                appleError = "Apple didn't return a usable credential. Try email instead."
                return
            }

            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")

            isAuthenticating = true
            Task {
                defer { isAuthenticating = false }
                do {
                    try await store.signInWithApple(identityToken: token, name: name.isEmpty ? nil : name)
                    Haptics.success()
                } catch {
                    appleError = error.userMessage
                    Haptics.error()
                }
            }

        case .failure(let error):
            // The user cancelling is not an error worth reporting.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appleError = "Apple sign-in didn't complete. Try email instead."
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
