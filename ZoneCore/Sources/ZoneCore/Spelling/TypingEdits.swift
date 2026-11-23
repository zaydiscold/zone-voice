// by zayd/cold @ zayd.wtf

import Foundation

/// An autocorrection the keyboard just made, kept so the next delete can undo it.
public struct AppliedCorrection: Equatable, Sendable {
    public let typed: String
    public let replacement: String
    public let separator: String

    public init(typed: String, replacement: String, separator: String) {
        self.typed = typed
        self.replacement = replacement
        self.separator = separator
    }
}

/// The text edits behind the keyboard's typing rules, as pure functions of the text around the
/// cursor so they can be tested without a host app. The keyboard applies an edit by calling
/// `deleteBackward()` `deleteCount` times, then inserting `insert`.
public enum TypingEdits {
    public struct Edit: Equatable, Sendable {
        public let deleteCount: Int
        public let insert: String
        /// Set when the edit replaced the typed word, so a following delete can revert it.
        public let correction: AppliedCorrection?

        public init(deleteCount: Int, insert: String, correction: AppliedCorrection? = nil) {
            self.deleteCount = deleteCount
            self.insert = insert
            self.correction = correction
        }
    }

    /// Characters that end a word and commit the pending autocorrection.
    public static let correctingSeparators: Set<String> = [" ", "\n", ".", ",", "?", "!", ";", ":"]

    /// A separator was typed. When `typedWord` (the word the user keyed, not dictated or pasted)
    /// sits right before the cursor and the corrector has a replacement, the word is swapped first.
    ///
    /// A word that finishes a listed name of ordinary words ("micro center", `PhraseCasing`) writes
    /// the whole name its way, unless `preserveLowercase` keeps the field lowercase. The applied
    /// correction then covers every word of the name, so Delete puts all of them back as typed.
    /// `writesNames` is false right after such an undo, so the same words stay as typed.
    public static func separator(_ separator: String, typedWord: String?, before: String?, after: String?, corrector: Autocorrector?,
                                 autoCapitalized: Bool = false, touches: [KeyTouch]? = nil, preserveLowercase: Bool = false,
                                 writesNames: Bool = true) -> Edit {
        guard let corrector, let typedWord, !typedWord.isEmpty, let before,
              let composing = Autocorrector.composingWord(before: before, after: after),
              composing == normalized(typedWord) else {
            return Edit(deleteCount: 0, insert: separator)
        }
        let evaluated = corrector.evaluate(composing, autoCapitalized: autoCapitalized, touches: touches, preserveLowercase: preserveLowercase,
                                           previous: Autocorrector.previousWord(before: before, composing: composing)).replacement
        let replacement = evaluated == composing ? nil : evaluated
        if writesNames, !preserveLowercase, before.hasSuffix(composing),
           let named = PhraseCasing.name(before: String(before.dropLast(composing.count)), word: replacement ?? composing) {
            let typed = String(before.suffix(named.prefixLength + composing.count))
            return Edit(deleteCount: typed.count, insert: named.name + separator,
                        correction: AppliedCorrection(typed: typed, replacement: named.name, separator: separator))
        }
        guard let replacement else { return Edit(deleteCount: 0, insert: separator) }
        return Edit(
            deleteCount: composing.count,
            insert: replacement + separator,
            correction: AppliedCorrection(typed: composing, replacement: replacement, separator: separator))
    }

    /// Two spaces in a row after a word become ". ", as on the system keyboard.
    public static func doubleSpacePeriod(before: String?) -> Edit? {
        guard let before, before.hasSuffix(" ") else { return nil }
        let rest = before.dropLast()
        guard let last = rest.last, last.isLetter || last.isNumber || last == ")" || last == "\u{201D}" || last == "\"" else {
            return nil
        }
        return Edit(deleteCount: 1, insert: ". ")
    }

    /// Delete right after an autocorrection puts the typed word back (and drops the separator).
    public static func revert(_ correction: AppliedCorrection, before: String?) -> Edit? {
        let applied = correction.replacement + correction.separator
        guard let before, before.hasSuffix(applied) else { return nil }
        return Edit(deleteCount: applied.count, insert: correction.typed)
    }

    /// A suggestion was tapped: the word at the cursor becomes `text`, followed by a space unless
    /// one already follows the cursor.
    public static func choose(_ text: String, before: String?, after: String?) -> Edit? {
        guard let composing = Autocorrector.composingWord(before: before, after: after) else { return nil }
        let followedBySpace = after?.first?.isWhitespace == true
        return Edit(deleteCount: composing.count, insert: followedBySpace ? text : text + " ")
    }

    /// How many characters a word-at-a-time delete removes: trailing spaces, then the word before them.
    public static func wordDeletionCount(before: String?) -> Int {
        guard let before, !before.isEmpty else { return 1 }
        var count = 0
        var iterator = before.reversed().makeIterator()
        var sawWord = false
        while let character = iterator.next() {
            if character.isWhitespace {
                if sawWord { break }
            } else if character.isLetter || character.isNumber || character == "'" || character == "\u{2019}" {
                sawWord = true
            } else {
                if sawWord { break }
                count += 1
                sawWord = true
                break
            }
            count += 1
        }
        return max(count, 1)
    }

    public static func normalized(_ word: String) -> String {
        word.replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
