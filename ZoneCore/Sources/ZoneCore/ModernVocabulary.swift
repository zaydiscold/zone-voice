// by zayd/cold @ zayd.wtf

import Foundation

/// Current words every install knows: products, apps and everyday words newer than the bundled
/// word list (142 of 255 sampled were missing from it, "Reddit", "Spotify" and "chatbot" among
/// them). The list is `Resources/modern-words.txt`, data the app could later download.
///
/// - Dictation spells them right, in the style's casing (`docs/dictation-styles.md`): formal
///   writes "OpenAI", casual "openai". The recognizer splits and miscases names it never
///   saw in training ("test flight", "chat GPT", "anthropic") and writes a known word for an
///   unknown one ("clawed code" for Claude Code); only the listed forms are rewritten.
/// - Swipe typing can write them, in their own casing.
/// - Tap autocorrect leaves them alone and capitalizes the names.
///
/// A person's own words always win: a spelling in My Words or contacts is never rewritten.
public enum ModernVocabulary {
    struct Entry {
        let word: String
        var rank: Int
        /// What a recognizer writes for the word, lowercase, single spaces.
        let heard: [String]
        /// Swearing, sexual slang or a slur (rank written with a trailing x): typed and swiped as
        /// written, but never a correction target, so a typo is never turned into one.
        var blocked = false
        /// False for a short, rare word of the broad list: typing keeps it, swipe never offers it.
        var swipes = true
    }

    /// modern-words.txt: typing, swipe and dictation.
    static let entries: [Entry] = load("modern-words")

    /// Each one-word entry's rank by lowercase spelling (the lower when listed twice), so passes that
    /// protect everyday words know these as words, not as unknown spellings free to replace.
    private static let singleWordRanks: [String: Int] = Dictionary(
        entries.filter { !$0.word.contains(" ") }.map { ($0.word.lowercased(), $0.rank) },
        uniquingKeysWith: min)

    static func singleWordRank(_ word: String) -> Int? { singleWordRanks[word.lowercased()] }

    /// more-words.txt: the broad third pass, for typing and swipe only. Dictation leaves these to
    /// the recognizer, which already writes them, so nothing here rewrites speech.
    static let moreEntries: [Entry] = load("more-words").map {
        var entry = $0
        // A short rare word ("GBR", "edf", "tsui") traces like a common one and won human swipes
        // meant for "the", "west" and "two"; typing still keeps it as written.
        entry.swipes = entry.word.count > 4 || entry.rank <= moreWordsShortSwipeMaximumRank
        entry.rank = max(entry.rank, moreWordsSwipeRank)
        return entry
    }

    /// The rarest list rank at which a broad-list word of four letters or fewer is swipeable.
    static let moreWordsShortSwipeMaximumRank = 20_000

    /// Lowercase keys of the broad list's capitalized names ("lakers" for Lakers), for swipe's
    /// casing penalty.
    public static let broadNames: Set<String> = Set(moreEntries.filter { $0.word != $0.word.lowercased() }.map { $0.word.lowercased() })

    /// The broad list's swipe rank floor: a swipe that clearly traces one of its words writes it,
    /// but it never wins a close call against a word people type more (measured on the human
    /// swipe set, where list ranks alone cost 0.19 points top-1).
    static let moreWordsSwipeRank = 40_000

