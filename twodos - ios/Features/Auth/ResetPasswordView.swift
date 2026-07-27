import SwiftUI

/// Two-step password reset: request a code, then set a new password.
///
/// Both steps live on one screen with the second revealed in place, so the user
/// can see the email address they used while typing the code.
struct ResetPasswordView: View {
    @Binding var path: NavigationPath

    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var codeSent = false
    @State private var isSending = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didReset = false

    init(path: Binding<NavigationPath>, prefilledEmail: String?) {
        _path = path
        _email = State(initialValue: prefilledEmail ?? "")
    }

    private var canReset: Bool {
        Validate.code(code) == nil
            && Validate.isValidPassword(newPassword)
            && newPassword == confirmation
            && !isSubmitting
    }

    var body: some View {
        AuthScaffold(
            title: didReset ? "Password changed" : "Reset your password",
            subtitle: subtitle,
            errorMessage: errorMessage
        ) {
            if didReset {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Brand.success.gradient)
                    .symbolEffect(.bounce, value: didReset)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityLabel("Password changed")
            } else {
                AuthField(title: "Email", text: $email, icon: "envelope",
                          contentType: .username, keyboard: .emailAddress,
                          validator: Validate.email)
                    .disabled(codeSent)
                    .opacity(codeSent ? 0.6 : 1)

                if codeSent {
                    CodeField(code: $code)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)

                    AuthField(title: "New password", text: $newPassword, icon: "lock",
                              contentType: .newPassword, isSecure: true,
                              validator: Validate.password)

                    PasswordStrengthView(password: newPassword)

                    AuthField(title: "Confirm new password", text: $confirmation,
                              icon: "lock.rotation", contentType: .newPassword,
                              isSecure: true, submitLabel: .go,
                              validator: { value in
                                  guard !value.isEmpty else { return "Type your password again." }
                                  return value == newPassword ? nil : "These don't match."
                              },
                              onSubmit: { if canReset { reset() } })
                }
            }
        } actions: {
            if didReset {
                PrimaryButton(title: "Sign in") {
                    path = NavigationPath()
                    path.append(AuthRoute.signIn)
                }
            } else if codeSent {
                PrimaryButton(title: "Set new password", isLoading: isSubmitting) { reset() }
                    .disabled(!canReset)
                ResendButton(isBusy: isSending) { await sendCode() }
            } else {
                PrimaryButton(title: "Email me a reset code", isLoading: isSending) {
                    Task { await sendCode() }
                }
                .disabled(!Validate.isValidEmail(email) || isSending)
            }
        }
        .navigationTitle("Reset password")
        .motion(Motion.content, value: codeSent)
        .motion(Motion.content, value: didReset)
    }

    private var subtitle: String {
        if didReset { return "You can sign in with your new password now." }
        if codeSent { return "Enter the code we sent to \(email), then choose a new password." }
        return "We'll email you a code to prove it's you."
    }

    private func sendCode() async {
        guard Validate.isValidEmail(email) else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            _ = try await APIClient.shared.requestPasswordReset(
                email: email.trimmingCharacters(in: .whitespaces)
            )
            Haptics.light()
            withAnimation(Motion.content) { codeSent = true }
        } catch {
            Haptics.error()
            errorMessage = error.userMessage
        }
    }

    private func reset() {
        guard canReset else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                _ = try await APIClient.shared.resetPassword(
                    email: email.trimmingCharacters(in: .whitespaces),
                    token: code.trimmingCharacters(in: .whitespaces),
                    password: newPassword
                )
                Haptics.success()
                didReset = true
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }
}
