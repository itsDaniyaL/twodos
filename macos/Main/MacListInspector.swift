import SwiftUI

/// Everything about a list that is not its tasks.
///
/// iOS reaches these through five separate sheets — options, info, colour,
/// deadline, location — because a phone has nowhere to put them. A Mac window
/// has a whole edge going spare, and an inspector is the platform's answer to
/// "settings for the thing currently selected": it stays open while you work,
/// it changes as the selection changes, and nothing it contains covers up what
/// it is describing.
///
/// Toggled from the toolbar and with ⌥⌘I, the shortcut every Apple app uses
/// for the inspector.
struct MacListInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var location
    let list: TodoList

    @State private var labelDraft = ""
    @State private var isEditingLabel = false
    @State private var deadlineDraft = Date()
    @State private var deadlineTarget: AlarmTarget = .both
    @State private var isPickingPlace = false
    @State private var challengeDeadline = Date().addingTimeInterval(86_400)
    @State private var challengeError: String?
    @State private var isStartingChallenge = false

    private var live: TodoList { store.list(id: list.id) ?? list }

    var body: some View {
        Form {
            Section("Name") {
                if isEditingLabel {
                    TextField("List name", text: $labelDraft)
                        .onSubmit(commitRename)
                        .onExitCommand { isEditingLabel = false }
                    Button("Save", action: commitRename)
                        .disabled(labelDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    LabeledContent(live.label) {
                        Button("Rename") {
                            labelDraft = live.label
                            isEditingLabel = true
                        }
                    }
                }
            }

            Section("Colour") {
                // A wrapping grid of swatches, not a menu: colour is the one
                // setting where seeing the options *is* choosing.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 8)], spacing: 8) {
                    ForEach(ListTint.all) { tint in
                        Button {
                            Task { await store.setListColor(id: live.id, tint: tint) }
                        } label: {
                            Circle()
                                .fill(tint.color)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if tint.hex == live.tint.hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(tint.name)
                        .accessibilityLabel(tint.name)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Priority") {
                Picker("Priority", selection: Binding(
                    get: { live.priority },
                    set: { value in Task { await store.setListPriority(id: live.id, priority: value) } }
                )) {
                    Text("None").tag(ListPriority?.none)
                    ForEach(ListPriority.allCases) { Text($0.title).tag(ListPriority?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Deadline") {
                if let due = live.doBefore {
                    LabeledContent("Due", value: Format.fullDateTime(due))
                    Button("Remove deadline") {
                        Task { await store.setListDeadline(id: live.id, date: nil, target: nil) }
                    }
                } else {
                    DatePicker("Due", selection: $deadlineDraft)
                    // Only a shared list has somebody else to remind.
                    if isShared {
                        Picker("Remind", selection: $deadlineTarget) {
                            ForEach(AlarmTarget.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Button("Set deadline") {
                        Task {
                            await store.setListDeadline(id: live.id, date: deadlineDraft,
                                                        target: isShared ? deadlineTarget : .me)
                        }
                    }
                }
            }

            Section("Place reminder") {
                // Said here because it is broken and fixable: a pinned place
                // with location off is a reminder that silently never fires.
                if live.hasLocation && location.isDenied {
                    Label("Location is off for twodos, so this won't remind you.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings…", action: MacLocationSettings.open)
                }
                if live.hasLocation {
                    LabeledContent("Place", value: live.locationName ?? "Pinned")
                    LabeledContent("When", value: live.trigger == .arrive ? "On arriving" : "On leaving")
                    Button("Remove place") {
                        Task { await store.clearListLocation(listId: live.id) }
                    }
                } else {
                    Text("Pin a place and this list reminds you when you get there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose a place…") { isPickingPlace = true }
                }
            }

            Section("Details") {
                Toggle("Favourite", isOn: Binding(
                    get: { live.favorite },
                    set: { _ in Task { await store.toggleFavorite(id: live.id) } }
                ))
                if let created = live.createdAt {
                    LabeledContent("Created", value: Format.fullDateTime(created))
                }
                if let updated = live.effectiveUpdatedAt {
                    LabeledContent("Last change", value: Format.relative(updated))
                }
                LabeledContent("Progress", value: Format.progress(done: live.completedCount, total: live.totalCount))
            }

            if let counterpart = store.counterpart(for: live) {
                sharedWith(counterpart)
            }

            if isShared && !live.isPendingInvite {
                challengeSection
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPickingPlace) { MacPlacePickerSheet(target: .list(live)) }
        .onChange(of: live.id, initial: true) { _, _ in
            isEditingLabel = false
            deadlineDraft = live.doBefore ?? Date().addingTimeInterval(3_600)
        }
    }

    private var isShared: Bool { !live.isEffectivelyPersonal(currentUserId: store.currentUserId) }

    /// Never "someone": the person if the app knows them, the address the
    /// invitation went to if not, and in every case what is actually going on.
    private func sharedWith(_ counterpart: ListCounterpart) -> some View {
        let invite = store.sentInvite(forList: live.id)
        return Section("Shared with") {
            HStack(spacing: 8) {
                if let person = counterpart.partner {
                    MacAvatar(partner: person, size: 28)
                } else {
                    Image(systemName: counterpart.icon)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(counterpart.partner?.displayName ?? counterpart.name ?? counterpart.statusText)
                    if let secondary = counterpart.partner?.handle ?? invite?.invitee.email {
                        Text(secondary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let badge = counterpart.badge {
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(counterpart.isPending ? Brand.warning : Brand.danger)
                } else if store.isPartnerOnline(counterpart.partner?.id) {
                    Text("Online").font(.caption).foregroundStyle(Brand.success)
                }
            }
            if counterpart.state != .accepted {
                Text(counterpart.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if invite?.invitee.hasAccount == false {
                LabeledContent("Account", value: String(localized: "Not on twodos yet"))
            }
            // Only an invitation to an address with no account ever expires.
            if counterpart.isPending, let expiry = invite?.expiresAt ?? live.inviteExpiresAt {
                LabeledContent("Invite expires", value: Format.relative(expiry))
            }
        }
    }

    /// Proposing a race. The other person has to accept before it starts, and
    /// the live one is shown above the tasks rather than here.
    @ViewBuilder
    private var challengeSection: some View {
        let current = store.challenge(for: live.id)
        if current == nil || current?.isLive == false {
            Section("Challenge") {
                Text("Race each other to tick off the open tasks before a deadline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DatePicker("Ends", selection: $challengeDeadline, in: Date()...)
                if let challengeError {
                    Text(challengeError).font(.caption).foregroundStyle(Brand.danger)
                }
                Button("Start Challenge") { startChallenge() }
                    .disabled(isStartingChallenge || !live.todos.contains { !$0.done })
            }
        }
    }

    private func startChallenge() {
        isStartingChallenge = true
        challengeError = nil
        Task {
            defer { isStartingChallenge = false }
            do {
                // Empty means every open task on the list.
                try await store.startChallenge(listId: live.id, deadline: challengeDeadline, todoIds: [])
            } catch {
                challengeError = error.userMessage
            }
        }
    }

    private func commitRename() {
        let name = labelDraft.trimmingCharacters(in: .whitespaces)
        isEditingLabel = false
        guard !name.isEmpty, name != live.label else { return }
        Task { await store.renameList(id: live.id, to: name) }
    }
}
