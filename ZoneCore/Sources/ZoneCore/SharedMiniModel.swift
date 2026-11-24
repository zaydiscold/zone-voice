import Darwin
import Foundation

public enum SharedMiniModel {
    public static let path = "Library/Application Support/Models/fluid-speech-mini-coreml"
    public static let identifier = "FluidVoice-Labs/fluid-speech-mini-coreml"
    public static let revision = "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a"
    public struct File: Sendable {
        public let path: String
        public let bytes: Int64
        public let hash: FileDigest

        public init(path: String, bytes: Int64, hash: FileDigest) {
            self.path = path
            self.bytes = bytes
            self.hash = hash
        }
    }

    public static let files: [File] = [
        .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("d4beee43a6eab29b2adcc298f2e8582e8fb79d5fe3aa9f1ab692ade681ca369d")),
        .init(path: "Decoder.mlmodelc/coremldata.bin", bytes: 491, hash: .sha256("6094d06d05c1ca4599c7b13c9a4ca7c00826ee2396796cf3084ce602a9884468")),
        .init(path: "Decoder.mlmodelc/metadata.json", bytes: 3_373, hash: .gitBlob("a79debb5125b7c1a6a81e6a4445912c96474c0ee")),
        .init(path: "Decoder.mlmodelc/model.mil", bytes: 13_411, hash: .gitBlob("428742162c9e8b2b1a020e4a47da87adb87e7af0")),
        .init(path: "Decoder.mlmodelc/weights/weight.bin", bytes: 11_845_120, hash: .sha256("d173e381488d07fd7648e2ccecbfb1bceff0457d75461550b26ba7fa2d23309a")),
        .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("3a3caa2c6aec983d94a5659eff09a00f77077147ea6726b8ddfdf022f0238ce9")),
        .init(path: "Encoder.mlmodelc/coremldata.bin", bytes: 427, hash: .sha256("494d8e2ce30b37bcdf494b3ba7ddf6e1bc921b9a59e369a9efd44d013ca3bf7d")),
        .init(path: "Encoder.mlmodelc/metadata.json", bytes: 2_906, hash: .gitBlob("49b43277d5d42ac49af5a9e6bcec63195acbb76c")),
        .init(path: "Encoder.mlmodelc/model.mil", bytes: 712_643, hash: .gitBlob("69c0308b882eae9413bd787f757c80ee46a7f2bb")),
        .init(path: "Encoder.mlmodelc/weights/weight.bin", bytes: 233_096_704, hash: .sha256("cf0b61022de8c698984a8c7185c2d093fa744694621881ff062c46fee2546131")),
        .init(path: "JointDecision.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("9e767d69e1092b27b28d9f236b9cbcded58ff3891e320cba7855e2c24e803d69")),
        .init(path: "JointDecision.mlmodelc/coremldata.bin", bytes: 462, hash: .sha256("284b235c08cd4769202af017f854deace69c0209c29f2253a2073bb68d58d38d")),
        .init(path: "JointDecision.mlmodelc/metadata.json", bytes: 2_790, hash: .gitBlob("f838342b52059cd8b06bf6bedd185bb0c7ed1cac")),
        .init(path: "JointDecision.mlmodelc/model.mil", bytes: 7_547, hash: .gitBlob("18e706e2e2d4a78ad825a1a0542af639f52b3c62")),
        .init(path: "JointDecision.mlmodelc/weights/weight.bin", bytes: 6_350_284, hash: .sha256("f991f65979c1b3fee3db39a645aa87e6bef1a304ed1816d074b17479bea797fc")),
        .init(path: "LICENSE", bytes: 18_657, hash: .gitBlob("da6ab6cc8f333d7e89a99812866df8f24374d47c")),
        .init(path: "NOTICE", bytes: 690, hash: .gitBlob("ab1383ddb9427e377b5752cea97d2a0a3411dbc9")),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d")),
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486, hash: .sha256("dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d")),
        .init(path: "Preprocessor.mlmodelc/metadata.json", bytes: 2_841, hash: .gitBlob("06162c58cf2f5343a0e60f36f843bcdf3cc58527")),
        .init(path: "Preprocessor.mlmodelc/model.mil", bytes: 28_181, hash: .gitBlob("f987e2479228436c49189aa47edb376db74dcff5")),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491_072, hash: .sha256("129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea")),
        .init(path: "config.json", bytes: 314, hash: .gitBlob("88cccfe091f2335ba8f3af8d91bf378a35314b93")),
        .init(path: "parakeet_vocab.json", bytes: 151_122, hash: .gitBlob("c684822ec3b671ebc449c433a7012398d39b8bb0")),
        ]

    static func filesPresent(in directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appendingPathComponent("JointDecisionv3.mlmodelc").path)
            && files.allSatisfy { file in
                let path = directory.appendingPathComponent(file.path).path
                return (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value == file.bytes
            }
    }

    private static let moveLock = NSLock()
    private static let recordKey = "verifiedMiniModel"
    private static var record: [String: String] {
        ["identifier": identifier, "revision": revision, "path": path, "status": "complete and verified"]
    }
    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(path, isDirectory: true)
    }
    public static var verified: Bool {
        guard UserDefaults(suiteName: AppGroup.identifier)?.dictionary(forKey: recordKey) as? [String: String] == record,
              let directory else { return false }
        return filesPresent(in: directory)
    }
    public static func publish(_ complete: Bool) {
        UserDefaults(suiteName: AppGroup.identifier)?.set(complete ? record : nil, forKey: recordKey)
    }

    public static func prepareShared(from old: URL, to shared: URL, published: Bool,
                                     isComplete: (URL) -> Bool, verify: (URL) throws -> Bool) throws -> Bool {
        moveLock.lock()
        defer { moveLock.unlock() }
        let fm = FileManager.default
        if fm.fileExists(atPath: shared.path) {
            let hasPrivateCopy = fm.fileExists(atPath: old.path)
            if isComplete(shared), try (published && !hasPrivateCopy) || verify(shared) {
                if hasPrivateCopy { try fm.removeItem(at: old) }
                return true
            }
            guard fm.fileExists(atPath: old.path), try verify(old) else { return false }
            // The old copy is fully verified and remains intact across a kill before the move.
            try fm.removeItem(at: shared)
        } else {
            guard fm.fileExists(atPath: old.path), try verify(old) else { return false }
        }
        try fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: old, to: shared)
        return true
    }

    public static func removeCopies(_ paths: [URL], remove: (URL) throws -> Void) throws {
        var firstError: Error?
        for path in paths {
            do { try remove(path) } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    /// A rename leaves the whole directory at one path even if the app stops.
    public static func migrate(from old: URL, to new: URL, verify: (URL) throws -> Bool) throws -> URL {
        moveLock.lock()
        defer { moveLock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return new }
        guard !fm.fileExists(atPath: new.path), try verify(old) else { return old }
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        if renamex_np(old.path, new.path, UInt32(RENAME_EXCL)) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return new
    }
}
