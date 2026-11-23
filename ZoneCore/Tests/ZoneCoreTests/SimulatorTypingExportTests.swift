// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

/// The end-to-end check of the typing simulation: the fast typist's taps, placed on the keyboard as
/// it sits on an iPhone 17 Pro simulator (402 pt wide, the grid's bottom at y 799 in Messages,
/// bottom row 123, space, return), written as `axe batch` steps, plus what the harness's pipeline
/// makes of exactly those taps. Run the steps against the simulator, read the message field, and
/// compare. Opt in with `ZONE_E2E_EXPORT=<dir>` (and `ZONE_E2E_SENTENCES`, default 12).
final class SimulatorTypingExportTests: XCTestCase {
    static let width: CGFloat = 402
    static let gridBottom: CGFloat = 799
    static let height: CGFloat = 205

    static let grid = KeyGridGeometry(size: CGSize(width: width, height: height), rows: [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .fill, .units(2.78)]),
    ])

    enum Role: Equatable { case letter(Character), space, delete, ignored }

    static func role(_ p: KeyGridGeometry.Position) -> Role {
        switch p.row {
        case 0: return .letter(Array("qwertyuiop")[p.index])
        case 1: return .letter(Array("asdfghjkl")[p.index])
        case 2: return p.index == 0 ? .ignored : p.index == 8 ? .delete : .letter(Array("zxcvbnm")[p.index - 1])
        default: return p.index == 0 ? .ignored : .space
        }
    }

    static func position(_ c: Character) -> KeyGridGeometry.Position? {
        for (r, row) in ["qwertyuiop", "asdfghjkl"].enumerated() {
            if let i = Array(row).firstIndex(of: c) { return .init(row: r, index: i) }
        }
        if let i = Array("zxcvbnm").firstIndex(of: c) { return .init(row: 2, index: i + 1) }
        return nil
    }

    struct Sentence: Codable {
        var intended: String
        /// Grid points (add the grid origin for the screen), with what each tap meant.
        var taps: [[Double]]
        var meant: String
        /// The harness's output for these taps: nearest key, and with dynamic targets (the
        /// keyboard uses them only once the prefix's table is ready, which fast typing can outrun).
        var nearest: String
        var dynamic: String
        var typedNearest: String
    }

    func testExportSimulatorTaps() throws {
        guard let directory = ProcessInfo.processInfo.environment["ZONE_E2E_EXPORT"] else {
            throw XCTSkip("set ZONE_E2E_EXPORT to write the simulator typing run")
        }
        let count = Int(ProcessInfo.processInfo.environment["ZONE_E2E_SENTENCES"] ?? "") ?? 12
        let interval = Double(ProcessInfo.processInfo.environment["ZONE_E2E_INTERVAL"] ?? "") ?? 0.12
        var rng = FastTypingSimulation.SplitMix(seed: 0xE2E_2026)
        let typist = FastTypingSimulation.Typist(profile: .fast, rng: &rng)
        let source = FastTypingSimulation.grid
        let corrector = { Autocorrector(words: WordListTests.list) }
        let nearestCorrector = corrector(), dynamicCorrector = corrector()
        var nearestModel = TouchAdaptation(), dynamicModel = TouchAdaptation()
        let cache = FastTypingSimulation.TableCache()
        var sentences: [Sentence] = []
        // Short chat sentences from the corpus, a fixed stride so the run is spread over it.
        let pool = TypingCorpus.sentences.filter { $0.split(separator: " ").count <= 8 && !$0.contains("'") }
        for k in 0..<count {
            let text = pool[(k * 37) % pool.count]
            let typed = FastTypingSimulation.generate(text, typist: typist, rng: &rng)
            var taps: [[Double]] = []
            var meant = ""
            for tap in typed.taps {
                // Same offset from the meant key's center as on the simulation's 393 pt grid.
                guard let point = tap.point else { continue }
                let from: KeyGridGeometry.Position, to: KeyGridGeometry.Position
                switch tap.intent {
                case .letter(let c):
                    guard let a = FastTypingSimulation.letterPositions[c], let b = Self.position(c) else { continue }
                    from = a; to = b; meant.append(c)
                case .space:
                    from = FastTypingSimulation.spaceBar; to = .init(row: 3, index: 1); meant.append(" ")
                case .apostrophe:
                    continue
                }
                guard let a = source.cap(from), let b = Self.grid.cap(to) else { continue }
                taps.append([Double(b.midX + point.x - a.midX), Double(b.midY + point.y - a.midY)])
            }
            let nearest = Self.run(taps, dynamic: false, corrector: nearestCorrector, model: &nearestModel, cache: cache)
            let dynamic = Self.run(taps, dynamic: true, corrector: dynamicCorrector, model: &dynamicModel, cache: cache)
            sentences.append(Sentence(intended: typed.intended.joined(separator: " "), taps: taps, meant: meant,
                                      nearest: nearest.output, dynamic: dynamic.output, typedNearest: nearest.typed))
            // One axe batch file per sentence: every tap is a touch down and up, then a pause.
            var steps: [String] = []
            for tap in taps {
                steps.append(String(format: "touch -x %.1f -y %.1f --down --up", tap[0], tap[1] + Double(Self.gridBottom - Self.height)))
                if interval > 0 { steps.append(String(format: "sleep %.3f", interval)) }
            }
            // The final separator: a clean space tap at the space bar's center.
            if let space = Self.grid.cap(.init(row: 3, index: 1)) {
                steps.append(String(format: "touch -x %.1f -y %.1f --down --up", space.midX, space.midY + Self.gridBottom - Self.height))
            }
            try steps.joined(separator: "\n").write(toFile: "\(directory)/steps-\(k).txt", atomically: true, encoding: .utf8)
        }
        let data = try JSONEncoder().encode(sentences)
        try data.write(to: URL(fileURLWithPath: "\(directory)/e2e.json"))
        print("wrote \(sentences.count) sentences, \(sentences.reduce(0) { $0 + $1.taps.count }) taps to \(directory)")
    }

    /// The keyboard's pipeline on these taps: learned offsets (learned as words commit),
    /// optionally dynamic targets, then autocorrect with touch evidence on each space.
    static func run(_ taps: [[Double]], dynamic: Bool, corrector: Autocorrector, model: inout TouchAdaptation,
                    cache: FastTypingSimulation.TableCache) -> (typed: String, output: String) {
        let pitch = grid.unitWidth + grid.metrics.keySpacing, rowPitch = grid.metrics.rowPitch
        var output: [String] = []
        var typedWords: [String] = []
        var word = "", touches: [KeyTouch] = [], raw: [KeyTouch] = []
        func commit() {
            guard !word.isEmpty else { return }
            let fixed = corrector.evaluate(word, touches: touches).replacement ?? word
            model.learn(typed: word, committed: fixed, touches: raw)
            output.append(fixed)
            typedWords.append(word)
            word = ""; touches = []; raw = []
        }
        for tap in taps + [[Double(grid.cap(.init(row: 3, index: 1))!.midX), Double(grid.cap(.init(row: 3, index: 1))!.midY)]] {
            let point = CGPoint(x: tap[0], y: tap[1])
            let table = model.offsetTable
            let shifted = grid.adjusted(point) { position in
                guard case .letter(let c) = role(position), let byte = c.asciiValue else { return nil }
                let o = table[Int(byte - 0x61)]
                return CGVector(dx: CGFloat(o.dx) * pitch, dy: CGFloat(o.dy) * rowPitch)
            }
            var likelihood: ((KeyGridGeometry.Position) -> Double?)?
            if dynamic, let prefix = cache.table(word.lowercased()) {
                likelihood = { position in
                    guard case .letter(let c) = role(position) else { return nil }
                    return prefix.probability(of: String(c))
                }
            }
            guard let hit = grid.key(at: shifted, likelihood: likelihood) else { continue }
            switch role(hit) {
            case .letter(let c):
                word.append(c)
                touches.append(grid.touchOffset(shifted, on: hit) ?? .center)
                raw.append(grid.touchOffset(point, on: hit) ?? .center)
            case .space:
                commit()
            case .delete:
                if !word.isEmpty { word.removeLast(); touches.removeLast(); raw.removeLast() }
            case .ignored:
                break
            }
        }
        commit()
        return (typedWords.joined(separator: " "), output.joined(separator: " "))
    }
}
