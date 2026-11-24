// by zayd/cold @ zayd.wtf

import Foundation

/// Numbers said out loud, written the way people type them.
///
/// Fluid Speech Mini writes some numbers as digits ("30 minutes", "$5") and spells others
/// ("forty five miles", "five minutes", "T three", "nine thirty"), with no pattern a speaker
/// can predict. This pass makes them one way. Measured on 1,435 recognized dictations
/// (`docs/research/2026-11-10-dictation-numbers-and-modern-words.md`).
///
/// What becomes digits:
/// - any number of two or more words, and any number from ten up: "forty five" is 45, "fifteen"
///   is 15, "two thousand" is 2,000, "five point three" is 5.3, "twenty twenty six" is 2026;
/// - a clock time: "nine thirty" is 9:30, and the recognizer's own "12 30" is 12:30;
/// - a small number (two to nine) where a writer would use a digit: before a unit ("five
///   minutes"), in a range ("two to three times"), or after a label ("T three" is T3, "number
///   two", "IE seven").
///
/// What stays as said: a small number counting things ("two things", "the other two buttons"),
/// every "one" that is not part of a range, a label or a larger number ("this one", "one second"),
/// "a million things", ordinals, a spelled sequence ("one two three") and a capitalized title
/// ("Five Guys"). Only whole words between spaces are read, so a URL, a path or code is never
/// touched.
///
/// Two rules on top, from Zayd's own messages (2026-11-19, "8 or 9 maybe seven"):
/// - Numbers agree. A small number standing on its own beside one already written as a digit
///   is a digit too, in every style: "8 or 9, maybe 7".
/// - The texting styles pass `small: .digits`: two to nine are digits wherever they are plain
///   numbers ("around 7", "the first 3 lines", "2 things"), because that is how people text.
///   Spelling a small number out is formal writing. A fraction ("two thirds"), a few idioms
///   ("high five"), a spelled sequence and every "one" stay as said.
public enum SpokenNumbers {
    /// How two to nine are written where no rule above makes them a digit.
    public enum Small: Sendable {
        /// As the person said them: "around seven". Formal writing.
        case asSaid
        /// As digits: "around 7". How people text.
        case digits
        case alwaysDigits, words

        var isExplicit: Bool { self == .alwaysDigits || self == .words }
    }

    static func mightContainNumber(_ text: String, small: Small = .asSaid) -> Bool {
        if small.isExplicit && text.utf8.contains(where: { (48...57).contains($0) }) { return true }
        return trigger.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func writingDigits(_ text: String, small: Small = .asSaid) -> String {
        guard mightContainNumber(text, small: small) else { return text }
        return writingDetectedNumbers(text, small: small)
    }

    static func writingDetectedNumbers(_ text: String, small: Small, listComma: String? = nil,
                                       listDigits: Bool = false) -> String {
        var tokens: [Token] = []
        var gaps: [String] = []
        var gap = ""
        var chunk = ""
        for character in text {
            if character.isWhitespace {
                if !chunk.isEmpty { tokens.append(Token(chunk)); gaps.append(gap); chunk = ""; gap = "" }
                gap.append(character)
            } else {
                chunk.append(character)
            }
        }
        if !chunk.isEmpty { tokens.append(Token(chunk)); gaps.append(gap); gap = "" }
        let trailingGap = gap
        guard !tokens.isEmpty else { return text }

        if small.isExplicit {
            for i in tokens.indices.dropLast() where tokens[i].lower == "a" && tokens[i].trail.isEmpty
                && tokens[i + 1].lower == "hundred" && !gaps[i + 1].contains(where: \.isNewline) {
                tokens[i] = Token(tokens[i].lead + "one")
            }
        }
        var output: [String?] = tokens.map { Optional($0.raw) }
        // Where a short plain number stands as digits: the recognizer's own or one written here.
        var digitAt = tokens.map { isShortNumber($0.core) }
        var firstPoint: Int?
        var clockInMessage = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // Only a marked pause starts a point. A count such as "buy one, get two" does not.
            if let listComma, (token.trail == "," || (token.trail.isEmpty && index + 1 < gaps.count
                && gaps[index + 1].contains(where: \.isNewline))),
               let point = units[token.lower] ?? (token.core.count == 1 ? Int(token.core) : nil), point > 0 {
                let previous = index > 0 ? tokens[index - 1] : nil
                let opens = previous == nil || previous?.endsSentence == true || gaps[index].contains(where: \.isNewline)
                let followsCue = previous.map { beforeSpokenPoint.contains($0.lower) || ["first", "second"].contains($0.lower) } == true
                let joinsCounts = index >= 2 && previous?.lower == "and" && tokens[index - 2].isNumberish
                    && tokens[index - 2].trail.isEmpty
                if point == 1, opens || followsCue {
                    // A lone "one," can be a count. Keep its pause only when another point follows.
                    firstPoint = index
                } else if point > 1, !joinsCounts, (followsCue || (firstPoint != nil && (opens || previous?.trail.contains(",") == true
                    || previous?.trail.contains(";") == true))) {
                    if let firstPoint {
                        let first = tokens[firstPoint]
                        output[firstPoint] = first.lead + first.core + listComma
                    }
                    let marker = listDigits ? String(point) : token.core
                    output[index] = token.lead + marker + listComma
                    index += 1
                    continue
                }
            }
            if small.isExplicit, let phone = phoneDigits(at: index, tokens: tokens, gaps: gaps) {
                output[index] = token.lead + phone.text + tokens[phone.end - 1].trail
                for consumed in (index + 1)..<phone.end { output[consumed] = nil }
                index = phone.end
            } else if let clock = clockTime(at: index, in: tokens, gaps: gaps) {
                clockInMessage = true
                output[index] = tokens[index].lead + clock.text + tokens[clock.end - 1].trail
                for consumed in (index + 1)..<clock.end { output[consumed] = nil }
                digitAt[index] = true
                index = clock.end
            } else if let written = number(at: index, in: tokens, small: small) {
                output[index] = tokens[index].lead + written.text + tokens[written.end - 1].trail
                for consumed in (index + 1)..<max(written.end, index + 1) { output[consumed] = nil }
                if written.joinsPrevious { gaps[index] = "" }
                digitAt[index] = !written.joinsPrevious && isShortNumber(written.text)
                index = written.end
            } else {
                index += 1
            }
        }
        if clockInMessage || tokens.contains(where: { $0.core.contains(":") && existingClock($0.core) }) {
            for index in tokens.indices where output[index] == tokens[index].raw {
                guard index == 0 || output[index - 1] != nil,
                      let value = hour(tokens[index]), tokens[index].numbers != nil,
                      clockTail(after: index + 1, in: tokens),
                      hasClockLead(before: index, in: tokens) else { continue }
                output[index] = tokens[index].lead + String(value) + tokens[index].trail
                digitAt[index] = true
            }
            // "1118 or 12:18 pm": one of two times joined by "or" was written as a clock, so the
            // other is one too. Two bare numbers ("215 or 330 seats") decide nothing.
            for index in tokens.indices where output[index] == tokens[index].raw {
                guard let (hour, minute, end) = clockDigits(at: index, in: tokens), end == index + 1,
                      index == 0 || !(labels.contains(tokens[index - 1].lower) || nonClockLeads.contains(tokens[index - 1].lower)),
                      [index + 2, index - 2].contains(where: { other in
                          let (left, right) = (min(index, other), max(index, other))
                          guard tokens.indices.contains(other), let written = output[other],
                                existingClock(Token(written).core), output[left + 1] != nil,
                                clockConnectors.contains(tokens[left + 1].lower), tokens[left].trail.isEmpty,
                                tokens[left + 1].trail.isEmpty, tokens[left + 1].lead.isEmpty,
                                tokens[right].lead.isEmpty else { return false }
                          return true
                      }) else { continue }
                output[index] = tokens[index].lead + "\(hour):" + String(format: "%02d", minute) + tokens[index].trail
                digitAt[index] = true
            }
        }
        // Numbers agree: "8 or 9, maybe seven" is "8 or 9, maybe 7".
        // Counted in written words, so a second pass over the result decides the same.
        let written = tokens.indices.filter { output[$0] != nil }
        for (position, index) in written.enumerated() where !small.isExplicit && output[index] == tokens[index].raw {
            guard let value = loneSmallNumber(at: index, in: tokens) else { continue }
            let near = written[max(0, position - agreementReach)...min(written.count - 1, position + agreementReach)]
            guard near.contains(where: { $0 != index && digitAt[$0] }) else { continue }
            output[index] = tokens[index].lead + String(value) + tokens[index].trail
        }
        var out = ""
        for (position, piece) in output.enumerated() {
            guard let piece else { continue }
            out += gaps[position] + piece
        }
        return out + trailingGap
    }

