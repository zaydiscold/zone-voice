// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation
@testable import ZoneCore

/// A fast two-thumb typist on Zone's letters layer, for measuring hit targeting and autocorrect
/// against the errors people actually make. Deterministic for a seed.
///
/// Each simulated typist gets their own systematic touch offsets, as Azenkot and Zhai (MobileHCI
/// 2012) measured: per-key touch clouds are bivariate Gaussians whose means sit off the key
/// centers, differently per person; with two thumbs the left side is less accurate than the
/// right, and keys far from a thumb are undershot ("they did not reach far enough across the
/// keyboard"). The model: aim at the key center, then add
/// - a per-thumb constant (left thumb lands left, the dominant right thumb is tighter),
/// - an undershoot toward the thumb's resting side that grows with reach,
/// - a per-key constant (Gboard's personalization study saw users miss each key in its own
///   direction),
/// - how far below the aim iOS reports the contact (the grid assumes `KeyGridGeometry.touchBias`),
/// - per-tap Gaussian spread, wider on the bottom letter row and at the row ends.
/// Then speed errors that are not spatial: dropped taps (more on the second of a doubled letter),
/// extra taps, letters registered in the wrong order (mostly across thumbs), the space bar
/// missed or registered one letter early or late, the apostrophe skipped, and real misspellings
/// of longer words (Wikipedia's list). Space taps are spatial too, so a thumb that lands above the
/// space bar types x, c, v, b or n, and a bottom-row letter that lands low splits the word.
enum FastTypingSimulation {
    // MARK: Keyboard

    static let size = CGSize(width: 393, height: 212)
    /// The letters layer on a 393 pt phone, as `KeyGridGeometryTests` lays it out.
    static let grid = KeyGridGeometry(size: size, rows: [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
    ])

    enum Role: Equatable {
        case letter(Character)
        case space
        case delete
        /// Shift, 123 and the globe: the tap types nothing.
        case ignored
    }

    static let roles: [[Role]] = [
        "qwertyuiop".map { .letter($0) },
        "asdfghjkl".map { .letter($0) },
        [.ignored] + "zxcvbnm".map { .letter($0) } + [.delete],
        // 123, globe, space, return (return ends the word as space does).
        [.ignored, .ignored, .space, .space],
    ]

    static func role(_ position: KeyGridGeometry.Position) -> Role {
        guard roles.indices.contains(position.row), roles[position.row].indices.contains(position.index) else { return .ignored }
        return roles[position.row][position.index]
    }

    static let letterPositions: [Character: KeyGridGeometry.Position] = {
        var table: [Character: KeyGridGeometry.Position] = [:]
        for (r, row) in roles.enumerated() {
            for (i, role) in row.enumerated() {
                if case .letter(let c) = role { table[c] = .init(row: r, index: i) }
            }
        }
        return table
    }()

    static let spaceBar = KeyGridGeometry.Position(row: 3, index: 2)

    /// The letters over the space bar, as the keyboard hands them to autocorrect.
    static let spaceBarLetters: Set<Character> = Set(grid.keys(above: spaceBar).compactMap { position in
        letterPositions.first { $0.value == position }?.key
    })

    // MARK: Typists

    struct Profile {
        var name: String
        /// Per-tap spread on the top and home rows, pt (Azenkot and Zhai: about 1.5 mm, 9 pt, per
        /// person with two thumbs at 50 WPM).
        var sigmaX: Double
        var sigmaY: Double
        /// How much one typist's constant offsets vary between people, pt.
        var systematic: Double
        /// Per letter.
        var omission: Double
        /// Added on the second letter of a doubled pair ("tomorow").
        var doubledOmission: Double
        var insertion: Double
        /// Per adjacent letter pair typed by different thumbs, and by the same thumb.
        var crossThumbSwap: Double
        var sameThumbSwap: Double
        /// Per space between words.
        var spaceOmission: Double
        var spaceShift: Double
        /// Per word with an apostrophe.
        var apostropheSkip: Double
        /// Per word of five letters or more that has a known misspelling.
        var cognitive: Double
        /// How far above the space bar's center this typist's space taps land, pt: a thumb coming
        /// down from the letters that stops short, so a share of spaces type x, c, v, b or n.
        var spaceLift: Double = 0

