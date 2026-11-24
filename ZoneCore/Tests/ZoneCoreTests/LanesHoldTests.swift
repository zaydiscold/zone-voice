// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

final class LanesHoldTests: XCTestCase {
    // A wide score keeps every note around until we inspect it.
    private func score(_ segments: [(Float, Double)], hz: Int) -> [LanesPainter.Note] {
        let painter = LanesPainter()
        var tracker = VoiceTracker()
        for (level, duration) in segments {
            for _ in 0..<Int((duration * Double(hz)).rounded()) {
                painter.step(tracker.step(level: level, dt: 1 / Float(hz)),
                             dt: 1 / CGFloat(hz), size: CGSize(width: 2000, height: 40))
            }
        }
        return painter.notes
    }

    func testSteadyVowelGetsOneLongSustain() throws {
        for hz in [60, 120] {
            for level: Float in [0.035, 0.4] {
                let tone: [(Float, Double)] = [(0.005, 0.5), (level, 5)]
                let open = score([(0.005, 0.5), (level, 3)], hz: hz)
                XCTAssertEqual(open.count, 1)
                XCTAssertNil(open.first?.end)
                let released = score(tone + [(0.005, 0.3)], hz: hz)
                XCTAssertEqual(released.count, 1)
                let note = try XCTUnwrap(released.first)
                let duration = try XCTUnwrap(note.end) - note.start
                XCTAssertTrue((4.3...4.8).contains(duration), "held for \(duration) s at level \(level), \(hz) Hz")
                print("Flat vowel, level \(level), \(hz) Hz: \(duration) s")
            }
        }
    }

    func testAHeldVowelWithGentleModulationCanKeepItsTail() throws {
        let room: [(Float, Double)] = [(0.005, 0.5)]
        let vowel: [(Float, Double)] = (0..<100).map { post in
            (0.14 + 0.023 * sin(2 * Float.pi * 4 * Float(post) / 20), 0.05)
        }
        for hz in [60, 120] {
            let held = score(room + vowel, hz: hz)
            XCTAssertEqual(held.count, 1)
            XCTAssertNil(try XCTUnwrap(held.first).end)
            let released = score(room + vowel + room, hz: hz)
            let note = try XCTUnwrap(released.first)
            let duration = try XCTUnwrap(note.end) - note.start
            XCTAssertEqual(duration, 5, accuracy: 0.15)
            print("Modulated vowel, \(hz) Hz: \(duration) s")
        }
    }

    func testFanStartsMidRecordingThenSpeechRisesAboveIt() throws {
        var scale = AdaptiveLevelScale()
        func mapped(_ db: Float) -> Float { scale.map(decibels: db, elapsed: 0.05) }
        let room: [(Float, Double)] = [(mapped(-48), 1)]
        // A small level ripple makes the fan more demanding than a constant test value.
        let fan: [(Float, Double)] = (0..<200).map { post in
            (mapped(-35 + 1.2 * sin(Float(post) * 0.8)), 0.05)
        }
        // Independent sources add in power. Each syllable sits on top of the same running fan.
        let fanPower = pow(Float(10), -3.5)
        let speech: [(Float, Double)] = [-33, -28, -30, -26].flatMap { (db: Float) in
            [(mapped(10 * log10(fanPower + pow(10, db / 10))), 0.2), (mapped(-35), 0.25)]
        }
        for hz in [60, 120] {
            let notes = score(room + fan + speech, hz: hz)
            let fanNotes = notes.filter { $0.start < 11 }
            XCTAssertEqual(fanNotes.count, 1)
            let end = try XCTUnwrap(fanNotes.first?.end)
            XCTAssertTrue((3...5).contains(end - 1), "fan ended after \(end - 1) s at \(hz) Hz")
            let starts = notes.filter { $0.start >= 11 }.map(\.start)
            XCTAssertEqual(starts.count, 4)
            for (index, start) in starts.enumerated() {
                let expected = 11 + Double(index) * 0.45
                XCTAssertTrue((expected..<(expected + 0.2)).contains(start), "missing syllable at \(expected) s")
            }
            print("Fan, \(hz) Hz: released after \(end - 1) s; \(starts.count) speech starts")
        }
    }

