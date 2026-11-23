// by zayd/cold @ zayd.wtf

import Foundation

/// California Mode, an experimental setting: takes the filler "like" out of a dictation.
///
/// "Like" is a verb ("I like pizza"), a comparison ("looks like rain", "like a dream"), a quote
/// ("I was like, no way") and a filler ("it was like really good"). The recognizer writes all of
/// them the same way, usually with no commas at all, so each one is judged by the words around it.
/// When those words do not settle it, the "like" stays: a missed filler costs nothing, a removed
/// verb changes what the person said.
///
/// - Light removes fillers: set off by commas ("it was, like, so good"), opening a sentence or
///   clause ("Like, I don't know", "and like, we left"), before an intensifier or adjective after
///   "was" or "is" ("I was like really tired", "it was like amazing"), before a question ("so like
///   what are we doing"), and before a verb it cannot be ("we like made out").
/// - Aggressive also removes hedges: before an amount ("took like five minutes", "at like 6"),
///   between "and", "but" or "so" and a new clause ("and like we went home"), and after "he" or
///   "she", where the verb would be "likes" ("she like goes").
///
/// Only the word "like" is ever removed, and only in dictation: meeting transcripts stay as said.
///
/// Measured on recognized speech: `docs/evidence/2026-11-12-california-mode.md` (private notes).
public enum CaliforniaMode: String, Codable, CaseIterable, Sendable {
    case off
    case light
    case aggressive

