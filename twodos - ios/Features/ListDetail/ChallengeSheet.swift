import SwiftUI

/// Setting up a challenge on a shared list.
///
/// Two decisions only: when it ends, and what counts. Everything else the
/// server works out — who is ahead, who won, when to stop.
///
/// The task picker starts with everything selected, because "race me through
/// this list" is the obvious version of the idea and anything narrower is a
/// refinement of it. Tasks that already have somebody's name on them say so
/// while you pick: including a task your partner has already claimed is a fair
/// thing to do, but it should be a thing you *chose*, not something you find out
/// about afterwards.
struct ChallengeSheet: View {
    let listId: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var deadline = Date.now.addingTimeInterval(60 * 60 * 24)
    @State private var selection: Set<String> = []
    /// Set once from the list, so re-renders don't undo the user's picking.
    @State private var hasSeeded = false
    @State private var isSaving = false
    @State private var failure: String?

    private var list: TodoList? { store.list(id: listId) }

    /// Only unfinished tasks. A task that is already ticked cannot be raced for,
    /// and offering it implies points that will never arrive.
    private var candidates: [Todo] {
        list?.todos.filter { !$0.done } ?? []
    }

    private var partner: Partner? { store.partner(id: list?.partnerId) }

    private var canStart: Bool {
        !selection.isEmpty && deadline > .now && !isSaving
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                if candidates.isEmpty {
                    EmptyStateView(
                        icon: "flag.checkered",
                        title: "Nothing left to race for",
                        message: "Add a few unfinished items to this list, then start a challenge."
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            if let failure {
                                InlineBanner(kind: .error, title: "Couldn't start it", message: failure)
                            }
                            explainer
                            deadlineSection
                            taskSection
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .fontWeight(.semibold)
                        .disabled(!canStart)
                }
            }
            .task {
                guard !hasSeeded else { return }
                selection = Set(candidates.map(\.id))
                hasSeeded = true
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var explainer: some View {
        GlassCard(tint: Brand.info, radius: Metrics.controlRadius) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "flag.checkered.2.crossed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Race \(partner?.displayName ?? String(localized: "your partner"))")
                        .font(.subheadline.weight(.semibold))
                    Text("Whoever ticks off the most before the deadline wins. Finish every one of them first and it ends there and then.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var deadlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Ends")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(Window.allCases) { window in
                    SuggestionChip(
                        title: window.title,
                        isSelected: isChosen(window)
                    ) {
                        Haptics.selection()
                        withAnimation(Motion.tap) { deadline = window.date() }
                    }
                }
            }

            GlassCard {
                DatePicker(
                    "Deadline",
                    selection: $deadline,
                    in: Date.now...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "What counts")
                Spacer()
                Button(selection.count == candidates.count ? "Clear all" : "Select all") {
                    Haptics.selection()
                    withAnimation(Motion.content) {
                        selection = selection.count == candidates.count
                            ? []
                            : Set(candidates.map(\.id))
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }

            GlassCard {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, todo in
                        if index > 0 { GlassDivider() }
                        taskRow(todo)
                    }
                }
            }

            Text(selection.isEmpty
                 ? "Pick at least one task."
                 : "\(selection.count) of \(candidates.count) tasks are in the challenge.")
                .font(.caption)
                .foregroundStyle(selection.isEmpty ? Brand.warning : .secondary)
        }
    }

    private func taskRow(_ todo: Todo) -> some View {
        let isOn = selection.contains(todo.id)

        return Button {
            Haptics.selection()
            withAnimation(Motion.tap) {
                if isOn { selection.remove(todo.id) } else { selection.insert(todo.id) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    // The one piece of context that changes the decision.
                    if let owner = assigneeLabel(todo) {
                        Label(owner, systemImage: "person")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Helpers

    /// Who already has this task, phrased from the reader's side.
    private func assigneeLabel(_ todo: Todo) -> LocalizedStringResource? {
        guard let assignee = todo.assigneeId else { return nil }
        if assignee == store.currentUserId { return "Already yours" }
        return "Already with \(partner?.displayName ?? String(localized: "your partner"))"
    }

    private func isChosen(_ window: Window) -> Bool {
        abs(deadline.timeIntervalSince(window.date())) < 60
    }

    private func start() {
        isSaving = true
        failure = nil
        Task {
            do {
                try await store.startChallenge(
                    listId: listId,
                    deadline: deadline,
                    todoIds: Array(selection)
                )
                dismiss()
            } catch {
                failure = error.userMessage
                isSaving = false
            }
        }
    }

    // MARK: - Presets

    /// Deadlines people actually pick. A challenge that runs for a month is not
    /// a challenge, so the range stops at a week.
    private enum Window: String, CaseIterable, Identifiable {
        case tonight, tomorrow, twoDays, weekend, week

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .tonight: "Tonight"
            case .tomorrow: "Tomorrow"
            case .twoDays: "2 days"
            case .weekend: "This weekend"
            case .week: "A week"
            }
        }

        func date(from now: Date = .now, calendar: Calendar = .current) -> Date {
            switch self {
            case .tonight:
                return calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now)
                    ?? now.addingTimeInterval(6 * 3600)
            case .tomorrow:
                let next = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                return calendar.date(bySettingHour: 21, minute: 0, second: 0, of: next) ?? next
            case .twoDays:
                let next = calendar.date(byAdding: .day, value: 2, to: now) ?? now
                return calendar.date(bySettingHour: 21, minute: 0, second: 0, of: next) ?? next
            case .weekend:
                // The coming Sunday evening. On a Sunday that means today, which
                // is the reading people expect from "this weekend".
                let target = calendar.nextDate(
                    after: calendar.startOfDay(for: now),
                    matching: DateComponents(hour: 21, weekday: 1),
                    matchingPolicy: .nextTime
                )
                return target ?? now.addingTimeInterval(3 * 86_400)
            case .week:
                let next = calendar.date(byAdding: .day, value: 7, to: now) ?? now
                return calendar.date(bySettingHour: 21, minute: 0, second: 0, of: next) ?? next
            }
        }
    }
}