    func testUnevenFanRippleCanSpendWholePostsAtItsExtremes() throws {
        var scale = AdaptiveLevelScale()
        let ripple: [Float] = [1.2, 1.2, -1.1, -1.2, 0.8, -1.2, 1.2]
        let fan: [(Float, Double)] = (0..<200).map { post in
            (scale.map(decibels: -35 + ripple[post % ripple.count], elapsed: 0.05), 0.05)
        }
        for hz in [60, 120] {
            let notes = score([(0.005, 1)] + fan, hz: hz)
            XCTAssertEqual(notes.count, 1)
            XCTAssertEqual((try XCTUnwrap(notes.last?.end)) - 1, 4.5, accuracy: 0.3)
        }
    }

    func testTremoloAfterSpeechIsOneNote() throws {
        var phrase: [(Float, Double)] = [(0.005, 0.4)]
        for level: Float in [0.3, 0.12, 0.2, 0.4, 0.15, 0.25, 0.1, 0.35] {
            phrase += [(level, 0.2), (0.03, 0.1)]
        }
        phrase.append((0.005, 0.5))
        for post in 0..<100 {
            phrase.append((0.14 + 0.023 * sin(2 * Float.pi * 4 * Float(post) / 20), 0.05))
        }
        for hz in [60, 120] {
            let tail = score(phrase + [(0.005, 0.5)], hz: hz).filter { $0.start >= 3.3 }
            XCTAssertEqual(tail.count, 1)
            let note = try XCTUnwrap(tail.first)
            XCTAssertGreaterThan(try XCTUnwrap(note.end) - note.start, 4.3)
        }
    }

    func testRumbleAndBrownNoiseReleaseAndStayQuiet() throws {
        for brown in [false, true] {
            // Filter seeded white noise at 16 kHz. A leaky integrator limits brown
            // noise below 40 Hz. The fan rolls off at 300 Hz with broadband hiss.
            var random = ArtRandom(seed: 7)
            var low = 0.0
            let pole = exp(-2 * Double.pi * (brown ? 40 : 300) / 16000)
            var posts: [Double] = []
            var power = 0.0
            for _ in 0..<600 {
                var peak = 0.0
                for _ in 0..<5 {
                    var sum = 0.0
                    for _ in 0..<160 {
                        let white = 2 * Double(random.unit()) - 1
                        low = pole * low + (1 - pole) * white
                        let sample = brown ? low : low + 0.05 * white
                        sum += sample * sample
                    }
                    power += sum
                    peak = max(peak, sum / 160)
                }
                posts.append(peak)
            }
            var scale = AdaptiveLevelScale()
            let mean = power / Double(posts.count * 800)
            let noise = posts.map { (scale.map(decibels: -35 + Float(10 * log10($0 / mean)), elapsed: 0.05), 0.05) }
            for hz in [60, 120] {
                let notes = score([(0, 1)] + noise, hz: hz)
                let end = try XCTUnwrap(notes.last?.end)
                XCTAssertEqual(end - 1, 5, accuracy: 0.75, "brown=\(brown), \(hz) Hz")
            }
        }
    }

    func testLearningTheFanDoesNotWalkItsNoteDownTheLanes() throws {
        for hz in [60, 120] {
            let notes = score([(0.005, 0.5), (0.25, 0.3), (0.005, 0.5), (0.12, 10)], hz: hz)
            XCTAssertEqual(notes.count, 2)
            let fan = try XCTUnwrap(notes.last)
            XCTAssertTrue((1...2).contains(fan.lane))
            let duration = try XCTUnwrap(fan.end) - fan.start
            XCTAssertTrue((3...5).contains(duration), "fan held for \(duration) s after the loud phrase")
        }
    }

    func testOngoingSyllableModulationDoesNotBecomeRoomNoise() {
        for hz in [60, 120] {
            for rate: Double in [3, 8] {
                var tracker = VoiceTracker()
                for post in 0..<200 {
                    let level = Float(0.14 + 0.04 * sin(2 * Double.pi * rate * Double(post) / 20))
                    for _ in 0..<(hz / 20) {
                        let voice = tracker.step(level: level, dt: 1 / Float(hz))
                        if post > 1 { XCTAssertEqual(voice.quiet, 0) }
                    }
                }
            }
        }
    }