    public var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .aggressive: return "Aggressive"
        }
    }

    /// The text with filler "like" removed at this level. `wordsBefore` are the last words of the
    /// unfinished sentence before the cursor, lowercase, when the dictation continues one; a "like"
    /// that starts the dictation is then judged by them. A "like" inside one of `personalWords`
    /// is never touched.
    func tapering(_ text: String, wordsBefore: [String] = [], continuesSentence: Bool = false,
                  keeping personalWords: [String] = []) -> String {
        guard self != .off, text.range(of: "like", options: .caseInsensitive) != nil else { return text }
        let text = Self.collapsingStutters(text)
        let words = Self.wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        guard words.contains(where: { text[$0].lowercased() == "like" }) else { return text }
        let protected = VocabularyCandidates.matchedRanges(in: text, words: personalWords).compactMap { Range($0, in: text) }
        let passage = Passage(text: text, words: words, wordsBefore: wordsBefore, continuesSentence: continuesSentence)

        var removed = Set<Int>()
        for index in words.indices where passage.lower[index] == "like" {
            if protected.contains(where: { $0.overlaps(words[index]) }) { continue }
            if passage.fillerRule(at: index, aggressive: self == .aggressive, removedBefore: removed) != nil {
                removed.insert(index)
            }
        }
        guard !removed.isEmpty else { return text }
        return passage.removing(removed)
    }

    /// Each "like" in `text` with the rule that removes it at this level, or nil where it stays,
    /// after stutters are collapsed. For measurement only; `tapering` is what dictation uses.
    func fillerRules(in text: String) -> [(context: String, rule: String?)] {
        let collapsed = Self.collapsingStutters(text)
        let words = Self.wordExpression.matches(in: collapsed, range: NSRange(collapsed.startIndex..., in: collapsed))
            .compactMap { Range($0.range, in: collapsed) }
        let passage = Passage(text: collapsed, words: words, wordsBefore: [], continuesSentence: false)
        var removed = Set<Int>()
        var out: [(String, String?)] = []
        for index in words.indices where passage.lower[index] == "like" {
            let rule = passage.fillerRule(at: index, aggressive: self == .aggressive, removedBefore: removed)
            if rule != nil { removed.insert(index) }
            let from = words[max(0, index - 6)].lowerBound, to = words[min(words.count - 1, index + 6)].upperBound
            out.append((String(collapsed[from..<to]), rule))
        }
        return out
    }

    /// "like like" and "like, like" said by accident keep one "like", which is then judged on its
    /// own: "like like you say" keeps "like you say", "It was, like, like, the best" becomes "It
    /// was, like, the best" and then loses that filler too. Doubled on purpose after a subject or
    /// "do" ("Do you like like him?", "I like like her") it is the verb and stays.
    static func collapsingStutters(_ text: String) -> String {
        guard text.range(of: "like", options: .caseInsensitive) != nil else { return text }
        var out = text
        // Right to left, so earlier ranges stay valid.
        let words = wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        guard words.count > 1 else { return text }
        let lower = words.map { text[$0].lowercased() }
        let verbLeads: Set<String> = ["i", "you", "we", "they", "he", "she", "do", "does", "did", "don't", "doesn't",
                                      "didn't", "really", "actually", "kinda", "still", "totally", "would", "i'd", "you'd",
                                      // "if I say something like like too much": the word itself, talked about.
                                      "something", "say", "says", "said", "saying", "word", "spell", "type", "typed"]
        for index in stride(from: words.count - 2, through: 0, by: -1)
        where lower[index] == "like" && lower[index + 1] == "like" {
            let gap = text[words[index].upperBound..<words[index + 1].lowerBound]
            guard !Passage.endsSentence(gap) else { continue }
            let previous = index > 0 ? lower[index - 1].replacingOccurrences(of: "’", with: "'") : nil
            if let previous, verbLeads.contains(previous) { continue }
            // "Stuff people like, like hiking": with a comma between them the first is the verb and
            // the second starts an example. Only where the first sits in a filler's place ("It was
            // like, like, the best", "And like, like, we left") is the pair a stutter.
            if gap.contains(",") {
                let gapBefore = text[(index > 0 ? words[index - 1].upperBound : text.startIndex)..<words[index].lowerBound]
                let fillerPlace = previous.map { Passage.isCopula($0) || Passage.connectors.contains($0) ||
                    Passage.hesitations.contains($0) || $0 == "mean" } ?? true
                guard fillerPlace || gapBefore.contains(",") || Passage.endsSentence(gapBefore) else { continue }
            }
            // Drop the second "like" and the gap before it; the first keeps its capital and commas.
            out.removeSubrange(words[index].upperBound..<words[index + 1].upperBound)
        }
        return out
    }

    /// A word with any inner apostrophes or hyphens ("I'm", "life-like"), or a masked literal: the
    /// private-use placeholders that stand for URLs and code count as words, so a "like" after one
    /// is judged as mid-sentence rather than as an opener.
    private static let wordExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{M}\p{N}_\x{E000}-\x{F8FF}]+(?:['’\-][\p{L}\p{M}\p{N}_\x{E000}-\x{F8FF}]+)*"#)
}

/// One dictation split into words and the gaps between them, with the questions the rules ask
/// about the words around a "like".
private struct Passage {
    let text: String
    let words: [Range<String.Index>]
    /// Lowercased, curly apostrophes made straight.
    let lower: [String]
    /// `gaps[i]` is the text before word `i`; `gaps[words.count]` is the text after the last word.
    let gaps: [Substring]
    let wordsBefore: [String]
    let continuesSentence: Bool

    init(text: String, words: [Range<String.Index>], wordsBefore: [String], continuesSentence: Bool) {
        self.text = text
        self.words = words
        lower = words.map { text[$0].lowercased().replacingOccurrences(of: "’", with: "'") }
        var gaps: [Substring] = []
        var cursor = text.startIndex
        for word in words {
            gaps.append(text[cursor..<word.lowerBound])
            cursor = word.upperBound
        }
        gaps.append(text[cursor...])
        self.gaps = gaps
        self.wordsBefore = wordsBefore.map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
        self.continuesSentence = continuesSentence
    }

    // MARK: Reading the words around a "like"

    /// An ellipsis is a pause, not the end of a sentence: "life is like ... er ... this painting".
    static func endsSentence(_ gap: Substring) -> Bool {
        let bare = gap.replacingOccurrences(of: "...", with: " ").replacingOccurrences(of: "…", with: " ")
        return bare.contains { ".!?\n\r".contains($0) }
    }
    /// A dash with no space beside it joins two words ("Sunday—like"); it does not set one off.
    static func hasComma(_ gap: Substring) -> Bool {
        gap.contains { ",;".contains($0) } || (gap.contains { "—–".contains($0) } && gap.contains(where: \.isWhitespace))
    }
    static func hasEllipsis(_ gap: Substring) -> Bool { gap.contains("...") || gap.contains("…") }

    /// Hesitations are invisible to the rules: in "I, um, like really spicy food" the word before
    /// "like" is "I". `TextStyle` removes them later.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "ah", "er", "erm"]

    /// The words before `index` in its sentence, nearest first, hesitations skipped. When the
    /// dictation continues a sentence, the words before the cursor follow.
    func previousWords(_ index: Int, limit: Int = 3) -> [String] {
        var out: [String] = []
        var cursor = index
        while cursor > 0, out.count < limit {
            if Self.endsSentence(gaps[cursor]) { return out }
            cursor -= 1
            if !Self.hesitations.contains(lower[cursor]) { out.append(lower[cursor]) }
        }
        if cursor == 0, continuesSentence { out += wordsBefore.reversed().prefix(limit - out.count) }
        return out
    }

    /// Nothing but hesitations before it in its sentence, and the dictation does not continue one.
    func startsSentence(_ index: Int) -> Bool {
        var cursor = index
        while cursor > 0 {
            if Self.endsSentence(gaps[cursor]) { return true }
            cursor -= 1
            if !Self.hesitations.contains(lower[cursor]) { return false }
        }
        return !continuesSentence || wordsBefore.isEmpty
    }

    /// The words after `index` in its sentence, each with whether a comma comes right before it.
    func nextWords(_ index: Int, limit: Int = 3) -> [(word: String, afterComma: Bool)] {
        var out: [(String, Bool)] = []
        var cursor = index + 1
        while cursor < words.count, out.count < limit {
            if Self.endsSentence(gaps[cursor]) { break }
            if !Self.hesitations.contains(lower[cursor]) { out.append((lower[cursor], Self.hasComma(gaps[cursor]))) }
            cursor += 1
        }
        return out
    }

    func endsSentence(after index: Int) -> Bool { index + 1 >= words.count || Self.endsSentence(gaps[index + 1]) }

    // MARK: The rules

    /// Words that join a clause or open one, after which "like" is talk and not a verb.
    static let connectors: Set<String> = ["and", "but", "so", "or", "because", "cause", "cuz", "then", "yeah",
        "yep", "okay", "ok", "well", "plus", "oh", "dude", "bro", "anyway", "anyways"]

    /// "is" and "was" in every spelling, plus "got" ("it got like really cold"). "Let's" is not one.
    private static let copulas: Set<String> = ["is", "was", "are", "were", "am", "be", "been", "being", "get", "gets", "got",
        "getting", "isn't", "wasn't", "aren't", "weren't"]
    static func isCopula(_ word: String) -> Bool {
        if copulas.contains(word) { return true }
        guard word != "let's" else { return false }
        return word.hasSuffix("'s") || word.hasSuffix("'re") || word.hasSuffix("'m")
    }

    /// Words that sit between "is" and a filler without changing it: "I'm just like so tired".
    private static let copulaAdverbs: Set<String> = ["just", "also", "still", "all", "kinda", "literally", "always",
        "probably", "maybe", "really", "definitely", "basically", "actually", "totally", "honestly", "seriously"]

    /// Degree words that make a following "like" a filler. They must modify the next word, so a
    /// "really" that ends the sentence ("she was like really?") is a quote, not a filler.
    private static let degreeWords: Set<String> = ["so", "super", "very", "too", "pretty", "kinda", "way", "crazy",
        "insanely", "incredibly", "extremely", "completely", "absolutely", "hella", "quite", "fully", "such", "lowkey",
        "highkey", "kind", "sort"]
    /// Sentence adverbs: "Like seriously, stop" may put a comma after them.
    private static let sentenceAdverbs: Set<String> = ["really", "totally", "literally", "actually", "honestly",
        "seriously", "basically", "definitely", "legit", "genuinely", "truly", "obviously", "clearly"]

    /// Adjectives a filler "like" sits before: "it was like amazing". Only after a thing ("the food
    /// was like amazing"); after a person it may be a quote ("she was like, amazing!"). No word that
    /// is also a noun ("it was like fire", "like magic") is here.
    private static let adjectives: Set<String> = ["amazing", "awesome", "great", "good", "bad", "terrible", "horrible",
        "awful", "insane", "weird", "fine", "cool", "nice", "perfect", "beautiful", "gorgeous", "hilarious", "funny", "scary",
        "boring", "annoying", "ridiculous", "impossible", "huge", "tiny", "massive", "fast", "slow", "hard", "easy", "cheap",
        "expensive", "gross", "disgusting", "wild", "stupid", "dumb", "cute", "freezing", "broken", "late", "early", "empty",
        "packed", "crowded", "different", "important", "obvious", "incredible", "unbelievable", "sketchy", "random",
        "confusing", "complicated", "stressful", "exhausting", "frustrating", "worse", "better", "bigger", "smaller",
        "harder", "easier", "long", "short", "loud", "quiet", "dirty", "clean", "fun", "chill", "sad", "cringe"]

    /// After "like the": "it was like the best day". Not "first" or "last": "it was like the last
    /// time" compares.
    private static let superlatives: Set<String> = ["best", "worst", "most", "least", "biggest", "smallest", "hardest",
        "easiest", "craziest", "funniest", "weirdest", "longest", "shortest", "coolest", "nicest", "greatest", "dumbest",
        "scariest", "saddest", "happiest", "fastest", "slowest", "cheapest", "loudest", "grossest", "wildest"]

    private static let questionWords: Set<String> = ["what", "why", "how", "who", "where", "when"]
    private static let auxiliaries: Set<String> = ["do", "does", "did", "is", "are", "was", "were", "can", "could", "would",
        "should", "will", "am", "have", "has", "had", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "weren't",
        "can't", "won't", "wouldn't", "shouldn't", "couldn't"]

    /// Subjects that are never also objects, so "and like we went" is a filler before a clause.
    private static let subjects: Set<String> = ["i", "we", "they", "he", "she"]
    private static let quantifierSubjects: Set<String> = ["everyone", "everybody", "nobody", "someone", "somebody",
        "anyone", "anybody"]
    /// Subjects that are also objects ("and like it more"): a clause only when a verb follows.
    private static let ambiguousSubjects: Set<String> = ["it", "you", "this", "that", "there"]
    private static let sarcasmMarkers: Set<String> = ["would", "could", "gonna", "going", "will", "ever", "care", "cares",
        "cared", "matters", "matter", "know", "knows", "can", "should", "need", "needs", "want", "wanted"]
    private static let sayingVerbs: Set<String> = ["said", "say", "says", "saying", "mentioned", "mentioning", "told",
        "telling", "explained", "explaining", "suggested", "discussed", "talking"]
    private static let clauseVerbs: Set<String> = ["was", "is", "were", "are", "can", "could", "would", "will", "should",
        "just", "never", "always", "really", "has", "had", "have", "did", "do", "don't", "didn't", "doesn't", "isn't",
        "wasn't", "kinda", "got", "gets", "gotta", "need", "needs", "went", "goes", "feels", "felt", "looks", "looked",
        "seems", "seemed", "sounds", "makes", "made", "takes", "took"]
    /// "and like I said", "and like you know": "like" is the conjunction. Sarcasm ("Like I would
    /// ever") opens a sentence, where the clause rule does not run, so "or like we could" is a hedge.
    private static let conjunctionVerbs: Set<String> = ["said", "say", "says", "saying", "mentioned", "told", "tell",
        "explained", "thought", "expected", "expect", "promised", "asked", "wanted", "suggested", "discussed", "care",
        "cared", "ever", "know", "knew", "always", "usually"]

    /// Words after which "like" before an amount is a hedge: "took like five minutes", "for like an
    /// hour". An allowlist, because after a subject it is the verb: "I'd like two tickets".
    private static let amountLeads: Set<String> = ["for", "at", "about", "around", "in", "within", "after", "before", "than",
        "until", "till", "by", "with", "of", "from", "only", "maybe", "probably", "took", "take", "takes", "taking", "had",
        "have", "has", "having", "need", "needs", "ate", "eat", "eats", "cost", "costs", "pay", "paid", "spent", "spend",
        "spends", "wait", "made", "make", "makes", "ran", "run", "runs", "drove", "drive", "slept", "sleep", "bought", "buy",
        "sold", "sell", "saw", "see", "sent", "send", "wrote", "write", "went", "go", "goes", "lost", "lose", "won", "win",
        "owe", "owes", "weighs", "left", "drank", "drink", "live", "lives", "read", "there's"]
    /// Perception verbs: "it seemed like a year" compares, so their past tense is not an amount lead.
    private static let comparingVerbs: Set<String> = ["seemed", "looked", "sounded", "smelled", "tasted", "acted",
        "behaved", "appeared", "liked", "loved", "felt"]
    private static let numberWords: Set<String> = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "dozen", "half", "several"]
    /// "like a hundred", "like an hour", "like a lot": amounts that start with "a".
    private static let amountNouns: Set<String> = ["hundred", "thousand", "million", "billion", "couple", "few", "dozen",
        "half", "minute", "hour", "second", "day", "week", "month", "year", "mile", "lot", "bunch", "ton", "grand", "buck",
        "dollar", "foot", "inch", "block", "sec", "min"]

    /// Words that cannot end a phrase, so a comma right after one was only fencing the filler:
    /// "it was, like, amazing" becomes "it was amazing", but "late, like, really late" keeps its comma.
    private static let unfinishedWords: Set<String> = ["is", "was", "are", "were", "am", "be", "been", "do", "does", "did",
        "have", "has", "had", "will", "would", "can", "could", "should", "might", "must", "to", "of", "in", "on", "at",
        "for", "with", "from", "by", "about", "into", "than", "a", "an", "the", "my", "your", "his", "her", "our", "their",
        "and", "but", "or", "so", "because", "cause", "cuz", "if", "then", "since", "got", "get", "just", "really"]

    /// People, so "she was, like, are you serious?" keeps its quote. Other lowercase subjects ("the
    /// movie was, like, amazing") are things; a capitalized word is a name.
    private static let people: Set<String> = ["i", "he", "she", "they", "we", "you", "y'all", "everyone", "everybody",
        "someone", "somebody", "nobody", "mom", "mum", "dad", "brother", "sister", "friend", "friends", "boss", "teacher",
        "guy", "guys", "girl", "girls", "dude", "man", "people", "kid", "kids", "wife", "husband", "girlfriend",
        "boyfriend", "parents", "roommate"]
    private static let things: Set<String> = ["it", "that", "this", "there", "which", "what", "everything", "nothing",
        "something", "anything", "here"]

    /// The rule that makes the "like" at `index` a filler at this level, or nil when it stays.
    /// Named so measurements can say which rule removed what.
    func fillerRule(at index: Int, aggressive: Bool, removedBefore: Set<Int> = []) -> String? {
        let before = previousWords(index)
        let after = nextWords(index)
        let start = startsSentence(index)
        let end = endsSentence(after: index)
        let commaBefore = !start && Self.hasComma(gaps[index])
        let commaAfter = !end && Self.hasComma(gaps[index + 1])
        let previous = before.first
        // A dictation that is only "Like." may mean the verb. After other sentences ("I don't care.
        // Like.") the recognizer has split a trailing filler into a sentence of its own.
        if start && end { return words.count > 1 ? "lone sentence" : nil }
        // "Things I like, like pizza": the second one gives an example of the first.
        if let previous, ["like", "likes", "liked", "love", "loves", "enjoy"].contains(previous) { return nil }
        // "and, like, oh honey, by the way": a quote, with or without "was" before it.
        if let next = after.first?.word, Self.interjections.contains(next) { return nil }
        let opener = start || previous.map(Self.connectors.contains) == true || isDiscourseMarker(before)
        let copula = copulaSubject(before)
        // Before a verb, "like" is neither the verb nor a comparison: "we like made out", "which
        // like made me think", "you have to like pay", "I was just like idolizing these guys".
        if !commaBefore, let next = after.first, !next.afterComma,
           verbFollowsFiller(previous: previous, next: next.word, copula: copula) {
            return "before a verb"
        }

        // "Just push the button, like ..." trails off into showing how: "like this".
        if end, index + 1 < gaps.count, Self.hasEllipsis(gaps[index + 1]) { return nil }
        // "I don't know, like." and "so like?"
        if end {
            if commaBefore { return "end after a comma" }
            return opener && !start ? "end after and/so" : nil
        }
        // "several hundred dollars, like, tires for the car", "things, like, mitigating
        // circumstances": after a plural or a word such as "things", "like" before a noun gives an
        // example. So does "Like, Dick Tracy." answering a question.
        if commaBefore || (start && commaAfter), examplesFollow(previous: start ? nil : previous, index: index, after: after) {
            return nil
        }
        // "It was, like, so good", "I mean, like, it's fine". A person's quote stays:
        // "she was, like, are you serious?"
        if commaBefore && commaAfter {
            if let copula {
                return !isPerson(copula) || degreeFollows(after, commaAllowed: false) ? "commas, after is" : nil
            }
            return "commas"
        }
        // "Like, I don't even know", "and like, we left". After "was" it is a quote ("I was like,
        // no way") unless a thing is the subject and a degree word follows ("it's like, really hard").
        if commaAfter {
            if opener { return start ? "opens a sentence, comma" : "after and/so, comma" }
            // "he was like, six foot".
            if aggressive, copula != nil, amountFollows(after) { return "amount after is, comma" }
            if let copula, !isPerson(copula) {
                if degreeFollows(after, commaAllowed: false) { return "degree after is, comma" }
                if let next = after.first?.word, Self.adjectives.contains(next) ||
                    (next == "the" && after.count >= 2 && Self.superlatives.contains(after[1].word)) {
                    return "adjective after is, comma"
                }
            }
            return nil
        }
        // "I was like really tired", "it's like so annoying".
        if let copula {
            if degreeFollows(after, commaAllowed: false) { return "degree after is" }
            // "it was like amazing", "it was like the worst traffic ever". Not after a person:
            // "she's like the best friend I never had" compares.
            if !isPerson(copula), let next = after.first?.word {
                if Self.adjectives.contains(next) { return "adjective after is" }
                if next == "the", after.count >= 2, Self.superlatives.contains(after[1].word) { return "superlative after is" }
            }
        }
        // "late, like really late".
        if commaBefore, degreeFollows(after, commaAllowed: false) { return "degree after a comma" }
        if opener {
            // "Like honestly I don't care", "but like pretty good", "Like seriously, stop".
            if degreeFollows(after, commaAllowed: true) { return "degree after an opener" }
            // "so like what are we doing", "but like why would he".
            if questionFollows(after) { return "question after an opener" }
        }
        guard aggressive else {
            if let rule = betweenLooseWords(index, before: before, after: after, start: start) { return rule }
            // Light also takes the loose fillers that never carry an amount or a clause: "the like
            // stuff", "especially like I mean", "I'm like paranoid".
            guard let rule = looseRule(index, before: before, after: after, start: start, commaBefore: commaBefore,
                                       copula: copula, removedBefore: removedBefore),
                  Self.lightLooseRules.contains(rule), !amountFollows(after), !timeFollows(after) else { return nil }
            return rule
        }
        // "what's the weather like in winter", "see what his schedule is like on Wednesday": the
        // "what" in front is the object of this "like".
        if asksWhatItIsLike(index), asksAboutIt(after) { return nil }

        // "took like five minutes", "at like 6", "it's like a mile", "make it like 6". Any past tense
        // ("waited like 20 minutes", "called like a dozen times") leads only a count or a length of
        // time, and never "a couple of": "cracked like a couple of nuts" compares.
        let objectIt = previous == "it" && !(before.count > 1 && Self.auxiliaries.contains(before[1]))
        let existential = copula == "there" || previous == "there's"
        let comparable = copula != nil && !existential
        if let previous, Self.amountLeads.contains(previous) || objectIt || Self.connectors.contains(previous) || copula != nil,
           amountFollows(after, comparable: comparable) { return "amount" }
        if let previous, isPastTense(previous), numberFollows(after) || countFollows(after) { return "amount after a past tense" }
        // "it comes on like at nine o'clock", "I moved here like in late August": before a time,
        // "like" cannot compare. "Just like in the movies" and "like in the old days" stay.
        if timeFollows(after) { return "before a time" }
        // "there's like certain types", "there was like this guy": nobody says "there is similar to".
        if copula == "there" || previous == "there's", after.first != nil, !(after.first?.afterComma ?? false),
           !after.prefix(3).contains(where: { Self.sayingVerbs.contains($0.word) }) {
            return "after there's"
        }
        // "she's got like a small patch of lawn", "I use like Miracle Whip". Not after "eat",
        // "drink", "act" or "used", which compare ("eat like a pig", "used like a hammer").
        if let previous, Self.havingVerbs.contains(previous), let next = after.first?.word, !after[0].afterComma,
           Self.phraseStarts.contains(next) || ["a", "an", "just", "some", "no"].contains(next) || isName(index + 1) ||
            numberFollows(after) {
            return "after have or got"
        }
        // "and like we went home", "because like everyone was there". Not at the start of a
        // sentence: "Like I'm gonna do that" and "Like I care" are sarcasm. Not where "like" means
        // "as if" after an earlier comparison: "I felt mean and like I couldn't look at her",
        // "like they hadn't expected it and then like they had".
        if opener, clauseFollows(after), !comparesEarlier(index, removedBefore: removedBefore) {
            // "Like we have peach trees in the yard" opens a sentence with a filler; "Like I'd ever",
            // "Like it matters" and "Like I'm gonna do that" are sarcasm and stay.
            if !start { return "clause after and/so" }
            if !after.prefix(4).contains(where: { Self.sarcasmMarkers.contains($0.word) || $0.word.hasSuffix("'d") ||
                                                 $0.word.hasSuffix("'ll") }) {
                return "clause opening a sentence"
            }
        }
        // "since he like cancelled all this", "she like goes": after "he" or "she" the verb is
        // "likes", unless a question puts a verb first ("does she like it", "what's he like").
        // Not "someone like you", where the pronoun is an object and "like" compares. Aggressive
        // only: a recognizer that drops the "s" of "likes" would make this remove the verb.
        if let previous, previous == "he" || previous == "she",
           !(before.count > 1 && (Self.auxiliaries.contains(before[1]) || Self.modals.contains(before[1]) ||
                                  Self.isCopula(before[1]) || ["would", "let", "make", "makes", "made", "help"].contains(before[1]))),
           let next = after.first, !next.afterComma, !Self.conjunctionVerbs.contains(next.word) { return "after he or she" }
        // "Yeah, like if you're approaching them": a loose "like" before a new clause.
        if opener, !start, let next = after.first?.word, ["if", "when", "whenever", "because", "since", "once"].contains(next),
           after.count >= 2 { return "if or when after and/so" }
        // "instead of like President Nixon", "for like the whole day". Only these: after "in", "on",
        // "about" or "with" it compares ("streamed in like a benediction", "caught on like a house on
        // fire", "about like this") or gives examples ("with like Chinese cabbage"). Not "think of
        // like a puzzle" or "kind of like a dream" either.
        if let previous, ["of", "for", "from", "than"].contains(previous),
           !(before.count > 1 && ["think", "thought", "kind", "sort", "type", "more", "something", "nothing", "kinda"].contains(before[1])),
           let next = after.first?.word, Self.phraseStarts.contains(next) || isName(index + 1) { return "after of or for" }
        // Not "you know like the X": in recorded conversation that gives examples ("you know like
        // the conservation corps", "you know like the trim around the house") or compares ("you
        // know like what Geraldo used to be") as often as it hedges.
        if let previous, previous == "know", before.count > 1, before[1] == "you", let next = after.first?.word,
           Self.phraseStarts.contains(next) || next == "a" || next == "what" { return nil }
        return looseRule(index, before: before, after: after, start: start, commaBefore: commaBefore,
                         copula: copula, removedBefore: removedBefore)
    }

    private static let perceptionVerbs: Set<String> = ["feel", "feels", "felt", "feeling", "look", "looks", "looked",
        "looking", "seem", "seems", "seemed", "sound", "sounds", "sounded", "act", "acts", "acted", "acting", "smell",
        "smells", "smelled", "taste", "tastes", "tasted"]

    func asksWhatItIsLike(_ index: Int) -> Bool {
        var cursor = index
        while cursor > 0, !Self.endsSentence(gaps[cursor]) {
            cursor -= 1
            if ["what", "what's", "what're", "whatever"].contains(lower[cursor]) { return true }
        }
        return false
    }

    /// An earlier comparison in the same sentence: a perception verb, or a "like" that was kept.
    private func comparesEarlier(_ index: Int, removedBefore: Set<Int>) -> Bool {
        var cursor = index
        while cursor > 0, !Self.endsSentence(gaps[cursor]) {
            cursor -= 1
            if Self.perceptionVerbs.contains(lower[cursor]) { return true }
            if lower[cursor] == "like", !removedBefore.contains(cursor) { return true }
        }
        return false
    }

    private static let havingVerbs: Set<String> = ["have", "has", "had", "having", "got", "gotten", "get", "gets",
        "getting", "need", "needs", "needed", "want", "wants", "wanted", "buy", "buys", "bought", "use", "uses", "using"]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday"]
    private static let timeNouns: Set<String> = ["noon", "midnight", "night", "morning", "evening", "afternoon", "weekend",
        "summer", "winter", "spring", "fall", "christmas", "thanksgiving", "today", "tonight", "tomorrow", "yesterday"]

    /// "like at nine o'clock", "like in late August", "like during the Christmas season".
    private func timeFollows(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard after.count >= 2, ["at", "in", "on", "around", "during", "by", "until", "till", "before", "after", "from"]
            .contains(after[0].word), !after[1].afterComma else { return false }
        var words = after.dropFirst().map(\.word)
        if ["the", "late", "early", "mid", "last", "next", "this"].contains(words.first ?? "") { words = Array(words.dropFirst()) }
        if ["late", "early", "mid", "middle", "end", "beginning"].contains(words.first ?? ""), words.count > 1,
           ["of", "the"].contains(words[1]) || Self.months.contains(words[1]) || Self.timeNouns.contains(words[1]) { return true }
        guard let word = words.first else { return false }
        if word.first?.isNumber == true || Self.numberWords.contains(word) { return true }
        if Self.months.contains(word) || Self.timeNouns.contains(word) { return true }
        return ["week", "year", "month", "day", "minute", "hour", "fifties", "sixties", "seventies", "eighties", "nineties",
                "twenties", "thirties", "forties", "season", "semester"].contains(word)
    }

    /// Not "a" ("mistaken for like a ghost") or "this" and "that", which always compare.
    private static let phraseStarts: Set<String> = ["the", "my", "your", "his", "their", "our", "some", "any", "no",
        "every", "all", "half"]

    /// A capitalized word in the middle of a sentence: a name.
    private func isName(_ index: Int) -> Bool {
        guard index < words.count, !startsSentence(index) else { return false }
        return text[words[index]].first?.isUppercase == true && lower[index] != "i"
    }

    /// Words that name a list ("things like", "stuff like") and plurals other than these.
    private static let listNouns: Set<String> = ["things", "stuff", "items", "ones", "places", "people", "kinds", "sorts",
        "types", "something", "anything", "everything", "activities", "foods", "sports", "shows", "games", "movies"]
    private static let notPlurals: Set<String> = ["was", "is", "has", "does", "this", "his", "hers", "its", "yes", "always",
        "perhaps", "sometimes", "guess", "us", "less", "unless", "across", "plus", "thus", "whereas", "besides", "towards",
        "afterwards", "nowadays", "anyways", "seriously", "obviously", "basically", "literally", "actually", "probably",
        "definitely", "totally", "really", "anyways", "kinda", "gross", "boss", "bus", "class", "glass", "grass", "dress",
        "mess", "kiss", "miss", "pass", "process", "access", "business", "address", "chess", "stress", "lots"]

    /// "Like" starts an example: a noun phrase after a list noun or a plural, or a name opening
    /// the sentence. Not when a degree word, a question or a clause follows.
    private func examplesFollow(previous: String?, index: Int, after: [(word: String, afterComma: Bool)]) -> Bool {
        guard let next = after.first?.word else { return false }
        if previous == nil { return isName(index + 1) }
        guard let previous else { return false }
        let listLike = Self.listNouns.contains(previous) ||
            (previous.count >= 4 && previous.hasSuffix("s") && !previous.hasSuffix("ss") && !previous.contains("'") &&
             !Self.notPlurals.contains(previous) && !Self.copulas.contains(previous))
        guard listLike else { return false }
        if Self.degreeWords.contains(next) || Self.sentenceAdverbs.contains(next) || Self.questionWords.contains(next) ||
            Self.subjects.contains(next) || Self.ambiguousSubjects.contains(next) || Self.interjections.contains(next) ||
            Self.hesitations.contains(next) || ["well", "if", "when", "because", "so", "and", "but", "or", "maybe"].contains(next) {
            return false
        }
        return true
    }

    private static let interjections: Set<String> = ["oh", "wow", "whoa", "ugh", "hey", "yeah", "yes", "no", "nah",
        "dude", "damn", "gosh", "omg", "oops", "yay", "hmm", "please"]

    /// Past tenses that are never adjectives or nouns ("I like baked goods", "I like thought
    /// experiments" are excluded by leaving those words out).
    private static let pastVerbs: Set<String> = ["made", "went", "said", "told", "got", "came", "took", "gave", "saw",
        "knew", "found", "ran", "sat", "stood", "threw", "brought", "bought", "caught", "taught", "kept", "held", "wrote",
        "drove", "ate", "fell", "chose", "woke", "forgot", "began", "swam", "drank", "hung", "sent", "meant", "met", "slept",
        "sold", "wore", "tore", "hid", "shook", "rode", "flew", "grew", "drew", "blew", "quit", "freaked", "screamed",
        "yelled", "texted", "grabbed", "panicked", "started", "stopped", "tried", "decided", "realized", "noticed"]
    /// Plain verbs that are never nouns after "like" ("I'd like help" is the verb, so "help" is out).
    private static let plainVerbs: Set<String> = ["go", "get", "make", "take", "pay", "say", "tell", "imagine", "show",
        "give", "put", "try", "ask", "start", "stop", "think", "come", "turn", "pull", "push", "throw", "grab", "pick",
        "drop", "freak", "flip", "scream", "yell", "laugh", "jump", "sit", "stand", "leave", "find", "keep", "let", "write",
        "wait", "check", "text", "figure", "realize", "decide", "explain", "pretend", "lock", "remember", "forget",
        "understand", "learn", "finish", "choose", "become", "bring", "send", "spend", "sell", "teach", "see", "eat", "buy",
        "hang", "wear", "carry", "literally", "totally", "actually"]
    private static let subjectsAndRelatives: Set<String> = ["i", "we", "they", "he", "she", "you", "which", "who"]
    /// Not "would": "I'd like make a reservation" is the verb with "to" lost, by the speaker or the
    /// recognizer, and without "like" it says something else.
    private static let modals: Set<String> = ["could", "should", "will", "can", "might", "must", "gonna", "wanna",
        "gotta", "to"]
    /// Words ending in "ing" that are not verbs.
    private static let ingNouns: Set<String> = ["thing", "things", "nothing", "something", "anything", "everything",
        "morning", "evening", "string", "spring", "during", "ceiling", "wedding", "building", "pudding", "king", "ring",
        "wing", "sibling", "darling"]

    private func verbFollowsFiller(previous: String?, next: String, copula: String?) -> Bool {
        guard let previous else { return false }
        // "we like made out": a subject and a past tense, so "like" is not the verb.
        if Self.subjectsAndRelatives.contains(previous), Self.pastVerbs.contains(next) { return true }
        // "you have to like pay", "you can like go": the verb "like" needs "to" before a verb.
        let modal = Self.modals.contains(previous) || previous.hasSuffix("'ll")
        if modal, Self.plainVerbs.contains(next), !["literally", "totally", "actually"].contains(next) { return true }
        // "I was just like idolizing these guys": a person in the middle of doing something. After
        // a thing it compares: "it's like riding a bike".
        if let copula, isPerson(copula), next.count >= 5, next.hasSuffix("ing"), !Self.ingNouns.contains(next) {
            return true
        }
        return false
    }

    private func isDiscourseMarker(_ before: [String]) -> Bool {
        before.count >= 2 && ((before[1] == "you" && before[0] == "know") || (before[1] == "i" && before[0] == "mean"))
    }

    /// The subject of the "is" or "was" right before "like" ("I" in "I was", "it" in "it's"), or
    /// nil when no such verb is there.
    private func copulaSubject(_ before: [String]) -> String? {
        var words = before[...]
        if let first = words.first, Self.copulaAdverbs.contains(first), words.count > 1 { words = words.dropFirst() }
        guard let verb = words.first, Self.isCopula(verb) else { return nil }
        if let apostrophe = verb.firstIndex(of: "'"), !Self.copulas.contains(verb) {
            return String(verb[..<apostrophe])
        }
        return words.dropFirst().first ?? ""
    }

    private func isPerson(_ subject: String) -> Bool {
        if let apostrophe = subject.firstIndex(of: "'"), Self.people.contains(String(subject[..<apostrophe])) { return true }
        if Self.people.contains(subject) { return true }
        if Self.things.contains(subject) || subject.isEmpty { return false }
        // Lowercase here; a name was capitalized in the text.
        return words.indices.contains { lower[$0] == subject && text[words[$0]].first?.isUppercase == true }
    }

    private func degreeFollows(_ after: [(word: String, afterComma: Bool)], commaAllowed: Bool) -> Bool {
        guard after.count >= 2, let word = after.first?.word else { return false }
        let next = after[1]
        if Self.sentenceAdverbs.contains(word) {
            return !next.afterComma || commaAllowed || Self.sentenceAdverbs.contains(next.word) || Self.degreeWords.contains(next.word)
        }
        guard Self.degreeWords.contains(word), !next.afterComma else { return false }
        switch word {
        // "I was like so what?" is a quote; "so I left" joins a clause.
        case "so": return !Self.questionWords.contains(next.word) && !Self.subjects.contains(next.word) &&
            !Self.ambiguousSubjects.contains(next.word)
        case "kind", "sort": return next.word == "of" && after.count >= 3
        // "it was like such a mess"; "nice people and like such things" is the verb.
        case "such": return next.word == "a" || next.word == "an"
        default: return true
        }
    }

    private func questionFollows(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard after.count >= 2, let word = after.first?.word else { return false }
        if let apostrophe = word.firstIndex(of: "'") { return Self.questionWords.contains(String(word[..<apostrophe])) }
        guard Self.questionWords.contains(word) else { return false }
        // "so like how long is this", "but like how much does it cost", "and like how come".
        if word == "how", ["long", "many", "much", "come", "often", "far", "big", "old", "soon"].contains(after[1].word) {
            return true
        }
        return word == "why" || Self.auxiliaries.contains(after[1].word)
    }

    private func isPastTense(_ word: String) -> Bool {
        word.count >= 5 && word.hasSuffix("ed") && !Self.comparingVerbs.contains(word)
    }

    /// A number, written or spoken: "like 20", "like five". "like one or two", but "like one of
    /// those days" compares.
    private func numberFollows(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard let word = after.first?.word else { return false }
        if word.first?.isNumber == true || Self.numberWords.contains(word) { return true }
        // "ninety-three", "twenty-five".
        if let head = word.split(separator: "-").first, word.contains("-"), Self.numberWords.contains(String(head)) { return true }
        if word == "one" { return after.count >= 2 && !["of", "who", "that", "another"].contains(after[1].word) }
        return false
    }

    /// "a dozen times", "an hour": a count or a length of time, not followed by "of".
    private func countFollows(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard after.count >= 2, ["a", "an"].contains(after[0].word),
              ["dozen", "hundred", "thousand", "million", "few", "couple", "minute", "hour", "second", "day", "week",
               "month", "year", "mile"].contains(after[1].word) else { return false }
        return after.count < 3 || after[2].word != "of"
    }

    /// A number, or an amount that starts with "a": "like a hundred", "like an hour". `comparable`
    /// is false after "he's" or "I'm", where "like a lot of quarterbacks" and "like a bunch of
    /// kids" compare; "there were like a bunch of people" and "I have like a lot of" are amounts.
    private func amountFollows(_ after: [(word: String, afterComma: Bool)], comparable: Bool = false) -> Bool {
        if numberFollows(after) { return true }
        guard let word = after.first?.word, word == "a" || word == "an", after.count >= 2,
              Self.amountNouns.contains(after[1].word) else { return false }
        if comparable, ["lot", "bunch", "ton", "couple", "few"].contains(after[1].word), after.count >= 3,
           after[2].word == "of" { return false }
        return true
    }

    private func clauseFollows(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard after.count >= 2, let word = after.first?.word else { return false }
        let next = after[1]
        guard !next.afterComma, !Self.conjunctionVerbs.contains(next.word) else { return false }
        // "like I was saying", "like we we said earlier": "like" is "as".
        if after.dropFirst().prefix(3).contains(where: { Self.sayingVerbs.contains($0.word) }) { return false }
        // "like we do here", "like she used to be": a verb standing in for one said before, so
        // "like" compares.
        if ["do", "does", "did"].contains(next.word) { return false }
        if after.count >= 3, next.word == "used", after[2].word == "to" { return false }
        // "like you would when you're up north": the same, with a modal.
        if ["would", "do", "does", "did", "could", "can", "should", "will"].contains(next.word),
           after.count == 2 || ["when", "if", "in", "at", "with", "for", "before", "after", "every", "all", "too"].contains(after[2].word) {
            return false
        }
        if Self.subjects.contains(word) { return true }
        if Self.quantifierSubjects.contains(word) { return next.word != "else" }
        if let apostrophe = word.firstIndex(of: "'") {
            let subject = String(word[..<apostrophe])
            return Self.subjects.contains(subject) || Self.ambiguousSubjects.contains(subject)
        }
        if word == "there" { return ["was", "is", "were", "are"].contains(next.word) }
        if Self.ambiguousSubjects.contains(word) { return Self.clauseVerbs.contains(next.word) }
        return false
    }

    // MARK: Removing

    /// The text without the words at `removed`, each run of them replaced by one gap.
    func removing(_ removed: Set<Int>) -> String {
        var out = String(gaps[0])
        var index = 0
        var capitalizeNext = false
        while index < words.count {
            guard removed.contains(index) else {
                var word = String(text[words[index]])
                // "Like, um you know": the capital goes past the "um", which TextStyle removes next.
                if capitalizeNext, Self.hesitations.contains(lower[index]) {
                    out += word
                    out += gaps[index + 1]
                    index += 1
                    continue
                }
                if capitalizeNext, let first = word.first, first.isLowercase {
                    word = first.uppercased() + word.dropFirst()
                }
                capitalizeNext = false
                out += word
                out += gaps[index + 1]
                index += 1
                continue
            }
            var last = index
            while removed.contains(last + 1) { last += 1 }
            // The gap already written before this run is `gaps[index]`; replace it.
            out.removeLast(gaps[index].count)
            out += replacementGap(first: index, last: last)
            if startsSentence(index), text[words[index]].first?.isUppercase == true { capitalizeNext = true }
            index = last + 1
        }
        return out
    }

    private func replacementGap(first: Int, last: Int) -> String {
        let before = gaps[first]
        let after = gaps[last + 1]
        let isLast = last + 1 >= words.count
        // Quotes and brackets around the removed words stay.
        let kept = after.filter { !",;—–".contains($0) && !$0.isWhitespace && !".!?…".contains($0) }
        if startsSentence(first) {
            return isLast ? String(before.reversed().drop(while: \.isWhitespace).reversed()) : String(before) + kept
        }
        if endsSentence(after: last) {
            // "I don't know, like." keeps its period, not its comma.
            let ending = after.drop(while: { ",;—–".contains($0) || $0.isWhitespace })
            return isLast && ending.isEmpty ? "" : String(ending)
        }
        if Self.hasComma(before), let previous = previousWords(first, limit: 1).first,
           Self.unfinishedWords.contains(previous) || Self.isCopula(previous) {
            return " " + kept
        }
        return String(before) + kept
    }
}

