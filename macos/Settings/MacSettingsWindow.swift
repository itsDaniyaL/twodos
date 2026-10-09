import SwiftUI
import ServiceManagement
import CoreLocation

/// ⌘, — the preferences window.
///
/// Everything iOS keeps in its "You" tab lives here instead, which is why the
/// sidebar has only four sections. A Mac user looks for preferences in one
/// place and it is not the navigation; putting an Appearance row in a sidebar
/// beside Lists and Alarms would make it look like a fifth kind of content.
///
/// Tabs rather than a list, because that is what a Settings scene renders as
/// throughout the system.
struct MacSettingsWindow: View {
    /// Remembered, and also written by the sidebar's account row so that
    /// clicking your own name lands on Account rather than wherever the
    /// window was last left.
    @AppStorage(MacSettingsTab.storageKey) private var tab: MacSettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            MacGeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(MacSettingsTab.general)
            MacAccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(MacSettingsTab.account)
            MacSecuritySettings()
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag(MacSettingsTab.security)
            MacAppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(MacSettingsTab.appearance)
            MacNotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(MacSettingsTab.notifications)
            MacAboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(MacSettingsTab.about)
        }
        .frame(width: 560, height: 520)
    }
}

enum MacSettingsTab: String {
    case general, account, security, appearance, notifications, about

    static let storageKey = "mac.settings.tab"
}

// MARK: - General