    func testQuietAndNormalSyllablesUseTheRange() {
        for hz in [60, 120] {
            for gain: Float in [1, 3] {
                var syllables: [(Float, Double)] = [(0.005, 0.4)]
                for stress: Float in [0.1, 0.03, 0.05, 0.075, 0.095, 0.035] {
                    syllables += [(stress * gain, 0.25), (0.005, 0.25)]
                }
                let notes = score(syllables, hz: hz)
                XCTAssertEqual(notes.count, 6)
                XCTAssertGreaterThanOrEqual(Set(notes.map(\.lane)).count, 3)
            }
        }
    }

    /// A car's microphone (CarPlay, 2026-11-22): road noise near -38 dB and a voice the car has
    /// already levelled into a band about 7 dB wide. "Not getting the full range", and the green
    /// lane at the bottom never lit. Every lane, the bottom one too, has to get its share.
    func testACarMicrophonesNarrowVoiceStillPlaysEveryLane() {
        var scale = AdaptiveLevelScale()
        func mapped(_ db: Float) -> Float { scale.map(decibels: db, elapsed: 0.05) }
        // Fixed stresses, so the run repeats: syllable peaks between -31 and -24 dB.
        let stresses: [Float] = [0.9, 0.2, 0.6, 0.05, 1.0, 0.4, 0.75, 0.1, 0.5, 0.3, 0.85, 0.0, 0.65, 0.25, 0.95, 0.45]
        var segments: [(Float, Double)] = (0..<20).map { post in (mapped(-38 + 0.8 * sin(Float(post) * 0.9)), 0.05) }
        for phrase in 0..<8 {
            for syllable in 0..<10 {
                let peak = -31 + 7 * stresses[(phrase * 7 + syllable * 3) % stresses.count]
                segments += [(mapped(peak - 2), 0.05), (mapped(peak), 0.1), (mapped(peak - 3), 0.05), (mapped(-37), 0.05)]
            }
            segments += (0..<10).map { post in (mapped(-38 + 0.8 * sin(Float(post) * 0.9)), 0.05) }
        }
        for hz in [60, 120] {
            let notes = score(segments, hz: hz).filter { $0.start > 3 }
            let shares = (0..<4).map { lane in Double(notes.filter { $0.lane == lane }.count) / Double(max(1, notes.count)) }
            print("Car microphone, \(hz) Hz: \(notes.count) notes, lane shares \(shares.map { String(format: "%.2f", $0) })")
            XCTAssertGreaterThan(notes.count, 30, "a voice over road noise must still play notes")
            for lane in 0..<4 {
                XCTAssertGreaterThanOrEqual(shares[lane], 0.1, "lane \(lane) got \(shares[lane]) of the notes at \(hz) Hz")
            }
        }
    }

    func testShortPauseReplacesAnOldLoudPeak() {
        let phrases: [(Float, Double)] = [(0.005, 0.5), (0.35, 0.3), (0.005, 0.5),
                                          (0.07, 0.3), (0.005, 0.5), (0.07, 0.3)]
        for hz in [60, 120] {
            let lanes = score(phrases, hz: hz).map(\.lane)
            XCTAssertEqual(lanes.count, 3)
            guard lanes.count == 3 else { continue }
            XCTAssertLessThan(lanes[1], lanes[0])
            XCTAssertGreaterThan(lanes[2], lanes[1])
        }
    }

    func testBoundaryFlutterIsIgnoredAndARealMoveSplitsTheHold() {
        for hz in [60, 120] {
            // Establish a phrase peak, then hover on the boundary between the two middle lanes.
            let start: [(Float, Double)] = [(0.005, 0.5), (0.1, 0.3), (0.005, 0.2), (0.05, 0.4)]
            let flutter: [(Float, Double)] = [(0.060, 0.05), (0.042, 0.05)]
            let middle = start + Array(repeating: flutter, count: 8).flatMap { $0 }
            let notes = score(middle, hz: hz)
            XCTAssertEqual(notes.count, 2)
            // From 0.05, 0.03 is only 2.02 dB away. 0.024 crosses the 2.5 dB move threshold.
            XCTAssertEqual(score(middle + [(0.03, 0.5)], hz: hz).count, 2)
            let moved = score(middle + [(0.024, 0.5)], hz: hz)
            XCTAssertEqual(moved.count, 3)
            if let last = moved.last, let previous = notes.last { XCTAssertLessThan(last.lane, previous.lane) }
        }
    }