// MARK: Every other "like": kept only where it carries meaning

/// The rules above remove a "like" only when its neighbors prove it is a filler, which on real
/// dictation left about four in five fillers in (`docs/california-mode-recall.md`). Aggressive now
/// turns that around: after those rules, a "like" goes unless something protects it. Protected:
/// the verb ("I really like it", "you'd like", "doesn't like to"), a comparison ("feels like",
/// "something like that", "kind of like", "just like in the movies", "people like us"), a noun
/// ("the like button"), a quote ("I was like, no way", "she was like really?"), a word talked about
/// ("I keep saying like", "like is a big one"), "as" or "as if" before a clause ("like it was
/// before"), sarcasm ("Like I care"), and a simile after a word Zone cannot place ("fold like a
/// chair"). Light gains one safe case: "like" between two small words ("so like for instance").
extension Passage {
    /// The loose rules Light uses too: none of them removes a hedge before an amount.
    static let lightLooseRules: Set<String> = ["after a cut-off word", "before I mean", "after a determiner",
        "after a small word", "clause after a small word", "before a verb after can or do", "before a verb after a subject",
        "description after is", "before an action"]
    /// Words that can sit between a subject and the verb "like": "I really like", "they all like".
    static let looseAdverbs: Set<String> = ["really", "actually", "also", "just", "still", "totally", "genuinely",
        "definitely", "honestly", "kinda", "particularly", "always", "never", "usually", "both", "all", "even",
        "sometimes", "only", "truly", "seriously", "literally", "probably", "mostly", "generally", "obviously",
        "personally", "secretly", "lowkey", "highkey", "def", "already", "kind", "sort", "lot", "a"]
    /// More words that sit between a subject and its verb: "I do not particularly like", "I especially like".
    static let walkAdverbs: Set<String> = ["not", "especially", "particularly", "specifically", "mainly", "often",
        "rarely", "seldom", "hardly", "barely", "certainly", "surely", "kind", "sort", "kinda", "sorta", "so", "too",
        "much", "very", "quite", "rather", "somewhat", "slightly", "absolutely", "completely", "simply", "now", "then",
        "still", "already", "ever", "myself", "yourself", "himself", "herself", "ourselves", "themselves", "usually",
        "normally", "typically", "generally", "personally", "certainly", "do", "does", "did"]
    /// Words that are a subject in front of the verb "like".
    static let looseSubjects: Set<String> = ["i", "we", "they", "he", "she", "who", "y'all", "people", "everyone",
        "everybody", "nobody", "somebody", "someone", "anyone", "anybody", "folks", "guys", "kids", "friends",
        "parents", "users", "customers", "u", "ya"]
    /// After these the verb "like" takes its object: "don't like it", "can't like him".
    static let verbAuxiliaries: Set<String> = ["do", "does", "did", "don't", "doesn't", "didn't", "dont", "doesnt",
        "didnt", "won't", "wouldn't", "will", "can", "can't", "cannot", "could", "couldn't", "should", "shouldn't",
        "might", "may", "must", "gonna", "wanna", "gotta", "shall"]
    /// "want to like", "learn to like": the infinitive. Otherwise "to" is a preposition ("back to like where it was").
    static let infinitiveLeads: Set<String> = ["want", "wants", "wanted", "need", "needs", "needed", "have", "has", "had",
        "going", "used", "try", "trying", "tried", "start", "started", "begin", "began", "learn", "learned", "grow",
        "grew", "seem", "seems", "seemed", "able", "supposed", "love", "loved", "hate", "hated", "pretend", "expect",
        "hope", "hoping", "like", "liked", "would", "'d", "got", "came", "come", "happen", "happened", "tend", "tends",
        "grown", "grow", "growing", "getting", "get", "learning", "seeming", "pretending", "managed", "manage", "refuse",
        "refused", "wish", "wished", "ought", "deserve", "deserves", "chose", "choose", "decided", "decide", "used",
        "reason", "reasons", "chance", "hard", "easy", "nice", "fun", "glad", "happy", "able", "ready", "way"]
    /// Base verbs, so "you can like prime the mic" is not the verb "like". Only words that are rarely
    /// the thing someone likes: "doesn't like change" keeps its verb, so "change" is not here.
    static let baseVerbs: Set<String> = ["go", "get", "make", "take", "pay", "say", "tell", "imagine", "give", "put", "try",
        "ask", "start", "stop", "think", "come", "turn", "pull", "push", "throw", "grab", "pick", "freak", "flip", "scream",
        "yell", "laugh", "jump", "sit", "stand", "leave", "find", "keep", "let", "write", "figure", "realize", "decide",
        "explain", "pretend", "lock", "remember", "forget", "understand", "learn", "finish", "choose", "become", "bring",
        "send", "spend", "sell", "teach", "see", "eat", "buy", "hang", "wear", "carry", "prime", "convert", "swap", "mine",
        "breathe", "believe", "lay", "sparkle", "teleport", "title", "click", "scroll", "delete", "paste", "upload",
        "download", "merge", "fix", "install", "update", "remove", "record", "transcribe", "assign", "integrate",
        "coordinate", "iterate", "rebuild", "reset", "restart", "reload", "refresh", "rename", "adjust", "tweak",
        "organize", "schedule", "cancel", "confirm", "approve", "submit", "register", "enable", "disable", "toggle",
        "launch", "deploy", "ship", "publish", "upgrade", "migrate", "wire", "hook", "plug", "connect", "sync", "pair",
        "walk", "hop", "plan", "drop", "steal", "borrow", "wonder", "consider", "mention", "describe", "notice", "hear", "listen", "type",
        "swipe", "tap", "kick", "catch", "lift", "open", "close", "fill", "clean", "wash", "cook", "drive", "ride", "fly",
        "hit", "kill", "hug", "kiss", "smack", "slap", "punch", "shove", "drag", "tape", "glue", "stick", "attach",
        "squeeze", "stretch", "bend", "twist", "shake", "rub", "scratch", "lean", "lie", "tuck", "fold", "wrap", "unwrap",
        "cut", "chop", "break", "crash", "reach", "touch", "feel", "look", "sound", "seem", "act"]
    /// Words that start what the verb "like" takes: "don't like the", "can't like them", "like to".
    static let objectStarts: Set<String> = ["the", "a", "an", "my", "your", "his", "her", "our", "their", "its", "this",
        "that", "these", "those", "it", "them", "him", "me", "us", "you", "to", "how", "what", "when", "where", "who",
        "whoever", "whatever", "whichever", "being", "having", "some", "any", "every", "each", "all", "most", "both",
        "either", "neither", "no", "anything", "something", "everything", "nothing", "anyone", "someone", "everyone",
        "nobody", "people", "one", "ones", "either", "much", "many", "more", "less", "him", "her", "y'all", "u"]
    /// Comparisons: "something like that", "much like", "almost like", "kinda like".
    static let comparisonLeads: Set<String> = ["exactly", "almost", "less", "much", "nothing", "something", "anything",
        "everything", "someone", "somebody", "anyone", "anybody", "nobody", "lot", "similar", "same", "quite",
        "unlike", "kinda", "sorta", "nearly", "alike", "precisely", "kind", "sort", "type", "look", "looks", "looked",
        "looking", "feel", "feels", "felt", "feeling", "seem", "seems", "seemed", "seeming", "sound", "sounds",
        "sounded", "sounding", "smell", "smells", "smelled", "smelling", "taste", "tastes", "tasted", "tasting", "act",
        "acts", "acted", "acting", "behave", "behaves", "behaved", "behaving", "appear", "appears", "appeared",
        "dress", "dressed", "dresses", "treat", "treated", "treats", "become", "becomes", "became", "becoming"]
    /// "said like in this text", "I keep saying like": the word itself, talked about.
    static let mentionLeads: Set<String> = ["say", "says", "said", "saying", "word", "words", "type", "typed", "typing",
        "spell", "spelled", "write", "wrote", "writing", "use", "using", "used", "hear", "heard", "the word"]
    static let mentionFollowers: Set<String> = ["but", "and", "or", "in", "too", "so", "all", "every", "constantly",
        "again", "much", "at", "as", "when", "because", "instead", "anymore", "there", "here", "on", "a lot", "lots",
        "enough", "less", "more", "often", "twice", "once"]
    /// After these "like" starts a quote: "I was like, okay", "just be like hey".
    static let quoteOpeners: Set<String> = ["okay", "ok", "hey", "oh", "yo", "blah", "damn", "wow", "whoa", "yeah", "yep",
        "nope", "no", "yes", "ugh", "bruh", "ha", "haha", "lol", "dude", "bro", "omg", "oops", "yay", "hmm", "please",
        "word", "bet", "duh", "nah", "sure", "wait", "ew", "eww", "aw", "aww", "hello", "hi", "bye", "thanks", "sorry",
        "what", "huh"]
    /// Determiners: "the like button" is a noun; "the like cool light" is a filler.
    static let determiners: Set<String> = ["a", "an", "the", "my", "your", "his", "our", "their", "its", "this", "these",
        "those", "every", "each"]
    static let likeNouns: Set<String> = ["button", "buttons", "count", "counts", "ratio", "and", "or", "icon", "icons"]
    /// Small words in front of a filler: connectors, adverbs and question words.
    static let fillerAdverbs: Set<String> = ["maybe", "also", "even", "especially", "probably", "actually", "basically",
        "literally", "honestly", "somehow", "realistically", "definitely", "totally", "seriously", "obviously",
        "apparently", "clearly", "generally", "usually", "sometimes", "though", "tho", "um", "uh", "as",
        "except", "including", "especially", "particularly", "specifically", "mainly", "mostly", "hopefully",
        "ideally", "potentially", "possibly", "currently", "originally", "initially", "finally", "instead",
        "otherwise", "meanwhile", "currently", "anymore", "only", "simply", "barely"]
    static let whWords: Set<String> = ["how", "why", "when", "where", "which", "who", "whatever", "whenever", "wherever",
        "whoever", "whether"]
    static let prepositions: Set<String> = ["of", "for", "from", "at", "to", "about", "by", "into", "with", "between",
        "through", "during", "within", "without", "above", "below", "under", "over", "around", "across", "toward",
        "towards", "until", "till", "via", "per", "than", "besides", "regarding", "near", "beside", "behind", "inside",
        "outside", "beyond", "against", "among", "throughout", "onto", "upon", "in", "on", "off", "up", "down", "after",
        "before"]
    /// Prepositions after which "like a" is usually a simile: "streamed in like a benediction".
    static let simileProps: Set<String> = ["in", "on", "onto", "upon", "with", "into", "through", "about", "above",
        "below", "under", "over", "around", "across", "toward", "towards", "than", "off", "up", "down", "after",
        "before", "behind", "inside", "outside", "beyond", "against", "among", "throughout", "near"]
    /// Verbs whose object follows: "make like a shortcut", "it says like compatibility". Not "eat",
    /// "drink", "run" or "act", which compare ("eat like a pig").
    static let objectVerbs: Set<String> = ["do", "does", "did", "doing", "done", "make", "makes", "made", "making",
        "get", "gets", "got", "getting", "give", "gives", "gave", "giving", "show", "shows", "showed", "showing",
        "create", "creates", "created", "creating", "spent", "spend", "spends", "spending", "buy", "buys", "bought",
        "add", "adds", "added", "adding", "send", "sends", "sent", "sending", "need", "needs", "needed", "want", "wants",
        "wanted", "find", "finds", "found", "build", "builds", "built", "building", "take", "takes", "took", "taking",
        "bring", "brings", "brought", "hire", "hired", "put", "puts", "say", "says", "said",
        "saying", "ask", "asked", "offer", "offered", "pay", "paid", "owe", "see", "saw", "seen", "read", "write", "wrote",
        "keep", "kept", "lose", "lost", "sell", "sold", "order", "ordered", "hear", "heard", "include", "includes",
        "included", "call", "called", "check", "checked", "start", "started", "open", "opened", "plan", "planned",
        "enable", "enabled", "install", "installed", "move", "moved", "remove", "removed", "consider", "considered",
        "reiterate", "explain", "explained", "attuned", "between", "has", "have", "had", "having",
        "mentioned", "suggest", "suggested", "recommend", "dilute",
        "shows", "gives", "creates", "is", "are", "was", "were"]
    /// Adjectives and other words that never follow a comparing "like" without a noun.
    static let bareAdjectives: Set<String> = ["whack", "weird", "paranoid", "efficient", "casual", "whatever", "dead",
        "done", "obsessed", "over", "okay", "ok", "real", "true", "wrong", "right", "sure", "ready", "tired", "hungry",
        "broke", "busy", "free", "green", "red", "blue", "yellow", "purple", "orange", "pink", "black", "white", "gray",
        "grey", "brown", "fine", "elegant", "pleasant", "beautiful", "visible", "invisible", "usable", "useful",
        "useless", "possible", "impossible", "obvious", "clear", "unclear", "full", "empty", "not", "upstairs",
        "downstairs", "together", "apart", "soon", "later", "earlier", "tonight", "today", "tomorrow", "yesterday",
        "anywhere", "everywhere", "somewhere", "nowhere", "only", "very", "quite", "rather", "less", "more",
        "different", "same", "similar", "normal", "regular", "basic", "simple", "nice", "mean", "rude", "sweet", "smart",
        "dumb", "stupid", "slow", "fast", "quick", "big", "small", "little", "tiny", "huge", "giant", "old", "new",
        "young", "high", "low", "light", "dark", "bright", "loud", "quiet", "hot", "cold", "warm", "cool", "wet", "dry",
        "pretty", "ugly", "happy", "sad", "mad", "angry", "upset", "scared", "nervous", "excited", "bored", "stressed",
        "sick", "hurt", "safe", "sorry", "lucky", "cheap", "super", "so", "way", "too", "kinda", "sorta", "lowkey",
        "highkey", "legit", "deadass", "fr", "literally", "basically", "honestly", "actually", "totally", "really",
        "just", "also", "even", "still", "maybe", "probably", "always", "never", "sometimes", "constantly", "again",
        "already", "almost", "pretty", "mostly", "mainly", "especially", "definitely", "seriously", "obviously",
        "visually", "technically", "emotionally", "physically", "mentally", "completely", "absolutely", "entirely",
        "fully", "partly", "slightly", "barely", "hardly", "immediately", "instantly", "suddenly", "finally"]
    /// Words ending in "ly" that are nouns: "like a family", "like July".
    static let lyNouns: Set<String> = ["family", "july", "italy", "jelly", "belly", "reply", "supply", "fly", "ally",
        "bully", "lily", "holly", "molly", "sally", "emily", "kelly", "rally", "folly", "assembly", "anomaly", "only"]
    static let unitWords: Set<String> = ["second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week",
        "weeks", "month", "months", "year", "years", "mile", "miles", "foot", "feet", "inch", "inches", "meter", "meters",
        "pound", "pounds", "dollar", "dollars", "cent", "cents", "buck", "bucks", "k", "times", "people", "percent", "gigs",
        "megabytes", "gigabytes", "pixels", "tabs", "messages", "texts", "calls", "emails", "items", "things", "pages",
        "words", "steps", "tries", "sec", "secs", "min", "mins", "hrs", "o'clock", "am", "pm", "degrees", "grand"]
    /// Words in "ing" that describe how something is: "it's like embarrassing".
    static let describingParticiples: Set<String> = ["embarrassing", "annoying", "amazing", "boring", "confusing",
        "exhausting", "frustrating", "terrifying", "depressing", "disgusting", "exciting", "interesting", "overwhelming",
        "relaxing", "satisfying", "shocking", "surprising", "tiring", "disappointing", "entertaining", "fascinating",
        "horrifying", "humiliating", "infuriating", "insulting", "intimidating", "irritating", "refreshing", "rewarding",
        "stunning", "thrilling", "upsetting", "worrying", "alarming", "appalling", "astonishing", "charming", "comforting",
        "compelling", "concerning", "convincing", "demanding", "devastating", "distracting", "disturbing", "encouraging",
        "engaging", "heartbreaking", "inspiring", "misleading", "promising", "pleasing", "puzzling", "revealing",
        "startling", "striking", "tempting", "touching", "troubling", "unsettling", "appealing", "freezing", "boiling",
        "stressing", "lagging", "glitching", "jarring", "grating", "draining",
        "nauseating", "sickening", "maddening", "deafening", "blinding", "mind-blowing", "breathtaking", "underwhelming",
        "uninspiring", "unappealing", "uninteresting", "unconvincing", "unsatisfying", "disorienting", "cringing"]
    /// Nouns ending in "y", which "it's like" compares to: "it's like candy", "it's like therapy".
    static let yNouns: Set<String> = ["candy", "comedy", "tragedy", "therapy", "poetry", "history", "money", "honey",
        "journey", "party", "city", "country", "company", "story", "glory", "army", "baby", "body", "everybody", "nobody",
        "anybody", "somebody", "memory", "energy", "economy", "industry", "library", "factory", "theory", "strategy",
        "policy", "reality", "fantasy", "philosophy", "technology", "gravity", "democracy", "eternity", "infinity",
        "destiny", "symphony", "harmony", "melody", "diary", "dictionary", "jury", "duty", "beauty", "charity", "penalty",
        "salary", "battery", "gallery", "lottery", "mystery", "misery", "victory", "slavery", "surgery", "recovery",
        "delivery", "discovery", "biology", "psychology", "ministry", "agency", "emergency", "currency", "frequency",
        "privacy", "pharmacy", "anxiety", "society", "variety", "safety", "security", "community", "university",
        "opportunity", "activity", "authority", "majority", "minority", "personality", "quality", "quantity", "ability",
        "facility", "identity", "entity", "property", "category", "territory", "inventory", "laboratory", "directory",
        "trajectory", "kitty", "puppy", "bunny", "teddy", "daddy", "mommy", "granny", "buddy", "lady", "guy", "boy",
        "toy", "day", "today", "birthday", "holiday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "highway", "subway", "railway", "hallway", "doorway", "essay", "display", "replay", "relay", "array",
        "galaxy", "ivy", "jelly", "belly", "bully"]
    static let intensifyingIdioms: Set<String> = ["mad", "crazy", "hell", "fury", "anything", "wildfire", "clockwork",
        "magic", "heck", "nuts", "lightning", "rain", "glue", "family", "gold", "royalty", "trash", "garbage", "shit",
        "crap", "butter", "silk", "ice", "fire", "nothing", "everything", "new"]
    /// Adjectives ending in "ly", which can describe a noun: "like friendly neighbors".
    static let lyAdjectives: Set<String> = ["friendly", "lovely", "lonely", "ugly", "silly", "holy", "early", "curly",
        "jolly", "likely", "elderly", "deadly", "costly", "lively", "manly", "motherly", "fatherly", "sisterly",
        "brotherly", "kindly", "orderly", "homely", "ghostly", "heavenly", "worldly", "cowardly", "daily", "weekly",
        "monthly", "yearly", "hourly", "chilly", "smelly", "wobbly", "bubbly", "sickly", "beastly", "princely", "comely"]
    static let clauseConjunctions: Set<String> = ["if", "when", "whenever", "because", "since", "once", "but", "and",
        "or", "then", "though", "although", "unless", "while", "whether", "cuz", "cause"]

