import SwiftUI

/// The right-hand column: one list's tasks.
///
/// The add field sits at the *top* rather than the bottom. On a phone the
/// keyboard rises from the bottom and the field rises with it; on a Mac there
/// is no keyboard to make room for, and the natural place to type is under the
/// title where the insertion point already is.
struct MacListDetailPane: View {
    @Environment(AppStore.self) private var store
    @Environment(MacCommands.self) private var commands

    let list: TodoList

    @State private var draft = ""
    @State private var notesDraft = ""
    @State private var showsNotesField = false
    @State private var editingTodoId: String?
    @FocusState private var addFocused: Bool

    private var live: TodoList { store.list(id: list.id) ?? list }

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()

            if live.todos.isEmpty {
                MacEmptyState(
                    icon: "checkmark.circle",
                    title: "Nothing here yet",
                    message: "Add the first task above. Whoever you share this with sees it straight away."
                )
            } else {
                List {
                    Section {
                        ForEach(live.todos.filter { !$0.done }) { todo in
                            MacTodoRow(list: live, todo: todo, editingTodoId: $editingTodoId)
                        }
                        .onMove { indices, destination in
                            var ordered = live.todos.filter { !$0.done }
                            ordered.move(fromOffsets: indices, toOffset: destination)
                            Task { await store.persistOrder(listId: live.id, todos: ordered) }
                        }
                    }

                    let done = live.todos.filter(\.done)
                    if !done.isEmpty {
                        Section("Done") {
                            ForEach(done) { todo in
                                MacTodoRow(list: live, todo: todo, editingTodoId: $editingTodoId)
                            }
                        }
                    }
                }
                .listStyle(.inset)
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
            }
        }
        .onChange(of: commands.newItemRequests) { _, _ in addFocused = true }
        .onAppear { commands.openListId = live.id }
    }

    private var subtitle: String {
        var parts: [String] = []
        if live.totalCount > 0 { parts.append("\(live.completedCount) of \(live.totalCount) done") }
        if let partner = store.partner(id: partnerId) { parts.append("with \(partner.displayName)") }
        return parts.joined(separator: " · ")
    }

    private var partnerId: String? {
        guard live.hasPartner else { return nil }
        return live.partnerId == store.currentUserId ? live.createdBy : live.partnerId
    }

    private var addBar: some View {
        VStack(spacing: 8) {
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

                Button("Add", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if showsNotesField {
                TextField("Note (optional)", text: $notesDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
        .padding(MacMetrics.gutter)
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let notes = notesDraft.trimmingCharacters(in: .whitespaces)
        Task { await store.addTodo(listId: live.id, title: title, notes: notes.isEmpty ? nil : notes) }
        draft = ""
        notesDraft = ""
        addFocused = true
    }
}

/// One task.
struct MacTodoRow: View {
    @Environment(AppStore.self) private var store
    let list: TodoList
    let todo: Todo
    @Binding var editingTodoId: String?

    @State private var titleDraft = ""

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

                if let due = todo.doBefore {
                    Label(Format.deadline(due), systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // Double-click to rename is the desktop gesture; the context menu
        // carries everything the iOS swipe offers, since a mouse cannot swipe.
        .onTapGesture(count: 2) { beginRename() }
        .contextMenu {
            Button("Rename…") { beginRename() }
            Button(todo.done ? "Mark as Not Done" : "Mark as Done") {
                Task { await store.setTodo(listId: list.id, todoId: todo.id, done: !todo.done) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await store.deleteTodo(listId: list.id, todoId: todo.id) }
            }
        }
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
