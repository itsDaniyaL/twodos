import SwiftUI

/// The account and settings hub.
struct ProfileView: View {
    @Environment(LanguageStore.self) private var languages
    @Environment(AppStore.self) private var store
    @Environment(ThemeStore.self) private var theme

    @State private var path = NavigationPath()
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var confirmingSignOut = false
    /// Shown when the avatar is tapped with nothing to pick from.
    @State private var isPromptingForPicture = false
    @State private var isChoosingUsername = false
    /// Whether the person has waved the username highlight away.
    ///
    /// A handle is optional, so the prompt has to be dismissible — and once
    /// dismissed it must not come back on the next launch, which is why this is
    /// stored rather than held in memory. The row in the Account section stays
    /// either way, so dismissing hides a suggestion rather than a feature.
    @AppStorage("usernameHighlightDismissed") private var usernameHighlightDismissed = false

    enum Route: Hashable {
        case appearance, language, notifications, partners, security, about, deleteAccount
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 20) {
                        identityCard
                        if showsUsernameHighlight { usernameHighlight }
                        statsRow
                        settingsSection
                        accountSection
                        signOutSection
                        versionFooter
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 4)
                    .padding(.bottom, 100)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .navigationTitle("You")
            .refreshable { await store.refreshAll() }
            // The avatar's menu depends on which connected accounts have a
            // picture, which `refreshAll` does not fetch.
            .task { await store.refreshSocialLinks() }
            .sheet(isPresented: $isChoosingUsername) { UsernameSheet() }
            .alert("Add a profile picture", isPresented: $isPromptingForPicture) {
                Button("Connect an account") { path.append(Route.security) }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("twodos uses the picture from your Google or Facebook account, so partners can tell your lists apart at a glance. Connect one in Sign-in and security and it's picked up automatically.")
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .appearance: AppearanceSettingsView()
                case .language: LanguageSettingsView()
                case .notifications: NotificationSettingsView()
                case .partners: PartnersView()
                case .security: SecurityView()
                case .about: AboutView()
                case .deleteAccount: DeleteAccountView()
                }
            }
            .alert("What should we call you?", isPresented: $isEditingName) {
                TextField("Your name", text: $draftName)
                    .textContentType(.name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    Task { try? await store.updateName(trimmed) }
                }
            }
            .confirmationDialog("Sign out of twodos?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await store.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your lists stay safe — you'll just need to sign in again.")
            }
        }
    }

    // MARK: - Sections

    private var identityCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                avatarButton
                    .padding(.top, 6)

                VStack(spacing: 3) {
                    Text(store.user?.name ?? "Your account")
                        .font(.title3.weight(.semibold))
                    Text(store.user?.email ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // The handle is the thing a partner types, so it belongs
                    // where they would look for it — with the name, not buried
                    // in a settings row. Absent until claimed, and never a
                    // blank space pretending to be a field.
                    if let handle = store.user?.handle {
                        Text(handle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .textSelection(.enabled)
                            .accessibilityLabel("Username \(handle)")
                    }
                }

                if store.user?.emailVerified == false {
                    MetaChip(icon: "exclamationmark.triangle.fill",
                             text: "Email not verified",
                             tint: Brand.warning,
                             emphasised: true)
                }

                Button {
                    draftName = store.user?.name ?? ""
                    isEditingName = true
                } label: {
                    Label("Edit name", systemImage: "pencil")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(Metrics.cardPadding)
        }
        .accessibilityElement(children: .contain)
    }

    /// Tapping the picture is how it gets changed.
    ///
    /// Pictures are borrowed from connected accounts rather than uploaded, so
    /// what the tap does depends on what is connected: with a Google or
    /// Facebook account that has one, it is a menu of which to use; without,
    /// it is a short explanation and a way to the screen that connects one.
    /// Someone who signed in with Google never sees either — their picture
    /// was on from the first sign-in.
    @ViewBuilder
    private var avatarButton: some View {
        let avatar = AvatarView(
            initials: store.user?.initials ?? "?",
            imageURL: store.user?.avatarURL,
            size: 76
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
                .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                .accessibilityHidden(true)
        }

        if store.providersWithPictures.isEmpty {
            Button { isPromptingForPicture = true } label: { avatar }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a profile picture")
        } else {
            Menu {
                ForEach(store.providersWithPictures) { link in
                    Button {
                        Task { try? await store.chooseAvatar(provider: link.socialProvider) }
                    } label: {
                        Label(
                            "Use my \(link.displayName) picture",
                            systemImage: store.user?.avatarProvider == link.provider ? "checkmark" : link.icon
                        )
                    }
                }
                if store.user?.avatarUrl != nil {
                    Button {
                        Task { try? await store.chooseAvatar(provider: nil) }
                    } label: {
                        Label("Use my initials", systemImage: "textformat")
                    }
                }
                Divider()
                Button {
                    path.append(Route.security)
                } label: {
                    Label("Connected accounts…", systemImage: "link")
                }
            } label: {
                avatar
            }
            .accessibilityLabel("Change profile picture")
        }
    }

    /// Offered only to accounts that have no handle, and only until the person
    /// says no. A username earns nothing by being nagged about: email remains a
    /// first-class identity, and someone who never claims one loses no feature.
    private var showsUsernameHighlight: Bool {
        store.user != nil && store.user?.username == nil && !usernameHighlightDismissed
    }

    private var usernameHighlight: some View {
        InlineBanner(
            kind: .info,
            title: "Claim your username",
            message: "Give partners one thing to type instead of an email address they have to remember. Optional, and yours for good once chosen.",
            actionTitle: "Choose one",
            action: { isChoosingUsername = true },
            onDismiss: { withAnimation(Motion.content) { usernameHighlightDismissed = true } }
        )
    }

    /// A little at-a-glance summary. It costs nothing — the data is already
    /// loaded — and it makes the screen feel like it belongs to this person.
    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(value: store.activeLists.count, label: "Lists", icon: "checklist")
            StatTile(value: store.acceptedPartners.count,
                     label: "Partners", icon: "person.2")
            StatTile(value: openItemCount, label: "To do", icon: "circle.dashed")
        }
    }

    private var openItemCount: Int {
        store.lists.filter { !$0.archived }.reduce(0) { $0 + $1.todos.count { !$0.done } }
    }

    private var settingsSection: some View {
        GlassSection(title: "Settings") {
            GlassRow(icon: "paintbrush", title: "Appearance",
                     subtitle: "\(theme.appearance.title) · \(theme.accent.title)",
                     showsChevron: true,
                     action: { path.append(Route.appearance) })
            GlassDivider()
            GlassRow(icon: "character.bubble", title: "Language",
                     subtitle: languageSubtitle,
                     showsChevron: true,
                     action: { path.append(Route.language) })
            GlassDivider()
            GlassRow(icon: "bell.badge", title: "Notifications",
                     subtitle: "Reminders, alarms, and partner activity",
                     showsChevron: true,
                     action: { path.append(Route.notifications) })
            GlassDivider()
            GlassRow(icon: "person.2", title: "Partners",
                     subtitle: partnerSubtitle,
                     showsChevron: true,
                     action: { path.append(Route.partners) })
        }
    }

    /// The language's own name, or "System default (English)".
    private var languageSubtitle: String {
        if let name = languages.language.endonym { return name }
        return String(localized: "System default (\(languages.effectiveLanguage.endonym ?? "English"))")
    }

    private var partnerSubtitle: String {
        // Counted from the same array the Partners screen splits into
        // sections, so the two can never show different numbers.
        let active = store.acceptedPartners.count
        let pending = store.partners.count { $0.isPending && !$0.isInBlock && !store.isBlocked($0.id) }
        let blocked = store.partners.count { $0.isInBlock || store.isBlocked($0.id) }
        if active == 0 && pending == 0 && blocked == 0 { return "Nobody yet" }
        var parts = ["\(active) partner\(active == 1 ? "" : "s")"]
        if pending > 0 { parts.append("\(pending) pending") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }

    private var accountSection: some View {
        GlassSection(title: "Account") {
            // Always here, whether or not the highlight above was dismissed —
            // a prompt someone waved away should not be the only way to reach
            // the thing. Reads as a plain value once claimed, because by then
            // there is nothing left to do with it.
            GlassRow(icon: "at", title: "Username",
                     subtitle: store.user?.handle ?? "Not set yet",
                     showsChevron: store.user?.username == nil,
                     action: store.user?.username == nil ? { isChoosingUsername = true } : nil)
            GlassDivider()
            GlassRow(icon: "lock.shield", title: "Sign-in and security",
                     subtitle: "Password and connected accounts",
                     showsChevron: true,
                     action: { path.append(Route.security) })
            GlassDivider()
            GlassRow(icon: "info.circle", title: "About twodos",
                     showsChevron: true,
                     action: { path.append(Route.about) })
        }
    }

    private var signOutSection: some View {
        VStack(spacing: 12) {
            SecondaryButton(title: "Sign out", icon: "rectangle.portrait.and.arrow.right") {
                confirmingSignOut = true
            }

            Button("Delete my account") {
                path.append(Route.deleteAccount)
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(Brand.danger)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private var versionFooter: some View {
        VStack(spacing: 2) {
            Text("twodos \(Bundle.main.appVersion)")
            if store.isSocketConnected {
                Label("Live", systemImage: "bolt.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Brand.success)
            } else {
                Label("Reconnecting…", systemImage: "bolt.slash")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 12)
        .motion(Motion.fade, value: store.isSocketConnected)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let value: Int
    let label: String
    let icon: String

    var body: some View {
        GlassCard(radius: Metrics.controlRadius) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("\(value)")
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())
                Text(localizable: label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .motion(Motion.content, value: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