    private static func load(_ resource: String) -> [Entry] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let word = fields[0].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return nil }
            var rankField = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            let blocked = rankField.hasSuffix("x")
            if blocked { rankField.removeLast() }
            let rank = Int(rankField) ?? defaultRank
            let heard = fields.count > 2 ? fields[2].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty } : []
            return Entry(word: word, rank: rank, heard: heard, blocked: blocked)
        }
    }

    static let defaultRank = 4_000

    /// The dictionary files the word as ordinary lowercase English ("amazon", "google").
    private static func isOrdinaryWord(_ lower: String) -> Bool {
        guard let entry = WordList.shared?.lookup(lower) else { return false }
        return entry.display == entry.display.lowercased()
    }

    /// One-word entries for the keyboard. A name the dictionary also files as an ordinary word
    /// is here only when the list says the name wins ("google" among its heard forms).
    private static let keyboardEntries: [Entry] = {
        var seen = Set<String>()
        return (entries + moreEntries).filter { entry in
            guard entry.word.allSatisfy({ $0.isLetter }) else { return false }
            let lower = entry.word.lowercased()
            guard entry.word == lower || !isOrdinaryWord(lower) || entry.heard.contains(lower) else { return false }
            return seen.insert(lower).inserted
        }
    }()

    /// One-word names written with an apostrophe or hyphen ("McDonald's", "T-Mobile",
    /// "Chick-fil-A"), keyed by their letters in lowercase: typed "tmobile" is T-Mobile.
    static let punctuatedNames: [String: String] = Dictionary(
        entries.filter { entry in
            entry.word.first?.isLetter == true && entry.word != entry.word.lowercased() && !entry.word.allSatisfy({ $0.isLetter })
                && entry.word.allSatisfy({ $0.isLetter || "'’-".contains($0) })
        }.map { (String($0.word.lowercased().filter(\.isLetter)), $0.word) },
        uniquingKeysWith: { first, _ in first }).filter { !isOrdinaryWord($0.key) }

    /// Words tap autocorrect accepts as typed.
    public static let words: [String] = keyboardEntries.map(\.word) + punctuatedNames.keys.sorted()

    /// The lowercase words among them ("bestie", "rizz"): ordinary English the dictionary is too old to have.
    static let ordinaryWords: Set<String> = Set(keyboardEntries.map(\.word).filter { $0 == $0.lowercased() })

    /// Lowercase to the standard spelling, for the names among them: a typed "reddit" is "Reddit".
    public static let names: [String: String] = Dictionary(
        keyboardEntries.filter { $0.word != $0.word.lowercased() }.map { ($0.word.lowercased(), $0.word) },
        uniquingKeysWith: { first, _ in first }).merging(punctuatedNames) { first, _ in first }

    /// Names that take their capital even though the dictionary has the lowercase word.
    public static let forcedNames: [String: String] = names.filter { isOrdinaryWord($0.key) }

    /// Swipe typing's share, each at its frequency rank.
    public static let swipeWords: [(word: String, rank: Int)] = keyboardEntries.filter(\.swipes).map { ($0.word, $0.rank) }

    /// The words a slip can be corrected to: modern-words.txt's curated entries, without swearing
    /// or slurs. The broad more-words.txt list is kept as typed and swipeable but is not searched
    /// for typos: thousands more targets cost every keystroke and let rare names steal slips.
    static let correctionWords: [(word: String, rank: Int)] = {
        let curated = Set(entries.map { $0.word.lowercased() })
        return keyboardEntries.filter { !$0.blocked && curated.contains($0.word.lowercased()) }.map { ($0.word, $0.rank) }
    }()

    /// Lowercase keys of the swearing, sexual slang and slurs among them: never a typo's fix.
    public static let blockedWords: Set<String> = Set(keyboardEntries.filter(\.blocked).map { $0.word.lowercased() })

    /// Names of two or three words with a capital ("Micro Center", "Trader Joe's"), keyed by their
    /// words in lowercase without apostrophes, joined by single spaces. Each word alone is often
    /// ordinary English, so the keyboard writes the name only once the whole of it is typed
    /// (`PhraseCasing`).
    static let phrases: [String: String] = {
        var table: [String: String] = [:]
        for entry in entries {
            let words = entry.word.split(separator: " ")
            guard (2...3).contains(words.count), entry.word != entry.word.lowercased(),
                  entry.word.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "’" }) else { continue }
            if let key = PhraseCasing.key(words.map(String.init)), table[key] == nil { table[key] = entry.word }
        }
        return table
    }()

    // MARK: Dictation

    /// Every form dictation rewrites, lowercase with single spaces, to the standard spelling.
    private static let spoken: [String: String] = {
        var table: [String: String] = [:]
        for entry in entries {
            for form in entry.heard where form != entry.word { table[form] = entry.word }
            let lower = entry.word.lowercased()
            // The word itself in another case ("anthropic"), unless lowercase is ordinary English.
            if lower != entry.word, !isOrdinaryWord(lower) || entry.heard.contains(lower) { table[lower] = entry.word }
        }
        return table
    }()

    private static let spokenExpression: NSRegularExpression? = {
        let alternation = spoken.keys.sorted { $0.count > $1.count }.map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"[ \t]+"#)
        }.joined(separator: "|")
        guard !alternation.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_'’\-@#./])(?:"# + alternation + #")(?=(?:['’]s|s)?(?![\p{L}\p{N}_'’\-]))"#,
            options: [.caseInsensitive])
    }()

    /// "clawed code", "cloud code" and friends. Google's Cloud Code keeps its name.
    private static let claudeCode = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])(?<!google[ \t])(?:clawed|claud|clawd|klaud|clod|clad|claude|cloud)[ \t]+code(?![\p{L}\p{N}_'’\-])"#,
        options: [.caseInsensitive])
    /// "clawed" with nothing after it that a claw could act on: "get him clawed", "a clawed agent".
    private static let clawed = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])clawed(?=(?:['’]s)?(?![\p{L}\p{N}_'’\-]))(?![ \t]+(?:at|by|back|out|up|through|into|away|off|its|his|her|their|my|our|your|the|a|an|me|him|them|us)(?![\p{L}]))"#,
        options: [.caseInsensitive])
    /// "clad" on its own. "Clad in", "iron clad" and "fully clad" are the adjective.
    private static let clad = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])(?<!(?:iron|steel|snow|armor|stone|copper|well|fully|lightly|scantily|heavily|poorly|warmly|ill)[ \t])clad(?=(?:['’]s)?(?![\p{L}\p{N}_'’\-]))(?![ \t]+in(?![\p{L}]))"#,
        options: [.caseInsensitive])

    /// A name the recognizer writes as a real word or another name, rewritten only where the
    /// words around it say which one was meant. "Deploy it on Versailles" is Vercel; "the Treaty
    /// of Versailles" is not. `next` is the word right after the form, `previous` the one before,
    /// `sentence` any word in the same sentence.
    struct ContextRule {
        let forms: [String]
        let word: String
        var previous: Set<String> = []
        var next: Set<String> = []
        var sentence: Set<String> = []
    }

    static let contextRules: [ContextRule] = [
        ContextRule(forms: ["versailles", "versace", "vercelle", "versell"], word: "Vercel",
                    sentence: ["deploy", "deployed", "deploying", "deployment", "deployments", "redeploy", "hosting", "hosted",
                               "serverless", "nextjs", "next.js", "next js", "frontend", "backend", "domain", "domains", "preview",
                               "previews", "repo", "github", "supabase", "netlify", "cloudflare", "railway", "heroku", "dashboard",
                               "env", "v0", "sdk", "api", "cli", "ai sdk", "edge functions", "agent desktop"]),
        ContextRule(forms: ["jupiter"], word: "Jupyter", next: ["notebook", "notebooks", "lab", "kernel", "server"]),
        ContextRule(forms: ["razor"], word: "Razer", next: ["mouse", "keyboard", "headset", "headphones", "laptop", "synapse", "kishi"]),
        ContextRule(forms: ["lift"], word: "Lyft", previous: ["uber", "an uber or", "uber or", "uber and"],
                    next: ["driver", "drivers", "app", "ride", "rides", "or uber", "and uber"]),
        ContextRule(forms: ["duncan"], word: "Dunkin", next: ["donuts", "donut", "doughnuts", "coffee", "iced", "munchkins"]),
        ContextRule(forms: ["grinder"], word: "Grindr", next: ["app", "profile", "date", "hookup"]),
        ContextRule(forms: ["ways"], word: "Waze", next: ["app"], sentence: ["google maps", "directions", "gps"]),
    ]

    /// One expression per rule, matching any of its forms as a whole word.
    private static let contextExpressions: [(ContextRule, NSRegularExpression)] = contextRules.compactMap { rule in
        let alternation = rule.forms.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?<![\p{L}\p{N}_'’\-@#./])(?:"# + alternation + #")(?=(?:['’]s)?(?![\p{L}\p{N}_'’\-]))"#
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (rule, $0) }
    }

    private static let wordToken = try! NSRegularExpression(pattern: #"[\p{L}\p{N}'’.]+"#)

    /// A sentence ends at ! ? a line break, or a period followed by a space ("next.js" is one word).
    private static func sentenceBoundary(in text: Substring, last: Bool) -> String.Index? {
        let indices = last ? Array(text.indices.reversed()) : Array(text.indices)
        return indices.first { index in
            let c = text[index]
            if "!?\n".contains(c) { return true }
            guard c == "." else { return false }
            let following = text.index(after: index)
            return following == text.endIndex || text[following].isWhitespace
        }
    }

    /// The text with each context rule applied where its context is present.
    static func applyingContext(_ text: String, own: Set<String>, lowercaseNames: Bool) -> String {
        var out = text
        for (rule, expression) in contextExpressions where !own.contains(rule.word.lowercased()) {
            do {
                for match in expression.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                    // A form the person saved ("Versailles" in My Words) is theirs.
                    guard let range = Range(match.range, in: out), !own.contains(out[range].lowercased()) else { continue }
                    let before = out[..<range.lowerBound], after = out[range.upperBound...]
                    let sentenceStart = sentenceBoundary(in: before, last: true).map { before.index(after: $0) } ?? before.startIndex
                    let sentenceEnd = sentenceBoundary(in: after, last: false) ?? after.endIndex
                    let lowerBefore = before[sentenceStart...].lowercased(), lowerAfter = after[..<sentenceEnd].lowercased()
                    let words = { (s: String) in wordToken.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } } }
                    let wordsBefore = words(lowerBefore), wordsAfter = words(lowerAfter)
                    func starts(_ list: [String], with phrase: String) -> Bool {
                        let parts = phrase.split(separator: " ").map(String.init)
                        return list.count >= parts.count && Array(list.prefix(parts.count)) == parts
                    }
                    func ends(_ list: [String], with phrase: String) -> Bool {
                        let parts = phrase.split(separator: " ").map(String.init)
                        return list.count >= parts.count && Array(list.suffix(parts.count)) == parts
                    }
                    let sentenceWords = Set(wordsBefore + wordsAfter)
                    let sentenceText = " " + (wordsBefore + wordsAfter).joined(separator: " ") + " "
                    let fits = rule.next.contains { starts(wordsAfter, with: $0) }
                        || rule.previous.contains { ends(wordsBefore, with: $0) }
                        || rule.sentence.contains { $0.contains(" ") ? sentenceText.contains(" \($0) ") : sentenceWords.contains($0) }
                    guard fits else { continue }
                    var written = rule.word
                    if lowercaseNames, !opensSentence(before) { written = written.lowercased() }
                    out.replaceSubrange(range, with: written)
                }
            }
        }
        return out
    }

    /// "Claude", "OpenAI", "Hugging Face": a capital first and a lowercase letter somewhere.
    /// "LLMs" is an acronym with a plural, not a name.
    private static func isNameShaped(_ word: String) -> Bool {
        let stem = word.hasSuffix("s") ? word.dropLast() : Substring(word)
        return word.first?.isUppercase == true && stem.contains(where: \.isLowercase)
    }

    private static func opensSentence(_ before: Substring) -> Bool {
        guard let last = before.last(where: { !$0.isWhitespace && !"\"'“‘([".contains($0) }) else { return true }
        return ".!?\n".contains(last)
    }

    /// The text with every listed form written the standard way. Spellings among `personalWords`
    /// (My Words, contacts, handles) are the person's own and stay.
    ///
    /// `lowercaseNames` is the texting styles: a name-shaped spelling ("Claude Code", "OpenAI",
    /// "TestFlight") is written lowercase unless it opens a sentence. Acronyms ("LLM", "API")
    /// and names that start lowercase ("iPhone") keep their casing in every style.
    static func correcting(_ text: String, personalWords: [String], lowercaseNames: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        let own = Set(personalWords.map { $0.lowercased() })
        var out = text
        func replace(_ expression: NSRegularExpression, with replacement: (String) -> String?) {
            for match in expression.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let found = String(out[range])
                // The person's word, or part of their phrase ("Auto-Correct Pro"), is theirs.
                let lower = found.lowercased()
                guard !own.contains(where: { $0.contains(lower) }), var written = replacement(found) else { continue }
                if lowercaseNames, isNameShaped(written), !opensSentence(out[..<range.lowerBound]) { written = written.lowercased() }
                guard written != found else { continue }
                out.replaceSubrange(range, with: written)
            }
        }
        if !own.contains("claude code") {
            replace(claudeCode) { _ in "Claude Code" }
        }
        replace(clawed) { _ in "Claude" }
        replace(clad) { _ in "Claude" }
        out = applyingContext(out, own: own, lowercaseNames: lowercaseNames)
        if let spokenExpression {
            replace(spokenExpression) { found in
                let key = found.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                guard let word = spoken[key] else { return nil }
                // An everyday word keeps the capital it was said with: "Auto correct had" opens a sentence.
                guard word == word.lowercased(), found.first?.isUppercase == true else { return word }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
        }
        return out
    }
}