    func testQuietAttacksReachPaintersThatListenForOnsets() {
        for hz in [60, 120] {
            var tracker = VoiceTracker()
            var attacks = 0
            for _ in 0..<5 {
                for _ in 0..<(hz / 2) {
                    XCTAssertEqual(tracker.step(level: 0.006, dt: 1 / Float(hz)).onset, 0)
                }
                for _ in 0..<(hz / 4) {
                    if tracker.step(level: 0.04, dt: 1 / Float(hz)).onset > 0 { attacks += 1 }
                }
            }
            XCTAssertEqual(attacks, 5)
        }
    }

    func testVowelEndsWhenOnlyRoomNoiseRemains() throws {
        var scale = AdaptiveLevelScale()
        let room = scale.map(decibels: -47, elapsed: 0.05)
        for hz in [60, 120] {
            let notes = score([(0, 1), (0.1, 1), (room, 3)], hz: hz)
            XCTAssertEqual(notes.count, 1)
            let end = try XCTUnwrap(notes.first?.end)
            XCTAssertEqual(end, 2, accuracy: 0.13)
        }
    }

    func testRoomNoiseNeverStartsANote() {
        var scale = AdaptiveLevelScale()
        let noise = (-46 ... -44).map { (scale.map(decibels: Float($0), elapsed: 0.05), 0.05) }
        for hz in [60, 120] {
            XCTAssertTrue(score(Array(repeating: noise, count: 50).flatMap { $0 }, hz: hz).isEmpty)
        }
    }

    func testBriefQuietWordAfterSilenceKeepsItsAttack() {
        for hz in [60, 120] {
            let notes = score([(0.002, 1), (0.025, 0.1), (0.002, 1)], hz: hz)
            XCTAssertEqual(notes.count, 1)
        }
    }

    func testRoomRippleSettlesAfterStartingFromSilence() {
        var scale = AdaptiveLevelScale()
        let room: [(Float, Double)] = (0..<400).map { post in
            let db = -45 + sin(Float(post) * 0.13)
            return (scale.map(decibels: db, elapsed: 0.05), 0.05)
        }
        for hz in [60, 120] {
            let notes = score([(0, 1)] + room, hz: hz)
            XCTAssertTrue(notes.allSatisfy { ($0.end ?? .infinity) < 6.1 })
        }
    }

    func testExcursionAcrossTwoOtherLanesSwitchesAfterDwell() throws {
        for hz in [60, 120] {
            for descending in [false, true] {
                let painter = LanesPainter()
                for tick in 0..<(hz / 2) {
                    var voice = VoiceSignal()
                    let hover: Float = ((tick - 1) / (hz / 20)).isMultiple(of: 2) ? 0.72 : 0.78
                    let contour: Float = tick == 0 ? 0.08 : hover
                    voice.contour = descending ? 1 - contour : contour
                    voice.decibels = -48 + 40 * voice.contour
                    painter.step(voice, dt: 1 / CGFloat(hz), size: CGSize(width: 300, height: 48))
                    if tick < Int(ceil(Double(hz) * 0.1)) { XCTAssertEqual(painter.notes.count, 1) }
                }
                XCTAssertEqual(painter.notes.map(\.lane), descending ? [3, 0] : [0, 3])
                let moved = try XCTUnwrap(painter.notes.dropFirst().first)
                XCTAssertEqual(moved.start - 1 / CGFloat(hz), 0.1, accuracy: 1 / CGFloat(hz))
            }
        }
    }

    func testSameLaneRestrikeSeparatesRoundedCaps() throws {
        for hz in [60, 120] {
            let painter = LanesPainter()
            for tick in 0...hz {
                var voice = VoiceSignal()
                voice.contour = 0.9
                voice.onset = tick.isMultiple(of: hz / 2) ? 1 : 0
                painter.step(voice, dt: 1 / CGFloat(hz), size: CGSize(width: 300, height: 48))
            }
            XCTAssertEqual(painter.notes.count, 3)
            for (a, b) in zip(painter.notes, painter.notes.dropFirst()) {
                // At maximum strength each pill is 0.17 strip heights thick.
                XCTAssertGreaterThan((b.start - (try XCTUnwrap(a.end))) * 1.5 - 0.17, 0.02)
            }
        }
    }

