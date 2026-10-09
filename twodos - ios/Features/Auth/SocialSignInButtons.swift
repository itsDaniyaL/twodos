import AuthenticationServices
import SwiftUI

/// The row of social sign-in buttons, drawn only for the providers the server
/// says are actually usable.
///
/// Each provider's button follows that provider's brand requirements, which is
/// not a stylistic choice: Apple, Google and Meta all publish sign-in button
/// guidelines, and shipping a recoloured approximation is a review risk as much
/// as a recognition one. So Apple's button is the system control, Google's is
/// white with the four-colour mark at the documented proportions, and
/// Facebook's is Meta's blue. They agree on height, radius and typography so
/// the stack still reads as one set of controls rather than three logos.
struct SocialSignInButtons: View {
    /// Providers to offer, in order. Empty renders nothing at all — including
    /// the divider, so a server with no social providers configured shows a
    /// plain email screen with no leftover scaffolding.
    var providers: [SocialProvider]
    var isBusy: Bool
    /// Apple is handled separately: its credential arrives through the system
    /// button's own completion handler rather than through a browser.
    var onApple: (Result<ASAuthorization, Error>) -> Void
    var onProvider: (SocialProvider) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !providers.isEmpty {
            VStack(spacing: 10) {
                ForEach(providers) { provider in
                    button(for: provider)
                }
            }
            .disabled(isBusy)
            .opacity(isBusy ? 0.6 : 1)
        }
    }

    @ViewBuilder
    private func button(for provider: SocialProvider) -> some View {
        switch provider {
        case .apple:
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                onApple(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: Self.buttonHeight)
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))

        case .google:
            SocialButton(
                title: "Continue with Google",
                foreground: Color(light: 0x1F1F1F, dark: 0xE3E3E3),
                background: Color(light: 0xFFFFFF, dark: 0x131314),
                border: Color(light: 0xDADCE0, dark: 0x8E918F)
            ) {
                // Google's mark is supplied as artwork rather than drawn: its
                // four colours and geometry are trademarked and must not be
                // approximated.
                Image("GoogleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } action: {
                onProvider(.google)
            }

        case .facebook:
            // The neutral surface Google's button uses: Meta's blue circle
            // mark is made for a light or dark surface, and on a blue fill it
            // would disappear into the button.
            SocialButton(
                title: "Continue with Facebook",
                foreground: Color(light: 0x1F1F1F, dark: 0xE3E3E3),
                background: Color(light: 0xFFFFFF, dark: 0x131314),
                border: Color(light: 0xDADCE0, dark: 0x8E918F)
            ) {
                // Supplied as artwork for the same reason as Google's: the
                // mark's gradient and geometry belong to Meta.
                Image("FacebookLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            } action: {
                onProvider(.facebook)
            }
        }
    }

    fileprivate static let buttonHeight: CGFloat = 50
}

// MARK: - Shared button shell

/// One provider button: a mark, a label, and nothing else.
///
/// The mark and the label are centred together as one group, which is how
/// Apple's system button lays itself out — so the three buttons in the stack
/// share one silhouette rather than two. Google's and Meta's guidelines both
/// permit this arrangement alongside the leading-pinned one.
private struct SocialButton<Mark: View>: View {
    var title: LocalizedStringKey
    var foreground: Color
    var background: Color
    var border: Color
    @ViewBuilder var mark: () -> Mark
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                mark()
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: SocialSignInButtons.buttonHeight)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: Metrics.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.controlRadius)
                    .strokeBorder(border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        // The mark is decorative once the label says the same thing.
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Divider

/// The "or" rule between the social buttons and the email form.
struct AuthSeparator: View {
    var title: LocalizedStringKey = "or"

    var body: some View {
        HStack(spacing: 12) {
            line
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
    }
}
