// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Colors that follow the host field's light or dark keyboard appearance. Keys match iOS 26's
/// system keyboard (measured in the iPhone 17 Pro simulator):
/// every key the same fill, no shadow, 8 pt corners. Zone's own color appears only on the
/// live waveform.
struct KeyboardTheme {
    let isDark: Bool
    /// The accent this theme was made with. The colors below are statics SwiftUI cannot observe;
    /// carrying the choice makes a theme made after `refreshAccent` changed it a different value,
    /// so every view handed the theme draws again with the new accent.
    var accentStamp = KeyboardTheme.accentChoice

    /// zayd.wtf's accent, shared with the app (the extension has no asset catalog).
    /// Read once per keyboard appearance (`refreshAccent`), not on every use: each read was a
    /// shared-defaults lookup, 40 to 60 a second while recording.
    nonisolated(unsafe) private(set) static var accentChoice = storedAccent()
    nonisolated(unsafe) private(set) static var accent = Color(hex: accentChoice.hex)
    nonisolated(unsafe) private(set) static var accentOnLight = Color(hex: accentChoice.textHexOnLight)

    /// The same accents as UIColors for the Core Animation views (meter, wave, ring), converted
    /// once per accent change instead of on every 20 Hz meter update.
    nonisolated(unsafe) private(set) static var accentUIColor = UIColor(accent)
    nonisolated(unsafe) private(set) static var accentOnLightUIColor = UIColor(accentOnLight)
    nonisolated(unsafe) private(set) static var accentGraphicOnLightUIColor = UIColor(Color(hex: accentChoice.graphicHexOnLight))

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
        accent = Color(hex: choice.hex)
        accentOnLight = Color(hex: choice.textHexOnLight)
        accentUIColor = UIColor(accent)
        accentOnLightUIColor = UIColor(accentOnLight)
        accentGraphicOnLightUIColor = UIColor(Color(hex: choice.graphicHexOnLight))
        return true
    }

    /// The accent for glyphs and text: Ice and Ember are too light on white keys and light
    /// backgrounds (1.3 to 2.3:1), so light keyboards use the deeper tone of the same hue.
    var accentInk: Color { isDark ? Self.accent : Self.accentOnLight }
    var accentInkUIColor: UIColor { isDark ? Self.accentUIColor : Self.accentOnLightUIColor }

    /// The accent for shapes (wave, bars, swipe trail): the accent on dark keyboards, its vivid
    /// mid tone on light ones, where the pale accent is a tint against the backdrop.
    var accentGraphicUIColor: UIColor { isDark ? Self.accentUIColor : Self.accentGraphicOnLightUIColor }

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
    var secondaryText: Color { isDark ? Color.white.opacity(0.65) : Color.black.opacity(0.55) }
    /// The one ink control in the strip: the mic circle and the Start pill.
    var ink: Color { isDark ? .white : .black }
    var onInk: Color { isDark ? .black : .white }
    static let cornerRadius: CGFloat = 8
}

/// The icon's Z on its own, with no tile behind it. It takes the accent's ink tone: the accent on
/// dark keyboards and its deeper shade on light ones, where Ice and Ember are too pale to read.
/// A charcoal tile behind it (build 2026110812) read as a dark square on light keyboards.
struct ZoneHomeMark: View {
    let theme: KeyboardTheme

    var body: some View {
        Image("ZoneHomeMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            // 18 pt: at 15 pt the icon Z's hairline bars washed out on a phone and the letter read as a slash.
            .frame(width: 18 * 293 / 355, height: 18)
            .foregroundStyle(theme.accentInk)
    }
}
