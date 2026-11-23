// by zayd/cold @ zayd.wtf

import OSLog
import ZoneCore

/// Structured logs for the dictation handshake. Read with:
/// `log show --predicate 'subsystem == "wtf.zayd.zone"' --style compact --last 5m`
enum ZoneLog {
    static let coordinator = Logger(subsystem: "wtf.zayd.zone", category: "coordinator")
    static let audio = Logger(subsystem: "wtf.zayd.zone", category: "audio")
    static let journal = Logger(subsystem: "wtf.zayd.zone", category: "journal")
}

/// The app's side of the recording log (`RecordingJournal`): what happened to each recording,
/// kept on the phone for two weeks. Every line is also sent to the system log at notice level,
/// which, unlike info, iOS keeps on disk.
enum Journal {
    static let app = RecordingJournal.shared(process: "app")

    static func log(_ name: String, recording: UUID? = nil, _ fields: [String: String] = [:]) {
        app?.log(name, recording: recording, fields)
        let summary = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let id = recording.map { String($0.uuidString.prefix(8)) } ?? "-"
        ZoneLog.journal.notice("\(name, privacy: .public) \(id, privacy: .public) \(summary, privacy: .public)")
    }
}
