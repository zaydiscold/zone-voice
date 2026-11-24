// by zayd/cold @ zayd.wtf

import AVFAudio
import Darwin
import OSLog
import Foundation

/// The open file is also the ownership lock. The app can import it after a process
/// dies, but cannot take it from a live writer, a retry, or a pending text save.
public final class KeyboardAudioFile {
    public static var inbox: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("Library/Application Support/KeyboardAudio", isDirectory: true)
    }
    public static func sealForHandoff(_ source: URL, id: UUID) throws -> URL {
        let sealed = source.deletingLastPathComponent().appendingPathComponent(KeyboardCapture.handoffName(id))
        if source == sealed { return sealed }
        guard renamex_np(source.path, sealed.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return sealed
    }

    public let url: URL
    let handle: FileHandle
    private let rate: UInt32
    private var payload: UInt32 = 0
    private var checkpoint: UInt32 = 0
    public private(set) var writeFailed = false

    public init(url: URL, sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { throw CocoaError(.featureUnsupported) }
        rate = UInt32(sampleRate.rounded())
        self.url = url
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var header = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ n: T) {
            withUnsafeBytes(of: n.littleEndian) { header.append(contentsOf: $0) }
        }
        append(UInt32(36))
        header.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: "data".utf8)
        append(UInt32(0))
        try handle.write(contentsOf: header)
        do { try KeyboardAudioAttempts.initializeNewFile(url) }
        catch {
            Logger(subsystem: "wtf.zayd.zone", category: "AudioRecovery").error("Could not initialize keyboard attempt history: \((error as NSError).code, privacy: .public)")
        }
        try handle.synchronize()
    }

    public func append(_ data: Data) {
        guard !writeFailed, !data.isEmpty else { return }
        do {
            guard data.count.isMultiple(of: 2), data.count <= UInt32.max - 36 - payload else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let second = rate * 2
            var offset = data.startIndex
            while offset < data.endIndex {
                let available = Int(second - (payload - checkpoint))
                let end = offset + min(available, data.endIndex - offset)
                try handle.write(contentsOf: data[offset..<end])
                payload += UInt32(end - offset)
                offset = end
                if payload - checkpoint == second {
                    try Self.setLengths(handle, dataStart: 44, bytes: payload)
                    try handle.synchronize()
                    checkpoint = payload
                }
            }
        } catch { writeFailed = true }
    }

    public var recordedSeconds: Double { Double(payload / 2) / Double(rate) }

    public func finish() -> Double {
        do {
            try Self.setLengths(handle, dataStart: 44, bytes: payload)
            try handle.synchronize()
        } catch { writeFailed = true }
        return recordedSeconds
    }

    /// Repair only a mono 16-bit WAV. Walk the chunks because older writers added
    /// padding before data. Round down a final incomplete sample left by a kill.
    public static func repair(_ handle: FileHandle) throws {
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: Int(min(length, 65_536))) ?? Data()
        guard prefix.count >= 44, prefix.prefix(4) == Data("RIFF".utf8),
              prefix[8..<12] == Data("WAVE".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        var start = 12, pcm = false
        while start + 8 <= prefix.count {
            let tag = prefix[start..<(start + 4)]
            let n = (0..<4).reduce(0) { $0 | Int(prefix[start + 4 + $1]) << (8 * $1) }
            let offset = start + 8
            if tag == Data("fmt ".utf8), n >= 16, offset + 16 <= prefix.count {
                pcm = prefix[offset] == 1 && prefix[offset + 1] == 0 && prefix[offset + 2] == 1 &&
                    prefix[offset + 3] == 0 && prefix[offset + 14] == 16
            }
            if tag == Data("data".utf8), pcm {
                let count = (length - UInt64(offset)) & ~1
                guard count <= UInt32.max - UInt32(offset) else { throw CocoaError(.fileReadTooLarge) }
                try handle.truncate(atOffset: UInt64(offset) + count)
                try setLengths(handle, dataStart: UInt64(offset), bytes: UInt32(count))
                try handle.synchronize()
                return
            }
            start = offset + n + n % 2
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func prepareToRead(_ url: URL, handle: FileHandle) throws {
        do { try repair(handle) }
        catch {
            // Earlier versions used Apple's WAV writer, including other valid format chunks.
            // An unreadable original stays in the inbox for another recovery attempt.
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { throw error }
        }
    }

    private static func setLengths(_ handle: FileHandle, dataStart: UInt64, bytes: UInt32) throws {
        for (position, size) in [(UInt64(4), UInt32(dataStart - 8) + bytes), (dataStart - 4, bytes)] {
            try handle.seek(toOffset: position)
            try withUnsafeBytes(of: size.littleEndian) { try handle.write(contentsOf: Data($0)) }
        }
        try handle.seek(toOffset: dataStart + UInt64(bytes))
    }

    public static func lock(_ url: URL) -> FileHandle? {
        let fd = open(url.path, O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    /// Convert already recorded audio in bounded buffers into the app's mono 16 kHz PCM.
    static func convert(_ source: URL, to output: FileHandle) throws {
        let input = try AVAudioFile(forReading: source)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw CocoaError(.fileReadCorruptFile) }
        while true {
            var failure: NSError?
            var readError: Error?
            let status = converter.convert(to: buffer, error: &failure) { count, state in
                guard input.framePosition < input.length,
                      let block = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else {
                    state.pointee = .endOfStream
                    return nil
                }
                do { try input.read(into: block) } catch { readError = error }
                state.pointee = block.frameLength > 0 ? .haveData : .endOfStream
                return block.frameLength > 0 ? block : nil
            }
            if let readError { throw readError }
            if let failure { throw failure }
            guard status != .error else { throw CocoaError(.fileReadCorruptFile) }
            if buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] {
                try output.write(contentsOf: Data(bytes: samples, count: Int(buffer.frameLength) * 2))
            }
            if status == .endOfStream { break }
        }
        try output.synchronize()
    }
}
