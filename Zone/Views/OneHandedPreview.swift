// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Zone keyboard > One-handed: a small drawing of the keyboard as the switches set it, so
/// the width slider and the thumb picker show what they do before the keyboard is opened. The
/// keys' share of the width is the keyboard's own (`OneHandedLayout`), drawn to scale.
struct OneHandedPreview: View {
    let side: OneHandedSide
    let width: Double
    @Environment(\.colorScheme) private var scheme

    /// Each row's keys in letter-key units, as the keyboard lays them out (`Key.widthUnits`).
    private static let rows: [[CGFloat]] = [
        Array(repeating: 1, count: 10),
        Array(repeating: 1, count: 9),
        [1.355] + Array(repeating: 1, count: 7) + [1.355],
        [2.78, 0, 2.78],
    ]
    /// Keys a row leaves dim: shift, delete, 123 and return.
    private static func isDim(row: Int, index: Int, count: Int) -> Bool {
        (row == 2 && (index == 0 || index == count - 1)) || (row == 3 && index != 1)
    }

    var body: some View {
        let fraction = OneHandedLayout.clamped(width)
        Canvas { context, size in
            let keys = (size.width * fraction).rounded()
            let x0 = side == .left ? 0 : size.width - keys
            drawKeys(in: CGRect(x: x0, y: 0, width: keys, height: size.height), context: &context)
            let panel = CGRect(x: side == .left ? keys : 0, y: 0, width: size.width - keys, height: size.height)
            drawPanel(in: panel, context: &context)
        }
        .frame(height: 104)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.82)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue("Keys on the \(side.label.lowercased()), \(Int((fraction * 100).rounded())) percent of the width")
    }

    private var cap: Color { scheme == .dark ? Color(white: 0.42) : .white }

    private func drawKeys(in area: CGRect, context: inout GraphicsContext) {
        let inset: CGFloat = 4, spacing: CGFloat = 3, rowGap: CGFloat = 5
        let usable = area.width - 2 * inset
        let unit = (usable - spacing * 9) / 10
        let rowHeight = (area.height - 2 * inset - rowGap * 3) / 4
        for (r, row) in Self.rows.enumerated() {
            let fixed = row.reduce(0, +) * unit
            let gaps = spacing * CGFloat(row.count - 1)
            // The space bar (0 units) takes what the row leaves.
            let fill = max(usable - fixed - gaps, 0)
            let rowWidth = fixed + gaps + (row.contains(0) ? fill : 0)
            var x = area.minX + inset + (usable - rowWidth) / 2
            let y = area.minY + inset + CGFloat(r) * (rowHeight + rowGap)
            for (i, units) in row.enumerated() {
                let w = units == 0 ? fill : units * unit
                let rect = CGRect(x: x, y: y, width: w, height: rowHeight)
                let dim = Self.isDim(row: r, index: i, count: row.count)
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5, style: .continuous),
                             with: .color(dim ? cap.opacity(0.55) : cap))
                x += w + spacing
            }
        }
    }

    /// The side panel's two buttons: switch sides above, full width below.
    private func drawPanel(in area: CGRect, context: inout GraphicsContext) {
        guard area.width > 8 else { return }
        let flip = Text(Image(systemName: KeyboardHand(side.other).symbolName))
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        let expand = Text(Image(systemName: side == .left ? "chevron.compact.right" : "chevron.compact.left"))
            .font(.system(size: 18)).foregroundStyle(.secondary)
        context.draw(context.resolve(flip), at: CGPoint(x: area.midX, y: area.minY + area.height * 0.28))
        context.draw(context.resolve(expand), at: CGPoint(x: area.midX, y: area.minY + area.height * 0.72))
    }
}
