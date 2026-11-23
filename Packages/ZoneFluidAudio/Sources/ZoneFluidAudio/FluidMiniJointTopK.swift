// by zayd/cold @ zayd.wtf

import Foundation

/// Fluid Speech Mini's joint network with FluidAudio's top-K outputs added, which the
/// spelled-letter repeat rule (`TdtConfig.spelledLetterRepeatMargin`) reads.
///
/// Mini's downloaded joint (`JointDecision.mlmodelc`) returns only its best token. This package
/// carries the same Core ML program with a top-64 pair added, built by
/// `scripts/spelled-letter-eval/build_mini_joint_topk_shared.py`: about 12 KB, no weights. The
/// program reads the downloaded joint's `weights/weight.bin`, byte for byte the file it was built
/// from, so installing it means copying that one file beside the program. Token, probability and
/// duration come out identical to the downloaded joint's.
public enum FluidMiniJointTopK {
    /// The folder FluidAudio's v3 loader opens.
    public static let installedName = "JointDecisionv3.mlmodelc"
    /// Mini's own joint, whose weights the program reads.
    public static let downloadedName = "JointDecision.mlmodelc"
    /// The weights file the program was built against (FluidVoice-Labs/fluid-speech-mini-coreml
    /// at d81c316). A different file means a different model, so nothing is installed.
    public static let weightBytes: Int64 = 6_350_284

    static let programFiles = ["model.mil", "coremldata.bin", "metadata.json", "analytics/coremldata.bin"]
    static let weightPath = "weights/weight.bin"

    /// This package's copy of the program, or nil when the resource is missing.
    static var program: URL? {
        Bundle.module.url(forResource: "FluidMiniJointTopK", withExtension: nil)
    }

    /// True when `directory` holds this program as `JointDecisionv3.mlmodelc`, with weights.
    public static func isInstalled(in directory: URL) -> Bool {
        guard let program else { return false }
        let installed = directory.appendingPathComponent(installedName)
        return programFiles.allSatisfy { file in
            FileManager.default.contentsEqual(
                atPath: program.appendingPathComponent(file).path,
                andPath: installed.appendingPathComponent(file).path)
        } && size(of: installed.appendingPathComponent(weightPath)) == weightBytes
    }

    /// Writes `JointDecisionv3.mlmodelc` in `directory` from this program and the downloaded
    /// joint's weights, replacing whatever was there. Assembled beside it and swapped in, so a
    /// failure leaves the previous folder in place.
    public static func install(in directory: URL) throws {
        guard let program else { throw InstallError.programMissing }
        let manager = FileManager.default
        let weights = directory.appendingPathComponent(downloadedName).appendingPathComponent(weightPath)
        guard size(of: weights) == weightBytes else { throw InstallError.weightsMismatch }

        let staging = directory.appendingPathComponent(installedName + ".partial")
        try? manager.removeItem(at: staging)
        do {
            for file in programFiles + [weightPath] {
                let source = file == weightPath ? weights : program.appendingPathComponent(file)
                let target = staging.appendingPathComponent(file)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: target)
            }
            let installed = directory.appendingPathComponent(installedName)
            if manager.fileExists(atPath: installed.path) {
                _ = try manager.replaceItemAt(installed, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: installed)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    public enum InstallError: Error, Equatable {
        case programMissing
        case weightsMismatch
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
