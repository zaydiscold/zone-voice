// by zayd/cold @ zayd.wtf

import CoreML
import Foundation
import ZoneCore

enum CleanupEngine {
  static let automaticKey = "zone.cleanup.automatic"
  static var archive: CleanupArchive {
    CleanupArchive(
      directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CleanupHistory", isDirectory: true))
  }
  static var unavailableReason: String? {
    guard #available(iOS 18, macOS 15, *) else { return "Requires iOS 18 or later." }
    return CleanupModelStore.installed
      ? nil : "One-time download. Runs offline after that."
  }
  static func clean(_ text: String) async throws -> String {
    guard #available(iOS 18, macOS 15, *), unavailableReason == nil else {
      throw CleanupError.unavailable
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.count <= CleanupPolicy.maximumCharacters
    else { throw CleanupError.length }
    return try await PicoCleanupRuntime.shared.clean(text)
  }

  /// Failure at either save boundary leaves the caller's text unchanged.
  static func cleanAndSave(_ text: String, id: UUID = UUID()) async throws -> String {
    try await CleanupTransaction.run(original: text, id: id, archive: archive) {
      try await clean($0)
    }
  }
}

@available(iOS 18, macOS 15, *)
private actor PicoCleanupRuntime {
  static let shared = PicoCleanupRuntime()
  func clean(_ text: String) throws -> String {
    let root = CleanupModelStore.directory
    let tokenizer = try CleanupTokenizer(
      data: Data(contentsOf: root.appendingPathComponent("tokenizer.json")))
    let tokens = try tokenizer.prompt(for: text)
    guard tokens.count < 768 else { throw CleanupError.context }
    let config = MLModelConfiguration()
    config.computeUnits = .cpuOnly
    let models = try (0..<4).map {
      try MLModel(
        contentsOf: root.appendingPathComponent("chunk_\($0).mlmodelc"), configuration: config)
    }
    let cacheShapes = [
      [2, 1, 512, 1, 1024], [2, 1, 512, 1, 1024], [4, 1, 512, 1, 1024], [4, 1, 512, 1, 1024],
    ]
    let convShapes = [[3, 1024, 3], [3, 1024, 3], [2, 1024, 3], [2, 1024, 3]]
    for (index, model) in models.enumerated() {
      guard
        model.modelDescription.inputDescriptionsByName["kv_cache_in"]?.multiArrayConstraint?.shape
          .map(\.intValue) == cacheShapes[index],
        model.modelDescription.inputDescriptionsByName["conv_state_in"]?.multiArrayConstraint?.shape
          .map(\.intValue) == convShapes[index]
      else { throw CleanupError.download }
    }
    let caches = try cacheShapes.map { try zeros($0.map(NSNumber.init), .float16) }
    var convs = try convShapes.map { try zeros($0.map(NSNumber.init), .float16) }
    let position = try zeros([1], .int32)
    let input = try zeros([1, 1], .int32)
    let mask = try zeros([1, 1025, 1, 1], .float16)
    let update = try zeros([1, 1, 1024, 1], .float16)
    var next = 0
    var generated: [Int] = []
    var finished = false
    for step in 0..<min(tokens.count + 512, 1024) {
      try Task.checkCancellation()
      input[0] = NSNumber(value: step < tokens.count ? tokens[step] : next)
      position[0] = NSNumber(value: step)
      let mp = mask.dataPointer.assumingMemoryBound(to: Float16.self)
      for j in 0..<1025 { mp[j] = j < step || j == 1024 ? 0 : -65504 }
      if step > 0 { update[step - 1] = 0 }
      update[step] = 1
      var hidden: MLMultiArray?
      for chunk in 0..<4 {
        var values: [String: MLFeatureValue] = [
          "position_ids": MLFeatureValue(multiArray: position),
          "causal_mask": MLFeatureValue(multiArray: mask),
          "update_mask": MLFeatureValue(multiArray: update),
          "kv_cache_in": MLFeatureValue(multiArray: caches[chunk]),
          "conv_state_in": MLFeatureValue(multiArray: convs[chunk]),
        ]
        guard let chunkInput = chunk == 0 ? input : hidden else { throw CleanupError.empty }
        values[chunk == 0 ? "input_ids" : "hidden_in"] = MLFeatureValue(multiArray: chunkInput)
        let out = try models[chunk].prediction(
          from: MLDictionaryFeatureProvider(dictionary: values))
        guard let conv = out.featureValue(for: "conv_state_out")?.multiArrayValue,
          let slice = out.featureValue(for: "kv_slice_out")?.multiArrayValue,
          slice.shape.map(\.intValue) == [cacheShapes[chunk][0], 1, 512, 1, 1],
          slice.dataType == .float16
        else { throw CleanupError.empty }
        convs[chunk] = conv

        let src = slice.dataPointer.assumingMemoryBound(to: Float16.self)
        let dst = caches[chunk].dataPointer.assumingMemoryBound(to: Float16.self)
        for j in 0..<slice.count {
          dst[j * 1024 + step] =
            src[(j / 512) * slice.strides[0].intValue + (j % 512) * slice.strides[2].intValue]
        }
        if chunk < 3 {
          hidden = out.featureValue(for: "hidden_out")?.multiArrayValue
        } else {
          guard let token = out.featureValue(for: "token_id")?.multiArrayValue else {
            throw CleanupError.empty
          }
          next = token[0].intValue
        }
      }
      if step >= tokens.count - 1 {
        if next == 7 {
          finished = true
          break
        }
        generated.append(next)
      }
    }

    guard finished else { throw CleanupError.context }
    let result = try tokenizer.decode(generated).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw CleanupError.empty }
    guard CleanupPolicy.isSafe(original: text, candidate: result) else {
      throw CleanupError.changedMeaning
    }
    return result
  }
  private func zeros(_ shape: [NSNumber], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape, dataType: type)
    memset(array.dataPointer, 0, array.count * (type == .float16 ? 2 : 4))
    return array
  }
}

enum CleanupError: LocalizedError {
  case unavailable, length, empty, changedMeaning, context, download, busy
  var errorDescription: String? {
    switch self {
    case .unavailable: "Download the cleanup model first. Your original is unchanged."
    case .length: "Cleanup handles up to 4,000 characters at a time."
    case .context:
      "Too long for one pass. Try a shorter section."
    case .changedMeaning:
      "Cleanup changed too much of the wording, so Zone kept your original."
    case .empty: "Cleanup returned nothing. Your original is unchanged."
    case .download: "Download failed verification. Try again; finished chunks were saved."
    case .busy: "Download already running."
    }
  }
}