    func testSpeechImmediatelyAfterLongVowel() {
        for hz in [60, 120] {
            var tracker = VoiceTracker()
            for _ in 0..<Int(4.4 * Double(hz)) { _ = tracker.step(level: 0.4, dt: 1 / Float(hz)) }
            var attacks = 0
            for tick in 0..<(hz * 2) {
                let level: Float = tick % (hz / 2) < hz / 4 ? 0.11 : 0.22
                let signal = tracker.step(level: level, dt: 1 / Float(hz))
                XCTAssertEqual(signal.quiet, 0)
                if signal.onset > 0 { attacks += 1 }
            }
            XCTAssertGreaterThanOrEqual(attacks, 3)
        }
    }

    func testRejectedClicksLeaveContourAlone() {
        for hz in [60, 120] {
            var tracker = VoiceTracker()
            for _ in 0..<hz { _ = tracker.step(level: 0.005, dt: 1 / Float(hz)) }
            let silent = tracker
            XCTAssertGreaterThan(tracker.step(level: 0.95, dt: 1 / Float(hz)).quiet, 0)
            var control = silent
            for level: Float in [0.005, 0.04, 0.04, 0.04, 0.04] {
                XCTAssertEqual(tracker.step(level: level, dt: 1 / Float(hz)).contour,
                               control.step(level: level, dt: 1 / Float(hz)).contour, accuracy: 0.01)
            }
        }
    }

    func testContinuousSyllablesStayVoicedAfterALoudOpening() {
        for hz in [60, 120] {
            var tracker = VoiceTracker()
            for _ in 0..<hz { _ = tracker.step(level: 0.95, dt: 1 / Float(hz)) }
            var attacks = 0
            for tick in 0..<(10 * hz) {
                let level: Float = tick % (hz / 2) < hz / 4 ? 0.04 : 0.12
                let signal = tracker.step(level: level, dt: 1 / Float(hz))
                XCTAssertEqual(signal.quiet, 0)
                if tick >= 8 * hz && signal.onset > 0 { attacks += 1 }
            }
            XCTAssertGreaterThanOrEqual(attacks, 3)
        }
    }

    func testMidPhrasePopRecoversWithinOneSecond() {
        for hz in [60, 120] {
            var tracker = VoiceTracker()
            for _ in 0..<(hz / 2) { _ = tracker.step(level: 0.005, dt: 1 / Float(hz)) }
            func syllable() -> Float {
                var peak: Float = 0
                for tick in 0..<(hz / 4) {
                    let loud = tick < 3 * hz / 20
                    let signal = tracker.step(level: loud ? 0.12 : 0.04, dt: 1 / Float(hz))
                    if loud { peak = max(peak, signal.contour) }
                }
                return peak
            }
            for _ in 0..<8 { _ = syllable() }
            for _ in 0..<(hz / 20) { _ = tracker.step(level: 0.95, dt: 1 / Float(hz)) }
            // Start timing at the end of the pop. Require a new syllable after a trough.
            _ = syllable()
            let recovery = (1..<4).first { _ in syllable() >= 0.5 }
            XCTAssertNotNil(recovery, "No accented syllable reached the upper half within one second")
        }
    }

    private func marks(_ engine: VoiceArtEngine) -> Int {
        switch engine.painter {
        case let p as InkPainter: return p.pointCount
        case let p as GlyphPainter: return p.glyphCount
        case let p as BranchPainter: return p.twigCount
        case let p as InkblotPainter: return p.dropCount
        case let p as LanesPainter: return p.notes.count
        case let p as StarsPainter: return p.starCount
        default:
            XCTFail("Missing painter observation")
            return 0
        }
    }

    private func feed(_ engine: VoiceArtEngine, _ level: Float, _ duration: Double, hz: Int, width: CGFloat = 3000) {
        engine.feed(level: level)
        for _ in 0..<Int((duration * Double(hz)).rounded()) {
            engine.advance(by: 1 / Double(hz), size: CGSize(width: width, height: 48))
        }
    }