        static let careful = Profile(name: "careful", sigmaX: 6.5, sigmaY: 6.0, systematic: 3.0,
                                     omission: 0.004, doubledOmission: 0.02, insertion: 0.002,
                                     crossThumbSwap: 0.006, sameThumbSwap: 0.001, spaceOmission: 0.005,
                                     spaceShift: 0.004, apostropheSkip: 0.5, cognitive: 0.06)
        static let fast = Profile(name: "fast", sigmaX: 8.0, sigmaY: 7.5, systematic: 4.0,
                                  omission: 0.009, doubledOmission: 0.04, insertion: 0.004,
                                  crossThumbSwap: 0.014, sameThumbSwap: 0.002, spaceOmission: 0.010,
                                  spaceShift: 0.010, apostropheSkip: 0.6, cognitive: 0.10)
        static let rushed = Profile(name: "rushed", sigmaX: 9.5, sigmaY: 9.0, systematic: 5.0,
                                    omission: 0.015, doubledOmission: 0.06, insertion: 0.007,
                                    crossThumbSwap: 0.022, sameThumbSwap: 0.004, spaceOmission: 0.016,
                                    spaceShift: 0.016, apostropheSkip: 0.7, cognitive: 0.14)
        /// Zayd's thumbs on November 6, 2026: fast, with space taps landing high. Four of the sixteen
        /// spaces in "i don't know if we could investigate this but I pressed V an awful lot
        /// instead of spacebar" typed c, v or b ("incestigstecthus butcibpressed ... lotvinstead").
        static let highSpace: Profile = {
            var profile = fast
            profile.name = "high space"
            profile.spaceLift = 17
            return profile
        }()
        static let all = [careful, fast, rushed, highSpace]
    }

    /// Where each thumb rests: the undershoot pulls touches toward these.
    static let leftHome = CGPoint(x: 45, y: size.height + 70)
    static let rightHome = CGPoint(x: size.width - 45, y: size.height + 70)

    static func isLeftThumb(_ letter: Character) -> Bool {
        guard let position = letterPositions[letter], let cap = grid.cap(position) else { return false }
        return cap.midX < size.width / 2
    }

    struct Typist {
        let profile: Profile
        let leftBias: CGVector
        let rightBias: CGVector
        let leftReach: Double
        let rightReach: Double
        let keyJitter: [Character: CGVector]
        /// How far below the aim iOS reports this typist's contact, pt.
        let reportedBelow: Double
        /// Share of space taps made with the right thumb (Azenkot and Zhai: mostly the right).
        let spaceRightShare: Double

        init(profile: Profile, rng: inout SplitMix) {
            self.profile = profile
            let s = profile.systematic
            leftBias = CGVector(dx: -0.5 * s + rng.gaussian() * 0.4 * s, dy: rng.gaussian() * 0.3 * s)
            rightBias = CGVector(dx: 0.25 * s + rng.gaussian() * 0.3 * s, dy: rng.gaussian() * 0.3 * s)
            leftReach = 0.015 + rng.uniform() * 0.01 * s
            rightReach = 0.01 + rng.uniform() * 0.007 * s
            var jitter: [Character: CGVector] = [:]
            for letter in "abcdefghijklmnopqrstuvwxyz" {
                jitter[letter] = CGVector(dx: rng.gaussian() * 0.6 * s, dy: rng.gaussian() * 0.5 * s)
            }
            keyJitter = jitter
            reportedBelow = Double(KeyGridGeometry.touchBias) + rng.gaussian() * 0.5 * s
            spaceRightShare = 0.65 + 0.25 * rng.uniform()
        }

