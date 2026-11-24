// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

/// Scores the swipe decoder on human swipes from the swipe.futo.org corpus (MIT), built into
/// fixtures by `scripts/swipe-eval/build-fixtures.py`. Skipped unless `ZONE_SWIPE_FIXTURES`
/// names one or more fixture files (comma separated). `ZONE_SWIPE_TUNING` may hold a JSON
/// object of `SwipeTuning` fields to override, for sweeps. `ZONE_SWIPE_PAIRS` names a word-pair
/// table to use as the context model. Results print to the test log and a miss list is written
/// beside each fixture as `<name>.misses.txt`.
///
/// The corpus prompts are Wikipedia sentences, so its word mix is encyclopedic. `ZONE_SWIPE_WEIGHTS`
/// names `word<TAB>count` files (comma separated) of conversational frequencies (scripts/swipe-eval/README.md);
/// each row is then also weighted by that frequency over the word's share of the fixture, which
/// estimates accuracy on a conversational word mix from the same human gestures. Rows whose
/// target autocorrect never suggests (profanity) are skipped unless `ZONE_SWIPE_ALL_WORDS=1`;
/// swipe can enter them. `ZONE_SWIPE_EXTRA_WORDS` names a file of words to add as personal
/// words, for vocabulary experiments.
///
///     ZONE_SWIPE_FIXTURES=~/.cache/zone-swipe-data/eval-dev-2000.json \
///       swift test -c release --package-path ZoneCore --filter SwipeEvalTests
final class SwipeEvalTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let i: Int
            let word: String
            let prev: String?
            let w: Double
            let h: Double
            let points: [[Double]]
        }
        let layout: [String: [Double]]
        let rows: [Row]
    }

    struct Report {
        var eligible = 0
        var top1 = 0
        var top3 = 0
        var empties = 0
        var times: [Double] = []
        var misses: [String] = []
        /// Per eligible row: the folded target, and whether it ranked first and in the top three.
        var outcomes: [(word: String, top1: Bool, top3: Bool)] = []

        /// Accuracy with each row weighted by `weights[word] / rows of that word`, or nil.
        func weighted(_ weights: [String: Double]) -> (top1: Double, top3: Double)? {
            var perWord: [String: Int] = [:]
            for o in outcomes { perWord[o.word, default: 0] += 1 }
            var total = 0.0, one = 0.0, three = 0.0
            for o in outcomes {
                guard let w = weights[o.word], w > 0 else { continue }
                let share = w / Double(perWord[o.word]!)
                total += share
                if o.top1 { one += share }
                if o.top3 { three += share }
            }
            return total > 0 ? (100 * one / total, 100 * three / total) : nil
        }
    }

    func testEval() throws {
        guard let paths = ProcessInfo.processInfo.environment["ZONE_SWIPE_FIXTURES"], !paths.isEmpty else {
            throw XCTSkip("set ZONE_SWIPE_FIXTURES to score the decoder")
        }
        let words = try XCTUnwrap(WordList.loadBundled())
        var tuning = SwipeTuning()
        if let json = ProcessInfo.processInfo.environment["ZONE_SWIPE_TUNING"], let data = json.data(using: .utf8) {
            tuning = try SwipeTuning.overriding(tuning, with: data)
        }
        var pairs: WordPairs?
        if let path = ProcessInfo.processInfo.environment["ZONE_SWIPE_PAIRS"], !path.isEmpty {
            pairs = try XCTUnwrap(WordPairs(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), words: words))
        }
        let neural = ProcessInfo.processInfo.environment["ZONE_SWIPE_NEURAL"] == "1" ? SwipeNeuralScorer() : nil
        if let weight = ProcessInfo.processInfo.environment["ZONE_SWIPE_NEURAL_WEIGHT"].flatMap(Float.init) { neural?.weight = weight }
        let decoder = SwipeDecoder(words: words, tuning: tuning, context: pairs)
        // Experiments: `word` lines are scored like personal words; `word<TAB>rank` lines replace
        // the starter vocabulary with these ranks.
        if let path = ProcessInfo.processInfo.environment["ZONE_SWIPE_EXTRA_WORDS"], !path.isEmpty {
            let text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
            var personal: [String] = [], starter: [(word: String, rank: Int)] = []
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2, let rank = Int(parts[1]) { starter.append((String(parts[0]), rank)) } else { personal.append(String(line)) }
            }
            decoder.setPersonalWords(personal, starter: starter.isEmpty ? SwipeVocabulary.starter : starter)
        }
        // Comma separated; each file adds its own weighted column.
        var weightTables: [(name: String, table: [String: Double])] = []
        for path in (ProcessInfo.processInfo.environment["ZONE_SWIPE_WEIGHTS"] ?? "").split(separator: ",") {
            let full = (String(path) as NSString).expandingTildeInPath
            var table: [String: Double] = [:]
            for line in try String(contentsOfFile: full, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count >= 2, let count = Double(parts[1]) { table[String(parts[0]).lowercased()] = count }
            }
            weightTables.append(((full as NSString).lastPathComponent, table))
        }
        for path in paths.split(separator: ",").map({ ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }) {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let report = score(fixture, decoder: decoder, words: words, neural: neural)
            let name = (path as NSString).lastPathComponent
            let sorted = report.times.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            var line = String(format: "SWIPE EVAL %@: eligible %d top1 %.2f%% top3 %.2f%% empties %d decode median %.2f ms p95 %.2f ms",
                              name, report.eligible, 100 * Double(report.top1) / Double(max(report.eligible, 1)),
                              100 * Double(report.top3) / Double(max(report.eligible, 1)), report.empties, median, p95)
            for (weightName, table) in weightTables {
                if let chat = report.weighted(table) {
                    line += String(format: " [%@ top1 %.2f%% top3 %.2f%%]", weightName, chat.top1, chat.top3)
                }
            }
            print(line)
            let missPath = (path as NSString).deletingPathExtension + ".misses.txt"
            try (line + "\n" + report.misses.joined(separator: "\n") + "\n").write(toFile: missPath, atomically: true, encoding: .utf8)
        }
    }

    private func score(_ fixture: Fixture, decoder: SwipeDecoder, words: WordList, neural: SwipeNeuralScorer?) -> Report {
        var report = Report()
        let allWords = ProcessInfo.processInfo.environment["ZONE_SWIPE_ALL_WORDS"] == "1"
        var layouts: [Int: SwipeLayout] = [:]
        for row in fixture.rows {
            let target = row.word.trimmingCharacters(in: .punctuationCharacters)
            // All words: every target, including slang outside the list, which only a personal word can produce.
            if !allWords { guard let entry = words.lookup(target), entry.isSuggestible else { continue } }
            let distinct = Set(target.lowercased().filter(\.isLetter)).count
            guard distinct >= 2, row.w > 0, row.h > 0 else { continue }
            let ratio = (row.h / 3) / (row.w / 10)
            let key = Int((ratio * 100).rounded())
            let layout = layouts[key] ?? {
                var centers: [Character: SwipePoint] = [:]
                for (letter, c) in fixture.layout where c.count == 2 {
                    centers[Character(letter)] = SwipePoint(x: Float(c[0] * 10), y: Float(c[1] * 3 * ratio))
                }
                let made = SwipeLayout(centers: centers, rowPitch: Float(ratio))
                layouts[key] = made
                return made
            }()
            let points = row.points.map { SwipePoint(x: Float($0[0] * 10), y: Float($0[1] * 3 * ratio), t: Float($0[2]) / 1000) }
            report.eligible += 1
            let context = SwipeContext(previousWord: row.prev)
            let started = DispatchTime.now().uptimeNanoseconds
            let geometric = decoder.decode(points, layout: layout, context: context, limit: neural == nil ? 10 : 96)
            let candidates = neural?.rank(geometric, points: points, layout: layout) ?? geometric
            report.times.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            let folded = target.lowercased()
            if candidates.isEmpty { report.empties += 1 }
            let first = candidates.first?.word.lowercased() == folded
            report.outcomes.append((folded, first, first || candidates.prefix(3).contains { $0.word.lowercased() == folded }))
            if let first = candidates.first, first.word.lowercased() == folded {
                report.top1 += 1
                report.top3 += 1
            } else {
                if candidates.prefix(3).contains(where: { $0.word.lowercased() == folded }) { report.top3 += 1 }
                let rank = candidates.firstIndex { $0.word.lowercased() == folded }.map { "\($0 + 1)" } ?? "-"
                report.misses.append("\(row.i)\t\(target)\tprev=\(row.prev ?? "")\trank=\(rank)\t" + candidates.prefix(5).map { "\($0.word):\(String(format: "%.3f", $0.score))" }.joined(separator: " "))
            }
        }
        return report
    }
}

