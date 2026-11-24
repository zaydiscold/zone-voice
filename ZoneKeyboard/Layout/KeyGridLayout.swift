// by zayd/cold @ zayd.wtf

import CoreGraphics
import ZoneCore

/// Maps the model's key rows onto the pure geometry in ZoneCore (`KeyGridGeometry`).
enum KeyGridLayout {
    /// The keys the grid draws: every key but the mic, which lives in the strip.
    static func drawnRows(_ rows: [[Key]]) -> [[Key]] {
        rows.map { $0.filter { $0 != .mic } }
    }

    /// One `KeyGridRow` per row. The third row always has the extra room beside shift and
    /// delete; on the number and symbol layers its punctuation keys share the leftover width,
    /// as iOS draws them wider than letters.
    static func gridRows(_ rows: [[Key]], layer: KeyboardLayer) -> [KeyGridRow] {
        rows.enumerated().map { index, row in
            let stretchPunctuation = index == 2 && layer != .letters
            // Return gives up a third of its width to a key beside it: Paste, or the field's own keys.
            let narrowReturn = row.contains(.paste) || (row.contains(.space) && row.contains { if case .character = $0 { true } else { false } })
            // 123 with no globe, emoji or field key beside it is as wide as Return, the way iOS draws
            // it when its own emoji key is absent. Alone at letter-and-a-bit width it looked too small.
            let loneSwitch = KeyboardLayout.hasLoneLayerSwitch(row)
            let widths = row.map { key -> KeySlotWidth in
                switch key {
                case .space: return .fill
                case .character: return stretchPunctuation ? .fill : .units(1)
                case .newline where narrowReturn: return .units(KeyboardLayout.narrowReturnUnits)
                case .switchLayer where loneSwitch: return .units(KeyboardLayout.loneSwitchUnits)
                default: return .units(key.widthUnits)
                }
            }
            return KeyGridRow(widths, edgeGaps: index == 2)
        }
    }
}

extension KeyGridLayout {
    /// G, V and Space occur on both halves. Page keys remain at their usual outside edges.
    static func split(_ rows: [[Key]]) -> (rows: [[Key]], cuts: [Int]) {
        var cuts: [Int] = []
        let keys = rows.enumerated().map { index, row in
            let middle = index == 3 ? row.firstIndex(of: .space)! : row.count / 2
            let duplicate = index == 3 || !row.count.isMultiple(of: 2)
            let cut = middle + (duplicate ? 1 : 0)
            cuts.append(cut)
            return Array(row[..<cut]) + Array(row[middle...])
        }
        return (keys, cuts)
    }
}
