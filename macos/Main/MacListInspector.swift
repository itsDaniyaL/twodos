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
    let list: TodoList

    @State private var labelDraft = ""
    @State private var isEditingLabel = false
    @State private var deadlineDraft = Date()
    @State private var isPickingPlace = false

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
                    Button("Set deadline") {
                        Task { await store.setListDeadline(id: live.id, date: deadlineDraft, target: .both) }
                    }
                }
            }

            Section("Place reminder") {
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

            if live.hasPartner, let partner = store.partner(id: partnerId) {
                Section("Shared with") {
                    HStack(spacing: 8) {
                        MacAvatar(partner: partner, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(partner.displayName)
                            Text(partner.handle ?? partner.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPickingPlace) { MacPlacePickerSheet(list: live) }
        .onChange(of: live.id, initial: true) { _, _ in
            isEditingLabel = false
            deadlineDraft = live.doBefore ?? Date().addingTimeInterval(3_600)
        }
    }

    private var partnerId: String? {
        guard live.hasPartner else { return nil }
        return live.partnerId == store.currentUserId ? live.createdBy : live.partnerId
    }

    private func commitRename() {
        let name = labelDraft.trimmingCharacters(in: .whitespaces)
        isEditingLabel = false
        guard !name.isEmpty, name != live.label else { return }
        Task { await store.renameList(id: live.id, to: name) }
    }
}
