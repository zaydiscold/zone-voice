// by zayd/cold @ zayd.wtf

import Foundation

/// Words the person kept once, waiting for a second keep before they are learned for good.
///
/// Keeping a word (tapping the quoted as-typed suggestion, or undoing an autocorrection and
/// typing on) used to learn it on the spot. One mistaken tap then saved a typo forever: it was
/// never corrected again and swipe and dictation offered it back. The first keep now only
/// protects the word until the keyboard process ends; the second keep, in this process or a
/// later one, learns it. A capital inside the word ("OpenRouter", "iPhone") is deliberate enough
/// to learn at once.
public struct KeepConfirmation: Equatable, Sendable {
    /// Oldest waiting words are dropped past this many, so the list stays a few kilobytes.
    public static let limit = 300

    /// Waiting words, lowercased, oldest first.
    public private(set) var pending: [String]

    public init(pending: [String] = []) {
        var seen = Set<String>()
        self.pending = Array(pending.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
            .suffix(Self.limit))
    }

    /// Records one keep of `word`. Returns true when the word should now be learned.
    public mutating func keep(_ word: String) -> Bool {
        let key = word.lowercased()
        guard !key.isEmpty else { return false }
        if Self.learnsAtOnce(word) {
            pending.removeAll { $0 == key }
            return true
        }
        if let index = pending.firstIndex(of: key) {
            pending.remove(at: index)
            return true
        }
        pending.append(key)
        if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
        return false
    }

    /// A capital after the first letter that is not an all-capitals word.
    public static func learnsAtOnce(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        let allCapitals = !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        return letters.dropFirst().contains(where: \.isUppercase) && !allCapitals
    }
}
