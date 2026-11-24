import Darwin
import Foundation

public enum KeyboardAudioAttempts {
    private static let key = "wtf.zayd.zone.audio-attempts"

    /// Called only on the locked, newly created file. A keyboard killed during capture
    /// has made zero speech model attempts. Unstamped files from older builds stay unknown.
    static func initializeNewFile(_ wav: URL) throws {
        try write(AudioAttempts(count: 0, earlierUnknown: false), to: wav)
    }

    public static func begin(on wav: URL, retry: Bool, now: Date = Date()) throws {
        var tries = try read(from: wav) ?? AudioAttempts(count: 0, earlierUnknown: retry)
        tries.count += 1
        tries.lastTry = now
        tries.outcome = .interrupted
        try write(tries, to: wav)
    }

    public static func finish(on wav: URL, outcome: AudioAttempts.Outcome) throws {
        guard var tries = try read(from: wav) else { throw CocoaError(.fileReadCorruptFile) }
        tries.outcome = outcome
        try write(tries, to: wav)
    }

    public static func read(from wav: URL) throws -> AudioAttempts? {
        var data = Data(count: 1024)
        let size = data.withUnsafeMutableBytes { getxattr(wav.path, key, $0.baseAddress, $0.count, 0, 0) }
        if size < 0, errno == ENOATTR { return nil }
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try JSONDecoder().decode(AudioAttempts.self, from: data.prefix(size))
    }

    private static func write(_ tries: AudioAttempts, to wav: URL) throws {
        let data = try JSONEncoder().encode(tries)
        let result = data.withUnsafeBytes { setxattr(wav.path, key, $0.baseAddress, $0.count, 0, 0) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

/// One recognition pass can try several providers. Only submitting audio starts a try.
public final class KeyboardRecognitionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let wav: URL
    private let retry: Bool
    private var submitted = false
    private var closed = false

    public init(wav: URL, retry: Bool) {
        self.wav = wav
        self.retry = retry
    }

    public func submit() throws {
        try lock.withLock {
            guard !submitted, !closed, !Task.isCancelled else { return }
            try KeyboardAudioAttempts.begin(on: wav, retry: retry)
            submitted = true
        }
    }

    public func finish(_ outcome: AudioAttempts.Outcome) throws {
        try lock.withLock {
            guard !closed else { return }
            closed = true
            if submitted { try KeyboardAudioAttempts.finish(on: wav, outcome: outcome) }
        }
    }
}
