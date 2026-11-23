// by zayd/cold @ zayd.wtf

import Foundation

/// One file per cleanup keeps an unreadable entry from taking down the rest of the library.
/// An original must reach disk before a model is allowed to replace the working text.
public struct CleanupArchive: Sendable {
  private static let fileLock = NSLock()
  public struct Entry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let original: String
    public var cleaned: String?
    public let createdAt: Date
    public init(
      id: UUID = UUID(), original: String, cleaned: String? = nil, createdAt: Date = Date()
    ) {
      self.id = id
      self.original = original
      self.cleaned = cleaned
      self.createdAt = createdAt
    }
  }
  public let directory: URL
  public init(directory: URL) { self.directory = directory }

  public func save(_ entry: Entry) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(entry.id.uuidString + ".json")
    if entry.cleaned != nil && !FileManager.default.fileExists(atPath: url.path) {
      // A user may delete the original while generation is still running. Never resurrect it.
      throw CocoaError(.fileNoSuchFile)
    }
    if FileManager.default.fileExists(atPath: url.path) {
      let existing = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
      guard existing.original == entry.original else { throw CocoaError(.fileWriteFileExists) }
    }
    let data = try JSONEncoder().encode(entry)
    #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }

  public func entries() throws -> [Entry] {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .compactMap { url in
      guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
          url.lastPathComponent == entry.id.uuidString + ".json"
        else { return nil }
        return entry
    }.sorted { $0.createdAt > $1.createdAt }
  }

  /// Removes every saved cleanup made in `range`, originals and cleaned text both: Your data's
  /// "Delete everything" and its dated deletes mean these files too. A file that cannot be read
  /// has no date, so only a delete of all time takes it. A cleanup still running cannot bring its
  /// entry back (`save` refuses a late result whose original is gone). Returns how many went.
  @discardableResult
  public func delete(createdIn range: ClosedRange<Date>) throws -> Int {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    let everything = range.lowerBound == .distantPast && range.upperBound == .distantFuture
    var removed = 0
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
      let created = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }?.createdAt
      guard created.map(range.contains) ?? everything else { continue }
      try FileManager.default.removeItem(at: url)
      removed += 1
    }
    return removed
  }

  public func delete(_ id: UUID) throws {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    try FileManager.default.removeItem(
      at: directory.appendingPathComponent(id.uuidString + ".json"))
  }
}
