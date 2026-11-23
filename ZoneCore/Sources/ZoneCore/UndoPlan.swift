// by zayd/cold @ zayd.wtf

import Foundation

/// Undo of a dictation is only safe when nothing was typed after it. The plan is the number
/// of `deleteBackward()` calls that removes exactly the inserted text, or nil when the field
/// no longer ends with it.
public enum UndoPlan {
    public static func deletionCount(contextBefore: String?, lastInserted: String) -> Int? {
        guard !lastInserted.isEmpty, let context = contextBefore, context.hasSuffix(lastInserted) else {
            return nil
        }
        return lastInserted.count
    }
}
