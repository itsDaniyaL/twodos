import SwiftUI

/// The watch's home screen.
///
/// Two tabs, swiped between: **Up next**, a flat run of everything still to do
/// across every list, and **Lists**, the same content organised the way the
/// phone shows it.
///
/// "Up next" comes first deliberately. On a phone you browse; on a watch you
/// have two seconds and one question — *what do I need to do?* Making the user
/// pick a list before they can answer that is a tab too many.
struct WatchListsView: View {
    @Environment(WatchStore.self) private var store

    private enum Tabs: Hashable { case upNext, lists }

    @State private var selection: Tabs = .upNext
    /// Lifted out of `AllListsView` so a complication tap can push a list onto
    /// it. A `NavigationStack` with no bound path can only be driven by the
    /// user's own taps, which is exactly what a deep link is not.
    @State private var listsPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            Tab("Up next", systemImage: "checklist", value: Tabs.upNext) {
                NavigationStack { UpNextView() }
            }
            Tab("Lists", systemImage: "square.stack", value: Tabs.lists) {
                NavigationStack(path: $listsPath) {
                    AllListsView()
                        .navigationDestination(for: String.self) { listId in
                            WatchListDetailView(listId: listId)
                        }
                }
            }
        }
        .tabViewStyle(.verticalPage)
        // `task(id:)` rather than `onChange`: a complication tap sets the intent
        // while the app is still on its loading or "open twodos on iPhone"
        // screen, so this view is mounted *after* the value it has to act on.
        .task(id: store.pendingListToOpen) {
            guard let listId = store.pendingListToOpen else { return }
            selection = .lists
            listsPath = NavigationPath()
            listsPath.append(listId)
            store.pendingListToOpen = nil
        }
    }
}

// MARK: - Up next

struct UpNextView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            if store.allOpenItems.isEmpty {
                emptyState
            } else {
                summaryHeader

                ForEach(store.allOpenItems, id: \.item.id) { entry in
                    WatchItemRow(
                        item: entry.item,
                        listLabel: entry.list.label,
                        tint: ListTint.all[safe: entry.list.tintIndex]?.color ?? Brand.meadow
                    ) {
                        await store.setItem(listId: entry.list.id, itemId: entry.item.id, done: true)
                    }
                }
            }
        }
        .listStyle(.carousel)
        .navigationTitle("twodos")
        .refreshable { await store.refresh() }
        .overlay(alignment: .bottom) { errorToast }
    }

    /// One line of orientation at the top: how much is left, and when the next
    /// thing is due. Cheap to render and answers most glances on its own.
    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(store.totalOpenCount) to do")
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            if let next = store.nextDue {
                Text(WatchFormat.relativeDeadline(next))
                    .font(.caption2)
                    .foregroundStyle(next < .now ? Brand.danger : .secondary)
            }
        }
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            TwodosMark(tickStyle: AnyShapeStyle(Brand.meadow))
                .frame(width: 30, height: 30)
            Text(store.lists.isEmpty ? "No lists yet" : "All done")
                .font(.headline)
            Text(store.lists.isEmpty
                 ? "Create a list on your iPhone."
                 : "Nothing left on any list.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var errorToast: some View {
        if let error = store.lastError {
            Text(error)
                .font(.caption2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Brand.danger.opacity(0.9)))
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    store.clearError()
                }
        }
    }
}

// MARK: - All lists

struct AllListsView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            ForEach(store.lists) { list in
                // A value-based link so a tap and a deep link push the same
                // destination through the same path.
                NavigationLink(value: list.id) {
                    WatchListRow(list: list)
                }
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Lists")
        .refreshable { await store.refresh() }
        .overlay {
            if store.lists.isEmpty {
                ContentUnavailableView(
                    "No lists",
                    systemImage: "square.stack",
                    description: Text("Create one on your iPhone.")
                )
            }
        }
    }
}

struct WatchListRow: View {
    let list: WatchList

    private var tint: Color {
        ListTint.all[safe: list.tintIndex]?.color ?? Brand.meadow
    }

    var body: some View {
        HStack(spacing: 10) {
            // A ring rather than a bar: at this size a progress ring is readable
            // in peripheral vision, where a thin bar is not.
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if list.isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(list.label)
                    .font(.body)
                    .lineLimit(1)
                Text(list.items.isEmpty ? "Empty" : "\(list.openCount) left")
                    .font(.caption2)
                    .foregroundStyle(list.isOverdue ? Brand.danger : .secondary)
            }

            Spacer(minLength: 0)

            if list.locationLabel != nil {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if list.isShared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // The glyphs are decoration at this size; VoiceOver gets the words.
        .accessibilityLabel(accessibilityLabel)
    }

    private var progress: Double {
        guard !list.items.isEmpty else { return 0 }
        return Double(list.doneCount) / Double(list.items.count)
    }

    private var accessibilityLabel: String {
        var parts = ["\(list.label), \(list.openCount) items left"]
        if let partner = list.partnerName { parts.append("shared with \(partner)") }
        if let place = list.locationLabel { parts.append(place) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Shared row

/// One tickable item.
///
/// The entire row is the tap target — on a watch a small checkbox is a missed
/// tap — and the tick animates in place rather than the row vanishing, so the
/// user sees which thing they just completed before it goes.
struct WatchItemRow: View {
    let item: WatchItem
    var listLabel: String?
    var tint: Color = Brand.meadow
    let onToggle: () async -> Void

    @State private var isCompleting = false

    var body: some View {
        Button {
            guard !isCompleting else { return }
            isCompleting = true
            Task {
                await onToggle()
                isCompleting = false
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(item.done || isCompleting ? .clear : Color.secondary.opacity(0.5),
                                      lineWidth: 2)
                    Circle()
                        .fill(tint)
                        .scaleEffect(item.done || isCompleting ? 1 : 0.1)
                        .opacity(item.done || isCompleting ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .opacity(item.done || isCompleting ? 1 : 0)
                }
                .frame(width: 22, height: 22)
                .animation(.snappy(duration: 0.25), value: item.done || isCompleting)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.body)
                        .strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let listLabel {
                        Text(listLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if let due = item.dueAt {
                        Text(WatchFormat.relativeDeadline(due))
                            .font(.caption2)
                            .foregroundStyle(item.isOverdue ? Brand.danger : .secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.done ? "Completed" : "Not completed")
        .accessibilityHint(item.done ? "Marks as not done" : "Marks as done")
    }
}

// MARK: - Helpers

extension Array {
    /// Bounds-checked access. The tint index arrives from another device, so a
    /// version mismatch must not crash the watch.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Watch-sized date phrasing. Shorter than the phone's — there is no room for
/// "Tomorrow, 09:00" in a caption on a 41mm screen.
enum WatchFormat {
    static func relativeDeadline(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 0 {
            let overdue = -interval
            if overdue < 3600 { return "\(Int(overdue / 60))m overdue" }
            if overdue < 86_400 { return "\(Int(overdue / 3600))h overdue" }
            return "\(Int(overdue / 86_400))d overdue"
        }
        if interval < 3600 { return "in \(Int(interval / 60))m" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
