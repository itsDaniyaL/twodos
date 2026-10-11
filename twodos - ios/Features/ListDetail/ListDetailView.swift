import SwiftUI
import PhotosUI

/// A single list and its items.
///
/// The add field lives at the bottom, pinned above the keyboard, so adding five
/// things in a row never requires reaching for a button. Completed items sink
/// into a collapsible section rather than staying interleaved.
struct ListDetailView: View {
    let listId: String
    /// How to leave.
    ///
    /// On the phone this view is pushed, so `dismiss()` pops it. In the split
    /// view it is the detail column and there is nothing to pop — `dismiss()` is
    /// a no-op there, which made "Back to lists" a button that took the tap and
    /// did nothing. The sidebar passes a closure that clears the path instead.
    var onLeave: (() -> Void)?

    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(AppCommands.self) private var commands
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var draft = ""
    /// The optional second line of a new item. Hidden until asked for, so the
    /// bar stays a single field for the nine adds in ten that have no detail.
    @State private var draftNotes = ""
    @State private var isAddingNotes = false
    @State private var showCompleted = true
    @State private var showingOptions = false
    @State private var showingInfo = false
    /// Swaps the action bar into the inline colour picker.
    @State private var isPickingColor = false
    @State private var editingTodo: Todo?
    /// Which field the editor opens on; set alongside `editingTodo`.
    @State private var editFocus: EditTodoSheet.Field = .title
    /// The item whose place is being pinned.
    @State private var locationTodo: Todo?
    /// Owned here so swiping a second item closes the first.
    @State private var swipeCoordinator = SwipeCoordinator()
    @State private var deadlineTarget: DeadlineTarget?
    @State private var showingChallenge = false
    @State private var typingTask: Task<Void, Never>?
    /// "Just my tasks". Offered once you have taken something on, because
    /// until then there is nothing for it to narrow to.
    @State private var onlyMine = false
    /// The open row a dragged item is hovering over, drawn with a marker so
    /// the drop has a visible destination.
    @State private var dropTargetId: String?
    /// Files queued for the item being typed, uploaded once it exists.
    @State private var draftAttachments: [AttachmentDraft] = []
    @State private var newPhotoItems: [PhotosPickerItem] = []
    @State private var showingNewFileImporter = false
    @FocusState private var addFieldFocused: Bool
    @FocusState private var notesFieldFocused: Bool

    private var list: TodoList? { store.list(id: listId) }

    /// Pops on the phone, clears the split view's selection on the tablet.
    private func leave() {
        if let onLeave { onLeave() } else { dismiss() }
    }

