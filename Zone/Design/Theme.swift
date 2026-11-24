// by zayd/cold @ zayd.wtf

import Observation
import SwiftUI
import UIKit
import ZoneCore

/// Zone's palette and surfaces: warm paper, ink, one chosen accent. Dark is the same system on
/// ash paper and is the default.
enum Zone {
    @MainActor static var darkAccent: Color { Color(hex: AccentStore.shared.choice.darkHex) }

    @MainActor static func accentTone(_ scheme: ColorScheme) -> Color {
        let choice = AccentStore.shared.choice
        return Color(hex: scheme == .dark ? choice.darkHex : choice.lightHex)
    }

    @MainActor static func controlFill(_ scheme: ColorScheme) -> Color {
        Color(hex: AccentStore.shared.choice.controlFillHex(isDark: scheme == .dark))
    }

    @MainActor static func controlInk(_ scheme: ColorScheme) -> Color {
        Color(hex: AccentStore.shared.choice.controlInkHex(isDark: scheme == .dark))
    }

    @MainActor static func accentStroke(_ scheme: ColorScheme) -> Color {
        let tone = UIColor(accentTone(scheme))
        let strong = UIColor(ink(scheme))
        return Color(uiColor: UIColor { $0.accessibilityContrast == .high ? strong : tone })
    }

    @MainActor static func inlineInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? accentStroke(scheme) : ink(scheme)
    }

    @MainActor static var accentTone: Color {
        Color(uiColor: AccentStore.shared.windowTint)
    }

    /// Errors and warnings only. Recording uses the accent: red read as alarm.
    static let live = Color(hex: 0xFF6B6B)
    /// One duration for every state change.
    static let motion: Animation = .easeInOut(duration: 0.2)
    /// zayd.wtf's --ease-out-quint, cubic-bezier(0.22, 1, 0.36, 1).
    static let easeOutQuint = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.22, y: 1), endControlPoint: UnitPoint(x: 0.36, y: 1))

    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2A2A2A) : Color(hex: 0xF1E9D2)
    }
    static func recess(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x242426) : Color(hex: 0xE9E0CA)
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x333333) : Color(hex: 0xF7F2E4)
    }
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF1E9D2) : Color(hex: 0x333333)
    }
    /// The label color on an ink surface (primary buttons).
    static func onInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2A2A2A) : Color(hex: 0xF1E9D2)
    }
    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xC9C1AB) : Color(hex: 0x555555)
    }
    static func rule(_ scheme: ColorScheme) -> Color {
        let color = UIColor(ink(scheme))
        return Color(uiColor: UIColor { traits in
            color.withAlphaComponent(traits.accessibilityContrast == .high ? 0.75 : (scheme == .dark ? 0.16 : 0.18))
        })
    }
    static func field(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x262626) : Color(hex: 0xF6EFDB)
    }

}

private struct ZoneAccentLink: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let scheme: ColorScheme

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content.foregroundStyle(increased ? Zone.ink(scheme) : Zone.inlineInk(scheme))
            .underline(scheme == .light || increased, color: increased ? Zone.ink(scheme) : Zone.accentStroke(scheme))
    }
}

struct ZoneCueLabelStyle: LabelStyle {
    let scheme: ColorScheme
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(Zone.accentTone(scheme))
            configuration.title.foregroundStyle(Zone.ink(scheme))
        }
    }
}

extension View {
    func zoneAccentLink(_ scheme: ColorScheme) -> some View {
        modifier(ZoneAccentLink(scheme: scheme))
    }

    func zoneAccentBadge(_ scheme: ColorScheme) -> some View {
        foregroundStyle(Zone.controlInk(scheme))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Zone.controlFill(scheme), in: Capsule())
    }
}

/// Observable so every view that reads `Zone.accentTone` redraws the moment the choice changes.
@Observable @MainActor
final class AccentStore {
    static let shared = AccentStore()
    var choice: AccentChoice = AccentChoice.current {
        didSet { applyToWindows() }
    }

    /// Pickers, links and other UIKit-backed controls take the window's tint, not SwiftUI's,
    /// so they kept the old color until the screen was rebuilt. Set it on every window.
    var windowTint: UIColor {
        let choice = choice
        return UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? choice.darkHex : choice.lightHex
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    var windowStyle: UIUserInterfaceStyle = .unspecified {
        didSet { applyToWindows() }
    }

    func applyToWindows() {
        let color = windowTint
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = windowStyle
                window.tintColor = color
            }
        }
    }
}

// MARK: Type roles (all scale with Dynamic Type)

