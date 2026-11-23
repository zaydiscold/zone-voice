// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Fast two-thumb typing over the chat corpus (`FastTypingSimulation`): every
/// pipeline's word accuracy, per error class, with floors so a change cannot quietly make typing
/// worse. `ZONE_TYPING_EXPORT=<dir> swift test --filter FastTypingSimulationTests` also writes
/// the nearest-key tokens per profile as JSON for `scripts/apple-autocorrect` (Apple's corrector).
final class FastTypingSimulationTests: XCTestCase {
    /// Word accuracy floors and false-correction ceilings per profile, for the keyboard as it
    /// ships ("keyboard": dynamic targets plus learned offsets) and without learned offsets
    /// ("dynamic"). Raise the floors and lower the ceilings when typing improves; never the other
    /// way to make a change pass. Set 2026-11-03; before that work the keyboard measured
    /// 95.8%, 90.6% and 83.3% with 0.5%, 0.8% and 0.8% of correct words changed. Raised
    /// 2026-11-06 by the space slip work (space bar claims after a finished word, multi-slip
    /// splits, no learning from slipped spaces), which took "high space" from 81.6% to 90.9%.
    /// Raised 2026-11-08 by reading x as a slipped space and weighing where the slipped key was
    /// tapped (high space 90.86% to 91.02%, fast and rushed up slightly, nothing changed more).
    static let floors: [String: (keyboard: Double, dynamic: Double, falseCorrections: Double)] = [
        "careful": (0.968, 0.964, 0.0030),
        "fast": (0.930, 0.918, 0.0060),
        "rushed": (0.864, 0.841, 0.0131),
        "high space": (0.910, 0.898, 0.0090),
    ]

    func testFastTypingAcrossProfiles() throws {
        for profile in FastTypingSimulation.Profile.all {
            let run = FastTypingSimulation.run(profile, recordFailures: Self.showFailures)
            report(run)
            try export(run)
            let keyboard = try XCTUnwrap(run.tallies["keyboard"])
            let dynamic = try XCTUnwrap(run.tallies["dynamic"])
            let touch = try XCTUnwrap(run.tallies["touch"])
            let plain = try XCTUnwrap(run.tallies["no touch"])
            XCTAssertGreaterThan(plain.accuracy, run.raw.accuracy, "autocorrect made \(profile.name) typing worse")
            XCTAssertGreaterThanOrEqual(touch.accuracy, plain.accuracy, "touch evidence made \(profile.name) typing worse")
            XCTAssertGreaterThanOrEqual(keyboard.accuracy, dynamic.accuracy, "learned offsets made \(profile.name) typing worse")
            let floor = try XCTUnwrap(Self.floors[profile.name])
            XCTAssertGreaterThanOrEqual(keyboard.accuracy, floor.keyboard, "\(profile.name) keyboard accuracy fell")
            XCTAssertGreaterThanOrEqual(dynamic.accuracy, floor.dynamic, "\(profile.name) accuracy without learned offsets fell")
            XCTAssertLessThanOrEqual(keyboard.falseCorrectionRate, floor.falseCorrections, "\(profile.name) changes more correct words")
            // A raw error rate outside what fast thumbs produce means the model drifted, not the keyboard.
            let rawBand: ClosedRange<Double> = profile.name == "careful" ? 0.015...0.04 : profile.name == "rushed" ? 0.10...0.14 : 0.05...0.10
            XCTAssertTrue(rawBand.contains(run.rawCharacterErrorRate), "\(profile.name) raw error \(run.rawCharacterErrorRate)")
        }
    }

    /// `ZONE_TYPING_FAILURES=1` prints each pipeline's failures per class.
    static let showFailures = ProcessInfo.processInfo.environment["ZONE_TYPING_FAILURES"] == "1"

    private func report(_ run: FastTypingSimulation.Run) {
        let columns = [("typed", run.raw)] + FastTypingSimulation.pipelines.map { ($0.name, run.tallies[$0.name] ?? .init()) }
        let sorted = run.evaluateNanos.sorted()
        let mean = sorted.isEmpty ? 0 : Double(sorted.reduce(0, +)) / Double(sorted.count) / 1000
        let p99 = sorted.isEmpty ? 0 : Double(sorted[min(sorted.count - 1, sorted.count * 99 / 100)]) / 1000
        let exact = FastTypingSimulation.pipelines.map { pipeline -> String in
            let tally = run.tallies[pipeline.name] ?? .init()
            return String(format: "%@ %.4f/%.4f", pipeline.name, tally.accuracy, tally.falseCorrectionRate)
        }.joined(separator: ", ")
        print("""
        fast typing, profile \(run.profile): \(run.raw.words) words, raw character error \(String(format: "%.1f%%", 100 * run.rawCharacterErrorRate)), \
        words typed right \(TypingScore.percent(run.raw.accuracy)); evaluate mean \(String(format: "%.1f", mean)) us, p99 \(String(format: "%.1f", p99)) us
        \(TypingScore.table(columns))
        exact accuracy/false corrections: \(exact)
        """)
        guard Self.showFailures else { return }
        for (pipeline, classes) in run.failures.sorted(by: { $0.key < $1.key }) {
            for (label, lines) in classes.sorted(by: { $0.key < $1.key }) {
                print("  \(run.profile) \(pipeline) \(label) (\(lines.count)): " + lines.prefix(60).joined(separator: "; "))
            }
        }
    }

    private func export(_ run: FastTypingSimulation.Run) throws {
        guard let directory = ProcessInfo.processInfo.environment["ZONE_TYPING_EXPORT"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("typing-\(run.profile).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(TypingScore.Export(profile: run.profile, sentences: run.export))
        try data.write(to: url)
        print("wrote \(url.path)")
    }
}