        /// The constant part of where this typist's taps on a letter land, relative to its cap
        /// center, beyond the grid's own `touchBias` (what perfect adaptation would remove).
        func systematic(_ letter: Character) -> CGVector {
            guard let position = FastTypingSimulation.letterPositions[letter], let cap = FastTypingSimulation.grid.cap(position) else { return .zero }
            let offset = constantOffset(aim: CGPoint(x: cap.midX, y: cap.midY), left: cap.midX < FastTypingSimulation.size.width / 2, letter: letter)
            return CGVector(dx: offset.dx, dy: offset.dy - Double(KeyGridGeometry.touchBias))
        }

        private func constantOffset(aim: CGPoint, left: Bool, letter: Character?) -> CGVector {
            let bias = left ? leftBias : rightBias
            let reach = left ? leftReach : rightReach
            let home = left ? FastTypingSimulation.leftHome : FastTypingSimulation.rightHome
            let undershoot = CGVector(dx: -reach * (aim.x - home.x), dy: reach * 0.3 * (home.y - aim.y))
            let jitter = letter.flatMap { keyJitter[$0] } ?? .zero
            return CGVector(dx: bias.dx + undershoot.dx + jitter.dx, dy: bias.dy + undershoot.dy + jitter.dy + reportedBelow)
        }

        /// A raw touch point for a tap aimed at `position`. `spread` widens the noise (an extra
        /// tap made in passing).
        func touch(_ position: KeyGridGeometry.Position, rng: inout SplitMix, spread: Double = 1) -> CGPoint {
            guard let cap = FastTypingSimulation.grid.cap(position) else { return .zero }
            var aim = CGPoint(x: cap.midX, y: cap.midY)
            var letter: Character?
            if case .letter(let c) = FastTypingSimulation.role(position) { letter = c }
            let left: Bool
            if position == FastTypingSimulation.spaceBar {
                left = rng.uniform() >= spaceRightShare
                // Each thumb hits the space bar on its own side of the center.
                aim.x += (left ? -1 : 1) * 0.22 * cap.width
            } else {
                left = aim.x < FastTypingSimulation.size.width / 2
            }
            let offset = constantOffset(aim: aim, left: left, letter: letter)
            var sx = profile.sigmaX * spread, sy = profile.sigmaY * spread
            if position.row >= 2 { sx *= 1.12; sy *= 1.12 }
            if let letter, "qazplm".contains(letter) { sx *= 1.1 }
            if position == FastTypingSimulation.spaceBar {
                sx *= 1.6
                aim.y -= profile.spaceLift
            }
            return CGPoint(x: aim.x + offset.dx + rng.gaussian() * sx, y: aim.y + offset.dy + rng.gaussian() * sy)
        }
    }

    // MARK: Generation

    enum Intent: Equatable {
        case letter(Character)
        /// Typed on the numbers layer; taken as exact.
        case apostrophe
        case space
    }

    struct Tap {
        var intent: Intent
        /// Nil for exact input (the apostrophe, the sentence's final separator).
        var point: CGPoint?
        /// The intended word this tap belongs to (a space belongs to the word before it).
        var word: Int
    }

    struct TypedSentence {
        var intended: [String]
        var classes: [String]
        var taps: [Tap]
    }

