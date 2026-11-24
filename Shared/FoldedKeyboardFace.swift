// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The keyboard key on both faces. On the type face it shows the rows folding down; on the
/// dictate face it shows a keyboard, the thing a tap brings back. Key fill, key corners, 44 pt
/// wide to match the shift column it sits above.
struct ModeKeyView: View {
    let mode: KeyboardMode
    let theme: KeyboardTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode == .type ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(mode == .dictate ? theme.accentStroke : theme.text)
                .frame(width: 45, height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        // Latched while the keys are folded away: the switchboard key stays pressed in until
        // a second tap releases it.
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: mode == .dictate))
        .accessibilityLabel(mode == .type ? "Hide keys" : "Show keys")
        .accessibilityHint(mode == .type ? "Shrinks the keyboard to the dictation surface" : "Brings the key rows back")
    }
}


/// The strip's X key in the key fill: closes the inline style row. Same key as Cancel.
struct CancelCircleView: View {
    let theme: KeyboardTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: StripKey.width, height: StripKey.height)
                .frame(height: StripKey.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel("Close")
    }
}


/// The running clock while listening.
struct ListeningClock: View {
    let since: Date
    let font: Font
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(since)
            Text(elapsed.clockLabel)
                .font(font.monospacedDigit())
                .foregroundStyle(color)
                .accessibilityLabel("Recording for \(elapsed.clockLabel)")
        }
    }
}

/// One key language for the strip: a rounded key in the key fill casting a hard shadow from
/// where the sun really is (zayd.wtf's sundial shadow, computed once when the keyboard
/// appears). Pressing slides the key into its shadow; a latched key stays pressed in with an
/// inner shadow until released, like a switchboard key. Only real on/off controls latch.
struct SwitchKeyStyle: ButtonStyle {
    let theme: KeyboardTheme
    let latched: Bool
    /// The visible key inside the label's taller touch frame.
    var height: CGFloat = StripKey.height
    var faceWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StripKeyFace(theme: theme, pressed: configuration.isPressed, latched: latched, height: height, width: faceWidth))
            .sensoryFeedback(trigger: latched) { _, isLatched in isLatched ? .impact(flexibility: .rigid, intensity: 0.7) : .impact(flexibility: .soft, intensity: 0.5) }
    }
}

/// The raised key itself, for buttons and for keys that track their own press (Delete repeats
/// while held): the key fill, the latch edge, and the sun shadow it slides into when pressed.
struct StripKeyFace: ViewModifier {
    let theme: KeyboardTheme
    let pressed: Bool
    let latched: Bool
    var height: CGFloat = StripKey.height
    var width: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let sun = KeyboardSun.current
        let down = pressed || latched
        let depth = pressed ? 1.0 : (latched ? 0.6 : 0)
        let shape = RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(latched ? theme.latchedKey : theme.key)
                    .frame(width: width, height: height)
                    .overlay {
                        if latched {
                            shape.strokeBorder(Color.black.opacity(theme.isDark ? 0.45 : 0.16), lineWidth: 1)
                                .frame(width: width, height: height)
                        }
                    }
                    .shadow(color: .black.opacity(down ? 0 : sun.alpha * (theme.isDark ? 0.6 : 0.25)), radius: 0,
                            x: sun.dx, y: sun.dy)
            }
            .offset(x: reduceMotion ? 0 : sun.dx * depth, y: reduceMotion ? 0 : sun.dy * depth)
            .animation(reduceMotion ? nil : (pressed ? .spring(duration: 0.16, bounce: 0)
                                             : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)),
                       value: pressed)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: latched)
    }
}

/// The strip's one key size. Every control on the typing strip, the collapsed face's top row
/// and its right column (X, Delete, Return) is 36 pt tall. The collapsed face's capture keys,
/// the mic or Stop and Pause, are 56 pt squares centered beside that column. No control is a
/// circle: everything shares the key rows' 8 pt corners.
enum StripKey {
    static let typingStripHeight: CGFloat = 40
    static let foldedLowerHeight: CGFloat = 84
    static let foldedHeight: CGFloat = 44 + foldedLowerHeight
    static let height: CGFloat = 36
    static let touch: CGFloat = 44
    static let heroHeight: CGFloat = 56
    static let heroTouch: CGFloat = 64
    /// Icon keys: the keyboard key, Recent dictations, Pause, Cancel, the mic.
    static let width: CGFloat = 44
    /// The collapsed face's mic, Stop and Pause.
    static let heroWidth: CGFloat = 56
    /// Room a key face needs to clear the keyboard glass's rounded top corner.
    static let cornerClearance: CGFloat = 12
}

