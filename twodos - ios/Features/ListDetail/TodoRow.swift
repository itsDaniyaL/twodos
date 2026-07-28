import SwiftUI

/// One item in a list.
///
/// The whole row is the checkbox target, which is what people actually aim for.
/// Editing, reminders and deletion live behind swipes and a context menu rather
/// than trailing icon buttons — the Flutter version put two small buttons on
/// every row, which crowded the text and were fiddly to hit.
struct TodoRow: View {
    let todo: Todo
    let listId: String
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onSetDeadline: () -> Void
    /// Pin this one item to a place. The API has always supported it; nothing
    /// reached it until now.
    let onSetLocation: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    var body: some View {
        // Two actions, not five. The long-press menu carries everything —
        // editing, the place reminder, marking done — so the swipe only needs
        // what a person reaches for one-handed while scanning a list.
        SwipeActionsContainer(actions: swipeActions) {
            rowCard
        }
    }

    private var swipeActions: [SwipeAction] {
        [
            SwipeAction(
                title: "Delete",
                systemImage: "trash",
                tint: Brand.danger,
                isDestructive: true,
                handler: onDelete
            ),
            SwipeAction(
                title: todo.doBefore == nil ? "Remind" : "Change",
                systemImage: "bell",
                tint: Brand.info,
                handler: onSetDeadline
            )
        ]
    }

    private var rowCard: some View {
        GlassCard(interactive: true, radius: Metrics.controlRadius) {
            HStack(alignment: .center, spacing: 12) {
                checkbox
                textColumn
                Spacer(minLength: 0)
                if todo.doBefore != nil { deadlineChip }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .contentShape(.rect)
        .onTapGesture {
            onToggle()
        }
        .scaleEffect(isPressed ? 0.985 : 1)
        .motion(Motion.tap, value: isPressed)
        .onLongPressGesture(minimumDuration: 0.01, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .contextMenu {
            Button(action: onToggle) {
                Label(todo.done ? "Mark as not done" : "Mark as done",
                      systemImage: todo.done ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            Button(action: onEdit) {
                Label("Edit text", systemImage: "pencil")
            }
            Button(action: onSetDeadline) {
                Label(todo.doBefore == nil ? "Add a reminder" : "Change reminder", systemImage: "bell")
            }
            Button(action: onSetLocation) {
                Label(todo.hasLocation ? "Change the place" : "Remind me at a place",
                      systemImage: "mappin.and.ellipse")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(todo.done ? "Completed" : "Not completed")
        .accessibilityHint(todo.done ? "Marks as not done" : "Marks as done")
        .accessibilityActions {
            Button("Edit", action: onEdit)
            Button("Set a reminder", action: onSetDeadline)
            Button("Delete", action: onDelete)
        }
    }

    // MARK: - Pieces

    /// A checkbox that fills and stamps a tick. The scale bump on completion is
    /// small but it is the app's single most repeated interaction, so it is
    /// worth making it feel good.
    private var checkbox: some View {
        ZStack {
            Circle()
                .strokeBorder(todo.done ? Color.clear : Color.secondary.opacity(0.45), lineWidth: 2)
                .frame(width: 24, height: 24)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 24, height: 24)
                .scaleEffect(todo.done ? 1 : 0.1)
                .opacity(todo.done ? 1 : 0)

            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(todo.done ? 1 : 0.4)
                .opacity(todo.done ? 1 : 0)
        }
        .motion(reduceMotion ? Motion.fade : Motion.delight, value: todo.done)
        .accessibilityHidden(true)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(todo.title)
                .font(.body)
                .strikethrough(todo.done, color: .secondary)
                .foregroundStyle(todo.done ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .motion(Motion.content, value: todo.done)

            if todo.isOverdue {
                Text("Overdue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.danger)
            }

            // Without this a place reminder is invisible until the moment it
            // fires, and the user has no way to tell they set one.
            if todo.hasLocation {
                Label(
                    "\(todo.trigger.shortTitle) at \(todo.locationName ?? "a saved place")",
                    systemImage: "mappin.and.ellipse"
                )
                .font(.caption2)
                .foregroundStyle(todo.done ? .tertiary : .secondary)
                .lineLimit(1)
            }
        }
    }

    private var deadlineChip: some View {
        MetaChip(
            icon: Format.deadlineIcon(todo.doBefore!),
            text: Format.deadline(todo.doBefore!),
            tint: todo.done ? .secondary : Format.deadlineTint(todo.doBefore!),
            emphasised: !todo.done
        )
        .opacity(todo.done ? 0.5 : 1)
    }

    private var accessibilityLabel: String {
        var parts = [todo.title]
        if todo.hasLocation {
            parts.append("reminder when you \(todo.trigger.shortTitle.lowercased()) at "
                         + (todo.locationName ?? "a saved place"))
        }
        if let due = todo.doBefore {
            parts.append(todo.done ? "was due \(Format.deadline(due))" : "due \(Format.deadline(due))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Edit sheet

/// Renaming an item.
struct EditTodoSheet: View {
    let listId: String
    let todo: Todo

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @FocusState private var focused: Bool

    init(listId: String, todo: Todo) {
        self.listId = listId
        self.todo = todo
        _text = State(initialValue: todo.title)
    }

    private var canSave: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != todo.title
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                VStack(spacing: 16) {
                    TextField("Item", text: $text, axis: .vertical)
                        .font(.title3)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                        .accessibilityLabel("Item text")
                    Spacer()
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 12)
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.renameTodo(
                                listId: listId,
                                todoId: todo.id,
                                title: text.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Banners

/// The list-level deadline, shown at the top of the list.
struct DeadlineBanner: View {
    let deadline: Date
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            GlassCard(tint: Format.deadlineTint(deadline), radius: Metrics.controlRadius) {
                HStack(spacing: 10) {
                    Image(systemName: Format.deadlineIcon(deadline))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Format.deadlineTint(deadline))
                    Text(deadline < .now ? "This list is overdue" : "Due \(Format.deadline(deadline))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(Format.fullDateTime(deadline))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("List deadline, \(Format.deadline(deadline))")
        .accessibilityHint("Opens the deadline picker")
    }
}

// `LocationBanner` and `PartnerPresenceBar` used to live here, as full-width
// banners at the top of the scrolling item stack. The place moved to the pinned
// `ListLocationBar`, which does not scroll away; the partner moved to the
// navigation bar as an avatar, which costs the list no row at all.

/// Three dots that ripple while the partner types.
struct TypingIndicator: View {
    @State private var phase = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .scaleEffect(reduceMotion ? 1 : scale(for: index))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private func scale(for index: Int) -> CGFloat {
        let offset = Double(index) * 0.22
        let value = (phase + offset).truncatingRemainder(dividingBy: 1)
        return 0.7 + 0.5 * sin(value * .pi)
    }
}