    static func generate(_ sentence: String, typist: Typist, rng: inout SplitMix) -> TypedSentence {
        let p = typist.profile
        let words = sentence.split(separator: " ").map(String.init)
        var events = [Set<String>](repeating: [], count: words.count)
        var slips = [Int](repeating: 0, count: words.count)
        var taps: [Tap] = []
        for (i, word) in words.enumerated() {
            var spelled = word
            if word.count >= 5, let wrongs = TypingCorpus.misspellings[word], rng.uniform() < p.cognitive {
                spelled = wrongs[Int(rng.next() % UInt64(wrongs.count))]
                events[i].insert(TypingScore.ErrorClass.cognitive)
            }
            if spelled.contains("'"), rng.uniform() < p.apostropheSkip {
                spelled.removeAll { $0 == "'" }
                events[i].insert(TypingScore.ErrorClass.apostrophe)
            }
            var wordTaps: [Tap] = []
            var previous: Character?
            for c in spelled {
                defer { previous = c }
                if c == "'" {
                    wordTaps.append(Tap(intent: .apostrophe, point: nil, word: i))
                    continue
                }
                guard let position = letterPositions[c] else { continue }
                if rng.uniform() < p.omission + (c == previous ? p.doubledOmission : 0) {
                    events[i].insert(TypingScore.ErrorClass.omission)
                    continue
                }
                wordTaps.append(Tap(intent: .letter(c), point: typist.touch(position, rng: &rng), word: i))
                if rng.uniform() < p.insertion {
                    wordTaps.append(Tap(intent: .letter(c), point: typist.touch(position, rng: &rng, spread: 1.8), word: i))
                    events[i].insert(TypingScore.ErrorClass.insertion)
                }
            }
            var k = 0
            while k + 1 < wordTaps.count {
                if case .letter(let a) = wordTaps[k].intent, case .letter(let b) = wordTaps[k + 1].intent, a != b {
                    let cross = isLeftThumb(a) != isLeftThumb(b)
                    if rng.uniform() < (cross ? p.crossThumbSwap : p.sameThumbSwap) {
                        wordTaps.swapAt(k, k + 1)
                        events[i].insert(TypingScore.ErrorClass.transposition)
                        k += 2
                        continue
                    }
                }
                k += 1
            }
            taps += wordTaps
            if i == words.count - 1 {
                // The sentence ends with punctuation or send: an exact separator.
                taps.append(Tap(intent: .space, point: nil, word: i))
            } else if rng.uniform() < p.spaceOmission {
                events[i].insert(TypingScore.ErrorClass.fused)
                events[i + 1].insert(TypingScore.ErrorClass.fused)
            } else {
                taps.append(Tap(intent: .space, point: typist.touch(spaceBar, rng: &rng), word: i))
            }
        }
        // The space registered one letter early ("th ecat") or late ("thec at").
        var s = 0
        while s < taps.count {
            defer { s += 1 }
            guard taps[s].intent == .space, taps[s].point != nil else { continue }
            let word = taps[s].word
            let roll = rng.uniform()
            if roll < p.spaceShift / 2, s > 0, taps[s - 1].word == word, case .letter = taps[s - 1].intent {
                taps.swapAt(s - 1, s)
                events[word].insert(TypingScore.ErrorClass.spaceShift)
                events[word + 1].insert(TypingScore.ErrorClass.spaceShift)
            } else if roll < p.spaceShift, s + 1 < taps.count, taps[s + 1].word == word + 1, case .letter = taps[s + 1].intent {
                taps.swapAt(s, s + 1)
                events[word].insert(TypingScore.ErrorClass.spaceShift)
                events[word + 1].insert(TypingScore.ErrorClass.spaceShift)
                s += 1
            }
        }
        // What the plain nearest-key grid makes of each tap labels the spatial errors.
        for tap in taps {
            guard let point = tap.point, let hit = grid.key(at: point) else { continue }
            let got = role(hit)
            switch tap.intent {
            case .letter(let wanted):
                switch got {
                case .letter(let c) where c == wanted: break
                case .letter: slips[tap.word] += 1
                case .space: events[tap.word].insert(TypingScore.ErrorClass.splitWord)
                case .delete, .ignored: events[tap.word].insert(TypingScore.ErrorClass.omission)
                }
            case .space:
                switch got {
                case .space: break
                case .letter:
                    events[tap.word].insert(TypingScore.ErrorClass.spaceLetter)
                    if tap.word + 1 < words.count { events[tap.word + 1].insert(TypingScore.ErrorClass.spaceLetter) }
                case .delete, .ignored:
                    events[tap.word].insert(TypingScore.ErrorClass.fused)
                    if tap.word + 1 < words.count { events[tap.word + 1].insert(TypingScore.ErrorClass.fused) }
                }
            case .apostrophe: break
            }
        }
        let classes = words.indices.map { i -> String in
            let kinds = events[i]
            if kinds.isEmpty { return slips[i] == 0 ? TypingScore.ErrorClass.clean : (slips[i] == 1 ? TypingScore.ErrorClass.key : TypingScore.ErrorClass.keys2) }
            if kinds.count == 1, slips[i] == 0 { return kinds.first! }
            return TypingScore.ErrorClass.multi
        }
        return TypedSentence(intended: words, classes: classes, taps: taps)
    }

