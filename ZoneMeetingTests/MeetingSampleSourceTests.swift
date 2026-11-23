// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// FluidAudio's offline diarizer reads whole 10 s windows, past the end of the source in the last
/// one, and expects zeros there. A window over part of a meeting must not hand it the audio after.
final class MeetingSampleSourceTests: XCTestCase {
    func testWindowZeroFillsPastItsEndInsteadOfReadingTheAudioAfterIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcm")
        defer { try? FileManager.default.removeItem(at: url) }
        // One second at +0.5, then one second at -0.5.
        var data = Data()
        for index in 0..<32_000 {
            let value: Int16 = index < 16_000 ? 16_384 : -16_384
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        let source = MeetingSampleSource(audio: try MeetingAudio(urls: [url]), offset: 0, count: 16_000)
        XCTAssertEqual(source.sampleCount, 16_000)

        var buffer = [Float](repeating: 9, count: 4_000)
        try buffer.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 14_000, count: 4_000)
        }
        XCTAssertEqual(buffer[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(buffer[1_999], 0.5, accuracy: 0.001)
        XCTAssertEqual(buffer[2_000], 0)
        XCTAssertEqual(buffer[3_999], 0)

        // Entirely past the window: all zeros.
        try buffer.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: 20_000, count: 4_000)
        }
        XCTAssertEqual(buffer.max(), 0)
        XCTAssertEqual(buffer.min(), 0)
    }
}
