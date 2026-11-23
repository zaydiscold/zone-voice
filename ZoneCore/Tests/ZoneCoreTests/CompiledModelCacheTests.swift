// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CompiledModelCacheTests: XCTestCase {
    private let current = "3CFA16C6-C447-4EFF-A585-1984101E0CAE"
    private let old = "597A33B5-9E6F-4795-BD95-621514BDF8C7"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("compiled-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(CompiledModelCache.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// The shape of a real H16.e5 from the phone: a binary header, then the source path as text.
    private func descriptor(container: String) -> Data {
        var data = Data([0x14, 0, 0, 0, 0, 0, 0, 0, 0x0c, 0, 0x14, 0, 0x04, 0, 0x08, 0])
        data += Data("espressoc-version\0".utf8)
        data += Data("/private/var/mobile/Containers/Data/Application/\(container)/Library/Application Support/Models/fluid-speech-mini-coreml/Encoder.mlmodelc/model.mil\0".utf8)
        data += Data("input-file-path\0main_bnns\0".utf8)
        return data
    }

    @discardableResult
    private func entry(build: String = "24A5390f", key: String, bundle: String? = nil, container: String?,
                       modified: Date? = nil) throws -> URL {
        let entry = root.appendingPathComponent(build).appendingPathComponent(key)
        let bundleURL = entry.appendingPathComponent(bundle ?? "\(key)-final.bundle")
        let arch = bundleURL.appendingPathComponent("H16.bundle")
        try FileManager.default.createDirectory(at: arch.appendingPathComponent("main/main_bnns"), withIntermediateDirectories: true)
        if let container { try descriptor(container: container).write(to: arch.appendingPathComponent("H16.e5")) }
        try Data(count: 64).write(to: arch.appendingPathComponent("main/main_bnns/bnns_program.bnnsir"))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: bundleURL.path)
        }
        return entry
    }

    private func stale(build: String? = "24A5390f", now: Date = Date()) -> Set<String> {
        Set(CompiledModelCache.staleEntries(in: root, currentContainerID: current, currentOSBuild: build, now: now)
            .map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: root.path + "/", with: "") })
    }

    func testDeletingOneModelFindsItsCurrentAndOldContainerCompilesOnly() throws {
        let a = try entry(key: "CURRENT", container: current)
        let b = try entry(key: "OLD", container: old)
        _ = try entry(key: "UNKNOWN", container: nil)
        let other = try entry(key: "OTHER", container: current)
        let mixed = try entry(key: "MIXED", container: current)
        let different = Data("/Library/Application Support/Models/another-model/Encoder.mlmodelc/model.mil".utf8)
        try different.write(to: other.appendingPathComponent("OTHER-final.bundle/H16.bundle/H16.e5"))
        try different.write(to: mixed.appendingPathComponent("MIXED-final.bundle/H16.bundle/other.e5"))
        let model = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(current)/Library/Application Support/Models/fluid-speech-mini-coreml")
        XCTAssertEqual(Set(CompiledModelCache.entries(in: root, forModelDirectory: model).map { $0.resolvingSymlinksInPath().path }), Set([a, b].map { $0.resolvingSymlinksInPath().path }))
        for url in CompiledModelCache.entries(in: root, forModelDirectory: model) {
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixed.path))
        XCTAssertTrue(CompiledModelCache.entries(in: root, forModelDirectory: model).isEmpty)
    }

    func testModelDirectoryPrefixDoesNotMatchAnotherModelsName() throws {
        _ = try entry(key: "FLUID", container: current)
        let model = URL(fileURLWithPath: "/Library/Application Support/Models/fluid-speech-mini")
        XCTAssertTrue(CompiledModelCache.entries(in: root, forModelDirectory: model).isEmpty)
    }

    func testContainerIDComesFromTheDataContainerPath() {
        XCTAssertEqual(CompiledModelCache.containerID(inPath: "/private/var/mobile/Containers/Data/Application/\(current.lowercased())/Library"), current)
        XCTAssertEqual(CompiledModelCache.containerID(inPath: "/Users/z/Library/Developer/CoreSimulator/Devices/X/data/Containers/Data/Application/\(old)"), old)
        XCTAssertNil(CompiledModelCache.containerID(inPath: "/private/var/mobile/Containers/Shared/AppGroup/\(old)/x"))
        XCTAssertNil(CompiledModelCache.containerID(inPath: "/private/var/mobile/Containers/Data/Application/not-a-uuid/x"))
    }

    func testDescriptorNamesTheModelsContainer() {
        XCTAssertEqual(CompiledModelCache.containerIDs(inDescriptor: descriptor(container: old)), [old])
        XCTAssertEqual(CompiledModelCache.containerIDs(inDescriptor: Data("no path here".utf8)), [])
    }

    func testOSBuildFromTheVersionString() {
        XCTAssertEqual(CompiledModelCache.osBuild(fromVersionString: "Version 27.0 (Build 24A5390f)"), "24A5390f")
        XCTAssertEqual(CompiledModelCache.osBuild(fromVersionString: "Version 26.2 (Build 23C54)"), "23C54")
        XCTAssertNil(CompiledModelCache.osBuild(fromVersionString: "Version 27.0"))
    }

    func testOnlyCompilesForAnotherContainerAreStale() throws {
        try entry(key: "CURRENT", container: current)
        try entry(key: "OLD1", container: old)
        try entry(key: "OLD2", container: "4B20B629-046C-ABD3-FE17-6413F8B52F85")
        XCTAssertEqual(stale(), ["24A5390f/OLD1", "24A5390f/OLD2"])
    }

    func testUnreadableOrUnnamedEntriesAreKept() throws {
        try entry(key: "NODESCRIPTOR", container: nil)
        XCTAssertEqual(stale(), [])
    }

    func testAnotherOSBuildIsStaleAsAWhole() throws {
        try entry(build: "24A5380a", key: "BEFOREUPDATE", container: current)
        try entry(key: "CURRENT", container: current)
        XCTAssertEqual(stale(), ["24A5380a"])
        XCTAssertEqual(stale(build: nil), [], "an unknown OS build deletes nothing by build")
    }

    func testAbandonedCompilesGoAfterAnHourAndRunningOnesStay() throws {
        let now = Date()
        try entry(key: "OLDTMP", bundle: "X.tmp.952_4362673344.bundle", container: nil, modified: now.addingTimeInterval(-7_200))
        try entry(key: "LIVETMP", bundle: "Y.tmp.1251_4601712384.bundle", container: old, modified: now.addingTimeInterval(-60))
        let mixed = try entry(key: "MIXED", container: current)
        try entry(key: "MIXED", bundle: "Z.tmp.1_2.bundle", container: nil, modified: now.addingTimeInterval(-7_200))
        XCTAssertEqual(stale(now: now), ["24A5390f/OLDTMP", "24A5390f/MIXED/Z.tmp.1_2.bundle"],
                       "a compile from the last hour may still be running, even for an old container")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixed.path))
    }

    func testWithoutAKnownContainerOnlyAbandonedCompilesGo() throws {
        try entry(key: "OLD", container: old)
        let found = CompiledModelCache.staleEntries(in: root, currentContainerID: nil, currentOSBuild: "24A5390f")
        XCTAssertEqual(found, [])
    }
}
