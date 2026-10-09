import Foundation

/// Which providers the *Mac* can actually complete.
///
/// Apple is the odd one out. The native sheet stamps the identity token's
/// `aud` with the requesting app's bundle ID, and the server verifies Apple
/// tokens against the iOS bundle ID and the Services ID only — so a token from
/// the Mac's own bundle ID is refused ("jwt audience invalid"). The Mac signs in
/// with Apple through the server's web bridge instead, whose token carries the
/// Services ID, and offers Apple only when the server has that bridge
/// configured. A button that fails after the click costs more trust than a
/// missing one.
extension SocialAuthConfig {
    var macOffersApple: Bool {
        guard let apple, apple.enabled else { return false }
        // `androidAvailable` is the server's "Services ID and public base URL
        // are both set" — exactly the bridge's preconditions, whoever uses it.
        return apple.androidAvailable == true && !(apple.bridgeStartUrl ?? "").isEmpty
    }

    var macAvailableProviders: [SocialProvider] {
        availableProviders.filter { $0 != .apple || macOffersApple }
    }
}
