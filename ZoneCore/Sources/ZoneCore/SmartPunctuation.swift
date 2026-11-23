// by zayd/cold @ zayd.wtf

import Foundation

/// Curly quotes, long dashes and the ellipsis as they are typed, as a pure function of the text
/// before the caret.
///
/// The baseline is Apple's keyboard, measured key by key on iOS 26.2 (`AppleSmartPunctuationOracle`
/// records it; `SmartPunctuationTests` holds the table). Zone departs from Apple only where Apple's
/// result is wrong for what was typed, and each departure is listed in that test:
/// - a leading apostrophe stays an apostrophe (`’90s`, `’tis`, `rock ’n’ roll`), where Apple opens a quote
/// - feet and inches stay straight (`5'10"`), unless a quote is open and this closes it
/// - web addresses, email addresses and `code spans` are left alone
/// - `-->` and a line of `---` survive
public enum SmartPunctuation {
    public struct Change: Equatable, Sendable {
        /// Characters to delete before the caret, then `insert` goes in.
        public let deleteCount: Int
        public let insert: String
        /// What plain typing would have left in place of `insert`: Backspace right after a change
        /// puts this back, which is also how a straight quote is typed on purpose.
        public let plain: String
    }

    /// Words that begin with an apostrophe standing in for dropped letters.
    static let elisions: Set<String> = ["tis", "twas", "twere", "twill", "em", "til", "cause", "bout", "n"]

    /// Nil means the character goes in as typed.
    public static func edit(typing character: Character, before context: String, quotes: Bool, dashes: Bool) -> Change? {
        guard quotes || dashes, !isLiteral(context) else { return nil }
        if quotes, !character.isLetter, !character.isNumber, character != "\u{2019}", let fixed = elision(in: context, closing: character) {
            // The word before the caret turned out to be `’tis`, not an opening quote: fix its
            // apostrophe, then type the character against the corrected text.
            let rest = String(context.dropLast(fixed.deleteCount)) + fixed.insert
            let next = change(typing: character, before: rest, quotes: quotes, dashes: dashes)
            let kept = next.map { String(rest.dropLast($0.deleteCount)) + $0.insert } ?? rest + String(character)
            let shared = context.commonPrefix(with: kept).count
            return Change(deleteCount: context.count - shared, insert: String(kept.dropFirst(shared)),
                          plain: String(context.dropFirst(shared)) + String(character))
        }
        return change(typing: character, before: context, quotes: quotes, dashes: dashes)
    }

    private static func change(typing character: Character, before context: String, quotes: Bool, dashes: Bool) -> Change? {
        func replace(_ count: Int, _ insert: String) -> Change {
            Change(deleteCount: count, insert: insert, plain: String(context.suffix(count)) + String(character))
        }
        let previous = context.last
        if quotes {
            switch character {
            case "\"":
                if opens(after: previous) || previous == "\u{2018}" { return replace(0, "\u{201C}") }
                if previous?.isNumber == true, !hasOpen("\u{201C}", "\u{201D}", in: context) { return nil }
                return replace(0, "\u{201D}")
            case "'":
                if opens(after: previous) || previous == "\u{201C}" { return replace(0, "\u{2018}") }
                if previous?.isNumber == true, !hasOpen("\u{2018}", "\u{2019}", in: context) { return nil }
                return replace(0, "\u{2019}")
            default:
                // `90's`: the mark after a number was left straight in case it meant feet.
                if character.isLetter, previous == "'", context.dropLast().last?.isNumber == true {
                    return replace(1, "\u{2019}" + String(character))
                }
                // `'90s`: a number right after an opening quote is a shortened year.
                if character.isNumber, previous == "\u{2018}", opens(after: context.dropLast().last) {
                    return replace(1, "\u{2019}" + String(character))
                }
            }
        }
        if dashes {
            switch character {
            case "-" where previous == "-":
                let earlier = context.dropLast().last
                if earlier == "-" || context.hasSuffix("<!-") { return nil }
                return replace(1, earlier?.isNumber == true ? "\u{2013}" : "\u{2014}")
            case "-" where previous == "\u{2014}":
                // Three hyphens alone on a line are a divider, not a dash and a hyphen.
                let line = context.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
                return line == "\u{2014}" ? replace(1, "---") : nil
            case ">" where previous == "\u{2014}":
                return replace(1, "-->")
            case "." where context.hasSuffix("..") && !context.hasSuffix("..."):
                return replace(2, "\u{2026}")
            default:
                break
            }
        }
        return nil
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "\u{2019}"
    }

    /// A quote typed here opens: the start of the text, after a space or line break, after an
    /// opening bracket, and after the joining marks Apple treats the same way.
    private static func opens(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace || previous.isNewline || "([{<=-/\u{2014}\u{2013}".contains(previous)
    }

    /// An opening quote in this paragraph that nothing has closed yet. For single quotes a closing
    /// mark inside a word is an apostrophe and closes nothing.
    private static func hasOpen(_ open: Character, _ close: Character, in context: String) -> Bool {
        let paragraph = context.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        guard let start = paragraph.lastIndex(of: open) else { return false }
        var index = paragraph.index(after: start)
        while index < paragraph.endIndex {
            let next = paragraph.index(after: index)
            if paragraph[index] == close, next == paragraph.endIndex || !paragraph[next].isLetter { return false }
            index = next
        }
        return true
    }

    /// Text where punctuation must stay exactly as typed: a web or email address being typed, and
    /// an open `code span` on this line.
    private static func isLiteral(_ context: String) -> Bool {
        let line = context.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        if line.filter({ $0 == "`" }).count % 2 == 1 { return true }
        let token = line.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).last ?? ""
        // A leading @ is a handle in a sentence; an @ inside the token is an address.
        return token.contains("://") || token.dropFirst().contains("@") || token.hasPrefix("www.")
    }

    /// `‘tis` before the caret, where the opening quote should have been an apostrophe. A closing
    /// quote typed next means the word really was quoted (`'em'`), except for `'n'`.
    private static func elision(in context: String, closing character: Character) -> (deleteCount: Int, insert: String)? {
        let word = context.reversed().prefix(while: \.isLetter)
        guard !word.isEmpty, word.count <= 5, context.count > word.count else { return nil }
        let text = String(word.reversed())
        let mark = context.index(context.endIndex, offsetBy: -(word.count + 1))
        guard context[mark] == "\u{2018}", elisions.contains(text.lowercased()),
              opens(after: mark == context.startIndex ? nil : context[context.index(before: mark)]),
              character != "'" || text.lowercased() == "n" else { return nil }
        return (word.count + 1, "\u{2019}" + text)
    }
}
