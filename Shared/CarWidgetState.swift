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

    /// When a recording claim with no refresh stops being believed.
    var staleAt: Date { max(updatedAt.addingTimeInterval(Self.staleAfter), freshUntil ?? .distantPast) }

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
    /// refreshes every 10 s from the microphone heartbeat while it records.
    static let staleAfter: TimeInterval = 45

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

    static let controlKind = "wtf.zayd.zone.control.standby"
    static let fileName = "standby-control-state.json"
    static let off = StandbyControlState(isOn: false, until: nil)

    /// On only while its own deadline has not passed, so a Zone that iOS ended never shows a
    /// session that ran out hours ago.
    func isOn(at now: Date = Date()) -> Bool {
        guard isOn else { return false }
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

    static func publish(_ state: StandbyControlState) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadControls(ofKind: controlKind) }
    }
}
