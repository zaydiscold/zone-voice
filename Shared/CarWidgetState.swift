// by zayd/cold @ zayd.wtf

import Foundation
import WidgetKit

/// What the Zone widget shows (Home Screen, StandBy, the CarPlay widget stacks): the recording
/// phase. The app writes it beside every Live Activity update; the widget extension reads it.
/// A small JSON file in the App Group, readable before first unlock, so the widget works in a
/// car with the phone locked in a pocket.
struct CarWidgetState: Codable, Equatable {
    enum Phase: String, Codable { case idle, recording, processing }
    var phase: Phase
    var noteMode: Bool
    var startedAt: Date?
    var updatedAt: Date
    /// Set while an interruption holds the recording: Zone sends no heartbeat with the
    /// microphone off, and the control must still show a recording that a press can stop.
    var freshUntil: Date?
    /// False for a recording no control started (the keyboard's, or one started in the app):
    /// a control press cannot stop it, but Zone is not free either. Nil is a control's own
    /// recording, which is all a file written before this field ever held.
    var controlOwned: Bool?

    /// When a recording claim with no refresh stops being believed.
    var staleAt: Date { max(updatedAt.addingTimeInterval(Self.staleAfter), freshUntil ?? .distantPast) }

    /// What a recording control shows, decided once for the Action Button, Control Center and
    /// the Voice note widget so they never disagree.
    enum ControlShows: Sendable, Equatable {
        /// Nothing running: a press starts.
        case off
        /// This control's own recording: a press stops it.
        case recording
        /// This control's own recording is being recognized.
        case saving
        /// Another recording holds Zone (the keyboard's, the app's, or the other control's).
        /// A press is refused with a notice, so this is never drawn as a stop.
        case busy(note: Bool, saving: Bool)

        /// The words under the glyph. A busy control names the other recording, so the notice
        /// a refused press shows is not a surprise.
        func title(off: String) -> String {
            switch self {
            case .off: off
            case .recording: "Recording"
            case .saving, .busy(_, saving: true): "Saving"
            case .busy(note: true, saving: false): "Recording note"
            case .busy(note: false, saving: false): "Dictating"
            }
        }

        /// Stop only where a press stops; a busy control shows the microphone in use instead.
        func glyph(off: String) -> String {
            switch self {
            case .off, .saving: off
            case .recording: "stop.fill"
            case .busy: "waveform"
            }
        }
    }

    /// For the control that starts notes (`noteMode` true) or dictations.
    func controlShows(noteMode: Bool, now: Date = Date()) -> ControlShows {
        // Zone stopped refreshing (killed, crashed): never claim a recording that is not running.
        guard phase != .idle, now < staleAt else { return .off }
        let saving = phase == .processing
        guard controlOwned != false, self.noteMode == noteMode else { return .busy(note: self.noteMode, saving: saving) }
        return saving ? .saving : .recording
    }

    static let widgetKind = "ZoneCarWidget"
    /// The Action Button, Control Center and Lock Screen controls (`ZoneActivity/ZoneControls.swift`).
    static let noteControlKind = "wtf.zayd.zone.control.note"
    static let dictateControlKind = "wtf.zayd.zone.control.dictate"
    /// The build's group (`ZONE_APP_GROUP`, the Info.plist's `ZoneAppGroup`), as `ZoneContract.appGroup`
    /// resolves it first; the widget extension does not link ZoneCore.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "ZoneAppGroup") as? String ?? "group.wtf.zayd.zone"
    static let fileName = "car-widget-state.json"
    /// A recording claim older than this with no refresh means Zone stopped (killed, crashed);
    /// the widget then says so instead of showing a timer that counts up forever. The app
    /// refreshes every 10 s: from the microphone heartbeat while it records, and from its own
    /// timer while it recognizes with the microphone off. The Live Activity's stale date uses
    /// the same limit (`RecordingLiveActivity.staleAfter`), so the island, the widget and the
    /// controls all give up on a dead Zone at the same moment.
    static let staleAfter: TimeInterval = 30

    static var idle: CarWidgetState { CarWidgetState(phase: .idle, noteMode: false, startedAt: nil, updatedAt: Date()) }

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func read() -> CarWidgetState {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return idle }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CarWidgetState.self, from: data)) ?? idle
    }

    /// Writes the state and asks WidgetKit to redraw. The reload is free while Zone's audio
    /// session is active (recording) and cheap otherwise: it happens on phase changes and on
    /// the 10 s heartbeat, not per level sample.
    static func publish(_ state: CarWidgetState) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        // The controls redraw only when asked; this is what flips the Action Button's glyph to
        // stop while recording and back afterwards.
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: noteControlKind)
            ControlCenter.shared.reloadControls(ofKind: dictateControlKind)
        }
    }
}


/// What the Toggle Zone control shows: whether the keyboard's instant dictation is on, and
/// until when. The app writes it whenever that changes; the widget extension reads it.
struct StandbyControlState: Codable, Equatable {
    var isOn: Bool
    /// Nil while on means "until I turn it off".
    var until: Date?

    var refreshedAt: Date? = Date()

    static let controlKind = "wtf.zayd.zone.control.standby"
    static let islandControlKind = "wtf.zayd.zone.control.island"
    static let fileName = "standby-control-state.json"
    static let off = StandbyControlState(isOn: false, until: nil)

    /// On only while its own deadline has not passed, so a Zone that iOS ended never shows a
    /// session that ran out hours ago.
    func isOn(at now: Date = Date()) -> Bool {
        guard isOn, let refreshedAt, now < refreshedAt.addingTimeInterval(CarWidgetState.staleAfter) else { return false }
        guard let until else { return true }
        return until > now
    }

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CarWidgetState.appGroup)?
            .appendingPathComponent(fileName)
    }

    static func read() -> StandbyControlState {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return off }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StandbyControlState.self, from: data)) ?? off
    }

    static func publish(_ state: StandbyControlState, reload: Bool) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if reload, #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: controlKind) }
    }
}
