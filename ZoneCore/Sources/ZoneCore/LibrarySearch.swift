// by zayd/cold @ zayd.wtf

import Foundation

/// Search over what the person said: notes and dictations. Speech recognition spells by sound,
/// people type a search with their thumbs, and both get words slightly wrong, so a plain
/// "contains" misses most of what it should find. This follows the same order as the computer
/// side (`search_wide` in zone-mcp), so the phone and the computer answer alike:
///
/// 1. Every word, as typed or in another form: a plural or tense (`meeting` finds `meetings`),
///    the beginning of a longer word while it is still being typed (`dent` finds `dentist`), a
///    word inside a joined one (`milk` finds `oatmilk`), two words said as one (`todo` finds
///    `to do`), and a number written either way (`5` finds `five`).
/// 2. A word found nowhere in the library is tried with close spellings from the library's own
///    words: one slipped letter (two in a long word), two letters swapped, or a different
///    spelling of the same sound (`versel` finds `Vercel`, `kowalsky` finds `Kowalski`). A word
///    the library does have is never respelled, so `meeting` cannot drift to `melting`.
/// 3. Only when nothing has every word, items with some of them.
///
/// Results come best first (the words side by side, then whole words, then partial ones, then
/// close spellings, then some of the words) and newest first within each. Each hit says how it
/// matched and where, so a row can show the words around the match and a page can light them.
///
/// The index is built once per library and holds each distinct word once; a search grades the
/// vocabulary, then walks integers. 2,000 items of 150 words search in a few milliseconds
/// (`LibrarySearchTests.testSearchingTwoThousandLongNotesIsFast`).
public struct LibrarySearch: Sendable {
    public struct Document: Sendable {
        public let id: UUID
        public let text: String
        public let date: Date
        public init(id: UUID, text: String, date: Date) {
            self.id = id
            self.text = text
            self.date = date
        }
    }

    /// How an item matched, best first.
    public enum Match: Int, Comparable, Sendable {
        /// Every word, side by side in the order typed.
        case phrase
        /// Every word as a whole word, or another form of it.
        case words
        /// Every word, some only as the beginning or a part of a longer word.
        case partial
        /// Every word, some only by a close spelling or the same sound.
        case close
        /// Some of the words.
        case some

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Hit: Sendable, Equatable {
        public let id: UUID
        public let match: Match
        /// Where the matched words are, as UTF-16 offsets into the item's text, in order.
        public let ranges: [Range<Int>]
    }

    /// A word of the search that the library does not have, and the library's words used for it.
    public struct Respelling: Sendable, Equatable {
        public let typed: String
        public let found: [String]
    }

    public struct Result: Sendable, Equatable {
        public let hits: [Hit]
        public let respelled: [Respelling]
        /// True when nothing had every word and the hits have only some of them.
        public let widened: Bool

        public static let empty = Result(hits: [], respelled: [], widened: false)
    }

    private struct Entry: Sendable {
        let id: UUID
        let date: Date
        /// One per word: its place in `vocabulary`, and where it is in the text.
        let words: [Int32]
        let starts: [Int32]
        let lengths: [Int32]
    }

    private struct Word: Sendable {
        let folded: String
        let stem: String
        /// As the person wrote or said it, for "Showing dentist".
        let shown: String
        var count: Int
    }

    private let entries: [Entry]
    private let vocabulary: [Word]

