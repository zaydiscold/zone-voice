// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Colors that follow the host field's light or dark keyboard appearance. Keys match iOS 26's
/// system keyboard (measured in the iPhone 17 Pro simulator):
/// every key the same fill, no shadow, 8 pt corners. Zone's own color appears only on the
/// live waveform.
struct KeyboardTheme {
    let isDark: Bool
    /// The stamp, fills and UIKit colors are captured together for this keyboard appearance.
    let accentStamp: AccentChoice
    let accentTone: Color
    let accentToneUIColor: UIColor

    init(isDark: Bool, accentStamp: AccentChoice = KeyboardTheme.accentChoice) {
        self.isDark = isDark
        self.accentStamp = accentStamp
        accentTone = Color(hex: isDark ? accentStamp.darkHex : accentStamp.lightHex)
        accentToneUIColor = UIColor(accentTone)
    }

    /// zayd.wtf's accent, shared with the app (the extension has no asset catalog).
    /// Read once per keyboard appearance (`refreshAccent`), not on every use: each read was a
    /// shared-defaults lookup, 40 to 60 a second while recording.
    nonisolated(unsafe) private(set) static var accentChoice = storedAccent()
    nonisolated(unsafe) private(set) static var accent = Color(hex: accentChoice.darkHex)

    /// The app's accent, or the last one this keyboard read when the App Group gives nothing back
    /// (a fresh keyboard process can read before its access settles, and drew violet).
    private static func storedAccent() -> AccentChoice {
        LastAccentChoice().resolve(stored: AccentChoice.stored)
    }

    /// Rereads the stored accent; true when it changed.
    @discardableResult
    static func refreshAccent() -> Bool {
        let choice = storedAccent()
        guard choice != accentChoice else { return false }
        accentChoice = choice
        accent = Color(hex: choice.darkHex)
        return true
    }

    /// The other reviewed tone makes the braid visible when either surface tone changes.
    var otherAccentToneUIColor: UIColor { UIColor(Color(hex: isDark ? accentStamp.lightHex : accentStamp.darkHex)) }

    var accentStroke: Color {
        let tone = accentToneUIColor
        let strong = UIColor(text)
        return Color(uiColor: UIColor { $0.accessibilityContrast == .high ? strong : tone })
    }

    var markFaceHex: UInt32 { isDark && accentStamp == .ice ? 0xB1D5DF : accentStamp.darkHex }
    var markRimHex: UInt32 { isDark && accentStamp == .ice ? 0x48636D : accentStamp.lightHex }

    var controlFill: Color { Color(hex: accentStamp.controlFillHex(isDark: isDark)) }
    var controlInk: Color { Color(hex: accentStamp.controlInkHex(isDark: isDark)) }

    static let live = Color(hex: 0xFF6B6B)

    /// Painted only when the system backdrop is unavailable; normally the input view's own
    /// keyboard backdrop shows through.
    var background: Color { isDark ? Color(hex: 0x171717) : Color(hex: 0xE2E4E8) }
    /// Dark #6B6B6B: the system key on a real iPhone 15 Pro, iOS 27, sampled from a
    /// device screenshot. The simulator's #424243 read far darker than the device,
    /// which made Zone's keys look smaller than Apple's at the same size.
    var key: Color { isDark ? Color(hex: 0x6B6B6B) : .white }
    var pressedKey: Color { isDark ? Color(hex: 0x4C4C4D) : Color(hex: 0xD1D3D9) }
    /// A latched strip key: darker than the raised key so it reads as pressed in.
    var latchedKey: Color { isDark ? Color(hex: 0x2E2E2F) : Color(hex: 0xD1D3D9) }
    var text: Color { isDark ? .white : .black }
    var ink: Color { isDark ? .white : .black }
    var onInk: Color { isDark ? .black : .white }
    var secondaryText: Color { isDark ? Color.white.opacity(0.65) : Color.black.opacity(0.55) }
    static let cornerRadius: CGFloat = 8
}

/// The logo has the same rim and face on both keyboard appearances.
struct ZoneHomeMark: View {
    let theme: KeyboardTheme

    var body: some View {
        ZoneHomeGlyph()
            .fill(Color(hex: theme.markFaceHex))
            .background {
                ZoneHomeGlyph().stroke(Color(hex: theme.markRimHex),
                                       style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .frame(width: 18 * 293 / 355, height: 18)
            .padding(1)
            .accessibilityHidden(true)
    }
}

/// The outline of the 293 × 355 serif Z used for the app mark. A native shape also
/// draws inside a hosted keyboard button without resolving a template image in Canvas.
private struct ZoneHomeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 11, y: 0))
        path.addLine(to: CGPoint(x: 291, y: 0))
        path.addLine(to: CGPoint(x: 108, y: 351))
        path.addQuadCurve(to: CGPoint(x: 174, y: 348), control: CGPoint(x: 140, y: 351))
        path.addCurve(to: CGPoint(x: 291, y: 231), control1: CGPoint(x: 254, y: 342),
                      control2: CGPoint(x: 280, y: 310))
        path.addLine(to: CGPoint(x: 288, y: 355))
        path.addLine(to: CGPoint(x: 1, y: 355))
        path.addLine(to: CGPoint(x: 184, y: 4))
        path.addQuadCurve(to: CGPoint(x: 124, y: 8), control: CGPoint(x: 153, y: 5))
        path.addCurve(to: CGPoint(x: 7, y: 110), control1: CGPoint(x: 47, y: 16),
                      control2: CGPoint(x: 20, y: 47))
        path.closeSubpath()
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 293, y: rect.height / 355))
    }
}

extension View {
    func keyboardAccentBadge(_ theme: KeyboardTheme) -> some View {
        foregroundStyle(theme.controlInk)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(theme.controlFill, in: Capsule())
    }
}

/// The sun or moon shadow for strip keys, read once per keyboard appearance: no location, no
/// timer. Strip keys sit a few points apart, so they keep a shorter shadow than the app's cards.
/// 2 pt overhead (and at night) to 3.5 pt on the horizon: at 1 pt the night shadow was a hairline
/// on the phone (Zayd, November 19), and the keys sit 6 pt apart, so 3.5 still clears the next.
enum KeyboardSun {
    static var current = cast()
    static func refresh() { current = cast() }
    private static func cast() -> SunShadow { SunShadow.at(minLength: 2, maxLength: 3.5) }
}

extension View {
    /// The raised-key shadow alone, for shapes that are not buttons (the style key's fill).
    func sunCast(theme: KeyboardTheme) -> some View {
        let sun = KeyboardSun.current
        return shadow(color: .black.opacity(sun.alpha * (theme.isDark ? 0.6 : 0.25)), radius: 0, x: sun.dx, y: sun.dy)
    }
}
