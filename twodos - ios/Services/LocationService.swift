import Foundation
import CoreLocation
import OSLog

/// Location permission, one-shot positioning, and background geofencing.
///
/// ## Why `CLMonitor` and not a position stream
/// The Flutter app polled `getPositionStream` and evaluated distances itself.
/// That only works while the app is running, so "remind me when I get to the
/// shop" arrived whenever you next opened twodos — often hours late, often in
/// the car park on the way home. `CLMonitor` hands the geofences to the system,
/// which wakes the app on a real boundary crossing even from a cold start, and
/// costs no battery in between.
///
/// ## What keeps it cheap
/// Handing the fences to the system is necessary but not sufficient — the app
/// can still make an inherently cheap feature expensive. Four rules:
///
/// 1. **Nothing is monitored that cannot produce a reminder.** A finished list,
///    an unanswered invite, an archived list, or the whole feature switched off
///    in Settings all mean zero fences, not fences whose events get discarded
///    after the app has already been woken to look at them.
/// 2. **A crossing costs no network.** Everything needed to write the
///    notification is persisted alongside the fence, so a cold background
///    relaunch notifies straight from disk. Waking the cellular radio to fetch
///    a list costs far more than the geofence that woke us.
/// 3. **A re-sync that changes nothing does nothing.** `syncGeofences` runs
///    after every list refresh — every foreground, every pull-to-refresh. When
///    the desired set matches what is already registered it returns before
///    touching CoreLocation or the disk.
/// 4. **Low Power Mode monitors less.** The user has told the OS that battery
///    beats completeness; the fence budget shrinks to match.
///
/// ## Permission staging
/// Three separate moments, never bundled:
/// 1. Nothing at all until the user opens the map picker.
/// 2. **While Using** when they tap "Use my location" or save a place.
/// 3. **Always** only *after* a location reminder exists, with an explanation
///    of what it buys them. iOS also surfaces its own retrospective prompt
///    later; both paths are fine because the feature already works — it just
///    works better with Always.
@MainActor
@Observable
final class LocationService: NSObject {
    static let shared = LocationService()

    private let logger = Logger(subsystem: "app.twodos", category: "location")
    private let manager = CLLocationManager()
    private var monitor: CLMonitor?
    private var monitoringTask: Task<Void, Never>?

    /// Live authorisation status, kept current by the delegate.
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// The most recent fix, if the user has asked for one this session.
    private(set) var lastKnownLocation: CLLocation?
    /// True while a one-shot location request is in flight.
    private(set) var isLocating = false

    /// Invoked on a real boundary crossing. Set by `AppStore`.
    var onCrossing: ((_ crossing: GeofenceCrossing) -> Void)?

    /// Asks the owner to re-run ``syncGeofences(from:)`` with the current lists.
    ///
    /// Used when something *other* than the lists changes what should be
    /// monitored — Low Power Mode toggling, or the user's own reminder switch.
    /// Set by `AppStore`.
    var onNeedsResync: (() -> Void)?

    @ObservationIgnored private var pendingLocationContinuation: CheckedContinuation<CLLocation?, Never>?
    @ObservationIgnored private var pendingAuthorizationContinuations: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var locationTimeout: Task<Void, Never>?
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    /// A plain alphanumeric identifier, *not* reverse-DNS.
    ///
    /// `CLMonitor` persists a monitor's conditions under this name so they
    /// survive termination, and it validates the name as a store identifier
    /// rather than as a bundle-style string. `"app.twodos.geofences"` was
    /// rejected with "Monitor name is not valid", and because the initialiser
    /// is non-throwing that failure was invisible: `ensureMonitor()` returned an
    /// unusable monitor, every `add` silently did nothing, and no geofence ever
    /// fired. Keep this free of dots, slashes and spaces.
    private let monitorName = "TwodosGeofenceMonitor"

    /// iOS monitors at most 20 regions per app.
    private static let maxFences = 20

    /// Low Power Mode monitors far fewer. Each extra region is more work for the
    /// system's location daemon, and a user who has just turned on Low Power
    /// Mode would rather lose the eleventh-most-relevant reminder than the
    /// battery. The fences that survive are the most relevant ones, because the
    /// candidate list is already sorted by urgency.
    private static let lowPowerMaxFences = 6

