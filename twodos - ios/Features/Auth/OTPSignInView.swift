import SwiftUI

/// Passwordless sign-in: the server emails a one-time code.
///
/// Worth knowing: a session started this way comes back with no refresh token,
/// so it expires for good rather than renewing silently. That is a server-side
/// choice, not a bug — but it means these users are asked to sign in again
/// sooner than password users.
struct OTPSignInView: View {
    @Binding var path: NavigationPath
    @Environment(AppStore.self) private var store

    @State private var email: String
    @State private var code = ""
    @State private var codeSent = false
    @State private var isSending = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(path: Binding<NavigationPath>, prefilledEmail: String?) {
        _path = path
        _email = State(initialValue: prefilledEmail ?? TokenStore.shared.lastSignedInEmail ?? "")
    }

    var body: some View {
        AuthScaffold(
            title: codeSent ? "Enter your code" : "Sign in without a password",
            subtitle: codeSent
                ? "We sent a code to \(email). It's good for a few minutes."
                : "We'll email you a code — no password to remember.",
            errorMessage: errorMessage
        ) {
            if codeSent {
                CodeField(code: $code) { submit() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            } else {
                AuthField(title: "Email", text: $email, icon: "envelope",
                          contentType: .username, keyboard: .emailAddress,
                          submitLabel: .send,
                          validator: Validate.email,
                          onSubmit: { Task { await sendCode() } })
            }
        } actions: {
            if codeSent {
                PrimaryButton(title: "Sign in", isLoading: isSubmitting) { submit() }
                    .disabled(Validate.code(code) != nil || isSubmitting)

                ResendButton(isBusy: isSending) { await sendCode() }

                Button("Use a different email") {
                    withAnimation(Motion.content) {
                        codeSent = false
                        code = ""
                    }
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                PrimaryButton(title: "Email me a code", isLoading: isSending) {
                    Task { await sendCode() }
                }
                .disabled(!Validate.isValidEmail(email) || isSending)
            }
        }
        .navigationTitle("One-time code")
        .motion(Motion.content, value: codeSent)
    }

    private func sendCode() async {
        guard Validate.isValidEmail(email) else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            _ = try await APIClient.shared.requestOTP(email: email.trimmingCharacters(in: .whitespaces))
            Haptics.light()
            withAnimation(Motion.content) { codeSent = true }
        } catch {
            Haptics.error()
            errorMessage = error.userMessage
        }
    }

    private func submit() {
        guard Validate.code(code) == nil, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await store.signInWithOTP(
                    email: email.trimmingCharacters(in: .whitespaces),
                    code: code.trimmingCharacters(in: .whitespaces)
                )
                Haptics.success()
            } catch {
                Haptics.error()
                if error.hintsAtUnverifiedEmail {
                    path.append(AuthRoute.verifyEmail(email: email))
                } else {
                    errorMessage = error.userMessage
                    code = ""
                }
            }
        }
    }
}
