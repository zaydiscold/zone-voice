// by zayd/cold @ zayd.wtf

import Foundation

enum KeyboardLayer: Equatable {
    case letters
    case numbers
    case symbols
}

enum Key: Hashable {
    case character(String)
    case shift
    case delete
    case space
    case newline
    /// Pastes the clipboard at the cursor. Between space and return when Settings turns it on.
    case paste
    /// Opens the emoji panel in the keys' place. Left of space, where Apple's keyboard keeps it,
    /// when Settings turns it on.
    case emoji
    case switchLayer(KeyboardLayer, label: String)
    case globe
    case mic

    /// Width relative to a letter key (33.5 pt on a 402 pt phone). iOS 26, measured 2026-10-31:
    /// 123 and globe 43.3 pt, return 93 pt, shift and delete 45.5 pt.
    var widthUnits: CGFloat {
        switch self {
        case .character: return 1
        case .shift, .delete: return 1.355
        case .switchLayer, .globe, .mic, .paste, .emoji: return 1.29
        case .newline: return 2.78
        case .space: return 0 // space takes the remaining width
        }
    }
}

/// QWERTY rows for the three layers. Letters respect the shift state; the other two layers
/// are the standard iOS English pairs.
enum KeyboardLayout {
    /// Return's width beside Paste: two thirds of its usual 2.78 units.
    static let narrowReturnUnits: CGFloat = 1.85
    /// 123 or ABC when it is the only key left of space: Return's usual width.
    static let loneSwitchUnits: CGFloat = 2.78

    /// True for a bottom row whose only key left of space is the layer switch, and whose right
    /// side has no field keys (".", "/", "@") taking room from space.
    static func hasLoneLayerSwitch(_ row: [Key]) -> Bool {
        guard let space = row.firstIndex(of: .space), space == 1, case .switchLayer = row[0] else { return false }
        return !row.contains { if case .character = $0 { true } else { false } }
    }

    static func rows(for layer: KeyboardLayer, shifted: Bool, needsGlobe: Bool, pasteKey: Bool = false,
                     emojiKey: Bool = false, fieldKeys: [String] = []) -> [[Key]] {
        var rows: [[Key]]
        switch layer {
        case .letters:
            let caseTransform: (String) -> String = shifted ? { $0.uppercased() } : { $0 }
            rows = [
                "qwertyuiop".map { .character(caseTransform(String($0))) },
                "asdfghjkl".map { .character(caseTransform(String($0))) },
                [.shift] + "zxcvbnm".map { .character(caseTransform(String($0))) } + [.delete],
                [.switchLayer(.numbers, label: "123")],
            ]
        case .numbers:
            rows = [
                "1234567890".map { .character(String($0)) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { .character($0) },
                [.switchLayer(.symbols, label: "#+=")] + [".", ",", "?", "!", "'"].map { .character($0) } + [.delete],
                [.switchLayer(.letters, label: "ABC")],
            ]
        case .symbols:
            rows = [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { .character($0) },
                ["_", "\\", "|", "~", "<", ">", "\u{20AC}", "\u{00A3}", "\u{00A5}", "\u{2022}"].map { .character($0) },
                [.switchLayer(.numbers, label: "123")] + [".", ",", "?", "!", "'"].map { .character($0) } + [.delete],
                [.switchLayer(.letters, label: "ABC")],
            ]
        }
        if needsGlobe {
            rows[3].append(.globe)
        }
        // The field's own keys go on the letters layer only; the other layers already have them.
        let fieldKeys = layer == .letters ? fieldKeys : []
        // Two of them and Paste leave space under two keys wide, so emoji gives way.
        if emojiKey, !(pasteKey && fieldKeys.count > 1) { rows[3].append(.emoji) }
        rows[3].append(.space)
        rows[3] += fieldKeys.map { .character($0) }
        if pasteKey { rows[3].append(.paste) }
        rows[3].append(.newline)
        return rows
    }
}
