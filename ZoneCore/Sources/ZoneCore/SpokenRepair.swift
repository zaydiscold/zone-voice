// by zayd/cold @ zayd.wtf

import Foundation

/// Repairs a speaker makes out loud, applied to recognizer text before style and commands run.
///
/// - Self-corrections: "Let's meet Tuesday, scratch that, Wednesday" becomes "Let's meet
///   Wednesday". The cue words count only when the recognizer set them apart with punctuation,
///   which it does when they are said as a command. "I want to scratch that itch", "can you
///   delete that file" and "no wait times" arrive without it and stay as said.
/// - Stutters: "I I think" becomes "I think", "just f- fidgeting" becomes "just fidgeting" and
///   "in the in the box" becomes "in the box". See `collapsingStutters`.
/// - Clock times: Fluid Speech Mini writes "4.30" for "four thirty". After "at", "by", "until"
///   and the like, or before "am" and "pm", it is written "4:30".
///
/// Measured on recognized speech: `docs/evidence/2026-11-08-spoken-repairs.md` (private notes).
public enum SpokenRepair {
    /// Explicit commands: always meant as an edit, so a repair with no other clue still applies.
    private static let commandCues: Set<String> = ["scratch that", "strike that", "delete that"]

    /// "scratch that", "no wait" and friends, fenced by punctuation or the edges of the text.
    /// Group 1 is the mark before the cue (empty at the start of the text), group 2 the cue.
    private static let cue = try! NSRegularExpression(
        pattern: #"(?:^|([,.;:!?…—–]))\s*\b(scratch that|strike that|delete that|no,?\s+wait|no,?\s+weight|no8|know,?\s+wait|wait,?\s+no)\b\s*(?:[,.;:!?…—–]+|$)"#,
        options: [.caseInsensitive])

