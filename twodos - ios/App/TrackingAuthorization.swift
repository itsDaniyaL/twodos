import AppTrackingTransparency

/// Requests the system tracking-permission prompt required by App Store
/// Guideline 5.1.2(i) whenever App Store Connect's privacy declarations mark
/// data (e.g. email address) as used for tracking. `requestTrackingAuthorization`
/// is a no-op that returns the cached status if the user has already answered,
/// so this is safe to call once per launch without re-checking.
enum TrackingAuthorization {
    @MainActor
    static func requestIfNeeded() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}
