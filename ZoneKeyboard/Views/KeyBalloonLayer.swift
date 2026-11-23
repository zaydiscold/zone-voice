// by zayd/cold @ zayd.wtf

import UIKit

/// The key pop preview: the pressed key's cap grows a wider head above it with the character
/// drawn large, like the system keyboard's balloon. One shape and one bitmap, no animation.
@MainActor
final class KeyBalloonLayer: CAShapeLayer {
    private let glyph = CALayer()

    /// Head is this much wider than the cap on each side.
    static let headOverhang: CGFloat = 11
    static let headHeight: CGFloat = 46
    static let neckHeight: CGFloat = 10
    static let headRadius: CGFloat = 10
    static let glyphSize: CGFloat = 32

    override init() {
        super.init()
        actions = Self.noActions
        glyph.actions = Self.noActions
        shadowColor = UIColor.black.cgColor
        shadowOffset = CGSize(width: 0, height: 1)
        shadowRadius = 1.5
        zPosition = 10
        addSublayer(glyph)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static let noActions: [String: CAAction] = [
        "backgroundColor": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "frame": NSNull(), "hidden": NSNull(), "path": NSNull(), "fillColor": NSNull(),
        "shadowPath": NSNull(), "opacity": NSNull(), "sublayers": NSNull(), "onOrderIn": NSNull(),
        "onOrderOut": NSNull(), "contentsScale": NSNull(),
    ]

    /// Shapes the balloon over `cap` (grid coordinates). `minY` is the highest point it may reach
    /// (the top of the keyboard's own view; anything above is clipped by the system), `width` the
    /// grid's width, which the head stays inside.
    func show(over cap: CGRect, glyph image: KeyGlyphs.Glyph?, fill: UIColor, isDark: Bool, minY: CGFloat, width: CGFloat, scale: CGFloat) {
        let headWidth = cap.width + 2 * Self.headOverhang
        let headLeft = min(max(cap.midX - headWidth / 2, 1), max(width - 1 - headWidth, 1))
        let headRight = headLeft + headWidth
        let headBottom = cap.minY - Self.neckHeight
        let headTop = max(headBottom - Self.headHeight, minY + 1)
        let neckStart = cap.minY + 4
        let r = KeyboardTheme.cornerRadius
        let hr = min(Self.headRadius, (headBottom - headTop) / 2)
        let bend = Self.neckHeight * 0.6

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cap.minX, y: cap.maxY - r))
        path.addLine(to: CGPoint(x: cap.minX, y: neckStart))
        path.addCurve(to: CGPoint(x: headLeft, y: headBottom),
                      control1: CGPoint(x: cap.minX, y: neckStart - bend),
                      control2: CGPoint(x: headLeft, y: headBottom + bend))
        path.addLine(to: CGPoint(x: headLeft, y: headTop + hr))
        path.addArc(tangent1End: CGPoint(x: headLeft, y: headTop), tangent2End: CGPoint(x: headLeft + hr, y: headTop), radius: hr)
        path.addLine(to: CGPoint(x: headRight - hr, y: headTop))
        path.addArc(tangent1End: CGPoint(x: headRight, y: headTop), tangent2End: CGPoint(x: headRight, y: headTop + hr), radius: hr)
        path.addLine(to: CGPoint(x: headRight, y: headBottom))
        path.addCurve(to: CGPoint(x: cap.maxX, y: neckStart),
                      control1: CGPoint(x: headRight, y: headBottom + bend),
                      control2: CGPoint(x: cap.maxX, y: neckStart - bend))
        path.addLine(to: CGPoint(x: cap.maxX, y: cap.maxY - r))
        path.addArc(tangent1End: CGPoint(x: cap.maxX, y: cap.maxY), tangent2End: CGPoint(x: cap.maxX - r, y: cap.maxY), radius: r)
        path.addLine(to: CGPoint(x: cap.minX + r, y: cap.maxY))
        path.addArc(tangent1End: CGPoint(x: cap.minX, y: cap.maxY), tangent2End: CGPoint(x: cap.minX, y: cap.maxY - r), radius: r)
        path.closeSubpath()

        contentsScale = scale
        self.path = path
        shadowPath = path
        fillColor = fill.cgColor
        shadowOpacity = isDark ? 0.5 : 0.3
        if let image {
            glyph.contentsScale = scale
            glyph.contents = image.image
            let center = CGPoint(x: (headLeft + headRight) / 2, y: (headTop + headBottom) / 2)
            glyph.frame = CGRect(x: KeyGridView.pixelRound(center.x - image.size.width / 2, scale),
                                 y: KeyGridView.pixelRound(center.y - image.size.height / 2, scale),
                                 width: image.size.width, height: image.size.height)
            glyph.isHidden = false
        } else {
            glyph.isHidden = true
        }
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}
