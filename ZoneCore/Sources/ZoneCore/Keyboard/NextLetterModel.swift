// by zayd/cold @ zayd.wtf

import Foundation

/// How likely each letter is to come next after a word prefix, for the key grid's dynamic hit
/// targets. Built from the bundled word list's most frequent completions of the prefix: each
/// completion votes for its next letter with weight `1 / (rank + rankOffset)`, a Zipf-like
/// frequency, and every letter keeps a small floor so an unseen letter is unlikely, not
/// impossible. The prefix itself, when it is a word, votes the same way for ending here, which is
/// what lets the space bar claim room from the bottom letter row after a finished word ("lot"
/// then a tap low on v is a space). Pure and deterministic; the keyboard computes it off the main
/// thread after each letter and the touch path only reads it.
public struct NextLetterLikelihood: Equatable, Sendable {
    public let prefix: String
    /// a...z then apostrophe, summing to 1: which letter comes next if the word goes on.
    public let probabilities: [Double]
    /// The chance the word ends here and the next tap is the space bar: 0 when the prefix is not
    /// a word, otherwise never 0 or 1.
    public let wordEnd: Double
    /// Bit `slot` set for a letter that goes on to a contraction typed without its apostrophe
    /// ("is" then n for "isnt", "i" then v for "ive").
    public let contractionLetters: UInt32

    public init(prefix: String, probabilities: [Double], wordEnd: Double = 0, contractionLetters: UInt32 = 0) {
        self.prefix = prefix
        self.probabilities = probabilities
        self.wordEnd = wordEnd
        self.contractionLetters = contractionLetters
    }

    /// The letter's probability, or nil for anything that is not a letter or apostrophe.
    public func probability(of character: String) -> Double? {
        guard character.utf8.count == 1, let byte = character.utf8.first else { return nil }
        let folded = byte | 0x20
        if folded >= 0x61, folded <= 0x7A, (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
            return probabilities[Int(folded - 0x61)]
        }
        if byte == 0x27 { return probabilities[26] }
        return nil
    }

    /// The chance the next tap is this key: a letter or apostrophe, or `" "` for the space bar.
    /// Letters share what the word ending leaves, so a letter and the space bar compare fairly.
    /// The space bar has no opinion (nil) inside a run that is not a word yet: it claims room
    /// only after a finished word, and never gives any up. A letter that goes on to a bare
    /// contraction counts as at least as likely as the ending: chat types "isnt" and "ive" far
    /// more than the word list's frequencies say, so the space bar never takes their n or v.
    public func nextKeyProbability(of character: String) -> Double? {
        if character == " " { return wordEnd > 0 ? wordEnd : nil }
        guard let p = probability(of: character) else { return nil }
        let next = p * (1 - wordEnd)
        if let byte = character.utf8.first, let slot = WordList.slot(byte | 0x20), contractionLetters & (1 << UInt32(slot)) != 0 {
            return max(next, wordEnd)
        }
        return next
    }
}

public enum NextLetterModel {
    /// Completions sampled per prefix: enough to rank the likely next letters, small enough that
    /// a one-letter prefix costs well under a millisecond.
    public static let sampleSize = 48
    static let rankOffset = 50.0
    /// Share of the total spread evenly over all 27 slots.
    static let floorShare = 0.02
    /// After a finished word, the ending and the word going on each keep at least this much, so
    /// neither the space bar nor a letter is ever ruled out.
    public static let wordEndFloor = 0.05

    /// Nil when there is no prefix (the first letter of a word is pure nearest key) or when the
    /// prefix is neither a word nor the start of one (a typo already, so no key deserves extra room).
    public static func likelihood(after prefix: String, in list: WordList, sampleSize: Int = sampleSize) -> NextLetterLikelihood? {
        let key = Array(prefix.lowercased().utf8)
        guard !key.isEmpty, key.count < WordList.maxWordLength else { return nil }
        let completions = list.completions(of: prefix, limit: sampleSize)
        var votes = [Double](repeating: 0, count: 27)
        let contractionLetters = list.bareContractionLetters(after: prefix)
        for entry in completions {
            let bytes = Array(entry.display.utf8)
            guard bytes.count > key.count, let slot = WordList.slot(bytes[key.count] | 0x20) else { continue }
            let vote = 1 / (Double(entry.rank) + rankOffset)
            votes[slot] += vote
            // Contractions are mostly typed without the apostrophe and fixed on space ("isnt",
            // "ive"), so the letter after it is as likely next as the apostrophe is.
            if bytes[key.count] == 0x27, bytes.count > key.count + 1, let bare = WordList.slot(bytes[key.count + 1] | 0x20) {
                votes[bare] += vote
            }
        }
        let total = votes.reduce(0, +)
        let ending = endingRank(of: prefix, in: list).map { 1 / (Double($0) + rankOffset) } ?? 0
        guard total > 0 || ending > 0 else { return nil }
        let floor = floorShare / 27
        let probabilities = total > 0 ? votes.map { floor + (1 - floorShare) * $0 / total } : [Double](repeating: 1.0 / 27, count: 27)
        let wordEnd = ending > 0 ? wordEndFloor + (1 - 2 * wordEndFloor) * ending / (ending + total) : 0
        return NextLetterLikelihood(prefix: prefix.lowercased(), probabilities: probabilities, wordEnd: wordEnd,
                                    contractionLetters: contractionLetters)
    }

    /// A prefix that is a rarer word than this ("lo", "gab") is read as the start of a longer
    /// one: the space bar takes no room from "lobby"'s b.
    public static let wordEndMaximumRank = 5_000

    /// The rank of the word the prefix already is, if it is a common one a person would end on:
    /// a suggestible lowercase dictionary word or "I", or a contraction missing its apostrophe
    /// ("dont"). A name ("ali") is more often the start of a longer one ("alina").
    static func endingRank(of prefix: String, in list: WordList) -> Int? {
        if let entry = list.lookup(prefix), entry.isSuggestible, entry.rank < wordEndMaximumRank,
           entry.display == "I" || entry.display.first?.isLowercase == true { return entry.rank }
        if let contraction = list.contraction(forBare: prefix), contraction.isSuggestible,
           contraction.rank < wordEndMaximumRank { return contraction.rank }
        return nil
    }
}
