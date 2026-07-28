import SwiftUI

/// The notification inbox — everything the app has told the user about,
/// grouped by day.
struct ActivityView: View {
    @Environment(AppStore.self) private var store

    @State private var hasLoaded = false
    @State private var openListId: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                content
            }
            .navigationTitle("Activity")
            .toolbar {
                if store.unreadNotificationCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await store.markAllNotificationsRead() }
                            Haptics.light()
                        } label: {
                            Label("Mark all as read", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .refreshable { await store.refreshNotifications() }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await store.refreshNotifications()
            }
            .navigationDestination(item: $openListId) { id in
                ListDetailView(listId: id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded && store.notificationFeed.isEmpty {
            LoadingView(message: "Loading activity…")
        } else if store.notificationFeed.isEmpty {
            EmptyStateView(
                icon: "bell",
                title: "Nothing yet",
                message: "Invitations, alarms, and changes your partner makes will show up here."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedByDay, id: \.key) { group in
                        Section {
                            VStack(spacing: 8) {
                                ForEach(group.items) { notification in
                                    NotificationRow(notification: notification) {
                                        open(notification)
                                    }
                                    .transition(.rowInsertion)
                                }
                            }
                        } header: {
                            SectionLabel(title: LocalizedStringKey(group.key))
                                .padding(.vertical, 6)
                                .background(.bar.opacity(0.001))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .motion(Motion.content, value: store.notificationFeed.map(\.id))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    // MARK: - Grouping

    private struct DayGroup {
        let key: String
        let items: [AppNotification]
    }

    /// "Today" / "Yesterday" / a date, rather than a wall of identical rows.
    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let sorted = store.notificationFeed.sorted { $0.createdAt > $1.createdAt }

        var order: [String] = []
        var buckets: [String: [AppNotification]] = [:]

        for notification in sorted {
            let key: String
            // Localised here rather than at the label, because the same string
            // is the bucket key — translating it twice would split one day into
            // two headings.
            if calendar.isDateInToday(notification.createdAt) {
                key = String(localized: "Today")
            } else if calendar.isDateInYesterday(notification.createdAt) {
                key = String(localized: "Yesterday")
            } else {
                key = notification.createdAt.formatted(.dateTime.day().month(.wide).year())
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(notification)
        }

        return order.map { DayGroup(key: $0, items: buckets[$0] ?? []) }
    }

    private func open(_ notification: AppNotification) {
        Task { await store.markNotificationRead(id: notification.id) }
        if let listId = notification.listId, store.list(id: listId) != nil {
            openListId = listId
            Haptics.light()
        }
    }
}

// MARK: - Row

struct NotificationRow: View {
    let notification: AppNotification
    let onTap: () -> Void

    @Environment(AppStore.self) private var store

    private var isActionable: Bool {
        notification.listId.flatMap { store.list(id: $0) } != nil
    }

    var body: some View {
        Button(action: onTap) {
            GlassCard(
                tint: notification.read ? nil : Color.accentColor,
                interactive: isActionable,
                radius: Metrics.controlRadius
            ) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: notification.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 30, height: 30)
                        if !notification.read {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .offset(x: 2, y: -1)
                        }
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(notification.title ?? "twodos")
                            .font(.subheadline.weight(notification.read ? .medium : .semibold))
                        if let body = notification.body, !body.isEmpty {
                            Text(body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(Format.relative(notification.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)

                    if isActionable {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActionable ? .isButton : [])
    }

    private var tint: Color {
        switch notification.notificationType {
        case APIConstants.NotificationType.inviteReceived: Brand.violet
        case APIConstants.NotificationType.inviteAccepted: Brand.success
        case APIConstants.NotificationType.listDeleted: Brand.danger
        case APIConstants.NotificationType.alarmFired: Brand.warning
        case APIConstants.NotificationType.geofence: Brand.info
        default: Color.accentColor
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if !notification.read { parts.append("Unread") }
        parts.append(notification.title ?? "Notification")
        if let body = notification.body { parts.append(body) }
        parts.append(Format.relative(notification.createdAt))
        return parts.joined(separator: ", ")
    }
}
