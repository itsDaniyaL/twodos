import SwiftUI

/// Who should have a task, as picked from the row's menu.
enum AssigneeChoice {
    /// "I'll do it."
    case me
    /// "You do it" — hand it to the other person on the list.
    case partner
    /// Unclaim it.
    case nobody
}

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
    /// Same editor as `onEdit`, opened on the notes field.
    let onEditNotes: () -> Void
    let onSetDeadline: () -> Void
    /// Pin this one item to a place. The API has always supported it; nothing
    /// reached it until now.
    let onSetLocation: () -> Void
    /// Sets who has this task. Nil when the list is not shared — there is
    /// nobody to hand it to.
    var onAssign: ((AssigneeChoice) -> Void)?
    /// The line under the title naming who is doing it — "You're doing this",
    /// "@sam_k is doing this". Nil when nobody has claimed it.
    var assigneeLabel: String?
    /// Whether the assignee is the person looking at the screen.
    var assignedToMe: Bool = false
    /// Whether the other person on the list has it.
    var assignedToPartner: Bool = false
    /// How the other person is named in "You do it", already resolved.
    var partnerName: String?
    /// Opens the task's attachments. Nil when the list does not take any.
    var onAttachments: (() -> Void)?
    /// Ticking this one scores a point in the list's running challenge.
    var isInChallenge: Bool = false
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
                // A flag, not a chip: it needs to read as a mark on the task
                // rather than another piece of metadata competing with the
                // deadline beside it.
                if isInChallenge {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.apricot)
                        .accessibilityHidden(true)
                }
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
            Button(action: onEditNotes) {
                Label(todo.hasNotes ? "Edit notes" : "Add notes", systemImage: "note.text")
            }
            Button(action: onSetDeadline) {
                Label(todo.doBefore == nil ? "Add a reminder" : "Change reminder", systemImage: "bell")
            }
            Button(action: onSetLocation) {
                Label(todo.hasLocation ? "Change the place" : "Remind me at a place",
                      systemImage: "mappin.and.ellipse")
            }
            if let onAttachments {
                Button(action: onAttachments) {
                    Label(todo.hasMedia ? "Attachments" : "Attach a file", systemImage: "paperclip")
                }
            }
            // Spelled out rather than cycled: a tap that silently hands your
            // task to the other person is not something to discover by accident.
            if let onAssign {
                Menu {
                    Button { onAssign(.me) } label: {
                        Label("I'll do it", systemImage: assignedToMe ? "checkmark" : "hand.raised")
                    }
                    Button { onAssign(.partner) } label: {
                        Label {
                            Text("You do it")
                            if let partnerName { Text("Hand it to \(partnerName)") }
                        } icon: {
                            Image(systemName: assignedToPartner ? "checkmark" : "arrow.right.circle")
                        }
                    }
                    if todo.assigneeId != nil {
                        Button { onAssign(.nobody) } label: {
                            Label("Nobody yet", systemImage: "person.crop.circle.badge.questionmark")
                        }
                    }
                } label: {
                    Label("Who's doing this?", systemImage: "person.crop.circle.badge.checkmark")
                }
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
            Button(todo.hasNotes ? "Edit notes" : "Add notes", action: onEditNotes)
            Button("Set a reminder", action: onSetDeadline)
            if let onAssign {
                Button("I'll do it") { onAssign(.me) }
                Button("You do it") { onAssign(.partner) }
            }
            if let onAttachments { Button("Attachments", action: onAttachments) }
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

            // A preview, not the note: two lines is enough to know what it says
            // and to tell two "Milk" entries apart. The full text lives in the
            // editor. Only drawn when there is one, so the default row is
            // exactly as tall as it was.
            if let notes = todo.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(todo.done ? .tertiary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if todo.isOverdue {
                Text("Overdue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.danger)
            }

            // A sentence, not initials or a face: two people without a
            // picture had no way to tell from the old mark which of them it
            // meant. The handle comes first because it is the one thing two
            // people on a list cannot share.
            if let assigneeLabel {
                Label(assigneeLabel, systemImage: assignedToMe ? "person.fill.checkmark" : "person.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(todo.done ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                     : assignedToMe ? AnyShapeStyle(Brand.meadow) : AnyShapeStyle(Brand.info))
                    .lineLimit(1)
            }

            if todo.hasMedia {
                Label(
                    todo.media.count == 1
                        ? String(localized: "1 attachment")
                        : String(localized: "\(todo.media.count) attachments"),
                    systemImage: "paperclip"
                )
                .font(.caption2)
                .foregroundStyle(todo.done ? .tertiary : .secondary)
                .lineLimit(1)
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
        if let notes = todo.notes { parts.append("notes: \(notes)") }
        if isInChallenge { parts.append("in the challenge") }
        if todo.hasLocation {
            parts.append("reminder when you \(todo.trigger.shortTitle.lowercased()) at "
                         + (todo.locationName ?? "a saved place"))
        }
        if let assigneeLabel { parts.append(assigneeLabel) }
        if todo.hasMedia { parts.append("\(todo.media.count) attachments") }
        if let due = todo.doBefore {
            parts.append(todo.done ? "was due \(Format.deadline(due))" : "due \(Format.deadline(due))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Edit sheet

/// Editing an item: its title and, underneath, its notes.
///
/// One sheet for both rather than a "Rename" and a separate "Notes" screen,
/// because the second thing people do after fixing a title is add the detail
/// they left out of it. The two fields save independently — the title goes to
/// the title endpoint and the notes to theirs — so an edit here can never
/// overwrite a change the partner made to the other field in the meantime.
struct EditTodoSheet: View {
    enum Field { case title, notes, attachments }

    let listId: String
    let todo: Todo
    /// Which field gets the keyboard on arrival. "Add notes" lands on the
    /// notes; "Edit text" on the title.
    let initialFocus: Field

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var notes: String
    @FocusState private var focus: Field?

    init(listId: String, todo: Todo, initialFocus: Field = .title) {
        self.listId = listId
        self.todo = todo
        self.initialFocus = initialFocus
        _text = State(initialValue: todo.title)
        _notes = State(initialValue: todo.notes ?? "")
        _detent = State(initialValue: initialFocus == .attachments ? .large : .medium)
    }

    private var trimmedTitle: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var titleChanged: Bool { trimmedTitle != todo.title }
    private var notesChanged: Bool { Todo.normalisedNotes(notes) != todo.notes }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && (titleChanged || notesChanged)
    }

    /// Over the limit the server would refuse with a 400; disabling Save with
    /// a visible count is kinder than a banner after the fact.
    private var notesOverLimit: Bool { notes.count > Self.notesLimit }
    /// Matches `TextLimits.TodoDescription` on the server.
    static let notesLimit = 1000

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Item", text: $text, axis: .vertical)
                            .font(.title3)
                            .lineLimit(1...6)
                            .focused($focus, equals: .title)
                            .submitLabel(.next)
                            .onSubmit { focus = .notes }
                            .padding(16)
                            .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                            .accessibilityLabel("Item text")

                        TextField("Notes", text: $notes, axis: .vertical)
                            .font(.body)
                            .lineLimit(3...12)
                            .focused($focus, equals: .notes)
                            .padding(16)
                            .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                            .accessibilityLabel("Notes")
                            .accessibilityHint("Optional detail shown under the item")

                        if notesOverLimit {
                            Text("Notes can be up to \(Self.notesLimit) characters — this is \(notes.count).")
                                .font(.caption)
                                .foregroundStyle(Brand.danger)
                                .padding(.horizontal, 4)
                        }

                        // Saved as they go rather than with the Save button:
                        // an upload is its own round trip, and holding a photo
                        // hostage to a title edit would lose it on Cancel.
                        AttachmentsSection(listId: listId, todoId: todo.id)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        // ⌘↩, since plain Return inserts a line into the notes.
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave || notesOverLimit)
                        .fontWeight(.semibold)
                }
            }
            // The attachments section is not a text field; arriving there
            // means no keyboard, so the files are not hidden behind one.
            .onAppear { focus = initialFocus == .attachments ? nil : initialFocus }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    @State private var detent: PresentationDetent = .medium

    private func save() {
        let title = trimmedTitle
        let newNotes = Todo.normalisedNotes(notes)
        let titleChanged = self.titleChanged
        let notesChanged = self.notesChanged
        Task {
            if titleChanged {
                await store.renameTodo(listId: listId, todoId: todo.id, title: title)
            }
            if notesChanged {
                await store.setTodoNotes(listId: listId, todoId: todo.id, notes: newNotes)
            }
        }
        dismiss()
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
