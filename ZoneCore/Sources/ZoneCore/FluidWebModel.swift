// by zayd/cold @ zayd.wtf
#if os(iOS)
import Foundation
import CryptoKit

public enum FluidWebModel {
    public static let revision = "fc592620325027419883cf272e70588d8a788c0a"
    public static let files = [
        "config.json": "0c4d0c84dadc0d439dfe3c843a4b482bf3ebb50421f781fcbafc7236903234f4",
        "decoder.onnx": "9ac7e6c22952c242d56df0992ba19489a05b87a8ed37e23798469b9316099af8",
        "encoder.onnx": "f8b3a45e71a33b44179a21ef6d6474779747846c4b01c9fd690abcebb88bea86",
        "encoder.onnx.data": "f865c582bec1bd57aa7f2242f3739f38987b7bf471fee4dca7d5c2714eec0747",
        "frontend.onnx": "cdbea06631920f25f6183e1389129e9c37106a766c6e130b7f0389b9531b43b7",
        "joint.onnx": "2e704908834b9f8cc7db88757b8966bac266e19bc00a527c46e9950281205253",
        "mel_filters.npy": "ce607f7ae1ce68fd01c02e1177fb1d11ee209c6176d35e47011917ca7d9cd4f2",
        "tokenizer.json": "7c200d88ac60da4de246cbd38e981a732f2e82580fdd285cb757d8d1f4af9627"
    ]
    public static var directory: URL? {
        KeyboardVoiceRoute.group?.appendingPathComponent("Library/Caches/KeyboardWebModel/" + revision, isDirectory: true)
    }
    public static var ready: Bool {
        guard let directory else { return false }
        return ready(at: directory)
    }

    private static func ready(at directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appendingPathComponent("verified").path)
            && files.keys.allSatisfy { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    public static func install(progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        guard let final = directory else { throw CocoaError(.fileNoSuchFile) }
        try await install(at: final, progress: progress)
    }

    static func install(at final: URL, progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        if ready(at: final) { return }
        let fm = FileManager.default
        let stage = final.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        for (index, name) in files.keys.sorted().enumerated() {
            try Task.checkCancellation()
            await progress(index, files.count)
            let url = URL(string: "https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-onnx/resolve/" + revision + "/" + name)!
            let (download, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let handle = try FileHandle(forReadingFrom: download)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty {
                try Task.checkCancellation()
                hash.update(data: bytes)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == files[name] else { throw CocoaError(.fileReadCorruptFile) }
            try fm.moveItem(at: download, to: stage.appendingPathComponent(name))
        }
        try Task.checkCancellation()
        try Data().write(to: stage.appendingPathComponent("verified"))
        try await publish(stage, at: final)
        await progress(files.count, files.count)
    }
    // Both settings entry points can finish downloads. Publish a complete version in one move.
    @MainActor private static func publish(_ stage: URL, at final: URL) throws {
        guard !ready(at: final) else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: final.path) {
            _ = try manager.replaceItemAt(final, withItemAt: stage)
        } else {
            try manager.moveItem(at: stage, to: final)
        }
    }

}
#endif
