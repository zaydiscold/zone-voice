// by zayd/cold @ zayd.wtf

import Foundation

/// Fixes a misheard personal word: "Zade" for Zayd, "Snakebite" for Snakebyte, "Dahlson" for
/// Dahlsson. Speech models spell unfamiliar names by sound, so a recognized word that sounds the
/// same as one of the person's words (same consonant skeleton, see `soundKey`) and is spelled
/// close to it is replaced by the stored spelling.
///
/// Guarded so ordinary English and other people's names are left alone:
/// - only single personal words of 4+ letters, never more than about a third of the letters off;
/// - a different first letter allows only one edit (Zaid, Zade become Zayd; Saad, Sayed stay);
/// - an everyday word (frequency rank under 5,000: said, cloud, made) is never replaced;
/// - a rarer dictionary word is replaced only when written as a name and one edit away, as
///   "Snakebite" is in "I use Snakebite", and never when it is also a common first name
///   ("Dawn" stays Dawn with Daan saved; "Zaid", not a dictionary word, still becomes Zayd).
public struct PersonalWordMatcher: Sendable {
    private struct Target: Sendable { let word: String; let key: String }
    private let targets: [Target]
    private let rank: @Sendable (String) -> Int?

    /// - Parameter rank: the word's frequency rank in the dictionary (0 = most common), nil if absent.
    public init(words: [String], rank: @escaping @Sendable (String) -> Int? = { _ in nil }) {
        self.rank = rank
        targets = words.compactMap { raw in
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= 4, word.allSatisfy({ $0.isLetter }) else { return nil }
            let key = Self.soundKey(word)
            guard key.count >= 2 else { return nil }
            return Target(word: word, key: key)
        }
    }

    public var isEmpty: Bool { targets.isEmpty }

    public func correct(_ text: String) -> String {
        guard !targets.isEmpty else { return text }
        var out = ""
        var sentenceStart = true
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            out += replacement(for: token, atSentenceStart: sentenceStart) ?? token
            sentenceStart = false
            token = ""
        }
        for character in text {
            if character.isLetter || character == "'" || character == "’" {
                token.append(character)
            } else {
                flush()
                out.append(character)
                if ".!?\n".contains(character) { sentenceStart = true }
            }
        }
        flush()
        return out
    }

    private func replacement(for token: String, atSentenceStart: Bool) -> String? {
        // A possessive is matched on its name: "Dahlson's" becomes "Dahlsson's".
        for suffix in ["'s", "’s", "'", "’"] where token.count > suffix.count && token.hasSuffix(suffix) {
            let stem = String(token.dropLast(suffix.count))
            guard stem.allSatisfy({ $0.isLetter }) else { return nil }
            return replacement(for: stem, atSentenceStart: atSentenceStart).map { $0 + suffix }
        }
        guard token.count >= 3, token.allSatisfy({ $0.isLetter }) else { return nil }
        let lower = token.lowercased()
        let key = Self.soundKey(token)
        let writtenAsName = token.first?.isUppercase == true && !atSentenceStart
        var best: (word: String, distance: Int)?
        for target in targets where target.key == key {
            let targetLower = target.word.lowercased()
            if targetLower == lower { return nil } // Already right; casing is handled elsewhere.
            guard abs(targetLower.count - lower.count) <= 2 else { continue }
            let distance = Self.editDistance(lower, targetLower)
            guard distance <= max(2, targetLower.count / 3) else { continue }
            if lower.first != targetLower.first, distance > 1 { continue }
            if best == nil || distance < best!.distance { best = (target.word, distance) }
        }
        guard let best else { return nil }
        if let rank = rank(lower) {
            guard rank >= 5_000, writtenAsName, best.distance <= 1 else { return nil }
            // A word that is also a common first name is that person: "Tell Dawn" with Daan saved.
            guard !SpokenMentions.firstNames.contains(lower) else { return nil }
        }
        return best.word
    }

    /// A small consonant skeleton in the spirit of Metaphone: common spellings of one sound are
    /// folded together and vowels after the first letter are dropped, so Zade, Zayd and Zaid
    /// share "SD" and Snakebite and Snakebyte share "FRSTBT".
    static func soundKey(_ word: String) -> String {
        var s = word.lowercased().filter { $0.isLetter }
        for (from, to) in [("ph", "f"), ("ck", "k"), ("gh", ""), ("qu", "kw"), ("x", "ks"), ("wr", "r"), ("kn", "n")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // A soft c sounds like s: Vercel is heard and written "Versel", Marcel "Marsel".
        for (from, to) in [("ce", "se"), ("ci", "si"), ("cy", "sy")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for (index, ch) in s.enumerated() {
            var c = ch
            switch c {
            case "z": c = "s"
            case "c": c = "k"
            case "q": c = "k"
            case "v": c = "f"
            case "j": c = "g"
            default: break
            }
            let vowel = "aeiouyhw".contains(c)
            if vowel { if index == 0 { out.append("a") }; continue }
            if out.last == c { continue }
            out.append(c)
        }
        return out.uppercased()
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