    public init(documents: [Document]) {
        var vocabulary: [Word] = []
        var index: [String: Int32] = [:]
        entries = documents.map { document in
            var words: [Int32] = [], starts: [Int32] = [], lengths: [Int32] = []
            for token in Self.tokens(document.text) {
                let place: Int32
                if let known = index[token.folded] {
                    place = known
                    vocabulary[Int(known)].count += 1
                } else {
                    place = Int32(vocabulary.count)
                    index[token.folded] = place
                    vocabulary.append(Word(folded: token.folded, stem: Self.stem(token.folded), shown: token.shown, count: 1))
                }
                words.append(place)
                starts.append(Int32(token.range.lowerBound))
                lengths.append(Int32(token.range.count))
            }
            return Entry(id: document.id, date: document.date, words: words, starts: starts, lengths: lengths)
        }
        self.vocabulary = vocabulary
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Searching

    /// How well one word of the library answers one word of the search. Lower is better; 0 is no match.
    private enum Grade: UInt8 { case none = 0, whole = 1, partial = 2, close = 3 }

    public func search(_ query: String) -> Result {
        let terms = Self.tokens(query).map(\.folded)
        guard !terms.isEmpty, !entries.isEmpty else { return .empty }

        // Grade the vocabulary once per word of the search; the items are then integer lookups.
        var grades: [[UInt8]] = []
        var respelled: [Respelling] = []
        for term in terms {
            var column = [UInt8](repeating: 0, count: vocabulary.count)
            let stem = Self.stem(term)
            var found = false
            for (place, word) in vocabulary.enumerated() {
                let grade = Self.grade(term: term, stem: stem, word: word)
                if grade != .none { column[place] = grade.rawValue; found = true }
            }
            // Two words said or typed as one ("todo" for "to do") count as found: the word is
            // in the library, only spaced differently.
            if !found, term.count >= 4, joinedSomewhere(term) { found = true }
            if !found {
                let close = closeSpellings(of: term)
                for candidate in close { column[candidate] = Grade.close.rawValue }
                if !close.isEmpty {
                    respelled.append(Respelling(typed: term, found: close.map { vocabulary[$0].shown }))
                }
            }
            grades.append(column)
        }

        var every: [(hit: Hit, date: Date)] = []
        var partly: [(hit: Hit, date: Date, found: Int)] = []
        for entry in entries {
            var ranges: [Range<Int>] = []
            var worst: UInt8 = 0
            var found = 0
            var foundContent = 0
            for (number, term) in terms.enumerated() {
                let column = grades[number]
                var best: UInt8 = 0
                for (position, place) in entry.words.enumerated() {
                    let grade = column[Int(place)]
                    guard grade != 0 else { continue }
                    if best == 0 || grade < best { best = grade }
                    ranges.append(Self.range(entry, position))
                }
                if best == 0, term.count >= 4 {
                    // "todo" against "to do", "checkin" against "check-in".
                    for position in entry.words.indices.dropLast() {
                        let first = vocabulary[Int(entry.words[position])].folded
                        let second = vocabulary[Int(entry.words[position + 1])].folded
                        guard first.count + second.count == term.count, term.hasPrefix(first), term.hasSuffix(second) else { continue }
                        best = Grade.whole.rawValue
                        ranges.append(Self.range(entry, position).lowerBound..<Self.range(entry, position + 1).upperBound)
                    }
                }
                guard best != 0 else { continue }
                found += 1
                if !Self.littleWords.contains(term) { foundContent += 1 }
                worst = max(worst, best)
            }
            guard found > 0 else { continue }
            let merged = Self.merge(ranges)
            if found == terms.count {
                var match: Match = worst == Grade.close.rawValue ? .close : (worst == Grade.partial.rawValue ? .partial : .words)
                if match != .close, terms.count > 1, inARow(entry, grades) { match = .phrase }
                every.append((Hit(id: entry.id, match: match, ranges: merged), entry.date))
            } else if foundContent > 0 || terms.allSatisfy(Self.littleWords.contains) {
                // A little word alone ("the", "to") is in everything and finds nothing.
                partly.append((Hit(id: entry.id, match: .some, ranges: merged), entry.date, foundContent))
            }
        }
        if !every.isEmpty {
            let hits = every.sorted { ($0.hit.match, $1.date) < ($1.hit.match, $0.date) }.map(\.hit)
            return Result(hits: hits, respelled: respelled, widened: false)
        }
        let hits = partly.sorted { ($1.found, $1.date) < ($0.found, $0.date) }.map(\.hit)
        return Result(hits: hits, respelled: respelled, widened: !hits.isEmpty)
    }

    private static func range(_ entry: Entry, _ position: Int) -> Range<Int> {
        let start = Int(entry.starts[position])
        return start..<(start + Int(entry.lengths[position]))
    }

    /// The words of the search in order, one after another, somewhere in the item.
    private func inARow(_ entry: Entry, _ grades: [[UInt8]]) -> Bool {
        let count = grades.count
        guard entry.words.count >= count else { return false }
        for start in 0...(entry.words.count - count) {
            var all = true
            for offset in 0..<count where grades[offset][Int(entry.words[start + offset])] == 0 {
                all = false
                break
            }
            if all { return true }
        }
        return false
    }

    private func joinedSomewhere(_ term: String) -> Bool {
        for entry in entries {
            for position in entry.words.indices.dropLast() {
                let first = vocabulary[Int(entry.words[position])].folded
                guard first.count < term.count, term.hasPrefix(first) else { continue }
                let second = vocabulary[Int(entry.words[position + 1])].folded
                if first.count + second.count == term.count, term.hasSuffix(second) { return true }
            }
        }
        return false
    }

    private static func grade(term: String, stem: String, word: Word) -> Grade {
        if word.folded == term || word.stem == stem { return .whole }
        // One letter is the start of too many words to mean anything.
        if term.count >= 2, word.folded.hasPrefix(term) { return .partial }
        if term.count >= 3, word.folded.count > term.count, word.folded.contains(term) { return .partial }
        return .none
    }

    /// The library's words close to one it does not have, nearest and most used first.
    private func closeSpellings(of term: String) -> [Int] {
        let letters = Array(term)
        guard letters.count >= 3, letters.contains(where: \.isLetter) else { return [] }
        // One edit for most words, two for long ones (names, technical words), where one
        // misheard sound often changes two letters.
        let allowed = letters.count <= 6 ? 1 : 2
        let sound = PersonalWordMatcher.soundKey(term)
        var found: [(place: Int, distance: Int, count: Int)] = []
        for (place, word) in vocabulary.enumerated() {
            let other = Array(word.folded)
            guard other.count >= 3 else { continue }
            let sameSound = sound.count >= 2 && PersonalWordMatcher.soundKey(word.folded) == sound
            guard sameSound || Self.startsAlike(letters[0], other[0]) else { continue }
            if abs(other.count - letters.count) <= 2 {
                let limit = sameSound ? max(2, letters.count / 3) : allowed
                // A three-letter word one letter off is another word, unless it starts the same.
                if letters.count > 3 || letters[0] == other[0] || sameSound,
                   let distance = Self.distance(letters, other, limit: limit) {
                    found.append((place, distance, word.count))
                    continue
                }
            }
            // Still being typed, with a slip: "dentes" on the way to "dentist".
            if letters.count >= 4, other.count > letters.count,
               let distance = Self.distance(letters, Array(other.prefix(letters.count)), limit: 1) {
                found.append((place, distance + 1, word.count))
            }
        }
        return found.sorted { ($0.distance, $1.count) < ($1.distance, $0.count) }.prefix(4).map(\.place)
    }

    /// Letters a misheard or mistyped word may start with instead: the same sound, or a vowel
    /// for a vowel.
    private static func startsAlike(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        for group in ["ckqs", "fpv", "gj", "aeiouy", "wh", "sz", "td", "mn"] where group.contains(a) && group.contains(b) { return true }
        return false
    }

    /// Edit distance where two swapped neighbors count once ("dentsit"), or nil when over `limit`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= limit ? max(a.count, b.count) : nil }
        var beforeLast = [Int](repeating: 0, count: b.count + 1)
        var last = Array(0...b.count)
        var row = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            row[0] = i
            var least = row[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(last[j] + 1, row[j - 1] + 1, last[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, beforeLast[j - 2] + 1)
                }
                row[j] = value
                least = min(least, value)
            }
            if least > limit { return nil }
            (beforeLast, last, row) = (last, row, beforeLast)
        }
        return last[b.count] <= limit ? last[b.count] : nil
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: Words