/// What should a swipe do right after the user deleted the last swiped word and swiped again?
///
/// `ZONE_SWIPE_RESWIPE=0,0.05,0.1,inf` (with `ZONE_SWIPE_FIXTURES`) pairs two different people's
/// swipes of the same word: the first is the swipe that was deleted, the second the retry. Each
/// value is a penalty added to the deleted word's score on the retry (`inf` leaves it out).
/// "Fixed" is how often the retry is right after a wrong first guess; "kept" is how often it is
/// still right when the first guess was right and the person deleted it anyway.
extension SwipeEvalTests {
    func testReswipeEval() throws {
        let env = ProcessInfo.processInfo.environment
        guard let paths = env["ZONE_SWIPE_FIXTURES"], !paths.isEmpty, let list = env["ZONE_SWIPE_RESWIPE"], !list.isEmpty else {
            throw XCTSkip("set ZONE_SWIPE_FIXTURES and ZONE_SWIPE_RESWIPE to measure retries")
        }
        let penalties = list.split(separator: ",").compactMap { Float($0 == "inf" ? "infinity" : String($0)) }
        let words = try XCTUnwrap(WordList.loadBundled())
        var tuning = SwipeTuning()
        if let json = env["ZONE_SWIPE_TUNING"], let data = json.data(using: .utf8) { tuning = try SwipeTuning.overriding(tuning, with: data) }
        let pairs = try env["ZONE_SWIPE_PAIRS"].flatMap { $0.isEmpty ? nil : $0 }.map {
            try XCTUnwrap(WordPairs(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath), words: words))
        }
        let neural = env["ZONE_SWIPE_NEURAL"] == "1" ? SwipeNeuralScorer() : nil
        let decoder = SwipeDecoder(words: words, tuning: tuning, context: pairs)
        for path in paths.split(separator: ",").map({ ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }) {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            var decoded: [String: [(ranked: [SwipeCandidate], end: UInt8?)]] = [:]
            for row in fixture.rows {
                let target = row.word.trimmingCharacters(in: .punctuationCharacters)
                guard let entry = words.lookup(target), entry.isSuggestible,
                      Set(target.lowercased().filter(\.isLetter)).count >= 2, row.w > 0, row.h > 0 else { continue }
                let ratio = (row.h / 3) / (row.w / 10)
                var centers: [Character: SwipePoint] = [:]
                for (letter, c) in fixture.layout where c.count == 2 {
                    centers[Character(letter)] = SwipePoint(x: Float(c[0] * 10), y: Float(c[1] * 3 * ratio))
                }
                let layout = SwipeLayout(centers: centers, rowPitch: Float(ratio))
                let points = row.points.map { SwipePoint(x: Float($0[0] * 10), y: Float($0[1] * 3 * ratio), t: Float($0[2]) / 1000) }
                let geometric = decoder.decode(points, layout: layout, context: SwipeContext(previousWord: row.prev), limit: neural == nil ? 10 : 96)
                let ranked = neural?.rank(geometric, points: points, layout: layout) ?? geometric
                decoded[target.lowercased(), default: []].append((ranked, SwipeRetry.endLetter(points.last, layout: layout)))
            }
            for penalty in penalties {
                var wrongFirst = 0, fixed = 0, rightFirst = 0, kept = 0
                for (target, attempts) in decoded where attempts.count >= 2 {
                    for (i, first) in attempts.enumerated() {
                        // One retry per first swipe: the next person's swipe of the same word.
                        let retry = attempts[(i + 1) % attempts.count]
                        guard let deleted = first.ranked.first?.word.lowercased() else { continue }
                        let best = SwipeRetry.alternatives(retry.ranked, retryOf: deleted, endLetter: retry.end,
                                                          penalty: penalty, limit: 1).first
                        let right = best?.word.lowercased() == target && best?.score.isFinite == true
                        if deleted == target { rightFirst += 1; if right { kept += 1 } } else { wrongFirst += 1; if right { fixed += 1 } }
                    }
                }
                print(String(format: "SWIPE RESWIPE %@ penalty %.3f: wrong first %d, retry fixed %.2f%%; right first %d, retry kept %.2f%%",
                             (path as NSString).lastPathComponent, penalty, wrongFirst, 100 * Double(fixed) / Double(max(wrongFirst, 1)),
                             rightFirst, 100 * Double(kept) / Double(max(rightFirst, 1))))
            }
        }
    }
}

