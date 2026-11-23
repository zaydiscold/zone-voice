// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

/// Measures what the suggestion row saves on real text, with the shipped corrector and pair
/// table: taps needed to write each word (letters until the word is in the row, plus the tap)
/// against typing it and a space. Skipped unless `ZONE_NEXTWORD_CORPUS` names a text file, one
/// message per line; private text never goes in the repository.
///
///     ZONE_NEXTWORD_CORPUS=/path/messages.txt swift test --package-path ZoneCore --filter NextWordBarEvaluationTests
final class NextWordBarEvaluationTests: XCTestCase {
    func testKeystrokesSavedOnACorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["ZONE_NEXTWORD_CORPUS"] else {
            throw XCTSkip("set ZONE_NEXTWORD_CORPUS to a text file")
        }
        let words = try XCTUnwrap(WordList.loadBundled())
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZoneKeyboard/Resources/en-pairs.bin")
        let plain = Autocorrector(words: words)
        let contextual = Autocorrector(words: words)
        contextual.context = try XCTUnwrap(WordPairs(url: url, words: words))

        var typedAll = 0, before = 0, after = 0, wordCount = 0, predicted = 0, withPrevious = 0
        var evaluations = 0, seconds = 0.0
        func offered(_ row: [Suggestion], _ target: String) -> Bool {
            row.contains { $0.kind != .literal && $0.text.lowercased() == target }
        }
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            var text = ""
            for raw in line.split(separator: " ") {
                defer { text += raw + " " }
                let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"()[]"))
                guard token.count >= 1, words.lookup(token) != nil else { continue }
                let target = token.lowercased(), letters = Array(target)
                let previous = SwipeSpacing.previousWord(before: text)
                wordCount += 1
                typedAll += letters.count + 1
                var old = letters.count + 1, new = letters.count + 1
                for typed in 1..<max(letters.count, 1) where offered(plain.evaluate(String(letters[..<typed])).suggestions, target) {
                    old = typed + 1
                    break
                }
                let start = Date()
                if let previous {
                    withPrevious += 1
                    if offered(contextual.predictions(after: previous), target) { new = 1; predicted += 1 }
                }
                if new > 1 {
                    for typed in 1..<max(letters.count, 1) {
                        evaluations += 1
                        if offered(contextual.evaluate(String(letters[..<typed]), previous: previous).suggestions, target) {
                            new = typed + 1
                            break
                        }
                    }
                }
                seconds += Date().timeIntervalSince(start)
                before += old
                after += new
            }
        }
        let report = String(format: "words %d, with a previous word %d, predicted at zero letters %.1f%% of those | saved before %.1f%%, after %.1f%% | %.3f ms per contextual evaluation",
                            wordCount, withPrevious, 100 * Double(predicted) / Double(max(withPrevious, 1)),
                            100 * (1 - Double(before) / Double(typedAll)), 100 * (1 - Double(after) / Double(typedAll)),
                            1000 * seconds / Double(max(evaluations, 1)))
        print("NEXTWORD " + report)
        XCTAssertGreaterThan(wordCount, 0)
        XCTAssertLessThan(after, before, "the row with context must save more than without")
    }
}
