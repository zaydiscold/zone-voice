// by zayd/cold @ zayd.wtf

import Foundation

/// Names made of ordinary words: "micro center" typed is Micro Center, "taco bell" Taco Bell.
/// Neither word can take the capital alone ("a micro USB", "the visitor center"), so the name is
/// written only when its last word is finished right after the others. The names are the
/// multi-word entries of `ModernVocabulary`, which dictation already writes the same way.
///
/// A word typed in capitals or mixed case is the person's own casing, so a name containing one
/// is left as typed. Undoing the change with Delete puts the typed words back, as for any
/// autocorrection.
public enum PhraseCasing {
    /// The longest name, in words.
    static let maximumWords = 3

    /// Lowercase last words of the listed names, so a finished word that cannot end one costs
    /// nothing more than a set lookup.
    static let lastWords: Set<String> = Set(ModernVocabulary.phrases.keys.compactMap { $0.split(separator: " ").last.map(String.init) })

    /// The table key for a run of words: lowercase, apostrophes dropped, single spaces.
    static func key(_ words: [String]) -> String? {
        let folded = words.map { word in
            String(word.lowercased().filter { $0 != "'" && $0 != "’" })
        }
        guard folded.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else { return nil }
        return folded.joined(separator: " ")
    }

    /// Whether `word` could finish a listed name. Cheap; the keyboard asks on every separator.
    public static func mayEndName(_ word: String) -> Bool {
        guard let key = key([word]) else { return false }
        return lastWords.contains(key)
    }

    /// The listed name that `word` completes, given the text typed before it. `before` ends right
    /// where `word` starts (normally with the space after the previous word). Returns how many
    /// characters at the end of `before` the name also covers (the earlier words and the spaces
    /// between them) and the name as written; nil when the words spell no listed name, already
    /// spell it, or one of them carries casing of its own.
    public static func name(before: String, word: String) -> (prefixLength: Int, name: String)? {
        guard mayEndName(word), isPlainlyCased(word) else { return nil }
        // Walk back over up to two earlier words, each followed by exactly one space.
        var earlier: [(word: String, start: String.Index)] = []
        var cursor = before.endIndex
        while earlier.count < maximumWords - 1 {
            guard cursor > before.startIndex, before[before.index(before: cursor)] == " " else { break }
            let wordEnd = before.index(before: cursor)
            var wordStart = wordEnd
            while wordStart > before.startIndex, isWordCharacter(before[before.index(before: wordStart)]) {
                wordStart = before.index(before: wordStart)
            }
            guard wordStart < wordEnd else { break }
            earlier.insert((String(before[wordStart..<wordEnd]), wordStart), at: 0)
            cursor = wordStart
        }
        // Longest name first, so a three-word name wins over a two-word name inside it.
        for count in stride(from: earlier.count, through: 1, by: -1) {
            let lead = earlier.suffix(count)
            let words = lead.map(\.word) + [word]
            guard let key = key(words), let name = ModernVocabulary.phrases[key],
                  let start = lead.first?.start, startsAtBoundary(before, start),
                  lead.allSatisfy({ isPlainlyCased($0.word) }) else { continue }
            let typed = words.joined(separator: " ")
            guard typed != name else { return nil }
            return (before.distance(from: start, to: before.endIndex), name)
        }
        return nil
    }

    /// Lowercase, or a capital only on the first letter ("micro", "Micro"); not "MICRO" or "mIcro".
    static func isPlainlyCased(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard let first = letters.first else { return false }
        return letters.dropFirst().allSatisfy(\.isLowercase) && (first.isLowercase || first.isUppercase)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’"
    }

    /// The name's first word is a word of its own: not the end of "@micro", "x.micro" or "v2micro".
    private static func startsAtBoundary(_ text: String, _ start: String.Index) -> Bool {
        guard start > text.startIndex else { return true }
        let previous = text[text.index(before: start)]
        return !(previous.isLetter || previous.isNumber || "@#_-/.'’".contains(previous))
    }
}