/// Language and place reminders.
struct MacGeneralSettings: View {
    @Environment(LanguageStore.self) private var languages
    @Environment(LocationService.self) private var location

    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                // A list rather than a pop-up menu, so every language is
                // visible in its own name without opening anything.
                Picker("Language", selection: Binding(
                    get: { languages.language },
                    set: { languages.select($0) }
                )) {
                    ForEach(AppLanguage.allCases) { option in
                        if let endonym = option.endonym {
                            Text(verbatim: endonym).tag(option)
                        } else {
                            Text("System default (\(languages.effectiveLanguage.endonym ?? "English"))").tag(option)
                        }
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Language")
            } footer: {
                Text("twodos changes straight away. Keep the new language, or it switches back on its own after a few seconds.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Location access") {
                    HStack(spacing: 8) {
                        Text(locationStatus)
                            .foregroundStyle(location.isDenied ? Brand.danger : .secondary)
                        if location.authorization == .notDetermined {
                            Button("Allow…") { location.requestWhenInUse() }
                        } else if location.isDenied {
                            Button("Open System Settings…", action: MacLocationSettings.open)
                        }
                    }
                }
                Toggle(isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin)) {
                    Text("Open twodos at login")
                    Text("Place reminders only work while twodos is running. Closing the window keeps it running; this starts it when you log in.")
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(Brand.danger)
                }
            } header: {
                Text("Place reminders")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private var locationStatus: String {
        switch location.authorization {
        case .notDetermined: String(localized: "Not asked yet")
        case .denied, .restricted: String(localized: "Turned off")
        default: String(localized: "Allowed")
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = String(localized: "macOS didn't allow that. You can add twodos under System Settings → General → Login Items.")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The Location Services pane, where a denied permission is turned back on.
enum MacLocationSettings {
    static func open() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Account

struct MacAccountSettings: View {
    @Environment(AppStore.self) private var store

    @State private var name = ""
    @State private var username = ""
    @State private var isClaimingHandle = false
    @State private var message: String?
    @State private var errorMessage: String?

    private var handle: String { UsernameRules.normalize(username) }
    private var handleProblem: String? { handle.isEmpty ? nil : UsernameRules.problem(handle) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Signed in as", value: store.user?.email ?? "—")

                TextField("Name", text: $name)
                    .onSubmit {
                        Task { try? await store.updateName(name.trimmingCharacters(in: .whitespaces)) }
                    }

                // A handle is optional and permanent. Once claimed it is a
                // value to read, not a field to edit, because the server has no
                // way to change it.
                if let claimed = store.user?.handle {
                    LabeledContent("Username", value: claimed)
                } else {
                    TextField("Username", text: $username, prompt: Text("Choose one (optional)"))
                        .autocorrectionDisabled()
                    Text(handleProblem ?? "A partner can share a list with @you instead of remembering your email. It can't be changed once set.")
                        .font(.caption)
                        .foregroundStyle(handleProblem == nil ? .secondary : Color(Brand.danger))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Claim @\(handle.isEmpty ? "username" : handle)") {
                        isClaimingHandle = true
                    }
                    .disabled(handle.isEmpty || handleProblem != nil)
                }
            }

            if let message {
                Section { Text(message).foregroundStyle(Brand.success) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(Brand.danger) }
            }

            Section {
                Button("Sign Out") { Task { await store.signOut() } }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { name = store.user?.name ?? "" }
        // Permanent, so it is confirmed by name before it is sent.
        .confirmationDialog(
            "Claim @\(handle)?",
            isPresented: $isClaimingHandle,
            titleVisibility: .visible
        ) {
            Button("Claim @\(handle)") { claim() }
            Button("Let me think", role: .cancel) {}
        } message: {
            Text("This will be your username for good — it can't be changed or given up later.")
        }
    }

    private func claim() {
        Task {
            do {
                try await store.claimUsername(handle)
                message = "Your username is @\(handle)."
                errorMessage = nil
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

// MARK: - Appearance

struct MacAppearanceSettings: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        @Bindable var theme = theme
        Form {
            Picker("Appearance", selection: $theme.appearance) {
                ForEach(ThemeStore.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Accent", selection: $theme.accent) {
                ForEach(AccentTheme.allCases) { accent in
                    Text(accent.title).tag(accent)
                }
            }

            Toggle("Use list colours throughout", isOn: $theme.tintEntireCard)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Notifications

/// The same switches as the iOS notification screen. They are subtractive:
/// the system decides whether twodos may notify at all, these quiet the kinds
/// you do not want.
struct MacNotificationSettings: View {
    @Environment(NotificationSettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("What to notify me about") {
                Toggle(isOn: $settings.deadlineReminders) {
                    Text("Deadlines")
                    Text("Lists and tasks with a due date")
                }
                Toggle(isOn: $settings.alarmAlerts) {
                    Text("Alarms")
                    Text("The alarms you set in Alarms")
                }
                Toggle(isOn: $settings.locationReminders) {
                    Text("Place reminders")
                    Text("When you arrive at or leave a saved place")
                }
                Toggle(isOn: $settings.partnerActivity) {
                    Text("Partner activity")
                    Text("Invites, and changes they make to shared lists")
                }
            }

            Section("How they behave") {
                Toggle("Play a sound", isOn: $settings.playSound)
                Toggle(isOn: $settings.showWhileUsingApp) {
                    Text("Show while I'm in twodos")
                    Text("Banners appear even when the app is in front")
                }
            }

            Section {
                Text("Whether twodos may show alerts at all is controlled in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Security

/// How you get into the account, and how to leave it for good.
struct MacSecuritySettings: View {
    @Environment(AppStore.self) private var store
    @State private var social = SocialSignInService()

    @State private var message: String?
    @State private var errorMessage: String?
    @State private var connecting: SocialProvider?

    // Password
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var resetCode = ""
    @State private var resetCodeSent = false
    @State private var isWorking = false

    // Deletion
    @State private var confirmingDeletion = false
    @State private var deletionCodeSent = false
    @State private var deletionCode = ""

    private var user: CurrentUser? { store.user }
    private var hasPassword: Bool { user?.hasPassword ?? true }
    private var email: String { user?.email ?? "" }

    private var providers: [SocialProvider] {
        let offered = store.socialAuth?.macAvailableProviders ?? []
        let linked = store.socialLinks.compactMap(\.socialProvider)
        var seen = Set<SocialProvider>()
        return (offered + linked).filter { seen.insert($0).inserted }
    }

    /// The server refuses to remove the last way in.
    private var canUnlink: Bool { hasPassword || store.socialLinks.count > 1 }

    var body: some View {
        Form {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(Brand.danger) }
            } else if let message {
                Section { Text(message).foregroundStyle(Brand.success) }
            }

            passwordSection
            linkedAccountsSection
            pictureSection
            deletionSection
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .task {
            await store.refreshSocialLinks()
            if store.socialAuth == nil { await store.refreshSocialAuthConfig() }
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDeletion) {
            Button("Email Me a Code", role: .destructive) { Task { await requestDeletion() } }
        } message: {
            Text("Every list you made, and your place on every list shared with you, will be removed. This can't be undone.")
        }
    }

    // MARK: Password

    @ViewBuilder
    private var passwordSection: some View {
        Section("Password") {
            if hasPassword {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                Text(newPassword.isEmpty ? PasswordRule.text : (PasswordRule.problem(newPassword) ?? PasswordRule.text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Change Password") { Task { await changePassword() } }
                    .disabled(currentPassword.isEmpty || !PasswordRule.isValid(newPassword) || isWorking)
            } else {
                // Accounts born from a social sign-in have no password until
                // they set one, through the same emailed-code route as a reset.
                Text("You sign in with a linked account. Set a password to sign in with \(email) as well.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if resetCodeSent {
                    TextField("Code from your email", text: $resetCode)
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    Text(PasswordRule.text).font(.caption).foregroundStyle(.secondary)
                    Button("Set Password") { Task { await setPassword() } }
                        .disabled(resetCode.isEmpty || !PasswordRule.isValid(newPassword) || isWorking)
                } else {
                    Button("Email Me a Code") { Task { await sendResetCode() } }
                        .disabled(email.isEmpty || isWorking)
                }
            }
        }
    }

    // MARK: Linked accounts

    private var linkedAccountsSection: some View {
        Section("Sign-in methods") {
            LabeledContent("Email and password") {
                Text(hasPassword ? email : String(localized: "Not set up"))
                    .foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                let link = store.socialLinks.first { $0.socialProvider == provider }
                LabeledContent {
                    if let link {
                        Button("Unlink") { Task { await store.unlinkSocial(provider: link.provider) } }
                            .disabled(!canUnlink)
                            .help(canUnlink ? "" : "This is your only way in. Set a password first.")
                    } else if connecting == provider {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Connect") { connect(provider) }
                            .disabled(connecting != nil)
                    }
                } label: {
                    Text(provider.displayName)
                    Text(link.map { $0.hasPicture ? "\($0.providerEmail) · has your picture" : $0.providerEmail }
                         ?? String(localized: "Not connected"))
                }
            }
        }
    }

    // MARK: Picture

    @ViewBuilder
    private var pictureSection: some View {
        if !store.providersWithPictures.isEmpty {
            Section("Profile picture") {
                Picker("Show", selection: Binding(
                    get: { user?.avatarProvider ?? "" },
                    set: { value in
                        Task {
                            do {
                                try await store.chooseAvatar(provider: SocialProvider(rawValue: value.lowercased()))
                            } catch {
                                errorMessage = error.userMessage
                            }
                        }
                    }
                )) {
                    Text("Initials").tag("")
                    ForEach(store.providersWithPictures) { link in
                        Text("From \(link.displayName)").tag(link.provider)
                    }
                }
            }
        }
    }

    // MARK: Deletion

    private var deletionSection: some View {
        Section("Delete account") {
            if deletionCodeSent {
                Text("We've emailed a code to \(email). Enter it to delete your account for good.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Code from your email", text: $deletionCode)
                HStack {
                    Button("Keep My Account") {
                        deletionCodeSent = false
                        deletionCode = ""
                    }
                    Spacer()
                    Button("Delete Everything", role: .destructive) { Task { await completeDeletion() } }
                        .disabled(deletionCode.isEmpty || isWorking)
                }
            } else {
                Button("Delete Account…", role: .destructive) { confirmingDeletion = true }
                    .disabled(email.isEmpty)
            }
        }
    }

    // MARK: Actions

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do { try await work() } catch { errorMessage = error.userMessage }
    }

    private func changePassword() async {
        await run {
            try await store.changePassword(current: currentPassword, new: newPassword)
            currentPassword = ""
            newPassword = ""
            message = String(localized: "Your password has been changed.")
        }
    }

    private func sendResetCode() async {
        await run {
            _ = try await APIClient.shared.requestPasswordReset(email: email)
            resetCodeSent = true
            message = String(localized: "We've sent a code to \(email).")
        }
    }

    private func setPassword() async {
        await run {
            _ = try await APIClient.shared.resetPassword(email: email, token: resetCode, password: newPassword)
            await store.refreshUser()
            resetCodeSent = false
            resetCode = ""
            newPassword = ""
            message = String(localized: "Password set. You can now sign in with \(email).")
        }
    }

    private func connect(_ provider: SocialProvider) {
        guard let config = store.socialAuth else { return }
        connecting = provider
        errorMessage = nil
        message = nil
        Task {
            defer { connecting = nil }
            do {
                let token: String
                if provider == .apple {
                    token = try await social.appleIdentityTokenViaBridge(config: config).token
                } else {
                    token = try await social.token(for: provider, config: config).token
                }
                try await store.linkSocial(provider: provider, token: token)
                message = String(localized: "\(provider.displayName) is connected.")
            } catch let failure as SocialSignInService.Failure {
                if !failure.isCancellation {
                    errorMessage = failure.errorDescription ?? String(localized: "That didn't complete. Please try again.")
                }
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func requestDeletion() async {
        await run {
            try await store.requestAccountDeletion(email: email)
            deletionCodeSent = true
        }
    }

    private func completeDeletion() async {
        await run {
            try await store.completeAccountDeletion(email: email, token: deletionCode)
        }
    }
}

// MARK: - About

struct MacAboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("twodos").font(.title2.weight(.semibold))
            Text(version).font(.callout).foregroundStyle(.secondary)

            Link("Privacy Policy", destination: URL(string: "https://twodos.app/privacy")!)
            Link("Terms & Conditions", destination: URL(string: "https://twodos.app/terms")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }
}
