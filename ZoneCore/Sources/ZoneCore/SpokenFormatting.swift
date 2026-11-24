// by zayd/cold @ zayd.wtf

import Foundation

/// Explicit spoken formatting, not paraphrasing. The caller masks existing literals first and
/// restores emitted tokens after style/joining, so an explicit comma or newline cannot be erased.
enum SpokenFormatting {
    struct Token {
        let marker: String
        var value: String
        let suppressesLeadingSpace: Bool
        let startsList: Bool
        let protectsEnding: Bool
        /// The recognizer put its own sentence end (. ? !) around this spoken mark ("comma.",
        /// ". Semicolon."), so the capital on the next word is the recognizer's, not a name's.
        var followsRecognizerSentenceEnd = false
    }
    struct Result {
        var text: String
        var tokens: [Token] = []
        var suppressesLeadingSpace = false
        var startsList = false
        var endsWithToken = false
        var prefix: String

        /// Cleanup may remove prose before/after a command. Its original position must not
        /// leave a join-space before punctuation or duplicate the first list's newline.
        mutating func refreshBoundaries(after cleaned: String) {
            text = cleaned
            let firstIsLeading = tokens.first.map { cleaned.hasPrefix($0.marker) } ?? false
            suppressesLeadingSpace = firstIsLeading && tokens[0].suppressesLeadingSpace
            startsList = firstIsLeading && tokens[0].startsList
            if startsList, tokens[0].value.hasPrefix("\n") {
                tokens[0].value.removeFirst()
            }
            endsWithToken = tokens.last.map { $0.protectsEnding && cleaned.hasSuffix($0.marker) } ?? false
        }

        func restore(_ input: String) -> String {
            guard !tokens.isEmpty else { return input }
            let pattern = NSRegularExpression.escapedPattern(for: prefix) + "([0-9]+)\u{E003}"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
            let source = input as NSString
            var pieces: [String] = []
            var cursor = 0
            for match in regex.matches(in: input, range: NSRange(location: 0, length: source.length)) {
                guard let index = Int(source.substring(with: match.range(at: 1))), tokens.indices.contains(index) else { continue }
                pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                pieces.append(tokens[index].value)
                cursor = NSMaxRange(match.range)
            }
            pieces.append(source.substring(from: cursor))
            return pieces.joined()
        }
    }

    private enum Spacing { case word, open, close, line, list, comma }

    // Bounded lexical contexts where “period” is a noun. Explicit “insert period” bypasses
    // this guard; no sentence rewriting or inference from arbitrary numbers is attempted.
    private static let literalPeriodPrefixes: Set<String> = [
        "time", "grace", "menstrual", "trial", "probationary", "incubation", "short", "long", "brief", "of",
        "geological", "historical", "academic", "prehistoric", "early", "middle", "late",
        "precambrian", "cambrian", "ordovician", "silurian", "devonian", "carboniferous", "permian",
        "triassic", "jurassic", "cretaceous", "paleogene", "neogene", "quaternary",
        "paleolithic", "mesolithic", "neolithic", "classical", "hellenistic", "roman", "medieval",
        "renaissance", "tudor", "elizabethan", "stuart", "georgian", "victorian", "edwardian",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth"
    ]

    /// A placeholder prefix no later pass can read into: `lead`, then sixteen private-use
    /// characters. They are not letters, digits, spaces or punctuation, so the personal-word
    /// matcher, the filler and acronym expressions and casing never see a word inside a
    /// placeholder. (A hexadecimal UUID did contain words: "Cade" rewrote "cad" inside one and
    /// the URL it stood for was lost.)
    static func placeholderPrefix(lead: Unicode.Scalar, avoiding text: String) -> String {
        var prefix = ""
        repeat {
            var scalars = String.UnicodeScalarView([lead])
            let id = UUID().uuid
            for byte in [id.0, id.1, id.2, id.3, id.4, id.5, id.6, id.7, id.8, id.9, id.10, id.11, id.12, id.13, id.14, id.15] {
                scalars.append(Unicode.Scalar(0xE100 + UInt32(byte))!)
            }
            prefix = String(scalars) + "_"
        } while text.contains(prefix)
        return prefix
    }

