import SwiftUI

/// Picking a deadline.
///
/// Presets come first because most deadlines are one of five obvious times, and
/// the full date picker is one tap away for the rest. Notification permission is
/// requested *here* — the moment a reminder actually needs to be able to ring —
/// rather than at launch.
struct DeadlineSheet: View {
    let title: String
    let initialDate: Date?
    var showsTargetPicker: Bool = false
    let onSave: (Date, AlarmTarget?) -> Void
    var onClear: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(NotificationService.self) private var notifications

    @State private var date: Date
    @State private var target: AlarmTarget = .me
    @State private var showingFullPicker = false
    @State private var selectedPreset: Preset?

    init(
        title: String,
        initialDate: Date?,
        showsTargetPicker: Bool = false,
        onSave: @escaping (Date, AlarmTarget?) -> Void,
        onClear: (() -> Void)? = nil
    ) {
        self.title = title
        self.initialDate = initialDate
        self.showsTargetPicker = showsTargetPicker
        self.onSave = onSave
        self.onClear = onClear
        _date = State(initialValue: initialDate ?? Preset.thisEvening.date())
        _showingFullPicker = State(initialValue: initialDate != nil)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        permissionNotice
                        presets
                        exactPicker
                        if showsTargetPicker { targetPicker }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Remind me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { save() }
                        .fontWeight(.semibold)
                        .disabled(date <= .now)
                }
                if onClear != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remove reminder", role: .destructive) {
                            onClear?()
                            Haptics.light()
                            dismiss()
                        }
                    }
                }
            }
            .task { await notifications.refreshAuthorization() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    /// Only shown when notifications are actually off — otherwise it is noise.
    @ViewBuilder
    private var permissionNotice: some View {
        if notifications.isDenied {
            InlineBanner(
                kind: .warning,
                title: "Notifications are off",
                message: "We'll still save this deadline, but it can't alert you until you turn notifications on.",
                actionTitle: "Open Settings",
                action: openSettings
            )
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Quick picks")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(Preset.allCases) { preset in
                    Button {
                        withAnimation(Motion.tap) {
                            date = preset.date()
                            selectedPreset = preset
                            showingFullPicker = false
                        }
                        Haptics.selection()
                    } label: {
                        VStack(spacing: 2) {
                            Text(preset.title)
                                .font(.subheadline.weight(.medium))
                            Text(Format.time(preset.date()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .tint(selectedPreset == preset ? Color.accentColor : .primary)
                }
            }
        }
    }

    private var exactPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "Exact time")
                Spacer()
                Button(showingFullPicker ? "Hide" : "Choose") {
                    withAnimation(Motion.content) { showingFullPicker.toggle() }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            GlassCard {
                VStack(spacing: 0) {
                    if showingFullPicker {
                        DatePicker(
                            "Deadline",
                            selection: $date,
                            in: Date.now...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.graphical)
                        .padding(12)
                        .onChange(of: date) { _, _ in selectedPreset = nil }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundStyle(Color.accentColor)
                            Text(Format.fullDateTime(date))
                                .font(.body.weight(.medium))
                                .contentTransition(.numericText())
                            Spacer()
                            Text(Format.deadline(date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(Metrics.cardPadding)
                    }
                }
            }
            .motion(Motion.content, value: showingFullPicker)
            .motion(Motion.content, value: date)
        }
    }

    /// Who the reminder should reach. Only shown on shared lists, where the
    /// question actually has more than one answer.
    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Who gets reminded")
            Picker("Who gets reminded", selection: $target) {
                ForEach(AlarmTarget.allCases) { option in
                    Label(option.title, systemImage: option.icon).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: target) { _, _ in Haptics.selection() }
        }
    }

    // MARK: - Actions

    private func save() {
        Task {
            // Ask now — the user has just expressed intent for something that
            // only works if a notification can be delivered.
            await notifications.requestAuthorizationIfNeeded()
            onSave(date, showsTargetPicker ? target : nil)
            Haptics.success()
            dismiss()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Presets

    enum Preset: String, CaseIterable, Identifiable {
        case inAnHour, thisEvening, tomorrowMorning, tomorrowEvening, thisWeekend, nextWeek

        var id: String { rawValue }

        var title: String {
            switch self {
            case .inAnHour: "In an hour"
            case .thisEvening: "This evening"
            case .tomorrowMorning: "Tomorrow"
            case .tomorrowEvening: "Tomorrow eve"
            case .thisWeekend: "This weekend"
            case .nextWeek: "Next week"
            }
        }

        /// Presets that have already passed roll forward to the next sensible
        /// occurrence, so "This evening" tapped at 10pm means tomorrow evening
        /// rather than a time in the past.
        func date(from reference: Date = .now) -> Date {
            let calendar = Calendar.current

            switch self {
            case .inAnHour:
                return reference.addingTimeInterval(3600)

            case .thisEvening:
                let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: reference) ?? reference
                return evening > reference ? evening : calendar.date(byAdding: .day, value: 1, to: evening)!

            case .tomorrowMorning:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference)!
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow

            case .tomorrowEvening:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference)!
                return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? tomorrow

            case .thisWeekend:
                // The coming Saturday at 10am.
                var components = DateComponents()
                components.weekday = 7
                components.hour = 10
                components.minute = 0
                return calendar.nextDate(
                    after: reference,
                    matching: components,
                    matchingPolicy: .nextTime
                ) ?? reference.addingTimeInterval(86_400 * 5)

            case .nextWeek:
                let next = calendar.date(byAdding: .day, value: 7, to: reference)!
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next
            }
        }
    }
}
