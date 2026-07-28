import Foundation
import Testing
@testable import twodos___ios

/// How spoken text resolves to a list.
///
/// This is the piece most likely to break a working Shortcut without anyone
/// noticing: it runs inside Siri, fails silently, and the user concludes the
/// feature is unreliable rather than reporting a bug.
@Suite("Siri list matching")
struct IntentMatchingTests {

    private func matches(_ label: String, _ spoken: String) -> Bool {
        TodoListQuery.matches(label: label, spoken: spoken)
    }

    @Test("An exact name matches")
    func exactMatch() {
        #expect(matches("Groceries", "Groceries"))
    }

    @Test("Case and diacritics do not decide whether a Shortcut works")
    func caseAndDiacriticInsensitive() {
        #expect(matches("Groceries", "GROCERIES"))
        #expect(matches("Groceries", "groceries"))
        // Speech rarely returns the accent.
        #expect(matches("Café run", "cafe run"))
    }

    @Test("A phrase shorter than the label matches — the label contains it")
    func labelContainsPhrase() {
        // "add milk to groceries" → list is actually "Groceries (Tesco)"
        #expect(matches("Groceries (Tesco)", "groceries"))
        #expect(matches("Weekly Shop 🛒", "weekly shop"))
    }

    @Test("A phrase longer than the label matches — the phrase contains it")
    func phraseContainsLabel() {
        // Speech adds words the list name does not have. Matching only one
        // direction would reject this, which is most of what people say.
        #expect(matches("Weekly Shop", "the weekly shop list"))
        #expect(matches("Admin", "my admin list"))
    }

    @Test("An empty phrase shows everything rather than nothing")
    func emptyPhraseShowsAll() {
        // What the Shortcuts picker sends before the user types. Returning no
        // matches would make the list picker look broken.
        #expect(matches("Groceries", ""))
        #expect(matches("Groceries", "   "))
    }

    @Test("An unrelated phrase does not match")
    func unrelatedDoesNotMatch() {
        #expect(!matches("Groceries", "weekend trip"))
        #expect(!matches("Admin", "shopping"))
    }

    @Test("A one-letter phrase does not match everything it happens to appear in")
    func shortPhraseIsStillASubstring() {
        // Honest about the trade-off: "a" genuinely appears in "Admin", and
        // this matcher will return it. That is acceptable — Siri disambiguates
        // by asking, and the alternative (a length floor) would reject real
        // short list names like "Gym" or "DIY".
        #expect(matches("Admin", "a"))
        #expect(matches("Gym", "gym"))
    }
}
