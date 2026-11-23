// by zayd/cold @ zayd.wtf

import Foundation

/// One line of the recording log: what happened to a recording, never what was said.
public struct JournalEvent: Codable, Equatable, Sendable {
    /// Wall-clock time, milliseconds since 1970.
    public var t: Int64
    /// The process that wrote it: "app" or "keyboard".
    public var p: String
    /// First eight characters of the recording's id, when the event belongs to one.
    public var r: String?
    public var name: String
    /// Counts, durations, states and error codes. Never transcript text.
    public var f: [String: String]

    public init(at date: Date, process: String, recording: UUID?, name: String, fields: [String: String]) {
        t = Int64((date.timeIntervalSince1970 * 1000).rounded())
        p = process
        r = recording.map { String($0.uuidString.prefix(8)) }
        self.name = name
        f = fields
    }

    public var date: Date { Date(timeIntervalSince1970: Double(t) / 1000) }
}

/// A persistent log of what happens to recordings: starts, stops, interruptions and how they
/// ended, resumes, engine failures, saves. It exists because `Logger.info` lines are kept only
/// in memory and are gone within minutes, so a recording that went wrong in a meeting left no
/// trace by the time anyone looked (2026-11-03: three cut-offs, no Zone log lines survived).
///
/// One JSON object per line, one file per process (no cross-process locking), in the App Group
/// so the app can show the keyboard's side too. Each file is capped at `maxBytes` and cut back to
/// `trimTarget` when it grows past it, oldest lines first; lines older than `retention` go at the
/// same time. Nothing here leaves the phone unless the person shares the file.
public final class RecordingJournal: @unchecked Sendable {
    public static let maxBytes = 1_000_000
    public static let trimTarget = 850_000
    public static let retention: TimeInterval = 14 * 86_400

    public let directory: URL
    public let process: String
    private let fileURL: URL
    private let queue: DispatchQueue
    private var handle: FileHandle? // queue only
    private var bytes = 0 // queue only
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(directory: URL, process: String) {
        self.directory = directory
        self.process = process
        fileURL = directory.appendingPathComponent("\(process).jsonl")
        queue = DispatchQueue(label: "wtf.zayd.zone.journal.\(process)", qos: .utility)
    }

    /// The journal in the App Group container, or nil when the container is unreachable.
    public static func shared(process: String) -> RecordingJournal? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) else {
            return nil
        }
        return RecordingJournal(directory: container.appendingPathComponent("Library/Application Support/Journal", isDirectory: true),
                                process: process)
    }

    public func log(_ name: String, recording: UUID? = nil, _ fields: [String: String] = [:], at date: Date = Date()) {
        let event = JournalEvent(at: date, process: process, recording: recording, name: name, fields: fields)
        queue.async { [self] in append(event) }
    }

    /// Waits for every event logged so far to reach the file. For tests and before an export.
    public func flush() {
        queue.sync {}
    }

    /// Every process's events, oldest first, optionally only those at or after `since`.
    public func events(since: Date? = nil) -> [JournalEvent] {
        flush()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let cutoff = since.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        var events: [JournalEvent] = []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let event = try? decoder.decode(JournalEvent.self, from: Data(line)) else { continue }
                if let cutoff, event.t < cutoff { continue }
                events.append(event)
            }
        }
        return events.sorted { $0.t < $1.t }
    }

    /// One file with every process's lines in time order, for the share sheet.
    public func exportFile(to url: URL) throws {
        let lines = try events().map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Queue only

    private func append(_ event: JournalEvent) {
        guard var line = try? encoder.encode(event) else { return }
        line.append(UInt8(ascii: "\n"))
        guard let handle = openHandle() else { return }
        do {
            try handle.write(contentsOf: line)
            bytes += line.count
        } catch {
            try? handle.close()
            self.handle = nil
            return
        }
        if bytes > Self.maxBytes { trim(now: event.date) }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var url = fileURL
                try? url.setResourceValues(values)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            bytes = Int(try handle.seekToEnd())
            self.handle = handle
            if bytes > Self.maxBytes { trim(now: Date()) }
            return self.handle
        } catch {
            return nil
        }
    }

    /// Keeps the newest whole lines that fit in `trimTarget` and are younger than `retention`.
    private func trim(now: Date) {
        try? handle?.close()
        handle = nil
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let oldest = Int64(((now.timeIntervalSince1970 - Self.retention) * 1000).rounded())
        var kept: [Data.SubSequence] = []
        var size = 0
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard size + line.count + 1 <= Self.trimTarget else { break }
            if let event = try? decoder.decode(JournalEvent.self, from: Data(line)), event.t < oldest { break }
            kept.append(line)
            size += line.count + 1
        }
        var out = Data(capacity: size)
        for line in kept.reversed() {
            out.append(contentsOf: line)
            out.append(UInt8(ascii: "\n"))
        }
        try? out.write(to: fileURL, options: .atomic)
        bytes = out.count
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }
}

/// Short, stable spellings for journal fields.
public enum JournalFormat {
    public static func seconds(_ value: Double) -> String { String(format: "%.1f", value) }
    public static func words(_ text: String) -> String {
        String(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
    }
    /// Domain and code, which say what failed; the localized message is left out on purpose.
    public static func error(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}