    // MARK: - Persisted bookkeeping
    //
    // All three of these outlive the process, because the app is routinely
    // relaunched from cold *by* the crossing it needs to report. They are
    // mirrored in memory and written through only on a real change: a geofence
    // wake should not pay for a plist rewrite it does not need.

    private let defaults = UserDefaults.standard
    private enum StoreKey {
        static let states = "geofence.states"
        static let shapes = "geofence.shapes"
        static let facts = "geofence.facts"
    }

    /// Last known inside/outside per fence. See ``handle(event:)``.
    @ObservationIgnored private var statesCache: [String: Bool] = [:]
    /// identifier → "lat,lng,radius", so a moved pin is noticed.
    @ObservationIgnored private var shapesCache: [String: String] = [:]
    /// identifier → everything needed to write the reminder without a network.
    @ObservationIgnored private var factsCache: [String: GeofenceFact] = [:]

    /// Whether this launch has reconciled against `CLMonitor`'s own idea of what
    /// is registered. Until it has, ``syncGeofences(from:)`` may not take the
    /// cheap path — the persisted shapes are only a belief about the monitor's
    /// contents, and the first sync of a launch is where that belief is checked.
    @ObservationIgnored private var hasReconciledThisLaunch = false

    private var fenceStates: [String: Bool] {
        get { statesCache }
        set {
            guard newValue != statesCache else { return }
            statesCache = newValue
            defaults.set(newValue, forKey: StoreKey.states)
        }
    }

    private var fenceShapes: [String: String] {
        get { shapesCache }
        set {
            guard newValue != shapesCache else { return }
            shapesCache = newValue
            defaults.set(newValue, forKey: StoreKey.shapes)
        }
    }

    private var fenceFacts: [String: GeofenceFact] {
        get { factsCache }
        set {
            guard newValue != factsCache else { return }
            factsCache = newValue
            defaults.set(try? JSONEncoder().encode(newValue), forKey: StoreKey.facts)
        }
    }

    /// How many places were dropped because the budget was reached, so the UI
    /// can say so rather than letting reminders fail silently.
    private(set) var droppedPlaceCount: Int = 0

    nonisolated private static func shape(lat: Double, lng: Double, radius: Double) -> String {
        // Rounded so floating-point noise from a round trip through JSON does
        // not read as "the user moved the pin".
        String(format: "%.6f,%.6f,%.0f", lat, lng, radius)
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus

        statesCache = defaults.dictionary(forKey: StoreKey.states) as? [String: Bool] ?? [:]
        shapesCache = defaults.dictionary(forKey: StoreKey.shapes) as? [String: String] ?? [:]
        factsCache = defaults.data(forKey: StoreKey.facts)
            .flatMap { try? JSONDecoder().decode([String: GeofenceFact].self, from: $0) } ?? [:]

        observePowerState()
    }

    // MARK: - Status

    var hasAnyPermission: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var hasAlwaysPermission: Bool { authorization == .authorizedAlways }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// True when geofences would silently not fire in the background — the state
    /// that deserves an explanatory prompt rather than silent failure.
    var needsAlwaysUpgrade: Bool { authorization == .authorizedWhenInUse }

    /// How many fences are currently monitored. Surfaced so a settings screen
    /// can be honest about what the app is asking the system to watch.
    private(set) var monitoredCount: Int = 0

    /// Whether the fence budget is currently reduced.
    var isConservingPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    private var fenceBudget: Int {
        isConservingPower ? Self.lowPowerMaxFences : Self.maxFences
    }

    /// The user's own switch. With it off there is nothing a crossing could do,
    /// so there is no reason to have the system watching for one.
    private var remindersEnabled: Bool { NotificationSettingsStore.shared.locationReminders }

    // MARK: - Permission requests

    /// Step 2: asks for While Using. Safe to call repeatedly — iOS shows the
    /// prompt only once.
    func requestWhenInUse() {
        guard authorization == .notDetermined else { return }
        logger.info("Requesting When In Use authorization.")
        manager.requestWhenInUseAuthorization()
    }

    /// Step 3: asks to upgrade to Always. Only meaningful once While Using has
    /// been granted; iOS ignores it otherwise.
    func requestAlways() {
        guard authorization == .authorizedWhenInUse else { return }
        logger.info("Requesting Always authorization.")
        manager.requestAlwaysAuthorization()
    }

    // MARK: - One-shot location

