import SwiftUI

// MARK: - Alarms

/// Alarms, upcoming first.
///
/// One column rather than the iOS two-section screen plus a sheet: a desktop
/// window has room to show the form beside the list, so creating an alarm never
/// covers the ones already set.
struct MacAlarmsPane: View {
    @Environment(AppStore.self) private var store

    @State private var label = ""
    @State private var date = Date().addingTimeInterval(3_600)
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            newAlarmBar
            Divider()

            if store.alarms.isEmpty {
                MacEmptyState(
                    icon: "alarm",
                    title: "No alarms",
                    message: "Set one above and it will ring on every device you're signed in on."
                )
            } else {
                List {
                    if !store.upcomingAlarms.isEmpty {
                        Section("Upcoming") {
                            ForEach(store.upcomingAlarms) { MacAlarmRow(alarm: $0) }
                        }
                    }
                    if !store.pastAlarms.isEmpty {
                        Section("Past") {
                            ForEach(store.pastAlarms) { MacAlarmRow(alarm: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Alarms")
    }

    private var newAlarmBar: some View {
        HStack(spacing: 8) {
            TextField("What's it for?", text: $label)
                .textFieldStyle(.roundedBorder)
            DatePicker("", selection: $date)
                .labelsHidden()
            Button("Set") {
                isSaving = true
                Task {
                    defer { isSaving = false }
                    try? await store.createAlarm(
                        at: date,
                        label: label.trimmingCharacters(in: .whitespaces),
                        repeatRule: .never,
                        listId: nil,
                        target: nil
                    )
                    label = ""
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
        }
        .controlSize(.large)
        .padding(MacMetrics.gutter)
    }
}

struct MacAlarmRow: View {
    @Environment(AppStore.self) private var store
    let alarm: Alarm

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alarm.fired ? "alarm.waves.left.and.right" : "alarm")
                .foregroundStyle(alarm.fired ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.label ?? "Alarm").lineLimit(1)
                Text(Format.fullDateTime(alarm.alarmAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if !alarm.fired {
                Menu("Snooze") {
                    ForEach([5, 10, 30, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            Task { await store.snoozeAlarm(id: alarm.id, minutes: minutes) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Delete", role: .destructive) {
                Task { await store.deleteAlarm(id: alarm.id) }
            }
        }
    }
}

// MARK: - Activity

/// Everything that happened while you were elsewhere.
struct MacActivityPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.notificationFeed.isEmpty {
                MacEmptyState(
                    icon: "bell",
                    title: "Nothing new",
                    message: "Invitations, finished tasks and alarms from the person you share with show up here."
                )
            } else {
                List {
                    ForEach(store.notificationFeed) { note in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(note.read ? Color.clear : Color.accentColor)
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                                .accessibilityLabel(note.read ? "" : "Unread")

                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title ?? "Update")
                                    .fontWeight(note.read ? .regular : .semibold)
                                if let body = note.body {
                                    Text(body)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(Format.relative(note.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(.rect)
                        .onTapGesture {
                            guard !note.read else { return }
                            Task { await store.markNotificationRead(id: note.id) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            if store.unreadNotificationCount > 0 {
                Button("Mark All Read") { Task { await store.markAllNotificationsRead() } }
            }
        }
    }
}

// MARK: - Partners

/// The people you share with.
struct MacPartnersPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.partners.isEmpty {
                MacEmptyState(
                    icon: "person.2",
                    title: "Nobody yet",
                    message: "Share a list with someone's email — or their @username if they already have twodos — and they'll appear here."
                )
            } else {
                List {
                    ForEach(store.partners) { partner in
                        HStack(spacing: 10) {
                            MacAvatar(partner: partner, size: 32)
                                .grayscale(store.isBlocked(partner.id) ? 1 : 0)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(partner.displayName)
                                // Their handle when they have one: it is what
                                // you would type to share another list, and it
                                // is the shorter of the two.
                                Text(partner.handle ?? partner.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 6)

                            if store.isBlocked(partner.id) {
                                Text("Blocked")
                                    .font(.caption)
                                    .foregroundStyle(Brand.danger)
                            } else if store.presence[partner.id] == true {
                                Text("Online")
                                    .font(.caption)
                                    .foregroundStyle(Brand.success)
                            }
                        }
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button(store.isBlocked(partner.id) ? "Unblock" : "Block") {
                                Task { await store.setBlocked(!store.isBlocked(partner.id), userId: partner.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Partners")
    }
}
