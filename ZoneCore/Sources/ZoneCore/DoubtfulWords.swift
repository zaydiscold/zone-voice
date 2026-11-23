// by zayd/cold @ zayd.wtf

import Foundation

/// A dictated word the speech engine was unsure of: the word as decoded and the lowest
/// probability the decoder gave any of its letter pieces (Fluid Speech Mini's TDT joint reports
/// one softmax probability per emitted piece). Punctuation pieces do not count; a comma the
/// engine hesitated over is not a doubt about the word before it.
public struct DoubtfulWord: Codable, Equatable, Sendable {
    public let word: String
    public let confidence: Float

    public init(word: String, confidence: Float) {
        self.word = word
        self.confidence = confidence
    }
}

/// The few dictated words most likely to be wrong, offered in the keyboard's strip to fix with
/// one tap. Only Fluid Speech Mini reports confidence; other engines send none and nothing shows.
public enum DoubtfulWords {
    /// The app sends every word under this; the keyboard's `DoubtCalibration` decides which show.
    public static let candidateCeiling: Float = 0.8
    public static let candidateLimit = 24
    /// At most this many words are flagged per dictation.
    public static let flagLimit = 3

    /// Groups decoder pieces into words. A piece that starts with a space or "▁" starts a word
    /// (SentencePiece); the rest continue it. Each word keeps the lowest confidence of its letter
    /// pieces, and its text loses surrounding punctuation ("way," is "way").
    public static func words(pieces: [(piece: String, confidence: Float)]) -> [DoubtfulWord] {
        var out: [(text: String, confidences: [Float])] = []
        for (piece, confidence) in pieces {
            guard !piece.isEmpty, piece != "<blank>", piece != "<pad>", piece != "<unk>" else { continue }
            let startsWord = piece.first == " " || piece.first == "\u{2581}"
            let body = String(piece.drop { $0 == " " || $0 == "\u{2581}" })
            let isLetters = body.contains { $0.isLetter || $0.isNumber }
            if startsWord || out.isEmpty {
                out.append((body, isLetters ? [confidence] : []))
            } else {
                out[out.count - 1].text += body
                if isLetters { out[out.count - 1].confidences.append(confidence) }
            }
        }
        return out.compactMap { word in
            let text = word.text.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'\u{2019}")).inverted)
            guard !text.isEmpty, let lowest = word.confidences.min(), lowest.isFinite else { return nil }
            return DoubtfulWord(word: text, confidence: lowest)
        }
    }

