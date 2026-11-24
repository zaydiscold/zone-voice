// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// One worker per visible keyboard. Initialization, neural inference and defaults serialization
/// never block touch highlighting.
///
/// The decoder's index (about 3.8 MB) and the neural scorer's weights (about 2.5 MB) are built
/// once per process and shared by every engine, as the word list is: the host makes a new
/// keyboard controller for nearly every appearance, and building them again each time churned
/// 6 MB through the allocator per appearance, which the process did not give back. All engines
/// run on one serial queue, so the scorer's scratch buffers and the decoder's personal words
/// are only touched from one thread. Each engine still keeps its own personal words and swipe
/// history, put back on the shared decoder before its decode when another engine replaced them.
final class SwipeEngine: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "wtf.zayd.zone.swipe", qos: .userInitiated)
    /// Queue only. Built by the first engine that configures; dropped when swipe typing is off.
    private static var shared: (decoder: SwipeDecoder, neural: SwipeNeuralScorer?)?
    /// Queue only. The engine whose personal words the shared decoder holds.
    private static var personalWordsOwner: ObjectIdentifier?
    /// Queue only. The list the shared decoder's personal index was last built from. One
    /// appearance configures its engine four or five times (the switches twice, the personal
    /// words, the system lexicon) and a new appearance's engine nearly always brings the same
    /// words, so an equal list costs a comparison (well under 0.1 ms) instead of a rebuild
    /// (8 to 37 ms measured for 300 to 5,000 words) queued ahead of the first swipe.
    private static var indexedWords: [String]?

    private var queue: DispatchQueue { Self.queue }
    private var decoder: SwipeDecoder?
    private var neural: SwipeNeuralScorer?
    private let learnedKey: String
    private let resetKey: String

    init(split: Bool = false) {
        learnedKey = split ? "zone.duo.split.corrections.v1" : "zone.swipe.corrections.v1"
        resetKey = split ? "zone.duo.split.reset.v1" : "zone.swipe.reset.v1"
    }
    private var learning = SwipeLearning()
    private var learns = false
    private var personalWords: [String] = []

    /// Swipe typing was switched off: the next engine builds the decoder again. Engines that
    /// still exist keep theirs until they go.
    static func releaseShared() {
        queue.async {
            shared = nil
            personalWordsOwner = nil
            indexedWords = nil
        }
    }

    func configure(learns: Bool, reset: String, personalWords: [String]) {
        queue.async {
            self.learns = learns
            self.personalWords = personalWords
            if let shared = Self.shared {
                if shared.decoder.context == nil { shared.decoder.setContextModel(WordPairs.shared) }
                if shared.neural == nil { Self.shared?.neural = SwipeNeuralScorer() }
                self.neural = Self.shared?.neural
            }
            if self.decoder == nil {
                if let data = UserDefaults.standard.data(forKey: self.learnedKey), data.count < 1_000_000,
                   let saved = try? JSONDecoder().decode(SwipeLearning.self, from: data) { self.learning = saved }
                if let shared = Self.shared ?? Self.build() {
                    // A decoder built just now has an empty personal index.
                    if Self.shared == nil { Self.indexedWords = nil }
                    Self.shared = shared
                    self.decoder = shared.decoder
                    self.neural = shared.neural
                }
            }
            if UserDefaults.standard.string(forKey: self.resetKey) != reset {
                self.learning = SwipeLearning()
                UserDefaults.standard.removeObject(forKey: self.learnedKey)
                UserDefaults.standard.set(reset, forKey: self.resetKey)
            }
            self.refreshWords()
        }
    }

    /// Queue only.
    private static func build() -> (decoder: SwipeDecoder, neural: SwipeNeuralScorer?)? {
        guard let words = WordList.shared else { return nil }
        var tuning = SwipeTuning()
        tuning.visitRadius = 0
        tuning.shortlist = 160
        // Mapped read-only: clean pages, a few hundred KB touched per session.
        let pairs = WordPairs.shared
        if pairs == nil { KeyboardLog.typing.error("swipe word pairs missing or built from another word list") }
        return (SwipeDecoder(words: words, tuning: tuning, context: pairs), SwipeNeuralScorer())
    }

    /// `retryOf` is the swiped word the person just deleted at this spot. Someone who deletes a
    /// swipe and swipes again usually wanted another word, so that word gets a score penalty on
    /// the retry. A trace that ends squarely on the original final key still favors that
    /// ending over a neighbor. Words with the same ending can still trade places.
    func decode(_ points: [SwipePoint], layout: SwipeLayout, previous: String?, retryOf: String? = nil,
                completion: @escaping @MainActor ([SwipeCandidate]) -> Void) {
        queue.async {
            if Self.personalWordsOwner != ObjectIdentifier(self) { self.refreshWords() }
            let context = SwipeContext(previousWord: previous, learning: self.learns ? self.learning : SwipeLearning())
            let geometric = self.decoder?.decode(points, layout: layout, context: context, limit: 96) ?? []
            let ranked = self.neural?.rank(geometric, points: points, layout: layout) ?? geometric
            let result = SwipeRetry.alternatives(ranked, retryOf: retryOf, endLetter: SwipeRetry.endLetter(points.last, layout: layout))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Only an explicit alternative choice trains a positive preference. Automatic guesses do not.
    func chose(_ word: String, after previous: String?) {
        queue.async {
            guard self.learns else { return }
            self.learning.chose(word, after: previous)
            self.refreshWords()
            self.save()
        }
    }

    /// Only a completed explicit replacement rejects the old guess. Delete alone is ambiguous.
    func corrected(_ original: String, to word: String, after previous: String?) {
        queue.async {
            guard self.learns, SwipeLearning.key(original) != SwipeLearning.key(word) else { return }
            self.learning.rejected(original)
            self.learning.chose(word, after: previous)
            self.refreshWords()
            self.save()
        }
    }

    /// Queue only.
    private func refreshWords() {
        guard let decoder else { return }
        let learned = learns ? (WordList.shared.map { learning.words(spelledBy: $0) } ?? learning.words) : []
        let list = personalWords + learned
        // An engine that outlived a `releaseShared` holds an older decoder; only the shared one
        // is covered by `indexedWords`.
        let isShared = Self.shared.map { $0.decoder === decoder } ?? false
        if !isShared {
            decoder.setPersonalWords(list)
        } else if Self.indexedWords != list {
            decoder.setPersonalWords(list)
            Self.indexedWords = list
        }
        Self.personalWordsOwner = ObjectIdentifier(self)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(learning) else { return }
        UserDefaults.standard.set(data, forKey: self.learnedKey)
    }

    deinit {
        // Another engine may later get this identifier; it must not take these words for its own.
        let id = ObjectIdentifier(self)
        Self.queue.async { if Self.personalWordsOwner == id { Self.personalWordsOwner = nil } }
    }
}
