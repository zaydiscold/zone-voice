// by zayd/cold @ zayd.wtf

import AppIntents
import SwiftUI
import WidgetKit

/// Controls (iOS 18): Zone's recording state as toggles the system draws itself, so they
/// can sit directly on the Action Button (Settings, Action Button, Controls), in Control Center
/// and on the Lock Screen. Through a Shortcut the Action Button shows a generic Shortcuts glyph
/// and no state; as a control it shows Zone's mic, and while that kind of recording runs, a red
/// stop with "Stop note" or "Stop dictation", so a glance says what the next press does.
/// The intents are `AudioRecordingIntent`s, so iOS performs them in the Zone app, exactly as
/// from the widget or a Shortcut. State comes from the same App Group file the widget reads.

/// What a control shows, from the App Group file the app writes (`CarWidgetState.controlShows`).
struct ControlPhase: Sendable, Equatable {
    var shows: CarWidgetState.ControlShows

    static func current(noteMode: Bool, now: Date = Date()) -> ControlPhase {
        ControlPhase(shows: CarWidgetState.read().controlShows(noteMode: noteMode, now: now))
    }

    /// On only for this control's own recording: iOS sends the toggle's opposite on a press, and
    /// only that recording can be stopped from here.
    var isOn: Bool { shows == .recording }
    func title(off: String) -> String { shows.title(off: off) }
    func glyph(off: String) -> String { shows.glyph(off: off) }
}

struct NoteControlProvider: ControlValueProvider {
    var previewValue: ControlPhase { ControlPhase(shows: .off) }
    func currentValue() async throws -> ControlPhase { .current(noteMode: true) }
}

struct DictateControlProvider: ControlValueProvider {
    var previewValue: ControlPhase { ControlPhase(shows: .off) }
    func currentValue() async throws -> ControlPhase { .current(noteMode: false) }
}

private func controlTint(isOn: Bool = false) -> Color {
    let choice = LastAccentChoice.current
    let light = UIColor(Color(hex: choice.lightHex))
    let dark = UIColor(Color(hex: choice.darkHex))
    return Color(uiColor: UIColor { traits in
        isOn || traits.userInterfaceStyle != .dark ? light : dark
    })
}

struct ZoneNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CarWidgetState.noteControlKind, provider: NoteControlProvider()) { phase in
            ControlWidgetToggle("Voice note", isOn: phase.isOn,
                                action: SetZoneRecordingIntent(noteMode: true)) { _ in
                Label(phase.title(off: "Off"), systemImage: phase.glyph(off: "mic.fill"))
            }
            .tint(controlTint(isOn: phase.isOn))
        }
        .displayName("Voice note")
        .description("Press to start a note, press again to finish. Saved in Zone; the app you are in stays in front.")
    }
}

struct ZoneDictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CarWidgetState.dictateControlKind, provider: DictateControlProvider()) { phase in
            ControlWidgetToggle("Dictate and copy", isOn: phase.isOn,
                                action: SetZoneRecordingIntent(noteMode: false)) { _ in
                Label(phase.title(off: "Off"), systemImage: phase.glyph(off: "doc.on.clipboard"))
            }
            .tint(controlTint(isOn: phase.isOn))
        }
        .displayName("Dictate and copy")
        .description("Press to start, press again to finish. The words are copied, ready to paste or insert from the Zone keyboard.")
    }
}

struct StandbyControlProvider: ControlValueProvider {
    var previewValue: StandbyControlState { .off }
    func currentValue() async throws -> StandbyControlState { .read() }
}

/// Toggle Zone: primes the keyboard's microphone the way Home's Turn on does, for the time
/// set in Zone. Turning it on opens Zone; turning it off does not.
struct ZoneStandbyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: StandbyControlState.controlKind, provider: StandbyControlProvider()) { state in
            ControlWidgetToggle("Toggle Zone", isOn: state.isOn(), action: SetZoneStandbyIntent()) { isOn in
                if isOn, let until = state.until {
                    Label("Until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "waveform")
                } else {
                    Label(isOn ? "On" : "Off", systemImage: isOn ? "waveform" : "waveform.slash")
                }
            }
            .tint(controlTint(isOn: state.isOn()))
        }
        .displayName("Toggle Zone")
        .description("Keeps the mic ready. Opens Zone to turn it on.")
    }
}

/// Bring back Zone's island, as a button for Control Center, the Lock Screen or the Action
/// Button. While Zone is on, one press puts Zone's card back in the Dynamic Island when iOS took
/// it away (its eight-hour limit, say), without opening Zone; iOS allows a new card from the
/// background only inside a press like this. With Zone off it does nothing.
struct ZoneIslandControl: ControlWidget {
    static let kind = StandbyControlState.islandControlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ShowIslandIntent()) {
                Label("Zone island", systemImage: "capsule.inset.filled")
            }
            .tint(controlTint())
        }
        .displayName("Bring back Zone's island")
        .description("Put Zone back in the Dynamic Island while Zone is on.")
    }
}
