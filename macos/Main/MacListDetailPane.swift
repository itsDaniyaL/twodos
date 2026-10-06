import SwiftUI
import PhotosUI

/// The right-hand column: one list's tasks.
///
/// The add field sits at the *top* rather than the bottom. On a phone the
/// keyboard rises from the bottom and the field rises with it; on a Mac there
/// is no keyboard to make room for, and the natural place to type is under the
/// title where the insertion point already is.
///
/// Everything about the list that is not its tasks lives in the inspector on
/// the trailing edge (⌥⌘I), which is where a Mac user looks for "settings for
/// the selected thing".
struct MacListDetailPane: View {
    @Environment(AppStore.self) private var store
    @Environment(MacCommands.self) private var commands

    let list: TodoList

    @State private var draft = ""
    @State private var notesDraft = ""
    @State private var showsNotesField = false
    @State private var editingTodoId: String?
    /// The task whose full editor is open.
    @State private var editingTask: Todo?
    @State private var editorFocus: MacTaskEditSheet.Focus = .details
    @State private var placeTarget: MacPlaceTarget?
    /// "Just my tasks". Offered once you have taken something on.
    @State private var onlyMine = false
    @State private var draftAttachments: [AttachmentDraft] = []
    @State private var newPhotoItems: [PhotosPickerItem] = []
    @State private var showingNewFileImporter = false
    @State private var stagingError: String?
    @AppStorage("mac.inspector.visible") private var showsInspector = true
    @FocusState private var addFocused: Bool

    private var live: TodoList { store.list(id: list.id) ?? list }
    private var isShared: Bool { !live.isEffectivelyPersonal(currentUserId: store.currentUserId) }

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()

            if let challenge = store.challenge(for: live.id) {
                MacChallengeBanner(list: live, challenge: challenge)
                    .padding(.horizontal, MacMetrics.gutter)
                    .padding(.vertical, 10)
                Divider()
            }

            if showsAssigneeFilter {
                assigneeFilter
                    .padding(.horizontal, MacMetrics.gutter)
                    .padding(.vertical, 8)
                Divider()
            }

