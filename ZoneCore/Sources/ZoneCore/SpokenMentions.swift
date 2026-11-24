// by zayd/cold @ zayd.wtf

import Foundation

/// Spoken handles: "at Kevin" is written "@kevin", to tag someone in a chat app.
///
/// One left-to-right pass over the words of a transcript. Each "at" is a trigger, read as:
///
///     trigger  ["sign" | "symbol"]  handle  [the same name again, the other way]
///
/// A handle is one of the person's handles ("at cold", or "at snake byte" for snakebyte), one word,
/// or spelled letters ("D A A N", "D-A-A-N", or the recognizer's uneven "K E NJI"). A name said and then spelled ("Dan, D A A N"), or spelled and then said ("D A A N,
/// Daan"), is one handle: the spelling wins. The trigger becomes a mention only when the words
/// around it pass conservative lexical filters. These are heuristics, not an intent detector.
///
/// Measured on Fluid Speech Mini with four synthetic voices (`docs/evidence/2026-11-06-spoken-handles.md`):
/// the recognizer writes "at" as "Ad" before a name ("Ad Lena") and fuses it into the name
/// ("Admarcus", "Addan"), so both count as "at" before a first name. "Add Mike", "Aunt Emily"
/// and "And Kevin" are real English and stay.
enum SpokenMentions {
    /// Brackets a mention's placeholder, its index between them. Private use: no later pass reads
    /// a word, a digit run or punctuation into them.
    static let lead: Character = "\u{E006}"
    static let end: Character = "\u{E007}"

    struct Marked {
        var text: String
        /// "@kevin" for placeholder 0, and so on.
        var handles: [String] = []
    }

    /// `bare` allows "at Kevin"; without it only the explicit "at sign Kevin" tags. Vocabulary is
    /// the person's words and the built-in names, keyed by lowercase. `handles` are the person's
    /// own (`PersonalVocabulary.handles`), written as stored.
    /// `before` is the end of the sentence already in the field (a dictation in two goes:
    /// "I'm looking" and then "at Kevin"), lowercase, in reading order.
    static func mark(_ text: String, bare: Bool, vocabulary: [String: String], handles: [String] = [],
                     before: [String] = []) -> Marked {
        var marked = Marked(text: text)
        // Every trigger ("at", "ad", "Admarcus") has an "a"; without saved handles most dictations
        // are done here. A saved handle can be heard without its "at" ("TXM."), so those read on.
        guard !handles.isEmpty || text.contains(where: { $0 == "a" || $0 == "A" }),
              !text.contains(lead), !text.contains(end) else { return marked }
        let words = words(in: text)
        var known: [String: String] = [:]
        if !handles.isEmpty {
            // Exact spellings win; a spoken alias must identify only one stored handle.
            let groups = Dictionary(grouping: handles, by: key)
            for (alias, matches) in groups where Set(matches).count == 1 { known["~" + alias] = matches[0] }
            for handle in handles { known[handle.lowercased()] = handle }
        }
        var output = ""
        var cursor = text.startIndex
        var index = 0
        // Where the current clause starts: a mention ends the one before ("at Kevin at Sarah").
        var floor = 0
        while index < words.count {
            guard let mention = mention(at: index, in: words, floor: floor, before: before, bare: bare,
                                        vocabulary: vocabulary, known: known)
                    ?? (bare ? unsaid(at: index, in: words, known: known) : nil) else {
                index += 1
                continue
            }
            output += text[cursor..<words[index].range.lowerBound]
            output.append(lead)
            output += String(marked.handles.count)
            output.append(end)
            marked.handles.append(mention.handle)
            cursor = words[mention.last].range.upperBound
            index = mention.last + 1
            floor = index
        }
        guard !marked.handles.isEmpty else { return marked }
        marked.text = output + text[cursor...]
        return marked
    }

    // MARK: Words

    private struct Word {
        let range: Range<String.Index>
        let text: Substring
        /// What lies between the previous word (or the start) and this one.
        let gap: Substring
        let lower: String
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "'" || character == "’"
    }

