import Foundation
import UIKit
import OSLog

/// Keeps the server's idea of this device in step with Apple's.
///
/// ## Why this is not fire-and-forget
/// APNs device tokens rotate — on restore from backup, on reinstall, and
/// occasionally for no reason the app can see. A token registered once and never
/// refreshed stops delivering silently: nothing errors, notifications simply
/// stop arriving. So registration runs on **every launch**, not only the first.
///
/// ## Why it is cheap to call repeatedly
/// The server matches on the token itself, so re-registering an unchanged token
/// updates one row rather than creating another. The local copy below skips even
/// that when nothing has changed, so the common launch costs no request at all.
@MainActor
@Observable
final class PushRegistrationService: NSObject {
    static let shared = PushRegistrationService()
    private override init() {}

    private let logger = Logger(subsystem: "app.twodos", category: "push")
    private let defaults = UserDefaults.standard

    private enum Key {
        /// The token last accepted by the server, so an unchanged one is not resent.
        static let registeredToken = "push.registeredToken"
        /// The server's id for this device, needed to unregister on sign-out.
        static let deviceId = "push.deviceId"
    }

    private(set) var isRegistered: Bool = false

    /// Asks iOS for a token. The delegate callback does the actual work.
    ///
    /// Safe to call on every launch: iOS answers from cache when it already has
    /// one, so this does not prompt and does not hit the network.
    func refresh() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from the app delegate when Apple hands over a token.
    func handle(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()

        // Unchanged since last time, and the server already has it.
        guard token != defaults.string(forKey: Key.registeredToken) else {
            isRegistered = true
            return
        }

        Task { await send(token: token) }
    }

    /// Called from the app delegate when registration fails.
    ///
    /// Not worth surfacing: it happens on Simulator without a paired push
    /// environment, in Airplane Mode, and when the user has denied
    /// notifications — none of which the user can act on from inside the app.
    func handle(error: any Error) {
        logger.debug("Remote notification registration failed: \(error.localizedDescription)")
    }

    private func send(token: String) async {
        do {
            let id = try await APIClient.shared.registerDevice(
                platform: APIConstants.platform,
                token: token,
                bundleId: Bundle.main.bundleIdentifier
            )
            defaults.set(token, forKey: Key.registeredToken)
            if let id { defaults.set(id, forKey: Key.deviceId) }
            isRegistered = true
            logger.info("Device registered for push.")
        } catch {
            // Deliberately not retried here. The next launch calls `refresh()`
            // again, and a device that cannot reach the API has bigger problems
            // than push registration.
            logger.warning("Device registration failed: \(error.localizedDescription)")
        }
    }

    /// Stops notifications reaching this device.
    ///
    /// Called on sign-out. Without it, a shared phone keeps ringing for the
    /// person who just signed out — which is a privacy problem, not a bug.
    func unregister() async {
        guard let id = defaults.string(forKey: Key.deviceId) else { return }

        // Cleared first: if the request fails the local record must not keep
        // pointing at a registration this session can no longer address.
        defaults.removeObject(forKey: Key.deviceId)
        defaults.removeObject(forKey: Key.registeredToken)
        isRegistered = false

        _ = try? await APIClient.shared.unregisterDevice(tokenId: id)
    }
}