    /// `prefilter` is for tests only: false puts every word in the expression, the reference
    /// the filtered result must equal. `continuesSentence` says the cursor is mid-sentence, so a
    /// punctuation word that opens the dictation ("comma, see you") is a command, not a mention.
    /// Abbreviations whose period belongs to the word, not to the sentence.
    private static let abbreviations: Set<String> = [
        "inc", "ltd", "co", "corp", "llc", "etc", "vs", "dr", "mr", "mrs", "ms", "st", "jr", "sr",
        "prof", "approx", "dept", "ave", "fig", "vol",
    ]

    static func endsWithAbbreviation(_ text: Substring) -> Bool {
        let word = text.reversed().prefix(while: { $0.isLetter })
        guard !word.isEmpty else { return false }
        return abbreviations.contains(String(word.reversed()).lowercased())
    }

    private static let boundaryStart = #"(?<![\p{L}\p{N}_'’\-])"#
    private static let boundaryEnd = #"(?![\p{L}\p{N}_'’\-])"#

    private static func canonicalVocabulary(_ personalWords: [String]) -> [String: String] {
        var vocabulary: [String: String] = [:]
        for value in personalWords {
            let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if vocabulary[word.lowercased()] == nil { vocabulary[word.lowercased()] = word }
        }
        return vocabulary
    }