            if live.todos.isEmpty {
                MacEmptyState(
                    icon: "checkmark.circle",
                    title: "Nothing here yet",
                    message: "Add the first task above. Whoever you share this with sees it straight away."
                )
            } else if onlyMine && visibleTodos.isEmpty {
                MacEmptyState(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Nothing on your plate",
                    message: "No task on this list is yours right now. Choose “I'll Do It” on one to see it here.",
                    actionTitle: "Show All Tasks",
                    action: { onlyMine = false }
                )
            } else {
                taskList
            }
        }
        .navigationTitle(live.label)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if live.completedCount > 0 {
                    Button("Clear Done") { Task { await store.clearCompleted(listId: live.id) } }
                        .help("Remove every finished task")
                }
                Menu {
                    Button(live.favorite ? "Remove from Favourites" : "Add to Favourites") {
                        Task { await store.toggleFavorite(id: live.id) }
                    }
                    Button(live.archived ? "Unarchive" : "Archive") {
                        Task { await store.archiveList(id: live.id, archived: !live.archived) }
                    }
                    Divider()
                    Button("Delete List", role: .destructive) {
                        Task { await store.deleteList(id: live.id) }
                    }
                } label: {
                    Label("List Options", systemImage: "ellipsis.circle")
                }
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide list details (⌥⌘I)")
            }
        }
        .inspector(isPresented: $showsInspector) {
            MacListInspector(list: live)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .sheet(item: $editingTask) { todo in
            MacTaskEditSheet(listId: live.id, todo: todo, initialFocus: editorFocus)
        }
        .sheet(item: $placeTarget) { MacPlacePickerSheet(target: $0) }
        .task(id: live.id) { await store.refreshChallenge(listId: live.id) }
        .onChange(of: live.id) { _, _ in
            onlyMine = false
            draftAttachments = []
        }
        .onChange(of: commands.newItemRequests) { _, _ in addFocused = true }
        .onChange(of: commands.toggleInspectorRequests) { _, _ in showsInspector.toggle() }
        .onAppear { commands.openListId = live.id }
    }

    private var subtitle: String {
        var parts: [String] = []
        if live.totalCount > 0 { parts.append("\(live.completedCount) of \(live.totalCount) done") }
        if let counterpart = store.counterpart(for: live) {
            parts.append(counterpart.state == .accepted
                         ? String(localized: "with \(counterpart.statusText)")
                         : counterpart.statusText)
        }
        if live.hasLocation {
            parts.append("\(live.trigger.shortTitle) at \(live.locationName ?? "a saved place")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tasks

    private var visibleTodos: [Todo] {
        guard onlyMine, let me = store.currentUserId else { return live.todos }
        return live.todos.filter { $0.assigneeId == me }
    }

    private var taskList: some View {
        List {
            Section {
                ForEach(visibleTodos.filter { !$0.done }) { todo in
                    row(for: todo)
                }
                .onMove { indices, destination in
                    // Reordering a filtered view would scramble the tasks that
                    // are hidden, so it is only offered on the full list.
                    guard !onlyMine else { return }
                    var ordered = live.todos.filter { !$0.done }
                    ordered.move(fromOffsets: indices, toOffset: destination)
                    Task { await store.persistOrder(listId: live.id, todos: ordered) }
                }
            }

            let done = visibleTodos.filter(\.done)
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done) { todo in
                        row(for: todo)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(for todo: Todo) -> some View {
        MacTodoRow(
            list: live,
            todo: todo,
            editingTodoId: $editingTodoId,
            onOpenEditor: { focus in
                editorFocus = focus
                editingTask = todo
            },
            onSetPlace: { placeTarget = .item(listId: live.id, todo: todo) }
        )
    }

    // MARK: - Who does what

    /// Only on a shared list, and only once you have taken something on. Kept
    /// while switched on so finishing your last task cannot strand you.
    private var showsAssigneeFilter: Bool {
        guard isShared else { return false }
        return onlyMine || live.todos.contains { $0.assigneeId != nil && $0.assigneeId == store.currentUserId }
    }

    private var assigneeFilter: some View {
        let mine = live.todos.count { $0.assigneeId != nil && $0.assigneeId == store.currentUserId && !$0.done }
        return Picker("Show", selection: $onlyMine) {
            Text("All Tasks").tag(false)
            Text("Just My Tasks (\(mine))").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Show only the tasks you said you'd do")
    }

    // MARK: - Add bar

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a task", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($addFocused)
                    .onSubmit(add)

                // A disclosure for the optional second line, rather than a
                // permanent second field: most tasks are a sentence, and an
                // always-visible notes box makes every one of them look
                // unfinished.
                Toggle(isOn: $showsNotesField) {
                    Image(systemName: "text.alignleft")
                }
                .toggleStyle(.button)
                .help("Add a note")

                if let allowance = live.mediaAllowance, allowance.enabled {
                    attachMenu(allowance: allowance)
                }

                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if showsNotesField {
                TextField("Note (optional)", text: $notesDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            if !draftAttachments.isEmpty {
                MacDraftAttachmentStrip(drafts: $draftAttachments)
            }

            if let stagingError {
                Text(stagingError)
                    .font(.caption)
                    .foregroundStyle(Brand.danger)
            }
        }
        .padding(MacMetrics.gutter)
        .disabled(live.archived)
        .onChange(of: newPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            newPhotoItems = []
            Task {
                for item in items {
                    if let draft = await MacAttachmentLoader.draft(from: item) { stage(draft) }
                }
            }
        }
        .fileImporter(
            isPresented: $showingNewFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let draft = MacAttachmentLoader.draft(from: url) { stage(draft) }
            }
        }
    }

    /// Files that should arrive *with* the task rather than be added after.
    private func attachMenu(allowance: MediaAllowance) -> some View {
        let room = max(0, min(allowance.filesPerTask, allowance.remainingOnList) - draftAttachments.count)
        return Menu {
            PhotosPicker(
                selection: $newPhotoItems,
                maxSelectionCount: max(1, room),
                matching: .any(of: [.images, .videos])
            ) {
                Label("Photo or Video…", systemImage: "photo.on.rectangle")
            }
            Button("File…") { showingNewFileImporter = true }
        } label: {
            Label("Attach", systemImage: draftAttachments.isEmpty ? "paperclip" : "paperclip.badge.ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(room == 0)
        .help("Attach files to the new task")
    }

    private func stage(_ draft: AttachmentDraft) {
        guard let allowance = live.mediaAllowance else { return }
        if allowance.maxFileBytes > 0, draft.sizeBytes > allowance.maxFileBytes {
            stagingError = String(localized: "“\(draft.fileName)” is \(MacAttachmentLoader.bytes(draft.sizeBytes)). Files can be up to \(MacAttachmentLoader.bytes(allowance.maxFileBytes)).")
            return
        }
        guard draftAttachments.count < min(allowance.filesPerTask, allowance.remainingOnList) else { return }
        stagingError = nil
        draftAttachments.append(draft)
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let notes = notesDraft.trimmingCharacters(in: .whitespaces)
        let attachments = draftAttachments
        Task {
            await store.addTodo(listId: live.id, title: title,
                                notes: notes.isEmpty ? nil : notes,
                                attachments: attachments)
        }
        draft = ""
        notesDraft = ""
        draftAttachments = []
        stagingError = nil
        addFocused = true
    }
}

// MARK: - Row

/// One task.
struct MacTodoRow: View {
    @Environment(AppStore.self) private var store
    let list: TodoList
    let todo: Todo
    @Binding var editingTodoId: String?
    var onOpenEditor: (MacTaskEditSheet.Focus) -> Void = { _ in }
    var onSetPlace: () -> Void = {}

    @State private var titleDraft = ""

    private var isShared: Bool { !list.isEffectivelyPersonal(currentUserId: store.currentUserId) }
    private var assignedToMe: Bool { todo.assigneeId != nil && todo.assigneeId == store.currentUserId }
    private var otherPersonId: String? {
        guard let me = store.currentUserId else { return nil }
        let other = list.createdBy == me ? list.partnerId : list.createdBy
        return other == me ? nil : other
    }

    private var isInChallenge: Bool {
        guard let challenge = store.challenge(for: list.id), challenge.isRunning else { return false }
        return challenge.todoIds.contains(todo.id) || todo.challengeId == challenge.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { todo.done },
                set: { done in Task { await store.setTodo(listId: list.id, todoId: todo.id, done: done) } }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                if editingTodoId == todo.id {
                    TextField("Task", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitRename)
                        .onExitCommand { editingTodoId = nil }
                } else {
                    Text(todo.title)
                        .strikethrough(todo.done, color: .secondary)
                        .foregroundStyle(todo.done ? .secondary : .primary)
                }

                if let notes = todo.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Said in words, not a face or initials: two people without a
                // picture could not tell from a mark which of them it meant.
                if isShared, let label = store.assigneeLabel(for: todo) {
                    Label(label, systemImage: assignedToMe ? "person.fill.checkmark" : "person.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(todo.done ? Color.secondary : assignedToMe ? Brand.meadow : Brand.info)
                }

                metadata
            }

            Spacer(minLength: 0)

            if isInChallenge {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(Brand.apricot)
                    .help("Part of the running challenge")
            }
        }
        .padding(.vertical, 2)
        // Double-click to rename is the desktop gesture; the context menu
        // carries everything the iOS swipe and long-press offer.
        .onTapGesture(count: 2) { beginRename() }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var metadata: some View {
        let hasAny = todo.doBefore != nil || todo.hasLocation || todo.hasMedia
        if hasAny {
            HStack(spacing: 10) {
                if let due = todo.doBefore {
                    Label(Format.deadline(due), systemImage: Format.deadlineIcon(due))
                        .foregroundStyle(todo.done ? Color.secondary : Format.deadlineTint(due))
                }
                if todo.hasLocation {
                    Label("\(todo.trigger.shortTitle) at \(todo.locationName ?? "a saved place")",
                          systemImage: "mappin.and.ellipse")
                }
                if todo.hasMedia {
                    Label(todo.media.count == 1 ? String(localized: "1 attachment")
                                                : String(localized: "\(todo.media.count) attachments"),
                          systemImage: "paperclip")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(todo.done ? "Mark as Not Done" : "Mark as Done") {
            Task { await store.setTodo(listId: list.id, todoId: todo.id, done: !todo.done) }
        }
        Divider()
        Button("Rename") { beginRename() }
        Button("Edit Task…") { onOpenEditor(.details) }
        Button(todo.doBefore == nil ? "Add Reminder…" : "Change Reminder…") { onOpenEditor(.reminder) }
        Button(todo.hasLocation ? "Change Place…" : "Remind Me at a Place…") { onSetPlace() }
        if list.mediaAllowance?.enabled == true || todo.hasMedia {
            Button(todo.hasMedia ? "Attachments…" : "Attach a File…") { onOpenEditor(.attachments) }
        }

        // Spelled out rather than cycled: handing your task to the other
        // person is not something to discover by accident.
        if isShared && !todo.done {
            Divider()
            Menu("Who's Doing This?") {
                Toggle("I'll Do It", isOn: Binding(
                    get: { assignedToMe },
                    set: { _ in assign(to: store.currentUserId) }
                ))
                Toggle(isOn: Binding(
                    get: { todo.assigneeId != nil && todo.assigneeId == otherPersonId },
                    set: { _ in assign(to: otherPersonId) }
                )) {
                    if let name = store.counterpart(for: list)?.name {
                        Text("You Do It — \(name)")
                    } else {
                        Text("You Do It")
                    }
                }
                .disabled(otherPersonId == nil)
                if todo.assigneeId != nil {
                    Divider()
                    Button("Nobody Yet") { assign(to: nil) }
                }
            }
        }

        Divider()
        Button("Delete", role: .destructive) {
            Task { await store.deleteTodo(listId: list.id, todoId: todo.id) }
        }
    }

    private func assign(to userId: String?) {
        guard userId != todo.assigneeId else { return }
        Task { await store.setTodoAssignee(listId: list.id, todoId: todo.id, assigneeId: userId) }
    }

    private func beginRename() {
        titleDraft = todo.title
        editingTodoId = todo.id
    }

    private func commitRename() {
        let title = titleDraft.trimmingCharacters(in: .whitespaces)
        editingTodoId = nil
        guard !title.isEmpty, title != todo.title else { return }
        Task { await store.renameTodo(listId: list.id, todoId: todo.id, title: title) }
    }
}

// MARK: - Task editor

/// Everything about one task: its words, its reminder, who is doing it, and
/// its files. iOS spreads these across a sheet, a deadline picker and a long
/// press; a Mac form has the room to put them on one page.
struct MacTaskEditSheet: View {
    enum Focus { case details, reminder, attachments }

    let listId: String
    let todo: Todo
    let initialFocus: Focus

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var notes: String
    @State private var hasReminder: Bool
    @State private var reminderDate: Date
    @State private var reminderTarget: AlarmTarget = .both
    @State private var placeTarget: MacPlaceTarget?
    @FocusState private var titleFocused: Bool

    /// Matches `TextLimits.TodoDescription` on the server.
    private static let notesLimit = 1_000

    init(listId: String, todo: Todo, initialFocus: Focus) {
        self.listId = listId
        self.todo = todo
        self.initialFocus = initialFocus
        _title = State(initialValue: todo.title)
        _notes = State(initialValue: todo.notes ?? "")
        _hasReminder = State(initialValue: todo.doBefore != nil || initialFocus == .reminder)
        _reminderDate = State(initialValue: todo.doBefore ?? Date().addingTimeInterval(3_600))
    }

    private var list: TodoList? { store.list(id: listId) }
    private var live: Todo { list?.todos.first { $0.id == todo.id } ?? todo }
    private var isShared: Bool { list?.isEffectivelyPersonal(currentUserId: store.currentUserId) == false }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Task") {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($titleFocused)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                    if notes.count > Self.notesLimit {
                        Text("Notes can be up to \(Self.notesLimit) characters — this is \(notes.count).")
                            .font(.caption)
                            .foregroundStyle(Brand.danger)
                    }
                }

                Section("Reminder") {
                    Toggle("Remind me", isOn: $hasReminder)
                    if hasReminder {
                        DatePicker("Due", selection: $reminderDate)
                        if isShared {
                            Picker("Who gets the reminder", selection: $reminderTarget) {
                                ForEach(AlarmTarget.allCases) { Text($0.title).tag($0) }
                            }
                        }
                    }
                    LabeledContent("Place") {
                        HStack {
                            Text(live.hasLocation
                                 ? "\(live.trigger.shortTitle) at \(live.locationName ?? "a saved place")"
                                 : String(localized: "None"))
                                .foregroundStyle(.secondary)
                            Button(live.hasLocation ? "Change…" : "Choose…") {
                                placeTarget = .item(listId: listId, todo: live)
                            }
                        }
                    }
                }

                if isShared {
                    Section("Who's doing this") {
                        Picker("Doing it", selection: Binding(
                            get: { live.assigneeId ?? "" },
                            set: { value in
                                Task {
                                    await store.setTodoAssignee(listId: listId, todoId: todo.id,
                                                                assigneeId: value.isEmpty ? nil : value)
                                }
                            }
                        )) {
                            Text("Nobody yet").tag("")
                            if let me = store.currentUserId { Text("I'll do it").tag(me) }
                            if let other = otherPersonId {
                                Text("You do it — \(store.partner(id: other)?.identityLabel ?? String(localized: "your partner"))")
                                    .tag(other)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }
                }

                MacAttachmentsSection(listId: listId, todoId: todo.id)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty || notes.count > Self.notesLimit)
            }
            .padding(14)
        }
        .frame(width: 520, height: 620)
        .sheet(item: $placeTarget) { MacPlacePickerSheet(target: $0) }
        .onAppear { titleFocused = initialFocus == .details }
    }

    private var otherPersonId: String? {
        guard let list, let me = store.currentUserId else { return nil }
        let other = list.createdBy == me ? list.partnerId : list.createdBy
        return other == me ? nil : other
    }

    /// Each field goes to its own endpoint, and only if it changed — sending
    /// the whole task back is how two people editing it overwrite each other.
    private func save() {
        let newTitle = trimmedTitle
        let newNotes = Todo.normalisedNotes(notes)
        let newDate: Date? = hasReminder ? reminderDate : nil
        let titleChanged = newTitle != todo.title
        let notesChanged = newNotes != todo.notes
        let dateChanged = newDate != todo.doBefore
        let target = isShared ? reminderTarget : nil
        Task {
            if titleChanged { await store.renameTodo(listId: listId, todoId: todo.id, title: newTitle) }
            if notesChanged { await store.setTodoNotes(listId: listId, todoId: todo.id, notes: newNotes) }
            if dateChanged {
                await store.setTodoDeadline(listId: listId, todoId: todo.id, date: newDate,
                                            target: newDate == nil ? nil : target)
            }
        }
        dismiss()
    }
}

// MARK: - Challenge

/// The running (or proposed) challenge on a list, above its tasks.
struct MacChallengeBanner: View {
    @Environment(AppStore.self) private var store
    let list: TodoList
    let challenge: Challenge

    private var me: String? { store.currentUserId }
    private var theirName: String {
        store.counterpart(for: list)?.partner?.displayName ?? String(localized: "Your partner")
    }

    var body: some View {
        MacCard(tint: Brand.apricot) {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.title2)
                    .foregroundStyle(Brand.apricot)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                actions
            }
        }
    }

    private var headline: String {
        let mine = challenge.score(for: me)
        let theirs = challenge.opponentScore(against: me)
        switch challenge.status {
        case .pending:
            return challenge.createdBy == me
                ? String(localized: "Challenge sent to \(theirName)")
                : String(localized: "\(theirName) challenged you")
        case .active:
            return String(localized: "You \(mine) – \(theirs) \(theirName)")
        case .complete:
            if challenge.isDraw { return String(localized: "A draw, \(mine) all") }
            return challenge.winnerId == me
                ? String(localized: "You won, \(mine) to \(theirs)")
                : String(localized: "\(theirName) won, \(theirs) to \(mine)")
        case .declined:
            return String(localized: "Challenge declined")
        case .cancelled:
            return String(localized: "Challenge cancelled")
        }
    }

    private var detail: String {
        switch challenge.status {
        case .pending, .active:
            return challenge.hasExpired
                ? String(localized: "Ended \(Format.relative(challenge.deadline))")
                : String(localized: "Ends \(Format.fullDateTime(challenge.deadline))")
        default:
            return String(localized: "Whoever ticks off the most tasks in time wins.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch challenge.status {
        case .pending where challenge.createdBy != me:
            Button("Decline") { answer(false) }
            Button("Accept") { answer(true) }.buttonStyle(.borderedProminent)
        case .pending, .active:
            Button("Cancel Challenge") {
                Task { await store.cancelChallenge(listId: list.id, challengeId: challenge.id) }
            }
        default:
            Button("Dismiss") { store.dismissChallenge(listId: list.id) }
        }
    }

    private func answer(_ accept: Bool) {
        Task { await store.answerChallenge(listId: list.id, challengeId: challenge.id, accept: accept) }
    }
}
