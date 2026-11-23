// by zayd/cold @ zayd.wtf

import Darwin
import Foundation
import XCTest
@testable import ZoneCore

/// Measurements behind docs/research/2026-11-18-lexicon-and-history-perf.md. Skipped unless
/// `ZONE_PERF=1`, so the ordinary suite stays fast; `scripts/perf/lexicon-history-bench.sh` runs
/// them, the cold-load one in a fresh process per sample. Each prints `PERF {json}` lines.
final class LexiconHistoryPerfTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["ZONE_PERF"] != nil else {
            throw XCTSkip("set ZONE_PERF=1 to run the lexicon and history measurements")
        }
    }

    /// The probe itself: a 32 MB buffer written and freed inside a step shows in its peak and
    /// not in what it retains.
    func testPeakProbeSeesATransientBuffer() throws {
        // Straight from the kernel: malloc keeps freed large blocks dirty for reuse.
        let size = 32 * 1_048_576
        let first = Probe().measure("probe.selfcheck") {
            let buffer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
            for offset in stride(from: 0, to: size, by: 4_096) { buffer.storeBytes(of: UInt8(1), toByteOffset: offset, as: UInt8.self) }
            munmap(buffer, size)
        }
        first.print()
        XCTAssertGreaterThan(first.peakKB, 30 * 1024)
        XCTAssertLessThan(first.retainedKB, 4 * 1024)
        // The reset works: a step after it does not inherit the earlier peak.
        let second = Probe().measure("probe.afterReset") {}
        second.print()
        XCTAssertLessThan(second.peakKB, 4 * 1024)
    }

    // MARK: Lexicon

    /// The first lexicon load in this process, as the keyboard pays it: time, the peak footprint
    /// it adds, and what stays. Run once per fresh process (the script does).
    func testColdLexiconLoad() throws {
        let probe = Probe()
        var words: WordList?
        let list = probe.measure("wordList.loadBundled") { words = WordList.loadBundled() }
        let loaded = try XCTUnwrap(words)
        let pairsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZoneKeyboard/Resources/en-pairs.bin")
        var pairs: WordPairs?
        let pairStep = probe.measure("wordPairs.init") { pairs = WordPairs(url: pairsURL, words: loaded) }
        var decoder: SwipeDecoder?
        let decoderStep = probe.measure("swipeDecoder.init") { decoder = SwipeDecoder(words: loaded, context: pairs) }
        var corrector: Autocorrector?
        let correctorStep = probe.measure("autocorrector.init") { corrector = Autocorrector(words: loaded) }
        let firstNames = probe.measure("firstNames") { _ = SpokenMentions.firstNames.count }
        let givenNames = probe.measure("givenNames") { _ = TextStyle.givenNames.count }
        var emoji: EmojiCatalog?
        let emojiStep = probe.measure("emojiCatalog") { emoji = EmojiCatalog.loadBundled() }
        var neural: SwipeNeuralScorer?
        let neuralStep = probe.measure("swipeNeural.init") { neural = SwipeNeuralScorer() }
        for step in [list, pairStep, decoderStep, correctorStep, firstNames, givenNames, emojiStep, neuralStep] { step.print() }
        withExtendedLifetime((loaded, pairs, decoder, corrector, emoji, neural)) {}
    }

    /// The parse alone, repeated in one process (file pages already resident): the floor for
    /// what a precomputed table could save in CPU.
    func testWarmLexiconParse() throws {
        let url = try XCTUnwrap(Bundle.zoneSwipeResources.url(forResource: "en-words", withExtension: "txt"))
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let ranks = try Data(contentsOf: XCTUnwrap(Bundle.zoneSwipeResources.url(forResource: "chat-ranks", withExtension: "txt")))
        var samples: [Double] = []
        var cpu: [Double] = []
        for _ in 0..<31 {
            let start = DispatchTime.now().uptimeNanoseconds
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let list = WordList(data: data, rankOverrides: ranks)
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            XCTAssertNotNil(list)
        }
        Probe.emit(["name": "wordList.parse.warm", "n": samples.count, "medianMs": Probe.median(samples),
                    "minMs": samples.min() ?? 0, "maxMs": samples.max() ?? 0, "medianCpuMs": Probe.median(cpu)])
    }

    // MARK: History

    /// Load, search and save costs of `TranscriptHistory` at realistic library sizes. Sizes come
    /// from `ZONE_PERF_SIZES` (comma separated), 2,000, 10,000 and 50,000 by default.
    func testHistoryScaling() throws {
        let sizes = (ProcessInfo.processInfo.environment["ZONE_PERF_SIZES"] ?? "2000,10000,50000")
            .split(separator: ",").compactMap { Int($0) }
        for size in sizes { try measureHistory(records: size) }
    }

    /// What the keyboard's own history work adds to its footprint, measured as the first thing
    /// in a fresh process (an earlier decode leaves freed pages the next one reuses). The file
    /// comes from `ZONE_PERF_HISTORY_FILE`, written by `SyntheticLibrary.write` (the script does).
    func testKeyboardHistoryFootprint() throws {
        let source = try XCTUnwrap(ProcessInfo.processInfo.environment["ZONE_PERF_HISTORY_FILE"], "set ZONE_PERF_HISTORY_FILE")
        let operation = ProcessInfo.processInfo.environment["ZONE_PERF_HISTORY_OP"] ?? "mark"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zone-history-footprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: directory.appendingPathComponent("history.json"))
        // As the keyboard has it: no decode kept between reads.
        let history = TranscriptHistory(directory: directory, keepsDecodedFile: false)
        let bytes = try FileManager.default.attributesOfItem(atPath: source)[.size] as? Int ?? 0
        let step: Probe.Step
        switch operation {
        case "codec":
            // Where a save's time and memory go: the decode, then the encode of the same file.
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var file = TranscriptHistory.File()
            let decode = Probe().measure("history.decode") { file = try! decoder.decode(TranscriptHistory.File.self, from: data) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var bytes = 0
            let chunked = ProcessInfo.processInfo.environment["ZONE_PERF_CHUNKED"] != nil
            let encode = Probe().measure("history.encode") {
                if chunked {
                    // One record at a time into one buffer: no tree of the whole library.
                    var out = Data("{\"retention\":\"untilDeleted\",\"retentionChosen\":true,\"records\":[".utf8)
                    for (index, record) in file.records.enumerated() {
                        if index > 0 { out.append(0x2C) }
                        out.append(try! encoder.encode(record))
                    }
                    out.append(contentsOf: Array("]}".utf8))
                    bytes = out.count
                } else {
                    bytes = try! encoder.encode(file).count
                }
            }
            Probe.emit(["name": "history.decode", "fileBytes": data.count, "ms": decode.ms, "cpuMs": decode.cpuMs, "peakKB": decode.peakKB, "retainedKB": decode.retainedKB])
            Probe.emit(["name": "history.encode", "fileBytes": bytes, "ms": encode.ms, "cpuMs": encode.cpuMs, "peakKB": encode.peakKB, "retainedKB": encode.retainedKB])
            return
        case "panel":
            step = Probe().measure("history.keyboardPanel") {
                history.recoverCutOff()
                _ = history.recent(limit: 50)
                _ = history.retention
            }
        default:
            // The id of the newest record, read without decoding the whole file through the store.
            let raw = try Data(contentsOf: URL(fileURLWithPath: source))
            let marker = Data("\"id\":\"".utf8)
            let found = try XCTUnwrap(raw.range(of: marker))
            let id = try XCTUnwrap(UUID(uuidString: String(decoding: raw[found.upperBound..<(found.upperBound + 36)], as: UTF8.self)))
            step = Probe().measure("history.keyboardMark") { history.mark(id: id, status: .inserted) }
        }
        Probe.emit(["name": step.name, "fileBytes": bytes, "ms": step.ms, "cpuMs": step.cpuMs, "peakKB": step.peakKB, "retainedKB": step.retainedKB, "heapKB": step.heapKB])
    }

    /// Writes the synthetic libraries the footprint test reads: `ZONE_PERF_WRITE_DIR`/history-N.json.
    func testWriteSyntheticLibraries() throws {
        let folder = try XCTUnwrap(ProcessInfo.processInfo.environment["ZONE_PERF_WRITE_DIR"], "set ZONE_PERF_WRITE_DIR")
        let sizes = (ProcessInfo.processInfo.environment["ZONE_PERF_SIZES"] ?? "2000,10000,50000")
            .split(separator: ",").compactMap { Int($0) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for size in sizes {
            try SyntheticLibrary.write(count: size, now: Date(), to: URL(fileURLWithPath: folder).appendingPathComponent("history-\(size).json"))
        }
    }


    private func measureHistory(records count: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zone-history-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let fileURL = directory.appendingPathComponent("history.json")
        let library = try SyntheticLibrary.write(count: count, now: now, to: fileURL)
        let history = TranscriptHistory(directory: directory)
        func size() -> Int { (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0 }
        let fileBytes = size()
        let words = library.reduce(0) { $0 + $1.wordCount }
        let sortedWords = library.map(\.wordCount).sorted()
        let runs = count >= 50_000 ? 5 : 9
        var report: [String: Any] = [
            "name": "history", "records": count, "fileBytes": fileBytes, "bytesPerRecord": fileBytes / max(count, 1),
            "words": words, "meanWords": Double(words) / Double(count), "medianWords": sortedWords[sortedWords.count / 2],
            "runs": runs,
        ]
        // Wall time and this thread's CPU time: the CPU time holds up when the Mac is busy with
        // other work, the wall time includes waiting for the disk and for a core.
        var samples: [String: (wall: [Double], cpu: [Double])] = [:]
        func sample(_ name: String, _ body: () -> Void) {
            let wall = DispatchTime.now().uptimeNanoseconds
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            body()
            samples[name, default: ([], [])].wall.append(Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e6)
            samples[name, default: ([], [])].cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6)
        }
        func repeated(_ name: String, _ body: () -> Void) {
            for _ in 0..<runs { sample(name, body) }
        }

        repeated("records") { XCTAssertEqual(history.records(now: now).count, count) }
        repeated("retention") { XCTAssertEqual(history.retention, .untilDeleted) }
        // HistoryView's poll, once a second while it is open.
        repeated("historyViewPoll") { _ = (history.records(now: now), history.retention) }
        // A read right after a write (the first after the other process saved): a full decode.
        repeated("recordsCold") { history.forgetSnapshot(); _ = history.records(now: now) }
        // The keyboard's History panel: recover, the newest 50, and the retention. The keyboard
        // keeps no decode between reads.
        let keyboard = TranscriptHistory(directory: directory, keepsDecodedFile: false)
        repeated("keyboardPanel") {
            keyboard.recoverCutOff(now: now)
            _ = keyboard.recent(limit: 50, now: now)
            _ = keyboard.retention
        }
        let phrase = "tomorrow morning"
        repeated("search") { _ = history.search(phrase, now: now) }
        let loaded = history.records(now: now)
        repeated("filterLoaded") { _ = loaded.filter { $0.text.localizedCaseInsensitiveContains(phrase) } }

        // One keyboard dictation across both processes: the app begins it, saves progress every
        // 5 s and finishes it; the keyboard marks it inserted; then the app's observers of
        // ZoneLibraryDidChange read it back (Zone Link's library read and the Watch share cache).
        // Progress must stay small whatever the library's size.
        let app = history
        var progressBytes = 0
        var finishWritten = 0
        for round in 0..<runs {
            let id = UUID()
            sample("dictationFlow") {
                app.begin(id: id, engine: "parakeet", source: .keyboard, now: now)
                for step in 1...3 {
                    sample("saveProgress") {
                        app.saveProgress(id: id, text: String(repeating: "word ", count: step * 10), audioSeconds: Double(step * 5), now: now)
                    }
                }
                let inflight = directory.appendingPathComponent("inflight/\(id.uuidString).json")
                progressBytes = (try? FileManager.default.attributesOfItem(atPath: inflight.path)[.size] as? Int) ?? 0
                sample("finish") {
                    XCTAssertTrue(app.finish(id: id, text: "Round \(round) of the save measurement, about twenty words long like a real message to a friend.", audioSeconds: 12, now: now))
                }
                finishWritten = size()
                sample("keyboardMark") { keyboard.mark(id: id, status: .inserted, now: now) }
                sample("observers") {
                    XCTAssertEqual(app.records(now: now).first?.status, .inserted)
                    _ = app.recent(limit: 40, now: now)
                }
            }
        }
        report["saveProgressBytes"] = progressBytes
        report["finishBytesWritten"] = finishWritten
        report["markBytesWritten"] = size()

        // A change that changes nothing, as `purgeExpired` is at every app launch with Until I
        // delete: is the file rewritten? Another process wrote the file last: same records, its
        // own key order.
        let foreign = JSONEncoder()
        foreign.dateEncodingStrategy = .iso8601
        foreign.outputFormatting = [.sortedKeys]
        var current = TranscriptHistory.File()
        current.retention = .untilDeleted
        current.retentionChosen = true
        current.records = history.records(now: now)
        try foreign.encode(current).write(to: fileURL, options: .atomic)
        let foreignID = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? Int
        repeated("noopPurge") { history.purgeExpired(now: now) }
        let afterID = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? Int
        report["noopPurgeRewroteForeignFile"] = foreignID != afterID

        for (name, values) in samples {
            report[name + "Ms"] = Probe.median(values.wall)
            report[name + "CpuMs"] = Probe.median(values.cpu)
        }
        // Footprint is measured per fresh process in testKeyboardHistoryFootprint: here an
        // earlier decode's freed pages would hide it.
        Probe.emit(report)
    }
}

