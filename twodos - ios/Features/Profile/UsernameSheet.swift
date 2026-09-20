import SwiftUI

/// Claiming the account's handle.
///
/// A handle is **optional and permanent**, and both halves shape this screen.
/// Optional, so nothing here is a gate — the sheet is reached from a highlight
/// the user can dismiss and a row they can ignore, and email keeps working as
/// identity forever. Permanent, so the confirmation is not ceremony: the server
/// has no change endpoint, and somebody who claims `jhon_smth` at two in the
/// morning needs support to unstick them.
///
/// There is no as-you-type availability check, deliberately. The endpoint that
/// would answer sits behind the auth rate limiter — ten calls per quarter of an
/// hour — so checking per keystroke would lock the user out mid-word. Instead
/// the format is checked locally against the server's own rule, the suggestions
/// arrive already filtered to handles that are free, and the claim itself
/// reports `USERNAME_TAKEN` without taking anything. A refused claim costs
/// nothing; only a successful one is irreversible, and that is the one behind
/// the confirmation.
struct UsernameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var suggestions: [String] = []
    @State private var isSubmitting = false
    @State private var isConfirming = false
    @State private var errorMessage: String?

    private var normalised: String {
        draft.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var canSubmit: Bool {
        Validate.isValidUsername(normalised) && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            AuthScaffold(
                title: "Choose your username",
                subtitle: "A username is how a partner finds you without knowing which email address you use this month. It's optional — and it can't be changed once it's set.",
                errorMessage: errorMessage
            ) {
                AuthField(
                    title: "username",
                    text: $draft,
                    icon: "at",
                    // Deliberately no content type. `.username` would put the
                    // password manager's saved sign-in names in the QuickType
                    // bar, and this is not a sign-in field — it is a name being
                    // invented, and nothing AutoFill knows about is a candidate.
                    contentType: nil,
                    keyboard: .asciiCapable,
                    autocapitalization: .never,
                    autocorrectionDisabled: true,
                    submitLabel: .done,
                    validator: { Validate.username($0.lowercased()) },
                    onSubmit: { if canSubmit { isConfirming = true } }
                )

                Text(Validate.usernameRules)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggestions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        // Wraps rather than scrolls sideways: on a Mac or an
                        // iPad there is width to spare, and a horizontal
                        // scroller is a gesture a mouse handles badly.
                        FlowLayout(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                SuggestionChip(
                                    verbatim: "@\(suggestion)",
                                    isSelected: normalised == suggestion
                                ) {
                                    draft = suggestion
                                    errorMessage = nil
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Said before the button, not after the fact. This is the one
                // field in the app the user can never correct themselves.
                InlineBanner(
                    kind: .warning,
                    title: "This is permanent",
                    message: "Usernames can't be changed or reused later. Pick one you'll still want in a year."
                )
            } actions: {
                PrimaryButton(title: "Claim this username", isLoading: isSubmitting) {
                    isConfirming = true
                }
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .task { suggestions = await store.usernameSuggestions() }
            .confirmationDialog(
                "Claim @\(normalised)?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Claim @\(normalised)") { submit() }
                Button("Let me think", role: .cancel) {}
            } message: {
                Text("This will be your username for good — it can't be changed or given up later.")
            }
            .motion(Motion.content, value: suggestions)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func submit() {
        guard canSubmit else { return }
        let claim = normalised
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await store.claimUsername(claim)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                // The server distinguishes taken, reserved and malformed, and
                // each message names what to do about it, so it is shown as
                // sent rather than flattened into "that didn't work".
                errorMessage = error.userMessage
            }
        }
    }
}

// MARK: - Flow layout

/// Lays chips out left to right and wraps them, the way tags want to behave.
///
/// `LazyVGrid` cannot do this — its columns are fixed widths, and a handle is
/// as long as it is. This is the smallest layout that does the job.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth,
                      height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
