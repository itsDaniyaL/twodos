import SwiftUI

/// Every way into the account, and the password.
///
/// ## One account, several doors
/// The server keys accounts on the verified email address: signing in with
/// Google, Apple or Facebook lands on the account that address already has,
/// and an account born social can add a password. This screen is where the
/// person sees all of that in one place — which doors are open, which could
/// be — and where a picture comes from, since pictures are borrowed from the
/// providers listed here.
///
/// Apple only ever appears on Apple platforms: the native sheet is the whole
/// point, and this file is compiled into the iOS target alone (the Mac build
/// is the iPad app). Android offers Google and Facebook.
struct SecurityView: View {
    @Environment(AppStore.self) private var store

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var message: (kind: InlineBanner.Kind, text: String)?
    @State private var hasLoadedLinks = false
    /// Which provider a Connect tap is mid-flight for, so the row shows it.
    @State private var connecting: SocialProvider?
    @State private var settingPassword = false
    @State private var social = SocialSignInService()

    private var user: CurrentUser? { store.user }
    private var hasPassword: Bool { user?.hasPassword ?? true }

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

                    waysToSignIn
                    if hasPassword {
                        changePassword
                    } else {
                        addPassword
                    }
                    if !store.providersWithPictures.isEmpty {
                        pictureSource
                    }
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
            // The provider buttons depend on what the server offers.
            if store.socialAuth == nil { await store.refreshSocialAuthConfig() }
        }
        .sheet(isPresented: $settingPassword) {
            SetPasswordSheet(email: user?.email ?? "") {
                message = (.success, "Password set. You can sign in with your email now.")
            }
        }
        .motion(Motion.content, value: message?.text)
        .motion(Motion.content, value: store.socialLinks)
        .motion(Motion.content, value: hasPassword)
    }

    // MARK: - Ways to sign in

    /// Email first, then the providers in the order the server lists them,
    /// then any linked provider the server has since switched off — still
    /// shown, because it is still linked and can still be removed.
    private var waysToSignIn: some View {
        GlassSection(
            title: "Ways to sign in",
            footer: "Each of these opens the same account. Your lists, partners and alarms are the same whichever you use."
        ) {
            emailRow
            ForEach(displayedProviders) { provider in
                GlassDivider()
                providerRow(provider)
            }
        }
    }

    private var displayedProviders: [SocialProvider] {
        let offered = store.socialAuth?.availableProviders ?? []
        let linked = store.socialLinks.compactMap(\.socialProvider)
        var seen = Set<SocialProvider>()
        return (offered + linked).filter { seen.insert($0).inserted }
    }

    private var emailRow: some View {
        GlassRow(
            icon: "envelope",
            iconTint: hasPassword ? Brand.success : nil,
            title: "Email and password",
            subtitle: hasPassword
                ? (user?.email ?? "Linked")
                : "Not set up — set a password to sign in with \(user?.email ?? "your email")"
        ) {
            if hasPassword {
                linkedMark
            } else {
                Button("Set up") { settingPassword = true }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: SocialProvider) -> some View {
        let link = store.socialLinks.first { $0.socialProvider == provider }
        let isConnecting = connecting == provider
        let subtitle: String = {
            guard let link else { return "Not connected" }
            var parts = [link.providerEmail]
            if link.hasPicture { parts.append("has your picture") }
            return parts.joined(separator: " · ")
        }()

        GlassRow(
            icon: icon(for: provider),
            iconTint: link == nil ? nil : Brand.success,
            title: provider.displayName,
            subtitle: subtitle
        ) {
            if let link {
                Button("Unlink") {
                    Task { await unlink(link) }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Brand.danger)
                .disabled(!canUnlink)
                .opacity(canUnlink ? 1 : 0.4)
            } else if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect") { connect(provider) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(connecting != nil)
            }
        }
    }

    /// The server refuses to remove the last way in; greying the button out
    /// says so before the tap rather than after.
    private var canUnlink: Bool {
        hasPassword || store.socialLinks.count > 1
    }

    private var linkedMark: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Brand.success)
            .accessibilityLabel("Linked")
    }

    private func icon(for provider: SocialProvider) -> String {
        switch provider {
        case .apple: "apple.logo"
        case .google: "g.circle"
        case .facebook: "f.circle"
        }
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

    /// For an account that was born social. A password is optional — the
    /// provider keeps working — but it is the way in on a device where that
    /// provider is not signed in, and the only way to unlink the last one.
    private var addPassword: some View {
        GlassSection(
            title: "Password",
            footer: "You signed up with \(originDescription). A password is optional, but it lets you sign in with just your email on any device."
        ) {
            GlassRow(
                icon: "key",
                title: "Set a password",
                subtitle: "We'll email a code to \(user?.email ?? "your address") to confirm it's you",
                showsChevron: true,
                action: { settingPassword = true }
            )
        }
    }

    private var originDescription: String {
        SocialProvider(rawValue: user?.authProvider ?? "")?.displayName ?? "a connected account"
    }

    // MARK: - Picture

    /// Which connected account the picture comes from. Only drawn when at
    /// least one of them has a picture; the profile screen's avatar offers the
    /// same choice, this is the settings-shaped version of it.
    private var pictureSource: some View {
        GlassSection(
            title: "Profile picture",
            footer: "Your picture comes from a connected account. Partners see it next to the lists you share."
        ) {
            ForEach(Array(store.providersWithPictures.enumerated()), id: \.element.id) { index, link in
                let isCurrent = user?.avatarProvider == link.provider
                GlassRow(
                    icon: link.icon,
                    title: "Use my \(link.displayName) picture",
                    subtitle: isCurrent ? "In use" : nil,
                    action: { Task { await choosePicture(link.socialProvider) } }
                ) {
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("In use")
                    }
                }
                if index < store.providersWithPictures.count - 1 { GlassDivider() }
            }
            if user?.avatarUrl != nil {
                GlassDivider()
                GlassRow(
                    icon: "textformat",
                    title: "Use my initials instead",
                    action: { Task { await choosePicture(nil) } }
                )
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

    /// Runs the provider's own flow, then attaches the result to *this*
    /// account. The server adopts the provider's picture as part of linking
    /// if the account had none, which is why an email-only account is sent
    /// here when it reaches for one.
    private func connect(_ provider: SocialProvider) {
        guard let config = store.socialAuth else { return }
        connecting = provider
        message = nil
        Task {
            defer { connecting = nil }
            do {
                let token: String
                switch provider {
                case .apple:
                    token = try await social.appleIdentityToken().token
                case .google, .facebook:
                    token = try await social.token(for: provider, config: config).token
                }
                try await store.linkSocial(provider: provider, token: token)
                Haptics.success()
                message = (.success, "\(provider.displayName) is connected.")
            } catch let failure as SocialSignInService.Failure {
                if !failure.isCancellation {
                    Haptics.error()
                    message = (.error, failure.errorDescription ?? "That didn't complete. Please try again.")
                }
            } catch {
                Haptics.error()
                message = (.error, error.userMessage)
            }
        }
    }

    private func unlink(_ link: SocialLink) async {
        message = nil
        await store.unlinkSocial(provider: link.provider)
        Haptics.light()
    }

    private func choosePicture(_ provider: SocialProvider?) async {
        message = nil
        do {
            try await store.chooseAvatar(provider: provider)
            Haptics.selection()
        } catch {
            Haptics.error()
            message = (.error, error.userMessage)
        }
    }
}

// MARK: - Set a password

/// The reset-password flow, from inside a signed-in session.
///
/// The server has one way to give an account its first password — the same
/// code-by-email reset an email account uses — and it is deliberately reused:
/// proving control of the inbox is the right bar for adding a whole new way
/// into the account. The code is requested on appear, so the sheet opens
/// already waiting for it.
private struct SetPasswordSheet: View {
    let email: String
    var onDone: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var isSending = false
    @State private var isSubmitting = false
    @State private var sent = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        Validate.code(code) == nil
            && Validate.isValidPassword(newPassword)
            && newPassword == confirmation
            && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            AuthScaffold(
                title: "Set a password",
                subtitle: sent
                    ? "We've emailed a code to \(email). Enter it with the password you'd like."
                    : "Sending a code to \(email)…",
                errorMessage: errorMessage
            ) {
                CodeField(code: $code)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                AuthField(title: "New password", text: $newPassword, icon: "lock",
                          contentType: .newPassword, isSecure: true,
                          validator: Validate.password)
                PasswordStrengthView(password: newPassword)
                AuthField(title: "Confirm password", text: $confirmation, icon: "checkmark.shield",
                          contentType: .newPassword, isSecure: true,
                          submitLabel: .go,
                          validator: { value in
                              guard !value.isEmpty else { return "Type it again." }
                              return value == newPassword ? nil : "These don't match."
                          },
                          onSubmit: { if canSubmit { submit() } })
            } actions: {
                PrimaryButton(title: "Set password", isLoading: isSubmitting) { submit() }
                    .disabled(!canSubmit || !sent)
                ResendButton(isBusy: isSending) { await sendCode() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await sendCode() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func sendCode() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            _ = try await APIClient.shared.requestPasswordReset(email: email)
            sent = true
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                _ = try await APIClient.shared.resetPassword(email: email, token: code, password: newPassword)
                await store.refreshUser()
                Haptics.success()
                onDone()
                dismiss()
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }
}
