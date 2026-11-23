// by zayd/cold @ zayd.wtf

import Foundation

extension Autocorrector {
    /// Whether a word the person typed over another is a slip of the keys, not a word to keep.
    ///
    /// A correction is taught by hand, so the keys can slip while teaching it, and a word in My
    /// Words is never autocorrected again and steers dictation toward itself. Saving "definitly"
    /// typed over "defiantly" keeps the misspelling for good. A slip is a word autocorrect would
    /// replace with some other word at the next space.
    ///
    /// Three things are never a slip, because each says the person meant the letters they typed:
    ///  - autocorrect would only put back the word just replaced ("frostbite" selected, "frostbyte"
    ///    typed): the person has already refused that word;
    ///  - a capital the person chose (`deliberateCapital`): names and brands are what My Words is
    ///    for, and many sit one key from a common word ("Brex" and "bred", "Stytch" and "stitch");
    ///  - a word the keyboard already knows.
    ///
    /// The cost of calling a real word a slip is one more correction: autocorrect changes it, the
    /// person retypes it over the change, and the first rule learns it. The cost of saving a slip
    /// is a misspelling that is never corrected again, so a lowercase near-miss is refused first.
    ///
    /// - Parameters:
    ///   - autoCapitalized: the word's capital came from the keyboard's sentence-start shift.
    public func isSlip(_ word: String, replacing original: String, autoCapitalized: Bool = false) -> Bool {
        guard !recognizes(word) else { return false }
        if Self.hasDeliberateCapital(word, autoCapitalized: autoCapitalized) { return false }
        guard let fix = evaluate(word, autoCapitalized: autoCapitalized).replacement else { return false }
        let folded = { (text: String) in text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") }
        return folded(fix) != folded(word) && folded(fix) != folded(original)
    }

    /// A capital the person asked for: any after the first letter ("OpenRouter", "iPhone"), or a
    /// first letter the keyboard did not shift on its own.
    static func hasDeliberateCapital(_ word: String, autoCapitalized: Bool) -> Bool {
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        return word.first?.isUppercase == true && !autoCapitalized
    }
}
