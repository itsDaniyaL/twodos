import SwiftUI

/// Everything you can change about a list.
///
/// This was four titled sections of nested cards, with an inline colour
/// scroller and a segmented priority control embedded among them — five
/// different row shapes competing in one sheet. It is now a single list of
/// uniform rows, each stating its current value on the right and drilling in if
/// there is a choice to make. Nothing was removed; the settings that need a
/// picker got one instead of trying to fit inline.
///
/// Delete stays visually apart at the bottom, because a destructive action
/// sitting flush in a list of harmless ones is how people delete lists by
/// accident.
struct ListOptionsSheet: View {
    let listId: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showingDeadline = false
    @State private var showingLocationPicker = false
    @State private var showingColors = false
    @State private var choosingPriority = false
    @State private var confirmingDelete = false

    private var list: TodoList? { store.list(id: listId) }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()

                if let list {
                    ScrollView {
                        VStack(spacing: 22) {
                            settings(list)
                            deleteRow(list)
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("List settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .alert("Rename list", isPresented: $isRenaming) {
                TextField("List name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    Task { await store.renameList(id: listId, to: trimmed) }
                }
            }
            .confirmationDialog(
                "Delete “\(list?.label ?? "this list")”?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete list", role: .destructive) {
                    Task {
                        await store.deleteList(id: listId)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteWarning)
            }
            .sheet(isPresented: $showingDeadline) {
                if let list {
                    DeadlineSheet(
                        title: list.label,
                        initialDate: list.doBefore,
                        showsTargetPicker: !list.isEffectivelyPersonal(currentUserId: store.currentUserId),
                        onSave: { date, target in
                            Task { await store.setListDeadline(id: listId, date: date, target: target) }
                        },
                        onClear: list.doBefore == nil ? nil : {
                            Task { await store.setListDeadline(id: listId, date: nil, target: nil) }
                        }
                    )
                }
            }
            .fullScreenCover(isPresented: $showingLocationPicker) {
                if let list {
                    LocationPickerView(list: list)
                }
            }
            .sheet(isPresented: $showingColors) {
                if let list {
                    ListColorSheet(
                        selected: list.tint,
                        onSelect: { tint in
                            Task { await store.setListColor(id: listId, tint: tint) }
                        }
                    )
                }
            }
            .confirmationDialog("Priority", isPresented: $choosingPriority, titleVisibility: .visible) {
                Button("Urgent") { setPriority(.urgent) }
                Button("Not urgent") { setPriority(.nonUrgent) }
                Button("Normal") { setPriority(nil) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Urgent lists sort to the top and are marked on their card.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Rows

    /// One card, uniform rows, every current value visible on the right.
    private func settings(_ list: TodoList) -> some View {
        GlassCard {
            VStack(spacing: 0) {
                GlassRow(
                    icon: "textformat",
                    title: "Name",
                    subtitle: list.label,
                    showsChevron: true,
                    action: {
                        draftName = list.label
                        isRenaming = true
                    }
                )
                GlassDivider()

                GlassRow(
                    icon: "paintpalette",
                    iconTint: list.tint.color,
                    title: "Colour",
                    subtitle: list.tint.name,
                    showsChevron: true,
                    action: { showingColors = true }
                ) {
                    Circle()
                        .fill(list.tint.color)
                        .frame(width: 22, height: 22)
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
                }
                GlassDivider()

                GlassRow(
                    icon: list.favorite ? "star.fill" : "star",
                    iconTint: Brand.lime,
                    title: "Favourite",
                    subtitle: "Sorts above everything else"
                ) {
                    Toggle("", isOn: Binding(
                        get: { list.favorite },
                        set: { _ in
                            Haptics.selection()
                            Task { await store.toggleFavorite(id: listId) }
                        }
                    ))
                    .labelsHidden()
                }
                GlassDivider()

                GlassRow(
                    icon: list.priority == .urgent ? "exclamationmark.2" : "flag",
                    iconTint: list.priority == .urgent ? Brand.danger : nil,
                    title: "Priority",
                    subtitle: list.priority?.title ?? "Normal",
                    showsChevron: true,
                    action: { choosingPriority = true }
                )
                GlassDivider()

                GlassRow(
                    icon: "calendar.badge.clock",
                    iconTint: list.doBefore.map { Format.deadlineTint($0) } ?? Color.accentColor,
                    title: "Deadline",
                    subtitle: list.doBefore.map { Format.fullDateTime($0) } ?? "Not set",
                    showsChevron: true,
                    action: { showingDeadline = true }
                )
                GlassDivider()

                GlassRow(
                    icon: list.hasLocation ? "mappin.circle.fill" : "mappin.circle",
                    iconTint: Brand.info,
                    title: "Location",
                    subtitle: locationSubtitle(list),
                    showsChevron: true,
                    action: {
                        Haptics.medium()
                        showingLocationPicker = true
                    }
                )
                GlassDivider()

                GlassRow(
                    icon: "eraser",
                    title: "Clear completed",
                    subtitle: list.completedCount == 0
                        ? "Nothing completed yet"
                        : "Removes \(list.completedCount) item\(list.completedCount == 1 ? "" : "s")",
                    action: list.completedCount == 0 ? nil : {
                        Haptics.light()
                        Task { await store.clearCompleted(listId: listId) }
                    }
                )
                .opacity(list.completedCount == 0 ? 0.5 : 1)
                GlassDivider()

                GlassRow(
                    icon: list.archived ? "tray.and.arrow.up" : "archivebox",
                    title: list.archived ? "Move back to Lists" : "Archive",
                    subtitle: list.archived
                        ? "Puts it back with your active lists"
                        : "Hides it without deleting anything",
                    action: {
                        Haptics.light()
                        Task { await store.archiveList(id: listId, archived: !list.archived) }
                    }
                )
            }
        }
    }

    private func deleteRow(_ list: TodoList) -> some View {
        GlassCard(tint: Brand.danger) {
            GlassRow(
                icon: "trash",
                title: "Delete list",
                subtitle: "\(list.totalCount) item\(list.totalCount == 1 ? "" : "s") will go with it",
                role: .destructive,
                action: { confirmingDelete = true }
            )
        }
    }

    private func setPriority(_ priority: ListPriority?) {
        Haptics.selection()
        Task { await store.setListPriority(id: listId, priority: priority) }
    }

    // MARK: - Helpers

    private func locationSubtitle(_ list: TodoList) -> String {
        guard list.hasLocation else { return "Not set" }
        let place = list.locationName ?? "Saved place"
        let radius = list.locationRadius.map { " · \(Format.distance(metres: $0))" } ?? ""
        return "\(list.trigger.shortTitle) at \(place)\(radius)"
    }

    /// The API deletes a shared list differently depending on who asks, so the
    /// warning has to say which one is about to happen.
    private var deleteWarning: String {
        guard let list else { return "This can't be undone." }
        let isOwner = list.createdBy == store.currentUserId
        if list.isEffectivelyPersonal(currentUserId: store.currentUserId) {
            return "This permanently deletes the list and everything in it."
        }
        return isOwner
            ? "This deletes the list for both of you, permanently."
            : "This removes the list from your account. Your partner keeps their copy."
    }
}
