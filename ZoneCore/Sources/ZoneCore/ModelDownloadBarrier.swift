// by zayd/cold @ zayd.wtf

import Foundation

/// A deletion epoch per model directory. Persist `generations` before removing files.
/// Old background callbacks stay invalid across process restarts and container moves;
/// explicitly started downloads carry the current epoch in their task description.
public struct ModelDownloadBarrier: Sendable {
    public private(set) var generations: [String: String]

    public init(generations: [String: String] = [:]) { self.generations = generations }

    public mutating func retire(_ directories: [URL]) {
        for directory in directories { generations[Self.key(directory)] = UUID().uuidString }
    }

    public func generation(for file: URL) -> String? {
        let path = Self.key(file)
        return generations.keys.filter { path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count }).flatMap { generations[$0] }
    }

    public func blocks(_ file: URL, generation: String?) -> Bool {
        guard let current = self.generation(for: file) else { return false }
        return generation != current
    }

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.range(of: "/Library/", options: .backwards).map { String(path[$0.lowerBound...]) } ?? path
    }
}
