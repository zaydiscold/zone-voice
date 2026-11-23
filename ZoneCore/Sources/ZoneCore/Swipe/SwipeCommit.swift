// by zayd/cold @ zayd.wtf

import Foundation

/// Exact ownership of a swipe insertion. Any cursor/field/selection change drops the right to
/// replace or delete it; equal-looking text in a different field is never enough.
public struct SwipeCommit: Equatable, Sendable {
    public let session: String
    public let before: String
    public let after: String
    public let leading: String
    public var word: String
    public let previousWord: String?

    public init(session: String, before: String, after: String, leading: String, word: String, previousWord: String?) {
        self.session = session; self.before = before; self.after = after
        self.leading = leading; self.word = word; self.previousWord = previousWord
    }

    public func owns(session: String?, before current: String?, after: String?, selection: String?) -> Bool {
        guard session == self.session, selection?.isEmpty != false, let current, let after else { return false }
        let expected = before + leading + word
        // Hosts truncate context. Compare a substantial suffix without accepting an empty context.
        return !current.isEmpty && current.hasSuffix(leading + word)
            && expected.hasSuffix(current) && after == self.after
    }
    public var deleteCount: Int { leading.count + word.count }
}
