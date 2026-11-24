// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

final class WorkerHealthTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let phone = WorkerHealth.Build(app: "2026112251", os: "24A5390f")

    override func setUp() {
        suite = "zone-worker-health-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOneEndedHelperIsRememberedForThisAppBuildAndSystemBuild() throws {
        XCTAssertNil(WorkerHealth.block(in: defaults, build: phone))
        let at = Date(timeIntervalSince1970: 1_795_374_000)
        WorkerHealth.remember(.ended, stage: "warm", limitMB: 35, in: defaults, build: phone, now: at)
        let block = try XCTUnwrap(WorkerHealth.block(in: defaults, build: phone))
        XCTAssertEqual(block, .init(reason: .ended, stage: "warm", limitMB: 35, build: phone, at: at))
        XCTAssertEqual(block.fields["helperBlock"], "ended")
        XCTAssertEqual(block.fields["helperStage"], "warm")
        XCTAssertEqual(block.fields["helperLimitMB"], "35")
        XCTAssertEqual(block.fields["helperBlockedBuild"], "2026112251")
        XCTAssertEqual(block.fields["helperBlockedOS"], "24A5390f")
        // Still there for a second reader, such as the keyboard after the app wrote it.
        XCTAssertNotNil(WorkerHealth.block(in: UserDefaults(suiteName: suite), build: phone))
    }

    func testANewAppBuildGetsOneNewTry() {
        WorkerHealth.remember(.ended, stage: "recognize", in: defaults, build: phone)
        XCTAssertNil(WorkerHealth.block(in: defaults, build: .init(app: "2026112301", os: "24A5390f")))
        // Forgotten, not only hidden: going back to the old build number does not bring it back.
        XCTAssertNil(WorkerHealth.block(in: defaults, build: phone))
        XCTAssertNil(defaults.data(forKey: WorkerHealth.key))
    }

    func testANewSystemBuildGetsOneNewTry() {
        WorkerHealth.remember(.tooLittleRoom, limitMB: 35, in: defaults, build: phone)
        XCTAssertNil(WorkerHealth.block(in: defaults, build: .init(app: "2026112251", os: "24B77")))
        XCTAssertNil(defaults.data(forKey: WorkerHealth.key))
    }

    func testForgetClearsItAndUnreadableDataIsDropped() {
        WorkerHealth.remember(.ended, in: defaults, build: phone)
        WorkerHealth.forget(in: defaults)
        XCTAssertNil(WorkerHealth.block(in: defaults, build: phone))
        defaults.set(Data("not a record".utf8), forKey: WorkerHealth.key)
        XCTAssertNil(WorkerHealth.block(in: defaults, build: phone))
        XCTAssertNil(defaults.data(forKey: WorkerHealth.key))
    }

    func testThePhonesThirtyFiveMegabytesIsTooLittleAndNoLimitIsAllowed() {
        XCTAssertFalse(WorkerHealth.hasRoom(limitBytes: 35 * 1_048_576))
        XCTAssertFalse(WorkerHealth.hasRoom(limitBytes: UInt64(WorkerHealth.neededMB) * 1_048_576 - 1))
        XCTAssertTrue(WorkerHealth.hasRoom(limitBytes: UInt64(WorkerHealth.neededMB) * 1_048_576))
        XCTAssertTrue(WorkerHealth.hasRoom(limitBytes: nil), "the simulator reports no limit")
    }

    func testOnlyAnAnswerLostOnScreenOnARealPhoneCountsAsEnded() {
        XCTAssertTrue(WorkerHealth.countsAsEnded(waitingOn: "warm", hostVisible: true, deviceEnforcesLimits: true))
        XCTAssertFalse(WorkerHealth.countsAsEnded(waitingOn: nil, hostVisible: true, deviceEnforcesLimits: true),
                       "an idle helper that goes away was not ended for its size")
        XCTAssertFalse(WorkerHealth.countsAsEnded(waitingOn: "warm", hostVisible: false, deviceEnforcesLimits: true),
                       "a hidden keyboard can lose its helper with it")
        XCTAssertFalse(WorkerHealth.countsAsEnded(waitingOn: "warm", hostVisible: true, deviceEnforcesLimits: false),
                       "the simulator has no limit to be ended for")
    }

    // MARK: The helper's cache

    private func makeCache() throws -> (root: URL, key: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("wtf.zayd.zone.recognition/com.apple.e5rt.e5bundlecache")
        let key = root.appendingPathComponent("24A5390f/8F3F925FAF15")
        // The names found on the iPhone on November 22, 2026.
        let sizes = ["530DF380D917.bundle": 1200, "530DF380D917.tmp.2340_4362571008.bundle": 1100,
                     "530DF380D917.tmp.2344_4341599488.bundle": 1000]
        for (name, size) in sizes {
            let folder = key.appendingPathComponent(name + "/H16.bundle/main/main_bnns")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: size).write(to: folder.appendingPathComponent("bnns_program.bnnsir"))
        }
        return (root, key)
    }

    func testCleanupRetriesUntilCleanAndRechecksEachBuild() {
        XCTAssertTrue(WorkerStorage.needsTidy(in: defaults, build: phone))
        WorkerStorage.markTidied(in: defaults, build: phone)
        XCTAssertFalse(WorkerStorage.needsTidy(in: defaults, build: phone))
        WorkerStorage.markDirty(in: defaults)
        XCTAssertTrue(WorkerStorage.needsTidy(in: defaults, build: phone))
        WorkerStorage.markTidied(in: defaults, build: phone)
        XCTAssertTrue(WorkerStorage.needsTidy(in: defaults, build: .init(app: "next", os: phone.os)))
    }

    func testCacheContentsSeparateStrandedCopiesFromTheFinishedProgram() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.root.deletingLastPathComponent().deletingLastPathComponent()) }
        let contents = WorkerStorage.contents(of: cache.root)
        XCTAssertEqual(contents, .init(finishedBytes: 1200, strandedBytes: 2100, strandedCopies: 2))
        XCTAssertEqual(try WorkerStorage.sweepTemporaryPrograms(in: cache.root), 2)
        XCTAssertEqual(WorkerStorage.contents(of: cache.root), .init(finishedBytes: 1200, strandedBytes: 0, strandedCopies: 0))
    }

    func testRemoveEverythingTakesTheFinishedProgramAndItsReceiptToo() throws {
        let cache = try makeCache()
        let container = cache.root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: container.deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: container.appendingPathComponent("zone-prepared.json"))
        XCTAssertEqual(try WorkerStorage.removeEverything(in: cache.root), 3300)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("zone-prepared.json").path))
        XCTAssertEqual(WorkerStorage.contents(of: cache.root), .init())
        XCTAssertEqual(try WorkerStorage.removeEverything(in: cache.root), 0, "nothing there is not an error")
    }

    // MARK: The lab switch

    func testTheLabFileOnlyWorksOnTheBuildItNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("own-model.json")
        XCTAssertNil(OwnModelLab.read(from: file, build: "2026112260"), "no file, no lab")
        let text = #"{"build":"2026112260","plan":[{"place":"keyboard","units":"cpu"},{"place":"helper","units":"neuralEngine","windows":1}]}"#
        try Data(text.utf8).write(to: file)
        let lab = try XCTUnwrap(OwnModelLab.read(from: file, build: "2026112260"))
        XCTAssertEqual(lab.plan, [.init(place: .keyboard, units: .cpu), .init(place: .helper, units: .neuralEngine, windows: 1)])
        XCTAssertNil(OwnModelLab.read(from: file, build: "2026112261"), "a later build ignores an old file")
        try Data(#"{"build":"2026112260","plan":[]}"#.utf8).write(to: file)
        XCTAssertNil(OwnModelLab.read(from: file, build: "2026112260"))
        try Data("on".utf8).write(to: file)
        XCTAssertNil(OwnModelLab.read(from: file, build: "2026112260"))
    }

    func testEachDictationTakesTheNextStepOnceEvenIfTheStepNeverReturns() {
        let lab = OwnModelLab(build: "2026112260", plan: [.init(place: .keyboard, units: .cpu), .init(place: .helper, units: .cpu)])
        XCTAssertTrue(lab.hasStepsLeft(in: defaults))
        XCTAssertEqual(lab.takeNextStep(in: defaults)?.index, 0)
        // Nothing marks a step finished: taking it is what counts, so a step that got the
        // process ended is not run again.
        XCTAssertEqual(lab.takeNextStep(in: defaults)?.step.place, .helper)
        XCTAssertNil(lab.takeNextStep(in: defaults))
        XCTAssertFalse(lab.hasStepsLeft(in: defaults))
        let next = OwnModelLab(build: "2026112261", plan: lab.plan)
        XCTAssertEqual(next.takeNextStep(in: defaults)?.index, 0, "a new build starts its plan from the top")
    }

    // MARK: The probe's guard

    func testAStageOnlyStartsWithItsCostAndTheMarginFree() {
        let options = MiniMemoryProbe.Options(directory: URL(fileURLWithPath: "/nowhere"), units: .cpu, marginMB: 30,
                                              costMB: ["predict.Encoder": 60], defaultCostMB: 4)
        let mb: UInt64 = 1_048_576
        XCTAssertTrue(MiniMemoryProbe.mayStart("predict.Encoder", left: 90 * mb, options: options))
        XCTAssertFalse(MiniMemoryProbe.mayStart("predict.Encoder", left: 90 * mb - 1, options: options))
        XCTAssertTrue(MiniMemoryProbe.mayStart("load.Unknown", left: 34 * mb, options: options))
        XCTAssertFalse(MiniMemoryProbe.mayStart("load.Unknown", left: 33 * mb, options: options))
        XCTAssertTrue(MiniMemoryProbe.mayStart("predict.Encoder", left: nil, options: options), "no limit reported")
        var expendable = options
        expendable.guarded = false
        XCTAssertTrue(MiniMemoryProbe.mayStart("predict.Encoder", left: 1, options: expendable),
                      "a helper may be run into its limit to find where it is")
    }

    func testTheProbeBacksOutBeforeLoadingWhenThereIsNoRoomAndReportsWhere() {
        let options = MiniMemoryProbe.Options(directory: URL(fileURLWithPath: "/nowhere"), units: .cpu)
        var steps: [MiniMemoryProbe.Step] = []
        // 21 MB left, as in a helper at 14 MB of its 35: the first load is refused, nothing is touched.
        let result = MiniMemoryProbe.run(options, footprint: { 14 * 1_048_576 }, left: { 21 * 1_048_576 }) { steps.append($0) }
        XCTAssertEqual(result.outcome, .stoppedForRoom(stage: "load.Preprocessor"))
        XCTAssertEqual(steps.map(\.name), ["load.Preprocessor", "released"])
        XCTAssertEqual(steps.first?.phase, .stopped)
        XCTAssertEqual(steps.first?.fields["limitMB"], "35")
        XCTAssertEqual(result.fields["stoppedAt"], "load.Preprocessor")
        XCTAssertEqual(result.fields["costMB"], "0")
    }

    func testAMissingModelIsAFailedStageNotACrash() {
        let options = MiniMemoryProbe.Options(directory: URL(fileURLWithPath: "/nowhere"), units: .cpu)
        var steps: [MiniMemoryProbe.Step] = []
        let result = MiniMemoryProbe.run(options, left: { nil }) { steps.append($0) }
        guard case .failed(let stage, _) = result.outcome else { return XCTFail("expected a failed stage") }
        XCTAssertEqual(stage, "load.Preprocessor")
        XCTAssertEqual(steps.map(\.phase), [.begin, .failed, .end])
    }

    /// The Mac measurement behind `WorkerHealth.neededMB` and `MiniMemoryProbe.expectedCostMB`.
    /// `ZONE_MINI_PROBE_DIR=<folder with the four .mlmodelc> ZONE_MINI_PROBE_UNITS=cpu swift test
    /// --filter WorkerHealthTests/testMeasureMiniOnThisMac`. Skipped without the folder.
    func testMeasureMiniOnThisMac() throws {
        guard let path = ProcessInfo.processInfo.environment["ZONE_MINI_PROBE_DIR"] else {
            throw XCTSkip("Set ZONE_MINI_PROBE_DIR to measure.")
        }
        let units = MiniMemoryProbeUnits(rawValue: ProcessInfo.processInfo.environment["ZONE_MINI_PROBE_UNITS"] ?? "cpu") ?? .cpu
        let options = MiniMemoryProbe.Options(directory: URL(fileURLWithPath: path), units: units, windows: 4)
        let result = MiniMemoryProbe.run(options) { step in
            print("PROBE", step.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        print("PROBE RESULT", result.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        XCTAssertEqual(result.outcome, .completed)
    }
}
