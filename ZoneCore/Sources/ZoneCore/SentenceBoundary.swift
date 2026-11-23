// by zayd/cold @ zayd.wtf

import Foundation

/// Where a sentence starts, for typing and dictation alike: after nothing, a line break or
/// `. ! ?`, looking through quotes ("Done." then a capital; Done. then an opening quote and a
/// capital).
public enum SentenceBoundary {
    static let enders: Set<Character> = [".", "!", "?"]
    static let quotes: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "\u{201D}", "\u{2019}"]

    /// Dictation: the joiner supplies the space itself, so the caret may sit right after the
    /// sentence end.
    public static func startsSentence(after context: String) -> Bool {
        var trimmed = Substring(context.trimmingCharacters(in: .whitespaces))
        while let last = trimmed.last, quotes.contains(last) {
            trimmed = trimmed.dropLast()
            let inner = trimmed.trimmingCharacters(in: .whitespaces)
            guard let innerLast = inner.last else { return true }
            if innerLast.isNewline || enders.contains(innerLast) { return true }
            if quotes.contains(innerLast) { trimmed = Substring(inner); continue }
            return false
        }
        guard let last = trimmed.last else { return true }
        if last.isNewline { return true }
        return enders.contains(last)
    }

    /// Typing: the next letter is a capital only once the sentence end has its space, or an
    /// opening quote that follows one ("Done. " then a quote).
    public static func startsSentenceWhileTyping(after context: String) -> Bool {
        guard let last = context.last else { return true }
        if last.isNewline { return true }
        if last.isWhitespace { return startsSentence(after: context) }
        guard quotes.contains(last) else { return false }
        let before = context.dropLast()
        guard let previous = before.last else { return true }
        return previous.isWhitespace && startsSentence(after: String(before))
    }
}