    private var aggressiveSarcasm: Set<String> { Self.sarcasmMarkers }

    /// Whether `word` reads as a description or an action rather than a thing: what a comparing
    /// "like" never stands before without a noun.
    private func isBareDescription(_ word: String) -> Bool {
        if Self.bareAdjectives.contains(word) || Self.adjectives.contains(word) || Self.degreeWords.contains(word) ||
            Self.sentenceAdverbs.contains(word) || Self.baseVerbs.contains(word) || Self.pastVerbs.contains(word) { return true }
        if word.count >= 4, word.hasSuffix("ly"), !Self.lyNouns.contains(word) { return true }
        if word.count >= 6, word.hasSuffix("ed"), !word.hasSuffix("eed") { return true }
        for suffix in ["ous", "ful", "less", "ive", "able", "ible", "ish", "ient", "ical"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
            return true
        }
        return false
    }

    private func isClauseStart(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard let word = after.first?.word else { return false }
        if word == "you" { return after.count > 1 && !after[1].afterComma }
        if Self.subjects.contains(word) || ["there's", "that's", "it's", "here's", "what's"].contains(word) { return true }
        if let apostrophe = word.firstIndex(of: "'") {
            let subject = String(word[..<apostrophe])
            return Self.subjects.contains(subject) || Self.ambiguousSubjects.contains(subject) || subject == "y" ||
                Self.quantifierSubjects.contains(subject)
        }
        if ["it", "there", "this", "that"].contains(word), after.count >= 2 {
            return Self.clauseVerbs.contains(after[1].word) || Self.auxiliaries.contains(after[1].word)
        }
        return false
    }