/// Deterministic dictations shaped like Zayd's library (2,040 dictations, 40,180 words on
/// 2026-11-18: mostly short keyboard messages, a few long ones), drawn from the word list's
/// commonest words so text length and character mix are realistic. No real text is used.
enum SyntheticLibrary {
    /// A history file of `count` synthetic records with Until I delete, as the app writes it.
    @discardableResult
    static func write(count: Int, now: Date, to url: URL) throws -> [TranscriptRecord] {
        let library = records(count: count, now: now)
        var file = TranscriptHistory.File()
        file.retention = .untilDeleted
        file.retentionChosen = true
        file.records = library
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url, options: .atomic)
        return library
    }

    static func records(count: Int, now: Date, seed: UInt64 = 0x5EED) -> [TranscriptRecord] {
        var rng = SplitMix(seed)
        let vocabulary = commonWords
        var records: [TranscriptRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let roll = rng.next() % 1000
            let words: Int
            if roll < 5 { words = 300 + Int(rng.next() % 400) }        // 0.5%: long app dictations and notes
            else if roll < 35 { words = 40 + Int(rng.next() % 80) }    // 3%: long messages
            else { words = 3 + Int(rng.next() % 30) }                  // the rest: 3 to 32 words
            var text = ""
            var sentence = 0
            for w in 0..<words {
                var word = vocabulary[Int(rng.next() % UInt64(vocabulary.count))]
                if sentence == 0 { word = word.prefix(1).uppercased() + word.dropFirst() }
                text += word
                sentence += 1
                if w == words - 1 { text += "." }
                else if sentence >= 8, rng.next() % 4 == 0 { text += ". "; sentence = 0 }
                else if rng.next() % 12 == 0 { text += ", " }
                else { text += " " }
            }
            let created = now.addingTimeInterval(-Double(index) * 432 - 60) // about 200 a day
            let source: TranscriptSource = roll < 3 ? .app : (rng.next() % 100 < 7 ? .note : .keyboard)
            let id = UUID(uuid: uuid(&rng))
            records.append(TranscriptRecord(id: id, text: text, createdAt: created,
                                            updatedAt: created.addingTimeInterval(Double(words) / 2 + 1),
                                            audioSeconds: Double(words) / 2.5, engine: "parakeet", source: source,
                                            status: source == .note ? .note : .inserted))
        }
        return records
    }

    private static let commonWords: [String] = {
        var words: [String] = []
        WordList.shared?.visitEntries { _, bytes, rank, suggestible in
            guard rank < 5_000, suggestible else { return }
            words.append(String(decoding: bytes, as: UTF8.self))
        }
        return words
    }()

    private static func uuid(_ rng: inout SplitMix) -> uuid_t {
        let a = rng.next(), b = rng.next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (UInt64(i) * 8)); bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (UInt64(i) * 8)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
    }
}

struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Footprint as jetsam counts it (`phys_footprint`), the peak over an interval, and the malloc
/// heap in use. The interval peak is reset through `proc_rlimit_control`, the call behind
/// `RLIMIT_FOOTPRINT_INTERVAL` in <sys/resource.h>.
struct Probe {
    struct Step {
        let name: String
        let ms: Double
        /// This thread's CPU time, which a busy Mac inflates far less than wall time.
        let cpuMs: Double
        /// Footprint growth that stays while the result is alive.
        let retainedKB: Int
        /// Highest footprint during the step, above where it started.
        let peakKB: Int
        /// Malloc heap growth that stays.
        let heapKB: Int

        func print() {
            Probe.emit(["name": name, "ms": ms, "cpuMs": cpuMs, "retainedKB": retainedKB, "peakKB": peakKB, "heapKB": heapKB])
        }
    }

    func measure(_ name: String, _ body: () -> Void) -> Step {
        Self.resetPeak()
        let footprint = MemoryFootprint.current() ?? 0
        let heap = Self.heapInUse()
        let start = DispatchTime.now().uptimeNanoseconds
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        let cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        let peak = Self.peakFootprint()
        let after = MemoryFootprint.current() ?? 0
        let heapAfter = Self.heapInUse()
        return Step(name: name, ms: ms, cpuMs: cpuMs,
                    retainedKB: (Int(after) - Int(footprint)) / 1024,
                    peakKB: (Int(max(peak, after)) - Int(footprint)) / 1024,
                    heapKB: (Int(heapAfter) - Int(heap)) / 1024)
    }

    static func resetPeak() {
        _ = proc_rlimit_control(getpid(), 0x4 /* RLIMIT_FOOTPRINT_INTERVAL */, UnsafeMutableRawPointer(bitPattern: 0x1) /* FOOTPRINT_INTERVAL_RESET */)
    }

    static func peakFootprint() -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_interval_max_phys_footprint : 0
    }

    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func emit(_ fields: [String: Any]) {
        let rounded = fields.mapValues { value -> Any in
            if let double = value as? Double { return (double * 1000).rounded() / 1000 }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rounded, options: [.sortedKeys]) else { return }
        Swift.print("PERF " + String(decoding: data, as: UTF8.self))
    }
}

@_silgen_name("proc_rlimit_control")
private func proc_rlimit_control(_ pid: pid_t, _ flavor: Int32, _ arg: UnsafeMutableRawPointer?) -> Int32
