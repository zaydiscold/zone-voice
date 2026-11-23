// by zayd/cold @ zayd.wtf

import Foundation

/// How a dictation's first letter is cased at the cursor.
public enum DictationOpening: Sendable, Equatable {
    /// The field's auto-capitalization and the text before the cursor decide.
    case automatic
    /// Shift showed a capital: the first letter is one, wherever the cursor is.
    case capital
    /// Shift showed lowercase: a plain first word is lowered, even at a sentence start. Names, "I",
    /// acronyms, mixed case and personal words keep their capitals.
    case lowercase
    /// Shift was locked (tapped twice): the whole dictation is written in capitals, as typing
    /// with caps lock would. Links, emails and other literals keep their spelling.
    case capsLock
}

/// How a transcript is shaped before insertion. Rule-based, no language model: the recognizer's
/// wording is preserved except for explicit hesitation tokens in every style.
/// Literal spellings remain intact while prose casing and punctuation follow the style.
public enum TextStyle: String, Codable, CaseIterable, Sendable {
    /// Caps and less punctuation: as recognized, without the final period. How people text.
    case casual
    /// All lowercase, commas and periods gone, questions keep their mark.
    case veryCasual
    /// As recognized, first letter capitalized, ends with a period.
    case formal
    /// Sentences end with an exclamation mark.
    case excited

    /// The name shown in the keyboard's style row and in Settings. Capitalized like every other
    /// choice in the app; Formal and Excited keep the mark they end sentences with.
    public var label: String {
        switch self {
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .formal: return "Formal."
        case .excited: return "Excited!"
        }
    }

    /// Whether insertion may capitalize the start of a sentence when the field asks for it. Very
    /// casual is all lowercase by design, so the field's capitals must not undo it.
    public var allowsSentenceCapitals: Bool { self != .veryCasual }

    /// The style's text joined at the cursor: the style decides casing, the field only adds capitals
    /// where the style allows them. `opening` is the keyboard's Shift key when the user wants the
    /// first letter to follow it; `.automatic` leaves the decision to the field and the context.
    /// `mentions` writes a spoken "at Kevin" as the handle "@kevin" (`SpokenMentions`); `handles` are
    /// the person's own (`PersonalVocabulary.handles`). `spokenCorrections` lets "scratch that" and
    /// "no wait" remove words (`SpokenRepair`); it is a Beta setting, off unless the person turns it on.
    /// `capsLockDropsPunctuation` (Beta, off by default) makes a caps-lock dictation also leave out
    /// commas, periods and apostrophes, the way people shout in a chat; ? and ! stay.
    /// `emoticons` writes a said "smiley face" as ":)" in the texting styles (`SpokenEmoticons`).
    /// `smallOrdinals` (Experimental, off by default) also writes first through ninth as 1st to
    /// 9th where they rank something; 10th and up are always digits (`SpokenOrdinals`).
    /// `california` removes the filler "like" (`CaliforniaMode`); also Beta, and off by default.
    /// `searchField` is a search bar or address bar: the words are a query, so the period or
    /// exclamation mark a style ends on is left off ("Amazon." finds nothing in Passwords).
    public func insertion(of transcript: String, contextBefore: String?, fieldCapitalizesSentences: Bool,
                          personalWords: [String] = [], opening: DictationOpening = .automatic,
                          mentions: Bool = false, handles: [String] = [], systemWords: [String] = [],
                          spokenCorrections: Bool = false, capsLockDropsPunctuation: Bool = false,
                          emoticons: Bool = true, smallOrdinals: Bool = false, california: CaliforniaMode = .off,
                          searchField: Bool = false, misheard: [String: String] = [:]) -> String {
        let text = insertion(of: transcript, contextBefore: contextBefore, fieldCapitalizesSentences: fieldCapitalizesSentences,
                             personalWords: personalWords, opening: opening, mentions: mentions, handles: handles,
                             systemWords: systemWords, spokenCorrections: spokenCorrections,
                             capsLockDropsPunctuation: capsLockDropsPunctuation, emoticons: emoticons, smallOrdinals: smallOrdinals,
                             california: california, misheard: misheard)
        guard searchField else { return text }
        // A question keeps its mark, and an ellipsis is not an ending.
        var query = Substring(text)
        while let last = query.last, last == "." || last == "!", !query.hasSuffix("..") { query.removeLast() }
        return query.contains(where: { $0.isLetter || $0.isNumber }) ? String(query) : text
    }

    private func insertion(of transcript: String, contextBefore: String?, fieldCapitalizesSentences: Bool,
                           personalWords: [String], opening: DictationOpening,
                           mentions: Bool, handles: [String], systemWords: [String],
                           spokenCorrections: Bool, capsLockDropsPunctuation: Bool,
                           emoticons: Bool, smallOrdinals: Bool, california: CaliforniaMode, misheard: [String: String]) -> String {
        let ownWords = personalWords
        let personalWords = BuiltInVocabulary.withNames(personalWords + SystemLexiconSpelling.formattingWords(systemWords))
        // Let the joiner decide sentence boundaries, but capitalize before restoring literals.
        // Otherwise a URL or mixed-case identifier at the beginning of a field gets modified.
        let capitalizes: Bool
        switch opening {
        case .automatic:
            capitalizes = fieldCapitalizesSentences && allowsSentenceCapitals &&
                TextJoiner.join(contextBefore: contextBefore, transcript: "a", capitalizeSentences: true).hasSuffix("A")
        case .capital, .capsLock: capitalizes = allowsSentenceCapitals
        case .lowercase: capitalizes = false
        }
        let continues = Self.continuesSentence(contextBefore)
        var prepared = transform(transcript, capitalize: capitalizes, ownWords: ownWords, capsLock: opening == .capsLock,
                                 continuesSentence: continues, mentions: mentions, handles: handles, systemWords: systemWords,
                                 wordsBefore: continues ? Self.lastWords(of: contextBefore) : [],
                                 spokenCorrections: spokenCorrections, emoticons: emoticons, smallOrdinals: smallOrdinals, california: california,
                                 misheard: misheard)
        // Continuing mid-sentence: the model still capitalizes its first word ("And so..."), so
        // a second dictation after a stop read "...it works And so". Lower it when the text
        // before the cursor says a sentence is in progress and the word is plain English.
        // A lowercase Shift asks for the same everywhere, the top of an empty field included.
        if !capitalizes, continues || opening == .lowercase {
            prepared.text = Self.lowercasingFirstWord(prepared.text, keeping: personalWords)
        }
        if opening == .capsLock {
            prepared.text = Self.shouting(prepared.text, droppingPunctuation: capsLockDropsPunctuation)
            // My words and names are restored with their saved spelling after this, so they are
            // capitalized here: "TELL ZAYD", as typing with caps lock would. A handle ("@cold"),
            // a mark or a face starts with something other than a letter and keeps its spelling.
            for index in prepared.tokens.indices where prepared.tokens[index].value.first?.isLetter == true {
                prepared.tokens[index].value = prepared.tokens[index].value.uppercased()
            }
        }
        let joined: String
        if prepared.startsList, let contextBefore,
           contextBefore.reversed().prefix(while: { $0 != "\n" && $0 != "\r" }).contains(where: { !$0.isWhitespace }) {
            // An explicit list begins a new block. Existing blank/indented lines already provide
            // its boundary; do not add a second newline or rewrite text before the cursor.
            joined = "\n" + prepared.text
        } else {
            joined = prepared.suppressesLeadingSpace ? prepared.text : TextJoiner.join(
                contextBefore: contextBefore, transcript: prepared.text, capitalizeSentences: false)
        }
        return prepared.restore(joined)
    }

