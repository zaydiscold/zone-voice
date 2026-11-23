// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// The computer side of Zone Link, written from PROTOCOL.md, for tests. It speaks over any
/// `LinkByteStream`: an in-memory pipe in ZoneCore's tests, a real iroh stream in ZoneLink's
/// (that package's test target includes this same file).
final class FakeComputer: @unchecked Sendable {
    struct Row: Equatable {
        var item: LinkItem
        var deleted: Bool
    }

    private let lock = NSLock()
    private var _databaseID = UUID().uuidString
    private var _secrets: Set<String> = []
    private var _phones: Set<String> = []
    private var _rows: [String: Row] = [:]
    private var _frames: [[LinkItem]] = []
    private var _hellos: [LinkMessage] = []
    private var _sessions = 0
    private var _resendAll = false
    private var _refuseAll: String?
    private var _silentAfterItems = false
    let name: String

    init(name: String = "testbox") { self.name = name }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var databaseID: String { locked { _databaseID } }
    var rows: [String: Row] { locked { _rows } }
    /// Every `items` frame received, in order, across sessions.
    var frames: [[LinkItem]] { locked { _frames } }
    var hellos: [LinkMessage] { locked { _hellos } }
    var sessions: Int { locked { _sessions } }
    var liveRows: [Row] { rows.values.filter { !$0.deleted } }

    /// `zone pair`: a fresh one-use secret, as 64 lowercase hex characters.
    func newPairingSecret() -> String {
        let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        locked { _ = _secrets.insert(secret) }
        return secret
    }

    func forgetPhones() { locked { _phones = [] } }
    /// A new, empty database: what the phone sees after the computer is wiped.
    func replaceDatabase() { locked { _databaseID = UUID().uuidString; _rows = [:] } }
    func askForEverythingOnce() { locked { _resendAll = true } }
    func refuseEverything(_ reason: String?) { locked { _refuseAll = reason } }
    /// Stops answering after the next `items` frame: no ack, the stream stays open.
    func goSilentAfterItems(_ silent: Bool) { locked { _silentAfterItems = silent } }
    func clearFrames() { locked { _frames = [] } }

    /// One session. `peer` is the phone's identity as the connection proved it (its iroh
    /// endpoint id); the computer authorizes by that, never by what `hello` claims.
    func serve(_ stream: LinkByteStream, peer: String) async {
        locked { _sessions += 1 }
        do {
            guard case .hello(_, let pair) = try await receive(stream) else { return }
            let reply: LinkMessage = locked {
                if let reason = _refuseAll { return .refused(reason: reason) }
                if let pair {
                    guard _secrets.remove(pair) != nil else { return .refused(reason: "bad_secret") }
                    _phones.insert(peer)
                } else if !_phones.contains(peer) {
                    return .refused(reason: "not_paired")
                }
                let resend = _resendAll
                _resendAll = false
                return .welcome(computer: LinkComputer(id: _databaseID, name: name, os: "macos", version: "0.0.0-test"),
                                items: _rows.count, resendAll: resend)
            }
            try await send(reply, stream)
            guard case .welcome = reply else {
                try? await stream.finishWriting()
                return
            }
            while true {
                switch try await receive(stream) {
                case .items(let seq, let items):
                    let silent: Bool = locked {
                        _frames.append(items)
                        for item in items { merge(item) }
                        return _silentAfterItems
                    }
                    if silent {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        return
                    }
                    try await send(.ack(seq: seq, stored: items.count), stream)
                case .bye:
                    try? await stream.finishWriting()
                    return
                default:
                    return
                }
            }
        } catch {
            return
        }
    }

    /// PROTOCOL.md's merge rule: insert when new, otherwise replace when the incoming
    /// `updated_at` is not older. A deletion keeps the row and drops the text.
    private func merge(_ item: LinkItem) {
        if let stored = _rows[item.id], item.updatedAt < stored.item.updatedAt { return }
        if item.deleted {
            var kept = _rows[item.id]?.item ?? item
            kept.text = nil
            kept.updatedAt = item.updatedAt
            _rows[item.id] = Row(item: kept, deleted: true)
        } else {
            _rows[item.id] = Row(item: item, deleted: false)
        }
    }

    private func receive(_ stream: LinkByteStream) async throws -> LinkMessage {
        let header = try await stream.read(exactly: LinkFrame.headerBytes)
        let payload = try await stream.read(exactly: try LinkFrame.length(header: header))
        let message = try LinkMessage.decode(payload)
        if case .hello = message { locked { _hellos.append(message) } }
        return message
    }

    private func send(_ message: LinkMessage, _ stream: LinkByteStream) async throws {
        try await stream.write(try LinkFrame.frame(try message.encoded()))
    }
}

