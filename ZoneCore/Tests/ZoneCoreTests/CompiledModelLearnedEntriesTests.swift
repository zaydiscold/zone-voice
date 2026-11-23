// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// iOS 26.2's compile-cache descriptors name a content hash, not the model, so the janitor also
/// keeps the entries a model's own decode used (`CompiledModelCache.LearnedEntries`).
final class CompiledModelLearnedEntriesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The temporary directory is under /var, which resolves to /private/var, as an iOS data
        // container path does: the mapping must hold across that.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(CompiledModelCache.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func file(_ build: String, _ entry: String, _ name: String = "bnns_program.bnnsir") throws -> URL {
        let directory = root.appendingPathComponent("\(build)/\(entry)/\(entry)-key.bundle/H16S.bundle/main/main_bnns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func testFilesMapToTheirEntriesOnceEach() throws {
        let encoder = try file("23C54", "ENC")
        let encoderDescriptor = try file("23C54", "ENC", "H16S.e5")
        let decoder = try file("23C54", "DEC")
        let other = try file("22A100", "OLD")
        let learned = CompiledModelCache.LearnedEntries(files: [encoder, encoderDescriptor, decoder, other], root: root, osBuild: "23C54")
        XCTAssertEqual(learned.entries, ["ENC", "DEC"], "the other build's file is not this build's entry")
    }

    func testResolvedAndUnresolvedPathsAgree() throws {
        let resolved = try file("23C54", "ENC").resolvingSymlinksInPath()
        XCTAssertNotEqual(resolved.path, root.appendingPathComponent("23C54/ENC").path.replacingOccurrences(of: "/private", with: ""),
                          "precondition: the test exercises a symlinked prefix")
        let learned = CompiledModelCache.LearnedEntries(files: [resolved], root: root, osBuild: "23C54")
        XCTAssertEqual(learned.entries, ["ENC"])
    }

    func testOnlyEntriesStillPresentOnTheSameBuildCount() throws {
        let encoder = try file("23C54", "ENC")
        let decoder = try file("23C54", "DEC")
        let learned = CompiledModelCache.LearnedEntries(files: [encoder, decoder], root: root, osBuild: "23C54")
        try FileManager.default.removeItem(at: root.appendingPathComponent("23C54/DEC"))
        XCTAssertEqual(learned.existing(in: root, osBuild: "23C54").map(\.lastPathComponent), ["ENC"])
        XCTAssertTrue(learned.existing(in: root, osBuild: "23D10").isEmpty, "an iOS update recompiles; old entries are the sweep's")
        XCTAssertTrue(learned.existing(in: root, osBuild: nil).isEmpty)
    }

    func testFilesOutsideTheCacheAreIgnored() {
        let stray = URL(fileURLWithPath: "/tmp/elsewhere/bnns_program.bnnsir")
        XCTAssertTrue(CompiledModelCache.LearnedEntries(files: [stray], root: root, osBuild: "23C54").entries.isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        let learned = CompiledModelCache.LearnedEntries(files: [try file("23C54", "ENC")], root: root, osBuild: "23C54")
        let decoded = try JSONDecoder().decode(CompiledModelCache.LearnedEntries.self, from: JSONEncoder().encode(learned))
        XCTAssertEqual(decoded, learned)
    }
}
