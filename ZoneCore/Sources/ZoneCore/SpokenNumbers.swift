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
public enum SpokenNumbers {
    public static func writingDigits(_ text: String) -> String {
        // Nothing to do for the common dictation with no number in it.
        guard text.range(of: trigger, options: [.regularExpression, .caseInsensitive]) != nil else { return text }
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

        var output: [String?] = tokens.map { Optional($0.raw) }
        var index = 0
        while index < tokens.count {
            if let written = number(at: index, in: tokens) {
                output[index] = tokens[index].lead + written.text + tokens[written.end - 1].trail
                for consumed in (index + 1)..<max(written.end, index + 1) { output[consumed] = nil }
                if written.joinsPrevious { gaps[index] = "" }
                index = written.end
            } else {
                index += 1
            }
        }
        var out = ""
        for (position, piece) in output.enumerated() {
            guard let piece else { continue }
            out += gaps[position] + piece
        }
        return out + trailingGap
    }

    // MARK: Tokens

    private static let trigger = #"(?<![\p{L}\p{N}])(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|(?:thir|four|fif|six|seven|eigh|nine)teen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|point|\d{1,2}[ \t]+[0-5]\d)(?![\p{L}])"#

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
    private static let labels: Set<String> = [
        "number", "no", "version", "building", "room", "chapter", "page", "step", "level", "phase", "season",
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
        "at", "by", "until", "till", "til", "around", "before", "after", "from", "to", "like", "say", "maybe",
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

    private static func number(at index: Int, in tokens: [Token]) -> Written? {
        let token = tokens[index]
        if token.isDigits { return digitTime(at: index, in: tokens) }
        if token.lower == "point" { return barePoint(at: index, in: tokens) }
        if token.numbers == nil { return hyphenatedMeasure(token, at: index) }
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
        if single, let second = twoDigits(in: tokens, from: run.end),
           !(second.end < tokens.count && tokens[second.end - 1].trail.isEmpty && isMeasure(tokens[second.end])
             && !afterTime.contains(tokens[second.end].lower)) {
            if (18...20).contains(run.value) {
                return Written(text: String(run.value) + second.text, end: second.end)
            }
            // A clock time: "at nine thirty", "twelve fifteen pm", "nine oh five". "It cost one
            // fifty" is a price, so without a sign of a time the words stay as said.
            if (1...12).contains(run.value), second.value < 60 {
                let before = index > 0 ? tokens[index - 1] : nil
                let after = second.end < tokens.count && tokens[second.end - 1].trail.isEmpty ? tokens[second.end] : nil
                let timed = before == nil || before!.endsSentence || (before!.trail.isEmpty && beforeTime.contains(before!.lower))
                    || after.map { afterTime.contains($0.lower) } ?? false
                    || comparesTimes(before: index, in: tokens)
                guard timed else {
                    let words = tokens[index..<second.end].map(\.raw).joined(separator: " ")
                    return Written(text: String(words.dropFirst(token.lead.count).dropLast(tokens[second.end - 1].trail.count)), end: second.end)
                }
                return Written(text: String(run.value) + ":" + second.text, end: second.end)
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
            guard inRange || measured || labelled else { return nil }
        }
        if let next, next.lower == "percent" {
            return Written(text: text + "%" , end: run.end + 1, joinsPrevious: joins)
        }
        return Written(text: text, end: run.end, joinsPrevious: joins)
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
           tokens[start + 1].lead.isEmpty, let digit = tokens[start + 1].numbers, digit.count == 1,
           let value = units[digit[0]], value > 0 {
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

    /// The recognizer's own "12 30" for a time: an hour, then two digits of minutes.
    private static func digitTime(at index: Int, in tokens: [Token]) -> Written? {
        let hour = tokens[index]
        guard index + 1 < tokens.count, hour.trail.isEmpty, hour.lead.isEmpty, let value = Int(hour.core), (1...12).contains(value),
              hour.core.count <= 2, !hour.core.hasPrefix("0") else { return nil }
        let minutes = tokens[index + 1]
        guard minutes.lead.isEmpty, minutes.isDigits, minutes.core.count == 2, let minute = Int(minutes.core), minute < 60 else { return nil }
        if index > 0, tokens[index - 1].trail.isEmpty,
           tokens[index - 1].isNumberish || labels.contains(tokens[index - 1].lower) || rangeWordsBeforeCount.contains(tokens[index - 1].lower) { return nil }
        if minutes.trail.isEmpty, index + 2 < tokens.count {
            let after = tokens[index + 2]
            guard after.lead.isEmpty, afterTime.contains(after.lower) else { return nil }
        }
        return Written(text: hour.core + ":" + minutes.core, end: index + 2)
    }

    /// "between 5 30 people" is not a time; the hour there is one end of a range.
    private static let rangeWordsBeforeCount: Set<String> = ["between"]

    /// "a three-hour drive": a number word hyphenated to its unit.
    private static func hyphenatedMeasure(_ token: Token, at index: Int) -> Written? {
        guard let dash = token.lower.firstIndex(of: "-") else { return nil }
        let head = String(token.lower[..<dash])
        let rest = String(token.lower[token.lower.index(after: dash)...])
        guard let value = units[head] ?? teens[head] ?? tens[head], value >= 2, measures.contains(rest),
              !token.startsUppercase || index == 0 else { return nil }
        return Written(text: String(value) + "-" + token.core[token.core.index(token.core.startIndex, offsetBy: head.count + 1)...], end: index + 1)
    }
}
