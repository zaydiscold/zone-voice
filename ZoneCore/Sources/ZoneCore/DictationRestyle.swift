// by zayd/cold @ zayd.wtf

import Foundation

/// A dictation the keyboard inserted, kept so that picking another style can write it again from
/// what was said instead of asking the person to say it again (Zayd, 2026-11-20: he dictated one
/// message four times to see it in four styles).
public struct InsertedDictation: Equatable, Sendable {
    /// What the speech engine heard, before any style.
    public var transcript: String
    /// What went into the field, with the space that joined it to the text before it.
    public var inserted: String
    public var style: TextStyle
    /// How Shift stood when it was inserted, so a rewrite opens the same way.
    public var opening: DictationOpening
    public var doubts: [DoubtfulWord]?

    public init(transcript: String, inserted: String, style: TextStyle, opening: DictationOpening,
                doubts: [DoubtfulWord]? = nil) {
        self.transcript = transcript
        self.inserted = inserted
        self.style = style
        self.opening = opening
        self.doubts = doubts
    }
}

/// Writing an inserted dictation again in another style, in place. Like Undo it is only safe
/// while the field still ends with exactly what was inserted (`UndoPlan`): once anything is typed
/// after it, or any of it is edited, there is no plan and the field is left alone.
public enum RestylePlan {
    /// Backspaces, then text to insert. Only the part that differs is retyped, so a host sees the
    /// smallest change (most rewrites share their opening words).
    public struct Edit: Equatable, Sendable {
        public let deletions: Int
        public let insertion: String
        /// The whole dictation as the field holds it afterwards.
        public let result: String
    }

    /// The edit that turns `current`, the text ending at the cursor, into `replacement`. Nil when
    /// the field no longer ends with `current`, or nothing would change.
    public static func edit(contextBefore: String?, from current: String, to replacement: String) -> Edit? {
        guard UndoPlan.deletionCount(contextBefore: contextBefore, lastInserted: current) != nil,
              !replacement.isEmpty, replacement != current else { return nil }
        var shared = 0
        var old = current.makeIterator(), new = replacement.makeIterator()
        while let a = old.next(), let b = new.next(), a == b { shared += 1 }
        return Edit(deletions: current.count - shared, insertion: String(replacement.dropFirst(shared)), result: replacement)
    }

    /// The edit that writes `last` again. `render` is given the text that stood before the
    /// dictation and returns it in the new style, joined the way an insertion would be.
    public static func edit(contextBefore: String?, last: InsertedDictation, render: (_ before: String) -> String) -> Edit? {
        guard let context = contextBefore,
              let count = UndoPlan.deletionCount(contextBefore: context, lastInserted: last.inserted) else { return nil }
        return edit(contextBefore: context, from: last.inserted, to: render(String(context.dropLast(count))))
    }
}
