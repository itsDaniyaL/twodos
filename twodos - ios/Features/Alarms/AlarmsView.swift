import SwiftUI

/// Standalone alarms, separate from list deadlines.
///
/// Split into upcoming and past so a screen full of alarms that already fired
/// does not bury the one that matters next.
struct AlarmsView: View {
    @Environment(AppStore.self) private var store
    @Environment(NotificationService.self) private var notifications

    @State private var showingCreate = false
    @State private var hasLoaded = false
    @State private var alarmToDelete: Alarm?

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                content
            }
            .navigationTitle("Alarms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreate = true
                        Haptics.medium()
                    } label: {
                        Label("New alarm", systemImage: "plus")
                    }
                }
            }
            .refreshable { await store.refreshAlarms() }
            .sheet(isPresented: $showingCreate) { CreateAlarmSheet() }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await store.refreshAlarms()
            }
            .confirmationDialog(
                "Delete this alarm?",
                isPresented: Binding(get: { alarmToDelete != nil }, set: { if !$0 { alarmToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let alarm = alarmToDelete {
                        Task { await store.deleteAlarm(id: alarm.id) }
                    }
                    alarmToDelete = nil
                }
                Button("Cancel", role: .cancel) { alarmToDelete = nil }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoaded && store.alarms.isEmpty {
            LoadingView(message: "Loading alarms…")
        } else if store.alarms.isEmpty {
            EmptyStateView(
                icon: "alarm",
                title: "No alarms",
                message: "Alarms are one-off or repeating nudges that aren't tied to a list. Deadlines on lists live with the list itself.",
                actionTitle: "Create an alarm",
                action: { showingCreate = true }
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if notifications.isDenied {
                        InlineBanner(
                            kind: .warning,
                            title: "Alarms can't alert you",
                            message: "Notifications are turned off for twodos, so these alarms will only show inside the app.",
                            actionTitle: "Open Settings",
                            action: openSettings
                        )
                    }

                    if !store.upcomingAlarms.isEmpty {
                        section(title: "Upcoming", alarms: store.upcomingAlarms, isPast: false)
                    }
                    if !store.pastAlarms.isEmpty {
                        section(title: "Past", alarms: store.pastAlarms, isPast: true)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .motion(Motion.content, value: store.alarms.map(\.id))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func section(title: String, alarms: [Alarm], isPast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, count: alarms.count)
            ForEach(alarms) { alarm in
                AlarmRow(
                    alarm: alarm,
                    listName: alarm.listId.flatMap { store.list(id: $0)?.label },
                    isPast: isPast,
                    onSnooze: { minutes in
                        Task { await store.snoozeAlarm(id: alarm.id, minutes: minutes) }
                    },
                    onDelete: { alarmToDelete = alarm }
                )
                .transition(.rowInsertion)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Row

struct AlarmRow: View {
    let alarm: Alarm
    let listName: String?
    let isPast: Bool
    let onSnooze: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        GlassCard(radius: Metrics.controlRadius) {
            HStack(spacing: 14) {
                timeColumn
                VStack(alignment: .leading, spacing: 3) {
                    Text(alarm.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if alarm.repeatRule != .never {
                            MetaChip(icon: "repeat", text: alarm.repeatRule.title, tint: Color.accentColor)
                        }
                        if let listName {
                            MetaChip(icon: "checklist", text: listName)
                        }
                        if alarm.snoozedUntil != nil {
                            MetaChip(icon: "zzz", text: "Snoozed", tint: Brand.warning)
                        }
                    }
                }
                Spacer(minLength: 0)
                menu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .opacity(isPast ? 0.65 : 1)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var timeColumn: some View {
        VStack(spacing: 1) {
            Text(Format.time(alarm.effectiveDate))
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(Format.shortDate(alarm.effectiveDate))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 66)
        .accessibilityHidden(true)
    }

    private var menu: some View {
        Menu {
            if !isPast {
                Menu("Snooze") {
                    ForEach([5, 10, 30, 60], id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) minutes" : "1 hour") { onSnooze(minutes) }
                    }
                }
            }
            Button("Delete", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .accessibilityLabel("Alarm options")
    }

    private var accessibilityLabel: String {
        var parts = [alarm.title, Format.fullDateTime(alarm.effectiveDate)]
        if alarm.repeatRule != .never { parts.append(alarm.repeatRule.title) }
        if let listName { parts.append("for \(listName)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Create sheet

struct CreateAlarmSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var date = Date.now.addingTimeInterval(3600)
    @State private var repeatRule: AlarmRepeat = .never
    @State private var linkedListId: String?
    @State private var target: AlarmTarget = .me
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var linkedList: TodoList? { linkedListId.flatMap { store.list(id: $0) } }

    /// Only offer the "who" picker when the chosen list actually has a partner.
    private var canChooseTarget: Bool {
        guard let linkedList else { return false }
        return !linkedList.isEffectivelyPersonal(currentUserId: store.currentUserId)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        if let errorMessage {
                            InlineBanner(kind: .error, title: errorMessage)
                        }

                        labelField

                        GlassCard {
                            VStack(spacing: 0) {
                                DatePicker("When", selection: $date, in: Date.now...)
                                    .datePickerStyle(.graphical)
                                    .padding(12)
                            }
                        }

                        GlassSection(title: "Repeat") {
                            Picker("Repeat", selection: $repeatRule) {
                                ForEach(AlarmRepeat.allCases) { rule in
                                    Text(rule.title).tag(rule)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(Metrics.cardPadding)
                        }

                        listPicker

                        if canChooseTarget {
                            GlassSection(title: "Who gets it") {
                                Picker("Who gets it", selection: $target) {
                                    ForEach(AlarmTarget.allCases) { option in
                                        Text(option.title).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(Metrics.cardPadding)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("New alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(isSaving || date <= .now)
                }
            }
            .motion(Motion.content, value: canChooseTarget)
        }
        .presentationDragIndicator(.visible)
    }

    private var labelField: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
            TextField("What's this for?", text: $label)
                .submitLabel(.done)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
        .accessibilityLabel("Alarm name")
    }

    private var listPicker: some View {
        GlassSection(
            title: "Attach to a list",
            footer: "Optional. Attaching an alarm lets you open the right list straight from the notification."
        ) {
            Menu {
                Button("None") { linkedListId = nil }
                Divider()
                ForEach(store.activeLists) { list in
                    Button(list.label) { linkedListId = list.id }
                }
            } label: {
                GlassRow(
                    icon: "checklist",
                    title: "List",
                    subtitle: linkedList?.label ?? "None",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        Task {
            defer { isSaving = false }
            await notifications.requestAuthorizationIfNeeded()
            do {
                try await store.createAlarm(
                    at: date,
                    label: label.trimmingCharacters(in: .whitespaces).isEmpty
                        ? nil : label.trimmingCharacters(in: .whitespaces),
                    repeatRule: repeatRule,
                    listId: linkedListId,
                    target: canChooseTarget ? target : nil
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
