// by zayd/cold @ zayd.wtf

import Foundation

/// The ways people say quotation marks, rewritten to the two commands `SpokenFormatting` knows
/// ("open quote" and "unquote") before it runs.
///
/// - "quote hello quote": a second "quote" closes the first.
/// - "quote hello on quote": the recognizer's spellings of "unquote" close an open quote.
/// - "she said quote hello": after a word that introduces speech, a "quote" nobody closed runs
///   to the end of the sentence.
/// - "the quote unquote expert": the next word is in quotation marks.
///
/// "Quote" stays a word when it is one: "a quote", "the quote", "I'll quote you", "quote tweet".
/// A "quote" with a spoken "unquote" or "end quote" after it is left to `SpokenFormatting`.
enum SpokenQuotes {
    private static let token = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])(?:(?<idiom>quote,?[ \t]+(?:unquote|on[ \t]quote|un[ \t-]quote|end[ \t]+quote),?[ \t]+(?<word>[\p{L}\p{N}][\p{L}\p{N}'’\-]*))|(?<close>unquote|un[ \t-]quote|on[ \t]quote|end[ \t]+quote|close[ \t]+quote)|(?<open>open[ \t]+quote|begin[ \t]+quote)|(?<bare>quote))(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])

    /// Before "quote": it is a noun or a verb there.
    private static let wordBefore: Set<String> = [
        "a", "an", "the", "word", "literal", "that", "this", "my", "your", "his", "her", "their", "our", "price",
        "to", "i", "you", "we", "they", "will", "would", "can", "could", "should", "please", "don't", "didn't", "not",
        "direct", "famous", "favorite", "great", "good", "best", "movie", "stock", "insurance", "pull", "block", "any",
        "another", "one", "each", "every", "no", "some", "free", "new",
    ]
    /// After "quote": it is a verb, or part of a name for something.
    private static let wordAfter: Set<String> = [
        "me", "him", "them", "us", "you", "it", "on", "from", "for", "of", "tweet", "tweets", "tweeted", "post",
        "posts", "posted", "retweet", "reply", "replied", "is", "was", "says", "said",
    ]
    private static let speech: Set<String> = [
        "said", "says", "say", "saying", "like", "goes", "went", "wrote", "writes", "write", "texted", "text", "replied",
        "asked", "yelled", "typed", "type", "put", "tweeted", "posted", "reads", "titled", "captioned", "caption",
        "called", "responded", "answered",
    ]

    /// Where "and I said" or ", then she was like" begins, before the "quote" at `location`.
    private static let clause = try! NSRegularExpression(
        pattern: #"(?:,?[ \t]+(?:and|but|then|so))*,?[ \t]+[\p{L}'’]+(?:[ \t]+(?:was|is|were|am|just|then|all))*[ \t]+[\p{L}]+,?[ \t]*$"#,
        options: [.caseInsensitive])
    private static func clauseStart(before location: Int, in source: NSString) -> Int? {
        let head = source.substring(to: location)
        guard let match = clause.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)),
              match.range.location > 0 else { return nil }
        return match.range.location
    }

    static func normalizing(_ text: String) -> String {
        guard text.range(of: "quote", options: .caseInsensitive) != nil else { return text }
        let source = text as NSString
        let matches = token.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        func word(before location: Int) -> String {
            source.substring(to: location).split(whereSeparator: { $0.isWhitespace }).last
                .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
        }
        func word(after location: Int) -> String {
            source.substring(from: location).split(whereSeparator: { $0.isWhitespace }).first
                .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() } ?? ""
        }
        enum Kind { case idiom, close, open, bare }
        let items: [(match: NSTextCheckingResult, kind: Kind)] = matches.compactMap { match in
            if match.range(withName: "idiom").location != NSNotFound { return (match, .idiom) }
            if match.range(withName: "close").location != NSNotFound { return (match, .close) }
            if match.range(withName: "open").location != NSNotFound { return (match, .open) }
            // A "quote" that is the noun or the verb is not a mark at all.
            guard !wordBefore.contains(word(before: match.range.location)),
                  !wordAfter.contains(word(after: NSMaxRange(match.range))) else { return nil }
            return (match, .bare)
        }
        var edits: [(range: NSRange, text: String)] = []
        var isOpen = false
        for (index, item) in items.enumerated() {
            let range = item.match.range
            switch item.kind {
            case .idiom:
                // Written as the marks themselves: "the" before it would read as naming the command.
                edits.append((range, "\"\(source.substring(with: item.match.range(withName: "word")))\""))
            case .open:
                isOpen = true
            case .close:
                // "on quote" is only the recognizer's "unquote" when a quote is open.
                let said = source.substring(with: range).lowercased()
                if isOpen, said != "unquote" { edits.append((range, "unquote")) }
                isOpen = false
            case .bare:
                let introduced = speech.contains(word(before: range.location))
                if isOpen {
                    // "he said quote bye and I said quote why": a "quote" right after a word for
                    // speech opens the next quotation, so the one before it ends where that
                    // clause begins. Any other second "quote" is the closer.
                    guard introduced, let clause = Self.clauseStart(before: range.location, in: source) else {
                        edits.append((range, "unquote"))
                        isOpen = false
                        continue
                    }
                    edits.append((NSRange(location: clause, length: 0), " unquote"))
                    isOpen = false
                }
                let later = items[(index + 1)...]
                if later.contains(where: { $0.kind == .close }) {
                    // `SpokenFormatting` pairs a "quote" with the spoken closer itself.
                    isOpen = true
                } else if later.contains(where: { $0.kind == .bare }) {
                    edits.append((range, "open quote"))
                    isOpen = true
                } else if introduced {
                    // Nobody closed it: the quotation is the rest of the sentence.
                    let rest = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
                    let end = source.range(of: #"[.!?]+(?=\s|$)|\n|$"#, options: .regularExpression, range: rest)
                    guard end.location != NSNotFound,
                          !source.substring(with: NSRange(location: rest.location, length: end.location - rest.location))
                              .trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    edits.append((range, "open quote"))
                    edits.append((NSRange(location: NSMaxRange(end), length: 0), " unquote"))
                }
            }
        }
        guard !edits.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: edit.range, with: edit.text)
        }
        return out as String
    }
}
