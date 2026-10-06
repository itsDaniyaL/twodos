import SwiftUI

extension Text {
    /// Text for interface copy that arrives as a `String`.
    ///
    /// SwiftUI translates a literal only when it reaches `Text` as a
    /// `LocalizedStringKey`. A component that takes `title: String` — and
    /// most of the design system does, so callers can pass data as well as
    /// copy — would otherwise show every caption in English whatever language
    /// is chosen. This looks the string up as a key: copy is translated, and
    /// data (a list name, an address) matches no key and shows as it is.
    ///
    /// A string with a `%` in it is shown verbatim, so user content such as
    /// "50% off" is never read as a format.
    init(localizable value: String) {
        if value.contains("%") {
            self.init(verbatim: value)
        } else {
            self.init(LocalizedStringKey(value))
        }
    }
}
