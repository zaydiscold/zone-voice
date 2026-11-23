// by zayd/cold @ zayd.wtf

import AppIntents
import Foundation

/// Zone's two recording intents, in a file the app and the widget extension both compile, so
/// a widget button (Home Screen, StandBy, the CarPlay widget stacks) can name them. Both are
/// `AudioRecordingIntent`s, so the system always performs them in the app's own process. Each
/// target supplies its own `ZoneIntentHost`: the app's does the work
/// (`Zone/Notes/DictateNoteIntent.swift`), the widget extension's can never be asked and says so.

/// "Voice note": bind it to the Action Button, run it from Shortcuts, or tap the Zone widget.
/// It starts recording into a new note at once; running it again while that note records
/// finishes the dictation; running it during preparation or processing leaves the current
/// work intact.
struct DictateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Voice note"
    static let description = IntentDescription("Press once to start, again to stop. The words are saved as a note in Zone. Nothing is pasted anywhere, and the app you are in stays in front.")
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ZoneIntentHost.perform(self, noteMode: true)
        return .result()
    }
}

/// Standalone dictation with a recoverable keyboard result, separate from saving a note.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate and copy"
    static let description = IntentDescription("Press once to start, again to stop. The words are copied, ready to paste anywhere or insert from the Zone keyboard. Not saved as a note.")
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ZoneIntentHost.perform(self, noteMode: false)
        return .result()
    }
}

/// Recording and Live Activity are separate system contracts. LiveActivityIntent permits
/// the user-triggered background intent to create the activity before microphone activation.
/// Both targets must advertise both contracts in their extracted intent metadata.
extension DictateNoteIntent: LiveActivityIntent {}
extension DictateIntent: LiveActivityIntent {}
@available(iOS 18.0, *)
extension DictateNoteIntent: AudioRecordingIntent {}
@available(iOS 18.0, *)
extension DictateIntent: AudioRecordingIntent {}


/// Direct controls send a desired state, unlike legacy Shortcuts which toggle. Repeated
/// requests for On must not turn recording off, and Off must never start a new recording.
struct SetZoneRecordingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Zone recording"
    static let isDiscoverable = false
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Recording") var value: Bool
    @Parameter(title: "Save as note") var noteMode: Bool

    init() {}
    init(noteMode: Bool) { self.noteMode = noteMode }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ZoneIntentHost.perform(self, noteMode: noteMode, desiredState: value)
        return .result()
    }
}

@available(iOS 18.0, *)
extension SetZoneRecordingIntent: AudioRecordingIntent {}
extension SetZoneRecordingIntent: LiveActivityIntent {}


/// "Toggle Zone": Home's Turn on and Turn off as a control, for people who dictate from the
/// keyboard and want it primed before they need it. On opens Zone, because iOS only lets an
/// app hold the microphone ready without a Live Activity when it was started in front; the
/// session then lasts as long as the person's own setting says. Off works in the background.
/// It is a `LiveActivityIntent` only so that iOS performs it in the Zone app, not the widget
/// extension. It is deliberately not an `AudioRecordingIntent`: it never records.
struct SetZoneStandbyIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Zone on or off"
    static let isDiscoverable = false
    static let openAppWhenRun = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "On") var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ZoneIntentHost.setStandby(self, on: value)
        return .result()
    }
}

extension SetZoneStandbyIntent: LiveActivityIntent {}


/// What a button in the Dynamic Island or on the Lock Screen card asks for.
enum IslandAction: String, CaseIterable {
    /// Standby: dictate now and copy the text, for use with any keyboard.
    case dictate
    /// Standby: record a voice note.
    case note
    /// Recording: finish, whichever surface started it.
    case stop
    /// Recording: pause, or carry on.
    case pause
}

/// The island's own buttons (Settings > Dynamic Island > Buttons). A `LiveActivityIntent`, so
/// iOS performs it in the Zone app, in the background, without opening it.
///
/// It is not an `AudioRecordingIntent`: it never switches the microphone on. Dictate and Note
/// appear only on the standby card, where the microphone session is already running; they
/// start a recording in that session the way a tap on the keyboard's microphone does. With no
/// session they do nothing but say so.
///
/// Stop is separate from `SetZoneRecordingIntent` on purpose. That intent only stops a
/// recording its own control started (`NoteActionPolicy`), so an Action Button press can never
/// end a keyboard dictation by accident. A Stop drawn on a recording's own card can only mean
/// that recording.
struct ZoneIslandIntent: AppIntent {
    static let title: LocalizedStringResource = "Zone island button"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "Action") var action: String

    init() {}
    init(_ action: IslandAction) { self.action = action.rawValue }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let action = IslandAction(rawValue: action) else { return .result() }
        try await ZoneIntentHost.island(action)
        return .result()
    }
}

extension ZoneIslandIntent: LiveActivityIntent {}
