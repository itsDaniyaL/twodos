import SwiftUI

// MARK: - Alarms

/// Alarms and reminders, upcoming by default.
///
/// One column rather than the iOS screen plus a sheet: a desktop window has
/// room to show the form above the list, so creating an alarm never covers the
/// ones already set. The ones that already went off are behind the Past
/// filter, not stacked under the live ones.
struct MacAlarmsPane: View {
    @Environment(AppStore.self) private var store

    enum Filter: Hashable { case upcoming, past }

    @State private var filter: Filter = .upcoming
    @State private var label = ""
    @State private var date = Date().addingTimeInterval(3_600)
    @State private var repeatRule: AlarmRepeat = .never
    @State private var linkedListId: String?
    @State private var target: AlarmTarget = .me
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var linkedList: TodoList? { linkedListId.flatMap { store.list(id: $0) } }
    private var linkedListIsShared: Bool {
        linkedList.map { !$0.isEffectivelyPersonal(currentUserId: store.currentUserId) } ?? false
    }

    private var shown: [Alarm] { filter == .upcoming ? store.upcomingAlarms : store.pastAlarms }

    var body: some View {
        VStack(spacing: 0) {
            newAlarmBar
            Divider()

            Picker("Show", selection: $filter) {
                Text("Upcoming (\(store.upcomingAlarms.count))").tag(Filter.upcoming)
                Text("Past (\(store.pastAlarms.count))").tag(Filter.past)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            .padding(.vertical, 8)

            if shown.isEmpty {
                MacEmptyState(
                    icon: "alarm",
                    title: filter == .upcoming ? "Nothing coming up" : "No past alarms",
                    message: filter == .upcoming
                        ? (store.pastAlarms.isEmpty
                            ? "Set one above and it will ring on every device you're signed in on."
                            : "Every alarm and reminder here has already gone off.")
                        : "Alarms and reminders that have gone off are kept here.",
                    actionTitle: filter == .upcoming && !store.pastAlarms.isEmpty ? "Show Past Alarms" : nil,
                    action: filter == .upcoming && !store.pastAlarms.isEmpty ? { filter = .past } : nil
                )
            } else {
                List {
                    ForEach(shown) { MacAlarmRow(alarm: $0) }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Alarms")
        .task { await store.refreshAlarms() }
    }

    private var newAlarmBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("What's it for?", text: $label)
                    .textFieldStyle(.roundedBorder)
                DatePicker("", selection: $date)
                    .labelsHidden()
                Button("Set") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
            HStack(spacing: 12) {
                Picker("Repeat", selection: $repeatRule) {
                    ForEach(AlarmRepeat.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("List", selection: $linkedListId) {
                    Text("None").tag(String?.none)
                    ForEach(store.activeLists) { Text($0.label).tag(String?.some($0.id)) }
                }
                .fixedSize()
                if linkedListIsShared {
                    Picker("Remind", selection: $target) {
                        ForEach(AlarmTarget.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
            }
            .font(.callout)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Brand.danger)
            }
        }
        .controlSize(.large)
        .padding(MacMetrics.gutter)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await store.createAlarm(
                    at: date,
                    label: label.trimmingCharacters(in: .whitespaces),
                    repeatRule: repeatRule,
                    listId: linkedListId,
                    target: linkedListIsShared ? target : nil
                )
                label = ""
                filter = .upcoming
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

struct MacAlarmRow: View {
    @Environment(AppStore.self) private var store
    let alarm: Alarm

    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alarm.isUpcoming ? "alarm" : "alarm.waves.left.and.right")
                .foregroundStyle(alarm.isUpcoming ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Format.fullDateTime(alarm.effectiveDate))
                    if alarm.repeatRule != .never { Text("· \(alarm.repeatRule.title)") }
                    if let listId = alarm.listId, let list = store.list(id: listId) {
                        Text("· \(list.label)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if alarm.isUpcoming {
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
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete this alarm?", isPresented: $confirmingDelete) {
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
                        // Clicking reads it and, as on iOS, opens the list it
                        // is about — the main window watches `pendingListToOpen`
                        // and switches to Lists.
                        .onTapGesture {
                            if !note.read {
                                Task { await store.markNotificationRead(id: note.id) }
                            }
                            if let listId = note.listId, store.list(id: listId) != nil {
                                store.pendingListToOpen = listId
                            }
                        }
                        .contextMenu {
                            if let listId = note.listId, store.list(id: listId) != nil {
                                Button("Open List") { store.pendingListToOpen = listId }
                            }
                            if !note.read {
                                Button("Mark as Read") { Task { await store.markNotificationRead(id: note.id) } }
                            }
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

/// The people you share with, split by where each relationship stands.
///
/// Every section is cut from the one `store.partners` array and each person
/// lands in exactly one, so the counts in the headings always add up to what
/// is on screen — and agree with the iOS app, which splits it the same way.
struct MacPartnersPane: View {
    @Environment(AppStore.self) private var store

    @State private var reportTarget: Partner?
    @State private var blockTarget: Partner?

    private func isBlockedEitherWay(_ partner: Partner) -> Bool {
        partner.isInBlock || store.isBlocked(partner.id)
    }

    private struct PartnerSection: Identifiable {
        let title: String
        let partners: [Partner]
        var id: String { title }
    }

    private var sections: [PartnerSection] {
        let pending = store.partners.filter { $0.isPending && !isBlockedEitherWay($0) }
        let inactive = store.partners.filter { !$0.isAccepted && !$0.isPending && !isBlockedEitherWay($0) }
        let blocked = store.partners.filter(isBlockedEitherWay)
        return [
            PartnerSection(title: String(localized: "Sharing With"), partners: store.acceptedPartners),
            PartnerSection(title: String(localized: "Invite Pending"), partners: pending),
            PartnerSection(title: String(localized: "Not Sharing"), partners: inactive),
            PartnerSection(title: String(localized: "Blocked"), partners: blocked),
        ].filter { !$0.partners.isEmpty }
    }

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
                    ForEach(sections) { section in
                        Section("\(section.title) (\(section.partners.count))") {
                            ForEach(section.partners) { partner in
                                MacPartnerRow(
                                    partner: partner,
                                    isBlocked: isBlockedEitherWay(partner),
                                    onBlock: { blockTarget = partner },
                                    onReport: { reportTarget = partner }
                                )
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Partners")
        .task {
            await store.refreshPartners()
            await store.refreshBlockedUsers()
        }
        .sheet(item: $reportTarget) { MacReportSheet(partner: $0) }
        .confirmationDialog(
            blockTarget.map { store.isBlocked($0.id) ? "Unblock \($0.displayName)?" : "Block \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
            presenting: blockTarget
        ) { target in
            let isBlocked = store.isBlocked(target.id)
            Button(isBlocked ? "Unblock" : "Block", role: isBlocked ? nil : .destructive) {
                Task { await store.setBlocked(!isBlocked, userId: target.id) }
            }
        } message: { target in
            Text(store.isBlocked(target.id)
                 ? "They'll be able to share lists with you again."
                 : "\(target.displayName) won't be able to invite you to new lists.")
        }
    }
}

struct MacPartnerRow: View {
    @Environment(AppStore.self) private var store
    let partner: Partner
    let isBlocked: Bool
    let onBlock: () -> Void
    let onReport: () -> Void

    /// The server's count when the directory gave one, otherwise counted from
    /// the lists on this Mac, from either side of the invitation.
    private var sharedListCount: Int {
        if partner.listCount > 0 { return partner.acceptedListCount }
        return store.lists.count {
            !$0.archived && ($0.partnerId == partner.id || $0.createdBy == partner.id)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            MacAvatar(partner: partner, size: 32)
                .grayscale(isBlocked ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(partner.displayName)
                // Their handle when they have one: it is what you would type to
                // share another list, and it is the shorter of the two.
                if let secondary = partner.handle ?? (partner.email.isEmpty ? nil : partner.email),
                   secondary != partner.displayName {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            if sharedListCount > 0 && !isBlocked {
                Text("\(sharedListCount) list\(sharedListCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                if isBlocked {
                    Text(partner.blockedByThem && !partner.blocked && !store.isBlocked(partner.id)
                         ? "Unavailable" : "Blocked")
                        .foregroundStyle(Brand.danger)
                } else if partner.isPending {
                    Text("Invite pending").foregroundStyle(Brand.warning)
                } else if partner.isRejected {
                    Text("Declined").foregroundStyle(.secondary)
                } else if store.presence[partner.id] == true {
                    Text("Online").foregroundStyle(Brand.success)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(store.isBlocked(partner.id) ? "Unblock…" : "Block…", action: onBlock)
            Button("Report…", action: onReport)
        }
    }
}

/// Reporting a partner to the twodos team.
struct MacReportSheet: View {
    let partner: Partner

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var type = APIConstants.ReportType.spam
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(didSubmit ? "Report submitted" : "Report \(partner.displayName)")
                .font(.title2.weight(.semibold))

            if didSubmit {
                Text("We'll take a look. You can also block \(partner.displayName) if you'd rather not hear from them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let errorMessage { MacBanner(kind: .error, title: errorMessage) }
                Form {
                    Picker("What's the problem?", selection: $type) {
                        ForEach(Array(APIConstants.ReportType.all.enumerated()), id: \.offset) { _, option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    TextField("Anything else? (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }
                .formStyle(.grouped)
                Text("Reports go to the twodos team. We review every one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if didSubmit && !store.isBlocked(partner.id) {
                    Button("Block \(partner.displayName)") {
                        Task { await store.setBlocked(true, userId: partner.id) }
                        dismiss()
                    }
                }
                Spacer()
                Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !didSubmit {
                    Button("Submit") { submit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSubmitting)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
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
                didSubmit = true
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
