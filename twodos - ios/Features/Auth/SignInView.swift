import SwiftUI

/// Email + password sign-in.
///
/// The password field carries `.password` content type so the system password
/// manager and passkey autofill both work; on success the app calls
/// `finishAutofillContext`-equivalent behaviour implicitly by leaving the field,
/// letting iOS offer to save the credential.
struct SignInView: View {
    @Binding var path: NavigationPath
    @Environment(AppStore.self) private var store

    @State private var email = TokenStore.shared.lastSignedInEmail ?? ""
    @State private var password = ""
    @State private var isSubmitting = false
    /// A social sign-in in flight. Kept apart from `isSubmitting` because the
    /// two lock different controls: a browser round-trip should not spin the
    /// "Sign in" button, and a password submit should not grey the social row.
    @State private var isSocialSigningIn = false
    @State private var errorMessage: String?
    /// Shown once a sign-in has been rejected.
    ///
    /// An account whose email has never been verified cannot log in, and the
    /// API reports that with the *same* 401 and the same
    /// "The username or password is incorrect." message as a genuinely wrong
    /// password — the two responses are byte-identical, so there is nothing to
    /// sniff. Someone who has just signed up and typed their password correctly
    /// would otherwise sit here being told their password is wrong, with no way
    /// forward. Offering the verification route after a failure is the only
    /// honest way to cover it.
    @State private var showsRecoveryOptions = false

    private var canSubmit: Bool {
        Validate.isValidEmail(email) && !password.isEmpty && !isSubmitting && !isSocialSigningIn
    }

    var body: some View {
        AuthScaffold(
            title: "Welcome back",
            subtitle: "Sign in to pick up where you and your partner left off.",
            errorMessage: errorMessage
        ) {
            AuthField(
                title: "Email",
                text: $email,
                icon: "envelope",
                contentType: .username,
                keyboard: .emailAddress,
                validator: Validate.email
            )
            AuthField(
                title: "Password",
                text: $password,
                icon: "lock",
                contentType: .password,
                isSecure: true,
                submitLabel: .go,
                validator: { $0.isEmpty ? "Enter your password." : nil },
                onSubmit: { if canSubmit { submit() } }
            )
        } actions: {
            PrimaryButton(title: "Sign in", isLoading: isSubmitting) { submit() }
                .disabled(!canSubmit)

            // The same providers the welcome screen offers, for the person who
            // came here out of habit and only then remembered they never set a
            // password. Errors land in the scaffold's banner rather than an
            // alert so a failed social attempt reads the same way a wrong
            // password does on this screen.
            if store.hasSocialProviders {
                AuthSeparator(title: "or continue with")
                    .padding(.vertical, 2)

                SocialSignInSection(isAuthenticating: $isSocialSigningIn) { message in
                    withAnimation(Motion.content) { errorMessage = message }
                }
                .disabled(isSubmitting)
            }

            SecondaryButton(title: "Create an account") {
                path.append(AuthRoute.signUp)
            }
            .disabled(isSocialSigningIn)

            if showsRecoveryOptions {
                Button("I haven't verified my email yet") {
                    path.append(AuthRoute.verifyEmail(email: email.isEmpty ? nil : email))
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 16) {
                Button("Forgot password?") {
                    path.append(AuthRoute.resetPassword(email: email.isEmpty ? nil : email))
                }
                Text("·").foregroundStyle(.tertiary)
                Button("Email me a code") {
                    path.append(AuthRoute.otp(email: email.isEmpty ? nil : email))
                }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .navigationTitle("Sign in")
        .task {
            // Usually already cached by the welcome screen; this covers a cold
            // launch that lands here directly, or a fetch that failed there.
            if store.socialAuth == nil { await store.refreshSocialAuthConfig() }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await store.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                Haptics.success()
            } catch {
                Haptics.error()
                // The API distinguishes these cases by message text, so the app
                // routes the user onward instead of leaving them at a dead end.
                if error.hintsAtUnverifiedEmail {
                    path.append(AuthRoute.verifyEmail(email: email))
                } else if error.hintsAtPendingInvite {
                    path.append(AuthRoute.completeInvite(email: email))
                } else {
                    errorMessage = error.userMessage
                    // Offline is a network problem, not an account problem —
                    // pointing at email verification would be a red herring.
                    if case APIError.offline = error {} else {
                        withAnimation(Motion.content) { showsRecoveryOptions = true }
                    }
                }
            }
        }
    }
}
