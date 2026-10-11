import Foundation
import Network
import OSLog

/// Tells the app when a usable network appears.
///
/// ## Why this exists
/// The socket's own reconnection is a backoff timer, which is right for one
/// case — a server that is briefly unreachable — and wrong for the commonest
/// one: walking out of wifi range. The old socket dies at once, the cellular
/// path is up within seconds, and by then the backoff may be most of half a
/// minute long. The system knows the moment a path is usable again; this asks.
///
/// Only *arrival* is reported. Nothing needs doing when a network goes away
/// that the socket's own failure handling does not already do.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let logger = Logger(subsystem: "app.twodos", category: "network")
    private let monitor = NWPathMonitor()
    private var isStarted = false
    private var wasSatisfied: Bool?
    private var lastInterfaces: Set<NWInterface.InterfaceType> = []

    /// Called when a path becomes usable, or switches interface while usable.
    var onNetworkAvailable: (() -> Void)?

    private init() {}

    /// Idempotent: a second monitor would double every resync.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = Set(
                [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
                    .filter { path.usesInterfaceType($0) }
            )
            Task { @MainActor [weak self] in
                self?.handle(satisfied: satisfied, interfaces: interfaces)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.twodos.network-monitor", qos: .utility))
    }

    private func handle(satisfied: Bool, interfaces: Set<NWInterface.InterfaceType>) {
        defer {
            wasSatisfied = satisfied
            lastInterfaces = interfaces
        }
        // The first report describes the network the app launched on; launch
        // already connects, so it is not news.
        guard let wasSatisfied, satisfied else { return }
        // Back from nothing, or moved from wifi to cellular (or back): either
        // way the socket is on a path that no longer exists.
        if !wasSatisfied || interfaces != lastInterfaces {
            logger.info("Network available; resyncing.")
            onNetworkAvailable?()
        }
    }
}
