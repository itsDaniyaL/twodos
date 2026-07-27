import SwiftUI

/// Account creation.
///
/// The password requirements are shown up front and tick off live as they are
/// met, rather than being revealed as errors after a failed submit.
struct SignUpView: View {
    @Binding var path: NavigationPath
    @Environment(AppStore.self) private var store

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var passwordsMatch: Bool { !confirmation.isEmpty && password == confirmation }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && Validate.isValidEmail(email)
            && Validate.isValidPassword(password)
            && passwordsMatch
            && !isSubmitting
    }

    var body: some View {
        AuthScaffold(
            title: "Create your account",
            subtitle: "You'll be able to share lists as soon as you're in.",
            errorMessage: errorMessage
        ) {
            AuthField(title: "Your name", text: $name, icon: "person",
                      contentType: .name,
                      validator: { Validate.required($0, "name") })

            AuthField(title: "Email", text: $email, icon: "envelope",
                      contentType: .username, keyboard: .emailAddress,
                      validator: Validate.email)

            AuthField(title: "Password", text: $password, icon: "lock",
                      contentType: .newPassword, isSecure: true,
                      validator: Validate.password)

            PasswordStrengthView(password: password)

            AuthField(title: "Confirm password", text: $confirmation, icon: "lock.rotation",
                      contentType: .newPassword, isSecure: true, submitLabel: .go,
                      validator: { value in
                          guard !value.isEmpty else { return "Type your password again." }
                          return value == password ? nil : "These don't match."
                      },
                      onSubmit: { if canSubmit { submit() } })
        } actions: {
            PrimaryButton(title: "Create account", isLoading: isSubmitting) { submit() }
                .disabled(!canSubmit)

            Button("I already have an account") {
                path.append(AuthRoute.signIn)
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Sign up")
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)

        Task {
            defer { isSubmitting = false }
            do {
                _ = try await APIClient.shared.register(
                    name: name.trimmingCharacters(in: .whitespaces),
                    email: trimmedEmail,
                    password: password
                )
                Haptics.success()
                path.append(AuthRoute.verifyEmail(email: trimmedEmail))
            } catch {
                Haptics.error()
                if error.hintsAtPendingInvite {
                    // This address was invited by a partner rather than
                    // registered — a different flow entirely.
                    path.append(AuthRoute.completeInvite(email: trimmedEmail))
                } else {
                    errorMessage = error.userMessage
                }
            }
        }
    }
}

/// Live password requirements. Showing the rules as a checklist that fills in
/// turns "your password is invalid" into "here's what's left".
struct PasswordStrengthView: View {
    let password: String

    private var rules: [(label: String, met: Bool)] {
        [
            ("At least 8 characters", password.count >= 8),
            ("A number", password.rangeOfCharacter(from: .decimalDigits) != nil),
            ("A symbol", password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil)
        ]
    }

    var body: some View {
        if !password.isEmpty {
            HStack(spacing: 14) {
                ForEach(rules, id: \.label) { rule in
                    HStack(spacing: 4) {
                        Image(systemName: rule.met ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(rule.met ? Brand.success : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(rule.label)
                            .font(.caption2)
                            .foregroundStyle(rule.met ? Brand.success : .secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .motion(Motion.tap, value: password)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Password requirements")
            .accessibilityValue(rules.filter(\.met).map(\.label).joined(separator: ", ") + " met")
        }
    }
}