    // MARK: Resolution

    /// One space-separated run of typed characters and, per character, where its tap sat on the
    /// key it typed (`KeyTouch`, the autocorrect evidence). The apostrophe counts as dead center.
    struct Token {
        var text: String
        /// Relative to the typed key after any learned shift: what autocorrect is given.
        var touches: [KeyTouch]
        /// Relative to the typed key without the learned shift: what `TouchAdaptation` learns from.
        var raw: [KeyTouch]
    }

    /// How the grid turns a tap into a key.
    struct Resolver {
        enum Offsets {
            case none
            /// The typist's true constant offsets: the most any per-key adaptation could do.
            case oracle
            /// Offsets learned online by `TouchAdaptation` from committed words.
            case learned
        }

        /// Apple-style dynamic hit targets from `NextLetterModel`, as the keyboard ships them.
        var dynamicTargets: Bool
        var offsets: Offsets = .none

        static let nearest = Resolver(dynamicTargets: false)
        static let dynamic = Resolver(dynamicTargets: true)
    }

    /// The keyboard's mapping from a grid position to a learned offset in points.
    static func learnedOffsets(_ adaptation: TouchAdaptation) -> (KeyGridGeometry.Position) -> CGVector? {
        let pitch = grid.unitWidth + grid.metrics.keySpacing, rowPitch = grid.metrics.rowPitch
        return { position in
            guard case .letter(let c) = role(position), let byte = c.asciiValue else { return nil }
            let offset = adaptation.offset(for: byte)
            return CGVector(dx: CGFloat(offset.dx) * pitch, dy: CGFloat(offset.dy) * rowPitch)
        }
    }

    /// Next-letter tables by prefix, shared across a run (the keyboard caches them the same way).
    final class TableCache {
        var tables: [String: NextLetterLikelihood?] = [:]
        func table(_ prefix: String) -> NextLetterLikelihood? {
            guard !prefix.isEmpty else { return nil }
            if let hit = tables[prefix] { return hit }
            let table = WordList.shared.flatMap { NextLetterModel.likelihood(after: prefix, in: $0) }
            tables[prefix] = .some(table)
            return table
        }
    }

