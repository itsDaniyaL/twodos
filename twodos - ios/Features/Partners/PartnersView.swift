import SwiftUI

/// The people you share lists with, plus anyone you've blocked.
struct PartnersView: View {
    @Environment(AppStore.self) private var store

    @State private var hasLoaded = false
    @State private var reportTarget: Partner?
    @State private var blockTarget: Partner?

    private var activePartners: [Partner] {
        store.partners.filter { !store.isBlocked($0.id) }
    }

    private var blockedPartners: [Partner] {
        store.partners.filter { store.isBlocked($0.id) }
    }

    var body: some View {
        ZStack {
            ScreenBackground()
            content
        }
        .navigationTitle("Partners")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refreshPartners()
            await store.refreshBlockedUsers()
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await store.refreshPartners()
            await store.refreshBlockedUsers()
        }
        .sheet(item: $reportTarget) { partner in
            ReportSheet(partner: partner)
        }
        .confirmationDialog(
            blockTarget.map { store.isBlocked($0.id) ? "Unblock \($0.displayName)?" : "Block \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = blockTarget {
                let isBlocked = store.isBlocked(target.id)
                Button(isBlocked ? "Unblock" : "Block", role: isBlocked ? nil : .destructive) {
                    Task { await store.setBlocked(!isBlocked, userId: target.id) }
                    blockTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { blockTarget = nil }
        } message: {
            if let target = blockTarget {
                Text(store.isBlocked(target.id)
                     ? "They'll be able to share lists with you again."
                     : "\(target.displayName) won't be able to invite you to new lists. Lists you already share stay as they are.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded && store.partners.isEmpty {
            LoadingView(message: "Loading partners…")
        } else if store.partners.isEmpty {
            EmptyStateView(
                icon: "person.2",
                title: "No partners yet",
                message: "Share a list with someone and they'll appear here. You can block or report anyone from this screen."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if !activePartners.isEmpty {
                        section(title: "Sharing with", partners: activePartners, isBlocked: false)
                    }
                    if !blockedPartners.isEmpty {
                        section(title: "Blocked", partners: blockedPartners, isBlocked: true)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .motion(Motion.content, value: store.blockedUserIds)
            }
        }
    }

    private func section(title: LocalizedStringKey, partners: [Partner], isBlocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, count: partners.count)
            ForEach(partners) { partner in
                PartnerRow(
                    partner: partner,
                    isBlocked: isBlocked,
                    isOnline: store.isPartnerOnline(partner.id),
                    lastSeen: store.lastSeen[partner.id],
                    sharedListCount: store.lists.count { $0.partnerId == partner.id && !$0.archived },
                    onToggleBlock: { blockTarget = partner },
                    onReport: { reportTarget = partner }
                )
                .transition(.rowInsertion)
            }
        }
    }
}

// MARK: - Row

struct PartnerRow: View {
    let partner: Partner
    let isBlocked: Bool
    let isOnline: Bool
    let lastSeen: Date?
    let sharedListCount: Int
    let onToggleBlock: () -> Void
    let onReport: () -> Void

    var body: some View {
        GlassCard(radius: Metrics.controlRadius) {
            HStack(spacing: 14) {
                AvatarView(
                    initials: partner.initials,
                    size: 44,
                    isOnline: isBlocked ? nil : isOnline
                )
                .grayscale(isBlocked ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(partner.displayName)
                        .font(.body.weight(.medium))
                    Text(partner.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if isBlocked {
                            MetaChip(icon: "hand.raised.fill", text: "Blocked", tint: Brand.danger)
                        } else {
                            if sharedListCount > 0 {
                                MetaChip(icon: "checklist",
                                         text: "\(sharedListCount) list\(sharedListCount == 1 ? "" : "s")")
                            }
                            if partner.isPending {
                                MetaChip(icon: "clock", text: "Invite pending", tint: Brand.warning)
                            } else if isOnline {
                                MetaChip(icon: "circle.fill", text: "Online", tint: Brand.success)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                Menu {
                    Button(role: isBlocked ? nil : .destructive, action: onToggleBlock) {
                        Label(isBlocked ? "Unblock" : "Block",
                              systemImage: isBlocked ? "hand.raised.slash" : "hand.raised")
                    }
                    Button(action: onReport) {
                        Label("Report", systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Options for \(partner.displayName)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .opacity(isBlocked ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [partner.displayName, partner.email]
        if isBlocked { parts.append("Blocked") }
        else if isOnline { parts.append("Online") }
        else if let lastSeen { parts.append(Format.lastSeen(lastSeen)) }
        if sharedListCount > 0 { parts.append("\(sharedListCount) shared lists") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Report

struct ReportSheet: View {
    let partner: Partner

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var type = APIConstants.ReportType.spam
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        if didSubmit {
                            confirmation
                        } else {
                            if let errorMessage {
                                InlineBanner(kind: .error, title: errorMessage)
                            }

                            GlassSection(
                                title: "What's the problem?",
                                footer: "Reports go to the twodos team. We review every one."
                            ) {
                                ForEach(Array(APIConstants.ReportType.all.enumerated()), id: \.offset) { index, option in
                                    GlassRow(
                                        icon: type == option.value ? "largecircle.fill.circle" : "circle",
                                        title: option.title,
                                        action: {
                                            type = option.value
                                            Haptics.selection()
                                        }
                                    )
                                    if index < APIConstants.ReportType.all.count - 1 { GlassDivider() }
                                }
                            }
                            .motion(Motion.tap, value: type)

                            GlassSection(title: "Anything else? (optional)") {
                                TextField("Add any detail that would help", text: $details, axis: .vertical)
                                    .lineLimit(3...6)
                                    .padding(Metrics.cardPadding)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(didSubmit ? "Thank you" : "Report \(partner.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                if !didSubmit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit") { submit() }
                            .fontWeight(.semibold)
                            .disabled(isSubmitting)
                    }
                }
            }
            .motion(Motion.content, value: didSubmit)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(Brand.success.gradient)
                .symbolEffect(.bounce, value: didSubmit)
            Text("Report submitted")
                .font(.title3.weight(.semibold))
            Text("We'll take a look. You can also block \(partner.displayName) if you'd rather not hear from them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !store.isBlocked(partner.id) {
                SecondaryButton(title: "Block \(partner.displayName)", icon: "hand.raised") {
                    Task { await store.setBlocked(true, userId: partner.id) }
                    dismiss()
                }
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 24)
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                try await store.report(
                    userId: partner.id,
                    type: type,
                    details: details.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                Haptics.success()
                didSubmit = true
            } catch {
                Haptics.error()
                errorMessage = error.userMessage
            }
        }
    }
}
