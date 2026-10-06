import SwiftUI

/// The signed-out screen.
///
/// Where iOS fills the display with artwork, a Mac window can be 1400pt wide —
/// so the content sits in a fixed-width column, centred, the way Mail's account
/// setup and the App Store's sign-in sheet do. The illustration is the same one
/// iOS shows here, at a size a desktop window can carry without it becoming a
/// mural.
struct MacWelcomeView: View {
    @Environment(AppStore.self) private var store

    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var route: MacAuthRoute?
    /// Set when a route is opened from the password step, so the sheet starts
    /// with the address and — for a code — has already asked for one.
    @State private var routeEmail: String?
    @State private var routeSendsImmediately = false
    @State private var step: Step = .email
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    /// Email first, then the password. Asking for the address on its own lets
    /// the second step offer the right ways in for it — a password, or a code
    /// sent to that address — instead of every option at once.
    private enum Step { case email, password }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    private var canContinue: Bool { EmailRule.looksLikeAddress(email) }

    private var canSubmit: Bool {
        EmailRule.looksLikeAddress(email) && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Illustration.highFive
                    .padding(.top, 8)

                VStack(spacing: 6) {
                    Text("twodos")
                        .font(.largeTitle.weight(.bold))
                    Text(step == .email
                         ? "A shared list for two people, on every device you own."
                         : "Enter your password, or we'll email you a code instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    MacBanner(kind: .error, title: errorMessage)
                }

                switch step {
                case .email: emailStep
                case .password: passwordStep
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .animation(.default, value: step)
        .onAppear { focus = .email }
        // A sheet rather than a pushed screen: these are short errands, and a
        // Mac window that navigates away from sign-in has to grow a back button
        // the platform otherwise never needs.
        .sheet(item: $route, onDismiss: {
            routeEmail = nil
            routeSendsImmediately = false
        }) { route in
            MacAuthSheet(route: route, prefilledEmail: routeEmail, sendOnAppear: routeSendsImmediately)
        }
    }

    // MARK: - Step one

    @ViewBuilder
    private var emailStep: some View {
        TextField("Email", text: $email)
            .textContentType(.username)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($focus, equals: .email)
            .onSubmit { if canContinue { advance() } }

        Button(action: advance) {
            Text("Continue").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!canContinue)

        MacSocialSignInRow()

        Divider().padding(.vertical, 2)

        // Plain links, not buttons: on a Mac a row of filled buttons reads as
        // equally likely things to do, and these are exits from the main path.
        VStack(spacing: 6) {
            Button("Create an account") { open(.signUp) }
            Button("I was invited") { open(.completeInvite) }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    // MARK: - Step two

    @ViewBuilder
    private var passwordStep: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope").foregroundStyle(.secondary)
            Text(trimmedEmail).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Change") { goBack() }
                .buttonStyle(.link)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signing in as \(trimmedEmail)")

        SecureField("Password", text: $password)
            .textContentType(.password)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($focus, equals: .password)
            .onSubmit { if canSubmit { submit() } }

        Button(action: submit) {
            if isSubmitting {
                ProgressView().controlSize(.small)
            } else {
                Text("Sign in").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)

        // Beside the password because this is when it helps: the person who
        // cannot remember theirs is looking at the box right now. Only an
        // account that already exists is sent a code.
        Button {
            open(.otp, sendImmediately: true)
        } label: {
            Label("Sign in with a Code", systemImage: "envelope.badge")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isSubmitting)

        Button("Forgot your password?") { open(.resetPassword) }
            .buttonStyle(.link)
            .font(.callout)
    }

    private func advance() {
        guard canContinue else { return }
        errorMessage = nil
        step = .password
        // After the field exists, or there is nothing to focus yet.
        Task { @MainActor in focus = .password }
    }

    private func goBack() {
        errorMessage = nil
        password = ""
        step = .email
        Task { @MainActor in focus = .email }
    }

    private func open(_ route: MacAuthRoute, sendImmediately: Bool = false) {
        routeEmail = EmailRule.looksLikeAddress(email) ? trimmedEmail : nil
        routeSendsImmediately = sendImmediately && routeEmail != nil
        self.route = route
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await store.signIn(email: trimmedEmail, password: password)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