extension SwipeTuning {
    /// `base` with every field present in a JSON object replaced.
    static func overriding(_ base: SwipeTuning, with data: Data) throws -> SwipeTuning {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return base }
        var t = base
        func f(_ key: String) -> Float? { (object[key] as? NSNumber).map { Float(truncating: $0) } }
        func i(_ key: String) -> Int? { (object[key] as? NSNumber).map { Int(truncating: $0) } }
        t.startWeight = f("startWeight") ?? t.startWeight
        t.endWeight = f("endWeight") ?? t.endWeight
        t.priorWeight = f("priorWeight") ?? t.priorWeight
        t.shapeWeight = f("shapeWeight") ?? t.shapeWeight
        t.contextWeight = f("contextWeight") ?? t.contextWeight
        t.casingPenalty = f("casingPenalty") ?? t.casingPenalty
        t.samplesPerPitch = f("samplesPerPitch") ?? t.samplesPerPitch
        t.minimumSamples = i("minimumSamples") ?? t.minimumSamples
        t.maximumSamples = i("maximumSamples") ?? t.maximumSamples
        t.band = i("band") ?? t.band
        t.startRadius = f("startRadius") ?? t.startRadius
        t.endRadius = f("endRadius") ?? t.endRadius
        t.visitRadius = f("visitRadius") ?? t.visitRadius
        t.shortlist = i("shortlist") ?? t.shortlist
        t.lengthSlack = f("lengthSlack") ?? t.lengthSlack
        t.lengthPad = f("lengthPad") ?? t.lengthPad
        t.yScale = f("yScale") ?? t.yScale
        t.minimumLength = f("minimumLength") ?? t.minimumLength
        return t
    }
}