    private static func knownPattern(_ text: String, vocabulary: [String: String], prefilter: Bool) -> String {
        let candidates = VocabularyCandidates(text)
        let present = prefilter ? vocabulary.values.filter { candidates.mayMatch($0) } : Array(vocabulary.values)
        let names = present.sorted { $0.count > $1.count }.flatMap { word -> [String] in
            let exact = NSRegularExpression.escapedPattern(for: word)
            let letters = Array(word)
            guard (2...32).contains(letters.count), letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [exact] }
            let spelled = letters.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ \\t]+")
            return [spelled, exact]
        }
        return names.isEmpty ? "(?!)" : "(?:" + names.joined(separator: "|") + ")"
    }

    static func writingKnownNames(_ text: String, words: [String]) -> String {
        let vocabulary = canonicalVocabulary(words)
        let pattern = boundaryStart + knownPattern(text, vocabulary: vocabulary, prefilter: true) + boundaryEnd
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let output = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let original = output.substring(with: match.range).lowercased()
            if let saved = vocabulary[original] ?? vocabulary[original.filter { !$0.isWhitespace }] {
                output.replaceCharacters(in: match.range, with: saved)
            }
        }
        return output as String
    }

    /// `mentions` turns a spoken "at Kevin" into "@kevin" (see `SpokenMentions`); "at sign Kevin"
    /// is explicit and tags with or without it. `handles` are the person's own ("at cold").
    /// `spellsInCapitals` is caps lock: "spell d a a n" writes DAAN rather than Daan. The spelling
    /// is a protected token, so caps lock cannot raise it afterwards.
    static func process(_ spoken: String, personalWords: [String], continuesSentence: Bool = false,
                        mentions: Bool = false, handles: [String] = [], prefilter: Bool = true,
                        wordsBefore: [String] = [], spellsInCapitals: Bool = false) -> Result {
        // One escaped alternation and canonical lookup cover all stored vocabulary. ASR hint
        // limits belong to each engine, not to the user's dictionary or formatting.
        let vocabulary = canonicalVocabulary(personalWords)
        // Mentions are marked before anything else reads the text, so the name after "at" is
        // not also taken as a personal word or a command.
        let marked = SpokenMentions.mark(spoken, bare: mentions, vocabulary: vocabulary, handles: handles, before: wordsBefore)
        let text = marked.text
        let handles = marked.handles
        let prefix = placeholderPrefix(lead: "\u{E002}", avoiding: text)
        var result = Result(text: text, prefix: prefix)
        // Only words that can occur in this text join the expression: a dictionary that learns
        // from corrections grows without bound, and a 500-word alternation tried at every
        // position cost about 110 ms per dictation on an M4 (seconds on a long one).
        let known = knownPattern(text, vocabulary: vocabulary, prefilter: prefilter)
        let spelling = #"(?:spell|spelled)[ \t]+(?:[a-z][ \t]+){1,31}[a-z](?:[ \t]+end[ \t]+spelling)?"#
        let commands = #"literal[ \t]+(?:bullet[ \t]+point|next[ \t]+bullet|next[ \t]+item|comma|quote|period|colon|(?:semi[ \t-]?colon|semi[ \t]?cola)|question[ \t]+mark|exclamation[ \t]+(?:mark|point)|new[ \t]+(?:line|paragraph))|bullet[ \t]+point|bullet|next[ \t]+bullet|start[ \t]+numbered[ \t]+list|next[ \t]+item|end[ \t]+list|(?:open|close)[ \t]+parenthes(?:is|es)|(?:open|close|begin|end)[ \t]+quote|new[ \t]+(?:paragraph|line)|insert[ \t]+(?:comma|period|colon|(?:semi[ \t-]?colon|semi[ \t]?cola))|full[ \t]+stop|question[ \t]+mark|exclamation[ \t]+(?:mark|point)|quote|unquote|comma|period|colon|(?:semi[ \t-]?colon|semi[ \t]?cola)"#
        let knownSpelling = "(?:spell|spelled)[ \t]+" + known + "(?:[ \t]+end[ \t]+spelling)?"
        let mention = handles.isEmpty ? "(?!)" : "\(SpokenMentions.lead)[0-9]+\(SpokenMentions.end)"
        let pattern = boundaryStart + "(?:(?<mention>" + mention + ")|(?<knownspelling>" + knownSpelling + ")|(?<spelling>" + spelling + ")|(?<known>" + known + ")|(?<command>" + commands + "))" + boundaryEnd
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return result }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        func words(_ value: String) -> String { value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        func isLiteralMention(_ match: NSTextCheckingResult) -> Bool {
            let start = max(0, match.range.location - 64)
            let previous = source.substring(with: NSRange(location: start, length: match.range.location - start))
                .split(whereSeparator: { $0.isWhitespace }).last?.lowercased() ?? ""
            return ["a", "an", "the", "word", "literal"].contains(previous)
        }
        var remainingQuoteEnds = matches.filter {
            $0.range(withName: "command").location != NSNotFound && !isLiteralMention($0) &&
                ["close quote", "end quote", "unquote"].contains(words(source.substring(with: $0.range)))
        }.count
        var remainingNextBullets = matches.filter {
            $0.range(withName: "command").location != NSNotFound && !isLiteralMention($0) &&
                words(source.substring(with: $0.range)) == "next bullet"
        }.count
        func isLineStart(_ position: Int) -> Bool {
            var index = position
            while index > 0, [32, 9].contains(source.character(at: index - 1)) { index -= 1 }
            return index == 0 || [10, 13].contains(source.character(at: index - 1))
        }
        var quoteDepth = 0
        enum ListMode { case none, bullets, numbered(Int) }
        var listMode = ListMode.none
        var cursor = 0
        var output = ""
        var trimNextSpace = false
        var lastSpacing = Spacing.word
        for match in matches {
            let original = source.substring(with: match.range)
            let command = words(original)
            var value: String?
            var spacing = Spacing.word
            if match.range(withName: "mention").location != NSNotFound {
                value = Int(original.dropFirst().dropLast()).flatMap { handles.indices.contains($0) ? handles[$0] : nil }
            } else if match.range(withName: "knownspelling").location != NSNotFound {
                var body = original.split(whereSeparator: { $0.isWhitespace }).dropFirst().map(String.init)
                if body.suffix(2).map({ $0.lowercased() }) == ["end", "spelling"] { body.removeLast(2) }
                value = vocabulary[body.joined(separator: " ").lowercased()] ?? vocabulary[body.joined().lowercased()]
            } else if match.range(withName: "spelling").location != NSNotFound {
                let letters: String = original.split(whereSeparator: { $0.isWhitespace }).filter { $0.count == 1 }.joined()
                // Written as a spelled word is: "Daan", or the known spelling ("API").
                value = vocabulary[letters.lowercased()] ?? (spellsInCapitals ? letters.uppercased() : SpelledLetters.word(letters))
            } else if match.range(withName: "known").location != NSNotFound {
                let compact = original.filter { !$0.isWhitespace }
                value = vocabulary[original.lowercased()] ?? vocabulary[compact.lowercased()]
            } else {
                let mention = isLiteralMention(match)
                switch command {
                case "open parenthesis", "open parentheses": value = "("; spacing = .open
                case "close parenthesis", "close parentheses": value = ")"; spacing = .close
                case "open quote" where !mention, "begin quote" where !mention:
                    value = "\""; spacing = .open; quoteDepth += 1
                case "quote" where !mention && remainingQuoteEnds > quoteDepth:
                    value = "\""; spacing = .open; quoteDepth += 1
                case "close quote" where !mention, "end quote" where !mention, "unquote" where !mention:
                    remainingQuoteEnds -= 1
                    if quoteDepth > 0 { value = "\""; spacing = .close; quoteDepth -= 1 }
                case "bullet point" where !mention:
                    value = "• "; spacing = .list; listMode = .bullets
                case "bullet" where remainingNextBullets > 0 && isLineStart(match.range.location):
                    value = "• "; spacing = .list; listMode = .bullets
                case "next bullet" where !mention:
                    remainingNextBullets -= 1
                    if case .bullets = listMode { value = "• "; spacing = .list }
                case "start numbered list" where !mention:
                    value = "1. "; spacing = .list; listMode = .numbered(1)
                case "next item" where !mention:
                    if case .numbered(let number) = listMode {
                        value = "\(number + 1). "; spacing = .list; listMode = .numbered(number + 1)
                    }
                case "end list" where !mention:
                    if case .none = listMode {} else { value = "\n"; spacing = .line; listMode = .none }
                case "new line": value = "\n"; spacing = .line
                case "new paragraph": value = "\n\n"; spacing = .line
                case "insert comma": value = ","; spacing = .comma
                case "insert period", "full stop": value = "."; spacing = .comma
                case "insert colon": value = ":"; spacing = .comma
                case "insert semicolon", "insert semi colon", "insert semi-colon": value = ";"; spacing = .comma
                case "question mark" where !mention: value = "?"; spacing = .comma
                case "exclamation mark" where !mention, "exclamation point" where !mention: value = "!"; spacing = .comma
                case "comma", "period", "colon", "semicolon", "semi colon", "semi-colon", "semicola", "semi cola":
                    let beforeStart = max(0, match.range.location - 64)
                    let afterStart = NSMaxRange(match.range)
                    let before = source.substring(with: NSRange(location: beforeStart, length: match.range.location - beforeStart)).split(whereSeparator: { $0.isWhitespace }).last?.lowercased() ?? ""
                    let after = source.substring(with: NSRange(location: afterStart, length: min(64, source.length - afterStart))).split(whereSeparator: { $0.isWhitespace }).first?.lowercased() ?? ""
                    // Bare punctuation words are conventional commands, but keep clear noun
                    // mentions and common non-punctuation senses. "insert …" and "literal …"
                    // remain explicit ways to disambiguate without paraphrasing the sentence.
                    let nounIntroducers = ["a", "an", "the", "word", "literal", "my", "your", "his", "her", "our", "their", "this", "that"]
                    let nounPredicates = ["separated", "delimiter", "symbol", "means", "is", "are", "was", "usage"]
                    let periodMention = command == "period" &&
                        (Self.literalPeriodPrefixes.contains(before) ||
                         ["of", "pain", "pains", "cramp", "cramps", "tracker", "tracking", "drama", "cycle", "cycles", "later"].contains(after))
                    let colonMention = command == "colon" &&
                        (["ascending", "descending", "transverse", "sigmoid"].contains(before) ||
                         ["anatomy", "cancer", "polyp", "polyps", "screening", "disease", "pain", "surgery", "health"].contains(after))
                    // A semicolon word that opens a dictation is a command: it is how a second take
                    // continues ("semicolon, then..."). Comma, period and colon at the very start
                    // stay mentions ("Comma placement matters").
                    // Mid-sentence at the cursor, every one of them opens as a command.
                    let semicolonFamily = command.hasPrefix("semi")
                    if !(before.isEmpty && !after.isEmpty) || semicolonFamily || continuesSentence,
                       !nounIntroducers.contains(before), !nounPredicates.contains(after),
                       !(command == "comma" && ["oxford", "serial"].contains(before)),
                       !periodMention, !colonMention {
                        value = ["comma": ",", "period": ".", "colon": ":", "semicolon": ";", "semi colon": ";",
                                 "semi-colon": ";", "semicola": ";", "semi cola": ";"][command]
                        spacing = .comma
                    }
                default:
                    if command.hasPrefix("literal ") { value = String(original.dropFirst(8)); spacing = .word }
                }
            }
            guard var value else { continue }
            var consumedEnd = NSMaxRange(match.range)
            var recognizerSentenceEnd = false
            // Recognizers often punctuate the command phrase itself ("comma," or "new line.").
            // Explicit symbols replace that adornment; punctuation inside literal/name tokens stays.
            // A spoken mark also replaces "?", "!", ":" and ";" ("Question mark?"); delimiters
            // do not, since a "?" after "unquote" is the sentence's own.
            if match.range(withName: "command").location != NSNotFound, !command.hasPrefix("literal ") {
                let adornment: Set<unichar> = spacing == .comma ? [44, 46, 63, 33, 58, 59] : [44, 46]
                while consumedEnd < source.length, adornment.contains(source.character(at: consumedEnd)) {
                    if [46, 63, 33].contains(source.character(at: consumedEnd)) { recognizerSentenceEnd = true }
                    consumedEnd += 1
                }
            }
            var gap = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if trimNextSpace { gap = String(gap.drop(while: { $0 == " " || $0 == "\t" })) }
            output += gap
            // The recognizer often hears the pause before a spoken mark as its own mark
            // ("Hey, comma," or "home. Semicolon."). The spoken mark replaces it; an ellipsis
            // stays. Before a line break or an opening parenthesis only a comma goes.
            if value == "(" {
                var trimmed = output
                while trimmed.last == " " || trimmed.last == "\t" { trimmed.removeLast() }
                if trimmed.last == "," {
                    while trimmed.last == "," { trimmed.removeLast() }
                    output = trimmed + " "
                }
            } else if spacing == .comma || spacing == .line {
                while output.last == " " || output.last == "\t" { output.removeLast() }
                let replaceable: Set<Character> = spacing == .comma ? [",", ";", ":", ".", "?", "!"] : [","]
                while let last = output.last, replaceable.contains(last) {
                    if last == "." && output.dropLast().last == "." { break }
                    // "Acme Inc. comma" keeps the abbreviation's own period: "Inc.,".
                    if last == ".", value == ",", Self.endsWithAbbreviation(output.dropLast()) { break }
                    if ".?!".contains(last) { recognizerSentenceEnd = true }
                    output.removeLast()
                }
            }
            if spacing == .list {
                let followsLineCommand = lastSpacing == .line && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                while output.last == " " || output.last == "\t" { output.removeLast() }
                while output.last == "," { output.removeLast() }
                if !output.isEmpty && output.last != "\n" && !followsLineCommand { value = "\n" + value }
            }
            if spacing == .close || spacing == .comma || spacing == .line {
                while output.last == " " || output.last == "\t" { output.removeLast() }
            }
            if spacing == .close {
                // A model-added comma immediately before a spoken closer is not another command.
                while output.last == "," { output.removeLast() }
            }
            if output.isEmpty {
                result.suppressesLeadingSpace = spacing == .close || spacing == .comma || spacing == .line
                result.startsList = spacing == .list
            }
            let marker = prefix + String(result.tokens.count) + "\u{E003}"
            result.tokens.append(Token(marker: marker, value: value,
                suppressesLeadingSpace: spacing == .close || spacing == .comma || spacing == .line,
                startsList: spacing == .list, protectsEnding: spacing != .word,
                followsRecognizerSentenceEnd: recognizerSentenceEnd))
            output += marker
            cursor = consumedEnd
            trimNextSpace = spacing == .open || spacing == .line || spacing == .list
            lastSpacing = spacing
        }
        var rest = source.substring(from: cursor)
        if trimNextSpace { rest = String(rest.drop(while: { $0 == " " || $0 == "\t" })) }
        output += rest
        result.text = output
        result.endsWithToken = lastSpacing != .word && (result.tokens.last.map { output.hasSuffix($0.marker) } ?? false)
        return result
    }
}

