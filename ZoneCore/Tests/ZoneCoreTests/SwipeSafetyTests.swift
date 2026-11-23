// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SwipeSafetyTests: XCTestCase {
    func testPreferencesMigrateWithoutTurningSwipeOn() throws {
        let prefs = try JSONDecoder().decode(KeyboardPreferences.self, from: Data("{\"autocorrectEnabled\":false}".utf8))
        XCTAssertFalse(prefs.swipeTypingEnabled)
        XCTAssertFalse(prefs.autocorrectEnabled)
        XCTAssertTrue(prefs.swipeLearningEnabled)
        var enabled = prefs
        enabled.swipeTypingEnabled = true
        enabled.swipeLearningReset = "reset"
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(enabled)), enabled)
    }

    func testCommitNeverOwnsOtherFieldSelectionOrMovedCursor() {
        let c = SwipeCommit(session: "field1", before: "say", after: "!", leading: " ", word: "hello", previousWord: "say")
        XCTAssertTrue(c.owns(session: "field1", before: "say hello", after: "!", selection: nil))
        XCTAssertFalse(c.owns(session: "field2", before: "say hello", after: "!", selection: nil))
        XCTAssertFalse(c.owns(session: "field1", before: "say hello", after: "!", selection: "selected"))
        XCTAssertFalse(c.owns(session: "field1", before: "say hello", after: " world!", selection: nil))
        XCTAssertFalse(c.owns(session: "field1", before: "other hello", after: "!", selection: nil))
        XCTAssertFalse(c.owns(session: "field1", before: nil, after: "!", selection: nil))
        XCTAssertEqual(c.deleteCount, 6)
    }

    func testSpacing() {
        for before in ["hello", "done.", "done,", "42", "(done)"] { XCTAssertTrue(SwipeSpacing.needsLeadingSpace(before: before), before) }
        for before in ["", "hello ", "\n", "(", "email@", "https://a", "www.a", "#tag", "user@example.com"] {
            XCTAssertFalse(SwipeSpacing.needsLeadingSpace(before: before), before)
        }
        for text in ["word", "🙂", "(", "4"] { XCTAssertTrue(SwipeSpacing.paysPendingSpace(before: text), text) }
        for text in [" ", "\n", ".", ",", "!", "'", ")"] { XCTAssertFalse(SwipeSpacing.paysPendingSpace(before: text), text) }
    }

    func testPreviousWordStopsAtSentencesAndNonWords() {
        let cases: [(String?, String?)] = [
            ("i love ", "love"), ("i love", "love"), ("said, \"hey\" ", "hey"), ("well, ", "well"),
            ("don\u{2019}t ", "don't"), ("(maybe) ", "maybe"), ("I'm ", "I'm"),
            ("Done. ", nil), ("what? ", nil), ("note: ", nil), ("first line\n", nil), ("at 5 ", nil),
            ("see 🙂 ", nil), ("go to https://a.b ", nil), ("", nil), (nil, nil), ("   ", nil), ("café ", nil),
        ]
        for (before, expected) in cases { XCTAssertEqual(SwipeSpacing.previousWord(before: before), expected, before ?? "nil") }
    }

    func testGateDistinguishesTapRollAndSwipe() {
        let gate = SwipeGate()
        XCTAssertFalse(gate.isSwipe(travel: 0.3, duration: 0.1, sinceLastTap: nil))
        XCTAssertFalse(gate.isSwipe(travel: 0.8, duration: 0.1, sinceLastTap: 0.01))
        XCTAssertTrue(gate.isSwipe(travel: 1, duration: 0.2, sinceLastTap: nil))
        XCTAssertTrue(gate.isSwipe(travel: 4, duration: 2, sinceLastTap: 0.01))
        XCTAssertFalse(gate.isSwipe(travel: .nan, duration: 0, sinceLastTap: nil))
    }

    func testExplicitLearningChangesAmbiguousRankAndResetRemovesIt() throws {
        let words = try XCTUnwrap(WordList.loadBundled())
        let decoder = SwipeDecoder(words: words)
        let layout = SwipeLayout.qwerty()
        let points = [19, 14].enumerated().map { SwipePoint(x: layout.x[$0.element], y: layout.y[$0.element], t: Float($0.offset) * 0.2) }
        let base = decoder.decode(points, layout: layout, limit: 20)
        let candidate = try XCTUnwrap(base.first { $0.word.lowercased() == "too" })
        var learning = SwipeLearning()
        for _ in 0..<100 { learning.chose("too", after: "me") }
        let learned = decoder.decode(points, layout: layout, context: SwipeContext(previousWord: "me", learning: learning), limit: 20)
        XCTAssertLessThan(try XCTUnwrap(learned.first { $0.word == candidate.word }).score, candidate.score)
        XCTAssertEqual(learning.choices(of: "too"), 100)
        let restored = try JSONDecoder().decode(SwipeLearning.self, from: JSONEncoder().encode(learning))
        XCTAssertEqual(restored, learning)
        XCTAssertEqual(decoder.decode(points, layout: layout, context: SwipeContext(learning: SwipeLearning()), limit: 20), base)
    }

    func testLongTraceDoesNotDropWordAndInvalidTraceIsSafe() throws {
        let decoder = SwipeDecoder(words: try XCTUnwrap(WordList.loadBundled()))
        let l = SwipeLayout.qwerty()
        let word = "relationships"
        let keys = word.utf8.map { Int($0 - 97) }
        var points: [SwipePoint] = []
        for i in 0..<keys.count - 1 {
            for j in 0..<100 {
                let a = Float(j) / 100, k = keys[i], n = keys[i + 1]
                points.append(SwipePoint(x: l.x[k] + a * (l.x[n] - l.x[k]), y: l.y[k] + a * (l.y[n] - l.y[k]), t: Float(points.count) / 120))
            }
        }
        XCTAssertGreaterThan(points.count, 512)
        XCTAssertTrue(decoder.decode(points, layout: l, limit: 10).contains { $0.word.lowercased() == word })
        XCTAssertTrue(decoder.decode([SwipePoint(x: .nan, y: 0), SwipePoint(x: 1, y: 1)], layout: l).isEmpty)
    }

    func testFutoInferenceMatchesIndependentReference() throws {
        let modelURL = try XCTUnwrap(Bundle.module.url(forResource: "futo-swipe-fixture", withExtension: "txt"))
        let fixture = try String(contentsOf: modelURL, encoding: .utf8)
        // Production weights load through the package containing the model.
        XCTAssertNotNil(SwipeNeuralScorer())
        let weightURL = try XCTUnwrap(Bundle.zoneSwipeResources.url(forResource: "futoswipe", withExtension: "bin"))
        let model = try XCTUnwrap(FutoSwipeModel.load(try Data(contentsOf: weightURL)))
        var keys: [Float] = [], feats: [Float] = []
        var cases = 0
        for line in fixture.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            func floats() -> [Float] { parts[1].split(separator: ",").compactMap { Float($0) } }
            if parts[0] == "keys" { keys = floats() }
            if parts[0] == "feats" { feats = floats() }
            if parts[0] == "logem" {
                let expected = floats()
                var output = [Float](repeating: 0, count: expected.count)
                model.run(feats, keys, keys.count / 2, &output)
                // Upstream uses absolute 1e-2 plus relative 1e-3 tolerance for Accelerate vs scalar Python.
                for (reference, actual) in zip(expected, output) {
                    XCTAssertEqual(actual, reference, accuracy: 0.01 + 0.001 * abs(reference))
                }
                cases += 1
            }
        }
        XCTAssertGreaterThan(cases, 0)
    }
}
