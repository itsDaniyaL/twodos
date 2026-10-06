import SwiftUI

/// Read-only details about a list: when it was made, who it's shared with, and
/// where the invite stands.
struct ListInfoSheet: View {
    let listId: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var list: TodoList? { store.list(id: listId) }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                if let list {
                    ScrollView {
                        VStack(spacing: 18) {
                            summary(list)
                            details(list)
                            if !list.isEffectivelyPersonal(currentUserId: store.currentUserId) {
                                sharing(list)
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("About this list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    /// A progress ring is more legible at a glance than "4 of 9 done", and it
    /// gives the sheet an anchor.
    private func summary(_ list: TodoList) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(list.tint.color.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(list.progress, 0.001))
                    .stroke(list.tint.color,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .motion(Motion.content, value: list.progress)
                VStack(spacing: 0) {
                    Text("\(Int(list.progress * 100))%")
                        .font(.title2.weight(.bold))
                        .contentTransition(.numericText())
                    Text("done").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 108, height: 108)
            .padding(.top, 8)

            Text(list.label)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(Format.progress(done: list.completedCount, total: list.totalCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(list.label), \(Format.progressAccessible(done: list.completedCount, total: list.totalCount))")
    }

    private func details(_ list: TodoList) -> some View {
        GlassSection(title: "Details") {
            if let created = list.createdAt {
                InfoRow(icon: "calendar", label: "Created", value: Format.fullDateTime(created))
                GlassDivider()
            }
            if let updated = list.effectiveUpdatedAt {
                InfoRow(icon: "clock.arrow.circlepath", label: "Last change", value: Format.relative(updated))
                GlassDivider()
            }
            InfoRow(
                icon: "flag",
                label: "Priority",
                value: list.priority?.title ?? "Normal"
            )
            if let deadline = list.doBefore {
                GlassDivider()
                InfoRow(
                    icon: "calendar.badge.clock",
                    label: "Deadline",
                    value: Format.fullDateTime(deadline),
                    valueTint: Format.deadlineTint(deadline)
                )
            }
            if list.hasLocation {
                GlassDivider()
                InfoRow(
                    icon: list.trigger.icon,
                    label: "Location",
                    value: list.locationName ?? "Saved place"
                )
            }
        }
    }

    private func sharing(_ list: TodoList) -> some View {
        let counterpart = store.counterpart(for: list)
        let person = counterpart?.partner
        let invite = store.sentInvite(forList: list.id)
        let isPending = counterpart?.isPending ?? list.isPendingInvite

        return GlassSection(title: "Shared with") {
            HStack(spacing: 12) {
                AvatarView(
                    initials: person?.initials ?? "@",
                    imageURL: person?.avatarURL,
                    size: 44,
                    isOnline: counterpart?.state == .accepted ? store.isPartnerOnline(person?.id) : nil
                )
                VStack(alignment: .leading, spacing: 2) {
                    // Never "someone": the name if the app knows it, otherwise
                    // the address the invitation went to, otherwise what is
                    // actually going on.
                    Text(person?.displayName ?? counterpart?.name ?? counterpart?.statusText ?? "")
                        .font(.body.weight(.medium))
                    if let detail = secondaryLine(person: person, invite: invite) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                MetaChip(
                    icon: counterpart?.icon ?? "checkmark.circle.fill",
                    text: counterpart?.badge ?? String(localized: "Accepted"),
                    tint: counterpart?.state == .accepted ? Brand.success
                        : isPending ? Brand.warning : Brand.danger,
                    emphasised: true
                )
            }
            .padding(Metrics.cardPadding)

            if let counterpart, counterpart.state != .accepted {
                GlassDivider()
                InfoRow(icon: "info.circle", label: "Status", value: counterpart.statusText)
            }

            if let invite, invite.invitee.hasAccount == false {
                GlassDivider()
                InfoRow(icon: "person.crop.circle.badge.plus", label: "Account",
                        value: String(localized: "Not on twodos yet"))
            }

            // Only an invitation to an address with no account ever expires;
            // one to an existing user waits indefinitely, so no countdown.
            if isPending, let expiry = invite?.expiresAt ?? list.inviteExpiresAt {
                GlassDivider()
                InfoRow(
                    icon: "hourglass",
                    label: "Invite expires",
                    value: expiry < .now
                        ? "Expired — the list will be removed"
                        : "\(Format.fullDateTime(expiry)) (\(Format.relative(expiry)))",
                    valueTint: expiry.timeIntervalSinceNow < 86_400 * 2 ? Brand.warning : nil
                )
            }
        }
    }

    /// The handle or address under the name, whichever is not already the
    /// headline.
    private func secondaryLine(person: Partner?, invite: SentInvite?) -> String? {
        if let person {
            if let handle = person.handle, person.displayName != handle { return handle }
            if !person.email.isEmpty, person.displayName != person.email { return person.email }
            return nil
        }
        return invite?.invitee.email
    }
}

/// A label/value pair.
struct InfoRow: View {
    let icon: String
    let label: String
    let value: String
    var valueTint: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(localizable: label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(valueTint ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
