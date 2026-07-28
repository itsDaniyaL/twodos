import Foundation
import SwiftUI
import OSLog

/// State for the watch app.
///
/// Three sources feed it, in increasing order of authority:
/// 1. **Disk cache** — drawn instantly on launch so the app is never blank.
/// 2. **Phone snapshot** — arrives over `WatchConnectivity`, usually within a
///    second of launch when the phone is nearby.
/// 3. **The API** — fetched directly by the watch, and the only source that can
///    also *write*.
///
/// Ticking an item off applies immediately and locally, then goes to the API. On
/// a watch this matters more than on a phone: you are looking at the screen for
/// a second or two, and a round trip you have to wait for is a round trip you
/// will walk away from.
@MainActor
@Observable
final class WatchStore {

    private let logger = Logger(subsystem: "app.twodos.watch", category: "store")
    private let api = APIClient.shared
    private let bridge = WatchConnectivityBridge.shared

    enum Phase: Equatable {
        case loading
        /// No session has ever reached the watch.
        case needsPhone
        /// The phone's token has expired; only the phone can renew it.
        case sessionExpired
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var lists: [WatchList] = []
    private(set) var isSyncing = false
    /// Set when a write fails, so the row can show it rather than silently
    /// reverting and leaving the user unsure what happened.
    private(set) var lastError: String?

    /// Set when a complication tap should open a specific list.
    var pendingListToOpen: String?

    /// Items ticked while offline, replayed on the next successful sync.
    private var pendingToggles: [String: Bool] = [:]

    /// Acts on a `twodos://` URL handed over by a complication.
    ///
    /// Held rather than acted on when the watch has no session yet: the app is
    /// launching into the "open twodos on iPhone" screen, and the intent is
    /// replayed once the lists arrive. Dropping it would make a tap on a
    /// complication do nothing on exactly the launch where the user was most
    /// deliberately asking for something.
    func handle(deepLink: DeepLink?) {
        guard case .list(let id) = deepLink else { return }
        pendingListToOpen = id
    }

    init() {
        bridge.onSessionReceived = { [weak self] _, _ in
            Task { @MainActor in
                self?.phase = .ready
                await self?.refresh()
            }
        }
        bridge.onSnapshotReceived = { [weak self] snapshot in
            Task { @MainActor in self?.applySnapshot(snapshot) }
        }
    }

    // MARK: - Lifecycle

    func start() async {
        #if DEBUG
        if Self.wantsSampleData {
            loadSample()
            return
        }
        #endif

        lists = WatchCache.load()
        bridge.activate()

        if WatchSessionStore.shared.token == nil {
            phase = bridge.hasReceivedSession ? .sessionExpired : .needsPhone
            // The phone may be right there and simply not have pushed yet.
            bridge.requestSync()
            return
        }

        if WatchSessionStore.shared.isExpired {
            phase = .sessionExpired
            bridge.requestSync()
            return
        }

        phase = .ready
        await refresh()
    }

    // MARK: - Sync

    func refresh() async {
        guard let token = WatchSessionStore.shared.token else {
            bridge.requestSync()
            return
        }
        await api.setStandaloneToken(token)

        isSyncing = true
        defer { isSyncing = false }

        await flushPendingToggles()

        do {
            let fetched = try await api.lists()
            lists = WatchList.snapshot(from: fetched, currentUserId: nil)
            lastError = nil
            // Before `persist()`: the snapshot it writes records whether anyone
            // is signed in, and reading a phase we are about to change would
            // publish "not signed in" over a successful refresh.
            phase = .ready
            persist()
        } catch APIError.unauthorized {
            // Only the phone holds a refresh token, so this is its problem.
            phase = .sessionExpired
            bridge.requestSync()
        } catch {
            // Offline is not worth a message here — the cached lists are still
            // on screen and still tickable.
            logger.debug("Refresh failed: \(error.localizedDescription)")
        }
    }

    /// Writes the lists everywhere outside this object that draws them: the disk
    /// cache the app reads on launch, and the snapshot the complications read.
    ///
    /// Every path that changes `lists` calls this, including the optimistic tick
    /// in `setItem` and its rollback — so a complication reflects a tap on the
    /// watch immediately rather than waiting for the phone to hear about it and
    /// push a new payload back.
    private func persist() {
        WatchCache.save(lists)
        WidgetPublisher.publish(.make(fromWatch: lists, isSignedIn: phase == .ready))
    }