    /// Caps lock: every letter a capital. Placeholders for links and other literals carry no
    /// letters, so they survive and are restored with their own spelling. With
    /// `droppingPunctuation`, commas, apostrophes, semicolons and sentence-ending periods go
    /// too ("WHAT, NO WAY." becomes "WHAT NO WAY"); a period inside a number or a question or
    /// exclamation mark stays.
    static func shouting(_ text: String, droppingPunctuation: Bool) -> String {
        // Links, emails, handles, paths and version numbers are literals, not shouting.
        let protected = ProtectedText(text)
        var result = protected.masked.uppercased()
        if droppingPunctuation {
            // A face is a mark, not punctuation: ";)" and ":'(" (`SpokenEmoticons`) keep theirs.
            result = result.replacingOccurrences(of: #",|;(?!\)(?:\s|$))|(?<!:)['’]|['’](?!\()"#, with: "",
                                                 options: .regularExpression)
            result = result.replacingOccurrences(of: #"\.(?=\s|$)"#, with: "", options: .regularExpression)
            result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return protected.restore(result)
    }

    public var next: TextStyle {
        let all = TextStyle.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    public func apply(_ text: String, personalWords: [String] = [], mentions: Bool = false,
                      handles: [String] = [], systemWords: [String] = [], spokenCorrections: Bool = false,
                      emoticons: Bool = true, smallOrdinals: Bool = false, california: CaliforniaMode = .off,
                      misheard: [String: String] = [:]) -> String {
        let prepared = transform(text, capitalize: allowsSentenceCapitals, ownWords: personalWords,
                                 mentions: mentions, handles: handles, systemWords: systemWords,
                                 spokenCorrections: spokenCorrections, emoticons: emoticons, smallOrdinals: smallOrdinals, california: california,
                                 misheard: misheard)
        return prepared.restore(prepared.text)
    }

    /// Name spelling only, before a user transcript is saved; no style or punctuation changes.
    public static func correctingSystemVocabulary(_ text: String, systemWords: [String],
                                                   personalWords: [String] = [], mentions: Bool = false) -> String {
        guard !systemWords.isEmpty else { return text }
        let words = SystemLexiconSpelling.formattingWords(systemWords)
        guard !words.isEmpty else { return text }
        let protected = ProtectedText(text)
        let corrected = SystemLexiconSpelling.correct(protected.masked,
            words: words, explicitWords: personalWords, mentions: mentions)
        return protected.restore(corrected)
    }

    /// `ownWords` are the person's words; the built-in names are added here.
    private func transform(_ text: String, capitalize: Bool, ownWords: [String], capsLock: Bool = false,
                           continuesSentence: Bool = false, mentions: Bool = false,
                           handles: [String] = [], systemWords: [String] = [],
                           wordsBefore: [String] = [], spokenCorrections: Bool = false,
                           emoticons: Bool = true, smallOrdinals: Bool = false, california: CaliforniaMode = .off,
                           misheard: [String: String] = [:]) -> SpokenFormatting.Result {
        let surnames = ContactSurnames.candidates(systemWords)
        let systemWords = SystemLexiconSpelling.formattingWords(systemWords)
        let personalWords = BuiltInVocabulary.withNames(ownWords + systemWords)
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A word spelled with periods ("D. A.N.") is joined before anything reads those periods
        // as sentence ends or abbreviations.
        trimmed = SpelledLetters.joiningDotted(trimmed, personalWords: personalWords)
        // "U.S.A." is written "USA", the way people text it (Zayd, November 15).
        trimmed = SpelledLetters.droppingAbbreviationPeriods(trimmed)
        // Spoken repairs read the recognizer's own punctuation, so they run before casual drops
        // its commas ("Tuesday, scratch that, Wednesday"), and before literals are masked, which
        // would hide "4.30" from the clock-time pass. None of them can change a word with no
        // space in it, so a URL or path is never edited. Self-corrections remove words, so they
        // run only when the person turned them on; stutters and clock times always run.
        if spokenCorrections {
            trimmed = SpokenRepair.applyingSelfCorrections(trimmed, isPlainCommonWord: Self.isPlainCommonWord)
        }
        // Ordinals first, so "twenty first" is 21st and not "20 first".
        trimmed = SpokenOrdinals.writing(SpokenRepair.collapsingStutters(trimmed), small: smallOrdinals)
        trimmed = SpokenRepair.americanClockTimes(SpokenNumbers.writingDigits(trimmed))
        // A recording stopped mid-sentence ends "I went to the." and a long one cut there reads
        // "the. My dog". That period is the recognizer's guess at the end of the audio.
        trimmed = Self.joiningUnfinishedSentences(trimmed, keeping: personalWords)
        let protected = ProtectedText(trimmed)
        var prose = protected.masked
        // California Mode reads the recognizer's commas ("it was, like, so good"), so it runs before
        // casual drops them, and after masking, so a "like" in a URL or code is never touched.
        // It removes words, so it runs only when the person turned it on.
        if california != .off {
            prose = california.tapering(prose, wordsBefore: wordsBefore, continuesSentence: continuesSentence,
                                        keeping: ownWords)
        }
        if self == .casual || self == .veryCasual {
            prose = Self.normalizingCasualProse(prose, keeping: ownWords)
        }
        // Casual drops the commas the recognizer adds at every breath. This runs before spoken
        // commands are expanded, so a comma said out loud ("comma") still lands.
        // Fillers go first there: "think, for um, lunch?" must be judged as the two-part
        // sentence it becomes, not as a three-item list, or a second pass changes it again.
        var source = self == .casual
            ? Self.droppingRecognizerCommas(Self.removingFillers(prose)) : prose
        // A misheard personal word ("Dahlson" for Dahlsson) takes the stored spelling before
        // commands and casing run; literal spans are already masked. Built-in names are matched
        // only from their listed mishearings, so a stranger's Zahid is not turned into Zayd.
        source = SystemLexiconSpelling.correct(source, words: systemWords, explicitWords: ownWords, mentions: mentions)
        if !ownWords.isEmpty {
            source = PersonalWordMatcher(words: ownWords, rank: Self.personalWordRank).correct(source)
        }
        // What the person retyped right after an earlier dictation ("Versailles" as "Vercel").
        source = PersonalVocabulary.applyingMisheard(source, misheard, rank: Self.wordRank)
        source = BuiltInVocabulary.correctingMishearings(source, personalWords: ownWords + systemWords + handles)
        // Casual is how people text: a company's name is spelled right but takes no capital
        // ("openai", "claude code"). Formal and excited write it the company's way.
        source = ModernVocabulary.correcting(source, personalWords: ownWords + systemWords + handles,
                                             lowercaseNames: self == .casual || self == .veryCasual)
        // "Sarah Brown" is then one name, kept whole by the styles that lowercase prose.
        let named = ContactSurnames.capitalizing(source, surnames: surnames)
        source = named.text
        // "quote hello quote" and the recognizer's "on quote" become the commands below.
        source = SpokenQuotes.normalizing(source)
        var formatted = SpokenFormatting.process(source, personalWords: personalWords + named.names, continuesSentence: continuesSentence,
                                                 mentions: mentions, handles: handles, wordsBefore: wordsBefore,
                                                 spellsInCapitals: capsLock)
        // Hesitation cleanup is independent of presentation style. A formal message should
        // not retain "um" solely because it uses standard punctuation. Literal spans and
        // canonical personal terms were protected before this shared cleanup step.
        // Trimmed so a dropped leading comma (", see you") cannot leave a space where the
        // capital belongs.
        var out = Self.collapsingDoubledEndings(Self.removingFillers(formatted.text)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Speech models trained on internet text write "IDK" for spoken "I don't know". A person
        // saying the words wants the words; spelling the letters gives lowercase "idk", kept.
        out = Self.idkExpression.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "I don't know")
        // A word spelled out loud ("D-A-A-N") is the word. Spoken commands and handles have
        // already taken the letters meant for them ("at D A A N", "spell ... end spelling").
        out = Self.joiningTextingLetters(SpelledLetters.joining(out, personalWords: personalWords))
        // Small models write the pronoun lowercase mid-sentence ("battery i want numbers").
        if self != .veryCasual { out = Self.capitalizingPronounI(out) }
        // "etc" is never a proper noun; models write "Etc" and "ETC" (literals already masked).
        out = Self.etcExpression.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "etc")
        out = Self.loweringRecognizerRestarts(out)
        formatted.refreshBoundaries(after: out)
        guard !out.isEmpty else { formatted.text = ""; return formatted }
        if capitalize, !protected.startsWithLiteral {
            out = Self.capitalizeFirst(out)
        }
        // Formal writing starts every sentence with a capital. The recognizer often leaves the
        // second sentence of a dictation lowercase; the texting styles keep that as said.
        if self == .formal || self == .excited { out = Self.capitalizingSentences(out) }
        switch self {
        case .formal:
            if !protected.endsWithLiteral && !formatted.endsWithToken && !Self.endsUnfinished(out) {
                out = Self.ensureEnding(out, with: ".")
            }
        case .excited:
            // Every sentence is excited, not only the last: a period before the next sentence
            // becomes an exclamation mark. Ellipses, numbers and abbreviations (masked) stay.
            out = Self.innerSentenceStop.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "!")
            if !protected.endsWithLiteral && !formatted.endsWithToken && !Self.endsUnfinished(out) {
                out = Self.ensureEnding(out, with: "!")
            }
        case .casual:
            out = Self.droppingFinalPeriod(Self.texting(Self.relaxedCasual(out)))
        case .veryCasual:
            out = out.lowercased().replacingOccurrences(
                of: #"(?<!\.)[.,](?!\.)(?=\s|["'”’\)\]}]*$)"#,
                with: "", options: .regularExpression)
            out = Self.texting(out)
        }
        if self == .casual || self == .veryCasual {
            // Dropping a stray mark (" ." at the end, ". " at the start) must not leave its space
            // behind: the next dictation would join after it with a double space. Spoken newlines
            // are still placeholders here, so only real spaces go.
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if self != .veryCasual {
            out = Self.adjustingCase(afterSpokenMarks: formatted.tokens, in: out, personalWords: personalWords,
                                     textingStyle: self == .casual)
        }
        // Texting writes a said "smiley face" as the face. Last, so no casing pass touches it.
        if emoticons, self == .casual || self == .veryCasual { out = SpokenEmoticons.writing(out) }
        var restored = protected.restore(out)
        // "a.m." is masked as an abbreviation above, so the texting styles write it here.
        if self == .casual || self == .veryCasual {
            let written = Self.textingMeridiem(restored, dottedOnly: true)
            // "7 a.m." closing a casual message was a literal, so its dot outlived the casual
            // ending; now that it is "7 am." the dot is the sentence's period and goes.
            if self == .casual, written != restored, Self.endsWithMeridiem(written) {
                restored = Self.droppingFinalPeriod(written)
            } else {
                restored = written
            }
        }
        formatted.text = restored
        return formatted
    }

    /// A small texting vocabulary, not a rule for acronyms in general. Literal syntax and
    /// personal terms have already been masked, so their intentional casing stays intact.
    private static let casualAcronymWords = "smh|tbh|lol|lmao|rofl|idk|ikr|imo|imho|omg|btw|fwiw|brb|ttyl|ngl|wtf|omfg|lmk|nvm|istg|tldr|fyi"
    private static let casualAcronyms = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])(?:"# + casualAcronymWords + #")(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])
    /// Texting shorthand said as letters, which the recognizer writes in capitals: "TS", "FR", "AI".
    /// Lowercase in casual like the list above, but only from capitals, so the names Ty and Al
    /// and the words "af" and "og" in another language are never touched.
    private static let casualCapitalAcronyms = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-.])(?:TS|PMO|FR|AI|WYD|HMU|ILY|ILYSM|JK|OMW|TY|TYSM|IDC|IDGAF|IDEK|STFU|LMFAO|WYA|IYKYK|IRL|DMs?|GG|AF|ASAP|ONG|ICL|POV|FOMO|YOLO|TMI|BFF|OG|GOAT|HBU|WBU|NBD|OFC|TBF|FML|SMFH|IMY|SYBAU|GNG|WTV|WTH|BFFR)(?![\p{L}\p{N}_'’\-.])"#)

    /// Two letters said as shorthand arrive as "T-S" or "T S". A hyphenated pair that is one of
    /// the acronyms above is joined; spaced, only "T S", which is nothing else.
    private static let textingLetterPair = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-.])(?:(?:T-S|F-R|A-I|D-M|G-G|O-G|T-Y|J-K|A-F)|T S(?=[ \t]+\p{Ll}|[.,!?]|$))(?![\p{L}\p{N}_'’\-])"#)

    static func joiningTextingLetters(_ text: String) -> String {
        var out = text
        for match in textingLetterPair.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: out[range].filter { $0.isLetter })
        }
        return out
    }

    /// How people text "imma" and "y'all": no apostrophe, lowercase even at the start, like "lol".
    /// The recognizer writes "I'ma", "I'mma", "Imma" or "Y'all", "Ya'll". A bare "Ima" counts only
    /// before a lowercase word ("Ima go"), so the name in "Ima Hogg" or "I told Ima" stays.
    private static let textingImma = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])(?:i(?:['’]m{1,2}|mm|m['’]m)a|(?:(?-i:ima)|(?:^|(?<=[.!?]\s)|(?<=\n))(?-i:Ima))(?-i:(?=[ \t]+\p{Ll})))(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])
    private static let textingYall = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])y(?:['’]?a|a['’])ll(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])

    static func texting(_ text: String) -> String {
        var out = textingImma.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "imma")
        out = textingYall.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "yall")
        return textingMeridiem(out)
    }

    /// "7 AM", "7 A.M." and "7 a.m." after a number, captured: the letters, then a dot after them.
    private static let meridiem = try! NSRegularExpression(
        pattern: #"(?<=\d)([ \t]?)([AaPp])\.?([Mm])(\.?)(?![\p{L}\p{N}_])"#)
    /// Only the dotted forms, which `ProtectedText` keeps whole as an abbreviation until the end.
    private static let dottedMeridiem = try! NSRegularExpression(
        pattern: #"(?<=\d)([ \t]?)([AaPp])\.([Mm])(\.?)(?![\p{L}\p{N}_])"#)

    /// People text the time as "7 am" and "12:45 pm", not "7 AM" or "7 a.m.". Only after a number,
    /// so the PM who runs the project keeps the capitals. A dot that also ended the sentence
    /// ("at 7 a.m. Then") stays as the sentence's period.
    static func textingMeridiem(_ text: String, dottedOnly: Bool = false) -> String {
        let ns = text as NSString
        var out = text
        let expression = dottedOnly ? dottedMeridiem : meridiem
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let space = ns.substring(with: match.range(at: 1))
            let letter = ns.substring(with: match.range(at: 2)).lowercased()
            let dotted = match.range(at: 4).length > 0
            let rest = ns.substring(from: match.range.location + match.range.length)
            let endsSentence = dotted && (rest.isEmpty || rest.range(of: #"^[\s"'”’\)\]}]*(?:$|\p{Lu})"#, options: .regularExpression) != nil)
            let replacement = space + letter + "m" + (endsSentence ? "." : "")
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    static func endsWithMeridiem(_ text: String) -> Bool {
        text.range(of: #"\d[ \t]?[ap]m\.[\s"'”’\)\]}]*$"#, options: .regularExpression) != nil
    }

    /// Casual ends without a period. Ellipses keep all their dots.
    static func droppingFinalPeriod(_ text: String) -> String {
        var out = text
        let end = contentEnd(in: out)
        guard end > out.startIndex else { return out }
        let last = out.index(before: end)
        if out[last] == ".", (last == out.startIndex || out[out.index(before: last)] != ".") {
            out.remove(at: last)
        }
        return out
    }

    /// "work?." and "now!.": a model that wrote the question mark sometimes adds the period it
    /// writes after every sentence. An ellipsis after the mark ("what?...") is left alone.
    private static let doubledEnding = try! NSRegularExpression(pattern: #"([?!])\.(?!\.)"#)

    static func collapsingDoubledEndings(_ text: String) -> String {
        doubledEnding.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    private static let optionalOpeningComma = try! NSRegularExpression(
        pattern: #"^(okay|yeah|yep|smh|tbh|lol|lmao|idk|ikr|imo|imho|omg|btw|fwiw|ngl),([ \t]+)(?=(?:I|we|you|it|that|this)\b)"#,
        options: [.caseInsensitive])

    /// Texting has almost no commas. A sentence keeps its commas when they form a list (two or
    /// more short comma-separated items, with or without a closing "and"/"or"); otherwise a
    /// comma followed by a space goes, except where it carries meaning: between a day and a
    /// year ("November 1, 2026"), in digit groups (no space, untouched), and before a capitalized
    /// place or name ("Paris, France").
    static func droppingRecognizerCommas(_ text: String) -> String {
        guard text.contains(",") else { return text }
        var out = ""
        var sentence = ""
        func flush() {
            defer { sentence = "" }
            guard sentence.contains(",") else { out += sentence; return }
            if Self.isList(sentence) { out += sentence; return }
            out += Self.optionalCommaExpression.stringByReplacingMatches(
                in: sentence, range: NSRange(sentence.startIndex..., in: sentence), withTemplate: "")
        }
        for character in text {
            sentence.append(character)
            if character == "." || character == "?" || character == "!" || character == "\n" { flush() }
        }
        flush()
        return out
    }

    /// A comma plus space, unless a 4-digit year or a capitalized word (not "I", not a texting
    /// acronym such as "LOL", which casual lowers anyway) follows.
    private static let optionalCommaExpression = try! NSRegularExpression(
        pattern: #",(?=\s)(?!\s+\d{4}\b)(?!\s+(?!I\b)(?!(?i:"# + casualAcronymWords + #")(?![\p{L}\p{N}_'’\-]))\p{Lu})"#)

    /// Spoken asides that string together with commas but are not list items. Texting acronyms
    /// are asides too: "TBH, I don't care, LOL" is not a three-item list.
    private static let discourseWords: Set<String> = Set(["okay", "ok", "so", "yeah", "yep", "well", "honestly", "like",
        "right", "anyway", "basically", "actually", "fine", "great", "sure", "cool", "i think", "i mean", "you know", "hey", "hi"])
        .union(casualAcronymWords.split(separator: "|").map(String.init))

    private static func isList(_ sentence: String) -> Bool {
        let parts = sentence.components(separatedBy: ", ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        }
        guard parts.count >= 2, let first = parts.first?.split(separator: " ").last.map(String.init),
              !discourseWords.contains(first), !discourseWords.contains(parts[0]) else { return false }
        let last = parts[parts.count - 1]
        let closes = last.hasPrefix("and ") || last.hasPrefix("or ") || last.contains(" and ") || last.contains(" or ")
        // Middle items are short; a list is three or more items, or two closed by and/or.
        let shortMiddle = parts.dropFirst().dropLast().allSatisfy { $0.split(separator: " ").count <= 3 }
        return shortMiddle && (parts.count >= 3 && (closes || parts.allSatisfy { $0.split(separator: " ").count <= 3 })
                               || (parts.count == 2 && closes && parts[1].split(separator: " ").count <= 5))
    }

    /// True when there is text before the cursor and it does not end a sentence.
    /// The last few words of an unfinished sentence before the cursor, lowercase, so "at" in a
    /// second dictation is read with the first ("I'm looking" + "at Kevin").
    static func lastWords(of contextBefore: String?, count: Int = 4) -> [String] {
        guard let contextBefore else { return [] }
        let line = contextBefore.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        return line.split(whereSeparator: \.isWhitespace).suffix(count).map {
            $0.lowercased().replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
        }.filter { !$0.isEmpty }
    }

    static func continuesSentence(_ contextBefore: String?) -> Bool {
        guard let contextBefore else { return false }
        let trimmed = contextBefore.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !last.isNewline else { return false }
        return !".!?".contains(last)
    }

    static func lowercasingFirstWord(_ text: String, keeping personalWords: [String]) -> String {
        // transform has already restored literal spans. Mask them again for this final cursor
        // casing pass so Hello.com and A.B. cannot be mistaken for ordinary opening words.
        let protected = ProtectedText(text)
        let lowered = lowercasingFirstWord(protected.masked, keeping: personalWords) {
            isPlainCommonWord($0) && !givenNames.contains($0)
        }
        return protected.restore(lowered)
    }

    /// Lowers the first word when it is capitalized prose ("And", not "NASA", "iPhone", "I'm",
    /// a personal word or a name) and `allowed` accepts its lowercase form.
    private static func lowercasingFirstWord(_ text: String, keeping personalWords: [String],
                                             when allowed: (String) -> Bool) -> String {
        // Only skip opening prose punctuation. Never skip a literal/command placeholder,
        // a number or a list marker and accidentally change the text that follows it.
        let start = openingWordStart(in: text)
        guard start < text.endIndex, text[start].isUppercase else { return text }
        let word = String(text[start...].prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        guard word.count > 1 || word == "A",
              word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text } // NASA, iPhone
        let bare = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if bare == "i" || bare.hasPrefix("i'") || bare.hasPrefix("i’") { return text }
        if personalWords.contains(where: { $0.lowercased().replacingOccurrences(of: "’", with: "'") == bare }) { return text }
        // A possessive is judged by its word: "Friend's" comes down, "Mark's" stays.
        let stem = bare.hasSuffix("'s") ? String(bare.dropLast(2)) : bare
        guard allowed(bare) || (stem != bare && allowed(stem)) else { return text } // Likely a name.
        return String(text[..<start]) + text[start].lowercased() + text[text.index(after: start)...]
    }

    /// The pronoun "I" and its contractions (i'm, i'll, i'd, i've) written in capitals, as a
    /// whole word only: never "i.e.", "iPhone", "Wi-Fi", a path or a handle.
    public static func capitalizingPronounI(_ text: String) -> String {
        pronounI.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "I")
    }

    private static let pronounI = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-./@#:])i(?=(?:['’](?:m|ll|d|ve)\b)?(?![\p{L}\p{N}_\-@/])(?!\.\p{L}))"#)

    private static let idkExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])IDK(?![\p{L}\p{N}_'’\-])"#)

    /// Ordinary English the dictionary writes in lowercase: "then", not "Paris" or "Monday".
    static func isPlainCommonWord(_ word: String) -> Bool {
        guard let entry = commonWords?.lookup(word), entry.rank < 40_000 else { return false }
        return entry.display.first?.isUppercase != true
    }

    /// Words that are never names, so a capital on one after a spoken comma is always the
    /// recognizer's sentence guess. Other common words ("John" is "john" in the list) are only
    /// lowered when the recognizer also put its own sentence end around the spoken mark.
    /// A capitalized word that opens a sentence rather than continuing a name: "It", "The", "I".
    static func opensSentence(_ word: String) -> Bool {
        let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
        return lower == "i" || lower.hasPrefix("i'") || closedClassWords.contains(lower)
    }

    private static let closedClassWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "so", "yet", "then", "because", "if", "when",
        "while", "although", "though", "unless", "since", "that", "which", "who", "whom", "whose",
        "what", "where", "why", "how", "this", "these", "those", "it", "it's", "its", "he", "she",
        "we", "they", "you", "me", "him", "her", "us", "them", "my", "your", "his", "our", "their",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had",
        "can", "could", "would", "should", "shall", "may", "might", "must", "not", "no", "yes",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "as", "into", "like",
        "just", "also", "too", "maybe", "please", "there", "here", "now", "still", "even", "very",
        "really", "actually", "otherwise", "however", "therefore", "plus", "let's", "i'll", "we're",
        "you're", "they're", "that's", "there's", "he's", "she's", "we'll", "you'll", "don't",
        "didn't", "can't", "won't", "isn't", "wasn't", "okay", "ok", "well", "oh", "see"]

    /// A speaker who restarts ("so this was, this was one of those times") often gets the second
    /// start written as a new sentence with no mark before it: "so this was This was". A capital
    /// right after an all-lowercase word, with no punctuation between, is the recognizer's sentence
    /// guess when the word can never be a name and the sentence carries on in lowercase or with
    /// "I" ("I went home Then I slept"). "The Office", "It Follows" and "I love This Is Us so much"
    /// keep theirs (the next word, or the word before, is capitalized), "in May" is not on the list
    /// and a lone "A" is a label ("options A and B"). After a comma a capital stays: in 7 MB of
    /// edited books that was verse, titles and deliberate capitals, and 984 recognized dictations
    /// never wrote a restart that way. Literal spans and spoken marks are masked, so they never
    /// look like a lowercase word.
    static func loweringRecognizerRestarts(_ text: String) -> String {
        let source = text as NSString
        var out = text
        for match in restartCapital.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let range = match.range(at: 1)
            let word = source.substring(with: range)
            let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
            guard closedClassWords.contains(lower), !namesAmongClosedClass.contains(lower),
                  lower != "i", !lower.hasPrefix("i'"), // The pronoun stays a capital.
                  let swap = Range(range, in: out) else { continue }
            out.replaceSubrange(swap, with: word.prefix(1).lowercased() + word.dropFirst())
        }
        return out
    }

    /// Words a sentence cannot end on: articles, possessive determiners and "and"/"or". English
    /// does end sentences on prepositions ("what is it for") and on "his" and "her" ("it's
    /// his"), so those are left out.
    static let unfinishedEndings: Set<String> = ["a", "an", "the", "my", "your", "our", "their", "its", "and", "or", "nor"]

    /// Whether `word`, the last before a period, leaves the sentence unfinished. A capital
    /// "A" is a letter ("plan A") and "oh my" is complete.
    static func isUnfinishedEnding(_ word: Substring, after previous: Substring?) -> Bool {
        let lower = word.lowercased()
        // "A" is a letter and "AN" or "MY" an acronym, so only lowercase or a leading capital.
        guard unfinishedEndings.contains(lower), word != "A", word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return false }
        if lower == "my", let previous, ["oh", "my"].contains(previous.lowercased()) { return false }
        return true
    }

    /// True when the text ends on an unfinished word, with no mark after it, so formal and
    /// excited styles do not add one: the next dictation continues the sentence.
    static func endsUnfinished(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") })
        guard let last = words.last, text.last?.isLetter == true else { return false }
        // A whole word only: the "a" of "n/a" or "x.a" is not an article.
        if last.startIndex > text.startIndex, !text[text.index(before: last.startIndex)].isWhitespace { return false }
        return isUnfinishedEnding(last, after: words.dropLast().last)
    }

    /// Drops a recognizer period after an unfinished word ("to the." becomes "to the") and
    /// lowers the plain word it capitalized after it ("the. My dog" becomes "the my dog").
    /// Before a name, "I", an acronym or a personal word the period stays.
    static func joiningUnfinishedSentences(_ text: String, keeping personalWords: [String]) -> String {
        guard text.contains(".") else { return text }
        let source = text as NSString
        var out = text
        for match in unfinishedStop.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let word = source.substring(with: match.range(at: 2))
            let previous: Substring? = match.range(at: 1).location == NSNotFound ? nil : Substring(source.substring(with: match.range(at: 1)))
            guard isUnfinishedEnding(Substring(word), after: previous),
                  let stop = Range(match.range(at: 3), in: out) else { continue }
            let after = String(out[stop.upperBound...])
            let rest = lowercasingFirstWord(after, keeping: personalWords) {
                isPlainCommonWord($0) && !givenNames.contains($0)
            }
            // A name or "I" after it reads as a restart ("I went to the. Mark said no"): kept.
            if rest == after, after.first(where: { !$0.isWhitespace })?.isUppercase == true { continue }
            out = String(out[..<stop.lowerBound]) + rest
        }
        return out
    }

    private static let unfinishedStop = try! NSRegularExpression(
        pattern: #"(?:(\p{L}+)[ \t]+)?(?<![\p{L}\p{N}_'’\-./@#])(\p{L}+)(\.)(?=[ \t]|$)"#)

    /// Closed-class words that are also names or months, so a capital may be meant.
    private static let namesAmongClosedClass: Set<String> = ["may", "will", "see"]

    /// The whole previous word is lowercase (so "This Is Us" is not "is Us"); the capital is group 1;
    /// the next word is lowercase or the pronoun "I", which is never a sign of a title.
    private static let restartCapital = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’])\p{Ll}[\p{Ll}'’]*[ \t]+(\p{Lu}\p{Ll}+(?:['’]\p{Ll}+)?)(?=[ \t]+(?:\p{Ll}|I(?:['’]\p{Ll}+)?(?![\p{L}\p{N}])))"#)

    /// After a spoken comma, semicolon or colon the next word continues the sentence, so a
    /// recognizer capital there comes down; after a spoken period, question mark or
    /// exclamation mark a new sentence starts with a capital. Literals are still masked, so a
    /// URL or code span after a mark keeps its spelling.
    private static func adjustingCase(afterSpokenMarks tokens: [SpokenFormatting.Token], in text: String,
                                      personalWords: [String], textingStyle: Bool) -> String {
        guard tokens.contains(where: { [",", ";", ":", ".", "?", "!"].contains($0.value) }) else { return text }
        var out = ""
        var cursor = text.startIndex
        for (index, token) in tokens.enumerated() where [",", ";", ":", ".", "?", "!"].contains(token.value) {
            guard let marker = text.range(of: token.marker, range: cursor..<text.endIndex) else { continue }
            var wordStart = marker.upperBound
            // A spoken line break after the mark ("period new line next") still starts a sentence.
            var next = index + 1
            while true {
                while wordStart < text.endIndex, text[wordStart] == " " || text[wordStart] == "\t" {
                    wordStart = text.index(after: wordStart)
                }
                guard next < tokens.count, tokens[next].value.allSatisfy(\.isWhitespace),
                      text[wordStart...].hasPrefix(tokens[next].marker) else { break }
                wordStart = text.index(wordStart, offsetBy: tokens[next].marker.count)
                next += 1
            }
            let wordEnd = text[wordStart...].firstIndex(where: { !($0.isLetter || $0 == "'" || $0 == "’") }) ?? text.endIndex
            out += text[cursor..<wordStart]
            cursor = wordEnd
            let word = String(text[wordStart..<wordEnd])
            if ",;:".contains(token.value) {
                out += lowercasingFirstWord(word, keeping: personalWords) { bare in
                    closedClassWords.contains(bare)
                        || (token.followsRecognizerSentenceEnd && isPlainCommonWord(bare) && !givenNames.contains(bare))
                }
            } else {
                let capitalized = capitalizeFirst(word)
                out += textingStyle ? Self.texting(capitalized) : capitalized
            }
        }
        out += text[cursor...]
        return out
    }

    private static let etcExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])(?:ETC|Etc)(?![\p{L}\p{N}_'’\-])"#)

    /// First names (the BSD propernames list, lowercased) that the word list also files as
    /// ordinary words ("john", "mark", "grace"): after a spoken comma a capital on one is kept.
    /// Names that are mostly verbs or function words ("will", "may") were left out.
    static let givenNames: Set<String> = {
        guard let url = Bundle.module.url(forResource: "given-names", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }()

    /// The bundled word list, loaded once, decides what counts as ordinary English.
    private static var commonWords: WordList? { WordList.shared }
    static let wordRank: @Sendable (String) -> Int? = { word in commonWords?.lookup(word)?.rank }
    /// The rank the My Words matcher's everyday-word guard reads: the dictionary's, or for a word
    /// only modern-words.txt lists ("repo", "CUDA", "Hoka"), that list's rank. Without the second,
    /// those words count as unknown and a saved name that sounds like one replaces it: with a
    /// 306-name list as My Words, "repo" became "REAP" 29 times (2026-11-18, research doc
    /// 2026-11-18-doubt-gated-correction.md). Gating on the model's confidence did not catch it;
    /// the words were heard at 0.93 to 1.00.
    static let personalWordRank: @Sendable (String) -> Int? = { word in
        wordRank(word) ?? ModernVocabulary.singleWordRank(word)
    }
    static let isCommonWord: @Sendable (String) -> Bool = { word in
        guard let rank = wordRank(word) else { return false }
        return rank < 40_000
    }

    private static func relaxedCasual(_ text: String) -> String {
        let source = text as NSString
        var pieces: [String] = []
        var cursor = 0
        for match in casualAcronyms.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            pieces.append(source.substring(with: match.range).lowercased())
            cursor = NSMaxRange(match.range)
        }
        pieces.append(source.substring(from: cursor))
        var lowered = pieces.joined()
        for match in casualCapitalAcronyms.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)).reversed() {
            guard let range = Range(match.range, in: lowered) else { continue }
            lowered.replaceSubrange(range, with: lowered[range].lowercased())
        }
        // Only a conversational opener followed by a subject loses its optional comma.
        // Lists, subordinate clauses, vocatives and explicit spoken comma tokens stay intact.
        return optionalOpeningComma.stringByReplacingMatches(
            in: lowered, range: NSRange(lowered.startIndex..., in: lowered), withTemplate: "$1$2")
    }

    /// Only explicit hesitation tokens, not conversational words such as "like", "well" or
    /// "so". Protected spans are already masked, and word boundaries include apostrophes and
    /// hyphens so a token inside a name or compound cannot disappear. Drawn-out "umm" and
    /// "uhh" are the same hesitation; "uh huh" and "uh oh" are answers, not hesitations.
    private static let fillerExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-])(?:um+|ah|uh+(?![ \t]+(?:huh|oh)(?![\p{L}\p{N}_'’\-])))(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])

    private static func removingFillers(_ text: String) -> String {
        let matches = fillerExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        let source = text as NSString
        // Expand whitespace only around actual filler tokens. A regex that starts with optional
        // whitespace retries at every space in a long run even when no filler follows it.
        func isHorizontalSpace(_ value: unichar) -> Bool { value == 32 || value == 9 }
        let punctuation: Set<unichar> = [44, 59, 58, 46, 33, 63]
        var ranges: [NSRange] = []
        for match in matches {
            // "at sign um" names a handle, @um; the explicit command keeps the word it names.
            let window = max(0, match.range.location - 16)
            let before = source.substring(with: NSRange(location: window, length: match.range.location - window)).lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).suffix(2)
            if before.count == 2, before.first == "at", ["sign", "symbol"].contains(before.last) { continue }
            var start = match.range.location
            var end = NSMaxRange(match.range)
            while start > 0, isHorizontalSpace(source.character(at: start - 1)) { start -= 1 }
            if start > 0, source.character(at: start - 1) == 44 {
                start -= 1
                while start > 0, isHorizontalSpace(source.character(at: start - 1)) { start -= 1 }
            }
            while end < source.length, isHorizontalSpace(source.character(at: end)) { end += 1 }
            while end < source.length, punctuation.contains(source.character(at: end)) { end += 1 }
            while end < source.length, isHorizontalSpace(source.character(at: end)) { end += 1 }
            if let previous = ranges.last, start <= NSMaxRange(previous) {
                ranges[ranges.count - 1].length = max(NSMaxRange(previous), end) - previous.location
            } else {
                ranges.append(NSRange(location: start, length: end - start))
            }
        }
        var pieces: [String] = []
        var cursor = 0
        var lastOutput: Character?
        for range in ranges {
            let gap = source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            pieces.append(gap)
            if let last = gap.last { lastOutput = last }
            cursor = NSMaxRange(range)
            let after = cursor < source.length
                ? source.substring(with: NSRange(location: cursor, length: min(2, source.length - cursor))).first : nil
            if lastOutput.map({ !$0.isWhitespace }) == true,
               after.map({ !$0.isWhitespace && !",.;:!?)]}".contains($0) }) == true {
                pieces.append(" ")
                lastOutput = " "
            }
        }
        pieces.append(source.substring(from: cursor))
        let out = pieces.joined()
        // An utterance consisting only of fillers and their punctuation has no content.
        if out.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }) {
            return ""
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A lowercase word after a sentence's closing mark. Group 1 is the word before a period
    /// (empty after "?" or "!"), group 2 the letter to raise.
    private static let sentenceOpening = try! NSRegularExpression(
        pattern: #"(?:(?<![\p{L}\p{N}])(\p{L}+)\.|[\p{L}\p{N}"'”’)\]][?!]+)["'”’)\]]*[ \t]+(\p{Ll})(?=[\p{Ll}'’]*(?![\p{L}\p{N}_\-@./]))"#)
    /// Words that take a period without ending a sentence.
    private static let abbreviations: Set<String> = ["etc", "vs", "inc", "ltd", "approx", "mr", "mrs", "ms", "dr", "prof",
        "jr", "sr", "st", "no", "fig", "est", "dept", "gen", "col", "sgt", "capt", "min", "max", "ave", "blvd"]

    /// "Hello there. this is great" becomes "Hello there. This is great". A period after an
    /// abbreviation or a single letter ("Dr. brown", "J. smith") is not a sentence end.
    static func capitalizingSentences(_ text: String) -> String {
        var out = text
        for match in sentenceOpening.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            if let before = Range(match.range(at: 1), in: text) {
                let word = text[before].lowercased()
                if word.count < 2 || abbreviations.contains(word) { continue }
            }
            guard let range = Range(match.range(at: 2), in: out) else { continue }
            out.replaceSubrange(range, with: out[range].uppercased())
        }
        return out
    }

    private static func capitalizeFirst(_ text: String) -> String {
        let start = openingWordStart(in: text)
        guard start < text.endIndex else { return text }
        return String(text[..<start]) + text[start].uppercased() + text[text.index(after: start)...]
    }

    private static func openingWordStart(in text: String) -> String.Index {
        text.firstIndex(where: { !"\"'“‘([{¿¡".contains($0) && !$0.isWhitespace }) ?? text.endIndex
    }

    /// Sentence punctuation may sit inside closing quotes or brackets.
    private static func contentEnd(in text: String) -> String.Index {
        var end = text.endIndex
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
        while end > text.startIndex, closers.contains(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        return end
    }

    /// A period that ends a sentence inside the text: not part of an ellipsis or a number, and
    /// followed by a capitalized next sentence. A closing quote may follow the period and an
    /// opening quote or bracket may precede the next sentence.
    private static let innerSentenceStop = try! NSRegularExpression(
        pattern: #"(?<![.\d])\.(?!\.)(?=["”’']?[ \t]+["“‘'(\[]?\p{Lu})"#)

    private static func ensureEnding(_ text: String, with mark: String) -> String {
        let end = contentEnd(in: text)
        guard end > text.startIndex else { return text }
        let last = text.index(before: end)
        if ".!?…".contains(text[last]) {
            if mark == "!", text[last] == ".",
               last == text.startIndex || text[text.index(before: last)] != "." {
                var out = text
                out.replaceSubrange(last..<end, with: mark)
                return out
            }
            return text
        }
        // Without existing punctuation, append outside a closing quote/bracket. This avoids
        // changing the literal words inside a quotation; already-punctuated quotes stay intact.
        return text + mark
    }

    /// Cleanup only surrounding prose; saved compounds and phrases reach the later
    /// canonical vocabulary pass intact. Literal syntax has already been masked.
    private static func normalizingCasualProse(_ text: String, keeping words: [String]) -> String {
        guard text.contains("?") || text.range(of: "auto-correct", options: .caseInsensitive) != nil else { return text }
        func normalize(_ prose: Substring) -> String {
            // Run before spoken commands, so explicit repeated question marks survive.
            let questions = prose.replacingOccurrences(of: #"\?(?:[ \t]*\?)+"#, with: "?", options: .regularExpression)
            return questions.replacingOccurrences(of: #"\b(auto)-(correct)\b"#, with: "$1$2",
                                                   options: [.regularExpression, .caseInsensitive])
        }
        var output = ""
        var cursor = text.startIndex
        for span in VocabularyCandidates.matchedRanges(in: text, words: words) {
            guard let range = Range(span, in: text) else { continue }
            output += normalize(text[cursor..<range.lowerBound])
            output += text[range]
            cursor = range.upperBound
        }
        return output + normalize(text[cursor...])
    }

    /// Mask syntax whose spelling/case carries meaning. No guesses about vocabulary or names.
    /// Markers are collision-free, uncased, and restored after punctuation and capitalization.
    private struct ProtectedText {
        let masked: String
        let literals: [String]
        let restorationExpression: NSRegularExpression
        let startsWithLiteral: Bool
        let endsWithLiteral: Bool

        private static let expression = try! NSRegularExpression(pattern: #"```[\s\S]*?(?:```|$)|`[^`\n]+`|(?m:^[\t ]*(?:let|var|const)\s+[A-Za-z_$][\w$]*\s*=[^\n]*)|(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"`]+|(?<![A-Za-z0-9.!#$%&'*+/=?^_`{|}~-])[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|(?<![\p{L}\p{N}_])@[\p{L}\p{N}_](?:[\p{L}\p{N}_.-]*[\p{L}\p{N}_])?|(?<![A-Za-z0-9.@-])(?:www\.(?:[A-Za-z0-9-]+\.)*[A-Za-z0-9-]+\.[A-Za-z]{2,}|(?:[A-Za-z0-9-]+\.)+(?i:com|org|net|edu|gov|io|dev|app|ai|co|wtf|xyz|tv|gg|sh|ly|fm|info|biz|me|uk|ca|de))(?![A-Za-z0-9-])(?:/[^\s<>"`]*)?|\b(?:[A-Za-z]\.){2,}|\b[a-z]+[A-Z][A-Za-z0-9]*\b|\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b|\b\d+(?:\.\d+)+\b|(?:~/|/)[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+"#)

        /// A bare domain with a path, "www.Example.com/Docs." (no scheme, no "@"). Its trailing
        /// sentence punctuation belongs to the prose, as for a URL. Without a path the
        /// expression already stops at the top-level domain; "a.m." keeps its last dot.
        private static func isBareDomain(_ candidate: Substring) -> Bool {
            !candidate.contains("@") && !candidate.contains("`") && candidate.contains(".") && candidate.contains("/") &&
                candidate.first.map({ $0.isLetter || $0.isNumber }) == true &&
                !candidate.contains(where: { $0.isWhitespace })
        }

        init(_ text: String) {
            // A fixed-length nonce avoids growing a prefix one character at a time when the
            // transcript itself contains a long run of private-use characters.
            // Letter-free, so the personal-word pass cannot rewrite part of a placeholder.
            let prefix = SpokenFormatting.placeholderPrefix(lead: "\u{E000}", avoiding: text)
            var cursor = text.startIndex
            var masked = ""
            var literals: [String] = []
            var starts = false
            var ends = false
            for match in Self.expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard var range = Range(match.range, in: text) else { continue }
                // URL/path terminal sentence punctuation belongs to the prose, not the literal.
                let candidate = text[range]
                if candidate.contains("://") || candidate.hasPrefix("/") || candidate.hasPrefix("~/") ||
                    Self.isBareDomain(candidate) {
                    while range.upperBound > range.lowerBound,
                          ".,;!".contains(text[text.index(before: range.upperBound)]) {
                        range = range.lowerBound..<text.index(before: range.upperBound)
                    }
                }
                guard !range.isEmpty else { continue }
                masked += text[cursor..<range.lowerBound]
                let marker = prefix + String(literals.count) + "\u{E001}"
                literals.append(String(text[range]))
                masked += marker
                if range.lowerBound == text.startIndex { starts = true }
                if range.upperBound == text.endIndex { ends = true }
                cursor = range.upperBound
            }
            masked += text[cursor...]
            self.masked = masked
            self.literals = literals
            restorationExpression = try! NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: prefix) + "([0-9]+)\u{E001}")
            startsWithLiteral = starts
            endsWithLiteral = ends
        }

        func restore(_ text: String) -> String {
            guard !literals.isEmpty else { return text }
            // One scan, rather than replacing each marker through the whole transcript.
            let source = text as NSString
            var pieces: [String] = []
            var cursor = 0
            restorationExpression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
                guard let match, let index = Int(source.substring(with: match.range(at: 1))),
                      literals.indices.contains(index) else { return }
                pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                pieces.append(literals[index])
                cursor = NSMaxRange(match.range)
            }
            pieces.append(source.substring(from: cursor))
            return pieces.joined()
        }

    }
}
