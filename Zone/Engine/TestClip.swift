// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation

/// The bundled 16 kHz mono clip used by Diagnostics to prove the engine works offline.
enum TestClip {
    static let expectedPhrases = ["three thirty", "not four", "twelve point five"]
    /// The script the clip was synthesized from:
    /// `say -v Samantha -o clip.aiff "<transcript>"`, then `afconvert -f WAVE -d LEI16@16000 -c 1`.
    static let transcript = "Testing Zone. The meeting is at three thirty, not four. Call Priya about the twelve point five percent raise."

    static func samples() throws -> [Float] {
        guard let url = Bundle.main.url(forResource: "test-clip", withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try samples(from: url)
    }

    /// Reads any 16 kHz mono WAV as Float32 samples.
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