    /// "like I mean", "like I don't know", "like you know": the speaker thinking out loud.
    private func discourseFollows(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard after.count >= 2 else { return false }
        let a = after[0].word, b = after[1].word
        if a == "i", ["mean", "guess", "dunno", "swear", "think"].contains(b) { return true }
        if a == "i", b == "don't" || b == "dont", after.count >= 3, after[2].word == "know" { return true }
        if a == "you", b == "know" { return true }
        return false
    }

    func asksAboutIt(_ after: [(word: String, afterComma: Bool)]) -> Bool {
        guard let next = after.first?.word else { return true }
        return Self.prepositions.contains(next) || Self.clauseConjunctions.contains(next) || next.hasSuffix("ing") ||
            ["normally", "usually", "now", "today", "nowadays", "these", "there", "here", "right", "compared", "lately",
             "anymore", "when", "outside", "inside", "tomorrow", "yesterday", "tonight", "then", "this", "these", "nowadays",
             "overall", "generally", "honestly", "really", "anyway", "anyways", "though"].contains(next)
    }

    /// Light: a "like" between a connector, adverb or question word and another small word.
    func betweenLooseWords(_ index: Int, before: [String], after: [(word: String, afterComma: Bool)], start: Bool) -> String? {
        guard let next = after.first, !next.afterComma else { return nil }
        let previous = before.first
        let lead = start || previous.map { Self.connectors.contains($0) || Self.fillerAdverbs.contains($0) ||
            Self.whWords.contains($0) || $0 == "especially" } == true
        guard lead else { return nil }
        let smallNext: Set<String> = ["for", "maybe", "especially", "sometimes", "also", "even", "if", "when", "whenever",
            "because", "since", "once", "again", "always", "never", "just", "literally", "basically", "actually",
            "totally", "right", "instead", "probably", "definitely", "though", "anyway", "anyways", "almost", "mostly",
            "usually", "generally", "personally", "apparently", "obviously", "clearly", "only", "still", "already"]
        guard smallNext.contains(next.word) else { return nil }
        // "what women generally like in a man": a subject behind the adverb makes it the verb.
        var k = 0
        while k < before.count, Self.looseAdverbs.contains(before[k]) || Self.walkAdverbs.contains(before[k]) ||
                Self.fillerAdverbs.contains(before[k]) { k += 1 }
        if k > 0, k < before.count {
            let word = before[k]
            if Self.looseSubjects.contains(word) || ["you", "it"].contains(word) || Self.verbAuxiliaries.contains(word) ||
                (word.count >= 4 && word.hasSuffix("s") && !Self.notPlurals.contains(word)) || word.hasSuffix("'d") { return nil }
        }
        if asksWhatItIsLike(index), asksAboutIt(after) { return nil }
        // "and like for an hour", "like in late August": hedges stay at Light.
        if amountFollows(Array(after.dropFirst())) || timeFollows(after) { return nil }
        // "Like if you could": an opener that is also sarcasm stays.
        if start, after.prefix(4).contains(where: { Self.sarcasmMarkers.contains($0.word) && $0.word != "know" }) { return nil }
        return "between small words"
    }

