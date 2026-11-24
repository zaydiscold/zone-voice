// by zayd/cold @ zayd.wtf

import UIKit

/// Everything the keyboard logic needs from `UIInputViewController`, behind a protocol so the
/// model and mic controller never touch UIKit directly.
@MainActor
protocol TextProxyActions: AnyObject {
    /// A key or the mic was touched. Call before anything else the touch does.
    func userTouchedKeyboard()
    func insert(_ text: String)
    func deleteBackward()
    /// Move the insertion point without inserting or deleting text.
    func adjustTextPosition(byCharacterOffset offset: Int)
    func contextBefore() -> String?
    /// Text right after the cursor, so a word is only corrected when the cursor sits at its end.
    func contextAfter() -> String?
    /// The field holds any text at all. Tells an empty field from a host that reports nil context.
    func fieldHasText() -> Bool
    /// Read only after a coalesced selection-change callback, never for each ordinary key.
    func selectedText() -> String?
    /// The host's input-session identifier, or nil before a session exists.
    func currentInputSession() -> String?
    var returnKeyLabel: String { get }
    var autocapitalizesSentences: Bool { get }
    /// The field asked for no automatic capitals at all (`.none`), unlike a words or all-caps field.
    var fieldNeverCapitalizes: Bool { get }
    /// False for fields where autocorrect would get in the way: URLs, email addresses, user names,
    /// passwords, one-time codes, and any field that turned autocorrection off.
    var allowsAutocorrection: Bool { get }
    var allowsEmojiShortcodes: Bool { get }
    /// False only where a swiped word could never be what the field wants: passwords, user names,
    /// one-time codes, email addresses, bare URLs and number pads. Search bars and address bars
    /// turn autocorrection off and still take swiped words, as they do on Apple's keyboard.
    var allowsSwipeTyping: Bool { get }
    /// False where the field turned smart quotes or smart dashes off, and in the fields where
    /// Apple's keyboard leaves punctuation alone (measured on iOS 26.2: web and email address
    /// keyboards; a field with autocorrection off still gets both).
    var allowsSmartQuotes: Bool { get }
    var allowsSmartDashes: Bool { get }
    /// Number, decimal and phone fields open on the numbers layer (Custom Keyboard guide:
    /// design with keyboard type traits in mind).
    var prefersNumbers: Bool { get }
    /// Characters the field's keyboard type puts on the letters layer beside space, as Apple's
    /// does: a period in an address bar or web search, a slash too in a URL field, @ and # in a
    /// social field. Empty for ordinary text.
    var fieldKeys: [String] { get }
    /// Which letters the field wants capitalized on their own.
    var capitalization: FieldCapitalization { get }
    /// A search bar or address bar: what is typed is a query, not prose.
    var isSearchField: Bool { get }
    /// The field has no use for return while it is empty (`enablesReturnKeyAutomatically`).
    var dimsReturnWhenEmpty: Bool { get }
    /// Whether the keyboard may reach the App Group container (Full Access on device).
    var hasOpenAccess: Bool { get }
    /// The host field's explicit keyboard appearance, nil when it says "default".
    var explicitDarkAppearance: Bool? { get }
    var needsGlobeKey: Bool { get }
    func advanceToNextInputMode()
    func playClick()
    func open(_ url: URL)
    /// The model is about to read the field's traits for a host change: read them from the host
    /// again if they may have changed. Between these calls the traits answer from one snapshot,
    /// so an ordinary keystroke reads none (see `TextProxyGate`).
    func reloadFieldTraits()
}

extension TextProxyActions {
    /// Implementations that read their traits live have nothing to reload.
    func reloadFieldTraits() {}

    /// Restrictive input traits also cover code editors that deliberately mark their field literal.
    var allowsEmojiShortcodes: Bool {
        allowsAutocorrection && allowsSwipeTyping && !prefersNumbers && !isSearchField
    }
}

/// `UITextAutocapitalizationType`, without UIKit.
enum FieldCapitalization: Equatable {
    case none, words, sentences, allCharacters

    /// Whether the next letter after `context` starts as a capital.
    func capitalizesNext(after context: String) -> Bool {
        switch self {
        case .none: return false
        case .allCharacters: return true
        case .words: return context.last.map { $0.isWhitespace } ?? true
        case .sentences: return KeyboardModel.startsSentence(after: context)
        }
    }

    /// Dictated text in the field's own casing: a name field capitalizes each word.
    func dictated(_ text: String) -> String {
        switch self {
        case .none, .sentences: return text
        case .allCharacters: return text.uppercased()
        case .words:
            var out = "", startsWord = true
            for c in text {
                out += startsWord ? String(c).uppercased() : String(c)
                startsWord = c.isWhitespace
            }
            return out
        }
    }
}