    struct Token: Equatable {
        let folded: String
        let shown: String
        /// UTF-16 offsets into the text.
        let range: Range<Int>
    }

    /// Words that are in nearly everything: alone they find nothing worth showing.
    static let littleWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "had", "has", "have", "i", "if", "in", "is",
        "it", "its", "me", "my", "of", "on", "or", "so", "that", "the", "then", "this", "to", "was", "we", "with", "you",
    ]

    private static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
    ]

    /// The words of a text: letters and digits, lowercased, accents removed, an apostrophe inside
    /// a word dropped ("don't" is "dont" however it was typed). Everything else ends a word.
    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var shown = ""
        var start = 0
        var offset = 0
        func end() {
            guard !current.isEmpty else { return }
            // Nearly every word is plain ASCII, where lowercasing is all folding does.
            let folded = current.utf8.allSatisfy({ $0 < 128 })
                ? current.lowercased()
                : current.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            tokens.append(Token(folded: folded, shown: shown, range: start..<offset))
            current = ""
            shown = ""
        }
        for character in text {
            let width = character.utf16.count
            if character.isLetter || character.isNumber {
                if current.isEmpty { start = offset }
                current.append(character)
                shown.append(character)
            } else if (character == "'" || character == "’"), !current.isEmpty {
                shown.append(character)
            } else {
                // An apostrophe kept for show at the very end ("the Smiths'") is not part of the word.
                while let last = shown.last, last == "'" || last == "’" { shown.removeLast() }
                end()
            }
            offset += width
            if current.isEmpty { shown = "" }
        }
        while let last = shown.last, last == "'" || last == "’" { shown.removeLast() }
        end()
        return tokens
    }

    /// A word without its ending, so its plural and tenses meet: "meetings" and "meeting",
    /// "called" and "call", "making" and "make", "parties" and "party". Light on purpose: a
    /// stem stays at least three letters with a vowel, so "thing" and "string" are left whole.
    /// A number word becomes its digits ("five" is "5").
    static func stem(_ word: String) -> String {
        if let digits = numbers[word] { return digits }
        var stem = word
        func keeps(_ candidate: Substring) -> Bool {
            candidate.count >= 3 && candidate.contains(where: { "aeiouy".contains($0) })
        }
        if stem.hasSuffix("ies"), stem.count >= 5 {
            stem = stem.dropLast(3) + "y"
        } else if stem.hasSuffix("es"), stem.count >= 5, ["s", "x", "z", "ch", "sh"].contains(where: { stem.dropLast(2).hasSuffix($0) }) {
            stem = String(stem.dropLast(2))
        } else if stem.hasSuffix("s"), !stem.hasSuffix("ss"), !stem.hasSuffix("us"), !stem.hasSuffix("is"), stem.count >= 4 {
            stem = String(stem.dropLast())
        }
        for ending in ["ing", "ed"] where stem.hasSuffix(ending) && stem.count >= ending.count + 3 {
            var base = stem.dropLast(ending.count)
            // "stopped" and "running" double the last letter before the ending.
            if base.count >= 4, let last = base.last, base.dropLast().last == last, !"lsz".contains(last) { base = base.dropLast() }
            if keeps(base) { stem = String(base) }
            break
        }
        // "make" meets "making", "like" meets "liked".
        if stem.hasSuffix("e"), stem.count >= 4, keeps(stem.dropLast()) { stem = String(stem.dropLast()) }
        return stem
    }

    // MARK: Showing a match

    /// Where to start showing a text whose match is in the middle of it, so the match is on a
    /// row's first lines: the start of the sentence the match is in when that is near, otherwise
    /// a word boundary a few words before it. A UTF-16 offset; 0 when the match is near the
    /// beginning anyway.
    public static func excerptStart(in text: String, before match: Range<Int>, lead: Int = 48) -> Int {
        let units = Array(text.utf16)
        guard match.lowerBound > lead, match.lowerBound <= units.count else { return 0 }
        var start = match.lowerBound - lead
        // Back to the beginning of the word the cut landed in, never inside a surrogate pair.
        let space = UInt16(32), newline = UInt16(10)
        while start > 0, units[start - 1] != space, units[start - 1] != newline { start -= 1 }
        // The last sentence that begins between there and the match.
        let ends: Set<UInt16> = [46, 33, 63, 10] // . ! ? newline
        var index = match.lowerBound - 1
        while index > start {
            if units[index - 1] == space || units[index - 1] == newline, index >= 2, ends.contains(units[index - 2]) || units[index - 1] == newline {
                return index
            }
            index -= 1
        }
        return start
    }

    /// A text as a row shows it for a search: from just before its first match, with one
    /// character standing for the words left out, and the marks moved to match.
    public static func excerpt(_ text: String, marks: [Range<Int>]) -> (text: String, marks: [Range<Int>]) {
        guard let first = marks.first else { return (text, marks) }
        let start = excerptStart(in: text, before: first)
        guard start > 0 else { return (text, marks) }
        let units = Array(text.utf16)[start...]
        let shown = "\u{2026} " + String(utf16CodeUnits: Array(units), count: units.count)
        let moved = marks.compactMap { mark -> Range<Int>? in
            mark.lowerBound >= start ? (mark.lowerBound - start + 2)..<(mark.upperBound - start + 2) : nil
        }
        return (shown, moved)
    }
}