    func testEngineActuallyStepsAt120Hz() throws {
        let engine = try XCTUnwrap(VoiceArtEngine(style: .lanes, seed: 1, tick: 1.0 / 120))
        feed(engine, 0.4, 3.0 / 120, hz: 120)
        let notes = try XCTUnwrap((engine.painter as? LanesPainter)?.notes)
        XCTAssertEqual(try XCTUnwrap(notes.first).start, 3.0 / 120, accuracy: 0.000001)
    }

    func testAllPaintersWriteQuietPhrasesBeforeAndAfterALoudWord() throws {
        for hz in [60, 120] {
            for style in VoiceArtTests.drawn {
                for pause in [0.5, 10.0] {
                    let engine = try XCTUnwrap(VoiceArtEngine(style: style, seed: 7, tick: 1 / Double(hz)))
                    func phrase() {
                        for _ in 0..<6 {
                            feed(engine, 0.04, 0.2, hz: hz)
                            feed(engine, 0.005, 0.2, hz: hz)
                        }
                    }
                    feed(engine, 0.005, 0.5, hz: hz)
                    phrase()
                    XCTAssertGreaterThanOrEqual(marks(engine), 4, style.rawValue)
                    feed(engine, 0.95, 0.3, hz: hz)
                    feed(engine, 0.005, pause, hz: hz)
                    let before = marks(engine)
                    phrase()
                    // Let drops from before the quiet phrase finish drying.
                    if style == .inkblot { feed(engine, 0.005, 0.85, hz: hz) }
                    let added = marks(engine) - (style == .inkblot ? 0 : before)
                    XCTAssertGreaterThanOrEqual(added, 4, "\(style) after \(pause)s")
                    if let lanes = engine.painter as? LanesPainter {
                        XCTAssertGreaterThan(lanes.notes.suffix(6).map(\.lane).max() ?? 0, 0)
                    }
                }
            }
        }
    }

    func testAllPaintersStopMarkingLearnedFansThenHearSpeechAboveThem() throws {
        for hz in [60, 120] {
            for style in VoiceArtTests.drawn {
                for fan: Float in [0.25, 0.75] {
                    let engine = try XCTUnwrap(VoiceArtEngine(style: style, seed: 1, tick: 1 / Double(hz)))
                    var scale = AdaptiveLevelScale()
                    let center = -50 + 48 * pow(fan, 1 / AdaptiveLevelScale.curve)
                    func fanPosts(_ range: Range<Int>) {
                        for post in range {
                            let level = scale.map(decibels: center + 1.2 * sin(Float(post) * 0.8), elapsed: 0.05)
                            feed(engine, level, 0.05, hz: hz)
                        }
                    }
                    feed(engine, 0.005, 1, hz: hz)
                    fanPosts(0..<180)
                    let settled = marks(engine)
                    fanPosts(180..<240)
                    XCTAssertEqual(marks(engine), settled, "\(style) marked a learned fan at \(fan)")
                    if style == .inkblot { XCTAssertEqual(settled, 0) }
                    feed(engine, 1, 0.25, hz: hz)
                    XCTAssertGreaterThan(marks(engine), settled, "\(style) missed speech over \(fan)")
                }
            }
        }
    }

    func testFullScaleReachesTheTopLaneOverALearnedFan() {
        for hz in [60, 120] {
            var tracker = VoiceTracker()
            for _ in 0..<(10 * hz) { _ = tracker.step(level: 0.75, dt: 1 / Float(hz)) }
            XCTAssertGreaterThan(tracker.signal.quiet, 4)
            for _ in 0..<(hz / 5) { _ = tracker.step(level: 1, dt: 1 / Float(hz)) }
            XCTAssertEqual(tracker.signal.quiet, 0)
            XCTAssertGreaterThanOrEqual(tracker.signal.contour, 0.75)
        }
    }

    func testQuietStarsScrollAndPruneOverTenMinutes() throws {
        let engine = try XCTUnwrap(VoiceArtEngine(style: .stars, seed: 7))
        for _ in 0..<1500 {
            feed(engine, 0.04, 0.2, hz: 60, width: 240)
            feed(engine, 0.005, 0.2, hz: 60, width: 240)
        }
        XCTAssertTrue((4..<100).contains(marks(engine)), "Retained \(marks(engine)) stars")
    }
}