    /// Words are runs of letters, digits, underscores and apostrophes; a hyphen between two of
    /// them joins ("D-A-A-N", "Jean-Luc"). Everything else is a gap.
    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        var gapStart = index
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var cursor = text.index(after: index)
            while cursor < text.endIndex {
                if isWordCharacter(text[cursor]) {
                    cursor = text.index(after: cursor)
                } else if text[cursor] == "-", case let next = text.index(after: cursor), next < text.endIndex,
                          isWordCharacter(text[next]) {
                    cursor = next
                } else {
                    break
                }
            }
            let word = text[start..<cursor]
            words.append(Word(range: start..<cursor, text: word, gap: text[gapStart..<start],
                              lower: word.lowercased().replacingOccurrences(of: "’", with: "'")))
            index = cursor
            gapStart = cursor
        }
        return words
    }

    /// Only spaces: the two words are one phrase.
    private static func isSpaces(_ gap: Substring) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Spaces around at most one comma or period: "Dan, D A A N" or "D A A N. Daan".
    private static func isRepeatGap(_ gap: Substring) -> Bool {
        let marks = gap.filter { $0 != " " && $0 != "\t" }
        return !gap.isEmpty && (marks.isEmpty || marks == "," || marks == ".")
    }

    // MARK: Reading one mention

    private struct Mention {
        let handle: String
        /// The index of the last word it consumes.
        let last: Int
    }

    private enum Handle {
        /// One of the person's handles, and the index of the last word it was heard as.
        case known(String, last: Int)
        /// One word, by index.
        case word(Int)
        /// A name heard fused to "at" ("Admarcus"): the name, from the trigger word itself.
        case fused(String)
        /// Spelled letters, and the index of the last word that holds them.
        case spelled(String, last: Int)
        /// A spelling that can only be one of the person's handles (`savedSpelling`): that handle.
        case recovered(String, last: Int)
    }

    private static func mention(at index: Int, in words: [Word], floor: Int, before: [String], bare: Bool,
                                vocabulary: [String: String], known: [String: String]) -> Mention? {
        let trigger = words[index]
        // Every word of the dictation comes through here; only a trigger is worth reading.
        let isAt = trigger.lower == "at" || trigger.lower == "ad"
        // "at sign" heard as one word ("Absign ANNA").
        let fusedSign = fusedSigns.contains(trigger.lower)
        guard isAt || fusedSign || trigger.lower == "add" ||
                (bare && trigger.lower.count >= 5 && (trigger.lower.hasPrefix("at") || trigger.lower.hasPrefix("ad"))),
              !trigger.gap.hasSuffix("@") else { return nil }
        // The words "at" hangs from, nearest first, back to a clause mark ("Hey, at Kevin").
        var clause: [String] = []
        var back = index
        while back > floor, clause.count < 4, isSpaces(words[back].gap) {
            back -= 1
            clause.append(words[back].lower)
        }
        // The same sentence, started in an earlier dictation.
        if back == 0, floor == 0, words[0].gap.allSatisfy(\.isWhitespace) {
            clause += before.reversed().prefix(4 - clause.count)
        }
        // A spoken mark ends a clause like the mark itself: "new line at Sarah", "comma at Kevin".
        if let first = clause.first, spokenMarks.contains(first) ||
            (clause.count > 1 && spokenMarks.contains(clause[1] + " " + first)) {
            clause = []
        }
        let previous = clause.first

        var next = index + 1
        var explicit = false
        // "at sign" as the recognizer mishears it ("Add sine", "At signs"): explicit, but only for
        // letters it wrote in capitals, the way it writes a spelling.
        var misheard = false
        var handle: Handle
        if bare, !fusedSign, let name = fusedName(trigger, vocabulary: vocabulary) {
            handle = .fused(name)
        } else {
            guard next < words.count, isSpaces(words[next].gap) else { return nil }
            if fusedSign {
                explicit = true
                misheard = true
            } else {
                let sign = words[next].lower
                let exact = isAt && (sign == "sign" || sign == "symbol")
                let heardAs = (isAt || trigger.lower == "add") && (misheardSigns.contains(sign) || sign == "sign")
                if exact || heardAs, next + 1 < words.count, isSpaces(words[next + 1].gap) {
                    explicit = true
                    misheard = !exact
                    next += 1
                } else if !isAt {
                    return nil
                }
            }
            // Spelling owns its complete run. A saved short handle must not steal its prefix.
            if let spelled = spelled(from: next, in: words) {
                if spelled.certain {
                    handle = .spelled(spelled.letters, last: spelled.last)
                } else if let saved = savedSpelling(spelled.letters, known: known) {
                    // "D AN" is a guess on its own, but not when it can only be a saved handle.
                    handle = .recovered(saved, last: spelled.last)
                } else {
                    return nil
                }
            } else if let heard = knownHandle(from: next, in: words, known: known) {
                handle = .known(heard.handle, last: heard.last)
            } else {
                guard !words[next].text.contains(where: { $0 == "'" || $0 == "’" }) else { return nil } // "at Kevin's"
                handle = .word(next)
            }
        }
        handle = withRepeat(handle, trigger: index, in: words)
        // Spelled letters, or a word the recognizer capitalized the way it writes them ("DAN"),
        // that can only be one saved handle.
        switch handle {
        case .spelled(let letters, let last):
            if let saved = savedSpelling(letters, known: known) { handle = .recovered(saved, last: last) }
        case .word(let at) where words[at].text.count >= 2 && words[at].text.allSatisfy({ $0.isLetter && $0.isUppercase }):
            if let saved = savedSpelling(words[at].lower, known: known) { handle = .recovered(saved, last: at) }
        default: break
        }

        let lastIndex: Int
        let letters: String
        switch handle {
        case .known(let stored, let last), .recovered(let stored, let last): lastIndex = last; letters = stored
        case .word(let at): lastIndex = at; letters = folded(words[at].lower)
        case .fused(let name): lastIndex = index; letters = name
        case .spelled(let spelled, let last): lastIndex = last; letters = spelled.lowercased()
        }
        let kept: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || ($0 == "." && isSaved(handle)) }
        let written = letters.filter(kept)
        // Chat handles have a letter and at least two characters: "sign B" and "at 12" are not tags.
        guard written.count >= 2, written.contains(where: \.isLetter) else { return nil }
        let mention = Mention(handle: "@" + written, last: lastIndex)
        if misheard, !isCapitals(words[next...lastIndex]) { return nil }
        if explicit {
            // "I'm at sign B", "meet me at sign 4": a sign somewhere, unless it names a saved handle.
            if governsPreposition(clause), !isSaved(handle) { return nil }
            // "the at sign" names the symbol; "look at sign language" and "at sign up" are phrases.
            if ["a", "an", "the", "word", "literal"].contains(previous ?? "") { return nil }
            if case .word(let at) = handle {
                let word = words[at].lower
                // "at sign at Kevin", "you need at sign before the name": not a handle.
                if signFunctionWords.contains(word) { return nil }
                if words[at].text.first?.isUppercase != true, vocabulary[word] == nil,
                   !firstNames.contains(folded(word)), TextStyle.isPlainCommonWord(word) {
                    if signPhrases.contains(word) || governsPreposition(clause) { return nil }
                    // Mid-sentence, "at sign" and an everyday word talk about the symbol: "type at
                    // sign followed by", "Discord uses at sign mentions". Addressing starts a clause
                    // or follows a greeting: "at sign cold what's up", "hey at sign cold".
                    if let previous, !addressLeads.contains(previous) { return nil }
                }
            }
            return mention
        }
        guard bare, !governsPreposition(clause), !broadcastHandles.contains(letters.lowercased()) else { return nil }
        // "the ad Kevin made" is an advert.
        if trigger.lower == "ad", let previous, determiners.contains(previous) { return nil }
        switch handle {
        case .fused:
            // "Atanas called": a sentence's subject, not "at" fused to a name. "Admarcus, look".
            if previous == nil, index + 1 < words.count, isSpaces(words[index + 1].gap),
               !handleFollowers.contains(words[index + 1].lower) { return nil }
            return mention
        case .recovered: return mention
        case .known(_, let last):
            // A handle that is also an ordinary word ("cold", "everyone") stands alone after "at":
            // "@cold what's up", not "at cold temperatures" or "leave it at cold".
            if last == index + 1, TextStyle.isPlainCommonWord(words[last].lower),
               let previous, objectsAndAdverbs.contains(previous) { return nil }
            guard last + 1 < words.count, isSpaces(words[last + 1].gap) else { return mention }
            return handleFollowers.contains(words[last + 1].lower) ? mention : nil
        case .spelled(let spelled, _):
            // Spelled capitals are not English after "at"; lowercase letters are ("at a b").
            return spelled.allSatisfy(\.isUppercase) || vocabulary[letters] != nil ? mention : nil
        case .word(let at):
            return isName(at, in: words, vocabulary: vocabulary, afterAd: trigger.lower == "ad") ? mention : nil
        }
    }

    private static let fusedSigns: Set<String> = ["absign", "adsign", "atsign", "atsine", "adsine"]
    private static let misheardSigns: Set<String> = ["sine", "signs", "signed", "sines"]

    /// Letters the recognizer wrote as a spelling: capitals only, at least two of them ("TXM", "D A N").
    private static func isCapitals(_ run: ArraySlice<Word>) -> Bool {
        run.allSatisfy { word in word.text.contains(where: \.isLetter) && word.text.allSatisfy { !$0.isLetter || $0.isUppercase } }
            && run.reduce(0) { $0 + $1.text.filter(\.isLetter).count } >= 2
    }

    /// The recognizer can lose "at" ("D-A-A-N.", "TXM.") or hear it, or "at sign", as other words at
    /// the start ("That ANNA", "Sign TXM", "It's signed D A N"). With no "at" to go on, only a saved
    /// handle spelled in capitals at the start of a sentence is a tag, and only on its own or
    /// before what is said to that person.
    private static func unsaid(at index: Int, in words: [Word], known: [String: String]) -> Mention? {
        guard !known.isEmpty, index == 0 || words[index].gap.contains(where: { ".!?,;:\n".contains($0) }) else { return nil }
        var start = index
        for lead in unsaidLeads where index + lead.count < words.count {
            let matches = lead.indices.allSatisfy { at in
                words[index + at].lower == lead[at] && (at == 0 || isSpaces(words[index + at].gap))
            }
            if matches, isSpaces(words[index + lead.count].gap) { start = index + lead.count; break }
        }
        let letters: String
        let last: Int
        if let spelled = spelled(from: start, in: words) {
            letters = spelled.letters; last = spelled.last
        } else {
            letters = String(words[start].text); last = start
        }
        guard isCapitals(words[start...last]), let saved = savedSpelling(letters, known: known),
              // Never @everyone unasked; "LOL." and "OK." are the recognizer's capitals, not a spelling.
              !broadcastHandles.contains(saved), !TextStyle.isPlainCommonWord(saved) else { return nil }
        if last + 1 < words.count, isSpaces(words[last + 1].gap), !handleFollowers.contains(words[last + 1].lower) { return nil }
        return Mention(handle: "@" + saved, last: last)
    }

    private static let unsaidLeads: [[String]] = [["it's", "signed"], ["it", "signs"], ["that's"], ["that"], ["it's"], ["sign"]]

    /// What a handle is matched by: its letters and digits, so "snake byte" and "Snake_Byte" are
    /// both snakebyte.
    private static func key(_ text: some StringProtocol) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A stored handle, written as stored ("x_9.y" keeps its dot).
    private static func isSaved(_ handle: Handle) -> Bool {
        switch handle {
        case .known, .recovered: return true
        default: return false
        }
    }

    /// "José" is matched and written as the store keeps it: "jose".
    private static func folded(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: nil)
    }

    /// The saved handle these letters spell. The recognizer collapses a doubled letter it hears
    /// spelled ("D A A N" comes back "D A N"), so one missing repeat still names a handle, but
    /// only one: an exact saved spelling wins, and two candidates are no answer.
    private static func savedSpelling(_ letters: String, known: [String: String]) -> String? {
        guard !known.isEmpty else { return nil }
        let heard = key(letters)
        guard heard.count >= 2 else { return nil }
        if let exact = known["~" + heard] { return exact }
        var found: String?
        for (alias, handle) in known where alias.hasPrefix("~") && alias.count == heard.count + 2 {
            let saved = Array(alias.dropFirst())
            let isCollapse = (1..<saved.count).contains { at in
                guard saved[at] == saved[at - 1] else { return false }
                var candidate = saved
                candidate.remove(at: at)
                return String(candidate) == heard
            }
            guard isCollapse else { continue }
            if let found, found != handle { return nil }
            found = handle
        }
        return found
    }

    /// The longest run of up to three words from `start`, joined by spaces, that is one of the
    /// person's handles: the recognizer splits a made-up word ("snake byte" for snakebyte).
    private static func knownHandle(from start: Int, in words: [Word], known: [String: String]) -> (handle: String, last: Int)? {
        guard !known.isEmpty else { return nil }
        var runs: [(key: String, last: Int)] = []
        var joined = ""
        var index = start
        while index < words.count, index < start + 3, index == start || isSpaces(words[index].gap),
              words[index].text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            joined += key(words[index].text)
            runs.append((joined, index))
            index += 1
        }
        for run in runs.reversed() {
            if run.last == start, let exact = known[words[start].lower] { return (exact, start) }
            if let handle = known["~" + run.key] { return (handle, run.last) }
        }
        return nil
    }

    /// A said name next to its spelling, either order, is one handle and the spelling wins.
    private static func withRepeat(_ handle: Handle, trigger: Int, in words: [Word]) -> Handle {
        let at: Int
        let said: String
        switch handle {
        case .known(let name, let last): at = last; said = name
        case .word(let word): at = word; said = words[word].lower
        case .fused(let name): at = trigger; said = name
        case .recovered: return handle
        case .spelled(let letters, let last):
            // Spelled, then said: "D A A N, Daan".
            guard last + 1 < words.count, isRepeatGap(words[last + 1].gap) else { return handle }
            let word = words[last + 1]
            guard word.text.first?.isUppercase == true, word.text.allSatisfy(\.isLetter),
                  word.lower == letters.lowercased() else { return handle }
            return .spelled(letters, last: last + 1)
        }
        // Said, then spelled: "Dan, D A A N".
        guard at + 1 < words.count, isRepeatGap(words[at + 1].gap),
              let spelled = spelled(from: at + 1, in: words), spelled.certain, spelled.letters.allSatisfy(\.isUppercase),
              sameName(said, spelled.letters.lowercased()) else { return handle }
        return .spelled(spelled.letters, last: spelled.last)
    }

    /// A said name and its spelling, as the recognizer hears them: same first letter and at most
    /// two letters apart ("Dan" and "daan", "Don" and "daan").
    private static func sameName(_ said: String, _ spelled: String) -> Bool {
        said.count >= 2 && said.first == spelled.first && editDistance(said, spelled) <= 2
    }

    private struct Spelling {
        let letters: String
        let last: Int
        let certain: Bool
    }

    /// Reads letters without inferring missing ones. Uppercase chunks can bridge ASR splits
    /// ("K E NJI"), but ordinary words terminate a run or make a short mixed run ambiguous.
    /// Never consult the name list to decide whether a final I belongs to an unknown handle.
    private static func spelled(from start: Int, in words: [Word]) -> Spelling? {
        var letters = ""
        var last = start - 1
        var singles = 0
        var pieces = 0
        var hyphenated = false
        var onlySingles = true
        var index = start
        while index < words.count {
            let word = words[index]
            if index > start {
                let afterSingle = words[index - 1].text.count == 1
                let gapIsDot = word.gap.first == "." && isSpaces(word.gap.dropFirst())
                guard isSpaces(word.gap) || (afterSingle && gapIsDot) else { break }
            }
            let parts = word.text.split(separator: "-")
            if word.text.count == 1, word.text.first!.isLetter {
                // "I think" begins a sentence; "Q Y Z I hello" ends the spelling with I.
                if word.lower == "i", singles >= 2, index + 1 < words.count,
                   isSpaces(words[index + 1].gap), pronounVerbs.contains(words[index + 1].lower) { break }
                singles += 1
            } else if parts.count > 1, parts.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) {
                singles += parts.count
                hyphenated = true
            } else if (2...4).contains(word.text.count), word.text.allSatisfy({ $0.isLetter && $0.isUppercase }),
                      singles > 0 || (index + 1 < words.count && words[index + 1].text.count == 1) {
                if singles >= 2, spellingBoundaries.contains(word.lower) { break }
                if TextStyle.isPlainCommonWord(word.lower) {
                    // "D AN" could be collapsed spelling or ordinary words. Refuse the whole
                    // candidate instead of emitting @d or confidently inventing another A.
                    return Spelling(letters: letters + word.text, last: index, certain: false)
                }
                onlySingles = false
            } else {
                break
            }
            let piece = word.text.filter(\.isLetter)
            guard letters.count + piece.count <= 32 else {
                return Spelling(letters: letters, last: index, certain: false)
            }
            letters += piece
            pieces += 1
            last = index
            index += 1
        }
        guard letters.count >= 2, singles > 0, pieces > 1 || hyphenated else { return nil }
        // A hyphenated run or three separate letters is explicit spelling even if ASR lowercases
        // it. Two lowercase words such as "a b" remain ambiguous for bare "at".
        if hyphenated || (onlySingles && singles >= 3) { letters = letters.uppercased() }
        return Spelling(letters: letters, last: last, certain: true)
    }

    private static let spellingBoundaries: Set<String> = [
        "at", "and", "or", "but", "so", "then", "can", "are", "you", "the", "hey", "hi", "go", "ok", "yes", "no",
    ]

    private static let pronounVerbs: Set<String> = [
        "am", "was", "have", "had", "think", "thought", "want", "wanted", "need", "needed", "know", "knew",
        "will", "would", "can", "could", "should", "shall", "do", "did", "don't", "didn't", "like", "love",
        "hope", "see", "saw", "said", "say", "agree", "believe", "guess", "mean", "meant", "feel", "felt",
    ]

    // MARK: Deciding

    /// A first name, or one of the person's words, written the way a name is. All capitals pass
    /// only for a first name ("KENJI", not "MIT"); lowercase only when it is not also an ordinary
    /// word ("at kevin", not "at dawn"). A capital word right after it makes a place ("at Georgia
    /// Tech", "at Madison Square Garden"), unless that word is "I".
    private static func isName(_ index: Int, in words: [Word], vocabulary: [String: String], afterAd: Bool) -> Bool {
        let word = words[index]
        guard word.text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        if TextStyle.isPlainCommonWord(word.lower), index + 1 < words.count, isSpaces(words[index + 1].gap),
           !handleFollowers.contains(words[index + 1].lower) { return false }
        if vocabulary[word.lower] != nil { return true }
        guard !nonHandles.contains(word.lower), firstNames.contains(folded(word.lower)) else { return false }
        if word.text.first?.isUppercase != true {
            // "ad kevin" is not a mishearing anyone would make in lowercase.
            guard !afterAd, !TextStyle.isPlainCommonWord(word.lower) else { return false }
        }
        if index + 1 < words.count, isSpaces(words[index + 1].gap),
           words[index + 1].text.first?.isUppercase == true,
           !["i", "i'm", "i'll", "i'd", "i've"].contains(words[index + 1].lower) {
            return false
        }
        return true
    }

    /// "Admarcus" or "Addan": "at" heard fused to a first name, as a word no dictionary has.
    private static func fusedName(_ word: Word, vocabulary: [String: String]) -> String? {
        let lower = word.lower
        guard lower.count >= 5, lower.hasPrefix("at") || lower.hasPrefix("ad"),
              word.text.first?.isUppercase == true, word.text.dropFirst().allSatisfy(\.isLowercase),
              !firstNames.contains(lower), vocabulary[lower] == nil, TextStyle.wordRank(lower) == nil else { return nil }
        for cut in lower.hasPrefix("add") ? [2, 3] : [2] {
            let rest = String(lower.dropFirst(cut))
            if rest.count >= 3, !nonHandles.contains(rest), firstNames.contains(rest) || vocabulary[rest] != nil {
                return rest
            }
        }
        return nil
    }

    /// The words before "at" (nearest first) make it a preposition: where someone is ("is at",
    /// "works at"), or what an action or feeling points at ("look at", "mad at", "good at").
    private static func governsPreposition(_ clause: [String]) -> Bool {
        guard let previous = clause.first else { return false }
        if prepositionGovernors.contains(previous) { return true }
        // A time or a number, then where: "tonight at Madison", "pickup at 5 at Chase".
        if previous.allSatisfy(\.isNumber) || times.contains(previous) { return true }
        // "see you at Chase", "wait for you at Lincoln"; but "thank you at Kevin".
        if previous == "you" { return clause.count < 2 || !addressingYou.contains(clause[1]) }
        // Something done to someone happens at a place: "grab it at", "see him at", "pick them up at".
        if objectPronouns.contains(previous) { return true }
        if clause.count > 1, particles.contains(previous), objectPronouns.contains(clause[1]) { return true }
        // A noun phrase, then where it is: "my jacket at Ashley". Not "thanks a lot at Sarah".
        if clause.count > 1, determiners.contains(clause[1]), !quantities.contains(previous) { return true }
        // An object or adverb between the verb and "at": "throw it at Josh", "looking right at Dan".
        if clause.count > 1, objectsAndAdverbs.contains(previous), prepositionGovernors.contains(clause[1]) { return true }
        // A verb aimed at someone, or one that happens somewhere, reaches over its object ("throw
        // the ball at Liam", "stayed up late at Kevin", "going to be late at Mike"), not over a
        // preposition or conjunction that starts another phrase ("shout out to at Marcus").
        return clause.prefix(while: { !phraseBreaks.contains($0) })
            .contains { aimingVerbs.contains($0) || placeVerbs.contains($0) }
    }

    private static let times: Set<String> = [
        "tonight", "tomorrow", "today", "yesterday", "weekend", "am", "pm", "noon", "midnight", "o'clock", "oclock",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mondays", "tuesdays",
        "wednesdays", "thursdays", "fridays", "saturdays", "sundays", "lands", "starts", "begins", "ends",
        "opens", "closes", "pickup", "dropoff", "kickoff", "tipoff",
    ]

    /// Spoken marks, as the recognizer writes them before they are expanded.
    private static let spokenMarks: Set<String> = [
        "comma", "period", "colon", "semicolon", "semi-colon", "unquote", "bullet", "new line", "new paragraph",
        "question mark", "exclamation mark", "exclamation point", "bullet point", "full stop", "next item",
        "next bullet", "end list", "close quote", "end quote", "open quote", "begin quote", "semi colon",
        "close parenthesis", "open parenthesis",
    ]

    /// Words "at sign" never names: the phrase is about the symbol.
    private static let signFunctionWords: Set<String> = [
        "at", "sign", "symbol", "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "is",
        "are", "was", "before", "after", "by", "from", "as", "it", "this", "that", "then", "than",
    ]

    /// What comes before someone addressed mid-sentence: "hey at sign cold", "thanks at sign cold".
    private static let addressLeads: Set<String> = [
        "hey", "hi", "hello", "yo", "sup", "thanks", "thank", "thx", "ty", "cc", "and", "or", "to", "for",
        "with", "ping", "tell", "ask", "gg", "congrats", "sorry", "ok", "okay", "lol", "also", "plus", "from",
        "dear", "bro", "dude", "man", "you", "please", "pls", "welcome", "bye", "night", "morning",
    ]

    /// After these, "you at" still addresses someone: "thank you at Kevin", "love you at Mia".
    private static let addressingYou: Set<String> = ["thank", "love", "miss", "got", "hear", "feel"]

    private static let objectPronouns: Set<String> = [
        "it", "them", "him", "her", "me", "us", "this", "these", "those", "em", "'em",
    ]

    private static let particles: Set<String> = ["up", "off", "out", "down", "back", "over", "in", "on", "around"]

    /// "a lot", "a ton": an amount, not a thing that is somewhere.
    private static let quantities: Set<String> = ["lot", "ton", "bunch", "million", "bit", "little"]

    /// Being or doing something somewhere: they govern "at" across the words between.
    private static let placeVerbs: Set<String> = [
        "be", "am", "is", "are", "was", "were", "been", "being", "i'm", "im", "we're", "they're", "you're",
        "he's", "she's", "it's", "leave", "leaves", "leaving", "left", "stay", "stays", "stayed", "staying",
        "work", "works", "worked", "working", "live", "lives", "lived", "living", "meet", "meets", "met",
        "meeting", "eat", "eats", "ate", "eating", "sleep", "slept", "sleeping", "sit", "sat", "sitting",
        "stand", "stood", "standing", "hang", "hung", "hanging", "park", "parked", "land", "landed",
        "arrive", "arrived", "arriving", "play", "plays", "played", "playing", "drop", "dropped", "dropping",
        "pick", "picked", "picking", "grab", "grabbed", "grabbing", "buy", "bought", "buying", "get", "got",
        "getting", "see", "saw", "seen", "seeing", "find", "found", "lose", "lost", "forget", "forgot",
        "forgotten", "keep", "kept", "put", "bring", "brought", "drink", "drank", "shop", "shopped",
        "study", "studied", "waiting", "waited",
    ]

    private static let phraseBreaks: Set<String> = [
        "to", "for", "with", "about", "of", "on", "in", "from", "and", "or", "but", "so", "then",
        "because", "if", "when", "like",
    ]

    /// Verbs whose object can stand between them and "at": "point the camera at", "yelled so loud at".
    private static let aimingVerbs: Set<String> = [
        "look", "looks", "looking", "looked", "stare", "staring", "stared", "glare", "glared", "glaring",
        "smile", "smiled", "smiling", "laugh", "laughed", "laughing", "yell", "yelled", "yelling",
        "shout", "shouted", "shouting", "scream", "screamed", "screaming", "point", "pointed",
        "pointing", "aim", "aimed", "aiming", "throw", "threw", "thrown", "throwing", "toss", "tossed",
        "shoot", "shot", "shooting", "swing", "swung", "wave", "waved", "waving", "wink", "winked",
        "fire", "fired", "hurl", "hurled", "kick", "kicked", "lob", "lobbed", "pass", "passed",
    ]

    private static let prepositionGovernors: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being", "i'm", "im", "you're", "youre", "we're",
        "they're", "theyre", "he's", "she's", "it's", "that's", "there's", "who's", "where's", "here",
        "there", "back", "out", "over", "still", "already", "currently",
        "leave", "leaves", "leaving", "left", "hire", "hired", "hiring", "stop", "stops", "stopped", "stopping",
        "bite", "bit", "bitten", "interview", "interviewed", "interviewing", "excel", "excels", "excelling",
        "work", "works", "working", "worked", "live", "lives", "living", "lived", "stay", "stays",
        "staying", "stayed", "meet", "meets", "meeting", "met", "arrive", "arrives", "arriving", "arrived",
        "eat", "eats", "eating", "ate", "shop", "shops", "shopping", "shopped", "study", "studies",
        "studying", "studied", "intern", "interning", "interned", "sleep", "sleeping", "slept",
        "waiting", "waited", "park", "parked", "parking", "land", "landed", "sit", "sitting",
        "sat", "stand", "standing", "stood", "hang", "hanging", "hung", "speak", "speaking", "spoke",
        "perform", "performing", "performed", "teach", "teaches", "teaching", "taught", "volunteer",
        "volunteering", "volunteered", "available", "sold", "buy", "bought", "order", "ordered",
        "dinner", "lunch", "breakfast", "brunch", "drinks", "coffee", "party", "show", "concert",
        "event", "tickets", "table", "reservation", "appointment", "sale", "deal",
        "account", "card", "bank", "job", "internship", "office", "class", "school", "home",
        "someone", "somebody", "anyone", "everyone", "people", "friends", "student", "students",
        "look", "looks", "looking", "looked", "stare", "stares", "staring", "stared", "glance",
        "glanced", "glancing", "glare", "glared", "glaring", "smile", "smiled", "smiling", "grin",
        "grinned", "laugh", "laughed", "laughing", "yell", "yelled", "yelling", "shout", "shouted",
        "shouting", "scream", "screamed", "screaming", "point", "pointed", "pointing", "aim", "aimed",
        "aiming", "throw", "threw", "thrown", "throwing", "wave", "waved", "waving", "wink", "winked",
        "nod", "nodded", "swing", "swung", "shoot", "shot", "shooting", "snap", "snapped", "snapping",
        "lash", "lashed", "jab", "dig", "hint", "hinted", "hinting", "come", "comes", "coming", "came",
        "get", "gets", "getting", "got", "hit", "hits", "hitting", "mad", "angry", "upset", "annoyed",
        "pissed", "furious", "frustrated", "disappointed", "surprised", "shocked", "good", "bad",
        "great", "better", "best", "worse", "worst", "terrible", "amazing", "awful", "decent",
        "play", "plays", "played", "playing", "impressed", "proud", "jealous", "scared", "afraid",
        "amazed", "offended", "irritated", "embarrassed", "late", "early",
    ]

    private static let objectsAndAdverbs: Set<String> = [
        "it", "this", "that", "them", "him", "her", "me", "us", "one", "something", "stuff",
        "right", "straight", "directly", "back", "over", "up", "down", "out", "again",
    ]

    /// After "at sign", ordinary words that make a phrase rather than a handle.
    private static let signPhrases: Set<String> = [
        "language", "languages", "up", "in", "out", "on", "off", "post", "posts", "board", "boards",
        "there", "key", "button", "and", "or", "to", "of", "is", "for", "with",
    ]

    /// Words that can follow a handle which is also an ordinary word: the start of what is said to
    /// them ("at cold what's up", "at will please read this"). A noun after it ("at cold
    /// temperatures", "at will employment") is not on the list.
    private static let handleFollowers: Set<String> = [
        "i", "i'm", "i'll", "i'd", "i've", "you", "you're", "you'll", "you've", "your", "u", "ur", "we",
        "we're", "we'll", "let's", "lets", "he", "she", "they", "it's", "this", "that", "that's", "these",
        "those", "the", "there", "there's", "here", "here's", "what", "what's", "whats", "who", "who's", "when",
        "where", "where's", "why", "how", "how's", "which", "can", "could", "would", "will", "should",
        "shall", "do", "does", "did", "don't", "dont", "didn't", "are", "is", "was", "were", "have",
        "has", "had", "and", "or", "but", "so", "if", "please", "pls", "plz", "thanks", "thank", "thx",
        "ty", "sorry", "congrats", "welcome", "good", "nice", "great", "gg", "wp", "lol", "lmao", "haha",
        "yo", "hey", "hi", "hello", "bro", "dude", "man", "check", "look", "come", "join", "get", "go",
        "send", "tell", "call", "text", "ping", "make", "take", "help", "stop", "wait", "just", "also",
        "too", "now", "again", "for", "to", "in", "on", "with", "about", "from", "at", "yes", "no",
        "yeah", "nah", "ok", "okay", "real", "fr", "ngl", "tbh", "btw", "imo",
    ]

    /// These can notify a whole channel. Bare "at" never creates them, even if saved.
    static let broadcastHandles: Set<String> = ["everyone", "here"]

    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "my", "your", "our", "their", "his", "her", "its", "every",
        "each", "no", "one", "new", "some", "any",
    ]

    /// First names that, after "at", are a time or a word of the sentence: "at May", "at Dawn".
    private static let nonHandles: Set<String> = [
        "may", "june", "april", "august", "march", "summer", "winter", "autumn", "dawn",
    ]

    /// Levenshtein distance; names are short, so one row is enough.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}

