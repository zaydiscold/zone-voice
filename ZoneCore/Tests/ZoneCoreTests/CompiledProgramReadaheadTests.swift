// by zayd/cold @ zayd.wtf

import Darwin
import XCTest
@testable import ZoneCore

final class CompiledProgramReadaheadTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(CompiledModelCache.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// `<root>/<build>/<entry>/<key>.bundle/H16S.bundle/main/main_bnns/bnns_program.bnnsir`, as Core ML lays it out.
    @discardableResult
    private func program(build: String = "23C54", entry: String, bytes: Int, name: String = "bnns_program.bnnsir") throws -> URL {
        let directory = root.appendingPathComponent(build).appendingPathComponent(entry)
            .appendingPathComponent("\(entry)-key.bundle/H16S.bundle/main/main_bnns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for index in stride(from: 0, to: raw.count, by: 4_096) { raw[index] = UInt8(truncatingIfNeeded: index / 4_096 + 1) }
        }
        try data.write(to: url)
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { fsync(fd); close(fd) }
        return url.resolvingSymlinksInPath()
    }

    /// Drops a file's pages from the file cache the way memory pressure does; skips the test where
    /// the file system cannot.
    private func evict(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        let size = Int(info.st_size)
        guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), base != MAP_FAILED else { throw XCTSkip("mmap failed") }
        defer { munmap(base, size) }
        msync(base, size, MS_INVALIDATE)
        let resident = CompiledProgramReadahead.residency(of: [url])[url] ?? 1
        if resident > 0.5 { throw XCTSkip("this file system kept the pages (\(resident) resident)") }
    }

    private func resolved(_ urls: [URL]) -> [String] { urls.map { $0.resolvingSymlinksInPath().path } }

    func testFindsLargeProgramFilesOfTheRunningBuildLargestFirst() throws {
        let small = try program(entry: "B", bytes: 2 << 20)
        let large = try program(entry: "A", bytes: 3 << 20)
        try program(entry: "C", bytes: 64 << 10) // under the floor
        try program(build: "22A100", entry: "D", bytes: 4 << 20) // another iOS build
        XCTAssertEqual(resolved(CompiledProgramReadahead.programFiles(cacheRoot: root, osBuild: "23C54")), [large.path, small.path])
        XCTAssertEqual(CompiledProgramReadahead.programFiles(cacheRoot: root, osBuild: nil).count, 3)
    }

    func testSkipsUnfinishedCompilesAndSymbolicLinks() throws {
        try program(entry: "E.tmp.123", bytes: 2 << 20)
        let real = try program(entry: "F", bytes: 2 << 20)
        let link = real.deletingLastPathComponent().appendingPathComponent("link.bnnsir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(resolved(CompiledProgramReadahead.programFiles(cacheRoot: root, osBuild: "23C54")), [real.path])
    }

    func testMissingCacheFindsNothingAndReadsNothing() {
        let missing = root.appendingPathComponent("nope")
        XCTAssertTrue(CompiledProgramReadahead.programFiles(cacheRoot: missing, osBuild: nil).isEmpty)
        let report = CompiledProgramReadahead.read([missing.appendingPathComponent("x.bnnsir")])
        XCTAssertEqual(report.files, 0)
        XCTAssertEqual(report.bytesRead, 0)
        XCTAssertTrue(CompiledProgramReadahead.residency(of: [missing]).isEmpty)
    }

    func testAResidentProgramCostsOnlyAScan() throws {
        let file = try program(entry: "G", bytes: 6 << 20 + 123)
        _ = CompiledProgramReadahead.read([file])
        let report = CompiledProgramReadahead.read([file])
        XCTAssertEqual(report.files, 1)
        XCTAssertEqual(report.bytes, Int64(6 << 20 + 123))
        XCTAssertEqual(report.bytesRead, 0)
        XCTAssertEqual(report.bytesInMemory, Int64(6 << 20 + 123))
    }

    func testAnEvictedProgramIsReadBackWhole() throws {
        let file = try program(entry: "H", bytes: 8 << 20 + 5)
        try evict(file)
        let report = CompiledProgramReadahead.read([file], chunkBytes: 1 << 20, concurrency: 3)
        // Not `bytesRead == size`: reading chunks in order makes the kernel read ahead, so a later
        // chunk (or the 5-byte tail) is often in memory before its turn and is rightly skipped.
        // That assertion failed about one run in four with nothing else running. What must hold:
        // every chunk, the short last one included, was read or found in memory, something was
        // read, and the whole file is in memory afterwards.
        XCTAssertEqual(report.bytesRead + report.bytesInMemory, Int64(8 << 20 + 5), "every chunk is accounted for")
        XCTAssertGreaterThanOrEqual(report.bytesRead, Int64(1 << 20), "an evicted file is read, not skipped")
        XCTAssertEqual(CompiledProgramReadahead.residency(of: [file])[file] ?? 0, 1, accuracy: 0.001)
    }

    func testOddChunkSizesAndMoreWorkersThanChunksStillCoverTheFile() throws {
        let file = try program(entry: "I", bytes: 3 << 20)
        try evict(file)
        let report = CompiledProgramReadahead.read([file], chunkBytes: 1_000_000, concurrency: 64)
        XCTAssertEqual(report.bytesRead + report.bytesInMemory, Int64(3 << 20))
        XCTAssertGreaterThan(report.bytesRead, 0)
        XCTAssertEqual(CompiledProgramReadahead.residency(of: [file])[file] ?? 0, 1, accuracy: 0.001)
    }

    func testLearnsOnlyTheFilesInMemoryAndHonorsExclusions() throws {
        let used = try program(entry: "J", bytes: 2 << 20)
        let other = try program(entry: "K", bytes: 2 << 20)
        let idle = try program(entry: "L", bytes: 2 << 20)
        try evict(idle)
        _ = CompiledProgramReadahead.read([used, other])

        let program = CompiledProgramReadahead.Program(cacheRoot: root, osBuild: "23C54")
        XCTAssertNil(program.prefetch(), "nothing to read before learning")
        XCTAssertEqual(Set(resolved(program.learn())), Set([used.path, other.path]))
        XCTAssertEqual(resolved(program.learn(excluding: Set(CompiledProgramReadahead.programFiles(cacheRoot: root, osBuild: "23C54")
            .filter { $0.resolvingSymlinksInPath().path == other.path }))), [used.path])

        try evict(used)
        let report = try XCTUnwrap(program.prefetch())
        XCTAssertEqual(report.bytesRead + report.bytesInMemory, Int64(2 << 20))
        XCTAssertGreaterThan(report.bytesRead, 0)
        XCTAssertEqual(CompiledProgramReadahead.residency(of: [used])[used] ?? 0, 1, accuracy: 0.001)
    }

    func testNoCacheRootTurnsItOff() {
        let program = CompiledProgramReadahead.Program(cacheRoot: nil, osBuild: nil)
        XCTAssertTrue(program.learn().isEmpty)
        XCTAssertNil(program.prefetch())
    }

    func testAFileRemovedAfterLearningIsSkipped() throws {
        let file = try program(entry: "M", bytes: 2 << 20)
        let program = CompiledProgramReadahead.Program(cacheRoot: root, osBuild: "23C54")
        XCTAssertEqual(program.learn().count, 1)
        try FileManager.default.removeItem(at: file)
        let report = try XCTUnwrap(program.prefetch())
        XCTAssertEqual(report.files, 0)
        XCTAssertEqual(report.bytesRead, 0)
    }
}
