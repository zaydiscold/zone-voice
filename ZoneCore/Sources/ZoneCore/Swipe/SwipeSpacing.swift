// by zayd/cold @ zayd.wtf

import Foundation

/// The spaces around a swiped word, as pure rules over the text at the cursor.
///
/// A swiped word never types its own trailing space. Instead the keyboard remembers that one is
/// owed (a *phantom space*, the rule Gboard's open ancestor LatinIME and Apple's QuickPath
/// share) and pays it only when the next thing is a word: a tapped letter, another swipe, a
/// digit, an opening bracket or quote, an emoji. Punctuation attaches directly ("done,"), a
/// typed space is the owed space and never doubles, and a newline owes nothing.
///
/// Before a swiped word, a space is added when the cursor sits right after a word, a digit or
/// sentence punctuation, so a swipe after "end." gives "end. Next" and after "end" gives
/// "end next". Nothing is added after whitespace, an opening bracket or quote, a hyphen, a
/// slash, or inside a URL, an email address or a hashtag.
public enum SwipeSpacing {
    static let sentencePunctuation: Set<Character> = [".", ",", "!", "?", ":", ";"]
    static let closers: Set<Character> = [")", "]", "}", "\"", "\u{201D}", "\u{2019}", "'"]
    static let openers: Set<Character> = ["(", "[", "{", "\"", "\u{201C}", "\u{2018}", "$", "\u{20AC}", "\u{00A3}"]

    /// Whether a space goes in front of a swiped word, given the text before the cursor.
    public static func needsLeadingSpace(before context: String?) -> Bool {
        guard let context, let last = context.last else { return false }
        if last.isWhitespace || last.isNewline { return false }
        if isInsideToken(context) { return false }
        if last.isLetter || last.isNumber { return true }
        if sentencePunctuation.contains(last) { return true }
        if closers.contains(last) { return last != "'" && last != "\u{2019}" }
        // Hyphens, slashes, @, #, openers, emoji and everything else: attach.
        return false
    }

    /// Whether the owed space is paid before `text`, the next thing typed after a swiped word.
    /// The owed space is always discharged by whatever comes next; this says whether it is
    /// written.
    public static func paysPendingSpace(before text: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isWhitespace || first.isNewline { return false }
        if sentencePunctuation.contains(first) { return false }
        if closers.contains(first) { return false }
        if first == "-" || first == "/" || first == "\u{2019}" { return false }
        return true
    }

    /// The word a swipe at the cursor follows, for the context model and the user's pair counts,
    /// or nil when there is none to condition on. Tokenized like `build-wordpairs.py` builds the
    /// table: the last whitespace-separated token, surrounding quotes, brackets and commas
    /// stripped, curly apostrophes folded. Sentence punctuation (. ! ? ; :), a newline, or a
    /// token that is not a word (a number, an emoji, a URL) ends the context, so "Done. |" and
    /// "at 5 |" have no previous word.
    public static func previousWord(before context: String?) -> String? {
        guard let context else { return nil }
        let tail = context.suffix(128)
        guard let end = tail.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        if tail[tail.index(after: end)...].contains(where: \.isNewline) { return nil }
        let start = tail[...end].lastIndex(where: \.isWhitespace).map { tail.index(after: $0) } ?? tail.startIndex
        var token = Substring(tail[start...end].replacingOccurrences(of: "\u{2019}", with: "'"))
        while let first = token.first, openers.contains(first) || first == "'" || first == "\u{2018}" { token = token.dropFirst() }
        while let last = token.last, closers.contains(last) || sentencePunctuation.contains(last) {
            if last != ",", sentencePunctuation.contains(last) { return nil }
            token = token.dropLast()
        }
        guard let first = token.first, let last = token.last, first.isLetter, last.isLetter,
              token.allSatisfy({ ($0.isLetter && $0.isASCII) || $0 == "'" }), !token.contains("''") else { return nil }
        return String(token)
    }

    /// The token at the cursor is a URL, an email address, a handle or a hashtag: no automatic
    /// spaces inside it.
    public static func isInsideToken(_ context: String) -> Bool {
        let tail = context.suffix(128)
        guard let start = tail.lastIndex(where: { $0.isWhitespace || $0.isNewline }) else {
            return looksLikeToken(tail)
        }
        return looksLikeToken(tail[tail.index(after: start)...])
    }

    private static func looksLikeToken(_ token: Substring) -> Bool {
        guard !token.isEmpty else { return false }
        if token.first == "@" || token.first == "#" { return true }
        if token.contains("@") { return true }
        if token.contains("://") || token.lowercased().hasPrefix("www.") { return true }
        // A dot joining two letters with no space after it: a domain or a file name.
        var previousLetter = false
        var sawDot = false
        for c in token {
            if c == "." { sawDot = previousLetter; continue }
            if sawDot, c.isLetter { return true }
            sawDot = false
            previousLetter = c.isLetter || c.isNumber
        }
        return false
    }
}