    var body: some View {
        ZStack {
            ScreenBackground()

            if let list {
                content(for: list)
            } else {
                // The list vanished — deleted here or by the partner.
                EmptyStateView(
                    icon: "tray",
                    title: "This list is gone",
                    message: "It was deleted. Head back to see the rest.",
                    actionTitle: "Back to lists",
                    action: { leave() }
                )
            }
        }
        .navigationTitle(list?.label ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(locationSubtitle ?? "")
        // On the phone a list is a focused, one-thing-at-a-time screen with its
        // own action bar along the bottom. Leaving the tab bar there stacks two
        // rows of chrome on the same edge and invites a tap that throws away
        // where you were. It comes back on the way out.
        //
        // **Not on iPad.** With `.sidebarAdaptable` the tab bar *is* the
        // sidebar, on the leading edge, where nothing is stacked on anything —
        // and in the split layout a list is open in the detail column almost all
        // the time, so hiding it removed the only route to Alarms, Activity,
        // You and Search for as long as a list was showing.
        .toolbar(sizeClass == .compact ? .hidden : .automatic, for: .tabBar)
        .toolbar { toolbar }
        // The banner and the names on the rows can be as stale as the rows
        // themselves, so a pull brings all three up to date.
        .refreshable {
            async let items: Void = store.refreshList(id: listId, reportErrors: true)
            async let challenge: Void = store.refreshChallenge(listId: listId)
            async let partners: Void = store.refreshPartners()
            _ = await (items, challenge, partners)
        }
        .sheet(isPresented: $showingOptions) { ListOptionsSheet(listId: listId) }
        .sheet(isPresented: $showingInfo) { ListInfoSheet(listId: listId) }
        .sheet(isPresented: $showingChallenge) { ChallengeSheet(listId: listId) }
        // Separate from the list's own load: the scoreboard has its own endpoint
        // and its own socket event, so folding it in would mean refetching every
        // item to learn two integers.
        //
        // The list itself is read on the way in as well. Its rows otherwise come
        // from whatever the last full load cached — so a list opened from a
        // notification showed the state from before the change it announced.
        .task(id: listId) {
            async let items: Void = store.refreshList(id: listId)
            async let challenge: Void = store.refreshChallenge(listId: listId)
            _ = await (items, challenge)
        }
        .environment(\.swipeCoordinator, swipeCoordinator)
        .sheet(item: $locationTodo) { todo in
            LocationPickerView(listId: listId, todo: todo)
        }
        .sheet(item: $editingTodo) { todo in
            EditTodoSheet(listId: listId, todo: todo, initialFocus: editFocus)
        }
        .sheet(item: $deadlineTarget) { target in
            DeadlineSheet(
                title: target.title,
                initialDate: target.currentDate,
                showsTargetPicker: list?.isEffectivelyPersonal(currentUserId: store.currentUserId) == false,
                onSave: { date, alarmTarget in
                    Task { await apply(deadline: date, alarmTarget: alarmTarget, to: target) }
                },
                onClear: target.currentDate == nil ? nil : {
                    Task { await apply(deadline: nil, alarmTarget: nil, to: target) }
                }
            )
        }
        // ⌘⇧N. The menu item is greyed out unless a list is on screen, which
        // is what `openListId` is for.
        .onChange(of: commands.newItemRequests) { _, _ in
            guard list?.archived != true else { return }
            addFieldFocused = true
        }
        .onAppear { commands.openListId = listId }
        .onDisappear {
            stopTyping()
            if commands.openListId == listId { commands.openListId = nil }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for list: TodoList) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    header(for: list)

                    if showsAssigneeFilter(for: list) {
                        assigneeFilter(for: list)
                    }

                    if list.todos.isEmpty {
                        emptyState
                    } else if onlyMine && visibleTodos(in: list).isEmpty {
                        EmptyStateView(
                            icon: "person.crop.circle.badge.checkmark",
                            title: "Nothing on your plate",
                            message: "No task on this list is yours right now. Say “I'll do it” on one to see it here.",
                            actionTitle: "Show everything",
                            action: { withAnimation(Motion.content) { onlyMine = false } }
                        )
                        .padding(.top, 24)
                    } else {
                        openItems(for: list)
                        if list.isComplete && !onlyMine { allDoneBanner(for: list) }
                        completedItems(for: list)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .motion(Motion.content, value: list.todos)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollEdgeEffectStyle(.soft, for: .top)

            addBar(for: list)
            actionBar(for: list)
        }
    }

    /// The list's pinned place, rendered as the navigation subtitle.
    ///
    /// It has now been a scrolling banner and a pinned row, and both were the
    /// same mistake in different sizes: a geofence is a *property of the list*,
    /// like its name, and properties belong with the title rather than in the
    /// column where the items live. As a subtitle it costs no row at all, never
    /// scrolls away, and sits exactly where you look to confirm which list you
    /// are in. The collaborator made the same journey to the avatar beside it.
    ///
    /// Returns nil when there is no place set, which leaves the title alone.
    private var locationSubtitle: String? {
        guard let list, list.hasLocation else { return nil }
        let place = list.locationName ?? "a saved place"
        guard let radius = list.locationRadius else { return "\(list.trigger.shortTitle) at \(place)" }
        return "\(list.trigger.shortTitle) at \(place) · \(Format.distance(metres: radius))"
    }

    /// The person this list is shared with, if anyone.
    private var collaborator: Partner? {
        guard let list else { return nil }
        // The other person, from either side: for an invitee `partnerId` is
        // their own id, and the person they share with is the creator.
        return store.counterpart(for: list)?.partner
    }

    /// Only things that are *temporarily* true live here. Deadlines and the
    /// archived notice are states worth interrupting the items for; who the
    /// list is shared with is not, and has moved to the pinned bar above.
    @ViewBuilder
    private func header(for list: TodoList) -> some View {
        // Emitted only when it has something to say. An empty `VStack` still
        // draws its own padding, which left a visible gap above the first item
        // on every list without a deadline — i.e. most of them.
        let geofenceIsCrippled = list.hasLocation && location.needsAlwaysUpgrade
        // A finished list has nothing left to be late for. The "all done" mark
        // below already says what there is to say, and an overdue banner over
        // the top of it is just wrong.
        let showsDeadline = list.doBefore != nil && !list.isComplete

        let challenge = store.challenge(for: listId)

        if showsDeadline || list.archived || geofenceIsCrippled || challenge != nil {
            VStack(spacing: 8) {
                // Above the deadline banner: while a challenge is running it is
                // the thing you opened the list to look at.
                if let challenge {
                    ChallengeScoreboard(
                        challenge: challenge,
                        me: store.currentUserId,
                        myName: String(localized: "You"),
                        theirName: collaborator?.displayName ?? String(localized: "Your partner"),
                        theirId: list.partnerId == store.currentUserId ? nil : list.partnerId,
                        onAccept: { answer(challenge, accept: true) },
                        onDecline: { answer(challenge, accept: false) },
                        onCancel: {
                            Task { await store.cancelChallenge(listId: listId, challengeId: challenge.id) }
                        },
                        onDismiss: { store.dismissChallenge(listId: listId) }
                    )
                }

                if showsDeadline, let deadline = list.doBefore {
                    DeadlineBanner(deadline: deadline) {
                        deadlineTarget = .list(currentDate: deadline, title: list.label)
                    }
                }

                // The place itself is in the subtitle; this is here because it
                // is broken and fixable, which is a different kind of fact. A
                // geofence that silently only works with the app open is worse
                // than no geofence, so it gets said out loud.
                if geofenceIsCrippled {
                    InlineBanner(
                        kind: .warning,
                        title: "This reminder only works while twodos is open",
                        message: "Allow location access “Always” so it can reach you in the background.",
                        actionTitle: "Open Settings",
                        action: openSettings
                    )
                }

                if list.archived {
                    InlineBanner(
                        kind: .info,
                        title: "This list is archived",
                        message: "It won't show up with your active lists.",
                        actionTitle: "Move back to Lists",
                        action: { Task { await store.archiveList(id: listId, archived: false) } }
                    )
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "text.badge.plus",
            title: "Nothing here yet",
            message: "Add your first item using the field below."
        )
        .padding(.top, 40)
    }

    /// Shown once every item is ticked off. Small, quiet, and uses the app's own
    /// mark — a moment of completion is worth marking, but not with confetti.
    private func allDoneBanner(for list: TodoList) -> some View {
        VStack(spacing: 8) {
            TwodosMark(tickStyle: AnyShapeStyle(Brand.meadow))
                .frame(width: 30, height: 30)
            Text("All done")
                .font(.subheadline.weight(.semibold))
            Text(list.hasPartner && !list.isEffectivelyPersonal(currentUserId: store.currentUserId)
                 ? "Nothing left on this one for either of you."
                 : "Nothing left on this one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All items complete")
    }

    // MARK: - Who does what

    /// The list as it is being looked at — everything, or just your share.
    private func visibleTodos(in list: TodoList) -> [Todo] {
        guard onlyMine, let me = store.currentUserId else { return list.todos }
        return list.todos.filter { $0.assigneeId == me }
    }

    /// Only on a list with somebody else on it, and only once you have said
    /// "I'll do it" to something. Kept on screen while it is switched on, so
    /// finishing your last task cannot strand you in an empty filter.
    private func showsAssigneeFilter(for list: TodoList) -> Bool {
        guard !list.isEffectivelyPersonal(currentUserId: store.currentUserId) else { return false }
        return onlyMine || list.todos.contains { $0.assigneeId != nil && $0.assigneeId == store.currentUserId }
    }

    private func assigneeFilter(for list: TodoList) -> some View {
        let mine = list.todos.count { $0.assigneeId != nil && $0.assigneeId == store.currentUserId && !$0.done }
        return Picker("Show", selection: Binding(
            get: { onlyMine },
            set: { value in withAnimation(Motion.content) { onlyMine = value } }
        )) {
            Text("All tasks").tag(false)
            Text("Just my tasks · \(mine)").tag(true)
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 4)
        .accessibilityHint("Shows only the tasks you said you'd do")
    }

    private func assign(_ choice: AssigneeChoice, todo: Todo, in list: TodoList) {
        guard let me = store.currentUserId else { return }
        let target: String?
        switch choice {
        case .me:
            target = me
        case .partner:
            // The other person is whichever of the two ids is not yours.
            let other = list.createdBy == me ? list.partnerId : list.createdBy
            guard let other, other != me else { return }
            target = other
        case .nobody:
            target = nil
        }
        guard target != todo.assigneeId else { return }
        Task { await store.setTodoAssignee(listId: listId, todoId: todo.id, assigneeId: target) }
    }

    private var otherPersonId: String? {
        guard let list, let me = store.currentUserId else { return nil }
        let other = list.createdBy == me ? list.partnerId : list.createdBy
        return other == me ? nil : other
    }

    @ViewBuilder
    private func row(
        for todo: Todo,
        in list: TodoList,
        done: Bool,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil
    ) -> some View {
        let shared = !list.isEffectivelyPersonal(currentUserId: store.currentUserId)
        let takesMedia = list.mediaAllowance?.enabled == true
        TodoRow(
            todo: todo,
            listId: listId,
            onToggle: { Task { await store.setTodo(listId: listId, todoId: todo.id, done: !done) } },
            onEdit: { editFocus = .title; editingTodo = todo },
            onEditNotes: { editFocus = .notes; editingTodo = todo },
            onSetDeadline: {
                deadlineTarget = .item(todoId: todo.id, currentDate: todo.doBefore, title: todo.title)
            },
            onSetLocation: { locationTodo = todo },
            onAssign: shared && !done ? { assign($0, todo: todo, in: list) } : nil,
            assigneeLabel: shared ? store.assigneeLabel(for: todo) : nil,
            assignedToMe: todo.assigneeId != nil && todo.assigneeId == store.currentUserId,
            assignedToPartner: todo.assigneeId != nil && todo.assigneeId == otherPersonId,
            partnerName: store.counterpart(for: list)?.name,
            onAttachments: takesMedia || todo.hasMedia
                ? { editFocus = .attachments; editingTodo = todo }
                : nil,
            isInChallenge: done ? false : isInChallenge(todo),
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onDelete: { Task { await store.deleteTodo(listId: listId, todoId: todo.id) } }
        )
    }

    @ViewBuilder
    private func openItems(for list: TodoList) -> some View {
        let open = visibleTodos(in: list).filter { !$0.done }
        if !open.isEmpty {
            ForEach(Array(open.enumerated()), id: \.element.id) { index, todo in
                let reorderable = canReorder(list)
                let moveUp: (() -> Void)? = reorderable && index > 0
                    ? { Task { await store.moveTodo(listId: listId, todoId: todo.id, by: -1) } }
                    : nil
                let moveDown: (() -> Void)? = reorderable && index < open.count - 1
                    ? { Task { await store.moveTodo(listId: listId, todoId: todo.id, by: 1) } }
                    : nil
                row(for: todo, in: list, done: false, onMoveUp: moveUp, onMoveDown: moveDown)
                .transition(.rowInsertion)
                .reorderable(todo: todo, enabled: reorderable, dropTarget: $dropTargetId) { draggedId in
                    Task { await store.moveTodo(listId: listId, todoId: draggedId, to: todo.id) }
                }
            }
        }
    }

    /// Reordering a filtered view would scramble the tasks that are hidden, and
    /// an archived list is read-only — so both turn it off, as on the Mac.
    private func canReorder(_ list: TodoList) -> Bool {
        !onlyMine && !list.archived
    }

    /// Whether ticking this one scores a point.
    ///
    /// Read from the challenge's own task list rather than the item's
    /// `challengeId`, so the flag is right the moment the scoreboard arrives —
    /// the items themselves only pick it up on the next list refresh.
    private func isInChallenge(_ todo: Todo) -> Bool {
        guard let challenge = store.challenge(for: listId), challenge.isRunning else { return false }
        return challenge.todoIds.contains(todo.id) || todo.challengeId == challenge.id
    }

    @ViewBuilder
    private func completedItems(for list: TodoList) -> some View {
        let done = visibleTodos(in: list).filter(\.done)
        if !done.isEmpty {
            VStack(spacing: 8) {
                HStack {
                    Button {
                        withAnimation(Motion.content) { showCompleted.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .rotationEffect(.degrees(showCompleted ? 90 : 0))
                            Text("Completed")
                                .font(.footnote.weight(.semibold))
                            Text("\(done.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("Clear") {
                        Task { await store.clearCompleted(listId: listId) }
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHint("Permanently deletes all completed items")
                }
                .padding(.horizontal, 4)
                .padding(.top, 12)

                if showCompleted {
                    ForEach(done) { todo in
                        row(for: todo, in: list, done: true)
                            .transition(.rowInsertion)
                    }
                }
            }
        }
    }


    private func answer(_ challenge: Challenge, accept: Bool) {
        Task { await store.answerChallenge(listId: listId, challengeId: challenge.id, accept: accept) }
    }

    // MARK: - Add bar

    private func addBar(for list: TodoList) -> some View {
        VStack(spacing: 8) {
            // Return inserts a newline here rather than submitting: a note is
            // the one place a line break is wanted, and the arrow button is
            // right there to send it.
            if isAddingNotes {
                TextField("Notes (optional)", text: $draftNotes, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .focused($notesFieldFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .glassEffect(.regular, in: .rect(cornerRadius: Metrics.controlRadius))
                    .accessibilityLabel("Notes for the new item")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !draftAttachments.isEmpty {
                DraftAttachmentStrip(drafts: $draftAttachments)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                // The notes toggle sits inside the capsule as a suffix rather
                // than as a third button in the row: a second circle beside the
                // send button squeezed the field to the point where a normal
                // item title wrapped.
                HStack(spacing: 8) {
                    TextField("Add an item", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($addFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(addItem)
                        .onChange(of: draft) { _, newValue in
                            handleTypingSignal(isTyping: !newValue.isEmpty)
                        }
                        // Vertical padding stays on the field, so the capsule
                        // is exactly the height it was before the suffix.
                        .padding(.vertical, 11)
                        .accessibilityLabel("New item")

                    Button(action: toggleNotesField) {
                        Image(systemName: isAddingNotes ? "note.text.badge.plus" : "note.text")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isAddingNotes ? Color.accentColor : .secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .motion(Motion.tap, value: isAddingNotes)
                    .accessibilityLabel(isAddingNotes ? "Hide notes" : "Add notes")
                    .accessibilityHint("Adds an optional line of detail to the new item")

                    if let allowance = list.mediaAllowance, allowance.enabled {
                        newItemAttachMenu(allowance: allowance)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .glassEffect(.regular, in: .capsule)

                Button(action: addItem) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .clipShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .scaleEffect(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.85 : 1)
                .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                .motion(Motion.tap, value: draft.isEmpty)
                .accessibilityLabel("Add item")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .motion(Motion.content, value: isAddingNotes)
        .motion(Motion.content, value: draftAttachments.count)
        .disabled(list.archived)
        .opacity(list.archived ? 0.5 : 1)
        .onChange(of: newPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            newPhotoItems = []
            Task {
                for item in items {
                    if let draft = await AttachmentLoader.draft(from: item) { stage(draft, in: list) }
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
                if let draft = AttachmentLoader.draft(from: url) { stage(draft, in: list) }
            }
        }
    }

    /// A paperclip beside the notes toggle, for files that should arrive with
    /// the task rather than be added to it afterwards.
    private func newItemAttachMenu(allowance: MediaAllowance) -> some View {
        let room = max(0, min(allowance.filesPerTask, allowance.remainingOnList) - draftAttachments.count)
        return Menu {
            PhotosPicker(
                selection: $newPhotoItems,
                maxSelectionCount: max(1, room),
                matching: .any(of: [.images, .videos])
            ) {
                Label("Photo or video", systemImage: "photo.on.rectangle")
            }
            Button {
                showingNewFileImporter = true
            } label: {
                Label("File", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: draftAttachments.isEmpty ? "paperclip" : "paperclip.badge.ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(draftAttachments.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .disabled(room == 0)
        .accessibilityLabel("Attach a file to the new item")
    }

    /// Queues a file for the item being typed, refusing what cannot fit now
    /// rather than after the task has been created without it.
    private func stage(_ draft: AttachmentDraft, in list: TodoList) {
        guard let allowance = list.mediaAllowance else { return }
        if allowance.maxFileBytes > 0, draft.sizeBytes > allowance.maxFileBytes {
            store.banner = AppStore.BannerMessage(
                kind: .warning,
                title: "That file is too large",
                message: String(localized: "“\(draft.fileName)” is \(Format.bytes(draft.sizeBytes)). Files can be up to \(Format.bytes(allowance.maxFileBytes)).")
            )
            return
        }
        guard draftAttachments.count < min(allowance.filesPerTask, allowance.remainingOnList) else { return }
        draftAttachments.append(draft)
    }

    private func toggleNotesField() {
        isAddingNotes.toggle()
        if isAddingNotes {
            notesFieldFocused = true
        } else {
            // Hiding the field discards what was in it; keeping invisible text
            // and sending it with the next add would be a nasty surprise.
            draftNotes = ""
            addFieldFocused = true
        }
    }

    // MARK: - Action bar

    /// The settings people actually reach for, one tap from the list itself.
    ///
    /// These all previously lived behind the "…" menu in the navigation bar,
    /// which is both the furthest point from the thumb and the last place
    /// anyone looks. Archiving and setting a reminder are the two things done
    /// most often to a list, so they get named buttons; colour gets a swatch
    /// because it is recognisable without a label; everything else stays one
    /// tap deeper under More.
    @ViewBuilder
    private func actionBar(for list: TodoList) -> some View {
        Group {
            if isPickingColor {
                colorPickerBar(for: list)
            } else {
                HStack(spacing: 8) {
                    ActionBarButton(
                        icon: list.archived ? "tray.and.arrow.up" : "archivebox",
                        title: list.archived ? "Unarchive" : "Archive"
                    ) {
                        Haptics.light()
                        Task { await store.archiveList(id: listId, archived: !list.archived) }
                    }

                    ActionBarButton(icon: "alarm", title: "Set Alarm") {
                        Haptics.light()
                        deadlineTarget = .list(currentDate: list.doBefore, title: list.label)
                    }

                    ActionBarButton(icon: "paintpalette", title: "Colour", swatch: list.tint.color) {
                        Haptics.light()
                        withAnimation(Motion.content) { isPickingColor = true }
                    }

                    ActionBarButton(icon: "ellipsis", title: "More", showsChevron: true) {
                        Haptics.light()
                        showingOptions = true
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
        // Deliberately no `.background(.bar)`. The add field and these buttons
        // sit in a VStack *below* the scroll view, so nothing ever passes
        // underneath them and there is nothing for a scrim to separate. All it
        // did was lay an opaque band across the bottom of the screen that the
        // glass buttons then had to compete with — worst in dark mode, where
        // the band and the buttons resolve to nearly the same grey. Against the
        // app background the glass reads as distinct controls.
    }

    /// Colour picking takes over the action bar rather than opening a sheet:
    /// choosing a colour is a look-at-the-result decision, and a sheet would
    /// cover the very list being recoloured.
    private func colorPickerBar(for list: TodoList) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.content) { isPickingColor = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 38, height: 38)
                    .contentShape(.rect)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Done choosing a colour")

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(ListTint.all) { tint in
                        let isSelected = list.tint.hex.uppercased() == tint.hex.uppercased()
                        Button {
                            Haptics.selection()
                            Task { await store.setListColor(id: listId, tint: tint) }
                        } label: {
                            Circle()
                                .fill(tint.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay {
                                    Circle().strokeBorder(
                                        isSelected ? Color.primary.opacity(0.5) : .clear,
                                        lineWidth: 2
                                    )
                                }
                                .scaleEffect(isSelected ? 1.1 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tint.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .motion(Motion.tap, value: list.colorHex)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await store.toggleFavorite(id: listId) }
            } label: {
                Label(
                    list?.favorite == true ? "Remove from favourites" : "Add to favourites",
                    systemImage: list?.favorite == true ? "star.fill" : "star"
                )
            }
            .tint(list?.favorite == true ? Brand.lime : nil)
            .symbolEffect(.bounce, value: list?.favorite)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        // Settings, deadline and colour all live in the action bar now, so this
        // slot is free for the one thing a shared list should never make you
        // hunt for: who else is in it. The avatar carries presence on its own
        // badge and opens the same details an "i" would have, so nothing is
        // lost by spending the slot on a face instead of a glyph.
        //
        // A personal list has no face to show, and falls back to the glyph —
        // otherwise the details become unreachable on exactly the lists that
        // show no location bar either.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingInfo = true
            } label: {
                if let collaborator {
                    HStack(spacing: 6) {
                        if store.isPartnerTyping(inList: listId) { TypingIndicator() }
                        AvatarView(
                            initials: collaborator.initials,
                            imageURL: collaborator.avatarURL,
                            size: 28,
                            isOnline: list?.isPendingInvite == true
                                ? nil
                                : store.isPartnerOnline(list?.partnerId)
                        )
                    }
                } else {
                    Label("List info", systemImage: "info.circle")
                }
            }
            .accessibilityLabel(collaboratorAccessibilityLabel)
            .accessibilityHint("Opens the list's details")
        }
    }

    /// The avatar is a picture with no inherent label, so VoiceOver gets the
    /// whole story the sighted user reads from the badge.
    private var collaboratorAccessibilityLabel: String {
        guard let collaborator else { return "List info" }
        if let list, let counterpart = store.counterpart(for: list), counterpart.state != .accepted {
            return counterpart.statusText
        }
        if store.isPartnerTyping(inList: listId) {
            return "Shared with \(collaborator.displayName), typing"
        }
        return store.isPartnerOnline(list?.partnerId)
            ? "Shared with \(collaborator.displayName), online now"
            : "Shared with \(collaborator.displayName)"
    }

    // MARK: - Actions

    private func addItem() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let notes = Todo.normalisedNotes(draftNotes)
        let attachments = draftAttachments
        draft = ""
        draftNotes = ""
        draftAttachments = []
        isAddingNotes = false
        stopTyping()
        // Keep focus so a run of items can be typed without re-tapping.
        addFieldFocused = true
        Task { await store.addTodo(listId: listId, title: title, notes: notes, attachments: attachments) }
    }

    /// Debounced typing indicator. The "started" signal is sent immediately so
    /// the partner sees it right away; the "stopped" signal waits three seconds
    /// so it does not flicker between words.
    private func handleTypingSignal(isTyping: Bool) {
        typingTask?.cancel()
        guard isTyping else {
            store.sendTyping(listId: listId, isTyping: false)
            return
        }
        store.sendTyping(listId: listId, isTyping: true)
        typingTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            store.sendTyping(listId: listId, isTyping: false)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func stopTyping() {
        typingTask?.cancel()
        typingTask = nil
        store.sendTyping(listId: listId, isTyping: false)
    }

    private func apply(deadline: Date?, alarmTarget: AlarmTarget?, to target: DeadlineTarget) async {
        switch target {
        case .list:
            await store.setListDeadline(id: listId, date: deadline, target: alarmTarget)
        case .item(let todoId, _, _):
            await store.setTodoDeadline(listId: listId, todoId: todoId, date: deadline, target: alarmTarget)
        }
    }
}

// MARK: - Action bar button

/// One compact glass button in the list's action bar.
///
/// The label is carried at `.caption2` rather than dropped on narrow phones:
/// an unlabelled row of four glyphs is a guessing game, and these are
/// destructive-adjacent enough (archive) that guessing is the wrong mode to put
/// someone in. The text shrinks before it truncates.
struct ActionBarButton: View {
    let icon: String
    let title: String
    /// Drawn in place of the icon's tint — used by Colour to preview itself.
    var swatch: Color?
    var showsChevron: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 15, height: 15)
                        .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1) }
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(localizable: title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        // `.buttonBorderShape`, not `.clipShape`. The glass style draws its own
        // capsule *and* the backing beneath it; clipping to a rounded rect
        // afterwards left the two shapes disagreeing at the corners, which is
        // where that grey came from — the style's backing showing through
        // outside its own capsule. Telling the style the shape instead means
        // there is only ever one.
        .buttonBorderShape(.capsule)
        .accessibilityLabel(title)
    }
}

// MARK: - Deadline target

/// Which thing a deadline sheet is editing.
enum DeadlineTarget: Identifiable {
    case list(currentDate: Date?, title: String)
    case item(todoId: String, currentDate: Date?, title: String)

    var id: String {
        switch self {
        case .list: "list"
        case .item(let todoId, _, _): todoId
        }
    }

    var currentDate: Date? {
        switch self {
        case .list(let date, _), .item(_, let date, _): date
        }
    }

    var title: String {
        switch self {
        case .list(_, let title), .item(_, _, let title): title
        }
    }
}
