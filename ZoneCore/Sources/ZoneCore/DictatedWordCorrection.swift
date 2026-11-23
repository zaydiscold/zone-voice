// by zayd/cold @ zayd.wtf

import Foundation

/// Learns from the commonest fix after a dictation: backspacing over the last word Zone wrote and
/// typing it the right way ("Deploy it on Versailles" backspaced to "Deploy it on Vercel"). Wispr
/// Flow learns its dictionary from edits like this. Selecting a word and retyping it is
/// `SelectedWordCorrection`; this covers the cursor never leaving the end of the dictation.
///
/// Only the dictation's own text counts: the context before the cursor when the word is finished
/// must be the context after the dictation with its last word (and anything after that word)
/// replaced by one typed word. Continuing the sentence, editing earlier words, or typing on to
/// the same word ("Versaillesx") learns nothing.
public struct DictatedWordCorrection: Sendable {
    public struct Learned: Equatable, Sendable {
        /// What dictation wrote.
        public let heard: String
        /// What the person typed in its place.
        public let written: String
        public init(heard: String, written: String) {
            self.heard = heard
            self.written = written
        }
    }

    private struct Pending: Sendable {
        /// The context before the cursor right after the dictation, at most 256 characters.
        var context: String
        /// Where the dictated text starts in `context`.
        var dictationStart: String.Index
        var session: String?
        var deleted = false
    }

    private var pending: Pending?
    public init() {}
    public var isTracking: Bool { pending != nil }
    public mutating func cancel() { pending = nil }

    /// Called once the dictated `text` is in the field; `contextBefore` is read after inserting it.
    public mutating func begin(inserted text: String, contextBefore: String?, session: String?) {
        pending = nil
        guard let contextBefore, !text.isEmpty, contextBefore.hasSuffix(text) else { return }
        let context = String(contextBefore.suffix(256))
        guard context.count >= text.count else { return }
        pending = Pending(context: context, dictationStart: context.index(context.endIndex, offsetBy: -text.count), session: session)
    }

    /// A backspace in the same field. Learning needs at least one.
    public mutating func delete(session: String?) {
        guard var current = pending else { return }
        guard current.session == session else { cancel(); return }
        current.deleted = true
        pending = current
    }

    /// When the typed word is finished (a space, punctuation or an emoji follows), before the
    /// separator goes in. Returns the correction once, then stops tracking.
    public mutating func finish(contextBefore: String?, session: String?) -> Learned? {
        defer { cancel() }
        guard let current = pending, current.deleted, current.session == session, let now = contextBefore else { return nil }
        let dictated = String(current.context[current.dictationStart...])
        // What was typed since: everything in `now` after the text that preceded the dictation,
        // found by its last 32 characters (hosts hand over a window, not the whole field).
        let anchor = String(current.context[..<current.dictationStart].suffix(32))
        let typedAfter: String
        if anchor.isEmpty {
            typedAfter = now
        } else if let range = now.range(of: anchor, options: .backwards) {
            typedAfter = String(now[range.upperBound...])
        } else {
            return nil
        }
        // Words of the dictation that are still there, then the one replaced.
        var shared = 0
        let d = Array(dictated), t = Array(typedAfter)
        while shared < d.count, shared < t.count, d[shared] == t[shared] { shared += 1 }
        while shared > 0, Self.isWordCharacter(d[shared - 1]) { shared -= 1 }
        let oldTail = String(d[shared...]), newTail = String(t[shared...])
        guard let heard = Self.singleWord(leading: oldTail), Self.isWord(newTail) else { return nil }
        // Whatever followed the heard word in the dictation must be punctuation or spaces.
        let afterHeard = oldTail.dropFirst(heard.count)
        guard afterHeard.allSatisfy({ !Self.isWordCharacter($0) }) else { return nil }
        // Typing on from the word ("Versaillesx") extends it; it does not correct it.
        guard newTail != heard, !(newTail.count > heard.count && newTail.lowercased().hasPrefix(heard.lowercased())) else { return nil }
        return Learned(heard: heard, written: newTail)
    }

    /// The word at the start of `text`, when `text` is that word plus non-word characters.
    private static func singleWord(leading text: String) -> String? {
        let word = String(text.prefix(while: isWordCharacter))
        return isWord(word) ? word : nil
    }

    private static func isWord(_ word: String) -> Bool {
        (2...64).contains(word.count) && word.first?.isLetter == true && word.last?.isLetter == true && word.allSatisfy(isWordCharacter)
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
    }
}
