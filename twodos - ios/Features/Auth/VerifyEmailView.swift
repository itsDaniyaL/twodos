import SwiftUI

/// Email verification after sign-up.
///
/// The email address is carried in from the previous screen, so the user only
/// has to deal with the code — but it stays editable in case they mistyped it.
struct VerifyEmailView: View {
    @Binding var path: NavigationPath

    @State private var email: String
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var isResending = false
    @State private var errorMessage: String?
    @State private var didVerify = false

    init(path: Binding<NavigationPath>, email: String?) {
        _path = path
        _email = State(initialValue: email ?? "")
    }

    private var canSubmit: Bool {
        Validate.isValidEmail(email) && Validate.code(code) == nil && !isSubmitting
    }

    var body: some View {
        AuthScaffold(
            title: didVerify ? "You're all set" : "Check your email",
            subtitle: didVerify
                ? "Your email is verified. Sign in and you're away."
                : "We sent a code to \(email.isEmpty ? "your inbox" : email). Enter it below to finish setting up.",
            errorMessage: errorMessage
        ) {
            if didVerify {
                successMark
            } else {
                CodeField(code: $code) { if canSubmit { submit() } }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                DisclosureGroup("Wrong email address?") {
                    AuthField(title: "Email", text: $email, icon: "envelope",
                              contentType: .username, keyboard: .emailAddress,
                              validator: Validate.email)
                        .padding(.top, 8)
                }
                .font(.subheadline)
                .tint(Color.accentColor)
            }
        } actions: {
            if didVerify {
                PrimaryButton(title: "Go to sign in") {
                    path = NavigationPath()
                    path.append(AuthRoute.signIn)
                }
            } else {
                PrimaryButton(title: "Verify", isLoading: isSubmitting) { submit() }
                    .disabled(!canSubmit)

                ResendButton(isBusy: isResending) { await resend() }
            }
        }
        .navigationTitle("Verify email")
        .motion(Motion.content, value: didVerify)
    }

    private var successMark: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 64))
            .foregroundStyle(Brand.success.gradient)
            .symbolEffect(.bounce, value: didVerify)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityLabel("Email verified")
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                _ = try await APIClient.shared.verifyEmail(
                    email: email.trimmingCharacters(in: .whitespaces),
                    token: code.trimmingCharacters(in: .whitespaces)
                )
                Haptics.success()
                didVerify = true
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
                code = ""
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
        _ = try? await APIClient.shared.requestEmailToken(email: email.trimmingCharacters(in: .whitespaces))
    }
}
