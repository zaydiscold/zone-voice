// by zayd/cold @ zayd.wtf

import Foundation
import XCTest

/// Shared pieces for the stress and fuzz tests: a seeded generator so every failure reproduces,
/// the `ZONE_STRESS=1` switch for the heavy variants, and a wall-clock helper for time bounds.
enum Stress {
    /// Heavier iteration counts and sizes run only with `ZONE_STRESS=1 swift test`.
    static let enabled = ProcessInfo.processInfo.environment["ZONE_STRESS"] == "1"

    /// `light` in the default suite, `heavy` under `ZONE_STRESS=1`.
    static func iterations(_ light: Int, heavy: Int) -> Int { enabled ? heavy : light }

    /// Seconds of wall time for `body`.
    @discardableResult
    static func time(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// The bundled word list as (word, rank) pairs, read straight from the package resource.
    static let bundledWords: [(word: String, rank: Int)] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZoneCore/Resources/en-words.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, let rank = Int(fields[1]) else { return nil }
            return (String(fields[0]), rank)
        }
    }()

    static func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zone-stress-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}

/// SplitMix64: tiny, fast, and the same sequence on every machine for a given seed.
struct StressRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension StressRNG {
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &self) < probability }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
}