    static func resolve(_ taps: [Tap], with resolver: Resolver, cache: TableCache, typist: Typist? = nil,
                        adaptation: TouchAdaptation? = nil) -> [Token] {
        var stream: [(Character, KeyTouch, KeyTouch)] = []
        var prefix = ""
        var shift: ((KeyGridGeometry.Position) -> CGVector?)?
        switch resolver.offsets {
        case .none: break
        case .oracle:
            if let typist {
                shift = { position in
                    guard case .letter(let c) = role(position) else { return nil }
                    return typist.systematic(c)
                }
            }
        case .learned:
            if let adaptation { shift = learnedOffsets(adaptation) }
        }
        for tap in taps {
            switch tap.intent {
            case .apostrophe:
                stream.append(("'", .center, .center))
                prefix.append("'")
                continue
            case .space where tap.point == nil:
                stream.append((" ", .center, .center))
                prefix = ""
                continue
            default:
                break
            }
            guard let raw = tap.point else { continue }
            let point = shift.map { grid.adjusted(raw, offsets: $0) } ?? raw
            var likelihood: ((KeyGridGeometry.Position) -> Double?)?
            if resolver.dynamicTargets, let table = cache.table(prefix) {
                likelihood = { position in
                    switch FastTypingSimulation.role(position) {
                    case .letter(let c): return table.nextKeyProbability(of: String(c))
                    case .space: return position == spaceBar ? table.nextKeyProbability(of: " ") : nil
                    case .delete, .ignored: return nil
                    }
                }
            }
            guard let hit = grid.key(at: point, likelihood: likelihood) else { continue }
            switch role(hit) {
            case .letter(let c):
                stream.append((c, grid.touchOffset(point, on: hit) ?? .center, grid.touchOffset(raw, on: hit) ?? .center))
                prefix.append(c)
            case .space:
                stream.append((" ", .center, .center))
                prefix = ""
            case .delete:
                if !stream.isEmpty { stream.removeLast() }
                prefix = String(prefix.dropLast())
            case .ignored:
                break
            }
        }
        var tokens: [Token] = []
        var current = Token(text: "", touches: [], raw: [])
        for (character, touch, raw) in stream {
            if character == " " {
                if !current.text.isEmpty { tokens.append(current) }
                current = Token(text: "", touches: [], raw: [])
            } else {
                current.text.append(character)
                current.touches.append(touch)
                current.raw.append(raw)
            }
        }
        if !current.text.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Output words after a corrector replaced tokens (a replacement may hold two words).
    static func words(_ corrected: [String]) -> [String] {
        corrected.flatMap { $0.split(separator: " ").map(String.init) }
    }

    // MARK: Runs

    struct Run {
        var profile: String
        var raw = TypingScore.Tally()
        var tallies: [String: TypingScore.Tally] = [:]
        var export: [TypingScore.Sentence] = []
        var characters = 0
        var characterEdits = 0
        /// Nanoseconds per `evaluate` call in the timed pipeline.
        var evaluateNanos: [UInt64] = []
        /// Per pipeline and class, the failures: "wanted <- typed -> got".
        var failures: [String: [String: [String]]] = [:]

        var rawCharacterErrorRate: Double { characters == 0 ? 0 : Double(characterEdits) / Double(characters) }
    }

    /// A correction pipeline: how the grid resolves taps, then what turns a token into output.
    struct Pipeline {
        var name: String
        var resolver: Resolver
        /// Given a fresh corrector per typist; returns the committed text for one token.
        var correct: (Autocorrector, Token) -> String
        var timed = false
    }

    /// Every pipeline uses the same autocorrector; they differ in how taps become keys and
    /// whether autocorrect sees where the taps landed.
    /// - "no touch": nearest key, autocorrect on the letters alone (what Apple's word-level
    ///   corrector is compared against, on the same tokens).
    /// - "touch": nearest key, autocorrect with touch evidence.
    /// - "dynamic": plus dynamic hit targets (the keyboard before learned offsets).
    /// - "keyboard": plus offsets learned online from committed words (the keyboard now).
    /// - "oracle": the typist's true offsets instead of learned ones, the ceiling for adaptation.
    static let pipelines: [Pipeline] = [
        Pipeline(name: "no touch", resolver: .nearest) { corrector, token in
            corrector.evaluate(token.text).replacement ?? token.text
        },
        Pipeline(name: "touch", resolver: .nearest) { corrector, token in
            corrector.evaluate(token.text, touches: token.touches).replacement ?? token.text
        },
        Pipeline(name: "dynamic", resolver: .dynamic) { corrector, token in
            corrector.evaluate(token.text, touches: token.touches).replacement ?? token.text
        },
        Pipeline(name: "keyboard", resolver: Resolver(dynamicTargets: true, offsets: .learned), correct: { corrector, token in
            corrector.evaluate(token.text, touches: token.touches).replacement ?? token.text
        }, timed: true),
        Pipeline(name: "oracle", resolver: Resolver(dynamicTargets: true, offsets: .oracle)) { corrector, token in
            corrector.evaluate(token.text, touches: token.touches).replacement ?? token.text
        },
    ]

    /// Several typists share the corpus: typist `t` types every `typists`-th sentence, so each
    /// sentence is typed once per run and every typist types a few hundred words in a row.
    static func run(_ profile: Profile, typists: Int = 6, seed: UInt64 = 20261103, sentences: [String] = TypingCorpus.sentences,
                    pipelines: [Pipeline] = pipelines, recordFailures: Bool = false,
                    configure: ((Autocorrector) -> Void)? = nil) -> Run {
        var run = Run(profile: profile.name)
        let cache = TableCache()
        for t in 0..<typists {
            var rng = SplitMix(seed: seed &+ UInt64(t) &* 0x9E37_79B9)
            let typist = Typist(profile: profile, rng: &rng)
            let correctors = pipelines.map { _ in
                let corrector = Autocorrector(words: WordListTests.list)
                corrector.spaceBarLetters = spaceBarLetters
                configure?(corrector)
                return corrector
            }
            var adaptations = pipelines.map { _ in TouchAdaptation() }
            for (index, sentence) in sentences.enumerated() where index % typists == t {
                let typed = generate(sentence, typist: typist, rng: &rng)
                let raw = resolve(typed.taps, with: .nearest, cache: cache)
                let record = TypingScore.Sentence(intended: typed.intended, classes: typed.classes, tokens: raw.map(\.text))
                run.export.append(record)
                run.raw.add(record, output: raw.map(\.text))
                let intendedText = typed.intended.joined(separator: " ")
                run.characters += intendedText.count
                run.characterEdits += TypingScore.characterEdits(intendedText, raw.map(\.text).joined(separator: " "))
                for (p, pipeline) in pipelines.enumerated() {
                    let plain = !pipeline.resolver.dynamicTargets && pipeline.resolver.offsets == .none
                    let tokens = plain ? raw : resolve(typed.taps, with: pipeline.resolver, cache: cache, typist: typist, adaptation: adaptations[p])
                    var corrected: [String] = []
                    corrected.reserveCapacity(tokens.count)
                    for token in tokens {
                        if pipeline.timed {
                            let start = DispatchTime.now().uptimeNanoseconds
                            corrected.append(pipeline.correct(correctors[p], token))
                            run.evaluateNanos.append(DispatchTime.now().uptimeNanoseconds - start)
                        } else {
                            corrected.append(pipeline.correct(correctors[p], token))
                        }
                    }
                    if pipeline.resolver.offsets == .learned {
                        // As the keyboard does: only a word it recognizes teaches.
                        // As the keyboard does: a word it does not recognize keeps its low bottom-row taps out.
                        for (token, committed) in zip(tokens, corrected) {
                            adaptations[p].learn(typed: token.text, committed: committed, touches: token.raw,
                                                 recognized: correctors[p].recognizes(committed))
                        }
                    }
                    let output = words(corrected)
                    run.tallies[pipeline.name, default: TypingScore.Tally()].add(record, output: output)
                    if recordFailures {
                        let (matched, _) = TypingScore.align(intended: typed.intended, output: output)
                        let typedPairs = TypingScore.pairs(intended: typed.intended, output: tokens.map(\.text))
                        let outputPairs = TypingScore.pairs(intended: typed.intended, output: output)
                        for (i, ok) in matched.enumerated() where !ok {
                            let line = "\(typed.intended[i]) <- \(typedPairs[i].map { tokens[$0].text } ?? "-") -> \(outputPairs[i].map { output[$0] } ?? "-")"
                            run.failures[pipeline.name, default: [:]][typed.classes[i], default: []].append(line)
                        }
                    }
                }
            }
        }
        return run
    }

    /// Small, seeded and portable, so every run and every machine sees the same taps.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }
}
