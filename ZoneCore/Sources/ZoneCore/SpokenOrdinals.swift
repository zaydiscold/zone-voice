// by zayd/cold @ zayd.wtf

import Foundation

/// Ordinal numbers said out loud, written as digits: "eleventh" is 11th, "twenty first" 21st.
///
/// From tenth up an ordinal is always written in digits, as most style guides and nearly every
/// text message do ("I was in 10th and got bumped to 11th", Zayd, November 15). First through
/// ninth are written in digits only with the Experimental setting on (`small`), and then only
/// where they rank something: after "the", a possessive or "in"/"on" ("in 2nd", "my 1st car",
/// "the 3rd floor"), after a month ("May 2nd") or before a ranking word ("2nd place"). Phrases
/// that only look like ranks stay words: "wait a second", "one second", "at first", "first of
/// all", "on second thought", "the second I saw it".
///
/// Left alone everywhere: fractions ("a tenth of a second", "one fifth of it"), plurals
/// ("thirds"), and a capitalized ordinal mid-sentence, which is a name ("Fifth Avenue").
/// Only whole words between spaces are read, so a URL, a path or code is never touched.
public enum SpokenOrdinals {
    static let unitOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9]
    static let teenOrdinals: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19]
    static let tensOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90, "hundredth": 100]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// Words before a small ordinal that make it a rank.
    static let rankers: Set<String> = ["the", "my", "your", "his", "her", "our", "their", "its", "in", "on", "this",
                                      "that", "every", "each", "their", "whose"]
    /// Words after an ordinal that make it a rank whatever comes before.
    static let rankNouns: Set<String> = ["place", "grade", "floor", "period", "round", "base", "gen", "generation",
                                        "quarter", "half", "row", "seat", "year", "semester", "edition", "season",
                                        "episode", "chapter", "birthday", "anniversary", "date", "try", "attempt", "time"]
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
                                     "september", "october", "november", "december", "jan", "feb", "mar", "apr",
                                     "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    /// After a small ordinal these make it something else: "the second I saw it", "on second
    /// thought", "first of all".
    static let notAfterSmall: Set<String> = ["i", "you", "he", "she", "we", "they", "it", "thought", "thoughts", "hand",
                                            "nature", "guessing", "guess", "ago", "later"]
    /// Before any ordinal these make it a fraction: "a tenth of", "one fifth".
    static let fractionLeads: Set<String> = ["a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private static let trigger = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|\p{L}+(?:th|ieth))(?![\p{L}])"#,
        options: [.caseInsensitive])

    public static func writing(_ text: String, small: Bool = false, numericDates: Bool = false) -> String {
        guard trigger.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return text }
        // Split into words and the space before each, keeping everything else as it was.
        var words: [(gap: String, raw: String)] = []
        var gap = "", chunk = ""
        for character in text {
            if character.isWhitespace {
                if !chunk.isEmpty { words.append((gap, chunk)); chunk = ""; gap = "" }
                gap.append(character)
            } else {
                chunk.append(character)
            }
        }
        if !chunk.isEmpty { words.append((gap, chunk)); gap = "" }
        let trailing = gap

        func parts(_ raw: String) -> (lead: Substring, core: Substring, trail: Substring) {
            let start = raw.firstIndex(where: \.isLetter) ?? raw.endIndex
            let end = raw.lastIndex(where: \.isLetter).map(raw.index(after:)) ?? start
            guard start < end else { return (Substring(raw), "", "") }
            return (raw[..<start], raw[start..<end], raw[end...])
        }
        func lower(_ index: Int) -> String? {
            guard words.indices.contains(index) else { return nil }
            let p = parts(words[index].raw)
            return p.core.isEmpty ? nil : p.core.lowercased()
        }
        /// The word at `index` starts a sentence: first in the text, or after . ! ? or a new line.
        func startsSentence(_ index: Int) -> Bool {
            guard index > 0 else { return true }
            if words[index].gap.contains(where: \.isNewline) { return true }
            return words[index - 1].raw.last.map { ".!?".contains($0) } ?? false
        }

        var out: [String?] = words.map(\.raw)
        var index = 0
        while index < words.count {
            defer { index += 1 }
            let p = parts(words[index].raw)
            guard !p.core.isEmpty, p.lead.allSatisfy({ !$0.isLetter && !$0.isNumber && !"@#/_".contains($0) }),
                  p.trail.allSatisfy({ !$0.isLetter && !$0.isNumber && !"/_@".contains($0) && $0 != "-" }) else { continue }
            // "twenty-first" is one word; "twenty first" two.
            let pieces = p.core.lowercased().split(separator: "-").map(String.init)
            var value: Int?
            var first = index
            if pieces.count == 2, let t = tens[pieces[0]], let u = unitOrdinals[pieces[1]] {
                value = t + u
            } else if pieces.count == 1 {
                let word = pieces[0]
                if let u = unitOrdinals[word] {
                    value = u
                    // "twenty first": the tens word before it belongs to the number.
                    if index > 0, let t = lower(index - 1).flatMap({ tens[$0] }),
                       parts(words[index - 1].raw).trail.isEmpty, !words[index].gap.contains(where: \.isNewline) {
                        value = t + u
                        first = index - 1
                    }
                } else {
                    value = teenOrdinals[word] ?? tensOrdinals[word]
                }
            }
            guard let number = value else { continue }
            let leading = parts(words[first].raw)
            // A capitalized ordinal mid-sentence is a name: "Fifth Avenue", "Twenty First Century".
            if leading.core.first?.isUppercase == true, !startsSentence(first) { continue }
            // "Twenty First Century" opening a sentence: the ordinal's own capital marks a title.
            if first != index, p.core.first?.isUppercase == true { continue }
            let before = lower(first - 1), after = lower(index + 1)
            let afterWord = p.trail.isEmpty ? after : nil
            // "a tenth of a second", "one fifth": a fraction, not a rank.
            if let before, fractionLeads.contains(before), parts(words[first - 1].raw).trail.isEmpty,
               (before != "a" && before != "an") || afterWord == "of" {
                continue
            }
            if number < 10 {
                guard small || (numericDates && before.map(months.contains) == true) else { continue }
                if let afterWord, notAfterSmall.contains(afterWord) { continue }
                // "first of all", "first and foremost".
                if let afterWord, let next = lower(index + 2), afterWord == "of" && next == "all" || afterWord == "and" && next == "foremost" { continue }
                let ranked = before.map { rankers.contains($0) || months.contains($0) } ?? false
                let rankNoun = afterWord.map { rankNouns.contains($0) } ?? false
                guard ranked && parts(words[first - 1].raw).trail.isEmpty || rankNoun else { continue }
            }
            let written = String(number) + suffix(number)
            out[first] = String(leading.lead) + written + String(p.trail)
            for consumed in (first + 1)..<(index + 1) { out[consumed] = nil }
        }
        if small { writingListsOneWay(&out, words: words.map(\.raw), parts: parts, startsSentence: startsSentence) }
        var result = ""
        for (position, piece) in out.enumerated() {
            guard let piece else { continue }
            result += words[position].gap + piece
        }
        return result + trailing
    }

    /// Words that keep two ordinals one list: "second and third", "first through ninth".
    static let listJoins: Set<String> = ["and", "or", "to", "through", "thru", "then"]
    private static let digitOrdinal = try! NSRegularExpression(pattern: #"^\d[\d,]*(?:st|nd|rd|th)$"#, options: [.caseInsensitive])

    /// A list reads one way: "second and third place" is "2nd and 3rd place", and "second, third,
    /// 127th" is "2nd, 3rd, 127th". Once one ordinal in a list is in digits, first through ninth
    /// beside it are too. A list of words alone ("first, second, third") is left as it is.
    private static func writingListsOneWay(_ out: inout [String?], words: [String],
                                           parts: (String) -> (lead: Substring, core: Substring, trail: Substring),
                                           startsSentence: (Int) -> Bool) {
        enum Member { case digits, word(Int) }
        func member(_ index: Int) -> Member? {
            guard let piece = out[index] else { return nil }
            let core = piece.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.!?"))
            if digitOrdinal.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) != nil { return .digits }
            let p = parts(words[index])
            guard piece == words[index], p.lead.isEmpty, p.trail.allSatisfy({ ",;:.!?".contains($0) }),
                  let value = unitOrdinals[p.core.lowercased()] else { return nil }
            return .word(value)
        }
        var lists: [[Int]] = []
        var current: [Int] = []
        var gap: [Int] = []
        for index in out.indices where out[index] != nil {
            if member(index) != nil {
                let joined = current.last.map { last in
                    !out[last]!.contains(where: { ".!?".contains($0) }) && gap.count <= 1
                        && gap.allSatisfy { listJoins.contains(words[$0].lowercased()) }
                } ?? false
                if !joined { lists.append(current); current = [] }
                current.append(index)
                gap = []
            } else if !current.isEmpty {
                gap.append(index)
                if gap.count > 1 { lists.append(current); current = []; gap = [] }
            }
        }
        lists.append(current)
        for list in lists where list.count > 1 && list.contains(where: { if case .digits = member($0) { return true }; return false }) {
            for index in list {
                guard case .word(let value) = member(index) else { continue }
                let p = parts(words[index])
                // "Fifth Avenue" mid-sentence is a name.
                if p.core.first?.isUppercase == true, !startsSentence(index) { continue }
                out[index] = String(value) + suffix(value) + String(p.trail)
            }
        }
    }

    static func suffix(_ number: Int) -> String {
        if (11...13).contains(number % 100) { return "th" }
        switch number % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
