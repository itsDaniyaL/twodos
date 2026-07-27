import SwiftUI

/// Password change and connected sign-in methods.
struct SecurityView: View {
    @Environment(AppStore.self) private var store

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var message: (kind: InlineBanner.Kind, text: String)?
    @State private var hasLoadedLinks = false

    private var canSave: Bool {
        !currentPassword.isEmpty
            && Validate.isValidPassword(newPassword)
            && newPassword == confirmation
            && newPassword != currentPassword
            && !isSaving
    }

    var body: some View {
        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(spacing: 20) {
                    if let message {
                        InlineBanner(kind: message.kind, title: message.text)
                    }

                    changePassword
                    connectedAccounts
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Sign-in and security")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoadedLinks else { return }
            hasLoadedLinks = true
            await store.refreshSocialLinks()
        }
        .motion(Motion.content, value: message?.text)
    }

    // MARK: - Password

    private var changePassword: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Change password")

            VStack(spacing: 12) {
                AuthField(title: "Current password", text: $currentPassword,
                          icon: "lock", contentType: .password, isSecure: true)
                AuthField(title: "New password", text: $newPassword,
                          icon: "lock.rotation", contentType: .newPassword, isSecure: true,
                          validator: Validate.password)
                PasswordStrengthView(password: newPassword)
                AuthField(title: "Confirm new password", text: $confirmation,
                          icon: "checkmark.shield", contentType: .newPassword, isSecure: true,
                          submitLabel: .go,
                          validator: { value in
                              guard !value.isEmpty else { return "Type it again." }
                              return value == newPassword ? nil : "These don't match."
                          },
                          onSubmit: { if canSave { save() } })

                PrimaryButton(title: "Update password", isLoading: isSaving) { save() }
                    .disabled(!canSave)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Social

    private var connectedAccounts: some View {
        GlassSection(
            title: "Connected accounts",
            footer: "Signing in with Apple links to the same twodos account as your email address."
        ) {
            if store.socialLinks.isEmpty {
                GlassRow(
                    icon: "link",
                    title: "Nothing connected",
                    subtitle: "You sign in with your email and password."
                )
            } else {
                ForEach(Array(store.socialLinks.enumerated()), id: \.element.id) { index, link in
                    GlassRow(
                        icon: link.icon,
                        title: link.displayName,
                        subtitle: "\(link.providerEmail) · linked \(Format.relative(link.linkedAt))"
                    ) {
                        Button("Unlink") {
                            Task { await store.unlinkSocial(provider: link.provider) }
                        }
                        .font(.footnote.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.danger)
                    }
                    if index < store.socialLinks.count - 1 { GlassDivider() }
                }
            }
        }
    }

    // MARK: - Actions

    private func save() {
        guard canSave else { return }
        isSaving = true
        message = nil

        Task {
            defer { isSaving = false }
            do {
                try await store.changePassword(current: currentPassword, new: newPassword)
                Haptics.success()
                message = (.success, "Your password has been changed.")
                currentPassword = ""
                newPassword = ""
                confirmation = ""
            } catch {
                Haptics.error()
                message = (.error, error.userMessage as String? ?? "Couldn't change your password.")
            }
        }
    }
}