/// A phone for tests: a real history file, notes and meetings in memory, the Link store and the
/// deletion log wired the way the app wires them, and a session run over an in-memory pipe.
final class LinkTestPhone: @unchecked Sendable {
    let directory: URL
    let history: TranscriptHistory
    let store: LinkStore
    let log: LinkDeletionLog
    let endpointID: String
    let identity = "phone-endpoint-id"
    private let lock = NSLock()
    private var _notes: [LibraryNote] = []
    private var _meetings: [Meeting] = []
    private var _extra: [TranscriptRecord] = []
    private var _now = Date(timeIntervalSince1970: 1_794_500_000)

    init(endpointID: String = "523c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea") {
        self.endpointID = endpointID
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-tests-\(UUID().uuidString)")
        history = TranscriptHistory(directory: directory.appendingPathComponent("History"))
        store = LinkStore(directory: directory.appendingPathComponent("Link"))
        log = LinkDeletionLog(fileURL: store.deletionLogURL)
        let log = log, store = store
        history.explicitDeletionSink = { ids, date in store.recordDeletion(ids, kind: .dictation, at: date, in: log) }
        store.add(PairedComputer(endpointID: endpointID, name: "testbox"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
    var notes: [LibraryNote] {
        get { lock.lock(); defer { lock.unlock() }; return _notes }
        set { lock.lock(); _notes = newValue; lock.unlock() }
    }
    var meetings: [Meeting] {
        get { lock.lock(); defer { lock.unlock() }; return _meetings }
        set { lock.lock(); _meetings = newValue; lock.unlock() }
    }
    /// Dictations that skip the history file, for libraries too large to write one at a time.
    var extraDictations: [TranscriptRecord] {
        get { lock.lock(); defer { lock.unlock() }; return _extra }
        set { lock.lock(); _extra = newValue; lock.unlock() }
    }

    @discardableResult
    func dictate(_ number: Int, text: String? = nil) -> UUID {
        let id = LinkFixtures.uuid(number)
        history.finish(id: id, text: text ?? "dictation number \(number)", audioSeconds: 3, status: .finished,
                       engine: "fluidMini", source: .keyboard, now: now)
        return id
    }

    func library() -> [LinkItem] {
        LinkEncoding.library(dictations: history.records(now: now) + extraDictations, notes: notes, meetings: meetings)
    }

    var delivery: LinkDeliveryState { store.delivery(for: endpointID) }
}

/// A synthetic library with stable ids, for tests and the fake computer.
enum LinkFixtures {
    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "9F1C2E6A-0000-4000-8000-%012d", number))!
    }

    static func dictation(_ number: Int, text: String? = nil, at seconds: Double = 1_794_445_200,
                          status: TranscriptStatus = .inserted, source: TranscriptSource = .keyboard) -> TranscriptRecord {
        let created = Date(timeIntervalSince1970: seconds + Double(number))
        return TranscriptRecord(id: uuid(number), text: text ?? "dictation number \(number)", createdAt: created,
                                updatedAt: created.addingTimeInterval(2), audioSeconds: 4.2, engine: "fluidMini",
                                source: source, status: status)
    }

    static func note(_ number: Int, text: String? = nil) -> LibraryNote {
        LibraryNote(id: uuid(1_000_000 + number), text: text ?? "note number \(number)",
                    createdAt: Date(timeIntervalSince1970: 1_794_000_000 + Double(number)))
    }

    static func meeting(_ number: Int = 1, status: Meeting.Status = .done) -> Meeting {
        var meeting = Meeting(id: uuid(2_000_000 + number), title: "Planning \(number)",
                              createdAt: Date(timeIntervalSince1970: 1_794_100_000), status: status)
        meeting.parts = [MeetingAudioPart(fileName: "part-1.pcm", bytes: 16_000 * 2 * 30)]
        meeting.speakers = [MeetingSpeaker(id: "S1", name: "Dana"), MeetingSpeaker(id: "S2", isMe: true), MeetingSpeaker(id: "S3")]
        meeting.segments = [
            MeetingSegment(start: 0, end: 4.5, speaker: "S1", text: "Let us start with the launch."),
            MeetingSegment(start: 4.5, end: 9, speaker: "S2", text: "The build is ready."),
            MeetingSegment(start: 9, end: 12.5, speaker: "S3", text: "Then we ship on Friday."),
            MeetingSegment(start: 12.5, end: 15, speaker: nil, text: "Agreed."),
            MeetingSegment(start: 15, end: 16, speaker: "S1", text: "   "),
        ]
        meeting.engine = "fluidMini"
        meeting.diarizer = "pyannote"
        meeting.transcribedThrough = 30
        return meeting
    }
}