    /// Returns the device's current position, requesting permission first if the
    /// user has never been asked. Returns `nil` if permission is refused or the
    /// fix times out — callers fall back to letting the user search or drop a pin.
    ///
    /// This is the only place the app ever powers up positioning itself, and it
    /// is always one shot: `requestLocation` stops the hardware as soon as it has
    /// an answer, and the watchdog below stops it if it never gets one.
    func currentLocation() async -> CLLocation? {
        if authorization == .notDetermined {
            requestWhenInUse()
            await awaitAuthorizationAnswer()
        }
        guard hasAnyPermission else { return nil }

        isLocating = true
        defer { isLocating = false }

        let location = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            pendingLocationContinuation = continuation
            manager.requestLocation()

            // requestLocation can hang on a device with no signal. The watchdog
            // is cancelled the moment a fix lands, so a successful lookup does
            // not leave a timer running for another twelve seconds.
            locationTimeout?.cancel()
            locationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, let pending = self.pendingLocationContinuation else { return }
                self.pendingLocationContinuation = nil
                // Nothing is coming; let go of the hardware rather than leaving
                // an unanswered request holding it.
                self.manager.stopUpdatingLocation()
                pending.resume(returning: self.lastKnownLocation)
            }
        }
        locationTimeout?.cancel()
        locationTimeout = nil

        if let location { lastKnownLocation = location }
        return location
    }

    /// Waits for the user to answer the system permission prompt.
    ///
    /// Replaces a 40-iteration polling loop. The delegate already tells us the
    /// moment the answer arrives, so waiting on that costs nothing while the
    /// sheet is up instead of waking every 100ms for four seconds.
    private func awaitAuthorizationAnswer() async {
        guard authorization == .notDetermined else { return }

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.resumeAuthorizationWaiters()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingAuthorizationContinuations.append(continuation)
        }
        timeout.cancel()
    }

    private func resumeAuthorizationWaiters() {
        let waiting = pendingAuthorizationContinuations
        pendingAuthorizationContinuations = []
        for continuation in waiting { continuation.resume() }
    }

    // MARK: - Geofencing

    /// Attaches the persisted monitor and starts consuming its events.
    ///
    /// Called at launch *before* any network work, which is what makes a
    /// background relaunch cheap. iOS wakes the app for a crossing, the stream
    /// delivers the event, and the reminder is written from data already on
    /// disk. Previously the stream was only ever started at the end of a
    /// successful list fetch, so a wake with no network did nothing at all: the
    /// app was started, spent a radio cycle failing to reach the API, and
    /// dropped the crossing it had been woken for.
    func resumeMonitoring() async {
        guard remindersEnabled else {
            // The switch may have been turned off in a build that left the
            // fences registered, or on another launch entirely. Either way the
            // system should not still be watching.
            await removeAllGeofences()
            return
        }
        guard hasAnyPermission, !shapesCache.isEmpty else { return }
        _ = await ensureMonitor()
        startMonitoringEvents()
        monitoredCount = shapesCache.count
    }

    /// Replaces the monitored set with exactly the fences these lists describe.
    ///
    /// Called after every list refresh, so a fence removed on another device
    /// disappears here too.
    ///
    /// A list only earns a fence if a crossing could actually produce a
    /// reminder, which rules out more than it sounds: an archived list, an
    /// invite the user has not accepted, and a list whose every item is already
    /// ticked off. Each of those previously kept a live fence that could wake
    /// the app from cold, at full cost, only for the result to be thrown away.
    ///
    /// What survives is prioritised by soonest deadline then most recently
    /// updated, so the budget removes the least relevant fences rather than an
    /// arbitrary tail.
    func syncGeofences(from lists: [TodoList], currentUserId: String? = nil) async {
        guard remindersEnabled else {
            await removeAllGeofences()
            return
        }
        guard hasAnyPermission else { return }

        let candidates = lists
            .filter(Self.deservesFence)
            .sorted { lhs, rhs in
                switch (lhs.doBefore, rhs.doBefore) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return (lhs.effectiveUpdatedAt ?? .distantPast) > (rhs.effectiveUpdatedAt ?? .distantPast)
                }
            }

        // Build the whole plan before touching CoreLocation, so the cheap path
        // below is a dictionary comparison rather than a round trip.
        //
        // Everything is keyed by place, so a list and three of its items pinned
        // at the same shop collapse into a single region carrying four targets.
        var wanted: [String: PlannedFence] = [:]
        var desiredFacts: [String: GeofenceFact] = [:]
        /// First-seen order, which follows the urgency sort above. Needed
        /// because trimming to the budget must drop the *least* relevant place,
        /// and a dictionary has no order to reason about.
        var placeOrder: [String] = []

        func bind(_ fence: PlannedFence, _ target: GeofenceFact.Target, placeName: String?) {
            if wanted[fence.identifier] == nil { placeOrder.append(fence.identifier) }
            wanted[fence.identifier] = fence
            var fact = desiredFacts[fence.identifier]
                ?? GeofenceFact(placeName: placeName, targets: [])
            // The first place name wins; a later unnamed pin should not blank a
            // named one, and two names for one coordinate is not worth a choice.
            if fact.placeName == nil { fact.placeName = placeName }
            fact.targets.append(target)
            desiredFacts[fence.identifier] = fact
        }

        for list in candidates {
            let notifiesPartner = !list.isEffectivelyPersonal(currentUserId: currentUserId)

            if let fence = PlannedFence(lat: list.locationLat, lng: list.locationLng,
                                        radius: list.locationRadius) {
                bind(fence, GeofenceFact.Target(
                    listId: list.id,
                    todoId: nil,
                    label: list.label,
                    listLabel: list.label,
                    triggerValue: list.trigger.rawValue,
                    notifiesPartner: notifiesPartner
                ), placeName: list.locationName)
            }

            // Items carry their own pins. Only open ones: a ticked-off item has
            // nothing left to remind anyone about, and leaving its fence up
            // would wake the app at a shop for something already bought.
            for todo in list.todos where !todo.done && todo.hasLocation {
                guard let fence = PlannedFence(lat: todo.locationLat, lng: todo.locationLng,
                                               radius: todo.locationRadius) else { continue }
                bind(fence, GeofenceFact.Target(
                    listId: list.id,
                    todoId: todo.id,
                    label: todo.title,
                    listLabel: list.label,
                    triggerValue: todo.trigger.rawValue,
                    notifiesPartner: notifiesPartner
                ), placeName: todo.locationName ?? list.locationName)
            }
        }

        // The budget applies to *places*, which is the resource iOS actually
        // meters. Trimming happens here rather than during the walk above so a
        // place is never half-populated.
        if placeOrder.count > fenceBudget {
            let dropped = placeOrder.count - fenceBudget
            let keep = Set(placeOrder.prefix(fenceBudget))
            wanted = wanted.filter { keep.contains($0.key) }
            desiredFacts = desiredFacts.filter { keep.contains($0.key) }
            logger.warning("Geofence budget reached; dropped \(dropped) least-urgent place(s).")
        }
        droppedPlaceCount = max(0, placeOrder.count - fenceBudget)

        // Facts change whenever an item is ticked, far more often than the fence
        // itself moves. They are written outside the comparison below so a
        // changed count refreshes the snapshot without provoking a pointless
        // re-registration of the region.
        fenceFacts = desiredFacts

        if hasReconciledThisLaunch, wanted.mapValues(\.shape) == shapesCache {
            monitoredCount = shapesCache.count
            return
        }

        let monitor = await ensureMonitor()
        let existing = Set(await monitor.identifiers)

        var shapes = shapesCache
        var states = statesCache

        for identifier in existing.subtracting(wanted.keys) {
            await monitor.remove(identifier)
            shapes[identifier] = nil
            states[identifier] = nil
        }
        // Anything we believed was registered but the monitor has never heard of
        // is bookkeeping for a fence that no longer exists.
        for identifier in Set(shapes.keys).subtracting(wanted.keys) {
            shapes[identifier] = nil
            states[identifier] = nil
        }

        for (id, fence) in wanted {
            // Re-register when the pin moved or the radius changed. Adding under
            // an identifier that is already monitored is a no-op, so without
            // this an edited reminder kept firing on its *old* location — the
            // fence only ever matched wherever it was first dropped.
            let isMonitored = existing.contains(id)
            guard !isMonitored || shapes[id] != fence.shape else { continue }

            if isMonitored {
                await monitor.remove(id)
                states[id] = nil // its inside/outside answer was about the old place
            }

            await monitor.add(fence.condition, identifier: id)
            shapes[id] = fence.shape
        }

        fenceShapes = shapes
        fenceStates = states
        hasReconciledThisLaunch = true
        monitoredCount = shapes.count

        logger.info("Monitoring \(shapes.count) geofence(s)\(self.isConservingPower ? " (low power budget)" : "").")

        if shapes.isEmpty {
            // Nothing left to watch for. Drop the stream rather than leaving a
            // task parked on a monitor with no conditions.
            monitoringTask?.cancel()
            monitoringTask = nil
        } else {
            startMonitoringEvents()
        }
    }

    /// One monitored place, resolved once so the shape used for the comparison
    /// and the region handed to CoreLocation can never disagree.
    private struct PlannedFence {
        let center: CLLocationCoordinate2D
        let radius: Double
        let shape: String
        /// Stable across launches and identical for two pins at the same place,
        /// which is what makes the coalescing work at all.
        let identifier: String

        init?(lat: Double?, lng: Double?, radius rawRadius: Double?) {
            guard let lat, let lng else { return nil }
            center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            // iOS is unreliable below ~100 m, and a fence that small makes the
            // system fall back on GPS far more often than a realistic one does.
            radius = max(rawRadius ?? 200, 100)
            shape = LocationService.shape(lat: lat, lng: lng, radius: radius)
            identifier = LocationService.placeIdentifier(lat: lat, lng: lng, radius: radius)
        }

        var condition: CLMonitor.CircularGeographicCondition {
            CLMonitor.CircularGeographicCondition(center: center, radius: radius)
        }
    }

    /// A stable, CoreLocation-safe name for a place.
    ///
    /// Coordinates are rounded to four decimals — about 11 m — before they reach
    /// the key. Two pins on the same shop are then the same fence even when they
    /// were dropped by hand rather than picked from search, while genuinely
    /// different places stay apart. Radius is part of the key because two
    /// reminders at one shop with different radii really are different regions.
    ///
    /// Kept to letters, digits and underscores: `CLMonitor` validated the
    /// monitor's own name as a store identifier and rejected dots, and there is
    /// no reason to find out the hard way whether condition identifiers are
    /// checked the same way.
    nonisolated static func placeIdentifier(lat: Double, lng: Double, radius: Double) -> String {
        func part(_ value: Double, scale: Double) -> String {
            let scaled = Int((value * scale).rounded())
            return scaled < 0 ? "n\(-scaled)" : "\(scaled)"
        }
        return "p_\(part(lat, scale: 10_000))_\(part(lng, scale: 10_000))_\(part(radius, scale: 1))"
    }

    /// Whether this list is worth walking for places at all.
    ///
    /// A list earns consideration if either it or one of its open items is
    /// pinned somewhere. `isComplete` is not a rejection on its own any more:
    /// a list can be "complete" by item count while still carrying its own
    /// list-level pin, and per-item fences are filtered by `done` where they
    /// are built.
    private static func deservesFence(_ list: TodoList) -> Bool {
        guard !list.archived, !list.isPendingInvite else { return false }
        if list.hasLocation && !list.isComplete { return true }
        return list.todos.contains { !$0.done && $0.hasLocation }
    }

    /// Forgets what is registered so the next sync rebuilds from scratch.
    ///
    /// There is no longer a fence *belonging* to a list to remove: a place is
    /// shared by everything pinned there, so clearing one list's reminder can
    /// only ever be answered by recomputing the whole plan. Callers follow this
    /// with `syncGeofences`, which then takes the full path rather than the
    /// dictionary-comparison shortcut.
    func invalidatePlan() {
        hasReconciledThisLaunch = false
    }

    func removeAllGeofences() async {
        // Read before clearing: a device that never registered anything should
        // not construct a monitor purely to find it empty. Constructing one is
        // not free — it restores the persisted condition store from disk.
        let hadFences = !shapesCache.isEmpty

        fenceStates = [:]
        fenceShapes = [:]
        fenceFacts = [:]
        monitoredCount = 0
        hasReconciledThisLaunch = false

        monitoringTask?.cancel()
        monitoringTask = nil

        // Attach if we are not already, because `CLMonitor` restores its
        // persisted conditions when re-created under the same name. Dropping the
        // reference without removing them would leave the system watching fences
        // this app can no longer see.
        //
        // Written out rather than with `??` because the fallback has to await,
        // and `??` takes an autoclosure that cannot — the same reason
        // `APIClient.perform` spells out its token lookup.
        let monitorToClear: CLMonitor?
        if let monitor = self.monitor {
            monitorToClear = monitor
        } else if hadFences {
            monitorToClear = await ensureMonitor()
        } else {
            monitorToClear = nil
        }

        if let monitorToClear {
            for identifier in await monitorToClear.identifiers {
                await monitorToClear.remove(identifier)
            }
        }
        self.monitor = nil
    }

    private func ensureMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(monitorName)
        monitor = created
        return created
    }

    /// Consumes the monitor's event stream. The stream is long-lived and
    /// resumes after a background relaunch, which is the whole point.
    private func startMonitoringEvents() {
        guard monitoringTask == nil, let monitor else { return }
        monitoringTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    guard !Task.isCancelled else { break }
                    self?.handle(event: event)
                }
            } catch {
                self?.logger.warning("Geofence event stream ended: \(error.localizedDescription)")
            }
            // Clear the handle so a later sync can start a fresh stream. Leaving
            // it set meant one ended stream disabled geofencing for the rest of
            // the process's life.
            self?.monitoringTask = nil
        }
    }

    // MARK: - Power state

    /// Re-syncs when Low Power Mode is switched on or off, so the fence budget
    /// follows the user's choice immediately rather than at the next refresh.
    private func observePowerState() {
        powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("Power state changed; low power = \(self.isConservingPower).")
                self.onNeedsResync?()
            }
        }
    }

    // MARK: - Events

    /// Turns monitor events into *crossings*.
    ///
    /// `CLMonitor` reports state, not transitions: it emits an event the moment
    /// a condition is first evaluated, so simply mapping `.satisfied` → arrive
    /// fired a reminder every time the fences were registered. Standing at home,
    /// outside the shop, each launch emitted `.unsatisfied` and announced
    /// "Leaving Tesco" — and a fence added while already inside announced an
    /// arrival that never happened.
    ///
    /// So a crossing is a *change* of state. The comparison is against a
    /// persisted value rather than one held in memory, which is the part that
    /// matters: the app is routinely relaunched from cold *by* the crossing it
    /// needs to report, and an in-memory baseline would be empty at exactly
    /// that moment and swallow the real event. With the previous state on disk,
    /// a background relaunch still sees outside → inside and fires.
    ///
    /// Only the genuinely first sighting of a fence is recorded silently.
    private func handle(event: CLMonitor.Event) {
        let listId = event.identifier

        let isInside: Bool
        switch event.state {
        case .satisfied: isInside = true
        case .unsatisfied: isInside = false
        default:
            // `.unknown` — no usable answer yet, so nothing to compare against.
            logger.debug("Geofence \(listId, privacy: .public) → unknown; ignoring.")
            return
        }

        let previous = statesCache[listId]
        // Writing through the property only touches the disk on a real change,
        // which matters here: this runs on a background wake-up, and the common
        // event by far is a re-report of a state we already knew.
        var states = statesCache
        states[listId] = isInside
        fenceStates = states

        switch GeofenceTransition.resolve(previous: previous, current: isInside) {
        case .baseline:
            logger.info("Geofence \(listId, privacy: .public) baseline: inside=\(isInside).")
        case .unchanged:
            break
        case .crossed(let trigger):
            // A region watches both directions because CoreLocation offers no
            // one-way geofence, so arriving at a place that only holds "when I
            // leave" reminders must produce nothing. Filtering here — rather
            // than in `AppStore` — means the rest of the app is never woken for
            // a crossing that could not have said anything.
            guard let fact = factsCache[listId] else {
                logger.debug("Geofence \(listId, privacy: .public) has no snapshot; ignoring.")
                return
            }
            let matched = fact.targets(matching: trigger)
            guard !matched.isEmpty else {
                logger.debug("Geofence \(listId, privacy: .public) crossed the other way; ignoring.")
                return
            }
            logger.info("Place \(listId, privacy: .public) crossed → \(matched.count) reminder(s).")
            onCrossing?(GeofenceCrossing(
                placeId: listId,
                placeName: fact.placeName,
                trigger: trigger,
                targets: matched
            ))
        }
    }
}