extension Font {
    /// The wordmark in a screen header.
    static let zoneWordmark = Font.system(.title, design: .serif, weight: .semibold)
    /// The one headline per screen.
    static let zoneHeadline = Font.system(.largeTitle, design: .serif, weight: .semibold)
    /// A section or sheet title.
    static let zoneTitle = Font.system(.title2, design: .serif, weight: .semibold)
    /// Small label above a block.
    static let zoneEyebrow = Font.footnote.weight(.medium)
}

/// A serif display line sized in points but scaled with the reader's text size.
struct DisplayText: View {
    @Environment(\.colorScheme) private var scheme
    private var size: ScaledMetric<CGFloat>
    private let text: String
    private let weight: Font.Weight

    init(_ text: String, size: CGFloat = 40, weight: Font.Weight = .semibold) {
        self.text = text
        self.weight = weight
        self.size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Text(text)
            .font(.system(size: size.wrappedValue, weight: weight, design: .serif))
            .foregroundStyle(Zone.ink(scheme))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
    }
}

/// The hero number: a big serif figure with tabular digits that animates between values.
struct HeroNumber: View {
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 72
    let text: String
    var color: Color?

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .serif).monospacedDigit())
            .foregroundStyle(color ?? Zone.ink(scheme))
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: Surfaces

struct ZoneScreenModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Zone.paper(scheme).ignoresSafeArea())
            .tint(Zone.inlineInk(scheme))
    }
}

struct ZoneCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            // Every card is as wide as its column, so cards on one page share an edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Zone.cardRadius, style: .continuous)
                    .fill(Zone.card(scheme))
                    .sunShadow(scale: 0.8)
            }
            .overlay(RoundedRectangle(cornerRadius: Zone.cardRadius, style: .continuous).strokeBorder(Zone.rule(scheme), lineWidth: 1))
    }
}

/// A hard-edged shadow cast from where the sun or the moon actually is right now (real-shadows).
/// The light is worked out by RootView on each activation and every five minutes after, and
/// handed down the environment; no card computes it on its own.
struct SunShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sunShadow) private var sun
    var scale: Double = 1

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(sun.alpha * (scheme == .dark ? 0.55 : 0.18)), radius: 0,
                    x: sun.dx * scale, y: sun.dy * scale)
    }
}

private struct SunShadowKey: EnvironmentKey {
    /// Only for views outside RootView (previews); the app always sets the value.
    static let defaultValue = SunShadow.now()
}

extension SunShadow {
    /// The shadow for this moment. Debug builds take `-zoneSunAt 2026-11-16T15:00:00-08:00` to
    /// show the light at another time, for screenshots of a morning or a sunset.
    static func now() -> SunShadow {
        #if DEBUG
        if let iso = UserDefaults.standard.string(forKey: "zoneSunAt"), let date = ISO8601DateFormatter().date(from: iso) {
            return .at(date)
        }
        #endif
        return .at()
    }
}

extension EnvironmentValues {
    /// Where the sun is, for every sun-cast shadow in the app. Set by RootView on activation.
    var sunShadow: SunShadow {
        get { self[SunShadowKey.self] }
        set { self[SunShadowKey.self] = newValue }
    }
}

extension View {
    func sunShadow(scale: Double = 1) -> some View { modifier(SunShadowModifier(scale: scale)) }
}

/// Paints the status bar band in paper so scrolled content never shows under the clock on
/// screens without a navigation bar.
struct StatusBarBandModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { proxy in
                Zone.paper(scheme)
                    .frame(height: proxy.safeAreaInsets.top)
                    .offset(y: -proxy.safeAreaInsets.top)
                    .allowsHitTesting(false)
            }
            .frame(height: 0)
        }
    }
}

extension View {
    func zoneScreen() -> some View { modifier(ZoneScreenModifier()) }
    func statusBarBand() -> some View { modifier(StatusBarBandModifier()) }
    /// A quiet inset surface for quoted text (a note, a transcript). Not for layout.
    func zoneCard(padding: CGFloat = 16) -> some View { modifier(ZoneCardModifier(padding: padding)) }
}

/// One physical pixel between sibling rows. Its container aligns it with the row text.
struct RowRule: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle().fill(Zone.rule(scheme)).frame(height: 1 / scale)
            .accessibilityHidden(true)
    }
}

/// Open paper before a new group. Keep its title close to the first row.
struct SectionBreak: View {
    static let spacing: CGFloat = 28

    var body: some View {
        Color.clear.frame(height: Self.spacing).accessibilityHidden(true)
    }
}

/// A one-point stroke used in documents and fixed controls.
/// Use RowRule between library entries and SectionBreak between library groups.
struct Hairline: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Rectangle().fill(Zone.rule(scheme)).frame(height: 1)
    }
}

/// A small label that introduces a block. Sentence case.
struct Eyebrow: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.zoneEyebrow)
            .foregroundStyle(Zone.muted(scheme))
    }
}

