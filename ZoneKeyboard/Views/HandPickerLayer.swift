// by zayd/cold @ zayd.wtf

import UIKit
import ZoneCore

/// The callout a held 123 (or emoji) key opens once the one-handed keyboard is on in Settings:
/// keys on the left, full width, keys on the right. The finger slides across it and the layout
/// under the finger when it lifts is the one chosen, the way Apple's globe menu works. It opens on
/// the hand in use, so lifting without sliding changes nothing.
@MainActor
final class HandPickerLayer: CALayer {
    static let choices: [KeyboardHand] = [.left, .full, .right]
    static let itemSize = CGSize(width: 52, height: 46)
    static let padding: CGFloat = 5
    static var size: CGSize {
        CGSize(width: itemSize.width * CGFloat(choices.count) + padding * 2, height: itemSize.height + padding * 2)
    }

    private let highlight = CALayer()
    private var glyphs: [CALayer] = []
    private(set) var selection: KeyboardHand = .full
    private var isDark = false
    private var scale: CGFloat = 3

    override init() {
        super.init()
        actions = KeyBalloonLayer.noActions
        cornerRadius = 12
        cornerCurve = .continuous
        shadowColor = UIColor.black.cgColor
        shadowOpacity = 0.28
        shadowRadius = 6
        shadowOffset = CGSize(width: 0, height: 2)
        highlight.actions = KeyBalloonLayer.noActions
        highlight.cornerRadius = 9
        highlight.cornerCurve = .continuous
        addSublayer(highlight)
        for _ in Self.choices {
            let glyph = CALayer()
            glyph.actions = KeyBalloonLayer.noActions
            let mask = CALayer()
            mask.actions = KeyBalloonLayer.noActions
            glyph.mask = mask
            addSublayer(glyph)
            glyphs.append(glyph)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Where the callout goes for a key: just above it, centered on it, kept inside the grid.
    static func frame(over cap: CGRect, in bounds: CGRect) -> CGRect {
        let size = Self.size
        let x = min(max(cap.midX - size.width / 2, bounds.minX + 4), bounds.maxX - 4 - size.width)
        return CGRect(x: x, y: cap.minY - 6 - size.height, width: size.width, height: size.height)
    }

    func show(over cap: CGRect, in bounds: CGRect, current: KeyboardHand, fill: UIColor, isDark: Bool, scale: CGFloat) {
        frame = Self.frame(over: cap, in: bounds)
        backgroundColor = fill.cgColor
        self.isDark = isDark
        self.scale = scale
        isHidden = false
        selection = current
        redraw()
    }

    func hide() {
        isHidden = true
    }

    /// The choice under a point in the grid's coordinates. Only the horizontal position counts,
    /// so a thumb that drifts up or down while sliding still picks what it is over.
    func choice(atX x: CGFloat) -> KeyboardHand {
        let local = x - frame.minX - Self.padding
        let index = Int((local / Self.itemSize.width).rounded(.down))
        return Self.choices[min(max(index, 0), Self.choices.count - 1)]
    }

    /// Moves the selection; true when it changed (for the haptic).
    @discardableResult
    func select(_ hand: KeyboardHand) -> Bool {
        guard hand != selection else { return false }
        selection = hand
        redraw()
        return true
    }

    private func redraw() {
        let theme = KeyboardTheme(isDark: isDark)
        highlight.backgroundColor = UIColor(theme.controlFill).cgColor
        for (index, hand) in Self.choices.enumerated() {
            let item = CGRect(x: Self.padding + CGFloat(index) * Self.itemSize.width, y: Self.padding,
                              width: Self.itemSize.width, height: Self.itemSize.height)
            if hand == selection { highlight.frame = item.insetBy(dx: 2, dy: 2) }
            // Render the cached symbol as a mask so its ink follows the selected fill.
            let onAccent = hand == selection
            let glyph = KeyGlyphs.glyph(.symbol(hand.symbolName, size: 22), isDark: isDark, scale: scale)
            let layer = glyphs[index]
            layer.mask?.contents = glyph?.image
            layer.backgroundColor = UIColor(onAccent ? theme.controlInk : theme.text).cgColor
            layer.mask?.contentsScale = scale
            let size = glyph?.size ?? .zero
            layer.frame = CGRect(x: KeyGridView.pixelRound(item.midX - size.width / 2, scale),
                                 y: KeyGridView.pixelRound(item.midY - size.height / 2, scale),
                                 width: size.width, height: size.height)
            layer.mask?.frame = layer.bounds
        }
    }
}
