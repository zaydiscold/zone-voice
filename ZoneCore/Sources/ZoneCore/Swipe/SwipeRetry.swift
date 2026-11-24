// by zayd/cold @ zayd.wtf

/// On the next swipe at the same insertion point, give a close alternative a turn.
/// A trace that lands near the middle of the original final key favors that ending.
public enum SwipeRetry {
    public static func endLetter(_ point: SwipePoint?, layout: SwipeLayout) -> UInt8? {
        guard let point else { return nil }
        return layout.letters(near: point.x, point.y, within: 0.25).first.map { UInt8($0 + 97) }
    }

    public static func alternatives(_ ranked: [SwipeCandidate], retryOf: String?, endLetter: UInt8? = nil,
                                    penalty: Float = 0.3, limit: Int = 3) -> [SwipeCandidate] {
        guard let deleted = retryOf?.lowercased(), ranked.contains(where: { $0.word.lowercased() == deleted }) else {
            return Array(ranked.prefix(limit))
        }
        let pinnedEnd = endLetter != nil && deleted.utf8.last == endLetter
        let adjusted = ranked.map { candidate in
            let word = candidate.word.lowercased()
            let penalized = word == deleted || (pinnedEnd && word.utf8.last != endLetter)
            return penalized ? SwipeCandidate(word: candidate.word, score: candidate.score + penalty,
                                              entryIndex: candidate.entryIndex) : candidate
        }
        return Array(adjusted.sorted { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }.prefix(limit))
    }
}