    /// The words worth sending: under the ceiling, in the order spoken, at most `candidateLimit`
    /// (the least sure kept when there are more).
    public static func candidates(_ words: [DoubtfulWord]) -> [DoubtfulWord] {
        let under = words.enumerated().filter { $0.element.confidence < candidateCeiling }
        let kept = under.sorted { $0.element.confidence < $1.element.confidence }.prefix(candidateLimit)
        return kept.sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// A flagged word where it landed in the inserted text.
    public struct Placement: Equatable, Sendable {
        /// The word as it reads in the field (styling may have changed its case).
        public let word: String
        public let confidence: Float
        /// Characters from the end of the word to the end of the inserted text.
        public let charactersAfter: Int

        public init(word: String, confidence: Float, charactersAfter: Int) {
            self.word = word
            self.confidence = confidence
            self.charactersAfter = charactersAfter
        }
    }

    /// Finds each word in the text the keyboard inserted, in order. Styling can rewrite a word
    /// ("two" as "2", a filler removed, a name corrected from My Words); a word no longer there
    /// is dropped, never guessed at. Only plain words (letters and an apostrophe) are placed, so
    /// a fix deletes exactly its letters.
    public static func place(_ words: [DoubtfulWord], in inserted: String) -> [Placement] {
        let tokens = wordRanges(in: inserted)
        var next = 0
        var placements: [Placement] = []
        for doubt in words {
            let key = foldedKey(doubt.word)
            guard !key.isEmpty, let found = tokens[next...].firstIndex(where: { foldedKey(String(inserted[$0])) == key }) else { continue }
            let range = tokens[found]
            let text = String(inserted[range])
            next = found + 1
            guard text.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { continue }
            placements.append(Placement(word: text, confidence: doubt.confidence,
                                        charactersAfter: inserted.distance(from: range.upperBound, to: inserted.endIndex)))
        }
        return placements
    }

    /// The text with one placed word replaced, and the other placements after the edit. Each is
    /// counted from the end of the text, so a word before the edit is now further from the end by
    /// the change in length, and a word after it has not moved.
    public static func replacing(_ placement: Placement, with replacement: String, in inserted: String,
                                 placements: [Placement]) -> (text: String, placements: [Placement])? {
        guard placement.charactersAfter + placement.word.count <= inserted.count else { return nil }
        let end = inserted.index(inserted.endIndex, offsetBy: -placement.charactersAfter)
        let start = inserted.index(end, offsetBy: -placement.word.count)
        guard inserted[start..<end] == placement.word else { return nil }
        let text = inserted.replacingCharacters(in: start..<end, with: replacement)
        let delta = replacement.count - placement.word.count
        let remaining = placements.filter { $0 != placement }.map { other in
            other.charactersAfter > placement.charactersAfter
                ? Placement(word: other.word, confidence: other.confidence, charactersAfter: other.charactersAfter + delta)
                : other
        }
        return (text, remaining)
    }

    /// Whether the inserted text holds this word as a whole word, whatever its case.
    public static func contains(_ word: String, in inserted: String) -> Bool {
        let key = foldedKey(word)
        return !key.isEmpty && wordRanges(in: inserted).contains { foldedKey(String(inserted[$0])) == key }
    }

    /// The same word whatever its case or apostrophe shape.
    public static func sameWord(_ a: String, _ b: String) -> Bool {
        let key = foldedKey(a)
        return !key.isEmpty && key == foldedKey(b)
    }

    /// The part of the inserted text a fix rewrites: the word and everything after it.
    public static func tail(of placement: Placement, in inserted: String) -> String {
        String(inserted.suffix(placement.charactersAfter + placement.word.count))
    }

    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let inWord = c.isLetter || c.isNumber || ((c == "'" || c == "\u{2019}") && start != nil)
            if inWord {
                if start == nil { start = index }
            } else if let s = start {
                ranges.append(s..<trimmedEnd(text, s, index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start { ranges.append(s..<trimmedEnd(text, s, text.endIndex)) }
        return ranges
    }

    /// A word's end before a trailing apostrophe ("dogs'" stays whole only when it is a word).
    private static func trimmedEnd(_ text: String, _ start: String.Index, _ end: String.Index) -> String.Index {
        var e = end
        while e > start, let last = text[..<e].last, last == "'" || last == "\u{2019}" { e = text.index(before: e) }
        return e
    }

    static func foldedKey(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    // MARK: Alternatives

    /// What the strip offers in place of a flagged word, best first: what the person chose for
    /// this word before, then their own words and contacts that sound like it, then dictionary
    /// words a slip or two away that sound like it, read against the word before it when the
    /// word-pair table is loaded. Never the word itself.
    public static func alternatives(for heard: String, previous: String?, corrector: Autocorrector?,
                                    personalWords: [String], memory: DoubtMemory, limit: Int = 3) -> [String] {
        let key = foldedKey(heard)
        guard !key.isEmpty else { return [] }
        var out: [String] = []
        var seen: Set<String> = [key]
        func add(_ word: String) {
            let k = foldedKey(word)
            guard !k.isEmpty, seen.insert(k).inserted else { return }
            out.append(word)
        }
        for chosen in memory.choices(for: heard) { add(chosen) }
        let sound = PersonalWordMatcher.soundKey(heard)
        for word in personalWords where !word.contains(" ") && PersonalWordMatcher.soundKey(word) == sound {
            add(word)
        }
        if let corrector {
            let words = corrector.words
            let previousIndex = previous.flatMap { words.lookup($0)?.index }
            let scored = words.neighbors(of: key, maxCost: 2, limit: 16).compactMap { neighbor -> (String, Float)? in
                let entry = neighbor.entry
                guard entry.isSuggestible, foldedKey(entry.display) != key else { return nil }
                var score = neighbor.cost + 0.4 * log10(Float(entry.rank) + 10)
                if PersonalWordMatcher.soundKey(entry.display) == sound { score -= 1 }
                if let pairs = corrector.context, let previousIndex, pairs.knows(previous: previousIndex),
                   let cost = pairs.cost(of: entry.index, after: previousIndex) {
                    score += 0.17 * min(max(cost - pairs.unigramCost(of: entry.index), -4), 4)
                }
                return (entry.display, score)
            }
            for (word, _) in scored.sorted(by: { $0.1 < $1.1 }) { add(word) }
        }
        return Array(out.prefix(limit)).map { cased($0, like: heard) }
    }

    /// The heard word's capital carries over ("Kaylee" heard at a sentence start offers "Kayleigh",
    /// "Hear" offers "Here"); a name's own capital always stays.
    static func cased(_ word: String, like heard: String) -> String {
        guard heard.first?.isUppercase == true, let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }
}

/// Which confidence is low enough to flag, for this person. It starts from how often a word in
/// each confidence band was wrong when Zone measured Fluid Speech Mini on LibriSpeech, and each
/// fix or keep in the strip adds to that band's count, so the flags follow how often this
/// person's flagged words really were wrong. A band is flagged while its words are more likely
/// wrong than right; the measured prior stops that well below 0.8, so a word the engine was
/// fairly sure of is never flagged however the counts go.
public struct DoubtCalibration: Codable, Equatable, Sendable {
    /// Upper edges of the bands, from 0.
    public static let bands: [Float] = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    /// Share of words wrong per band: Fluid Speech Mini on all 2,939 LibriSpeech test-other clips,
    /// 52,383 words (2026-11-15). Under 0.5 a word is more likely wrong than right (73% of the
    /// 358 words there were), about 0.7 words per 100, and 9 in 10 clips have none.
    public static let measuredWrong: [Double] = [0.81, 0.82, 0.67, 0.44, 0.37, 0.32]
    /// The measurement counts as this many strip decisions per band, so one tap does not move
    /// it: about four fixes start flagging the 0.5 band, about a dozen keeps stop the 0.4 band.
    public static let priorWeight: Double = 30
    /// Flagged while at least this share of a band's words are expected to be wrong.
    public static let flagShare: Double = 0.5

    public private(set) var fixed: [Int]
    public private(set) var kept: [Int]

    public init() {
        fixed = Array(repeating: 0, count: Self.bands.count)
        kept = Array(repeating: 0, count: Self.bands.count)
    }

    static func band(_ confidence: Float) -> Int? {
        Self.bands.firstIndex { confidence < $0 }
    }

    /// Expected share wrong in the band: the measurement and this person's decisions together.
    public func expectedWrong(_ confidence: Float) -> Double? {
        guard let b = Self.band(confidence), b < fixed.count, b < kept.count else { return nil }
        return (Self.measuredWrong[b] * Self.priorWeight + Double(fixed[b])) / (Self.priorWeight + Double(fixed[b] + kept[b]))
    }

    public func flags(_ confidence: Float) -> Bool {
        (expectedWrong(confidence) ?? 0) >= Self.flagShare
    }

    /// The words to show, least sure first among those flagged, at most `limit`, in spoken order.
    public func select(_ words: [DoubtfulWord], limit: Int = DoubtfulWords.flagLimit) -> [DoubtfulWord] {
        let flagged = words.enumerated().filter { flags($0.element.confidence) }
        let chosen = flagged.sorted { $0.element.confidence < $1.element.confidence }.prefix(limit)
        return chosen.sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// A flagged word was fixed (true) or kept as heard (false).
    public mutating func record(confidence: Float, fixed wasFixed: Bool) {
        guard let b = Self.band(confidence), b < fixed.count, b < kept.count else { return }
        if wasFixed { fixed[b] += 1 } else { kept[b] += 1 }
    }
}

/// What the person chose in place of a heard word, newest choices kept, so the same mishearing
/// offers the same fix first next time.
public struct DoubtMemory: Codable, Equatable, Sendable {
    public static let limit = 300
    /// Heard word (folded) to chosen words, most recent last.
    private var entries: [String: [String]] = [:]
    private var order: [String] = []

    public init() {}

    public func choices(for heard: String) -> [String] {
        (entries[DoubtfulWords.foldedKey(heard)] ?? []).reversed()
    }

    public mutating func record(heard: String, chosen: String) {
        let key = DoubtfulWords.foldedKey(heard)
        guard !key.isEmpty, DoubtfulWords.foldedKey(chosen) != key else { return }
        var list = entries[key] ?? []
        list.removeAll { DoubtfulWords.foldedKey($0) == DoubtfulWords.foldedKey(chosen) }
        list.append(chosen)
        entries[key] = Array(list.suffix(3))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit {
            entries[order.removeFirst()] = nil
        }
    }
}