    // MARK: Tokens

    private static let trigger = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:half|quarter|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|(?:thir|four|fif|six|seven|eigh|nine)teen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|point|\d{3,4}(?!\d)|\d{1,2}(?:[ \t]+|\.)[0-5]\d)(?![\p{L}])"#, options: [.caseInsensitive])

    private struct Token {
        let raw: String
        let lead: String
        let core: String
        let trail: String
        let lower: String
        /// The core as number words ("forty-five" is two), or nil when it is anything else.
        let numbers: [String]?
        let isDigits: Bool

        init(_ raw: String) {
            self.raw = raw
            var start = raw.startIndex
            while start < raw.endIndex, "\"'“‘([{".contains(raw[start]) { start = raw.index(after: start) }
            var end = raw.endIndex
            while end > start, ".,!?;:\"'”’)]}".contains(raw[raw.index(before: end)]) { end = raw.index(before: end) }
            lead = String(raw[..<start])
            core = String(raw[start..<end])
            trail = String(raw[end...])
            lower = core.lowercased().replacingOccurrences(of: "’", with: "'")
            let parts = lower.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            numbers = !parts.isEmpty && parts.allSatisfy({ SpokenNumbers.isNumberWord($0) }) ? parts : nil
            isDigits = !core.isEmpty && core.allSatisfy { $0.isASCII && $0.isNumber }
        }

        var clockBase: Token {
            guard lower.hasSuffix("-ish") else { return self }
            return Token(lead + String(core.dropLast(4)) + trail)
        }

        var isNumberish: Bool { numbers != nil || isDigits }
        var startsUppercase: Bool { core.first?.isUppercase == true }
        var endsSentence: Bool { trail.contains(where: { ".!?".contains($0) }) }
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    private static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || teens[word] != nil || tens[word] != nil || scales[word] != nil || word == "hundred"
    }

    // MARK: Reading a number

    private struct Cardinal {
        var value: Int
        /// One past the last token.
        var end: Int
        var words: Int
        /// The largest of thousand, million and billion that was said, or 0.
        var scale: Int
    }

    private enum Kind { case start, zero, unit, teen, tens, hundred, scale, and }

    /// The longest well-formed number starting at `start`: "two hundred and five", "forty-five",
    /// "three million". "one two" is two numbers and "twenty thirty" is two, so each stops at one.
    private static func cardinal(in tokens: [Token], from start: Int) -> Cardinal? {
        var total = 0, current = 0, last = Kind.start, lowestScale = Int.max, hasHundred = false
        var words = 0, scale = 0
        var best: Cardinal?
        var index = start
        scan: while index < tokens.count {
            let token = tokens[index]
            if index > start, !token.lead.isEmpty { break }
            if token.lower == "and", last == .hundred || last == .scale, token.trail.isEmpty, index + 1 < tokens.count,
               tokens[index + 1].lead.isEmpty, let next = tokens[index + 1].numbers?.first,
               units[next] != nil || teens[next] != nil || tens[next] != nil {
                last = .and
                index += 1
                continue
            }
            guard let parts = token.numbers else { break }
            var (nextTotal, nextCurrent, nextLast, nextLowest, nextHundred, nextScale) =
                (total, current, last, lowestScale, hasHundred, scale)
            for part in parts {
                if let value = units[part] {
                    if value == 0 {
                        guard nextLast == .start else { break scan }
                        nextLast = .zero
                    } else {
                        guard [.start, .tens, .hundred, .scale, .and].contains(nextLast) else { break scan }
                        nextCurrent += value
                        nextLast = .unit
                    }
                } else if let value = teens[part] ?? tens[part] {
                    guard [.start, .hundred, .scale, .and].contains(nextLast) else { break scan }
                    nextCurrent += value
                    nextLast = teens[part] != nil ? .teen : .tens
                } else if part == "hundred" {
                    guard nextLast == .unit || nextLast == .teen, !nextHundred, (1...99).contains(nextCurrent) else { break scan }
                    nextCurrent *= 100
                    nextHundred = true
                    nextLast = .hundred
                } else if let value = scales[part] {
                    guard nextCurrent > 0, value < nextLowest else { break scan }
                    nextTotal += nextCurrent * value
                    nextCurrent = 0
                    nextHundred = false
                    nextLowest = value
                    nextScale = max(nextScale, value)
                    nextLast = .scale
                }
            }
            (total, current, last, lowestScale, hasHundred, scale) =
                (nextTotal, nextCurrent, nextLast, nextLowest, nextHundred, nextScale)
            words += parts.count
            index += 1
            best = Cardinal(value: total + current, end: index, words: words, scale: scale)
            if !token.trail.isEmpty { break }
        }
        return best
    }

    private static func formatted(_ number: Cardinal) -> String {
        if number.scale >= 1_000_000, number.value % (number.scale / 1_000) == 0 {
            // "two million", "one point five billion" as people write them.
            let whole = number.value / number.scale
            let thousandths = (number.value % number.scale) / (number.scale / 1_000)
            var text = String(whole)
            if thousandths > 0 {
                var fraction = String(format: "%03d", thousandths)
                while fraction.hasSuffix("0") { fraction.removeLast() }
                text += "." + fraction
            }
            return text + (number.scale == 1_000_000 ? " million" : " billion")
        }
        guard number.scale > 0 else { return String(number.value) }
        var digits = String(number.value)
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + digits.suffix(3) + grouped
            digits.removeLast(3)
        }
        return digits + grouped
    }

    // MARK: Deciding

    private struct Written {
        var text: String
        var end: Int
        /// "T three" is the one word T3.
        var joinsPrevious = false
    }

    /// Units a writer puts a digit in front of. Singular forms cover "a five minute break".
    private static let measures: Set<String> = [
        "second", "seconds", "sec", "secs", "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs",
        "day", "days", "week", "weeks", "month", "months", "year", "years", "yr", "yrs", "decade", "decades",
        "dollar", "dollars", "buck", "bucks", "cent", "cents", "grand", "percent", "am", "pm", "a.m", "p.m",
        "o'clock", "ish", "times", "x", "pound", "pounds", "lb", "lbs", "ounce", "ounces", "oz", "gram", "grams",
        "kilo", "kilos", "kg", "mg", "ml", "liter", "liters", "gallon", "gallons", "mile", "miles", "foot", "feet",
        "inch", "inches", "yard", "yards", "meter", "meters", "km", "mph", "degree", "degrees", "pixel", "pixels",
        "px", "point", "points", "byte", "bytes", "megabyte", "megabytes", "gigabyte", "gigabytes", "gig", "gigs",
        "mb", "gb", "tb", "hz", "fps", "volt", "volts", "watt", "watts", "caliber", "star", "stars"]

    /// The few a lone "one" takes a digit before: "one percent", "one pm". "One second" and "one
    /// day" are how people talk.
    private static let measuresOfOne: Set<String> = ["percent", "am", "pm", "a.m", "p.m", "o'clock"]

    /// Words a number names an instance of: "number two", "version three", "building one".
    /// Not "no": "no one came" and "no two are alike" are far more common than a spoken "No. 1".
    private static let labels: Set<String> = [
        "number", "version", "building", "room", "chapter", "page", "step", "level", "phase", "season",
        "episode", "gate", "option", "part", "tier", "round", "top", "gen", "model", "exit", "route", "highway",
        "floor", "grade", "size", "type", "class", "bay", "lot", "unit", "apartment", "apt", "suite", "terminal",
        "platform", "track", "channel", "person", "player", "day", "week", "quarter", "act", "volume", "figure",
        "question", "rule", "item"]

    /// Products with numbered versions: "iPhone seven", "Opus four". Never with "one", which after
    /// a name is usually the start of something else ("Claude one shot this").
    private static let versioned: Set<String> = [
        "iphone", "ios", "ipad", "windows", "claude", "opus", "sonnet", "haiku", "gemini", "llama", "gpt", "pixel"]

    /// Capitals that are ordinary words in a sentence, not the name of a numbered thing: after
    /// "AI" or "TV" a small number is counting ("free local AI zero data collection").
    private static let commonAcronyms: Set<String> = [
        "AI", "API", "OK", "TV", "US", "UK", "EU", "UN", "CEO", "CTO", "CFO", "UI", "UX", "URL", "ID", "DM", "PR",
        "QA", "HR", "IT", "PM", "AM", "PC", "LOL", "IDK", "TBH", "BTW", "OMG", "FYI", "ASAP", "DIY", "FAQ", "PDF",
        "LLM", "MCP", "SDK", "CLI", "GPU", "CPU", "VPN", "USA", "NYC", "LA", "SF", "ETA", "RSVP", "PS", "AC", "DJ"]

    /// "One by one" and "two by two" are idioms, so "by" is not here.
    private static let rangeWords: Set<String> = ["to", "or", "through"]

    /// What comes before a time said as two numbers: "at nine thirty", "maybe twelve fifteen".
    private static let beforeTime: Set<String> = [
        "at", "by", "until", "till", "til", "around", "before", "after", "since", "from", "to", "between", "like", "say", "maybe",
        "is", "was", "it's", "its", "or", "and", "about", "for", "tomorrow", "tonight", "today", "probably", "past"]

    /// What follows a time said as two numbers, "8 30 if that works".
    private static let afterTime: Set<String> = [
        "am", "pm", "a.m", "p.m", "ish", "sharp", "if", "or", "and", "so", "but", "is", "works", "tomorrow",
        "tonight", "today", "then", "on", "at", "for", "would", "maybe"]

    /// "later than twelve forty five" and "earlier than nine thirty" compare clock times. "Than"
    /// alone is not a sign of one: "more than one fifty" is a price or a count.
    private static let timeComparatives: Set<String> = ["later", "earlier", "sooner"]

    private static func comparesTimes(before index: Int, in tokens: [Token]) -> Bool {
        guard index >= 2 else { return false }
        let than = tokens[index - 1], comparative = tokens[index - 2]
        return than.lower == "than" && than.trail.isEmpty && comparative.trail.isEmpty
            && timeComparatives.contains(comparative.lower)
    }

    /// "8", "12" or "8:30": a short number as digits, the kind a lone small number agrees with.
    private static func isShortNumber(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hour = parts.first, (1...2).contains(hour.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        return parts.count == 1 || parts[1].count == 2
    }

    /// How many words away a digit still decides how a lone small number is written.
    private static let agreementReach = 4

    /// What may follow a number that counts nothing: "seven or", "seven if that works".
    private static let afterLoneNumber: Set<String> = [
        "or", "to", "and", "maybe", "if", "so", "but", "then", "at", "on", "is", "works", "work", "would", "i",
        "we", "any", "anytime", "ish", "probably", "tonight", "tomorrow", "today", "instead", "either", "too",
        "also", "though", "because", "sharp", "max", "tops", "latest", "earliest", "depending", "whenever"]

    /// Two to nine as one plain word that counts nothing after it ("maybe seven,", "seven or"),
    /// not a title and not part of a spelled sequence. Its value, or nil.
    private static func loneSmallNumber(at index: Int, in tokens: [Token]) -> Int? {
        let token = tokens[index]
        guard let parts = token.numbers, parts.count == 1, let value = units[parts[0]], value >= 2,
              plainSmallNumber(token, at: index, in: tokens) else { return nil }
        if !token.trail.isEmpty || index + 1 == tokens.count { return value }
        let next = tokens[index + 1]
        return next.lead.isEmpty && afterLoneNumber.contains(next.lower) ? value : nil
    }

    /// Words a small number forms a fraction with: "two thirds", "three quarters".
    private static let fractionParts: Set<String> = [
        "thirds", "quarters", "fourths", "fifths", "sixths", "sevenths", "eighths", "ninths", "tenths", "halves"]

    /// The word before a small number in a saying: "high five", "take five", "cloud nine".
    private static let beforeSaidNumber: Set<String> = ["high", "take", "cloud", "fantastic", "big", "fab"]

    /// A small number that is a plain number where it stands: not a mid-sentence title ("Five
    /// Guys"), a fraction, a saying, "two by two", or one of a run said one at a time ("one two
    /// three", "this one and two more").
    private static func plainSmallNumber(_ token: Token, at index: Int, in tokens: [Token], explicit: Bool = false) -> Bool {
        if token.startsUppercase, index > 0, !tokens[index - 1].endsSentence { return false }
        let next: Token? = index + 1 < tokens.count && token.trail.isEmpty && tokens[index + 1].lead.isEmpty ? tokens[index + 1] : nil
        let previous: Token? = index > 0 && tokens[index - 1].trail.isEmpty && token.lead.isEmpty ? tokens[index - 1] : nil
        if !explicit && countingOne(near: index, in: tokens) { return false }
        if let next {
            if next.isNumberish || fractionParts.contains(next.lower) { return false }
            if next.lower == "by", index + 2 < tokens.count, tokens[index + 2].lower == token.lower { return false }
        }
        // "One I hope that's done, but two there's a button": the second point of a list said
        // out loud, not a count.
        let opensClause = index == 0 || tokens[index - 1].endsSentence
            || (previous.map { beforeSpokenPoint.contains($0.lower) } ?? false)
        if opensClause, let next,
           afterSpokenPoint.contains(String(next.lower.prefix(while: { $0 != "'" }))) { return false }
        if let previous {
            if previous.isNumberish || beforeSaidNumber.contains(previous.lower) { return false }
            // "catch one and two": the "one" stays a word, so its partner does.
            if ["and", "or"].contains(previous.lower), index >= 2, tokens[index - 2].lower == "one",
               tokens[index - 2].trail.isEmpty { return false }
            if previous.lower == "by", index >= 2, tokens[index - 2].lower == token.lower { return false }
        }
        return true
    }

    /// Around a number that names a point being made: "but two, I want", "and three there's".
    private static let beforeSpokenPoint: Set<String> = ["but", "and", "then", "so", "okay", "well", "also", "plus"]
    /// With a contraction read by its first word: "there's", "I'd", "it's".
    private static let afterSpokenPoint: Set<String> = [
        "i", "we", "you", "it", "they", "there", "the", "that", "this", "if", "when", "like", "let"]

    /// Before "one", the words that make it a pronoun: "this one", "the other one", "no one".
    private static let beforePronounOne: Set<String> = [
        "this", "that", "the", "which", "no", "any", "every", "each", "another", "only", "last", "first", "other",
        "same", "right", "wrong", "new", "old", "good", "big", "little", "next", "least", "at"]
    /// After "one", the words that show it counts nothing: "one of", "one is", "one that".
    private static let afterPronounOne: Set<String> = [
        "of", "is", "was", "that", "who", "which", "to", "and", "or", "more", "by", "in", "on", "at", "for", "with",
        "has", "had", "can", "will", "would", "should", "does", "did", "it", "i", "you", "we", "they", "he", "she",
        "but", "so", "if", "because", "day", "second", "sec", "minute", "moment", "time", "thing"]

    /// A "one" that counts something ("one apple") within reach of `index`. It stays a word, so
    /// the number beside it does too: "one apple and two pears", never "one apple and 2 pears".
    private static func countingOne(near index: Int, in tokens: [Token]) -> Bool {
        for other in max(0, index - agreementReach)...min(tokens.count - 1, index + agreementReach) where other != index {
            let token = tokens[other]
            guard token.lower == "one", token.trail.isEmpty, other + 1 < tokens.count else { continue }
            let next = tokens[other + 1]
            guard next.lead.isEmpty, next.core.first?.isLetter == true, !next.isNumberish,
                  !afterPronounOne.contains(next.lower), !next.lower.contains("'") else { continue }
            if other > 0, tokens[other - 1].trail.isEmpty, beforePronounOne.contains(tokens[other - 1].lower) { continue }
            return true
        }
        return false
    }

    private static func number(at index: Int, in tokens: [Token], small: Small) -> Written? {
        let token = tokens[index]
        if token.isDigits {
            guard small == .words, token.core.count == 1, let value = Int(token.core),
                  !numericContext(at: index, in: tokens) else { return nil }
            return Written(text: digitWords[value], end: index + 1)
        }
        if token.lower == "point" { return barePoint(at: index, in: tokens) }
        if token.numbers == nil { return hyphenatedMeasure(token, at: index, explicit: small.isExplicit) }
        guard var run = cardinal(in: tokens, from: index) else { return nil }
        // A capital in the middle of a sentence is a title or a name: "Five Guys", "Seven Eleven".
        if token.startsUppercase, index > 0, !tokens[index - 1].endsSentence { return nil }
        let single = run.words == 1 && tokens[index].trail.isEmpty

        // "twenty four seven"
        if run.value == 24, run.words == 2, run.end < tokens.count, tokens[run.end - 1].trail.isEmpty,
           tokens[run.end].lead.isEmpty, tokens[run.end].lower == "seven" {
            return Written(text: "24/7", end: run.end + 1)
        }
        // A year: "twenty twenty six", "nineteen ninety nine", "twenty ten".
        // "ten fifteen minute breaks" and "twenty thirty people" are two counts, not one number.
        if single, run.value == 1, let second = twoDigits(in: tokens, from: run.end),
           second.end < tokens.count, tokens[second.end].lower == "second", tokens[second.end - 1].trail.isEmpty {
            // "one thirty second" can be a fraction, even if the recognizer omitted its hyphens.
            return Written(text: tokens[index..<second.end].map(\.core).joined(separator: " "), end: second.end)
        }
        if single, let second = twoDigits(in: tokens, from: run.end),
           !(second.end < tokens.count && tokens[second.end - 1].trail.isEmpty && isMeasure(tokens[second.end])
             && !afterTime.contains(tokens[second.end].lower)) {
            if (18...20).contains(run.value) {
                return Written(text: String(run.value) + second.text, end: second.end)
            }
            // A plausible spoken pair also describes prices, scores and identifiers.
            // If the clock pass could not resolve it, leave both words together.
            if (1...12).contains(run.value), second.value < 60 {
                let words = tokens[index..<second.end].map(\.raw).joined(separator: " ")
                return Written(text: String(words.dropFirst(token.lead.count).dropLast(tokens[second.end - 1].trail.count)), end: second.end)
            }
        }

        var text = formatted(run)
        var decimal = false
        // "five point three", "one point o".
        if tokens[run.end - 1].trail.isEmpty, run.end + 1 < tokens.count, tokens[run.end].raw.lowercased() == "point",
           let digits = spokenDigits(in: tokens, from: run.end + 1), run.scale == 0 {
            text += "." + digits.text
            run.end = digits.end
            decimal = true
        }
        let last = tokens[run.end - 1]
        let next: Token? = run.end < tokens.count && last.trail.isEmpty && tokens[run.end].lead.isEmpty ? tokens[run.end] : nil
        let previous: Token? = index > 0 && tokens[index - 1].trail.isEmpty && token.lead.isEmpty ? tokens[index - 1] : nil

        var joins = false
        if run.words == 1, run.value < 10, !decimal {
            // "five, six hours": two numbers with only a comma between are one estimate.
            let listed = (last.trail == "," && run.end < tokens.count && tokens[run.end].lead.isEmpty && tokens[run.end].isNumberish)
                || (index > 0 && token.lead.isEmpty && tokens[index - 1].trail == "," && tokens[index - 1].isNumberish)
            let inRange = listed || isRange(next, tokens, run.end + 1, forward: true)
                || isRange(previous, tokens, index - 2, forward: false)
            let measured = next.map { run.value == 1 ? measuresOfOne.contains($0.lower) : isMeasure($0) } ?? false
            var labelled = false
            if let previous, !(run.value == 1 && next?.lower == "of") {
                let label = previous.core
                if label.count == 1, label.first?.isUppercase == true, label != "A", label != "I" {
                    labelled = true
                    joins = true
                } else if labels.contains(previous.lower) {
                    labelled = true
                } else if run.value >= 2, versioned.contains(previous.lower) {
                    labelled = true
                } else if run.value >= 2, (2...5).contains(label.count), label.allSatisfy({ $0.isUppercase }),
                          !commonAcronyms.contains(label) {
                    labelled = true
                }
            }
            let texted = small == .digits && run.value >= 2 && plainSmallNumber(token, at: index, in: tokens)
            let explicitDigit = small.isExplicit && numericContext(at: index, in: tokens)
            let plainDigit = small == .alwaysDigits && plainSmallNumber(token, at: index, in: tokens, explicit: true)
                && (run.value != 1 || countsOne(at: index, in: tokens))
            guard explicitDigit || plainDigit || inRange || measured || labelled || texted else { return nil }
        }
        if let next, next.lower == "percent" {
            return Written(text: text + "%" , end: run.end + 1, joinsPrevious: joins)
        }
        return Written(text: text, end: run.end, joinsPrevious: joins)
    }

    private static let digitWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let streets: Set<String> = ["road", "street", "avenue", "drive", "lane", "boulevard", "court", "rd", "st", "ave", "blvd"]
    private static let extraMeasures: Set<String> = ["cm", "mm", "ft", "inches", "kilometers", "kilometres", "metres", "milliseconds", "euros", "euro", "yen", "kilograms", "kilogram", "grams", "litres", "litre", "kilowatt", "kilowatts", "%", "°c", "°f"]

    /// Convert a counting "one" only with positive evidence of a following noun.
    /// Unknown grammatical roles stay words, including a standalone "one".
    private static func countsOne(at index: Int, in tokens: [Token]) -> Bool {
        guard index + 1 < tokens.count, tokens[index].trail.isEmpty else { return false }
        let next = tokens[index + 1].lower
        let previous = index > 0 && tokens[index - 1].trail.isEmpty ? tokens[index - 1].lower : ""
        let quantityLead = ["have", "has", "had", "got", "bought", "buy", "need", "needs", "want", "take", "took", "bring", "send", "sent", "saw", "found", "only", "exactly", "just", "another", "with"]
        return (index == 0 || quantityLead.contains(previous)) && !beforePronounOne.contains(previous)
            && !afterPronounOne.contains(next) && !["more", "else", "must", "could", "might", "should", "never", "that", "way"].contains(next)
            && tokens[index + 1].core.allSatisfy(\.isLetter)
    }

    private static func numericContext(at i: Int, in tokens: [Token]) -> Bool {
        let token = tokens[i]
        let before = i > 0 && tokens[i - 1].trail.isEmpty ? tokens[i - 1] : nil
        let after = i + 1 < tokens.count && token.trail.isEmpty ? tokens[i + 1] : nil
        if let before, ["$", "£", "€", "¥", "+", "minus", "negative"].contains(before.core)
            || (before.core.count == 1 && before.core.first?.isUppercase == true && !["A", "I"].contains(before.core)) { return true }
        if token.isDigits, token.trail == ".", i == 0 || tokens[i - 1].endsSentence, after == nil,
           i + 1 < tokens.count, tokens[i + 1].startsUppercase { return true }
        if isScheduledHour(at: i, in: tokens, before: before, after: after) { return true }
        if let before, labels.contains(before.lower)
            || (versioned.contains(before.lower) && (token.isDigits || token.lower != "one"))
            || (token.isDigits && (2...5).contains(before.core.count) && before.core.allSatisfy(\.isUppercase)
                && !commonAcronyms.contains(before.core))
            || SpokenOrdinals.months.contains(before.lower) || ["age", "aged"].contains(before.lower) { return true }
        if token.lower == "one", let after {
            // "One second!" asks someone to wait. "One day" can mean someday.
            // An explicit duration (for one day, one second of silence) stays numeric.
            let duration = ["for", "in", "within", "lasts", "lasted", "takes", "took", "after", "every"].contains(before?.lower)
                || (i + 2 < tokens.count && ["of", "later", "ago", "old", "long", "per"].contains(tokens[i + 2].lower))
            if !duration && ["second", "day", "moment"].contains(after.lower) { return false }
        }
        if before?.lower == "and", i >= 3, tokens[i - 2].isNumberish,
           labels.contains(tokens[i - 3].lower) { return true }
        if let after, isMeasure(after) || extraMeasures.contains(after.lower) || after.lower == "million"
            || after.lower == "billion" || after.lower == "year-old" { return true }
        if isRange(after, tokens, i + 2, forward: true) || isRange(before, tokens, i - 2, forward: false) { return true }
        if after?.lower == "of", i + 2 < tokens.count, tokens[i + 2].isNumberish { return true }
        if before?.lower == "of", i >= 2, tokens[i - 2].isNumberish { return true }
        if token.isDigits, (before?.isDigits == true || after?.isDigits == true) { return true }
        // One named street, optionally with a compass direction.
        if let after, after.core.first?.isLetter == true, after.trail.isEmpty, i + 2 < tokens.count {
            if streets.contains(tokens[i + 2].lower) { return true }
            if ["north", "south", "east", "west"].contains(after.lower), i + 3 < tokens.count,
               tokens[i + 2].trail.isEmpty, streets.contains(tokens[i + 3].lower) { return true }
        }
        return false
    }

    private static func isScheduledHour(at i: Int, in tokens: [Token], before: Token?, after: Token?) -> Bool {
        let token = tokens[i]
        guard hour(token) != nil else { return false }
        if hasClockLead(before: i, in: tokens), clockTail(after: i + 1, in: tokens),
           nearby(scheduleWords, before: i, in: tokens, limit: 6) || after.map({ timeAdverbs.contains($0.lower) }) == true {
            return true
        }
        if before?.lower == "to", i >= 2, ["noon", "midnight"].contains(tokens[i - 2].lower) { return true }
        if token.trail == ",", i + 2 < tokens.count, hour(tokens[i + 1]) != nil,
           clockSuffixes.contains(tokens[i + 2].lower) { return true }
        if hasClockLead(before: i, in: tokens) {
            let travel: Set<String> = ["arrive", "leave", "leaving", "depart"]
            let gettingOut = i >= 3 && tokens[i - 3..<i].map(\.lower) == ["of", "here", "around"]
            let leavesNext = after?.lower == "and" && i + 2 < tokens.count && travel.contains(tokens[i + 2].lower)
            if gettingOut || nearby(travel, before: i, in: tokens, limit: 8) || leavesNext,
               clockTail(after: i + 1, in: tokens) || leavesNext {
                return true
            }
        }
        // A proposed hour beside alternatives still agrees with them: "8 or 9,
        // maybe seven, anytime after that".
        if before?.lower == "maybe", i >= 3, hour(tokens[i - 2]) != nil, ["or", "to"].contains(tokens[i - 3].lower) { return true }
        return false
    }

    /// Read whole phone-length runs without losing their leading zeroes. Short
    /// strings of consecutive spoken digits can be counting practice.
    private static func phoneDigits(at start: Int, tokens: [Token], gaps: [String]) -> Written? {
        func digit(_ token: Token) -> String? {
            if let value = units[token.lower] { return String(value) }
            if token.lower == "oh" { return "0" }
            return token.isDigits && token.core.count == 1 ? token.core : nil
        }
        // A suffix of a longer sequence cannot become a separate phone number.
        if start > 0, tokens[start - 1].trail.isEmpty, tokens[start].lead.isEmpty,
           !gaps[start].contains(where: \.isNewline), digit(tokens[start - 1]) != nil { return nil }
        var digits = ""
        var end = start
        while end < tokens.count, end == start || (tokens[end - 1].trail.isEmpty && tokens[end].lead.isEmpty
            && !gaps[end].contains(where: \.isNewline)) {
            guard let next = digit(tokens[end]) else { break }
            digits += next
            end += 1
            if digits.count > 15 { return nil }
        }
        let phoneCue = nearby(["phone", "call", "text", "mobile", "cell", "telephone"], before: start, in: tokens, limit: 5)
        guard [7, 10, 11].contains(digits.count) || (phoneCue && (7...15).contains(digits.count)) else { return nil }
        return Written(text: digits, end: end)
    }

    private static func isMeasure(_ token: Token) -> Bool {
        measures.contains(token.lower) || (token.lower.hasSuffix(".") && measures.contains(String(token.lower.dropLast())))
    }

    /// A small number beside "to" or "or" and another number: "two to three", "5 or six".
    private static func isRange(_ connector: Token?, _ tokens: [Token], _ other: Int, forward: Bool) -> Bool {
        guard let connector, rangeWords.contains(connector.lower), connector.trail.isEmpty, connector.lead.isEmpty,
              tokens.indices.contains(other), tokens[other].isNumberish else { return false }
        return forward ? tokens[other].lead.isEmpty : tokens[other].trail.isEmpty
    }

    /// The second half of a year or a time: "thirty", "forty five", "fifteen", "oh five".
    private static func twoDigits(in tokens: [Token], from start: Int) -> (text: String, end: Int, value: Int)? {
        guard start < tokens.count, tokens[start - 1].trail.isEmpty, tokens[start].lead.isEmpty else { return nil }
        if ["oh", "o"].contains(tokens[start].lower), tokens[start].trail.isEmpty, start + 1 < tokens.count,
           tokens[start + 1].lead.isEmpty,
           let value = units[tokens[start + 1].lower] ?? Int(tokens[start + 1].core),
           (1...9).contains(value) {
            return ("0" + String(value), start + 2, value)
        }
        guard tokens[start].numbers != nil, let run = cardinal(in: tokens, from: start), run.scale == 0,
              (10...99).contains(run.value), run.words <= 2 else { return nil }
        return (String(run.value), run.end, run.value)
    }

    /// Digits said one at a time after "point": "three", "o one", "two five".
    private static func spokenDigits(in tokens: [Token], from start: Int) -> (text: String, end: Int)? {
        var text = ""
        var index = start
        while index < tokens.count, tokens[index].lead.isEmpty {
            let token = tokens[index]
            if let parts = token.numbers, parts.count == 1, let value = units[parts[0]] {
                text += String(value)
            } else if ["o", "oh"].contains(token.lower) {
                text += "0"
            } else {
                break
            }
            index += 1
            if !token.trail.isEmpty { break }
        }
        return text.isEmpty ? nil : (text, index)
    }

    private static let beforeBarePoint: Set<String> = [
        "is", "was", "of", "at", "to", "by", "around", "about", "like", "just", "only", "and", "or"]

    /// "one is point four": a fraction with no whole part, after a word that takes a value.
    private static func barePoint(at index: Int, in tokens: [Token]) -> Written? {
        let token = tokens[index]
        guard token.trail.isEmpty, token.lead.isEmpty, index > 0, tokens[index - 1].trail.isEmpty,
              beforeBarePoint.contains(tokens[index - 1].lower),
              let digits = spokenDigits(in: tokens, from: index + 1) else { return nil }
        let last = tokens[digits.end - 1]
        guard digits.end == tokens.count || !last.trail.isEmpty || isMeasure(tokens[digits.end]) else { return nil }
        return Written(text: "0." + digits.text, end: digits.end)
    }

    // MARK: Clock times

    private static let clockPrepositions: Set<String> = [
        "at", "after", "before", "by", "around", "until", "till", "til", "since"]
    private static let clockAlternatives: Set<String> = [
        "like", "maybe", "say", "about", "probably", "from", "to", "between", "and", "or"]
    private static let scheduleWords: Set<String> = [
        "meet", "meeting", "call", "available", "free", "schedule", "scheduled", "appointment", "open",
        "opens", "close", "closes", "arrive", "arrives", "depart", "departs", "leaves", "time", "anytime"]
    private static let appointmentWords = scheduleWords.union(["alarm", "wake"])
    private static let clockSuffixes: Set<String> = ["am", "pm", "a.m", "p.m", "o'clock", "ish", "sharp"]
    private static let timeAdverbs: Set<String> = ["tonight", "tomorrow", "today"]
    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private static let clockConnectors: Set<String> = ["or", "and", "to"]
    private static let clockFollowers: Set<String> = [
        "if", "so", "but", "then", "please", "maybe", "instead", "too", "though", "would"]
    private static let nonClockLeads: Set<String> = [
        "id", "code", "area", "flight", "address", "street", "zip", "bus", "fly", "score", "cost", "costs", "price",
        "weighs", "paid", "pay", "sold", "sells", "got", "gets", "section", "sections", "chapters", "pages",
        "rooms", "yards", "mile", "miles", "extension", "build", "firmware"]

    /// Verbs whose number is an amount: "bought it at 250", "peaked at 105", "increase it by 250".
    /// Not "up", "off" or "dropped" on their own: "I got up at 730", "dropped off at 215".
    private static let amountVerbs: Set<String> = [
        "bought", "buy", "buying", "weigh", "weighs", "weighed", "priced", "valued", "worth", "peaked", "peaks",
        "increase", "increased", "increases", "decrease", "decreased", "decreases", "reduce", "reduced", "raise",
        "raised", "grew", "grows", "multiply", "multiplied", "divide", "divided", "temperature", "averaged",
        "averages", "totals", "totaled", "capped"]
    private static let amountSteps: Set<String> = ["up", "down", "off", "over", "under"]

    /// The preposition before a packed number is about an amount: an amount verb up to three
    /// words before it, or "up by", "off by", "down by".
    private static func amountLead(before index: Int, in tokens: [Token]) -> Bool {
        guard index >= 2, tokens[index - 1].trail.isEmpty else { return false }
        if tokens[index - 1].lower == "by", tokens[index - 2].trail.isEmpty, amountSteps.contains(tokens[index - 2].lower) {
            return true
        }
        for token in tokens[max(0, index - 4)..<(index - 1)].reversed() {
            if !token.trail.isEmpty { break }
            if amountVerbs.contains(token.lower) { return true }
        }
        return false
    }

    /// Look back inside the current phrase. A comma or sentence end stops the cue.
    private static func nearby(_ words: Set<String>, before index: Int, in tokens: [Token], limit: Int) -> Bool {
        for token in tokens[max(0, index - limit)..<index].reversed() {
            if !token.trail.isEmpty { break }
            if words.contains(token.lower) { return true }
        }
        return false
    }

    private static func hour(_ token: Token) -> Int? {
        let value = token.isDigits ? Int(token.core) : units[token.lower] ?? teens[token.lower]
        return value.flatMap { (1...12).contains($0) ? $0 : nil }
    }

    private static func existingClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), (1...12).contains(hour),
              parts[1].count == 2, let minute = Int(parts[1]) else { return false }
        return (0...59).contains(minute)
    }

    /// A cue immediately before the number, optionally separated by "like" or "maybe".
    private static func hasClockLead(before index: Int, in tokens: [Token]) -> Bool {
        guard index > 0, tokens[index - 1].trail.isEmpty else { return false }
        if comparesTimes(before: index, in: tokens) { return true }
        let previous = tokens[index - 1].lower
        if clockPrepositions.contains(previous) { return true }
        return index >= 2 && clockAlternatives.contains(previous) && tokens[index - 2].trail.isEmpty
            && clockPrepositions.contains(tokens[index - 2].lower)
    }

    private static func hasSchedulingLead(before index: Int, in tokens: [Token]) -> Bool {
        guard index > 0, tokens[index - 1].trail.isEmpty, clockAlternatives.contains(tokens[index - 1].lower) else {
            return false
        }
        for token in tokens[max(0, index - 6)..<index].reversed() {
            if !token.trail.isEmpty { break }
            if scheduleWords.contains(token.lower) || existingClock(token.core) { return true }
        }
        return false
    }

    /// A following count, unit, ordinal or address blocks a reading licensed by "at" alone.
    private static func clockTail(after end: Int, in tokens: [Token], allowRange: Bool = true) -> Bool {
        guard end < tokens.count, tokens[end - 1].trail.isEmpty else { return true }
        let next = tokens[end]
        if next.core.isEmpty { return true }
        guard next.lead.isEmpty else { return false }
        if clockSuffixes.contains(next.lower) || timeAdverbs.contains(next.lower)
            || weekdays.contains(next.lower) || clockFollowers.contains(next.lower) {
            return true
        }
        if next.lower == "on", end + 1 < tokens.count, next.trail.isEmpty {
            return weekdays.contains(tokens[end + 1].lower)
        }
        if ["work", "works"].contains(next.lower) {
            // A proposed time "works?" or "works for me"; "330 work orders" is a count.
            return end + 1 == tokens.count || !next.trail.isEmpty
                || ["for", "with", "best", "better", "too"].contains(tokens[end + 1].lower)
        }
        if allowRange, clockConnectors.contains(next.lower), end + 1 < tokens.count, next.trail.isEmpty {
            let other = tokens[end + 1]
            if let (_, _, rangeEnd) = clockDigits(at: end + 1, in: tokens) {
                return clockTail(after: rangeEnd, in: tokens, allowRange: false)
            }
            return (hour(other) != nil || existingClock(other.core) || ["noon", "midnight"].contains(other.lower))
                && clockTail(after: end + 2, in: tokens, allowRange: false)
        }
        return false
    }

    /// The recognizer returns packed digits, dotted decimals, spaced digits, words or a mixture.
    /// Split a candidate into hour and minute before deciding whether its surroundings make it a time.
    private static func clockDigits(at index: Int, in tokens: [Token], explicitClock: Bool = false) -> (Int, Int, Int)? {
        let token = tokens[index].clockBase
        let dotted = token.core.contains(".") ? token.core.split(separator: ".", omittingEmptySubsequences: false) : []
        if dotted.count == 2, (1...2).contains(dotted[0].count), dotted[1].count == 2,
           let hour = Int(dotted[0]), (1...12).contains(hour),
           let minute = Int(dotted[1]), (0...59).contains(minute) { return (hour, minute, index + 1) }
        // Round hundreds, 911, and a leading zero need a stronger cue than "at".
        if token.isDigits, (3...4).contains(token.core.count),
           let hour = Int(token.core.dropLast(2)), let minute = Int(token.core.suffix(2)), minute < 60 {
            let ordinary = (1...12).contains(hour) && minute > 0 && !token.core.hasPrefix("0") && token.core != "911"
            if ordinary || (explicitClock && (0...23).contains(hour)) { return (hour, minute, index + 1) }
        }
        guard let hour = hour(token), index + 1 < tokens.count, token.trail.isEmpty else { return nil }
        let next = tokens[index + 1].clockBase
        guard next.lead.isEmpty else { return nil }
        if next.isDigits, next.core.count == 2, let minute = Int(next.core), minute < 60 {
            return (hour, minute, index + 2)
        }
        if tokens[index + 1].lower.hasSuffix("-ish"), let minute = teens[next.lower] ?? tens[next.lower], minute < 60 {
            return (hour, minute, index + 2)
        }
        if let minute = twoDigits(in: tokens, from: index + 1), minute.value < 60 {
            return (hour, minute.value, minute.end)
        }
        return nil
    }

    private static func clockTime(at index: Int, in tokens: [Token], gaps: [String]) -> Written? {
        let token = tokens[index]
        let relativeLead = token.lower == "half" || token.lower == "quarter"
            || (token.lower == "a" && index + 1 < tokens.count && tokens[index + 1].lower == "quarter")
        guard relativeLead || token.isNumberish || token.core.first?.isNumber == true || token.lower.hasSuffix("-ish") else {
            return nil
        }
        let previous = index > 0 && tokens[index - 1].trail.isEmpty && !gaps[index].contains(where: \.isNewline)
            ? tokens[index - 1] : nil
        if let previous, previous.isNumberish || labels.contains(previous.lower) || nonClockLeads.contains(previous.lower) {
            return nil
        }
        if index >= 2, let previous, clockPrepositions.contains(previous.lower) || clockAlternatives.contains(previous.lower),
           tokens[index - 2].trail.isEmpty, nonClockLeads.contains(tokens[index - 2].lower) { return nil }
        let withPreposition = previous.map { clockPrepositions.contains($0.lower) || $0.lower == "for" } == true
        let schedule = withPreposition && nearby(appointmentWords, before: index, in: tokens, limit: 5)
        if relativeLead || (schedule && token.lower == "five"),
           let relative = relativeClock(at: index, in: tokens, schedule: schedule),
           !(index + 1..<relative.end).contains(where: { gaps[$0].contains(where: \.isNewline) }) { return relative }

        // "five-ish" and "one o'clock": keep the qualifier and recognize the bare hour.
        if token.lower.hasSuffix("-ish"), let value = hour(Token(String(token.core.dropLast(4)))),
           clockTail(after: index + 1, in: tokens),
           hasClockLead(before: index, in: tokens) || hasSchedulingLead(before: index, in: tokens) {
            return Written(text: String(value) + "-ish", end: index + 1)
        }
        if let value = hour(token), token.numbers != nil, token.trail.isEmpty, index + 1 < tokens.count,
           tokens[index + 1].lead.isEmpty, !gaps[index + 1].contains(where: \.isNewline),
           clockSuffixes.contains(tokens[index + 1].lower), tokens[index + 1].lower != "ish" {
            return Written(text: String(value), end: index + 1)
        }

        let hasMeridiem = index + 1 < tokens.count && token.trail.isEmpty
            && ["am", "pm", "a.m", "p.m"].contains(tokens[index + 1].lower)
        let displayed = token.isDigits && previous.map { ["says", "reads", "shows"].contains($0.lower) } == true
            && nearby(["time", "clock"], before: index, in: tokens, limit: 10)
        guard let (hour, minute, end) = clockDigits(at: index, in: tokens, explicitClock: schedule || hasMeridiem || displayed),
              !hasMeridiem || (1...12).contains(hour),
              !(index + 1..<end).contains(where: { gaps[$0].contains(where: \.isNewline) }) else { return nil }
        let suffix = end < tokens.count && tokens[end - 1].trail.isEmpty ? tokens[end].lower : ""
        // A time said as words with a cue beside it is a time whatever follows: "I woke up at
        // six fifteen this morning", "nine thirty if that works". Only a unit says otherwise
        // ("ten fifteen minute breaks"). Digits the recognizer packed ("215") are judged by
        // what follows them, below.
        let saidAsWords = end > index + 1 && token.numbers != nil
        let followedByUnit = end < tokens.count && tokens[end - 1].trail.isEmpty && isMeasure(tokens[end])
            && !afterTime.contains(suffix)
        let wordsCue = saidAsWords && !followedByUnit
            && (index == 0 || tokens[index - 1].endsSentence || previous.map { beforeTime.contains($0.lower) } == true
                || afterTime.contains(suffix) || comparesTimes(before: index, in: tokens))
        // A date can be spoken as two numbers. An event named after 9/11 is not a time.
        if saidAsWords, token.lower == "nine", tokens[index + 1].lower == "eleven" {
            let eventWords = ["attacks", "attack", "memorial", "tragedy"]
            if eventWords.contains(suffix) || (suffix == "was" && tokens[end..<min(end + 3, tokens.count)]
                .contains(where: { eventWords.contains($0.lower) })) { return nil }
        }
        let scheduleClause = schedule && ["when", "outside", "inside", "because", "while"].contains(suffix)
        guard wordsCue || scheduleClause || (displayed && !followedByUnit) || clockTail(after: end, in: tokens) else { return nil }
        // "Increase it by 250" and "I weigh around 150" are amounts, whatever the preposition.
        let quantity = withPreposition && index >= 2 && (["seats", "headcount", "score", "price"].contains(tokens[index - 2].lower)
            || (["settled", "stood", "closed"].contains(tokens[index - 2].lower)
                && nearby(["price", "score", "headcount", "bid"], before: index - 2, in: tokens, limit: 3)))
        if end == index + 1, !hasMeridiem, amountLead(before: index, in: tokens) || quantity {
            return nil
        }
        let approximate = tokens[end - 1].lower.hasSuffix("-ish")
        let explicit = approximate || clockSuffixes.contains(suffix) || timeAdverbs.contains(suffix) || ["work", "works"].contains(suffix)
        let hasRangeSuffix: Bool
        if let previous, ["from", "between"].contains(previous.lower),
           clockConnectors.contains(suffix), end + 1 < tokens.count,
           let (_, _, otherEnd) = clockDigits(at: end + 1, in: tokens), otherEnd < tokens.count,
           tokens[otherEnd - 1].trail.isEmpty {
            hasRangeSuffix = clockSuffixes.contains(tokens[otherEnd].lower) || timeAdverbs.contains(tokens[otherEnd].lower)
        } else {
            hasRangeSuffix = false
        }
        // "at one am" is explicit, "330" alone could be a house number, and "Nine thirty"
        // by itself is the familiar spoken time. Keep that last convention for spoken pairs.
        let spoken = end > index + 1 && token.numbers != nil
        let opensClause = index == 0 || tokens[index - 1].endsSentence
        let spokenCue = spoken && (opensClause || previous.map { beforeTime.contains($0.lower) } == true)
        let splitAlternative = end > index + 1 && previous.map { clockAlternatives.contains($0.lower) } == true
        guard explicit || displayed || schedule || hasRangeSuffix || hasClockLead(before: index, in: tokens) || hasSchedulingLead(before: index, in: tokens)
            || spokenCue || wordsCue || splitAlternative || previous.map({ timeAdverbs.contains($0.lower) }) == true else { return nil }
        return Written(text: "\(hour):" + String(format: "%02d", minute) + (approximate ? "-ish" : ""), end: end)
    }

    private static func relativeClock(at index: Int, in tokens: [Token], schedule: Bool) -> Written? {
        if tokens[index].lower == "half", tokens[index].trail.isEmpty, index + 1 < tokens.count,
           tokens[index + 1].lead.isEmpty, let hour = hour(tokens[index + 1]),
           (schedule || (index == 0 && tokens.count == 2)), clockTail(after: index + 2, in: tokens) {
            return Written(text: "\(hour):30", end: index + 2)
        }
        let hasArticle = tokens[index].lower == "a" && tokens[index].trail.isEmpty
        let start = index + (hasArticle ? 1 : 0)
        guard start + 2 < tokens.count, (start...start + 1).allSatisfy({ tokens[$0].trail.isEmpty }),
              tokens[start + 1].lead.isEmpty, tokens[start + 2].lead.isEmpty,
              let hour = hour(tokens[start + 2]), clockTail(after: start + 3, in: tokens) else { return nil }
        switch (tokens[start].lower, tokens[start + 1].lower) {
        case ("half", "past") where !hasArticle: return Written(text: "\(hour):30", end: start + 3)
        case ("quarter", "past"): return Written(text: "\(hour):15", end: start + 3)
        case ("quarter", "to"), ("five", "to"):
            let end = start + 3
            let minute = tokens[start].lower == "five" ? 55 : 45
            let text = "\(hour == 1 ? 12 : hour - 1):\(minute)"
            // "Quarter to 12 PM" is 11:45 AM. Keep the recognizer's suffix style.
            if hour == 12, end < tokens.count, tokens[end - 1].trail.isEmpty {
                let marker = tokens[end]
                if ["am", "pm", "a.m", "p.m"].contains(marker.lower) {
                    let first = marker.lower.hasPrefix("a")
                        ? (marker.core.first?.isUppercase == true ? "P" : "p")
                        : (marker.core.first?.isUppercase == true ? "A" : "a")
                    return Written(text: text + " " + first + marker.core.dropFirst(), end: end + 1)
                }
            }
            return Written(text: text, end: end)
        default: return nil
        }
    }

    /// "a three-hour drive": a number word hyphenated to its unit.
    private static func hyphenatedMeasure(_ token: Token, at index: Int, explicit: Bool) -> Written? {
        guard let dash = token.lower.firstIndex(of: "-") else { return nil }
        let head = String(token.lower[..<dash])
        let rest = String(token.lower[token.lower.index(after: dash)...])
        guard let value = units[head] ?? teens[head] ?? tens[head], value >= (explicit ? 0 : 2),
              measures.contains(rest) || (explicit && (extraMeasures.contains(rest) || ["year-old", "month-old", "day-old"].contains(rest))),
              !token.startsUppercase || index == 0 else { return nil }
        return Written(text: String(value) + "-" + token.core[token.core.index(token.core.startIndex, offsetBy: head.count + 1)...], end: index + 1)
    }
}
