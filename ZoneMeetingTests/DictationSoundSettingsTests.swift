// by zayd/cold @ zayd.wtf

import AVFoundation
import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class DictationSoundSettingsTests: XCTestCase {
    func testSavedSelectionsAndOldDefaults() throws {
        let suite = "zone.tests.sound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choices: [(String?, DictationSounds.Set)] = [
            (nil, .wood), ("drop", .wood), ("glass", .wood),
            ("chime", .chime), ("wood", .wood), ("kalimba", .kalimba)
        ]
        for (saved, expected) in choices {
            defaults.set(saved, forKey: "zone.settings.soundSet")
            let settings = AppSettings(defaults: defaults, store: InMemorySharedStore(), vocabulary: nil)
            XCTAssertEqual(settings.soundSet, expected)
        }
    }

    func testEveryCuePlaysFromTheBundle() throws {
        XCTAssertEqual(DictationSounds.Set.allCases, [.wood, .chime, .kalimba])
        for cue in ["start", "stop"] {
            for set in DictationSounds.Set.allCases {
                let url = try XCTUnwrap(Bundle.main.url(forResource: "dictation-\(cue)-\(set.rawValue)", withExtension: "caf"))
                let player = try AVAudioPlayer(contentsOf: url)
                XCTAssertTrue(player.play())
                RunLoop.current.run(until: Date().addingTimeInterval(player.duration))
            }
            for removed in ["glass", "drop"] {
                XCTAssertNil(Bundle.main.url(forResource: "dictation-\(cue)-\(removed)", withExtension: "caf"))
            }
        }
    }
}