/// What a row shows of a note: a few words to know it by, the rest to skim, and how long it is.
/// Dictated notes have no titles and rarely a line break, so the lead is the first sentence (or
/// the whole note) when that is short enough to be a heading of at most two lines, and otherwise
/// the first words that fit on one line, cut between words so nothing is ever lost to "...".
public struct NotePreview: Equatable, Sendable {
    public let lead: String
    /// What follows the lead, or empty when the lead is the whole note. Line breaks are spaces.
    public let rest: String
    /// Where `lead` and `rest` start in the note, as UTF-16 offsets. Every character of both
    /// sits where it does in the note, so a search's ranges can be moved onto them.
    public let leadOffset: Int
    public let restOffset: Int
    public let words: Int

    /// - Parameters:
    ///   - sentenceLimit: the longest first sentence, or whole note, that is its own lead.
    ///   - lineLimit: how many characters of a longer opening lead it instead (about one line of
    ///     a row on the narrowest iPhone, beside Copy).
    public init(_ text: String, sentenceLimit: Int = 60, lineLimit: Int = 30) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        let line = trimmed.prefix { !$0.isNewline }
        var cut = line.endIndex
        // The first sentence, when there is one.
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if ".!?:".contains(line[index]), next == line.endIndex || line[next].isWhitespace {
                cut = next
                break
            }
            index = next
        }
        if line[..<cut].count > sentenceLimit {
            // The words that fit on a line, never less than one.
            var end = line.index(line.startIndex, offsetBy: lineLimit)
            while end > line.startIndex, !line[line.index(before: end)].isWhitespace, !line[end].isWhitespace {
                end = line.index(before: end)
            }
            cut = end == line.startIndex ? line.index(line.startIndex, offsetBy: lineLimit) : end
        }
        var lead = String(line[..<cut]).trimmingCharacters(in: .whitespaces)
        let remainder = trimmed[cut...]
        let rest = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lead that stops mid-sentence does not end in a comma; one that is a sentence keeps
        // its question mark, and loses a plain period or colon when words follow below.
        if !rest.isEmpty || lead.hasSuffix(",") || lead.hasSuffix(";") {
            while let last = lead.last, ",;".contains(last) { lead.removeLast() }
        }
        if !rest.isEmpty, let last = lead.last, ".:".contains(last), !lead.hasSuffix("...") { lead.removeLast() }
        self.lead = lead
        // Line breaks become spaces one for one, so offsets into the rest stay offsets into the note.
        self.rest = String(utf16CodeUnits: rest.utf16.map { $0 == 10 || $0 == 13 ? 32 : $0 }, count: rest.utf16.count)
        leadOffset = text.prefix { $0.isWhitespace || $0.isNewline }.utf16.count
        let skipped = remainder.prefix { $0.isWhitespace || $0.isNewline }.utf16.count
        restOffset = rest.isEmpty ? text.utf16.count : leadOffset + trimmed[..<cut].utf16.count + skipped
    }

    /// "86 words", "1 word".
    public var length: String { words == 1 ? "1 word" : "\(words.formatted()) words" }

    /// What a row shows for a search: the lead, and the rest from just before the first match
    /// in it, each with where its matched words are (UTF-16 offsets into the string shown).
    public struct Found: Equatable, Sendable {
        public let lead: String
        public let leadMarks: [Range<Int>]
        public let rest: String
        public let restMarks: [Range<Int>]
    }

    /// - Parameter marks: a hit's ranges in the whole note (`LibrarySearch.Hit.ranges`).
    public func found(_ marks: [Range<Int>]) -> Found {
        /// The part of a mark inside `bounds`, measured from where `bounds` starts.
        func inside(_ bounds: Range<Int>) -> [Range<Int>] {
            marks.compactMap { mark in
                let lower = max(mark.lowerBound, bounds.lowerBound), upper = min(mark.upperBound, bounds.upperBound)
                return lower < upper ? (lower - bounds.lowerBound)..<(upper - bounds.lowerBound) : nil
            }
        }
        let leadMarks = inside(leadOffset..<(leadOffset + lead.utf16.count))
        let inRest = inside(restOffset..<(restOffset + rest.utf16.count))
        let shown = LibrarySearch.excerpt(rest, marks: inRest)
        return Found(lead: lead, leadMarks: leadMarks, rest: shown.text, restMarks: shown.marks)
    }
}

/// The headings a long list of notes is read under: recent ones by day, then by week, month and
/// year, so hundreds of notes are a dozen groups and not a heading per day.
public enum NoteGroups {
    public static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "This week" }
        if days < 30 { return "This month" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) || days < 180 {
            style = style.month(.wide)
            return date.formatted(style)
        }
        return date.formatted(style.year())
    }
}
