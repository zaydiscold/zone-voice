// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Runs the stutter filter over recognized speech kept outside the repository and writes every
/// change it makes, for reading. Skipped unless `ZONE_STUTTER_CORPUS` names a file of JSON lines
/// with a `text` field (Fluid Speech Mini's output, one recording a line). `ZONE_STUTTER_OUT` is
/// the report's path; the filtered text goes beside it, a recording a line.
final class StutterCorpusTests: XCTestCase {
    func testWriteEveryChangeOnACorpus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpus = environment["ZONE_STUTTER_CORPUS"], let out = environment["ZONE_STUTTER_OUT"] else {
            throw XCTSkip("Set ZONE_STUTTER_CORPUS and ZONE_STUTTER_OUT to measure on recognized speech.")
        }
        var report = "", filteredLines = ""
        var clips = 0, changedClips = 0, wordsBefore = 0, wordsAfter = 0
        for line in try String(contentsOfFile: corpus, encoding: .utf8).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let text = object["text"] as? String else { continue }
            clips += 1
            let filtered = SpokenRepair.collapsingStutters(text)
            let before = text.split(whereSeparator: \.isWhitespace), after = filtered.split(whereSeparator: \.isWhitespace)
            wordsBefore += before.count
            wordsAfter += after.count
            filteredLines += filtered.replacingOccurrences(of: "\n", with: " ") + "\n"
            guard filtered != text else { continue }
            changedClips += 1
            // Each removal with the words around it: the words that went are in brackets.
            for change in after.difference(from: before).removals.reversed() {
                guard case let .remove(offset, _, _) = change else { continue }
                let from = max(0, offset - 6), to = min(before.count, offset + 7)
                let context = before[from..<to].enumerated().map { $0.offset + from == offset ? "[\($0.element)]" : String($0.element) }
                report += context.joined(separator: " ") + "\n"
            }
            XCTAssertEqual(SpokenRepair.collapsingStutters(filtered), filtered, "a second pass changes it again")
        }
        report = "\(clips) recordings, \(changedClips) changed, \(wordsBefore) words before, \(wordsBefore - wordsAfter) removed\n" + report
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        try filteredLines.write(toFile: out + ".filtered", atomically: true, encoding: .utf8)
    }
}
