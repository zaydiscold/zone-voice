// by zayd/cold @ zayd.wtf

import Foundation

/// Words every install knows, whatever the person has added. They are merged in where personal
/// words are used and never written to the person's dictionary, so they do not show up in
/// Settings and cannot be deleted there.
public enum BuiltInVocabulary {
    /// Names every install spells right: a friend dictating "Zayd" gets "Zayd", not the
    /// traditional "Zaid" the speech models write. They are hinted to the recognizer, kept in
    /// their casing, and fixed only from the listed `mishearings`, never by the sound-alike
    /// matcher: on a stranger's phone that would also turn Zahid, Zaida and Zod into Zayd.
    public static let names = ["Zayd", "Aalia"]

    /// Alternate spellings to normalize for each built-in name. This closed list leaves unrelated
    /// names alone. A person who adds one of these spellings to their own words (their friend
    /// really is Zaid or Alia) keeps it.
    public static let mishearings: [String: [String]] = [
        "Zayd": ["Zaid", "Zayed", "Zade", "Zayde", "Zaide", "Zeid", "Zeyd", "Zyed", "Zayid", "Zaed", "Zaydd"],
        "Aalia": ["Alia", "Aaliya", "Aliya", "Aaliyah", "Aliyah"],
    ]

    /// Texting spellings. They are hinted to the recognizer and protected from autocorrect, but
    /// never matched by sound: "imma" sounds like "Emma" and "yall" like "Ali". Casual styles
    /// rewrite the recognizer's spellings to these (`TextStyle`).
    public static let slang = ["imma", "yall"]

    /// The person's words plus the built-in names, for formatting and casing.
    public static func withNames(_ words: [String]) -> [String] {
        PersonalVocabulary.normalized(words + names)
    }

    /// The person's words plus every built-in word, for recognizer hints and autocorrect.
    public static func withAll(_ words: [String]) -> [String] {
        PersonalVocabulary.normalized(words + names + slang)
    }

    /// Replaces each listed mishearing with its built-in name, in any case and before a
    /// possessive ("Zaid's" becomes "Zayd's"). Spellings among `personalWords` are left alone.
    static func correctingMishearings(_ text: String, personalWords: [String]) -> String {
        let own = Set(personalWords.map { $0.lowercased() })
        var canonical: [String: String] = [:]
        for (name, heard) in mishearings {
            for spelling in heard where !own.contains(spelling.lowercased()) {
                canonical[spelling.lowercased()] = name
            }
        }
        guard !canonical.isEmpty else { return text }
        let alternation = canonical.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_'’\-])("# + alternation + #")(?=(?:['’]s?)?(?![\p{L}\p{N}_'’\-]))"#,
            options: [.caseInsensitive]) else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: out),
                  let name = canonical[out[range].lowercased()] else { continue }
            // "Inter alia" is ordinary prose, not a misheard name.
            if out[range].lowercased() == "alia",
               out[..<range.lowerBound].range(of: #"\binter\s+$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { continue }
            out.replaceSubrange(range, with: name)
        }
        return out
    }
}
