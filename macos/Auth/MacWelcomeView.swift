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
    @FocusState private var focus: Field?

    private enum Field { case email, password }

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
                    Text("A shared list for two people, on every device you own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    MacBanner(kind: .error, title: errorMessage)
                }

                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit { if canSubmit { submit() } }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)

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

                MacSocialSignInRow()

                Divider().padding(.vertical, 2)

                // Plain links, not buttons: on a Mac a row of four filled
                // buttons reads as four equally likely things to do, and all
                // four of these are exits from the main path.
                VStack(spacing: 6) {
                    Button("Create an account") { route = .signUp }
                    Button("Sign in with a code instead") { route = .otp }
                    Button("I was invited") { route = .completeInvite }
                    Button("Forgot your password?") { route = .resetPassword }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focus = .email }
        // A sheet rather than a pushed screen: these are four short errands,
        // and a Mac window that navigates away from sign-in has to grow a back
        // button the platform otherwise never needs.
        .sheet(item: $route) { MacAuthSheet(route: $0) }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await store.signIn(email: email.trimmingCharacters(in: .whitespaces),
                                       password: password)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