/// A one-pass index of a transcript that says which vocabulary words could possibly match the
/// spoken-formatting expression, in time linear in the text plus the dictionary.
///
/// The expression only matches a word between boundaries of `[\p{L}\p{N}_'’-]`, so an ASCII
/// word made of those characters can only match a whole token, and its spaced-out spelling
/// ("Z A Y D") only a run of single-letter tokens separated by spaces or tabs. Comparison is
/// under full case folding, which is at least as loose as the expression's case-insensitive
/// matching, so the index never drops a real match; it may keep a word that then does not
/// match, which only costs time. Other words ("C++", "New York", "ŞAHİN") fall back to a
/// substring check. `testVocabularyPrefilterNeverChangesTheResult` holds it to the unfiltered
/// expression.
struct VocabularyCandidates {
    private var tokens: Set<String> = []
    /// Each run of spaced single letters, joined, the runs separated by a non-letter.
    private var spelled: NSString = ""
    private let compact: NSString

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return scalar == "_" || scalar == "'" || scalar == "’" || scalar == "-"
        }
    }

    /// Exact explicit vocabulary spans, with whitespace variants and overlapping matches merged.
    /// Ascending ranges let callers normalize surrounding prose without changing saved spelling.
    static func matchedRanges(in text: String, words: [String]) -> [NSRange] {
        guard !words.isEmpty else { return [] }
        let present = VocabularyCandidates(text)
        let alternatives = words.filter { word in
            present.mayMatch(word) || ["'s", "’s", "'", "’"].contains { present.mayMatch(word + $0) }
        }.sorted { $0.count > $1.count }.map {
            $0.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }.filter { !$0.isEmpty }
        guard !alternatives.isEmpty, let regex = try? NSRegularExpression(
            pattern: #"(?=(?<![\p{L}\p{N}_'’\-])("# + alternatives.joined(separator: "|") + #")(?=(?:['’]s?)?(?![\p{L}\p{N}_'’\-])))"#,
            options: [.caseInsensitive]) else { return [] }
        var ranges: [NSRange] = []
        for range in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map({ $0.range(at: 1) }) {
            if let last = ranges.last, NSMaxRange(last) >= range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else { ranges.append(range) }
        }
        return ranges
    }

    private static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive], locale: nil) }

    init(_ text: String) {
        compact = Self.fold(text).filter { !$0.isWhitespace } as NSString
        var current = String.UnicodeScalarView()
        var gapIsSpaces = true
        var letters: [String] = [] // the current run of spaced single ASCII letters
        var runs = ""
        func closeRun() {
            if letters.count >= 2 { runs += letters.joined() + "|" }
            letters.removeAll()
        }
        func closeToken() {
            guard !current.isEmpty else { return }
            let folded = Self.fold(String(current))
            tokens.insert(folded)
            // One character that folds to an ASCII letter ("K" as the Kelvin sign included).
            if current.count == 1, folded.utf8.count == 1, let letter = folded.first, letter.isLetter {
                if !gapIsSpaces { closeRun() }
                letters.append(folded)
            } else {
                closeRun()
            }
            current = String.UnicodeScalarView()
            gapIsSpaces = true
        }
        for scalar in text.unicodeScalars {
            if Self.isWordScalar(scalar) {
                current.append(scalar)
            } else {
                closeToken()
                if scalar != " " && scalar != "\t" { gapIsSpaces = false }
            }
        }
        closeToken()
        closeRun()
        spelled = runs as NSString
    }

    func mayMatch(_ word: String) -> Bool {
        // ASCII only: a non-ASCII pattern character can match text outside the token classes
        // ("İ" matches "i" plus a combining dot, which is a mark and ends a token).
        if word.unicodeScalars.allSatisfy({ $0.isASCII && Self.isWordScalar($0) }) {
            let folded = Self.fold(word)
            if tokens.contains(folded) { return true }
            // Any stretch of a run is a valid spelled match: each letter is one character.
            return spelled.length > 0 && spelled.range(of: folded, options: .literal).location != NSNotFound
        }
        let needle = Self.fold(word).filter { !$0.isWhitespace }
        return !needle.isEmpty && compact.range(of: needle, options: .literal).location != NSNotFound
    }
}