    /// Aggressive: every "like" the rules above left that nothing here protects.
    func looseRule(_ index: Int, before: [String], after: [(word: String, afterComma: Bool)], start: Bool,
                   commaBefore: Bool, copula: String?, removedBefore: Set<Int>) -> String? {
        guard let first = after.first else { return nil }
        let next = first.word
        let previous = before.first
        let opener = start || previous.map { Self.connectors.contains($0) } == true || isDiscourseMarker(before)
        // "you know like Dahmer", "you know like goldfish": examples.
        if isDiscourseMarker(before), before.first == "know", isName(index + 1) || (!isBareDescription(next) &&
            !Self.prepositions.contains(next) && !Self.clauseConjunctions.contains(next) && !Self.whWords.contains(next) &&
            !isClauseStart(after) && !Self.fillerAdverbs.contains(next) && !Self.baseVerbs.contains(next) &&
            !Self.objectStarts.contains(next) && !Self.hesitations.contains(next) && !Self.connectors.contains(next)) { return nil }
        // "what the weather is going to be like tomorrow".
        if asksWhatItIsLike(index), asksAboutIt(after) { return nil }
        // Quotes, said or written around the word: keep.
        if gaps[index].contains(where: { "\"“”'‘".contains($0) }) { return nil }
        if Self.quoteOpeners.contains(next) || Self.interjections.contains(next) { return nil }
        // The word talked about: "like is a big one", "I'm still saying like but".
        // A question ("so like is this merged") puts a pronoun after "is"; the word itself does not.
        if ["is", "was", "isn't", "wasn't", "has", "means"].contains(next),
           previous.map({ Self.connectors.contains($0) || Self.mentionLeads.contains($0) }) ?? true,
           !(after.count > 1 && (Self.subjects.contains(after[1].word) || Self.ambiguousSubjects.contains(after[1].word))) {
            return nil
        }
        // Not after "like I said": "Like I said like in this transcript" has a filler after the frame.
        let saidFrame = before.count >= 3 && before[2] == "like" && (Self.subjects.contains(before[1]) || before[1] == "you")
        if let previous, Self.mentionLeads.contains(previous), Self.mentionFollowers.contains(next), !saidFrame { return nil }
        // "the l- like my sound": after a word cut off, "like" restarts the thought.
        // Not when it repairs a "like" just said: "like a r- like a new line".
        if index > 0, gaps[index].hasPrefix("-"), !before.prefix(3).contains("like") { return "after a cut-off word" }
        // "Like father, like son": a comparison repeated after a comma.
        if after.count >= 3, after[1].word == "like" || after[2].word == "like",
           after.dropFirst().prefix(2).contains(where: { $0.afterComma }) { return nil }

        // The verb: "I really like", "they'd like", "doesn't like to", "want to like it".
        if let previous, previous.hasSuffix("'d") || previous == "would" { return nil }
        // "Girls like to play", "I should so like to see it". Not "like to the right": a place.
        if next == "to", !(after.count > 1 && (Self.determiners.contains(after[1].word) || Self.phraseStarts.contains(after[1].word) ||
                                               numberFollows(Array(after.dropFirst())))) { return nil }
        // "Like as not": an old idiom for "probably".
        if next == "as", after.count > 1, after[1].word == "not" { return nil }
        var k = 0
        let back = previousWords(index, limit: 7)
        while k < back.count, Self.looseAdverbs.contains(back[k]) || Self.walkAdverbs.contains(back[k]),
              !(k == 0 && back[k] == "just") { k += 1 }
        if k < back.count {
            let word = back[k]
            let ahead = k + 1 < back.count ? back[k + 1] : nil
            // "I like it", "I really like it"; "Can I like drop off" is not the verb: it would take "to".
            // "would you like", "I'd also like": always the verb.
            if word == "would" || word.hasSuffix("'d") || ahead == "would" || ahead?.hasSuffix("'d") == true { return nil }
            // "girls usually like looking after pets": a plural subject.
            if k > 0, word.count >= 4, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.contains("'"),
               !Self.notPlurals.contains(word), !Self.objectVerbs.contains(word), !Self.prepositions.contains(word) { return nil }
            if Self.looseSubjects.contains(word) {
                let particles: Set<String> = ["off", "up", "out", "down", "in", "on", "over", "back", "away", "around"]
                if Self.baseVerbs.contains(next), !Self.objectStarts.contains(next), after.count > 1,
                   Self.objectStarts.contains(after[1].word) || particles.contains(after[1].word) {
                    return "before a verb after a subject"
                }
                // "I like trimmed it": a past tense with its object.
                if next.count >= 5, next.hasSuffix("ed") || Self.pastVerbs.contains(next), after.count > 1,
                   ["it", "them", "him", "her", "this", "that", "the", "my", "a", "an", "out", "up", "off"].contains(after[1].word) {
                    return "before a verb after a subject"
                }
                return nil
            }
            if ["you", "it", "ya"].contains(word) {
                // "gives you like a relay", "make it like sparkle": an object, not a subject.
                let object = ahead.map { (Self.objectVerbs.contains($0) || Self.prepositions.contains($0)) &&
                    !Self.verbAuxiliaries.contains($0) && !Self.isCopula($0) } ?? false
                // "it like teleports" would be "it likes".
                if !object, !(word == "it" && !Self.objectStarts.contains(next)) {
                    return Self.baseVerbs.contains(next) && after.count > 1 && Self.objectStarts.contains(after[1].word)
                        ? "before a verb after a subject" : nil
                }
            }
            let auxiliary = Self.verbAuxiliaries.contains(word) || word.hasSuffix("'ll") ||
                (word == "to" && (ahead.map(Self.infinitiveLeads.contains) == true ||
                    ["you", "them", "him", "her", "me", "us", "it", "people", "everyone", "everybody", "that", "this", "something",
                     "anything", "everything", "nothing", "someone", "anyone", "one", "ones", "being", "having", "whatever",
                     "myself", "yourself", "themselves", "each"].contains(next)))
            // "we'll do like a beta" is the verb "do"; "I do like it" is the auxiliary.
            var behind = k + 1
            while behind < back.count, Self.looseAdverbs.contains(back[behind]) || Self.walkAdverbs.contains(back[behind]) { behind += 1 }
            let doer = behind < back.count ? back[behind] : nil
            let doSubject = doer.map { Self.looseSubjects.contains($0) || $0 == "you" || $0 == "it" ||
                ($0.count >= 4 && $0.hasSuffix("s") && !Self.notPlurals.contains($0)) || ($0.first?.isLetter == true && isCapitalizedWord($0)) } ?? false
            let questioned = k + 2 < back.count && (Self.modals.contains(back[k + 2]) || Self.verbAuxiliaries.contains(back[k + 2]))
            let mainDo = ["do", "does", "did"].contains(word) && (!doSubject || questioned)
            if auxiliary, !mainDo {
                // "if you could like there's too much": a clause cannot be what someone likes.
                if isClauseStart(after), !["you", "it", "that", "this", "it's", "that's", "this's"].contains(next) {
                    return "before a clause after can or do"
                }
                if Self.objectStarts.contains(next) || isName(index + 1) { return nil }
                if Self.baseVerbs.contains(next) || Self.pastVerbs.contains(next) { return "before a verb after can or do" }
                return nil
            }
        }

        // Comparisons: "feels like", "something like", "kind of like", "people like us".
        if let previous {
            if Self.comparisonLeads.contains(previous) { return nil }
            if previous == "of", before.count > 1, ["kind", "sort", "type", "think", "thought"].contains(before[1]) { return nil }
            // "more like fine details": rather.
            if previous == "more" { return nil }
            if previous == "just" || previous == "not" {
                if isClauseStart(after) || discourseFollows(after) || Self.baseVerbs.contains(next) ||
                    (previous == "not" && (isBareDescription(next) || (next.count >= 5 && next.hasSuffix("ing")))) {
                    // falls through: "just like I mean", "not like considering"
                } else if previous == "just" && (next == "don't" || next == "do") {
                } else { return nil }
            }
            let listLike = Self.listNouns.contains(previous) ||
                (previous.count >= 4 && previous.hasSuffix("s") && !previous.hasSuffix("ss") && !previous.contains("'") &&
                 !Self.notPlurals.contains(previous) && !Self.copulas.contains(previous) &&
                 !["these", "those", "its", "ours", "yours", "theirs", "as", "was", "says", "seems", "looks", "feels",
                   "sounds", "means", "goes", "does", "has", "gets", "makes", "takes", "gives", "shows", "uses", "needs",
                   "wants", "works", "helps", "keeps", "thinks", "comes", "becomes", "plus", "always", "sometimes",
                   "perhaps", "nowadays", "towards", "afterwards", "anyways", "regardless", "unless", "thus"].contains(previous) &&
                 !Self.objectVerbs.contains(previous))
            if listLike, !Self.clauseConjunctions.contains(next) { return nil }
        }
        // "like me", "like them", "like everyone else", "like this", "something like so".
        if ["me", "him", "us", "them", "myself", "yourself", "himself", "herself", "ourselves", "themselves", "everyone",
            "everybody", "anyone", "anybody", "someone", "somebody", "nobody", "such", "one", "mine", "yours", "ours",
            "theirs", "hers"].contains(next) { return nil }
        if next == "his", after.count == 1 || after[1].afterComma { return nil }
        // "a young man like you, whose", "like her": a pronoun alone is compared to.
        if ["you", "her", "it"].contains(next), after.count == 1 || after[1].afterComma { return nil }
        // "whether it is like or not".
        if ["or", "and"].contains(next), after.count > 1, ["not", "unlike", "dislike"].contains(after[1].word) { return nil }
        // "light up like before", "same like always".
        if ["before", "always", "usual", "normal", "ever", "forever", "new"].contains(next),
           after.count == 1 || after[1].afterComma || Self.clauseConjunctions.contains(after[1].word) { return nil }
        // "read like fury", "cheered like mad", "works like a charm": idioms for "a lot".
        if Self.intensifyingIdioms.contains(next), after.count == 1 || after[1].afterComma ||
            Self.clauseConjunctions.contains(after[1].word) || Self.prepositions.contains(after[1].word) { return nil }
        // "looked so like a child", "so like my Beth": "so" is how much, not "so" joining a clause.
        if previous == "so", !start, index > 0, before.count > 1, !Self.hasComma(gaps[index - 1]), !Self.endsSentence(gaps[index - 1]),
           !Self.connectors.contains(before[1]), ["a", "an", "my", "your", "his", "her", "our", "their", "to"].contains(next) {
            return nil
        }
        // "Like a fool, I believed him", "And like most people, I", "Like that immortal hero, she", "yet like
        // the Englishman, the baby": a fronted comparison.
        let wide = nextWords(index, limit: 6)
        if opener || previous.map(Self.fillerAdverbs.contains) == true, !commaBefore || start, !isClauseStart(after),
           wide.dropFirst().prefix(5).contains(where: { $0.afterComma }),
           !Self.clauseConjunctions.contains(next), !Self.prepositions.contains(next), !Self.fillerAdverbs.contains(next),
           !isBareDescription(next) || describesANoun(at: index), !Self.whWords.contains(next), next != "right",
           !Self.quoteOpeners.contains(next), !Self.hesitations.contains(next) { return nil }
        // "Like this one?", "Like that guy over there?": a short answer.
        if start, ["this", "that", "these", "those", "all", "most", "many", "some", "every", "each"].contains(next),
           !isClauseStart(after), endsSentenceWithin(index, words: 8) || ["all", "most", "many", "every", "each"].contains(next) {
            return nil
        }
        if ["this", "that", "these", "those", "so"].contains(next) {
            let alone = after.count == 1
            if alone || !(opener && !isClauseStart(after)) && !isClauseStart(after) { return nil }
            if opener, after.count >= 2, !isClauseStart(after) { return "before this or that, after and/so" }
            if isClauseStart(after), opener { return "clause after and/so" }
            return nil
        }
        // "an enter key on the right, like a return key", "you know, like the dolphins": after a
        // comma, a noun phrase gives an example.
        if commaBefore, !Self.prepositions.contains(next), !Self.clauseConjunctions.contains(next), !isClauseStart(after),
           !discourseFollows(after), !Self.baseVerbs.contains(next), !isBareDescription(next) || describesANoun(at: index) { return nil }
        // "smiled over his face, like when you drop a brick": "as when".
        if commaBefore, ["when", "whenever"].contains(next) { return nil }
        // "Like a VPS but for phones.", "Like the cost center.": a short answer or a simile opening the sentence.
        if start, ["a", "an"].contains(next), !amountFollows(after) { return nil }
        // "Like sunshine after a storm", "Like bees swarming": a noun opening the sentence compares.
        if start, !isBareDescription(next), !Self.baseVerbs.contains(next), !Self.prepositions.contains(next),
           !Self.clauseConjunctions.contains(next), !Self.whWords.contains(next), !Self.fillerAdverbs.contains(next),
           !Self.objectStarts.contains(next), !Self.connectors.contains(next), !isClauseStart(after), next != "one",
           !Self.hesitations.contains(next), !Self.questionWords.contains(next), next.first?.isLetter == true,
           !numberFollows(after) { return nil }
        if start, Self.phraseStarts.contains(next) || isName(index + 1), endsSentenceWithin(index, words: 8) { return nil }
        // "Like I care", "Like I'd ever": sarcasm opening a sentence.
        if start, after.prefix(4).contains(where: { Self.sarcasmMarkers.contains($0.word) || $0.word.hasSuffix("'d") ||
                                                   $0.word.hasSuffix("'ll") }) { return nil }
        // "Like what?", "Like who cares?".
        if start, Self.questionWords.contains(next), after.count <= 2 { return nil }
        // "Like Claude." answering a question, "That's where an app like T3": a name gives an example.
        let functionWord: (String) -> Bool = { Self.connectors.contains($0) || Self.fillerAdverbs.contains($0) ||
            Self.prepositions.contains($0) || Self.objectVerbs.contains($0) || Self.determiners.contains($0) }
        if isName(index + 1), !Self.clauseConjunctions.contains(next), !Self.prepositions.contains(next),
           !Self.objectStarts.contains(next), !(previous.map(functionWord) ?? false) {
            if !start || after.count <= 3 { return nil }
        }

        // A clause after "like" is "as" or "as if" ("higher like it was before", "like it's connected")
        // unless it is the speaker thinking out loud ("like I mean", "like I don't know").
        // After "and" or at the start of a sentence the rules above already decided ("and like we
        // went", but "like I said", "like we do here", "Like I care").
        if isClauseStart(after) {
            if discourseFollows(after), !(copula.map(isPerson) ?? false) { return "before I mean" }
            // "like I say", "like you said": "as".
            if after.dropFirst().prefix(2).contains(where: { Self.sayingVerbs.contains($0.word) || Self.conjunctionVerbs.contains($0.word) }) {
                return nil
            }
            // "of like you could", "especially like I keep", "the like you have": nothing compares here.
            if let previous, !commaBefore, !before.prefix(2).contains(where: Self.isCopula), Self.determiners.contains(previous) || Self.fillerAdverbs.contains(previous) ||
                Self.whWords.contains(previous) || (["of", "for", "to", "at", "from", "about", "with", "by", "into", "in", "on"].contains(previous) &&
                !(before.count > 1 && ["kind", "sort", "type"].contains(before[1]))) {
                return "clause after a small word"
            }
            return nil
        }

        // After "is" or "was": "I'm like paranoid", "it's like whatever" go; "it's like a dream",
        // "she's like her sister", "it's like riding a bike" and "she was like really?" stay.
        // "is there like a meeting mode", "there should be like an enter button": nobody says "there
        // is similar to".
        if copula != nil || (previous == "there" && before.count > 1 && Self.isCopula(before[1])),
           before.prefix(3).contains("there") || before.first == "there's" {
            return "after there is"
        }
        let gets = before.first(where: Self.isCopula).map { ["get", "gets", "got", "getting"].contains($0) } ?? false
        if let copula, !gets {
            if isPerson(copula) {
                // "he's like keep trying": an order, quoted.
                if Self.baseVerbs.contains(next) { return nil }
                // "she was like really?", "I'm like then why": a quote.
                if let ending = sentenceEnding(index), ending == "?" || ending == "!" { return nil }
                if after.count == 1 || Self.clauseConjunctions.contains(next) || Self.whWords.contains(next) { return nil }
            }
            if Self.objectStarts.contains(next) && !["whatever", "more", "less", "much", "many"].contains(next) ||
                Self.prepositions.contains(next) { return nil }
            // "it's like riding a bike" and "it's like living in a nest" compare; "it's like
            // embarrassing" describes. Only a participle that is a feeling or a judgment describes:
            // every other word in "ing" after "it's like" is an activity, compared to.
            if next.hasSuffix("ing"), !isPerson(copula), !Self.ingNouns.contains(next) {
                return Self.describingParticiples.contains(next) && !describesANoun(at: index) ? "description after is" : nil
            }
            // "it's like sketchy", "I'm like hungry": a word ending in "y" that describes, alone.
            if next.count >= 5, next.hasSuffix("y"), !next.hasSuffix("ey"), !Self.yNouns.contains(next),
               !Self.lyNouns.contains(next), after.count == 1 || after[1].afterComma ||
                Self.clauseConjunctions.contains(after[1].word) || Self.prepositions.contains(after[1].word) {
                return "description after is"
            }
            if describesANoun(at: index) { return nil }
            if isBareDescription(next) || Self.clauseConjunctions.contains(next) || Self.whWords.contains(next) {
                return "description after is"
            }
            return nil
        }

        // Where the word before cannot lead a comparison: an opener, a small adverb, a question
        // word, a determiner, a preposition or a verb whose object follows.
        // "and like old times": a described noun after "and" compares.
        if opener, describesANoun(at: index), previous.map({ !Self.objectVerbs.contains($0) }) ?? true { return nil }
        if let previous {
            // "in a like manner": the old adjective. "the like stuff": a filler.
            if Self.determiners.contains(previous) {
                return Self.likeNouns.contains(next) || ["a", "an"].contains(previous) ? nil : "after a determiner"
            }
            // "how like an Italian he looked".
            if Self.whWords.contains(previous), ["a", "an", "the"].contains(next) { return nil }
            if Self.whWords.contains(previous) || Self.fillerAdverbs.contains(previous) { return "after a small word" }
            if Self.prepositions.contains(previous) {
                if Self.simileProps.contains(previous) {
                    if ["a", "an"].contains(next) && !amountFollows(after) { return nil }
                    // "flew about like gauzy butterflies", "handed about like refreshments".
                    if !["in", "on", "onto", "upon", "with"].contains(previous), describesANoun(at: index) ||
                        (!isBareDescription(next) && !Self.objectStarts.contains(next) && !Self.clauseConjunctions.contains(next) &&
                         !Self.whWords.contains(next) && !Self.prepositions.contains(next) && !numberFollows(after)) { return nil }
                    // "goes on like the rest", "wound up like the watch": a verb's particle, then a comparison.
                    let phrasal = before.count > 1 && ["go", "goes", "went", "going", "gone", "carry", "carries", "carried",
                        "come", "comes", "came", "coming", "keep", "kept", "catch", "caught", "set", "light", "lights", "lit",
                        "show", "shows", "wound", "wind", "move", "moves", "moved", "run", "runs", "ran"].contains(before[1])
                    if phrasal || !["in", "on", "onto", "upon"].contains(previous), Self.phraseStarts.contains(next) { return nil }
                    if ["in", "on", "onto", "upon", "off", "up", "down"].contains(previous),
                       !(Self.phraseStarts.contains(next) && next != "all") && !isBareDescription(next) && !isName(index + 1) &&
                        !Self.prepositions.contains(next) && !Self.clauseConjunctions.contains(next) &&
                        !Self.whWords.contains(next) { return nil }
                }
                return "after a preposition"
            }
            if Self.objectVerbs.contains(previous) {
                if ["use", "uses", "used", "using"].contains(previous), ["a", "an"].contains(next) { return nil }
                return "after a verb's object place"
            }
            // "give them like a one-liner", "make it like an alternative": the second object's place.
            if ["you", "me", "them", "him", "her", "us"].contains(previous), before.count > 1,
               ["give", "gives", "gave", "giving", "send", "sends", "sent", "sending", "show", "shows", "showed", "offer",
                "offered", "hand", "handed", "pay", "paid", "owe", "tell", "told", "teach", "taught", "buy", "bought", "get",
                "got", "bring", "brought", "make", "made"].contains(before[1]) { return "after a verb's object place" }
            // "want it like raping performance": a pronoun is never compared to an action.
            if ["you", "it", "me", "them", "him", "her", "us"].contains(previous), next.count >= 5, next.hasSuffix("ing"),
               !Self.ingNouns.contains(next) { return "before an action" }
        }
        if opener { return start ? "opens a sentence" : "after and/so" }

        // After anything else (a noun, an adjective): only before what cannot be compared to.
        // Not "cracked like a couple of nuts".
        // "waited like 20 minutes", but "work like three women": after a word Zone cannot place, only a
        // number of something measured.
        if numberFollows(after), after.count == 1 || after[1].afterComma || Self.unitWords.contains(after[1].word) ||
            after[1].word.first?.isNumber == true || ["to", "or", "and", "ish", "percent", "bucks", "grand"].contains(after[1].word) {
            return "before an amount"
        }
        if countFollows(after), !(after.count > 2 && after[1].word == "second") { return "before an amount" }
        if describesANoun(at: index) { return nil }
        if Self.prepositions.contains(next) || Self.clauseConjunctions.contains(next) || Self.whWords.contains(next) ||
            isBareDescription(next) {
            return "before a description"
        }
        return nil
    }

