import SwiftUI

/// Finishing an account that was created *by an invitation* rather than by
/// signing up.
///
/// When someone shares a list with an address that has no account, the API
/// creates a stub user and emails them a token. Registering normally with that
/// address fails with "you were invited to the platform" — this screen is where
/// that dead end leads instead.
struct CompleteInviteView: View {
    @Binding var path: NavigationPath

    @State private var email: String
    @State private var code = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var isResending = false
    @State private var errorMessage: String?
    @State private var didComplete = false

    init(path: Binding<NavigationPath>, prefilledEmail: String?) {
        _path = path
        _email = State(initialValue: prefilledEmail ?? "")
    }

    private var canSubmit: Bool {
        Validate.isValidEmail(email)
            && Validate.code(code) == nil
            && Validate.isValidPassword(password)
            && !isSubmitting
    }

    var body: some View {
        AuthScaffold(
            title: didComplete ? "You're in" : "Finish setting up",
            subtitle: didComplete
                ? "Your account is ready. Sign in to see the list you were invited to."
                : "Someone shared a list with you. Enter the code from that email and pick a password.",
            errorMessage: errorMessage
        ) {
            if didComplete {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 64))
                    .foregroundStyle(Brand.success.gradient)
                    .symbolEffect(.bounce, value: didComplete)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityLabel("Account ready")
            } else {
                AuthField(title: "Email", text: $email, icon: "envelope",
                          contentType: .username, keyboard: .emailAddress,
                          validator: Validate.email)

                CodeField(code: $code)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                AuthField(title: "Choose a password", text: $password, icon: "lock",
                          contentType: .newPassword, isSecure: true, submitLabel: .go,
                          validator: Validate.password,
                          onSubmit: { if canSubmit { submit() } })

                PasswordStrengthView(password: password)
            }
        } actions: {
            if didComplete {
                PrimaryButton(title: "Sign in") {
                    path = NavigationPath()
                    path.append(AuthRoute.signIn)
                }
            } else {
                PrimaryButton(title: "Finish setting up", isLoading: isSubmitting) { submit() }
                    .disabled(!canSubmit)

                ResendButton(title: "Resend invite email", isBusy: isResending) {
                    await resend()
                }
            }
        }
        .navigationTitle("Complete invite")
        .motion(Motion.content, value: didComplete)
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                _ = try await APIClient.shared.completeInvite(
                    email: email.trimmingCharacters(in: .whitespaces),
                    token: code.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                Haptics.success()
                didComplete = true
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }

    private func resend() async {
        guard Validate.isValidEmail(email) else {
            errorMessage = "Enter a valid email address first."
            return
        }
        isResending = true
        defer { isResending = false }
        _ = try? await APIClient.shared.requestInviteToken(
            email: email.trimmingCharacters(in: .whitespaces)
        )
    }
}
