import SwiftUI

/// Email, then password — or a code emailed to that address instead.
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

    /// Email first, then the password.
    ///
    /// Asking for the address on its own lets the second step offer the right
    /// ways in for it — a password, or a code sent to that address — instead of
    /// a form with every option on it at once.
    enum Step { case email, password }
    @State private var step: Step = .email

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    private var canContinue: Bool {
        Validate.isValidEmail(email) && !isSocialSigningIn
    }

    private var canSubmit: Bool {
        Validate.isValidEmail(email) && !password.isEmpty && !isSubmitting && !isSocialSigningIn
    }

    var body: some View {
        AuthScaffold(
            title: step == .email ? "Welcome back" : "Enter your password",
            subtitle: step == .email
                ? "Sign in to pick up where you and your partner left off."
                : "Or skip the password and we'll email you a code.",
            errorMessage: errorMessage
        ) {
            switch step {
            case .email:
                AuthField(
                    title: "Email",
                    text: $email,
                    icon: "envelope",
                    contentType: .username,
                    keyboard: .emailAddress,
                    submitLabel: .continue,
                    validator: Validate.email,
                    onSubmit: { if canContinue { advance() } }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))

            case .password:
                emailSummary
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        } actions: {
            switch step {
            case .email:
                emailActions
            case .password:
                passwordActions
            }
        }
        .navigationTitle("Sign in")
        .motion(Motion.content, value: step)
        .task {
            // Usually already cached by the welcome screen; this covers a cold
            // launch that lands here directly, or a fetch that failed there.
            if store.socialAuth == nil { await store.refreshSocialAuthConfig() }
        }
    }

    // MARK: - Step one

    @ViewBuilder
    private var emailActions: some View {
        PrimaryButton(title: "Continue") { advance() }
            .disabled(!canContinue)

        // The same providers the welcome screen offers, for the person who
        // came here out of habit and only then remembered they never set a
        // password. Errors land in the scaffold's banner rather than an alert
        // so a failed social attempt reads the same way a wrong password does.
        if store.hasSocialProviders {
            AuthSeparator(title: "or continue with")
                .padding(.vertical, 2)

            SocialSignInSection(isAuthenticating: $isSocialSigningIn) { message in
                withAnimation(Motion.content) { errorMessage = message }
            }
        }

        SecondaryButton(title: "Create an account") {
            path.append(AuthRoute.signUp)
        }
        .disabled(isSocialSigningIn)
    }

    // MARK: - Step two

    /// The address being signed in with, and the way back to change it.
    private var emailSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(trimmedEmail)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Change") { goBack() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signing in as \(trimmedEmail)")
    }

    @ViewBuilder
    private var passwordActions: some View {
        PrimaryButton(title: "Sign in", isLoading: isSubmitting) { submit() }
            .disabled(!canSubmit)

        // Beside the password because this is the moment it is useful: the
        // person who cannot remember theirs is looking at the box right now.
        // The code goes to this address, and only an account that already
        // exists is sent one.
        SecondaryButton(title: "Sign in with a code", icon: "envelope.badge") {
            path.append(AuthRoute.otpCode(email: trimmedEmail))
        }
        .disabled(isSubmitting)

        if showsRecoveryOptions {
            Button("I haven't verified my email yet") {
                path.append(AuthRoute.verifyEmail(email: trimmedEmail))
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        Button("Forgot password?") {
            path.append(AuthRoute.resetPassword(email: trimmedEmail))
        }
        .font(.footnote)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private func advance() {
        guard canContinue else { return }
        errorMessage = nil
        Haptics.light()
        withAnimation(Motion.content) { step = .password }
    }

    private func goBack() {
        errorMessage = nil
        password = ""
        showsRecoveryOptions = false
        withAnimation(Motion.content) { step = .email }
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