    /// "like clawed code", "like green salad": a description in front of a noun is a noun phrase,
    /// which "like" compares to or gives as an example.
    private func describesANoun(at index: Int) -> Bool {
        let wide = nextWords(index, limit: 5)
        var cursor = 0
        // Up to three descriptions, commas allowed between them: "like dark, shapeless blurs".
        while cursor < min(3, wide.count), isAdjectiveBeforeANoun(wide[cursor].word) { cursor += 1 }
        guard cursor > 0, cursor < wide.count, !wide[cursor].afterComma else { return false }
        let noun = wide[cursor].word
        return !Self.prepositions.contains(noun) && !Self.clauseConjunctions.contains(noun) && !isBareDescription(noun) &&
            (!Self.objectStarts.contains(noun) || ["people", "ones", "one"].contains(noun)) && !Self.auxiliaries.contains(noun) &&
            !Self.isCopula(noun) &&
            !Self.fillerAdverbs.contains(noun) && !Self.hesitations.contains(noun) && !Self.baseVerbs.contains(noun) &&
            !noun.hasSuffix("'s") && !Self.verbAuxiliaries.contains(noun) && !Self.connectors.contains(noun)
    }

    /// An adjective that can stand before a noun, not an adverb or a verb.
    private func isAdjectiveBeforeANoun(_ word: String) -> Bool {
        guard isBareDescription(word) else { return false }
        if Self.degreeWords.contains(word) || Self.sentenceAdverbs.contains(word) || Self.baseVerbs.contains(word) ||
            Self.pastVerbs.contains(word) || (word.hasSuffix("ly") && !Self.lyNouns.contains(word) && !Self.lyAdjectives.contains(word)) {
            return false
        }
        return !["whatever", "not", "upstairs", "downstairs", "together", "apart", "soon", "later", "earlier", "tonight",
                 "today", "tomorrow", "yesterday", "anywhere", "everywhere", "somewhere", "nowhere", "only", "very", "quite",
                 "rather", "less", "more", "so", "way", "too", "kinda", "sorta", "lowkey", "highkey", "legit", "deadass", "fr",
                 "just", "also", "even", "still", "maybe", "probably", "always", "never", "sometimes", "constantly", "again",
                 "already", "almost", "okay", "ok", "over", "done", "sure", "right", "wrong", "true"].contains(word)
    }
    static let colorWords: Set<String> = ["green", "red", "blue", "yellow", "purple", "orange", "pink", "black", "white",
        "gray", "grey", "brown"]
    /// Adjectives that usually sit before a noun: "like little features", "like big models".
    static let nounModifiers: Set<String> = ["big", "small", "little", "tiny", "huge", "giant", "old", "new", "young",
        "basic", "simple", "regular", "normal", "different", "same", "similar", "real", "full", "empty", "light", "dark"]

    /// Whether `word` is written with a capital somewhere in this dictation: a name.
    private func isCapitalizedWord(_ word: String) -> Bool {
        words.indices.contains { lower[$0] == word && text[words[$0]].first?.isUppercase == true && !startsSentence($0) }
    }

    /// Whether the sentence ends within `words` words after `index`.
    private func endsSentenceWithin(_ index: Int, words limit: Int) -> Bool {
        var cursor = index
        for _ in 0..<limit {
            if endsSentence(after: cursor) { return true }
            cursor += 1
        }
        return endsSentence(after: cursor)
    }

    /// The mark that ends the sentence holding `index`, if any.
    private func sentenceEnding(_ index: Int) -> Character? {
        var cursor = index + 1
        while cursor < gaps.count {
            if let mark = gaps[cursor].first(where: { ".!?\n".contains($0) }) { return mark }
            cursor += 1
        }
        return nil
    }
}