// MARK: - Crossings

/// One boundary crossing, already resolved to what should be said about it.
///
/// Carries every reminder waiting at the place rather than one, because a place
/// is the unit of monitoring: arriving at the supermarket with four things to
/// buy is one event, and reporting it as four would buzz the user four times for
/// a single walk through one door.
struct GeofenceCrossing: Equatable, Sendable {
    let placeId: String
    let placeName: String?
    let trigger: GeofenceTrigger
    /// Only the targets that care about this direction, never empty.
    let targets: [GeofenceFact.Target]

    /// The list to open when the notification is tapped.
    ///
    /// The first target's list: with one reminder it is exactly right, and with
    /// several from different lists any choice is arbitrary, so the most urgent
    /// one wins by virtue of being first.
    var primaryListId: String { targets[0].listId }

    /// True when at least one waiting reminder belongs to a shared list, and the
    /// partner should therefore be told. Checked as a group so a single API call
    /// covers the whole crossing.
    var notifiesPartner: Bool { targets.contains { $0.notifiesPartner } }
}

// MARK: - Fence snapshot

/// One monitored *place*, and everything bound to it.
///
/// ## Why a place and not a task
/// Once individual items can carry a location, the obvious implementation —
/// one region per item — breaks immediately. iOS monitors at most 20 regions
/// per app, so a user with thirty pinned items silently loses ten of them, and
/// every extra region is more work for the system's location daemon.
///
/// So the unit of monitoring is the *place*. Ten items pinned at the same
/// supermarket are one region, not ten. The fence count is bounded by how many
/// distinct places a person visits — home, work, the gym, two shops — which
/// stays small no matter how many tasks they pin to them.
///
/// It also fixes a problem the naive version would have created: arriving at
/// the shop with five things to buy would have buzzed five times. One region
/// means one notification, listing what is waiting there.
///
/// ## Why it is persisted
/// So a crossing never needs the network. iOS wakes the app from cold for a
/// boundary crossing, and answering that with a session refresh and a full list
/// fetch costs a radio cycle for text that has been known since the reminder was
/// created.
struct GeofenceFact: Codable, Equatable, Sendable {
    /// What the user called this place, e.g. "Tesco Metro".
    var placeName: String?
    /// Everything waiting here.
    var targets: [Target]

