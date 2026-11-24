// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

/// Replays saved dictations (the recognizer's raw text) through every text style, for measuring a
/// style change on real speech. Skipped unless `ZONE_STYLE_REPLAY` names a JSON Lines file with a
/// `text` field per line (`zone export --kind dictation --source keyboard -o file`); writes
/// `ZONE_STYLE_REPLAY_OUT` with one line per dictation: the raw text and each style's output.
/// `ZONE_STYLE_REPLAY_NO_CAPS` replays with Auto-Capitalization off and Shift lowercase.
final class StyleReplayTests: XCTestCase {
    func testReplay() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["ZONE_STYLE_REPLAY"], let output = environment["ZONE_STYLE_REPLAY_OUT"] else {
            throw XCTSkip("set ZONE_STYLE_REPLAY and ZONE_STYLE_REPLAY_OUT")
        }
        let sentenceCapitals = environment["ZONE_STYLE_REPLAY_NO_CAPS"] == nil
        let mode = environment["ZONE_NUMBER_MODE"].flatMap(NumberPreferences.Mode.init(rawValue:)) ?? .style
        var numbers = NumberPreferences(mode: mode)
        if environment["ZONE_NUMBER_ALL_STYLES"] == "1" { numbers.styles = Set(TextStyle.allCases) }
        var lines: [String] = []
        for line in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let text = object["text"] as? String else { continue }
            var row: [String: String] = ["raw": text]
            for style in TextStyle.allCases {
                row[style.rawValue] = style.insertion(of: text, contextBefore: "", fieldCapitalizesSentences: sentenceCapitals,
                                                      opening: sentenceCapitals ? .automatic : .lowercase,
                                                      numbers: numbers, autoCapitalization: sentenceCapitals)
            }
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
        try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
