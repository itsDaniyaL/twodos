import SwiftUI

/// Account deletion — deliberately the slowest flow in the app.
///
/// Two steps, an emailed code, and a plain statement of what disappears. This
/// is one of the few places where friction is the correct design.
struct DeleteAccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var isSending = false
    @State private var isDeleting = false
    @State private var confirmingFinal = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(spacing: 20) {
                    warning

                    if let errorMessage {
                        InlineBanner(kind: .error, title: errorMessage)
                    }

                    if codeSent {
                        codeStep
                    } else {
                        emailStep
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if email.isEmpty { email = store.user?.email ?? "" } }
        .confirmationDialog(
            "Delete your twodos account?",
            isPresented: $confirmingFinal,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { performDeletion() }
            Button("Keep my account", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Your lists, items, alarms, and sharing history are all removed.")
        }
        .motion(Motion.content, value: codeSent)
    }

    private var warning: some View {
        GlassCard(tint: Brand.danger) {
            VStack(alignment: .leading, spacing: 12) {
                Label("This is permanent", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Brand.danger)

                VStack(alignment: .leading, spacing: 8) {
                    bullet("Every list you created is deleted, for you and for anyone you shared it with.")
                    bullet("Lists your partners created are removed from your account; they keep theirs.")
                    bullet("Alarms, reminders, and location pins go with it.")
                    bullet("There is no way to get any of it back.")
                }
            }
            .padding(Metrics.cardPadding)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Brand.danger.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.top, 7)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emailStep: some View {
        VStack(spacing: 14) {
            AuthField(title: "Confirm your email", text: $email, icon: "envelope",
                      contentType: .username, keyboard: .emailAddress,
                      validator: Validate.email)

            PrimaryButton(title: "Email me a deletion code", isLoading: isSending) {
                Task { await sendCode() }
            }
            .disabled(!Validate.isValidEmail(email) || email != store.user?.email || isSending)

            if !email.isEmpty && email != store.user?.email {
                Text("That doesn't match the email on this account.")
                    .font(.caption)
                    .foregroundStyle(Brand.warning)
            }
        }
    }

    private var codeStep: some View {
        VStack(spacing: 14) {
            Text("Enter the code we sent to \(email).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            CodeField(code: $code)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

            PrimaryButton(title: "Delete my account", isLoading: isDeleting, role: .destructive) {
                confirmingFinal = true
            }
            .disabled(Validate.code(code) != nil || isDeleting)

            ResendButton(title: "Resend code", isBusy: isSending) { await sendCode() }

            Button("Cancel — keep my account") { dismiss() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
        }
    }

    private func sendCode() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            try await store.requestAccountDeletion(email: email.trimmingCharacters(in: .whitespaces))
            Haptics.warning()
            withAnimation(Motion.content) { codeSent = true }
        } catch {
            Haptics.error()
            errorMessage = error.userMessage
        }
    }

    private func performDeletion() {
        isDeleting = true
        errorMessage = nil

        Task {
            defer { isDeleting = false }
            do {
                try await store.completeAccountDeletion(
                    email: email.trimmingCharacters(in: .whitespaces),
                    token: code.trimmingCharacters(in: .whitespaces)
                )
                // The store signs out on success; the root view takes over.
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }
}
