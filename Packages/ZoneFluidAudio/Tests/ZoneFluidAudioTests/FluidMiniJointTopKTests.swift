// by zayd/cold @ zayd.wtf

import CoreML
import XCTest
@testable import ZoneFluidAudio

final class FluidMiniJointTopKTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stand-in for Mini's downloaded joint: the right-sized weights file, no real model.
    private func writeDownloadedJoint(bytes: Int64 = FluidMiniJointTopK.weightBytes) throws {
        let weights = directory.appendingPathComponent("JointDecision.mlmodelc/weights/weight.bin")
        try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: Int(bytes)).write(to: weights)
    }

    func testProgramShipsInThePackage() throws {
        let program = try XCTUnwrap(FluidMiniJointTopK.program)
        for file in FluidMiniJointTopK.programFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: program.appendingPathComponent(file).path), file)
        }
        let mil = try String(contentsOf: program.appendingPathComponent("model.mil"), encoding: .utf8)
        XCTAssertTrue(mil.contains("top_k_ids"))
        XCTAssertTrue(mil.contains("@model_path/weights/weight.bin"))
    }

    func testInstallsTheProgramWithTheDownloadedWeights() throws {
        try writeDownloadedJoint()
        XCTAssertFalse(FluidMiniJointTopK.isInstalled(in: directory))
        try FluidMiniJointTopK.install(in: directory)
        XCTAssertTrue(FluidMiniJointTopK.isInstalled(in: directory))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("JointDecisionv3.mlmodelc.partial").path))
    }

    func testReplacesAnOlderCopyOfTheDownloadedJoint() throws {
        try writeDownloadedJoint()
        // What Zone installed before: a plain copy of Mini's joint under the v3 name.
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("JointDecision.mlmodelc"),
            to: directory.appendingPathComponent("JointDecisionv3.mlmodelc"))
        XCTAssertFalse(FluidMiniJointTopK.isInstalled(in: directory))
        try FluidMiniJointTopK.install(in: directory)
        XCTAssertTrue(FluidMiniJointTopK.isInstalled(in: directory))
    }

    func testRefusesWeightsOfAnotherSize() throws {
        try writeDownloadedJoint(bytes: 1_000)
        XCTAssertThrowsError(try FluidMiniJointTopK.install(in: directory)) { error in
            XCTAssertEqual(error as? FluidMiniJointTopK.InstallError, .weightsMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("JointDecisionv3.mlmodelc").path))
    }

    /// With Mini downloaded (`ZONE_FLUID_MINI_DIR`, the fluid-speech-mini-coreml folder), the
    /// installed joint must decide exactly as Mini's own and return top-K led by that token.
    func testMatchesMinisOwnJoint() throws {
        guard let mini = ProcessInfo.processInfo.environment["ZONE_FLUID_MINI_DIR"] else {
            throw XCTSkip("Set ZONE_FLUID_MINI_DIR to a downloaded Fluid Speech Mini folder.")
        }
        let source = URL(fileURLWithPath: mini).appendingPathComponent("JointDecision.mlmodelc")
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("JointDecision.mlmodelc"))
        try FluidMiniJointTopK.install(in: directory)

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let original = try MLModel(contentsOf: source, configuration: configuration)
        let topK = try MLModel(
            contentsOf: directory.appendingPathComponent("JointDecisionv3.mlmodelc"), configuration: configuration)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let encoder = try MLMultiArray(shape: [1, 1024, 1], dataType: .float32)
            let decoder = try MLMultiArray(shape: [1, 640, 1], dataType: .float32)
            for i in 0..<1024 { encoder[i] = NSNumber(value: Float.random(in: -2...2, using: &generator)) }
            for i in 0..<640 { decoder[i] = NSNumber(value: Float.random(in: -2...2, using: &generator)) }
            let input = try MLDictionaryFeatureProvider(dictionary: ["encoder_step": encoder, "decoder_step": decoder])
            let a = try original.prediction(from: input)
            let b = try topK.prediction(from: input)
            for name in ["token_id", "token_prob", "duration"] {
                XCTAssertEqual(a.featureValue(for: name)?.multiArrayValue?[0], b.featureValue(for: name)?.multiArrayValue?[0], name)
            }
            let ids = try XCTUnwrap(b.featureValue(for: "top_k_ids")?.multiArrayValue)
            XCTAssertEqual(ids.count, 64)
            XCTAssertEqual(ids[0], a.featureValue(for: "token_id")?.multiArrayValue?[0])
        }
    }
}
