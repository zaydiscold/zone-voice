// by zayd/cold @ zayd.wtf

import Foundation

/// Files written by older releases stay on disk until their owner uses Your data.
public struct CleanupArchive: Sendable {
  private static let fileLock = NSLock()
  // Decode the original schema for dated deletes. A timestamp alone does not identify an entry.
  private struct LegacyEntry: Decodable {
    let id: UUID
    let original: String
    let cleaned: String?
    let createdAt: Date
  }
  private let directory: URL

  public init(directory: URL) { self.directory = directory }

  /// A dated deletion needs a timestamp. Delete everything also covers unreadable files.
  @discardableResult
  public func delete(createdIn range: ClosedRange<Date>) throws -> Int {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    let everything = range.lowerBound == .distantPast && range.upperBound == .distantFuture
    var removed = 0
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
      if !everything {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(LegacyEntry.self, from: data),
              range.contains(entry.createdAt) else { continue }
      }
      try FileManager.default.removeItem(at: url)
      removed += 1
    }
    return removed
  }
}
