import SwiftUI

/// The four errands that hang off the sign-in screen.
///
/// One sheet with four modes rather than four sheets: they share the same
/// column width, the same field styling and the same "one email, one code, one
/// password" rhythm, and splitting them into separate files made four copies of
/// that scaffolding on iOS.
enum MacAuthRoute: String, Identifiable {
    case signUp, otp, resetPassword, completeInvite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signUp: "Create your account"
        case .otp: "Sign in with a code"
        case .resetPassword: "Reset your password"
        case .completeInvite: "Finish setting up"
        }
    }

    var subtitle: String {
        switch self {
        case .signUp: "You'll be able to share lists as soon as you're in."
        case .otp: "We'll email you a code. No password needed."
        case .resetPassword: "We'll email you a code, then you choose a new password."
        case .completeInvite: "Somebody shared a list with your address. Choose a password to claim it."
        }
    }
}

struct MacAuthSheet: View {
    let route: MacAuthRoute

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var isSending = false
    /// Whether the emailed code has been asked for yet. The code-bearing flows
    /// are two steps, and showing the code field before anything has been sent
    /// invites somebody to sit waiting for a mail nobody requested.
    @State private var codeSent = false
    @State private var message: String?
    @State private var errorMessage: String?

    private var handle: String { UsernameRules.normalize(username) }
    private var handleProblem: String? { handle.isEmpty ? nil : UsernameRules.problem(handle) }

    private var canSubmit: Bool {
        guard !isSubmitting, EmailRule.looksLikeAddress(email) else { return false }
        switch route {
        case .signUp:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && PasswordRule.isValid(password)
                && handleProblem == nil
        case .otp:
            return codeSent && !code.isEmpty
        case .resetPassword, .completeInvite:
            return codeSent && !code.isEmpty && PasswordRule.isValid(password)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(route.title).font(.title2.weight(.semibold))
                Text(route.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 16)

            if route == .completeInvite {
                // The same drawing iOS shows here. Somebody arriving by an
                // invitation did not choose to be on this screen, and the
                // picture is most of what makes it read as a welcome rather
                // than a form.
                Illustration.handsSpark
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }

            if let errorMessage {
                MacBanner(kind: .error, title: errorMessage)
                    .padding(.bottom, 12)
            } else if let message {
                MacBanner(kind: .success, title: message)
                    .padding(.bottom, 12)
            }

            VStack(spacing: 10) {
                if route == .signUp {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                }

                TextField("Email", text: $email)
                    .textContentType(.username)
                    .disabled(codeSent && route != .signUp)

                if route == .signUp {
                    TextField("Username (optional)", text: $username)
                        .autocorrectionDisabled()
                    Text(handleProblem ?? "How a partner finds you instead of typing your email. You can skip this and choose one later.")
                        .font(.caption)
                        .foregroundStyle(handleProblem == nil ? .secondary : Color(Brand.danger))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if codeSent && route != .signUp {
                    TextField("Code from your email", text: $code)
                }

                if route != .otp {
                    SecureField(route == .signUp ? "Password" : "New password", text: $password)
                        .textContentType(.newPassword)
                    Text(PasswordRule.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)

            Spacer(minLength: 16)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if route != .signUp {
                    Button(codeSent ? "Send again" : "Send code") {
                        Task { await sendCode() }
                    }
                    .disabled(isSending || !EmailRule.looksLikeAddress(email))
                }

                Button(primaryTitle) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 420)
        .frame(minHeight: route == .completeInvite ? 560 : 420)
    }

    private var primaryTitle: String {
        switch route {
        case .signUp: "Create account"
        case .otp: "Sign in"
        case .resetPassword: "Set new password"
        case .completeInvite: "Claim my account"
        }
    }

    /// Step one of the two-step flows: ask the server to mail a code.
    private func sendCode() async {
        isSending = true
        errorMessage = nil
        message = nil
        defer { isSending = false }
        do {
            let address = email.trimmingCharacters(in: .whitespaces)
            switch route {
            case .otp:            _ = try await APIClient.shared.requestOTP(email: address)
            case .resetPassword:  _ = try await APIClient.shared.requestPasswordReset(email: address)
            case .completeInvite: _ = try await APIClient.shared.requestEmailToken(email: address)
            case .signUp:         return
            }
            codeSent = true
            message = "We've sent a code to \(address)."
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        let address = email.trimmingCharacters(in: .whitespaces)

        Task {
            defer { isSubmitting = false }
            do {
                switch route {
                case .signUp:
                    // The handle is best-effort: the server drops one already
                    // taken and creates the account anyway, and says nothing
                    // about it. Nothing here claims it was reserved — the
                    // Settings highlight re-offers it to anyone who arrives
                    // without one.
                    _ = try await APIClient.shared.register(
                        name: name.trimmingCharacters(in: .whitespaces),
                        email: address,
                        password: password,
                        username: handle.isEmpty ? nil : handle
                    )
                    message = "Account created. Check \(address) for the code, then sign in."
                    dismiss()

                case .otp:
                    try await store.signInWithOTP(email: address, code: code)
                    dismiss()

                case .resetPassword:
                    _ = try await APIClient.shared.resetPassword(email: address, token: code, password: password)
                    try await store.signIn(email: address, password: password)
                    dismiss()

                case .completeInvite:
                    _ = try await APIClient.shared.completeInvite(email: address, token: code, password: password)
                    try await store.signIn(email: address, password: password)
                    dismiss()
                }
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