public extension PersonalVocabulary {
    /// Handles taught by saying "at sign" and the handle ("at sign cold"), worth remembering so
    /// "at cold" works next time. First names and the person's words already tag, so they are left out.
    static func handles(taughtIn transcript: String, personalWords: [String] = [], knownHandles: [String] = []) -> [String] {
        var vocabulary: [String: String] = [:]
        for word in BuiltInVocabulary.withNames(personalWords) { vocabulary[word.lowercased()] = word }
        let taught = SpokenMentions.mark(transcript, bare: false, vocabulary: vocabulary, handles: knownHandles).handles.map { String($0.dropFirst()) }
        // @everyone and @here are written every time they are said; saving them adds nothing.
        return normalizedHandles(taught.filter {
            $0.count >= 2 && !SpokenMentions.firstNames.contains($0) && vocabulary[$0] == nil
                && !SpokenMentions.broadcastHandles.contains($0)
        })
    }

    /// Remembers the handles a dictation taught, in the shared store and off the caller's thread.
    static func learnHandles(taughtIn transcript: String, renderedText: String, personalWords: [String], knownHandles: [String]) {
        // Only learn what was actually emitted. Literal/code spans can contain "at sign" too.
        let taught = handles(taughtIn: transcript, personalWords: personalWords, knownHandles: knownHandles).filter { handle in
            let pattern = "(?<![\\p{L}\\p{N}_])@" + NSRegularExpression.escapedPattern(for: handle) + "(?![\\p{L}\\p{N}_])"
            return renderedText.range(of: pattern, options: .regularExpression) != nil
        }
        guard !taught.isEmpty else { return }
        learning.async { _ = try? shared?.addHandles(taught) }
    }

    private static let learning = DispatchQueue(label: "wtf.zayd.zone.handles", qos: .utility)
}