    /// "scratch that" with no punctuation around it. Fluid Speech Mini often sets none: "They're
    /// crazy flat scratch that crazy fast" (Zayd's phone, November 15). It is also ordinary
    /// English ("scratch that itch"), so it counts only when the repair matches what came just
    /// before it (`repair(... unfenced: true)`).
    private static let unfencedCue = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])(?:scratch|strike)\s+that(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])

    /// A word before an unfenced "scratch that" that makes "scratch" a verb: "I want to scratch
    /// that", "the cat will scratch that", "I don't know if scratch that works".
    private static let verbLeads: Set<String> = [
        "to", "can", "could", "will", "would", "should", "shall", "must", "might", "may", "please", "just", "gonna",
        "wanna", "gotta", "let's", "lets", "don't", "didn't", "doesn't", "won't", "can't", "couldn't", "wouldn't",
        "shouldn't", "never", "always", "also", "not", "i", "you", "we", "they", "he", "she", "it", "if", "whether",
        "say", "says", "said", "saying", "and", "or", "the", "a", "an", "did", "do", "does",
    ]
    /// A word after an unfenced "scratch that" that makes it a phrase: "scratch that off the list".
    private static let phraseFollowers: Set<String> = [
        "off", "out", "up", "down", "away", "itch", "from", "into", "onto", "on", "with", "for", "and", "or", "but",
        "so", "because", "is", "was", "are", "were", "too", "again", "it", "one", "part", "word", "line",
    ]

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–"]

    /// True when the whole dictation is one correction command and nothing else: "Scratch that."
    /// The keyboard reads that as "take back the dictation before this one".
    public static func isStandaloneCommand(_ text: String) -> Bool {
        let bare = text.lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return commandCues.contains(bare)
    }

    /// Applies every fenced correction, left to right. `isPlainCommonWord` says whether a word is
    /// ordinary lowercase English, so a repair landing mid-sentence loses a capital the
    /// recognizer gave it ("Scratch that. Then" continues as "then") but a name keeps its own.
    static func applyingSelfCorrections(_ text: String, isPlainCommonWord: (String) -> Bool) -> String {
        var current = text
        var searchFrom = 0
        // Each pass removes a cue or steps past one, so this ends; the cap is a guard only.
        for _ in 0..<16 {
            let ns = current as NSString
            guard searchFrom < ns.length,
                  let match = cue.firstMatch(in: current, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            else { break }
            let cueText = ns.substring(with: match.range(at: 2)).lowercased()
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let isCommand = commandCues.contains(cueText)
            // Fluid Speech Mini hears "no wait" as "no weight" for some voices. Fenced by
            // punctuation it is the same cue, and it gets the same like-for-like guard.
            let markBefore = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let before = ns.substring(to: match.range.location)
            let after = ns.substring(from: NSMaxRange(match.range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // "Is it Monday? No, wait..." is an answer, not a correction.
            if !isCommand, markBefore == "?" || markBefore == "!" {
                searchFrom = NSMaxRange(match.range)
                continue
            }
            if let repaired = repair(before: before, markBefore: markBefore, after: after,
                                     isCommand: isCommand, isPlainCommonWord: isPlainCommonWord) {
                current = repaired
                searchFrom = 0
            } else {
                searchFrom = NSMaxRange(match.range)
            }
        }
        return applyingUnfencedScratches(current, isPlainCommonWord: isPlainCommonWord)
    }

    /// "scratch that" the recognizer did not set apart, after every fenced cue has been read.
    private static func applyingUnfencedScratches(_ text: String, isPlainCommonWord: (String) -> Bool) -> String {
        var current = text
        var searchFrom = 0
        for _ in 0..<16 {
            let ns = current as NSString
            guard searchFrom < ns.length,
                  let match = unfencedCue.firstMatch(in: current, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            else { break }
            searchFrom = NSMaxRange(match.range)
            let before = ns.substring(to: match.range.location)
            var after = Substring(ns.substring(from: NSMaxRange(match.range)))
            while let first = after.first, first.isWhitespace || clauseMarks.contains(first) { after.removeFirst() }
            // A cue with nothing after it, or a full stop after it, has no repair to match.
            guard let first = after.first, !sentenceEnders.contains(first) else { continue }
            let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
            guard let lastBefore = trimmedBefore.split(whereSeparator: { $0.isWhitespace }).last else { continue }
            let endsWithMark = lastBefore.last.map { clauseMarks.contains($0) || sentenceEnders.contains($0) } ?? false
            if !endsWithMark, verbLeads.contains(fold(String(lastBefore))) { continue }
            if let next = after.split(whereSeparator: { $0.isWhitespace }).first,
               phraseFollowers.contains(fold(String(next))) { continue }
            let markBefore = endsWithMark ? String(lastBefore.last!) : ""
            if let repaired = repair(before: before, markBefore: markBefore, after: String(after), isCommand: true,
                                     unfenced: true, isPlainCommonWord: isPlainCommonWord) {
                current = repaired
                searchFrom = 0
            }
        }
        return current
    }

    /// The text with one correction applied, or nil to leave it as said.
    /// `unfenced`: the cue had no punctuation around it, so only a repair that repeats one of the
    /// last few words, or swaps a number or name right before the cue, applies.
    private static func repair(before rawBefore: String, markBefore: String, after: String,
                               isCommand: Bool, unfenced: Bool = false, isPlainCommonWord: (String) -> Bool) -> String? {
        // The text being corrected, without the mark the recognizer put before the cue.
        var before = rawBefore
        while let last = before.last, last.isWhitespace || clauseMarks.contains(last) || sentenceEnders.contains(last) {
            before.removeLast()
        }
        // A cue at the very start has nothing to correct inside this dictation. A lone
        // "Scratch that." is handled by the keyboard; anything longer is left as said.
        guard !before.isEmpty else { return nil }

        // The sentence being corrected starts after the last sentence end before the cue.
        let regionStart = sentenceStart(in: before)
        let regionWords = words(in: before, from: regionStart)

        if after.isEmpty {
            guard isCommand, !unfenced else { return nil }
            // "Buy milk, eggs, scratch that." takes back the last phrase; a cue after a full stop
            // takes back the sentence.
            let cut: String.Index
            if sentenceEnders.contains(markBefore.first ?? " ") {
                cut = regionStart
            } else if let clause = before[regionStart...].lastIndex(where: { clauseMarks.contains($0) }) {
                cut = clause
            } else {
                cut = regionStart
            }
            var kept = String(before[..<cut])
            while let last = kept.last, last.isWhitespace || clauseMarks.contains(last) { kept.removeLast() }
            if let last = kept.last, !sentenceEnders.contains(last), !kept.isEmpty { kept += "." }
            return kept
        }

        let repairWords = words(in: after, from: after.startIndex, stoppingAtPunctuation: true)
        guard let firstRepair = repairWords.first else { return nil }

        let cut: String.Index
        // Unfenced, a repair reaches back only a few words: "crazy flat scratch that crazy fast".
        let anchorWords = unfenced ? Array(regionWords.suffix(4)) : regionWords
        // The repair repeats a word from the sentence: rewind to that word. "at 3, no wait, at 4".
        if let anchor = anchorWords.last(where: { fold(String(before[$0])) == fold(firstRepair.word) }) {
            cut = anchor.lowerBound
        } else if repairWords.count <= 3, let slot = slotWord(for: firstRepair.word, in: before, words: regionWords,
                                                              regionStart: regionStart),
                  !unfenced || regionWords.suffix(2).contains(where: { $0.lowerBound == slot.lowerBound }) {
            // A number or a name replaces the last number or name: "on Friday, scratch that,
            // Saturday night" keeps "on".
            cut = slot.lowerBound
        } else if unfenced {
            return nil
        } else if repairWords.count <= 3, regionWords.count > repairWords.count {
            let replaced = regionWords[regionWords.count - repairWords.count]
            // "no wait" is everyday speech, so without an anchor it only swaps like for like:
            // a number for a number, or a capitalized word (a day, a name) for another.
            if !isCommand, !sameSlot(String(before[replaced]), firstRepair.word,
                                     replacedIsSentenceStart: replaced.lowerBound == regionStart) {
                return nil
            }
            cut = replaced.lowerBound
        } else {
            // A longer repair, or one as long as the sentence, replaces the sentence.
            guard isCommand else { return nil }
            cut = regionStart
        }

        var head = String(before[..<cut])
        let startsSentence = cut == regionStart
        var tail = after
        if startsSentence {
            tail = capitalizingFirst(tail)
        } else if let first = tail.first, first.isUppercase {
            let word = firstRepair.word
            let lower = word.lowercased()
            if lower != "i", !lower.hasPrefix("i'"), !lower.hasPrefix("i’"), isPlainCommonWord(lower) {
                tail = first.lowercased() + tail.dropFirst()
            }
        }
        while let last = head.last, last.isWhitespace { head.removeLast() }
        if head.isEmpty { return tail }
        return head + " " + tail
    }

    private static func sentenceStart(in text: String) -> String.Index {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if sentenceEnders.contains(text[previous]), index < text.endIndex, text[index].isWhitespace {
                var start = index
                while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
                return start
            }
            index = previous
        }
        return text.startIndex
    }

    private struct Word { let range: Range<String.Index>; let word: String }

    /// Word ranges from `start`; with `stoppingAtPunctuation`, only up to the first mark.
    private static func words(in text: String, from start: String.Index, stoppingAtPunctuation: Bool) -> [Word] {
        var found: [Word] = []
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if c.isWhitespace { index = text.index(after: index); continue }
            if stoppingAtPunctuation, clauseMarks.contains(c) || sentenceEnders.contains(c) { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var core = String(text[index..<end])
            while let last = core.last, clauseMarks.contains(last) || sentenceEnders.contains(last) || last == "\"" || last == "”" {
                core.removeLast()
            }
            if !core.isEmpty { found.append(Word(range: index..<end, word: core)) }
            if stoppingAtPunctuation, let last = text[index..<end].last,
               clauseMarks.contains(last) || sentenceEnders.contains(last) { break }
            index = end
        }
        return found
    }

    private static func words(in text: String, from start: String.Index) -> [Range<String.Index>] {
        words(in: text, from: start, stoppingAtPunctuation: false).map(\.range)
    }

    private static func fold(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
    }

    /// The last word in the sentence of the same kind as `repair`: a number for a number, a
    /// capitalized word that does not start the sentence for a capitalized one.
    private static func slotWord(for repair: String, in text: String, words: [Range<String.Index>],
                                 regionStart: String.Index) -> Range<String.Index>? {
        let kind = slotKind(repair, isSentenceStart: false)
        guard kind != nil,
              var index = words.lastIndex(where: { range in
                  slotKind(String(text[range]), isSentenceStart: range.lowerBound == regionStart) == kind
              })
        else { return nil }
        // A number said as words is one slot: "five thirty" is replaced whole, not "thirty".
        if kind == .number {
            while index > 0, numberWords.contains(fold(String(text[words[index - 1]]))) { index -= 1 }
        }
        return words[index].lowerBound..<words[words.count - 1].upperBound
    }

    private enum Slot { case number, name }

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    ]

    private static func slotKind(_ word: String, isSentenceStart: Bool) -> Slot? {
        let folded = fold(word)
        if let first = folded.first(where: { !"$£€".contains($0) }), first.isNumber { return .number }
        if numberWords.contains(folded) { return .number }
        if !isSentenceStart, word.first?.isUppercase == true, folded != "i", !folded.hasPrefix("i'") { return .name }
        return nil
    }

    private static func sameSlot(_ replaced: String, _ repair: String, replacedIsSentenceStart: Bool) -> Bool {
        guard let kind = slotKind(repair, isSentenceStart: false) else { return false }
        return slotKind(replaced, isSentenceStart: replacedIsSentenceStart) == kind
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Stutters

    /// Takes out what a speaker says twice by accident, in three passes. Every pass removes whole
    /// space-separated words only, so a URL, a path or a hyphenated word is never edited.
    ///
    /// Measured on 549 minutes of Zayd's own dictation recognized by Fluid Speech Mini (1,150
    /// recordings, 65,546 words; private notes, `docs/evidence/2026-11-17-stutter-filter.md`):
    /// the recognizer writes a stutter down as it hears it, about once every 80 seconds.
    ///
    /// 1. Cut-off sounds. A word the speaker abandoned is written with a hyphen and a space:
    ///    "I was just f- fidgeting", "the s- the stars", "is this r- healthy". 75 in the
    ///    recordings, none of them a word anyone meant.
    /// 2. Doubled words, for words that are never doubled on purpose: "I I think", "the the",
    ///    "it's it's", "a a couple".
    /// 3. Restarted phrases: "in the in the AMS", "I don't I don't really know". Only a phrase
    ///    that cannot end a thought counts, so "thank you thank you" and "come on come on" stay.
    static func collapsingStutters(_ text: String) -> String {
        // Nothing here can apply without a space, and most dictations have no stutter: the cheap
        // checks keep the common case to one scan.
        guard text.contains(where: \.isWhitespace) else { return text }
        // "so like like we did before" keeps one "like"; "I like like her" is the verb and stays.
        let text = CaliforniaMode.collapsingStutters(text)
        var tokens = StutterToken.split(text)
        guard tokens.count > 1 else { return text }
        var changed = droppingCutOffSounds(&tokens)
        if collapsingDoubledWords(&tokens) { changed = true }
        if collapsingRestartedPhrases(&tokens) { changed = true }
        // A phrase restart can leave a doubled word behind: "we we've been we've been".
        if changed, collapsingDoubledWords(&tokens) { changed = true }
        guard changed else { return text }
        return StutterToken.join(tokens)
    }

    /// One space-separated word with the whitespace before it, split into the marks around it and
    /// the word itself: `("` + `the` + `,`.
    private struct StutterToken {
        var gap: Substring
        var lead: Substring
        var core: Substring
        var trail: Substring
        /// The word folded for comparison: lowercase, straight apostrophes.
        var folded: String
        var removed = false

        var raw: String { String(lead) + core + trail }
        var isSingleLetter: Bool { core.count == 1 && core.first!.isLetter }
        /// A line break before this word: the speaker's "new line", which no stutter spans.
        var startsLine: Bool { gap.contains(where: \.isNewline) }
        var endsSentence: Bool { trail.contains(where: { SpokenRepair.sentenceEnders.contains($0) }) }

        private static let opening: Set<Character> = ["\"", "“", "‘", "(", "[", "{"]
        private static let closing: Set<Character> = [",", ".", "!", "?", ";", ":", "…", "\"", "”", "’", ")", "]", "}", "—", "–"]

        static func split(_ text: String) -> [StutterToken] {
            var tokens: [StutterToken] = []
            var index = text.startIndex
            while index < text.endIndex {
                let gapStart = index
                while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                let wordStart = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                var word = text[wordStart..<index]
                let gap = text[gapStart..<wordStart]
                var leadEnd = word.startIndex
                while leadEnd < word.endIndex, opening.contains(word[leadEnd]) { leadEnd = word.index(after: leadEnd) }
                let lead = word[..<leadEnd]
                word = word[leadEnd...]
                var trailStart = word.endIndex
                while trailStart > word.startIndex, closing.contains(word[word.index(before: trailStart)]) {
                    trailStart = word.index(before: trailStart)
                }
                let core = word[..<trailStart]
                tokens.append(StutterToken(gap: gap, lead: lead, core: core, trail: word[trailStart...],
                                           folded: core.lowercased().replacingOccurrences(of: "’", with: "'")))
            }
            return tokens
        }

        static func join(_ tokens: [StutterToken]) -> String {
            var out = ""
            // The whitespace before the first of a run of removed words. The next kept word takes
            // it in place of its own when the run opened the text (so no space is left in front)
            // or held a line break (so the break is kept); otherwise it keeps its own.
            var carriedGap: Substring?
            for (index, token) in tokens.enumerated() {
                if token.removed {
                    if carriedGap == nil, index == 0 || token.gap.contains(where: \.isNewline) { carriedGap = token.gap }
                    continue
                }
                out += carriedGap ?? token.gap
                carriedGap = nil
                out += token.raw
            }
            return out
        }
    }

    // MARK: Cut-off sounds

    /// Words joined to the next by a hanging hyphen in ordinary writing: "pre- and post-war".
    private static let suspendedHyphenJoiners: Set<String> = ["and", "or", "to", "nor", "through", "versus", "vs"]
    /// A lowercase letter and the noun it makes a compound with, in case the recognizer ever
    /// writes "e- mail" for "e-mail". Left as written.
    private static let letterCompounds: [String: Set<String>] = [
        "e": ["mail", "mails", "commerce", "book", "books", "bike", "bikes", "sports", "sign", "signature", "reader",
              "ink", "learning", "scooter", "scooters", "cigarette", "cigarettes"],
        "t": ["shirt", "shirts", "bone", "mobile", "rex", "bar", "square"],
        "x": ["ray", "rays", "axis", "factor"], "y": ["axis"], "z": ["axis"],
        "u": ["turn", "turns", "haul", "boat", "shaped"], "v": ["neck", "shaped"], "l": ["shaped"],
        "a": ["frame", "list", "side", "team", "game"], "b": ["side", "roll", "team", "list"],
        "c": ["section", "suite", "level"], "d": ["day"], "g": ["force", "string"], "k": ["pop"],
    ]

    /// Removes each word the speaker cut off ("f-" in "just f- fidgeting"). True when any went.
    private static func droppingCutOffSounds(_ tokens: inout [StutterToken]) -> Bool {
        var changed = false
        for index in tokens.indices {
            let token = tokens[index]
            // Letters, then one hyphen, with nothing but an optional comma after: "f-", "do-,".
            guard token.lead.isEmpty, token.core.last == "-", token.trail.isEmpty || token.trail == "," else { continue }
            let sound = token.core.dropLast()
            guard !sound.isEmpty, sound.allSatisfy(\.isLetter) else { continue }
            let next = tokens[(index + 1)...].first(where: { !$0.removed })
            let previous = tokens[..<index].last(where: { !$0.removed })
            let startsSentence = previous.map(\.endsSentence) ?? true
            if let next {
                // "pre- and post-war", "first- and second-order", "long- or short-term".
                if suspendedHyphenJoiners.contains(next.folded) {
                    let afterJoiner = tokens[(index + 1)...].filter({ !$0.removed }).dropFirst().first
                    if sound.count >= 3 || afterJoiner?.core.contains("-") == true { continue }
                }
                let soundFolded = sound.lowercased()
                if sound.count == 1 {
                    if letterCompounds[soundFolded]?.contains(next.folded) == true { continue }
                    // A capital letter in mid-sentence is a grade or a name ("got a B- in math"),
                    // unless the next word starts with it ("the E- EHS ones").
                    if sound.first!.isUppercase, !startsSentence, !next.folded.hasPrefix(soundFolded) { continue }
                }
            } else if sound.count == 1, sound.first!.isUppercase, !startsSentence {
                continue
            }
            tokens[index].removed = true
            changed = true
            // "S- so I think" at the start of a sentence becomes "So I think".
            if startsSentence, sound.first!.isUppercase,
               let nextIndex = tokens[(index + 1)...].firstIndex(where: { !$0.removed }),
               let first = tokens[nextIndex].core.first, first.isLowercase {
                tokens[nextIndex].core = Substring(first.uppercased() + tokens[nextIndex].core.dropFirst())
            }
        }
        return changed
    }

    // MARK: Doubled words

    /// Words a speaker repeats by accident and a writer never doubles: "I I", "the the", "to to".
    /// What is left out on purpose, because both copies can be meant: "that that", "had had",
    /// "you you" and "it it" (an object, then a subject: "I told you you had", "click it it
    /// opens"), "is is" ("what it is is"), "in in" and "on on" ("log in in", "turn it on on"),
    /// "this this" ("do this this way"), "so so", "do do", "not not", and every word of emphasis
    /// ("really really", "very very", "no no", "wait wait").
    private static let doubledWords: Set<String> = [
        "i", "we", "they", "he", "she",
        "the", "a", "an", "my", "your", "our", "their",
        "to", "of", "for", "with", "from",
        "and", "but", "or", "if", "than", "then", "because", "maybe",
        "what", "why", "how", "when", "where", "which",
    ]
    /// Before "a a" these make it the letter, said twice: "type a a few times".
    private static let letterMentions: Set<String> = [
        "type", "typed", "typing", "press", "pressed", "letter", "letters", "key", "spell", "spelled", "write",
        "wrote", "say", "said", "add", "capital", "lowercase", "uppercase", "double",
    ]

    private static func isContraction(_ folded: String) -> Bool {
        guard let apostrophe = folded.firstIndex(of: "'"), apostrophe != folded.startIndex else { return false }
        let after = folded[folded.index(after: apostrophe)...]
        return !after.isEmpty && after.allSatisfy(\.isLetter) && folded[..<apostrophe].allSatisfy(\.isLetter)
    }

    /// Collapses each run of a doubled word to its first copy. True when any run collapsed.
    private static func collapsingDoubledWords(_ tokens: inout [StutterToken]) -> Bool {
        var changed = false
        let live = tokens.indices.filter { !tokens[$0].removed }
        var position = 0
        while position < live.count - 1 {
            let first = tokens[live[position]]
            let word = first.folded
            guard doubledWords.contains(word) || isContraction(word), first.trail.isEmpty else { position += 1; continue }
            // The run: copies with nothing but whitespace between them. The last may carry a mark.
            var end = position
            while end + 1 < live.count {
                let next = tokens[live[end + 1]]
                guard next.folded == word, next.lead.isEmpty, !next.startsLine, tokens[live[end]].trail.isEmpty else { break }
                end += 1
            }
            guard end > position else { position += 1; continue }
            let before = position > 0 ? tokens[live[position - 1]] : nil
            let after = end + 1 < live.count ? tokens[live[end + 1]] : nil
            let last = tokens[live[end]]
            var collapse = true
            // Spelled names ("D A A N", "H A W A I I") are letters, not a stutter.
            if first.isSingleLetter, before?.isSingleLetter == true || after?.isSingleLetter == true { collapse = false }
            if word == "a" {
                // The recognizer writes a spelled letter as a capital, and "A a" opens no sentence.
                let copies = live[position...end].map { tokens[$0] }
                if copies.dropFirst().contains(where: { $0.core != "a" }) { collapse = false }
                if let before, letterMentions.contains(before.folded) { collapse = false }
                if after == nil || !last.trail.isEmpty { collapse = false }
            }
            if word == "my" {
                // "My my, look at you" and "oh my my" are said that way.
                let opensSentence = before.map(\.endsSentence) ?? true
                if opensSentence || !last.trail.isEmpty || after == nil { collapse = false }
                if let before, ["oh", "well", "why"].contains(before.folded) { collapse = false }
            }
            if collapse {
                for removedPosition in (position + 1)...end { tokens[live[removedPosition]].removed = true }
                tokens[live[position]].trail = last.trail
                changed = true
            }
            position = end + 1
        }
        return changed
    }

    // MARK: Restarted phrases

    /// A phrase ending in one of these is unfinished, so saying it twice in a row is a restart:
    /// "in the in the", "I don't I don't", "how is how is", "when we when we".
    private static let unfinishedEnders: Set<String> = [
        "the", "a", "an", "my", "your", "our", "their", "his", "this", "these", "those",
        "in", "of", "to", "for", "with", "from", "at", "about", "into", "as", "than",
        "i", "we", "they", "he", "she",
        "is", "are", "was", "were", "am", "be", "been", "do", "does", "did", "can", "could", "should", "would",
        "will", "have", "has", "had", "don't", "doesn't", "didn't", "can't", "couldn't", "shouldn't", "wouldn't",
        "won't", "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't",
        "want", "wanna", "gonna", "gotta",
        "if", "when", "because", "that", "what", "how", "why", "where", "which", "who",
        "very", "not", "no", "just", "either", "many", "much", "also",
    ]
    /// "can you can you open", "is it is it the same", "when you when you": after one of these a
    /// phrase ending in "you" or "it" is unfinished too. Without it the phrase can be whole and
    /// said twice on purpose: "thank you thank you", "got it got it".
    private static let questionStarters: Set<String> = [
        "can", "could", "would", "will", "is", "are", "was", "were", "do", "did", "does", "have", "has", "should",
        "if", "when", "that", "and", "but", "so", "because", "what", "how", "why", "where",
    ]
    /// A phrase opening with one of these is an exclamation, whole as it stands: "oh my oh my".
    private static let exclamations: Set<String> = [
        "oh", "no", "yes", "yeah", "yep", "nope", "ok", "okay", "hey", "wow", "well", "please", "sorry", "thank", "thanks",
    ]
    private static let unfinishedContractions: Set<String> = [
        "it's", "that's", "there's", "here's", "he's", "she's", "what's", "let's", "who's", "how's", "where's",
    ]

    /// Before a two-word phrase ending in "to" these make it a restart: "how to how to buy", "I
    /// want to want to go". After a noun it is an idiom and a new clause: "from time to time to
    /// see", "went door to door to sell".
    private static let toLeads: Set<String> = [
        "how", "want", "wants", "wanted", "going", "need", "needs", "needed", "trying", "tried", "able", "used",
        "supposed", "got", "about", "like", "where", "what", "when", "who", "way", "order", "ought", "meant", "have",
    ]
    /// Subject and helping verb, which a clause can end on: "everything I do I do for you", "what
    /// it is it is", "where we are we are safe". After one of `clauseHeads` the pair is left alone.
    private static let helpingVerbs: Set<String> = [
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could", "should", "would", "will", "have",
        "has", "had",
    ]
    private static let clauseHeads: Set<String> = [
        "what", "whatever", "everything", "anything", "all", "who", "whoever", "where", "wherever", "when", "whenever",
        "as", "than", "that", "which", "thing", "things", "stuff", "however", "how", "if", "because", "while",
    ]

    private static let restartedSubjects: Set<String> = ["i", "we", "they", "he", "she", "i'd", "we'd", "they'd", "i'll", "we'll"]
    private static let insistedVerbs: Set<String> = [
        "know", "knew", "see", "swear", "promise", "said", "say", "says", "try", "tried", "do", "did", "am", "will",
        "can", "mean", "love", "hate", "hear", "understand", "agree", "win", "won", "pray", "beg", "insist", "repeat",
        "go", "went", "come", "came", "wait", "hope", "wish", "think",
    ]

    /// `before` is the word ahead of the first copy, `following` the word after the second.
    private static func isUnfinished(_ phrase: [StutterToken], before: StutterToken?, following: StutterToken) -> Bool {
        guard let last = phrase.last, let first = phrase.first else { return false }
        if last.folded == "to", phrase.count == 2 {
            // "you have to have to finish it" is a sentence; "I have to have to go" is rarer.
            return toLeads.contains(first.folded) && !(first.folded == "have" && before?.folded == "you")
        }
        if phrase.count == 2, helpingVerbs.contains(last.folded), let before, before.trail.isEmpty,
           clauseHeads.contains(before.folded) { return false }
        // Digits read out: "one two one two", "five five five five".
        if phrase.contains(where: { numberWords.contains($0.folded) || $0.core.contains(where: \.isNumber) }) { return false }
        if exclamations.contains(first.folded) { return false }
        // A third copy starting is a list or a rhythm, not a restart: "back to back to back", "at
        // D-A-A-N at D-A-A-N at D-A-A-N". ("I want I want I want to" still ends in a restart, and
        // goes pair by pair from there.)
        if following.folded == first.folded { return false }
        // Letters being spelled: "at sign B at sign B".
        if phrase.contains(where: { $0.isSingleLetter && $0.folded != "i" && $0.folded != "a" }) { return false }
        if unfinishedEnders.contains(last.folded) || unfinishedContractions.contains(last.folded) { return true }
        if phrase.count == 2 {
            // "I guess I guess Riju told me", "I got I got these": a subject and its verb, started
            // over. Verbs people repeat to insist stay: "I know I know but".
            if restartedSubjects.contains(first.folded) { return !insistedVerbs.contains(last.folded) }
            // "the copper the copper to gold wire", "a save a save like an export".
            // Not "calling a spade a spade".
            if ["the", "a", "an"].contains(first.folded) { return !["call", "calls", "called", "calling"].contains(before?.folded ?? "") }
            if first.folded == "let", last.folded == "me" { return true }
        }
        // "I don't I don't", "we're we're": a contraction that is not a possessive ("Sam's").
        if isContraction(last.folded), !last.folded.hasSuffix("'s") { return true }
        if last.folded == "you" || last.folded == "it" { return questionStarters.contains(first.folded) }
        return false
    }

    /// "in the in the AMS" keeps one "in the". The two copies have only spaces between and inside
    /// them, and something follows: a phrase repeated at the end of a sentence is left as said.
    private static func collapsingRestartedPhrases(_ tokens: inout [StutterToken]) -> Bool {
        var changed = false
        // Longest first, so "I don't know I don't know what" is one restart, not two.
        for length in stride(from: 4, through: 2, by: -1) {
            var live = tokens.indices.filter { !tokens[$0].removed }
            var position = 0
            while position + 2 * length < live.count {
                let firstCopy = live[position..<(position + length)].map { tokens[$0] }
                let secondCopy = live[(position + length)..<(position + 2 * length)].map { tokens[$0] }
                let same = zip(firstCopy, secondCopy).allSatisfy { $0.folded == $1.folded && !$0.folded.isEmpty }
                // No marks in or after either copy: the recognizer's comma or full stop means a pause
                // the speaker made, and "I guess. I guess it's good" is left as said.
                let unmarked = firstCopy.allSatisfy { $0.trail.isEmpty && $0.lead.isEmpty }
                    && secondCopy.allSatisfy { $0.trail.isEmpty && $0.lead.isEmpty && !$0.startsLine }
                    && !firstCopy.dropFirst().contains(where: \.startsLine)
                let distinct = Set(firstCopy.map(\.folded)).count > 1
                guard same, unmarked, distinct,
                      isUnfinished(firstCopy, before: position > 0 ? tokens[live[position - 1]] : nil,
                                   following: tokens[live[position + 2 * length]]) else { position += 1; continue }
                for removedPosition in (position + length)..<(position + 2 * length) { tokens[live[removedPosition]].removed = true }
                changed = true
                live = tokens.indices.filter { !tokens[$0].removed }
                // Step back: in "I want I want I want to" the pair before this one is a restart now.
                position = max(0, position - 2 * length)
            }
        }
        return changed
    }

    // MARK: Clock times

    private static let dottedTimeAfterWord = try! NSRegularExpression(
        pattern: #"(?<=\b(?:at|by|around|until|till|til|before|after|since)\s)(1[0-2]|0?[1-9])\.([0-5][0-9])(?![\d.,]\d)(?!\s*(?:%|percent|dollars?|bucks|cents?|euros?|pounds?|quid|miles?|km|kilometers?|kilos?|kg|lbs?|a\s|an\s|per\b|each\b))"#,
        options: [.caseInsensitive])
    private static let dottedTimeBeforeMeridiem = try! NSRegularExpression(
        pattern: #"(?<![\d.$£€])\b(1[0-2]|0?[1-9])\.([0-5][0-9])(?=\s*(?:a\.?m\.?|p\.?m\.?|o['’]clock)(?![\p{L}]))"#,
        options: [.caseInsensitive])

    /// "at 4.30" is a time in American writing: "at 4:30". Prices say "$4.30" or "4.30 dollars"
    /// and keep their point, because neither pattern sees a currency sign or a unit after.
    static func americanClockTimes(_ text: String) -> String {
        var out = dottedTimeAfterWord.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1:$2")
        out = dottedTimeBeforeMeridiem.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1:$2")
        return out
    }
}
