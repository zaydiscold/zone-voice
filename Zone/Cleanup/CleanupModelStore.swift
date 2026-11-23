// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation

/// Cleanup owns its own download session and staging directory. Speech downloads are independent.
actor CleanupModelStore {
  static let shared = CleanupModelStore()
  struct File: Sendable {
    let path: String
    let bytes: Int
    let sha256: String
  }
  static let revision = "03fba3c10e33fd6587aa492735f7434e81322208"
  static let files: [File] = [
    .init(
      path: "chunk_0.mlmodelc/analytics/coremldata.bin", bytes: 243,
      sha256: "f4e8e467ca6fca6702b07ae86aac523be40b93db12b0964139eabc09aaaeb53c"),
    .init(
      path: "chunk_0.mlmodelc/coremldata.bin", bytes: 593,
      sha256: "9a1a3cf243d5be3c19e1b1cb200ae2115c1cf216ed1c7bf5bd9331e736e1dff8"),
    .init(
      path: "chunk_0.mlmodelc/metadata.json", bytes: 4463,
      sha256: "d2e9d4d8237324f1433bbece1cd33e657b1b5582dbd0688cef2b7358bcb08ccc"),
    .init(
      path: "chunk_0.mlmodelc/model.mil", bytes: 106074,
      sha256: "54fadda34cc23314a1c3c35cc16c98251959d24b2e5d8f37bde55647b6cb6c9b"),
    .init(
      path: "chunk_0.mlmodelc/weights/weight.bin", bytes: 70_016_064,
      sha256: "c28b6f4b37998eb19e1b0ffbfc2c63c084cdb4addb8aa60717bb370ce1ec4fd9"),
    .init(
      path: "chunk_1.mlmodelc/analytics/coremldata.bin", bytes: 243,
      sha256: "224a32aa61e0af070ea1c2378157fa26547affebb6bae00a1dba1e231f12b241"),
    .init(
      path: "chunk_1.mlmodelc/coremldata.bin", bytes: 595,
      sha256: "170008d157cc0032c34948d5f4471aff0fe438a498a6c16a1e30fb9304f5d8d6"),
    .init(
      path: "chunk_1.mlmodelc/metadata.json", bytes: 4468,
      sha256: "4135590ef8cfca2a7d832c332a6b669861ab812ec632c0f5134ab4ac0dc3c4b8"),
    .init(
      path: "chunk_1.mlmodelc/model.mil", bytes: 106102,
      sha256: "c4c08900fd8bcc06ffba35868fab3a73f5e18e8debfebb94b2f4d29779f0db57"),
    .init(
      path: "chunk_1.mlmodelc/weights/weight.bin", bytes: 54_742_208,
      sha256: "3bc1aed2cfe6f8cd0c762a51e07447d80b0e018c4d4ca5eb090476ffa5d60e65"),
    .init(
      path: "chunk_2.mlmodelc/analytics/coremldata.bin", bytes: 243,
      sha256: "3d5c03e1662c85dba881f36b8923878f2aed11f12fcb4221abf7bd46593ecd22"),
    .init(
      path: "chunk_2.mlmodelc/coremldata.bin", bytes: 595,
      sha256: "b19402467d1ed291fee7b48f0b5b0ac189f9f1e6f91a0ee50825931412e1ac80"),
    .init(
      path: "chunk_2.mlmodelc/metadata.json", bytes: 4469,
      sha256: "81930c46e5dfa055560ab8fe2682e3525579e446be40c8b5c63a208e15b9f68b"),
    .init(
      path: "chunk_2.mlmodelc/model.mil", bytes: 133976,
      sha256: "9b6addf762a4ad10fe10f9b6b550206061db5e91fa6040b78e1c4d22e206e37a"),
    .init(
      path: "chunk_2.mlmodelc/weights/weight.bin", bytes: 53_945_920,
      sha256: "28669e6786ba709618d22fedf9cbbb5efd980b989dbd6121b657693d64568177"),
    .init(
      path: "chunk_3.mlmodelc/analytics/coremldata.bin", bytes: 243,
      sha256: "dac4ff9ce720c3cc967be9811db3f7294d82d3645abda309a0979693467e3fd6"),
    .init(
      path: "chunk_3.mlmodelc/coremldata.bin", bytes: 616,
      sha256: "369c08e35d9c1a2a3433fb19727488dd9a05b197d75da6fb0cc93965454dd904"),
    .init(
      path: "chunk_3.mlmodelc/metadata.json", bytes: 4794,
      sha256: "ac83b8e26d1203b2b08e15314a1f5d63471c5748ebf767c6bdde252d33874209"),
    .init(
      path: "chunk_3.mlmodelc/model.mil", bytes: 139222,
      sha256: "79c37cbb3a7320277e546a133c90511f1fc92ad771721a39f4b4fbf85bc0b6f0"),
    .init(
      path: "chunk_3.mlmodelc/weights/weight.bin", bytes: 188_165_824,
      sha256: "e0eba083677fe26c2fa2e85708cae3e4284d486ae582e79305209d17795ff3e8"),
    .init(
      path: "LICENSE", bytes: 10574,
      sha256: "4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c"),
    .init(
      path: "README.md", bytes: 596,
      sha256: "3efdbb7d4d76b577fc32ac908ee61600b39601cfe5cc68f4966a3dff06af0962"),
  ]
  static let tokenizer = File(
    path: "tokenizer.json", bytes: 4_732_426,
    sha256: "98cff83b4f6d7e9d8929bebc62b07e92cf1b3f99c80d16bafe8b84a75448f40b")
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Cleanup/fluid-pico-" + revision, isDirectory: true)
  }
  static var installed: Bool {
    let root = directory
    guard
      (try? String(contentsOf: root.appendingPathComponent("verified"), encoding: .utf8))
        == revision
    else { return false }
    return (files + [tokenizer]).allSatisfy {
      ((try? FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent($0.path).path)[.size]) as? NSNumber)?.intValue
        == $0.bytes
    }
  }
  private var downloading = false
  func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    guard !downloading else { throw CleanupError.busy }
    downloading = true
    defer { downloading = false }
    if Self.installed {
      progress(1)
      return
    }
    let fm = FileManager.default
    let destination = Self.directory
    let staging = destination.appendingPathExtension("partial")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    var excluded = staging
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let all = Self.files + [Self.tokenizer]
    let total = all.reduce(0) { $0 + $1.bytes }
    var completed = 0
    for file in all {
      try Task.checkCancellation()
      let target = staging.appendingPathComponent(file.path)
      if let existing = try? Data(contentsOf: target, options: .mappedIfSafe),
        Self.valid(existing, file)
      {
        completed += file.bytes
        progress(Double(completed) / Double(total))
        continue
      }
      let base =
        file.path == "tokenizer.json"
        ? "https://huggingface.co/LiquidAI/LFM2-350M/resolve/f37d3f5c8c5484bc01dad379a595cf4c68c4e70e/"
        : "https://huggingface.co/altic-dev/Fluid-1-Pico-CoreML/resolve/\(Self.revision)/"
      let (temporary, response) = try await session.download(from: URL(string: base + file.path)!)
      defer { try? fm.removeItem(at: temporary) }
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CleanupError.download }
      let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
      guard Self.valid(data, file) else { throw CleanupError.download }
      try Task.checkCancellation()
      try fm.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target, options: .atomic)
      completed += file.bytes
      progress(Double(completed) / Double(total))
    }
    try Task.checkCancellation()
    try Data(Self.revision.utf8).write(
      to: staging.appendingPathComponent("verified"), options: .atomic)
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.moveItem(at: staging, to: destination)
  }
  func remove() throws {
    guard !downloading else { throw CleanupError.busy }
    for url in [Self.directory, Self.directory.appendingPathExtension("partial")] {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }
  private static func valid(_ data: Data, _ file: File) -> Bool {
    data.count == file.bytes
      && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
  }
}
