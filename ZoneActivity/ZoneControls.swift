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

/// What a control shows: nothing running, this control's recording running, or recognizing.
struct ControlPhase: Sendable, Equatable {
    enum Kind: Sendable { case idle, recording, processing }
    var kind: Kind

    /// The phase for the control that starts notes (`noteMode` true) or dictations. A recording
    /// of the other kind shows as idle here: pressing this control then does not stop it.
    static func current(noteMode: Bool, now: Date = Date()) -> ControlPhase {
        let state = CarWidgetState.read()
        // Zone stopped refreshing (killed, crashed): never claim a recording that is not running.
        guard now < state.staleAt else { return ControlPhase(kind: .idle) }
        switch state.phase {
        case .idle: return ControlPhase(kind: .idle)
        case .recording: return ControlPhase(kind: state.noteMode == noteMode ? .recording : .idle)
        case .processing: return ControlPhase(kind: state.noteMode == noteMode ? .processing : .idle)
        }
    }
}

struct NoteControlProvider: ControlValueProvider {
    var previewValue: ControlPhase { ControlPhase(kind: .idle) }
    func currentValue() async throws -> ControlPhase { .current(noteMode: true) }
}

struct DictateControlProvider: ControlValueProvider {
    var previewValue: ControlPhase { ControlPhase(kind: .idle) }
    func currentValue() async throws -> ControlPhase { .current(noteMode: false) }
}

struct ZoneNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CarWidgetState.noteControlKind, provider: NoteControlProvider()) { phase in
            ControlWidgetToggle("Voice note", isOn: phase.kind == .recording,
                                action: SetZoneRecordingIntent(noteMode: true)) { isOn in
                Label(isOn ? "Recording" : "Off", systemImage: isOn ? "stop.fill" : "mic.fill")
            }
            .tint(phase.kind == .recording ? .red : .orange)
        }
        .displayName("Voice note")
        .description("Press to start a note, press again to finish. Saved in Zone; the app you are in stays in front.")
    }
}

struct ZoneDictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: CarWidgetState.dictateControlKind, provider: DictateControlProvider()) { phase in
            ControlWidgetToggle("Dictate and copy", isOn: phase.kind == .recording,
                                action: SetZoneRecordingIntent(noteMode: false)) { isOn in
                Label(isOn ? "Recording" : "Off", systemImage: isOn ? "stop.fill" : "doc.on.clipboard")
            }
            .tint(phase.kind == .recording ? .red : .orange)
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
            .tint(.orange)
        }
        .displayName("Toggle Zone")
        .description("Turns Zone on so the keyboard microphone starts at once, for the time set in Zone. Turning it on opens Zone.")
    }
}