    private func applySnapshot(_ snapshot: [WatchList]) {
        guard !snapshot.isEmpty || lists.isEmpty else { return }
        lists = snapshot
        if phase != .ready, WatchSessionStore.shared.token != nil { phase = .ready }
        persist()
    }

    // MARK: - Writes

    /// Ticks an item off, or back on.
    func setItem(listId: String, itemId: String, done: Bool) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == listId }),
              let itemIndex = lists[listIndex].items.firstIndex(where: { $0.id == itemId })
        else { return }

        let previous = lists[listIndex].items[itemIndex].done
        lists[listIndex].items[itemIndex].done = done
        persist()
        WatchHaptics.play(done ? .success : .click)

        guard let token = WatchSessionStore.shared.token else {
            pendingToggles[itemId] = done
            return
        }
        await api.setStandaloneToken(token)

        do {
            _ = try await api.setTodoDone(listId: listId, todoId: itemId, done: done)
            pendingToggles[itemId] = nil
            lastError = nil
            // The server has it; the phone does not know yet.
            bridge.notifyMutation()
        } catch APIError.offline {
            // Keep the optimistic state and replay when there is a network.
            pendingToggles[itemId] = done
        } catch {
            lists[listIndex].items[itemIndex].done = previous
            persist()
            lastError = "Couldn't save that"
            WatchHaptics.play(.failure)
        }
    }

    /// Adds an item. On the watch this is nearly always dictation or Scribble.
    func addItem(listId: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let token = WatchSessionStore.shared.token else { return }
        await api.setStandaloneToken(token)

        // Shown straight away with a placeholder id; the refresh below replaces
        // it with the server's copy.
        if let index = lists.firstIndex(where: { $0.id == listId }) {
            lists[index].items.append(
                WatchItem(id: "pending-\(UUID().uuidString)", title: trimmed, done: false, dueAt: nil)
            )
        }
        WatchHaptics.play(.click)

        do {
            _ = try await api.createTodo(listId: listId, title: trimmed)
            bridge.notifyMutation()
            await refresh()
        } catch {
            lastError = "Couldn't add that"
            WatchHaptics.play(.failure)
            await refresh()
        }
    }

    private func flushPendingToggles() async {
        guard !pendingToggles.isEmpty else { return }
        var didFlushAny = false
        for (itemId, done) in pendingToggles {
            guard let list = lists.first(where: { $0.items.contains { $0.id == itemId } }) else {
                pendingToggles[itemId] = nil
                continue
            }
            if (try? await api.setTodoDone(listId: list.id, todoId: itemId, done: done)) != nil {
                pendingToggles[itemId] = nil
                didFlushAny = true
            }
        }
        // Ticks made offline reach the server here rather than in `setItem`, so
        // this is the only place the phone can be told about them.
        if didFlushAny { bridge.notifyMutation() }
    }

    // MARK: - Derived

    func list(id: String) -> WatchList? { lists.first { $0.id == id } }

    /// Everything still to do, newest-deadline-first. The watch's landing view,
    /// because "what do I need to do" beats "which list was it in" on a wrist.
    var allOpenItems: [(list: WatchList, item: WatchItem)] {
        lists.flatMap { list in
            list.items.filter { !$0.done }.map { (list: list, item: $0) }
        }
        .sorted { lhs, rhs in
            switch (lhs.item.dueAt ?? lhs.list.dueAt, rhs.item.dueAt ?? rhs.list.dueAt) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    var totalOpenCount: Int { lists.reduce(0) { $0 + $1.openCount } }

    /// The soonest deadline anywhere, for the header summary.
    var nextDue: Date? {
        allOpenItems.compactMap { $0.item.dueAt ?? $0.list.dueAt }.min()
    }

    func clearError() { lastError = nil }

    #if DEBUG
    /// Injects fixture lists. Here rather than in the sample file because
    /// `lists` is `private(set)`, which Swift scopes to this file.
    func applySample(_ sample: [WatchList]) {
        lists = sample
        phase = .ready
    }
    #endif
}

// MARK: - Disk cache

/// Last known lists, so the app draws content on the very first frame.
enum WatchCache {
    private static var url: URL {
        URL.cachesDirectory.appending(path: "watch-lists.json")
    }

    static func load() -> [WatchList] {
        guard let data = try? Data(contentsOf: url),
              let lists = try? JSONDecoder().decode([WatchList].self, from: data)
        else { return [] }
        return lists
    }

    static func save(_ lists: [WatchList]) {
        guard let data = try? JSONEncoder().encode(lists) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