/// The primary strip key uses the accent fill. It latches while a
/// recording is on (pressed into its shadow with an inner edge), so the mic key reads as a
/// switch that was thrown and the Stop glyph on it says what the next tap does.
struct AccentKeyStyle: ButtonStyle {
    let theme: KeyboardTheme
    let latched: Bool
    let height: CGFloat
    /// Press and release, for the mic's hold (the styles).
    var onPressChange: ((Bool) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let sun = KeyboardSun.current
        let down = configuration.isPressed || latched
        let depth = configuration.isPressed ? 1.0 : (latched ? 0.6 : 0)
        let shape = RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
        configuration.label
            .background {
                shape
                    .fill(theme.controlFill)
                    .frame(height: height)
                    .overlay {
                        if latched {
                            shape.strokeBorder(theme.controlInk.opacity(0.35), lineWidth: 1.5)
                                .frame(height: height)
                        }
                    }
                    .shadow(color: .black.opacity(down ? 0 : sun.alpha * (theme.isDark ? 0.6 : 0.25)), radius: 0,
                            x: sun.dx, y: sun.dy)
            }
            .offset(x: reduceMotion ? 0 : sun.dx * depth, y: reduceMotion ? 0 : sun.dy * depth)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : (configuration.isPressed ? .spring(duration: 0.16, bounce: 0)
                                             : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)),
                       value: configuration.isPressed)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: latched)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange?(pressed) }
    }
}

/// Both the keyboard and Appearance lay out the folded face with these same rows.
struct FoldedKeyboardFace<Top: View, Lower: View, Column: View>: View {
    @ViewBuilder var top: Top
    @ViewBuilder var lower: Lower
    @ViewBuilder var column: Column

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                top
            }
            // 4 pt above the 36 pt controls (they sit 4 pt down inside their 44 pt touch frames).
            .frame(height: 44, alignment: .top)
            HStack(alignment: .top, spacing: 8) {
                lower
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 36 pt keys in 41 pt touch frames: the same 6 to 7 pt between X, Delete and Return.
                VStack(spacing: 2) {
                    column
                }
            }
            .frame(height: StripKey.foldedLowerHeight)
        }
        .padding(.leading, StripKey.cornerClearance)
        // The keyboard's glass has rounded top corners; the trailing control needs room to clear it.
        .padding(.trailing, StripKey.cornerClearance)
        .frame(height: StripKey.foldedHeight, alignment: .top)
    }

}

struct FoldedVoiceGraphic: View {
    let style: MeterStyle
    let levels: [Float]
    let live: Bool
    let theme: KeyboardTheme

    var body: some View {
        VoiceGraphic(style: style, levels: levels, live: live,
                     ink: UIColor(theme.text), accent: theme.otherAccentToneUIColor, edgeColor: theme.accentToneUIColor, isDark: theme.isDark)
        .frame(maxWidth: .infinity)
        .frame(height: style == .wave ? 64 : 48)
        .accessibilityHidden(true)
    }
}

struct PauseKey: View {
    let theme: KeyboardTheme
    let hero: Bool
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        let height = hero ? StripKey.heroHeight : StripKey.height
        return Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: hero ? 17 : 15, weight: .semibold))
                .foregroundStyle(isPaused ? theme.accentStroke : theme.text)
                .frame(width: hero ? StripKey.heroWidth : StripKey.width, height: height)
                .frame(height: hero ? StripKey.heroTouch : StripKey.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: isPaused, height: height))
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }
}

struct FoldedColumnLabel: View {
    let symbol: String
    let theme: KeyboardTheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.text)
            .frame(width: StripKey.width, height: StripKey.height)
            .frame(height: 41)
            .contentShape(Rectangle())
    }
}

struct CaptureKeySymbol: View {
    let recording: Bool
    let hero: Bool
    let theme: KeyboardTheme

    var body: some View {
        Image(systemName: recording ? "stop.fill" : "mic.fill")
            .font(.system(size: hero ? 19 : 17, weight: .semibold))
            .foregroundStyle(theme.controlInk)
            .contentTransition(.symbolEffect(.replace))
    }
}
