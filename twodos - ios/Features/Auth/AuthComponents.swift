import SwiftUI

// MARK: - Field validation

/// Input rules shared by every auth form.
///
/// Validation messages appear only *after* a field has been touched and left,
/// never while the user is mid-word — nothing is more irritating than being told
/// your email is invalid after typing two characters of it.
enum Validate {
    static func email(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Enter your email address." }
        // Deliberately permissive: the server is the real authority, and an
        // over-strict regex rejects valid addresses.
        let pattern = #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return "That doesn't look like an email address."
        }
        return nil
    }

    static func isValidEmail(_ value: String) -> Bool { email(value) == nil }

    static let passwordRules = "At least 8 characters, with a number and a symbol."

    static func password(_ value: String) -> String? {
        guard !value.isEmpty else { return "Enter a password." }
        guard value.count >= 8 else { return "Use at least 8 characters." }
        guard value.rangeOfCharacter(from: .decimalDigits) != nil else {
            return "Include at least one number."
        }
        guard value.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil else {
            return "Include at least one symbol."
        }
        return nil
    }

    static func isValidPassword(_ value: String) -> Bool { password(value) == nil }

    static func required(_ value: String, _ label: String) -> String? {
        value.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter your \(label.lowercased())." : nil
    }

    /// Emailed tokens are alphanumeric and of no fixed length, so this only
    /// checks that *something* plausible was entered. The server is the
    /// authority on whether a token is valid — rejecting locally on a guessed
    /// format would lock users out of codes that are perfectly fine.
    static func code(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter the code from your email." }
        guard trimmed.count >= 4 else { return "That code looks too short." }
        return nil
    }
}

// MARK: - Auth text field

/// A form field with glass styling, inline validation, and the right keyboard
/// and AutoFill hints so the system password manager can do its job.
struct AuthField: View {
    var title: String
    @Binding var text: String
    var icon: String
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var isSecure: Bool = false
    var submitLabel: SubmitLabel = .next
    var validator: ((String) -> String?)?
    var onSubmit: (() -> Void)?

    @State private var hasBeenEdited = false
    @State private var revealPassword = false
    @FocusState private var isFocused: Bool

    private var error: String? {
        guard hasBeenEdited, !isFocused else { return nil }
        return validator?(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .frame(width: 20)
                    .motion(Motion.tap, value: isFocused)
                    .accessibilityHidden(true)

                Group {
                    if isSecure && !revealPassword {
                        SecureField(title, text: $text)
                    } else {
                        TextField(title, text: $text)
                    }
                }
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .autocorrectionDisabled(keyboard == .emailAddress || isSecure)
                .submitLabel(submitLabel)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

                if isSecure {
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassEffect(
                .regular.tint(error != nil ? Brand.danger.opacity(0.12) : .clear),
                in: .rect(cornerRadius: Metrics.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .strokeBorder(
                        error != nil ? Brand.danger.opacity(0.6)
                                     : (isFocused ? Color.accentColor.opacity(0.7) : .clear),
                        lineWidth: 1.5
                    )
            }
            .motion(Motion.tap, value: isFocused)
            .motion(Motion.tap, value: error)
            .onChange(of: isFocused) { _, focused in
                if !focused && !text.isEmpty { hasBeenEdited = true }
                if focused { hasBeenEdited = true }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.danger)
                    .padding(.leading, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - One-time code field

/// Entry for the tokens the API emails out.
///
/// Those tokens are **alphanumeric and of no fixed length**, so this is a single
/// wide field rather than a row of fixed digit boxes: boxes would silently
/// truncate a longer token and a number pad would make a token containing
/// letters impossible to type at all.
///
/// It still behaves like a code field where it counts — monospaced and
/// letter-spaced so characters are easy to check against the email, `oneTimeCode`
/// content type so AutoFill and the keyboard's code suggestion work, and no
/// autocorrect or capitalisation to mangle the input.
struct CodeField: View {
    @Binding var code: String
    /// Purely cosmetic: how many character slots to size the field for.
    var expectedLength: Int = 6
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            TextField("Paste or type your code", text: $code)
                .textContentType(.oneTimeCode)
                // `.asciiCapable` keeps the full alphabet available while
                // dropping emoji and other keyboards that can't appear in a token.
                .keyboardType(.asciiCapable)
                // Case is left exactly as typed. The server may well treat the
                // token as case-sensitive, and silently upper-casing it would
                // turn a valid code into a rejected one.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textCase(nil)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .tracking(4)
                .multilineTextAlignment(.center)
                .focused($isFocused)
                .submitLabel(.go)
                .onSubmit { onSubmit?() }
                .onChange(of: code) { _, newValue in
                    // Emailed tokens never contain whitespace, and pasting from
                    // a mail client routinely drags some along.
                    let cleaned = newValue.filter { !$0.isWhitespace && !$0.isNewline }
                    if cleaned != newValue { code = cleaned }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
                }
                .motion(Motion.tap, value: isFocused)
                .frame(minWidth: CGFloat(expectedLength) * 26)

            Text("Copy it exactly as it appears in the email — codes can contain letters as well as numbers.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .onAppear { isFocused = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verification code")
        .accessibilityValue(
            // Spelled out one character at a time — VoiceOver reads "A1B2" as a
            // word otherwise, which is useless for checking against an email.
            code.isEmpty ? "Empty" : code.map(String.init).joined(separator: " ")
        )
    }
}

// MARK: - Resend countdown

/// A "Resend code" control that becomes a countdown after use.
///
/// Rate-limiting the button in the UI is kinder than letting the user tap it
/// five times and then discover the server refused — and it makes the wait feel
/// intentional rather than broken.
struct ResendButton: View {
    var title: String = "Resend code"
    var cooldown: TimeInterval = 30
    var isBusy: Bool
    var action: () async -> Void

    @State private var remaining: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isBusy {
                ProgressView().controlSize(.small)
            } else if remaining > 0 {
                Text("Resend in \(Int(remaining))s")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(countsDown: true))
                    .motion(Motion.fade, value: remaining)
            } else {
                Button(title) {
                    Task {
                        await action()
                        startCountdown()
                    }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .onDisappear { timerTask?.cancel() }
    }

    private func startCountdown() {
        remaining = cooldown
        timerTask?.cancel()
        timerTask = Task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                remaining = max(0, remaining - 1)
            }
        }
    }
}

// MARK: - Auth screen scaffold

/// The shared frame for every auth screen: a heading, a subtitle, the form, and
/// the actions pinned to the bottom above the keyboard.
struct AuthScaffold<Fields: View, Actions: View>: View {
    var title: String
    var subtitle: String
    var errorMessage: String?
    @ViewBuilder var fields: Fields
    @ViewBuilder var actions: Actions

    var body: some View {
        ZStack {
            ScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    if let errorMessage {
                        InlineBanner(kind: .error, title: errorMessage)
                            .transition(.banner)
                    }

                    VStack(spacing: 14) { fields }

                    VStack(spacing: 12) { actions }
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .motion(Motion.content, value: errorMessage)
        }
        .toolbarTitleDisplayMode(.inline)
    }
}
