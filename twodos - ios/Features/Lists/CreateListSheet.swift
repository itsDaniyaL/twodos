import SwiftUI

/// Creating a list.
///
/// Sharing is presented as an explicit choice rather than an optional email
/// field, because "leave this blank to keep it private" is easy to misread and
/// the consequence — accidentally inviting someone — is awkward to undo.
struct CreateListSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Who the list is for.
    ///
    /// Starts as `.unanswered` on purpose. This was a toggle defaulting to
    /// "off", which offers sharing without ever asking about it — and on a
    /// two-person app, the collaborator is not an advanced option you go
    /// looking for, it is half of what a list *is*. An unset choice makes it a
    /// question, and the question is cheap to answer: one tap either way.
    enum Audience: Hashable {
        case unanswered
        case personal
        case shared
    }

    @State private var label = ""
    @State private var audience: Audience = .unanswered
    /// Who to share with — an address or a handle. One field, because the
    /// server takes one field, and because asking somebody to first classify
    /// what they are about to type is a question with no purpose.
    @State private var partnerRef = ""
    @State private var isFavorite = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var isShared: Bool { audience == .shared }

    /// How the server will read what has been typed, or nil while it is empty.
    private var reference: PartnerReference? { PartnerReference(partnerRef) }

    private var canSubmit: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && audience != .unanswered
            && (!isShared || reference?.isPlausible == true)
            && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        if let errorMessage {
                            InlineBanner(kind: .error, title: errorMessage)
                        }

                        nameField
                        sharingSection
                        favoriteToggle
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("New list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        // ⌘↩ on a keyboard; the name field's own Return still
                        // submits too.
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { nameFocused = true }
            .motion(Motion.content, value: isShared)
            .motion(Motion.content, value: errorMessage)
        }
        // Tall enough that the audience question is on screen without scrolling.
        // At the old 340pt it sat below the fold, which is most of the reason it
        // never read as being asked.
        .presentationDetents([.height(isShared ? 620 : 500), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    // MARK: - Sections

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What's the list for?", text: $label)
                .font(.title3)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { if canSubmit { submit() } }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                .accessibilityLabel("List name")

            Text("Groceries, Weekend trip, Things to fix…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Who's this list for?")

            VStack(spacing: 0) {
                audienceChoice(
                    .personal,
                    icon: "person.fill",
                    title: "Just for me",
                    subtitle: "Only you can see this. You can share it later."
                )
                GlassDivider()
                audienceChoice(
                    .shared,
                    icon: "person.2.fill",
                    title: "Share with someone",
                    subtitle: "You'll both see every change straight away."
                )

                if isShared {
                    GlassDivider()
                    partnerPicker
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
        }
    }

    /// One of the two answers. A filled tick rather than a radio dot, because
    /// the row is already tappable across its whole width and a second
    /// hit-target-looking control invites a miss.
    private func audienceChoice(
        _ value: Audience,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        Button {
            withAnimation(Motion.content) { audience = value }
            Haptics.selection()
            if value == .personal { nameFocused = false }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(audience == value ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: audience == value ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(audience == value ? Color.accentColor : Color.secondary.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(Metrics.cardPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(audience == value ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var partnerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email address or @username", text: $partnerRef)
                .textContentType(.emailAddress)
                // Not the email keyboard: a handle has no `@` to reach for and
                // the prominent `.com` key is noise when typing one.
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Their email address or username")

            if !suggestedPartners.isEmpty {
                recentPartners
            }

            // The hint follows what is actually being typed, because the two
            // routes behave differently for somebody with no account and the
            // difference is not guessable. Saying both at once, permanently,
            // would be a paragraph nobody reads.
            Text(partnerHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .motion(Motion.content, value: partnerHint)
        }
        .padding(Metrics.cardPadding)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// What happens to somebody who is not on twodos yet, which is the only
    /// place the address and the handle genuinely differ.
    private var partnerHint: String {
        switch reference {
        case .email:
            "If they don't have twodos yet, we'll email them an invitation."
        case .username:
            "Usernames only reach people who already have twodos. To invite somebody new, use their email address."
        case nil:
            "Their email address, or their @username if they've chosen one."
        }
    }

    /// Anyone who can actually be invited — not blocked either way, and with
    /// a way to reach them — with the people you already share with first.
    private var suggestedPartners: [Partner] {
        store.partners
            .filter { !$0.isInBlock && !store.isBlocked($0.id) && !$0.shareReference.isEmpty }
            .sorted { $0.isAccepted && !$1.isAccepted }
    }

    /// One-tap reuse of people already shared with — most sharing is with the
    /// same one or two people, so making them tappable removes a lot of typing.
    private var recentPartners: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestedPartners) { partner in
                    Button {
                        // Their handle when they have one — shorter, and it
                        // survives them changing the address on their account.
                        partnerRef = partner.shareReference
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            AvatarView(initials: partner.initials, imageURL: partner.avatarURL, size: 22)
                            Text(partner.displayName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(partnerRef == partner.shareReference ? Color.accentColor : .primary)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var favoriteToggle: some View {
        GlassSection {
            GlassRow(
                icon: "star",
                iconTint: Brand.lime,
                title: "Add to favourites",
                subtitle: "Favourites sort above everything else."
            ) {
                Toggle("", isOn: $isFavorite)
                    .labelsHidden()
                    .onChange(of: isFavorite) { _, _ in Haptics.selection() }
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await store.createList(
                    label: label.trimmingCharacters(in: .whitespaces),
                    favorite: isFavorite,
                    partner: isShared ? reference : nil
                )
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }
}

// MARK: - Avatar

/// A person: their profile picture when they have one, initials on a stable
/// per-person colour when they do not.
///
/// Pictures come from a linked Google or Facebook account — there is no
/// upload — so plenty of people have none, and the initials are the design,
/// not a placeholder. They are also what shows while a picture loads and if
/// it fails, so a row never draws an empty circle.
struct AvatarView: View {
    let initials: String
    /// The picture. `nil` draws initials. The URL is immutable on the server —
    /// a changed picture is a new URL — so the system cache can keep it as
    /// long as it likes.
    var imageURL: URL? = nil
    var size: CGFloat = 40
    var isOnline: Bool?

    /// Hashing the initials keeps a given person the same colour everywhere.
    /// Deliberately drawn from the muted end of the palette — an avatar is an
    /// identifier, and there may be several on screen at once.
    private var tint: Color {
        let palette: [Color] = [Brand.meadow, Brand.info, Brand.apricot, Brand.violet, Brand.lime]
        // `hashValue` is seeded per launch, so it would give the same person a
        // different colour every time the app starts.
        let index = abs(initials.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[index]
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(tint.opacity(0.85))
                .frame(width: size, height: size)
                .overlay {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .overlay {
                    if let imageURL {
                        AsyncImage(url: imageURL) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .transition(.opacity)
                            }
                            // Loading and failure both leave the initials
                            // underneath showing; nothing to draw here.
                        }
                        .frame(width: size, height: size)
                        .clipShape(.circle)
                    }
                }

            if let isOnline {
                Circle()
                    .fill(isOnline ? Brand.success : Color(.systemGray3))
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                    .motion(Motion.tap, value: isOnline)
            }
        }
        .accessibilityHidden(true)
    }
}
