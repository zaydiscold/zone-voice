// by zayd/cold @ zayd.wtf

import Foundation

/// Attributes learning to a deliberately selected single word replaced by this keyboard.
/// Keeps bounded anchors only while editing. Ordinary typing cannot create a candidate.
public struct SelectedWordCorrection: Sendable {
    private struct Candidate: Sendable {
        var original: String
        var replacement = ""
        var began = false
        var before: String
        var after: String
        var session: String
        var emptyContextMayBeNil: Bool
    }
    private var candidate: Candidate?
    public init() {}
    public var isTracking: Bool { candidate != nil }
    /// The selected word being replaced, while tracking.
    public var original: String? { candidate?.original }
    public mutating func cancel() { candidate = nil }

    /// UIKit can report nil at the edges of a nonempty selection. The caller may opt into
    /// that interpretation only after reading an actual selection in an eligible host field.
    public mutating func select(_ word: String, before: String?, after: String?, session: String?,
                                emptyContextMayBeNil: Bool = false) {
        candidate = nil
        let before = before ?? (emptyContextMayBeNil ? "" : nil)
        let after = after ?? (emptyContextMayBeNil ? "" : nil)
        guard Self.isWord(word), let before, let after, let session,
              before.last.map({ !Self.isWordCharacter($0) }) ?? true,
              after.first.map({ !Self.isWordCharacter($0) }) ?? true else { return }
        candidate = Candidate(original: word, before: String(before.suffix(64)),
                              after: String(after.prefix(64)), session: session,
                              emptyContextMayBeNil: emptyContextMayBeNil)
    }

    public mutating func insert(_ text: String, session: String?) {
        guard var current = candidate, current.session == session,
              !text.isEmpty, text.allSatisfy(Self.isWordCharacter),
              current.replacement.count + text.count <= 64 else { cancel(); return }
        current.began = true
        current.replacement += text
        candidate = current
    }

    public mutating func delete(session: String?) {
        guard var current = candidate, current.session == session else { cancel(); return }
        if !current.began { current.began = true }
        else if !current.replacement.isEmpty { current.replacement.removeLast() }
        else { cancel(); return }
        candidate = current
    }

    /// Fresh context must still describe exactly the edit before any separator is inserted.
    public mutating func finish(before: String?, after: String?, session: String?) -> String? {
        defer { cancel() }
        guard let current = candidate, current.began, current.session == session,
              Self.isWord(current.replacement), current.replacement != current.original,
              matches(current, before: before, after: after) else { return nil }
        return current.replacement
    }

    /// A host callback may merely acknowledge our edit; changed anchors/cursor abandon learning.
    public mutating func reconcile(before: String?, after: String?, session: String?) {
        guard let current = candidate else { return }
        guard current.began else { cancel(); return }
        if current.session != session || !matches(current, before: before, after: after) { cancel() }
    }

    private func matches(_ current: Candidate, before: String?, after: String?) -> Bool {
        // Missing before-context cannot validate a nonempty replacement. Only an empty
        // trailing anchor can accept UIKit's nil-at-end representation.
        guard let before else { return false }
        let after = after ?? (current.emptyContextMayBeNil && current.after.isEmpty ? "" : nil)
        guard let after else { return false }
        let expected = current.before + current.replacement
        let beforeMatches = current.before.isEmpty ? before == expected : before.hasSuffix(expected)
        let afterMatches = current.after.isEmpty ? after.isEmpty : after.hasPrefix(current.after)
        return beforeMatches && afterMatches
    }

    private static func isWord(_ word: String) -> Bool {
        (2...64).contains(word.count) && word.first?.isLetter == true && word.last?.isLetter == true && word.allSatisfy(isWordCharacter)
    }
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c == "'" || c == "’" || c == "-"
    }
}
