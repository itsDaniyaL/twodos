import SwiftUI

/// One list on the watch.
///
/// Adding an item uses `TextFieldLink`, which hands off to the system's own
/// input screen — dictation, Scribble, the emoji grid and a paired keyboard, all
/// for free. Rolling our own text entry would give you a worse version of one of
/// those four.
struct WatchListDetailView: View {
    let listId: String

    @Environment(WatchStore.self) private var store

    private var list: WatchList? { store.list(id: listId) }

    var body: some View {
        List {
            if let list {
                context(for: list)
                addButton(for: list)

                let open = list.items.filter { !$0.done }
                let done = list.items.filter(\.done)

                if open.isEmpty && !list.items.isEmpty {
                    allDone
                }

                ForEach(open) { item in
                    WatchItemRow(item: item, tint: tint) {
                        await store.setItem(listId: listId, itemId: item.id, done: true)
                    }
                }

                if !done.isEmpty {
                    Section("Done") {
                        ForEach(done) { item in
                            WatchItemRow(item: item, tint: tint) {
                                await store.setItem(listId: listId, itemId: item.id, done: false)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.carousel)
        .navigationTitle(list?.label ?? "List")
        .refreshable { await store.refresh() }
    }

    private var tint: Color {
        ListTint.all[safe: list?.tintIndex ?? 0]?.color ?? Brand.meadow
    }

    /// Who else is on this list, and where it is pinned.
    ///
    /// The phone puts both in the navigation bar — an avatar and a subtitle —
    /// but watchOS gives the title one line and no room for either, so they
    /// take a single compact row at the top instead. Both are omitted when
    /// absent, which is the common case, so a personal list loses nothing.
    @ViewBuilder
    private func context(for list: WatchList) -> some View {
        if list.partnerName != nil || list.locationLabel != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let partner = list.partnerName {
                    Label(partner, systemImage: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let place = list.locationLabel {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }
    }

    private func addButton(for list: WatchList) -> some View {
        TextFieldLink(prompt: Text(list.label)) {
            Label("Add item", systemImage: "plus.circle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
        } onSubmit: { text in
            Task { await store.addItem(listId: listId, title: text) }
        }
        .listRowBackground(Color.clear)
    }

    private var allDone: some View {
        VStack(spacing: 6) {
            TwodosMark(tickStyle: AnyShapeStyle(tint))
                .frame(width: 26, height: 26)
            Text("All done")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }
}
