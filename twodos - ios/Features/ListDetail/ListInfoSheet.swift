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
        let partner = store.partner(id: list.partnerId)
        let isPending = list.isPendingInvite

        return GlassSection(title: "Shared with") {
            HStack(spacing: 12) {
                AvatarView(
                    initials: partner?.initials ?? "?",
                    size: 44,
                    isOnline: isPending ? nil : store.isPartnerOnline(list.partnerId)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(partner?.displayName ?? "Invited person")
                        .font(.body.weight(.medium))
                    Text(partner?.email ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                MetaChip(
                    icon: isPending ? "clock" : "checkmark.circle.fill",
                    text: isPending ? "Pending" : "Accepted",
                    tint: isPending ? Brand.warning : Brand.success,
                    emphasised: true
                )
            }
            .padding(Metrics.cardPadding)

            if isPending, let expiry = list.inviteExpiresAt {
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
            Text(label)
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
