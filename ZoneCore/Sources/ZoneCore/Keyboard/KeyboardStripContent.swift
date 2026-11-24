// by zayd/cold @ zayd.wtf

/// Ownership of the typing strip. Dictation owns the whole strip; the other results
/// describe the suggestion area. Clipboard history opens from a separate control.
public enum KeyboardStripContent: Equatable, Sendable {
    case dictation
    case emojiPicker
    case unsureWord
    case typingSuggestions
    case nextWords
    case controls

    public static func resolve(dictationOwnsStrip: Bool, emojiPickerOpen: Bool, hasUnsureWords: Bool,
                               suggestions: [Suggestion]) -> Self {
        if dictationOwnsStrip { return .dictation }
        if emojiPickerOpen { return .emojiPicker }
        if hasUnsureWords { return .unsureWord }
        if suggestions.contains(where: { suggestion in
            if case .emoji(_, _, let spaced, _) = suggestion.kind { return !spaced }
            return suggestion.kind != .prediction
        }) { return .typingSuggestions }
        if !suggestions.isEmpty { return .nextWords }
        return .controls
    }
}
