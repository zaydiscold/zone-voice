// by zayd/cold @ zayd.wtf

import UIKit

/// A key label in the system font or an SF Symbol.
struct KeyGlyphSpec: Hashable {
    enum Kind: Hashable { case text, symbol }
    let kind: Kind
    let value: String
    let pointSize: CGFloat
    /// Points above the cap's center (labels sit about 1 pt high on the system keys).
    let lift: CGFloat
    /// Widest the glyph may draw; text shrinks to fit, down to 70 percent.
    let maxWidth: CGFloat

    static func text(_ value: String, size: CGFloat, lift: CGFloat = 0, maxWidth: CGFloat = .greatestFiniteMagnitude) -> KeyGlyphSpec {
        KeyGlyphSpec(kind: .text, value: value, pointSize: size, lift: lift, maxWidth: maxWidth)
    }

    static func symbol(_ name: String, size: CGFloat = 19) -> KeyGlyphSpec {
        KeyGlyphSpec(kind: .symbol, value: name, pointSize: size, lift: 0, maxWidth: .greatestFiniteMagnitude)
    }


}

/// Pre-rendered key labels. Each glyph is drawn once per appearance and scale and then reused as
/// a layer's contents, so a shift change swaps bitmaps instead of laying out text.
@MainActor
enum KeyGlyphs {
    struct Glyph {
        let image: CGImage
        /// Size in points.
        let size: CGSize
    }

    private struct CacheKey: Hashable {
        let spec: KeyGlyphSpec
        let isDark: Bool
        let scale: CGFloat
    }

    private static var cache: [CacheKey: Glyph] = [:]

    /// Drops every rendered glyph; keys already on screen keep their layer contents, and the
    /// rest are drawn again on demand. For a memory warning.
    static func purge() {
        cache = [:]
    }

    static func glyph(_ spec: KeyGlyphSpec, isDark: Bool, scale: CGFloat) -> Glyph? {
        let key = CacheKey(spec: spec, isDark: isDark, scale: scale)
        if let hit = cache[key] { return hit }
        // A keyboard draws a few hundred distinct glyphs at most; a runaway cache means a bug.
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        let color: UIColor = isDark ? .white : .black
        let made: Glyph?
        switch spec.kind {
        case .text: made = renderText(spec, color: color, scale: scale)
        case .symbol: made = renderSymbol(spec, color: color, scale: scale)
        }
        if let made { cache[key] = made }
        return made
    }

    private static func renderText(_ spec: KeyGlyphSpec, color: UIColor, scale: CGFloat) -> Glyph? {
        var font = UIFont.systemFont(ofSize: spec.pointSize, weight: .regular)
        var size = (spec.value as NSString).size(withAttributes: [.font: font])
        if size.width > spec.maxWidth, size.width > 0 {
            let factor = max(spec.maxWidth / size.width, 0.7)
            font = UIFont.systemFont(ofSize: spec.pointSize * factor, weight: .regular)
            size = (spec.value as NSString).size(withAttributes: [.font: font])
        }
        let canvas = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let image = renderer(canvas, scale: scale).image { _ in
            (spec.value as NSString).draw(at: CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2),
                                         withAttributes: [.font: font, .foregroundColor: color])
        }
        return image.cgImage.map { Glyph(image: $0, size: canvas) }
    }

    private static func renderSymbol(_ spec: KeyGlyphSpec, color: UIColor, scale: CGFloat) -> Glyph? {
        let configuration = UIImage.SymbolConfiguration(pointSize: spec.pointSize, weight: .regular)
        guard let symbol = UIImage(systemName: spec.value, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let canvas = symbol.size
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let image = renderer(canvas, scale: scale).image { _ in symbol.draw(at: .zero) }
        return image.cgImage.map { Glyph(image: $0, size: canvas) }
    }

    private static func renderer(_ size: CGSize, scale: CGFloat) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
    }
}
