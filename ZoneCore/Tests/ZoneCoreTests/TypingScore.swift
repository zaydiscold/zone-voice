// by zayd/cold @ zayd.wtf

import Foundation

/// Word-level scoring for the fast-typing simulation, shared by `FastTypingSimulationTests` and
/// `scripts/apple-autocorrect/` (which compiles this file in), so Zone and Apple are scored by
/// the same code. Foundation only: no ZoneCore, no XCTest.
enum TypingScore {
    /// One simulated sentence as typed: the words meant, the error class of each, and the
    /// space-separated tokens the key grid produced (nearest key, before any correction).
    struct Sentence: Codable, Equatable {
        var intended: [String]
        var classes: [String]
        var tokens: [String]
    }

    /// The export read by the Apple baseline tool.
    struct Export: Codable {
        var profile: String
        var sentences: [Sentence]
    }

    /// For each intended word, true when the output has the same word aligned to it (a
    /// case-insensitive word-level Levenshtein alignment; a fused token corrected into two words
    /// matches both). Also returns the number of word edits (substitutions, insertions,
    /// deletions), the numerator of word error rate.
    static func align(intended: [String], output: [String]) -> (matched: [Bool], edits: Int) {
        let a = intended.map { $0.lowercased() }, b = output.map { $0.lowercased() }
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
        }
        var matched = [Bool](repeating: false, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1], d[i][j] == d[i - 1][j - 1] {
                matched[i - 1] = true
                i -= 1; j -= 1
            } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (matched, d[n][m])
    }

    /// For each intended word, the index of the output word aligned to it (a match or a
    /// substitution), or nil when the alignment dropped it.
    static func pairs(intended: [String], output: [String]) -> [Int?] {
        let a = intended.map { $0.lowercased() }, b = output.map { $0.lowercased() }
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
        }
        var result = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                result[i - 1] = j - 1
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    /// Character error rate numerator: Levenshtein distance between two strings.
    static func characterEdits(_ x: String, _ y: String) -> Int {
        let a = Array(x), b = Array(y)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Accumulated scores for one condition (raw typing, or one corrector).
    struct Tally {
        var words = 0
        var right = 0
        var edits = 0
        /// Words typed exactly right that the corrector then changed.
        var cleanWords = 0
        var cleanBroken = 0
        var byClass: [String: (right: Int, total: Int)] = [:]

        mutating func add(_ sentence: Sentence, output: [String]) {
            let (matched, edits) = TypingScore.align(intended: sentence.intended, output: output)
            words += sentence.intended.count
            self.edits += edits
            for (index, ok) in matched.enumerated() {
                let label = sentence.classes[index]
                byClass[label, default: (0, 0)].total += 1
                if ok {
                    right += 1
                    byClass[label, default: (0, 0)].right += 1
                }
                if label == ErrorClass.clean {
                    cleanWords += 1
                    if !ok { cleanBroken += 1 }
                }
            }
        }

        var accuracy: Double { words == 0 ? 0 : Double(right) / Double(words) }
        var wordErrorRate: Double { words == 0 ? 0 : Double(edits) / Double(words) }
        var falseCorrectionRate: Double { cleanWords == 0 ? 0 : Double(cleanBroken) / Double(cleanWords) }

        func classAccuracy(_ label: String) -> Double? {
            guard let score = byClass[label], score.total > 0 else { return nil }
            return Double(score.right) / Double(score.total)
        }
    }

    /// Error classes, one per intended word (`FastTypingSimulation` assigns them).
    enum ErrorClass {
        static let clean = "clean"
        static let key = "key"
        static let keys2 = "keys2"
        static let omission = "omission"
        static let insertion = "insertion"
        static let transposition = "transposition"
        static let apostrophe = "apostrophe"
        static let cognitive = "cognitive"
        static let fused = "fused"
        static let spaceShift = "space-shift"
        static let splitWord = "split-word"
        static let spaceLetter = "space-letter"
        static let multi = "multi"
        static let all = [clean, key, keys2, omission, insertion, transposition, apostrophe, cognitive,
                          fused, spaceShift, splitWord, spaceLetter, multi]
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%5.1f%%", 100 * $0) } ?? "   n/a"
    }

    /// A per-class table, one column per condition.
    static func table(_ columns: [(name: String, tally: Tally)]) -> String {
        var lines: [String] = []
        let header = "class".padding(toLength: 14, withPad: " ", startingAt: 0) + "  words  " +
            columns.map { $0.name.padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ")
        lines.append(header)
        for label in ErrorClass.all {
            let total = columns.first?.tally.byClass[label]?.total ?? 0
            guard total > 0 else { continue }
            let row = label.padding(toLength: 14, withPad: " ", startingAt: 0) + String(format: "  %5d  ", total) +
                columns.map { TypingScore.percent($0.tally.classAccuracy(label)).padding(toLength: 10, withPad: " ", startingAt: 0) }
                .joined(separator: " ")
            lines.append(row)
        }
        let all = "all".padding(toLength: 14, withPad: " ", startingAt: 0) + String(format: "  %5d  ", columns.first?.tally.words ?? 0) +
            columns.map { TypingScore.percent($0.tally.accuracy).padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ")
        lines.append(all)
        let wer = "WER".padding(toLength: 14, withPad: " ", startingAt: 0) + "         " +
            columns.map { TypingScore.percent($0.tally.wordErrorRate).padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ")
        lines.append(wer)
        let broken = "false corr.".padding(toLength: 14, withPad: " ", startingAt: 0) + "         " +
            columns.map { TypingScore.percent($0.tally.falseCorrectionRate).padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ")
        lines.append(broken)
        return lines.joined(separator: "\n")
    }
}
