// by zayd/cold @ zayd.wtf

import Foundation

/// Decides exactly what to insert so consecutive dictations read as one text:
/// a leading space when the cursor sits after a word, a capital after a sentence end,
/// and neither after an opening bracket or quote.
public enum TextJoiner {
    /// Characters after which no space is wanted.
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "/", "-", "@", "#", "$"]
    /// Transcripts starting with one of these attach to the previous word.
    private static let closers: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "%"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    /// - Parameters:
    ///   - contextBefore: text immediately before the cursor, or nil when unknown or empty.
    ///   - transcript: raw engine output.
    ///   - capitalizeSentences: whether the host field auto-capitalizes sentences.
    /// - Returns: the string to insert; empty when the transcript has no content.
    public static func join(contextBefore: String?, transcript: String, capitalizeSentences: Bool) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = text.first else { return "" }

        let context = contextBefore ?? ""
        let lastCharacter = context.last

        if capitalizeSentences && startsSentence(after: context) {
            text = String(firstCharacter).uppercased() + text.dropFirst()
        }

        guard let last = lastCharacter else { return text }
        if last.isWhitespace || last.isNewline { return text }
        if closers.contains(firstCharacter) { return text }
        // A straight quote is an opener unless it closes a finished sentence ("Done." then a
        // quote), in which case the next words start a new sentence after a space.
        if quotes.contains(last), closesSentence(context) { return " " + text }
        if openers.contains(last) { return text }
        return " " + text
    }

    private static let quotes: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "\u{201D}", "\u{2019}"]

    /// True when the trailing quote(s) sit right after a sentence ender: a closing quote.
    private static func closesSentence(_ context: String) -> Bool {
        var trimmed = Substring(context)
        while let last = trimmed.last, quotes.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let inner = trimmed.last else { return false }
        return sentenceEnders.contains(inner)
    }

    private static func startsSentence(after context: String) -> Bool {
        SentenceBoundary.startsSentence(after: context)
    }
}