// MARK: Shapes

/// Three shapes, three jobs, on every Zone surface (the app, Zone for Mac, the computer's page):
/// a key for every button, a card for a group set apart, a capsule for the mode switch only.
/// Round is kept for the mic and the recording actions, which are the keyboard's own.
extension Zone {
    /// A card: a group of settings, quoted text, a figure set apart.
    static let cardRadius: CGFloat = 16
    /// A text field or editor that stands on the paper by itself.
    static let fieldRadius: CGFloat = 12
    static var keyShape: RoundedRectangle { RoundedRectangle(cornerRadius: keyRadius, style: .continuous) }
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
    static var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: fieldRadius, style: .continuous) }
}

// MARK: Buttons

/// The primary action uses the accent fill and its contrasting label.
struct ZonePrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let label = isEnabled ? Zone.controlInk(scheme) : Zone.muted(scheme)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(label)
            .tint(label)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background { Zone.keyShape.fill(isEnabled ? Zone.controlFill(scheme) : Zone.field(scheme)).sunShadow(scale: isEnabled ? 0.6 : 0) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Zone.motion, value: configuration.isPressed)
            .contentShape(Zone.keyShape)
    }
}

/// Card-colored key for secondary actions.
struct ZoneQuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Zone.ink(scheme))
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background { Zone.keyShape.fill(Zone.card(scheme)).sunShadow(scale: 0.6) }
            .overlay(Zone.keyShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Zone.motion, value: configuration.isPressed)
            .contentShape(Zone.keyShape)
    }
}

/// Small inline key for row actions (Copy, Share). The key is 32 pt tall; the touch target is 44.
struct ZonePillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .foregroundStyle(Zone.ink(scheme))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background { Zone.keyShape.fill(Zone.card(scheme)).sunShadow(scale: 0.6) }
            .overlay(Zone.keyShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The small ink key: the one action in a row that should pull the eye (Turn on).
struct ZoneInkPillButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Zone.onInk(scheme))
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background { Zone.keyShape.fill(Zone.ink(scheme).opacity(isEnabled ? 1 : 0.4)).sunShadow(scale: isEnabled ? 0.6 : 0) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Zone.motion, value: configuration.isPressed)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A plain text button in the accent tone.
struct ZoneLinkButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .zoneAccentLink(scheme)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A round action: X to cancel, checkmark to finish. The keyboard's vocabulary, reused in the app.
struct RoundAction: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let label: String
    var prominent = false
    var diameter: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.34, weight: .bold))
                .foregroundStyle(prominent ? Zone.onInk(scheme) : Zone.ink(scheme))
                .frame(width: diameter, height: diameter)
                .background(prominent ? Zone.ink(scheme) : Zone.card(scheme), in: Circle())
                .overlay(Circle().strokeBorder(prominent ? .clear : Zone.rule(scheme), lineWidth: 1))
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Zone.motion, value: configuration.isPressed)
    }
}

/// The round mic key used in the app's own surfaces: the accent circle with a mic. Recording
/// is shown by the surface around it (the Composer swaps to Cancel, a wave and Done), so this
/// key has no recording face of its own.
struct MicButton: View {
    @Environment(\.colorScheme) private var scheme
    var diameter: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(.system(size: diameter * 0.34, weight: .semibold))
                .foregroundStyle(Zone.controlInk(scheme))
                .frame(width: diameter, height: diameter)
                .background(Zone.controlFill(scheme), in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("Dictate")
    }
}

/// A state light. Accent-colored and pulsing when on, a hollow grey ring when off, so the state never
/// rests on color alone. The pulse is zayd.wtf's live ring: a 1.5 pt ring expands from 16 to
/// about 29 pt and fades from 0.8 to 0 over 2 s on ease-out-quint. Reduce Motion holds it still.
struct StatusDot: View {
    let color: Color
    var pulses = false
    var hollow = false
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulses {
                if reduceMotion {
                    Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5).frame(width: size * 2.2, height: size * 2.2)
                } else {
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                        .frame(width: size * 1.6, height: size * 1.6)
                        .keyframeAnimator(initialValue: PulseRing(), repeating: true) { ring, value in
                            ring.scaleEffect(value.scale).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                LinearKeyframe(1.8, duration: 2, timingCurve: Zone.easeOutQuint)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(0, duration: 2, timingCurve: Zone.easeOutQuint)
                            }
                        }
                }
            }
            if hollow {
                Circle().strokeBorder(color, lineWidth: max(1.5, size / 7)).frame(width: size, height: size)
            } else {
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .frame(width: size * 3, height: size * 3)
        .accessibilityHidden(true)
    }
}

private struct PulseRing {
    var scale: Double = 1
    var opacity: Double = 0.8
}

// MARK: Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func start() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
