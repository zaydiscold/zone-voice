// by zayd/cold @ zayd.wtf

import Foundation

/// Word error rate for the engine bakeoff.
///
/// Engines disagree on formatting more than on words: one writes "3:30", another "three
/// thirty"; one capitalizes and punctuates, another does not. `normalize` erases those
/// differences (case, punctuation, digits, fillers) so the score counts recognition mistakes,
/// not house style. Both reference and hypothesis go through the same normalizer.
public struct WordErrorRate: Equatable, Sendable, Codable {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceWords: Int

    public var errors: Int { substitutions + deletions + insertions }
    /// Errors over reference words; 0 for an empty reference with an empty hypothesis.
    public var rate: Double {
        guard referenceWords > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceWords)
    }

    public init(substitutions: Int, deletions: Int, insertions: Int, referenceWords: Int) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }

    public static func score(reference: String, hypothesis: String) -> WordErrorRate {
        align(reference: normalize(reference), hypothesis: normalize(hypothesis))
    }

    /// Sums several utterances the standard way: total errors over total reference words.
    public static func pooled(_ scores: [WordErrorRate]) -> WordErrorRate {
        WordErrorRate(
            substitutions: scores.reduce(0) { $0 + $1.substitutions },
            deletions: scores.reduce(0) { $0 + $1.deletions },
            insertions: scores.reduce(0) { $0 + $1.insertions },
            referenceWords: scores.reduce(0) { $0 + $1.referenceWords })
    }

    /// Levenshtein alignment over words, tracking which edit produced each cell.
    static func align(reference: [String], hypothesis: [String]) -> WordErrorRate {
        let n = reference.count
        let m = hypothesis.count
        // cost, substitutions, deletions, insertions
        var previous = (0...m).map { (cost: $0, s: 0, d: 0, i: $0) }
        for row in 1...max(n, 1) where n > 0 {
            var current = [(cost: row, s: 0, d: row, i: 0)]
            for column in 1...max(m, 1) where m > 0 {
                let same = reference[row - 1] == hypothesis[column - 1]
                let diagonal = previous[column - 1]
                let up = previous[column]
                let left = current[column - 1]
                let substitute = (cost: diagonal.cost + (same ? 0 : 1), s: diagonal.s + (same ? 0 : 1), d: diagonal.d, i: diagonal.i)
                let delete = (cost: up.cost + 1, s: up.s, d: up.d + 1, i: up.i)
                let insert = (cost: left.cost + 1, s: left.s, d: left.d, i: left.i + 1)
                var best = substitute
                if delete.cost < best.cost { best = delete }
                if insert.cost < best.cost { best = insert }
                current.append(best)
            }
            previous = current
        }
        let last = previous[m]
        return WordErrorRate(substitutions: last.s, deletions: last.d, insertions: last.i, referenceWords: n)
    }

    // MARK: Normalization

    static let fillers: Set<String> = ["um", "uh", "erm", "hmm", "mm", "ah"]

    public static func normalize(_ text: String) -> [String] {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        // Money and percent read as words.
        s = s.replacingOccurrences(of: #"\$(\d+(?:\.\d+)?)"#, with: "$1 dollars", options: .regularExpression)
        s = s.replacingOccurrences(of: "%", with: " percent")
        s = s.replacingOccurrences(of: "&", with: " and ")
        // Clock times: 3:30 -> three thirty, 3:05 -> three oh five, 3:00 -> three
        s = replaceMatches(in: s, pattern: #"\b(\d{1,2}):(\d{2})\b"#) { groups in
            let hour = Int(groups[1]) ?? 0
            let minute = Int(groups[2]) ?? 0
            if minute == 0 { return spell(hour) }
            if minute < 10 { return spell(hour) + " oh " + spell(minute) }
            return spell(hour) + " " + spell(minute)
        }
        // Times written with a dot after a time preposition ("at 3.30"), as several engines
        // emit them, read as clock times rather than decimals.
        s = replaceMatches(in: s, pattern: #"\b(at|by|until|till|before|after|around|from|to)\s+(\d{1,2})\.([0-5]\d)\b"#) { groups in
            let hour = Int(groups[2]) ?? 0
            let minute = Int(groups[3]) ?? 0
            let spoken = minute == 0 ? spell(hour)
                : minute < 10 ? spell(hour) + " oh " + spell(minute)
                : spell(hour) + " " + spell(minute)
            return groups[1] + " " + spoken
        }
        // Decimals: 12.5 -> twelve point five (each fractional digit spoken).
        s = replaceMatches(in: s, pattern: #"\b(\d+)\.(\d+)\b"#) { groups in
            let whole = spell(Int(groups[1]) ?? 0)
            let fraction = groups[2].map { spell(Int(String($0)) ?? 0) }.joined(separator: " ")
            return whole + " point " + fraction
        }
        // Ordinals: 1st, 2nd, 3rd, 21st.
        s = replaceMatches(in: s, pattern: #"\b(\d+)(st|nd|rd|th)\b"#) { groups in
            ordinal(Int(groups[1]) ?? 0)
        }
        // Thousands separators, then plain integers.
        s = s.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        s = replaceMatches(in: s, pattern: #"\b\d+\b"#) { groups in
            guard let value = Int(groups[0]), value < 1_000_000 else { return groups[0] }
            return spell(value)
        }
        // Hyphens and slashes separate words; apostrophes are dropped inside words.
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: "/", with: " ")
        s = s.replacingOccurrences(of: "'", with: "")
        let kept = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept)
            .split(separator: " ")
            .map(String.init)
            .filter { !fillers.contains($0) }
    }

    private static func replaceMatches(in text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : (text as NSString).substring(with: range))
            }
            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: " " + transform(groups) + " ")
        }
        return result
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func spell(_ value: Int) -> String {
        if value < 20 { return ones[value] }
        if value < 100 {
            return tens[value / 10] + (value % 10 == 0 ? "" : " " + ones[value % 10])
        }
        if value < 1000 {
            return ones[value / 100] + " hundred" + (value % 100 == 0 ? "" : " " + spell(value % 100))
        }
        return spell(value / 1000) + " thousand" + (value % 1000 == 0 ? "" : " " + spell(value % 1000))
    }

    static func ordinal(_ value: Int) -> String {
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        var words = spell(value).split(separator: " ").map(String.init)
        guard let last = words.popLast() else { return "" }
        let suffixed: String
        if let special = irregular[last] {
            suffixed = special
        } else if last.hasSuffix("y") {
            suffixed = String(last.dropLast()) + "ieth"
        } else {
            suffixed = last + "th"
        }
        return (words + [suffixed]).joined(separator: " ")
    }
}
