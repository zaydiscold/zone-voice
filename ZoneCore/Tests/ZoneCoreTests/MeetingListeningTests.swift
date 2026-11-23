// by zayd/cold @ zayd.wtf

import Foundation
import Testing
@testable import ZoneCore

@Suite struct MeetingSpeakerSamplesTests {
    private func segment(_ start: Double, _ end: Double, _ speaker: String?) -> MeetingSegment {
        MeetingSegment(start: start, end: end, speaker: speaker, text: "x")
    }

    @Test func picksThreeSpreadOverTheMeeting() {
        let segments = [
            segment(0, 3, "S1"), segment(3, 9, "S1"), segment(9, 10, "S2"),
            segment(20, 22, "S1"), segment(22, 30, "S1"),
            segment(40, 41, "S2"), segment(50, 60, "S1"), segment(60, 62, "S1"),
        ]
        let clips = MeetingSpeakerSamples.clips(for: "S1", in: segments)
        #expect(clips.count == 3)
        // One clip from each third, the longest there, never longer than 4 s.
        #expect(clips.map(\.lowerBound) == [3.2, 22.2, 50.2])
        #expect(clips.allSatisfy { $0.upperBound - $0.lowerBound <= 4.0001 })
        #expect(clips == clips.sorted { $0.lowerBound < $1.lowerBound })
    }

    @Test func fewerSegmentsGiveFewerClips() {
        let clips = MeetingSpeakerSamples.clips(for: "S2", in: [segment(0, 2, "S2"), segment(5, 6, "S1")])
        #expect(clips.count == 1)
        #expect(abs(clips[0].upperBound - 2) < 0.0001)
    }

    @Test func shortTurnsOnlyWhenNothingLonger() {
        let clips = MeetingSpeakerSamples.clips(for: "S1", in: [segment(0, 0.8, "S1"), segment(4, 4.6, "S1")])
        #expect(clips.count == 2)
        #expect(MeetingSpeakerSamples.clips(for: "S9", in: [segment(0, 4, "S1")]).isEmpty)
        #expect(MeetingSpeakerSamples.clips(for: "S1", in: [segment(3, 3, "S1")]).isEmpty)
    }
}

@Suite struct MeetingEstimateTests {
    @Test func usesTheLearnedRateWhenThereIsOne() {
        #expect(MeetingEstimate.seconds(forAudio: 600, rate: 0.25, labelsSpeakers: false) == 150)
        #expect(MeetingEstimate.seconds(forAudio: 600, rate: nil, labelsSpeakers: false) == 360)
        #expect(MeetingEstimate.seconds(forAudio: 600, rate: 0.25, labelsSpeakers: true) == 150 + 30 + 5)
    }

    @Test func labels() {
        #expect(MeetingEstimate.label(20) == "under a minute")
        #expect(MeetingEstimate.label(80) == "about a minute")
        #expect(MeetingEstimate.label(9 * 60) == "about 9 minutes")
        #expect(MeetingEstimate.label(62 * 60) == "about 1 hour")
        #expect(MeetingEstimate.label(130 * 60) == "about 2 hours 10 minutes")
    }

    @Test func rateBlendsAndIgnoresTinyClips() {
        #expect(MeetingEstimate.updatedRate(previous: nil, measuredSeconds: 30, audioSeconds: 60) == 0.5)
        #expect(MeetingEstimate.updatedRate(previous: 0.5, measuredSeconds: 3, audioSeconds: 5) == 0.5)
        let blended = MeetingEstimate.updatedRate(previous: 1.0, measuredSeconds: 30, audioSeconds: 60)!
        #expect(abs(blended - 0.7) < 0.0001)
        // One stalled run cannot push the estimate into hours.
        #expect(MeetingEstimate.updatedRate(previous: nil, measuredSeconds: 6_000, audioSeconds: 60) == 3)
    }
}

@Suite struct PCMWaveTests {
    @Test func headerAndSamples() {
        let data = PCMWave.data(samples: [0, 1, -1, 2, .nan])
        #expect(data.count == 44 + 10)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let values = stride(from: 44, to: data.count, by: 2).map { Int16(littleEndian: data[$0..<$0 + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }) }
        #expect(values == [0, Int16.max, -Int16.max, Int16.max, 0])
    }
}