    /// One reminder bound to this place — a whole list, or a single item.
    struct Target: Codable, Equatable, Sendable {
        var listId: String
        /// `nil` when the whole list is pinned here rather than one item.
        var todoId: String?
        /// What to say: the item's title, or the list's label.
        var label: String
        /// Always the list's name, so a per-item reminder can still say where
        /// the item lives.
        var listLabel: String
        /// Stored as the wire value so this stays decodable if the enum grows.
        var triggerValue: String
        /// Whether there is a second person to tell about the crossing. False
        /// for a personal list, which is what lets the common case skip the API
        /// call entirely.
        var notifiesPartner: Bool

        var trigger: GeofenceTrigger { GeofenceTrigger(apiValue: triggerValue) }
    }

    /// The targets that care about this direction of travel.
    ///
    /// A region watches both directions because CoreLocation offers no one-way
    /// geofence, so arriving somewhere that only has "when I leave" reminders
    /// must produce nothing at all.
    func targets(matching trigger: GeofenceTrigger) -> [Target] {
        targets.filter { $0.trigger == trigger }
    }
}

/// The rule that turns a pair of fence states into a crossing, extracted so it
/// can be tested without CoreLocation, a device, or a real journey.
enum GeofenceTransition: Equatable {
    /// First time this fence has been seen; record, announce nothing.
    case baseline
    /// The state was re-reported unchanged — the common case on every resync.
    case unchanged
    /// A genuine boundary crossing.
    case crossed(GeofenceTrigger)

    static func resolve(previous: Bool?, current: Bool) -> GeofenceTransition {
        guard let previous else { return .baseline }
        guard previous != current else { return .unchanged }
        return .crossed(current ? .arrive : .leave)
    }
}

// MARK: - Delegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.logger.info("Authorization is now \(status.rawValue).")
            self.resumeAuthorizationWaiters()
            if status == .denied || status == .restricted {
                await self.removeAllGeofences()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.lastKnownLocation = location
            if let pending = self.pendingLocationContinuation {
                self.pendingLocationContinuation = nil
                self.locationTimeout?.cancel()
                pending.resume(returning: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.logger.warning("Location failed: \(error.localizedDescription)")
            if let pending = self.pendingLocationContinuation {
                self.pendingLocationContinuation = nil
                self.locationTimeout?.cancel()
                pending.resume(returning: nil)
            }
        }
    }
}
