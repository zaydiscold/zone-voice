// by zayd/cold @ zayd.wtf

import Foundation

/// A word spelled out loud, written as the word.
///
/// The recognizer writes a spelled name as separate letters, with hyphens ("D-A-A-N"), spaces
/// ("D A A N") or periods ("D. A.N."). A person spelling a word wants the word. Three or more
/// single letters in a row are joined. "Double" before a letter writes it twice ("D double A N"
/// is Daan), which is how people spell a repeated letter and survives a recognizer that hears two
/// identical letters as one.
///
/// The word is written the way a name is: "Daan", not "DAAN" (Zayd, November 15). A spelling
/// the person or the word lists know keeps its own casing: My Words ("DeShawn"), an acronym
/// ("API", "USA"), a brand ("iPhone"), or letters with no vowel to say them by ("NBC"). Caps lock still writes it in capitals, and very casual
/// in lowercase, as they do every word.
///
/// Left alone: two letters ("A B test", "X-Y"), a run that is not all capitals when spaced
/// (so "a b c" in a sentence is never read as letters), letters with commas between them, initials
/// before a name ("J. R. R. Tolkien"), and a trailing "I" or "A" that starts the next clause
/// ("X Y Z I think").
enum SpelledLetters {
    /// Hyphenated letters: unambiguous, any case.
    private static let hyphenated = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])\p{L}(?:-\p{L}){2,}(?=(?:['’]s)?(?![\p{L}\p{N}_'’\-]))"#)

    /// Spaced capitals, each a letter or "double" and a letter.
    private static let spaced = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])(?:[Dd]ouble[ \t]+)?[A-Z](?:[ \t]+(?:[Dd]ouble[ \t]+)?[A-Z]){2,}(?![\p{L}\p{N}_'’\-])"#)

    /// Letters each followed by a period, spoken with pauses: "D. A.N.", "D. A. N.". The last
    /// letter's period is part of the spelling. A letter without a period ends the run, so
    /// "D. A.N. D A A N" is two spellings, not one. A run with no space at all ("U.S.A.",
    /// "R.S.V.P.") is how the abbreviation is written and stays.
    private static let dotted = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])[A-Z]\.(?:[ \t]?[A-Z]\.){2,}(?![\p{L}\p{N}_'’\-@/])"#)

    /// The spelled letters as a word: the person's or a list's own spelling when there is one,
    /// otherwise a name's casing ("Daan").
    static func word(_ letters: String, personalWords: [String] = []) -> String {
        let lower = letters.lowercased()
        if let own = personalWords.first(where: { $0.lowercased() == lower }) { return own }
        if let name = ModernVocabulary.names[lower] { return name }
        // An acronym or mixed-case spelling the dictionary lists ("API", "USA", "iOS").
        if let display = WordList.shared?.lookup(lower)?.display, display.dropFirst().contains(where: \.isUppercase) {
            return display
        }
        // No vowel to say it by ("XYZ", "NBC", "HTML"): letters read out one by one, an acronym.
        if !lower.contains(where: { "aeiou".contains($0) }) { return lower.uppercased() }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    static func joining(_ text: String, personalWords: [String] = []) -> String {
        guard text.utf8.count >= 5 else { return text }
        var out = text
        for match in hyphenated.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let letters = out[range].filter { $0 != "-" }
            // Spelling is said in capitals; a lowercase run keeps its case ("e-m-a-i-l").
            out.replaceSubrange(range, with: letters.contains(where: \.isUppercase)
                ? word(String(letters), personalWords: personalWords) : String(letters))
        }
        return joiningSpaced(out, personalWords: personalWords)
    }

    /// "D. A.N." and "D.A.N.". Run on the transcript before abbreviations are protected, which
    /// would otherwise keep "A.N." as one.
    static func joiningDotted(_ text: String, personalWords: [String] = []) -> String {
        guard text.utf8.count >= 5, text.contains(".") else { return text }
        var out = text
        for match in dotted.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out), out[range].contains(where: { $0 == " " || $0 == "\t" }) else { continue }
            // "J. R. R. Tolkien": initials before a capitalized name are the name's.
            let rest = out[range.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
            if rest.startIndex > range.upperBound, let next = rest.first, next.isUppercase,
               rest.dropFirst().first?.isLowercase == true { continue }
            let letters = out[range].filter(\.isLetter)
            guard letters.count >= 3 else { continue }
            out.replaceSubrange(range, with: word(String(letters), personalWords: personalWords))
        }
        return out
    }

    /// A capital abbreviation written with periods: "U.S.A.", "U.S.", "R.S.V.P.", "D.C.".
    private static let abbreviation = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’\-@#./])[A-Z]\.(?:[A-Z]\.)+(?![\p{L}\p{N}_\-@/])"#)

    /// "U.S.A." is "USA" and "R.S.V.P." "RSVP". The last period stays when it also ends a sentence:
    /// at the end of the text, before a new line, or before a sentence's opening word ("in the
    /// U.S. It was" is "in the US. It was"; "the U.S. Army" is "the US Army").
    static func droppingAbbreviationPeriods(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var out = text
        for match in abbreviation.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let letters = String(out[range].filter(\.isLetter))
            let rest = out[range.upperBound...]
            var endsSentence = rest.isEmpty || rest.first?.isNewline == true
            if !endsSentence, rest.first == " " || rest.first == "\t" {
                let next = rest.drop(while: { $0 == " " || $0 == "\t" })
                let word = next.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
                endsSentence = next.first?.isNewline == true || word.first?.isUppercase == true && TextStyle.opensSentence(String(word))
            }
            out.replaceSubrange(range, with: endsSentence ? letters + "." : letters)
        }
        return out
    }

    private static func joiningSpaced(_ text: String, personalWords: [String]) -> String {
        var out = text
        for match in spaced.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard var range = Range(match.range, in: out) else { continue }
            var tokens = out[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // "X Y Z I think": the last "I" or "A" opens the next clause when a lowercase word follows.
            if let last = tokens.last, last == "I" || last == "A", tokens.dropLast().last?.lowercased() != "double",
               let next = out[range.upperBound...].dropFirst().first, out[range.upperBound] == " ", next.isLowercase {
                tokens.removeLast()
                guard let cut = out[range].lastIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
                range = range.lowerBound..<cut
            }
            var letters = ""
            var doubles = false, pieces = 0
            for token in tokens {
                if token.lowercased() == "double" { doubles = true; continue }
                letters += doubles ? token + token : token
                doubles = false
                pieces += 1
            }
            // "A double A" alone is a battery, not a spelling.
            guard pieces >= 3, !doubles else { continue }
            out.replaceSubrange(range, with: word(letters, personalWords: personalWords))
        }
        return out
    }
}
