import SwiftUI

/// One list on the home screen.
///
/// The card is deliberately information-dense but ranked: name and progress
/// first, then only the metadata that actually applies. A personal list with no
/// deadline shows two lines; a shared, urgent, geofenced list shows five. The
/// Flutter version always reserved space for every field, which made simple
/// lists look cluttered.
struct ListCard: View {
    let list: TodoList
    let partner: Partner?
    let currentUserId: String?
    let matchedID: String
    let namespace: Namespace.ID
    let onOpen: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(ThemeStore.self) private var theme
    @State private var showingOptions = false

    private var isPersonal: Bool { list.isEffectivelyPersonal(currentUserId: currentUserId) }

    var body: some View {
        Button(action: {
            Haptics.light()
            onOpen()
        }) {
            GlassCard(
                tint: list.tint.color,
                // The colour is always present now; the preference decides
                // whether it washes the card or merely warms it.
                tintStrength: theme.tintEntireCard ? 0.26 : 0.11,
                interactive: true
            ) {
                HStack(alignment: .top, spacing: 14) {
                    colorTile
                    VStack(alignment: .leading, spacing: 8) {
                        titleRow
                        progressRow
                        metadataRow
                    }
                    Spacer(minLength: 0)
                }
                .padding(Metrics.cardPadding)
            }
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: matchedID, in: namespace)
        .contextMenu { contextMenu } preview: { preview }
        .swipeActions(edge: .trailing) { }
        .sheet(isPresented: $showingOptions) {
            ListOptionsSheet(listId: list.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the list")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Pieces

    /// A solid block of the list's colour, carrying the progress ring.
    ///
    /// This replaced a 6pt rail. A hairline down the edge is enough to *tell*
    /// two lists apart once you already know the colours, but it is not enough
    /// to recognise a list by colour while scanning — which is the entire point
    /// of letting people choose one. A filled tile makes the colour the second
    /// thing you see after the name, and still carries completion in the ring
    /// so nothing was traded away for the prominence.
    private var colorTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(list.tint.color)

            Circle()
                .stroke(.white.opacity(0.32), lineWidth: 3)
                .frame(width: 26, height: 26)

            // Nothing done yet draws no arc at all. Trimming to a hair instead
            // leaves the round cap painting a lone white dot on the track,
            // which reads as a rendering fault rather than as "empty".
            if list.progress > 0 {
                Circle()
                    .trim(from: 0, to: list.progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(-90))
                    .motion(Motion.content, value: list.progress)
            }

            if list.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 46, height: 46)
        // The tile is a solid colour block, so it needs to hold its shape
        // against whatever the glass behind it is refracting.
        .shadow(color: list.tint.color.opacity(0.35), radius: 5, y: 2)
        .motion(Motion.delight, value: list.isComplete)
        .accessibilityHidden(true)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(list.label)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if list.favorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.lime)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }

            if list.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.success)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)
        }
        .motion(Motion.tap, value: list.favorite)
        .motion(Motion.delight, value: list.isComplete)
    }

    private var progressRow: some View {
        Text(Format.progress(done: list.completedCount, total: list.totalCount))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .motion(Motion.content, value: list.completedCount)
    }

    /// Only the chips that apply, in order of urgency.
    private var metadataRow: some View {
        HStack(spacing: 6) {
            if let deadline = list.doBefore {
                MetaChip(
                    icon: Format.deadlineIcon(deadline),
                    text: Format.deadline(deadline),
                    tint: Format.deadlineTint(deadline),
                    emphasised: true
                )
            }

            if let priority = list.priority, priority == .urgent {
                MetaChip(icon: priority.icon, text: priority.title, tint: Brand.danger)
            }

            if list.hasLocation {
                MetaChip(
                    icon: "mappin.and.ellipse",
                    text: list.locationName ?? list.trigger.shortTitle,
                    tint: Brand.info
                )
            }

            if !isPersonal {
                MetaChip(
                    icon: list.isPendingInvite ? "clock.badge.questionmark" : "person.2.fill",
                    text: partnerLabel,
                    tint: list.isPendingInvite ? Brand.warning : .secondary
                )
            }

            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private var partnerLabel: String {
        let who = partner?.displayName ?? partner?.email
        if list.isPendingInvite { return who.map { "Waiting · \($0)" } ?? "Invite pending" }
        if store.isPartnerOnline(list.partnerId) { return who.map { "\($0) · online" } ?? "Shared" }
        return who ?? "Shared"
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            Task { await store.toggleFavorite(id: list.id) }
        } label: {
            Label(list.favorite ? "Remove from favourites" : "Add to favourites",
                  systemImage: list.favorite ? "star.slash" : "star")
        }

        Button {
            showingOptions = true
        } label: {
            Label("List settings", systemImage: "slider.horizontal.3")
        }

        if list.todos.contains(where: \.done) {
            Button {
                Task { await store.clearCompleted(listId: list.id) }
            } label: {
                Label("Clear completed", systemImage: "eraser")
            }
        }

        Button {
            Task { await store.archiveList(id: list.id, archived: !list.archived) }
        } label: {
            Label(list.archived ? "Move back to Lists" : "Archive",
                  systemImage: list.archived ? "tray.and.arrow.up" : "archivebox")
        }

        Divider()

        Button(role: .destructive) {
            Task { await store.deleteList(id: list.id) }
        } label: {
            Label("Delete list", systemImage: "trash")
        }
    }

    /// A peek at the first few items, so the context menu answers "what's in
    /// here?" without opening the list.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(list.label).font(.headline)
            if list.todos.isEmpty {
                Text("No items yet").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(list.todos.prefix(6)) { todo in
                    HStack(spacing: 8) {
                        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                            .font(.footnote)
                            .foregroundStyle(todo.done ? Brand.success : .secondary)
                        Text(todo.title)
                            .font(.subheadline)
                            .strikethrough(todo.done, color: .secondary)
                            .foregroundStyle(todo.done ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
                if list.todos.count > 6 {
                    Text("+ \(list.todos.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(width: 280, alignment: .leading)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts = [list.label]
        parts.append(Format.progressAccessible(done: list.completedCount, total: list.totalCount))
        if list.favorite { parts.append("Favourite") }
        if let deadline = list.doBefore { parts.append("Due \(Format.deadline(deadline))") }
        if let priority = list.priority { parts.append("\(priority.title) priority") }
        if list.hasLocation { parts.append("Has a location reminder") }
        if !isPersonal { parts.append(partnerLabel) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Invite card

/// A list someone shared that the user has not yet answered.
struct InviteCard: View {
    let list: TodoList
    let fromName: String?

    @Environment(AppStore.self) private var store
    @State private var isResponding = false

    var body: some View {
        GlassCard(tint: Brand.violet, radius: Metrics.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.title3)
                        .foregroundStyle(Brand.violet)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.label).font(.headline)
                        Text(fromName.map { "\($0) wants to share this with you" }
                             ?? "Someone wants to share this with you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if let expiry = list.inviteExpiresAt {
                    MetaChip(
                        icon: "hourglass",
                        text: "Expires \(Format.relative(expiry))",
                        tint: expiry.timeIntervalSinceNow < 86_400 * 2 ? Brand.warning : .secondary
                    )
                }

                HStack(spacing: 10) {
                    Button("Decline") { respond(accept: false) }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                    Button("Accept") { respond(accept: true) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.regular)
                    Spacer(minLength: 0)
                }
                .disabled(isResponding)
                .opacity(isResponding ? 0.5 : 1)
            }
            .padding(Metrics.cardPadding)
        }
        .accessibilityElement(children: .contain)
    }

    private func respond(accept: Bool) {
        isResponding = true
        Task {
            await store.respondToInvite(listId: list.id, accept: accept)
            isResponding = false
        }
    }
}
