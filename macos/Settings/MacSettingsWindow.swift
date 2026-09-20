import SwiftUI

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
    var body: some View {
        TabView {
            MacAccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            MacAppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            MacNotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            MacAboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
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

struct MacNotificationSettings: View {
    @Environment(NotificationService.self) private var notifications

    var body: some View {
        Form {
            Section {
                Text("twodos asks the system for permission to show alerts. Which kinds you receive is controlled here; whether they appear at all is controlled in System Settings.")
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
