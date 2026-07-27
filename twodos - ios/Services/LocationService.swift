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
    var onCrossing: ((_ listId: String, _ trigger: GeofenceTrigger) -> Void)?

    private var pendingLocationContinuation: CheckedContinuation<CLLocation?, Never>?
    private let monitorName = "app.twodos.geofences"

    /// Last known inside/outside per fence, and the shape each fence was
    /// registered with. Both persist because both questions outlive the process
    /// — see ``handle(event:)`` and ``syncGeofences(from:)``.
    private let defaults = UserDefaults.standard
    private enum StoreKey {
        static let states = "geofence.states"
        static let shapes = "geofence.shapes"
    }

    private var fenceStates: [String: Bool] {
        get { defaults.dictionary(forKey: StoreKey.states) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: StoreKey.states) }
    }

    /// identifier → "lat,lng,radius", so a moved pin is noticed.
    private var fenceShapes: [String: String] {
        get { defaults.dictionary(forKey: StoreKey.shapes) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: StoreKey.shapes) }
    }

    private static func shape(lat: Double, lng: Double, radius: Double) -> String {
        // Rounded so floating-point noise from a round trip through JSON does
        // not read as "the user moved the pin".
        String(format: "%.6f,%.6f,%.0f", lat, lng, radius)
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
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
    func currentLocation() async -> CLLocation? {
        if authorization == .notDetermined {
            requestWhenInUse()
            // Give the delegate a moment to report the user's answer.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                if authorization != .notDetermined { break }
            }
        }
        guard hasAnyPermission else { return nil }

        isLocating = true
        defer { isLocating = false }

        let location = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            pendingLocationContinuation = continuation
            manager.requestLocation()

            // requestLocation can hang on a device with no signal.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, let pending = self.pendingLocationContinuation else { return }
                self.pendingLocationContinuation = nil
                pending.resume(returning: self.lastKnownLocation)
            }
        }
        if let location { lastKnownLocation = location }
        return location
    }

    // MARK: - Geofencing

    /// Replaces the monitored set with exactly the fences these lists describe.
    ///
    /// Called after every list refresh, so a fence removed on another device
    /// disappears here too. iOS caps an app at 20 monitored regions; lists are
    /// prioritised by soonest deadline then most recently updated so the cap
    /// removes the least relevant fences rather than an arbitrary tail.
    func syncGeofences(from lists: [TodoList]) async {
        guard hasAnyPermission else { return }

        let candidates = lists
            .filter { $0.hasLocation && !$0.archived }
            .sorted { lhs, rhs in
                switch (lhs.doBefore, rhs.doBefore) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return (lhs.effectiveUpdatedAt ?? .distantPast) > (rhs.effectiveUpdatedAt ?? .distantPast)
                }
            }
            .prefix(20)

        let monitor = await ensureMonitor()
        let wanted = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let existing = Set(await monitor.identifiers)

        var shapes = fenceShapes
        var states = fenceStates

        for identifier in existing.subtracting(wanted.keys) {
            await monitor.remove(identifier)
            shapes[identifier] = nil
            states[identifier] = nil
        }

        for (id, list) in wanted {
            guard let lat = list.locationLat, let lng = list.locationLng else { continue }
            let radius = max(list.locationRadius ?? 200, 100) // iOS is unreliable below ~100 m
            let shape = Self.shape(lat: lat, lng: lng, radius: radius)

            // Re-register when the pin moved or the radius changed. Adding under
            // an identifier that is already monitored is a no-op, so without
            // this an edited reminder kept firing on its *old* location — the
            // fence only ever matched wherever it was first dropped.
            let isMonitored = existing.contains(id)
            guard !isMonitored || shapes[id] != shape else { continue }

            if isMonitored {
                await monitor.remove(id)
                states[id] = nil // its inside/outside answer was about the old place
            }

            await monitor.add(
                CLMonitor.CircularGeographicCondition(
                    center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    radius: radius
                ),
                identifier: id
            )
            shapes[id] = shape
        }

        fenceShapes = shapes
        fenceStates = states

        logger.info("Monitoring \(wanted.count) geofence(s).")
        startMonitoringEvents()
    }

    func removeGeofence(listId: String) async {
        // The bookkeeping is dropped whether or not a monitor exists, so a fence
        // removed before one was created cannot leave a stale state behind that
        // a later fence with the same id would be compared against.
        fenceStates[listId] = nil
        fenceShapes[listId] = nil
        guard let monitor else { return }
        await monitor.remove(listId)
    }

    func removeAllGeofences() async {
        fenceStates = [:]
        fenceShapes = [:]
        guard let monitor else { return }
        for identifier in await monitor.identifiers {
            await monitor.remove(identifier)
        }
        monitoringTask?.cancel()
        monitoringTask = nil
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
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            guard let self, let monitor = self.monitor else { return }
            do {
                for try await event in await monitor.events {
                    guard !Task.isCancelled else { return }
                    self.handle(event: event)
                }
            } catch {
                self.logger.warning("Geofence event stream ended: \(error.localizedDescription)")
            }
        }
    }

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

        let previous = fenceStates[listId]
        fenceStates[listId] = isInside

        switch GeofenceTransition.resolve(previous: previous, current: isInside) {
        case .baseline:
            logger.info("Geofence \(listId, privacy: .public) baseline: inside=\(isInside).")
        case .unchanged:
            break
        case .crossed(let trigger):
            logger.info("Geofence \(listId, privacy: .public) crossed → inside=\(isInside).")
            onCrossing?(listId, trigger)
        }
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
                pending.resume(returning: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.logger.warning("Location failed: \(error.localizedDescription)")
            if let pending = self.pendingLocationContinuation {
                self.pendingLocationContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }
}
