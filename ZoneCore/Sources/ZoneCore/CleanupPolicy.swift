// by zayd/cold @ zayd.wtf

import Foundation

/// First-release cleanup permits punctuation/case changes and removal of um/uh only.
/// A model instruction is not a guarantee: reject changes to the remaining word sequence.
public enum CleanupPolicy {
    public static let maximumCharacters = 4000
    public static func isSafe(original: String, candidate: String) -> Bool {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return tokens(original) == tokens(candidate)
    }
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "$" && $0 != "%" && $0 != "-" && $0 != "." })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0 != "um" && $0 != "uh" }
    }
}
