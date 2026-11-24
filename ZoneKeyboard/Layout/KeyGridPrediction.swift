// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// Dynamic hit targets for the key grid: tracks the word being typed on the grid and keeps a
/// next-letter likelihood table for it, built off the main thread. The touch path only reads the
/// table (a 27-entry array), so the per-touch cost is a few comparisons; until the table for the
/// current prefix is ready, touches use the plain nearest key.
@MainActor
final class KeyGridPrediction {
    /// Apple-style dynamic hit targets. Off gives pure nearest-key assignment.
    static let isEnabled = true

    private static let queue = DispatchQueue(label: "wtf.zayd.zone.keygrid-prediction", qos: .userInitiated)
    private static let cacheLimit = 256

    /// Letters typed on the grid since the last separator, lowercased. A best-effort mirror of
    /// the word at the cursor: it resets on any separator, layer key or reappearance, and a cursor
    /// moved by the host simply makes the bias a little less useful, never wrong about what key
    /// is drawn.
    private(set) var prefix = ""
    private var cache: [String: NextLetterLikelihood?] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []

    /// The table for the current prefix, if it is ready and there is one.
    var current: NextLetterLikelihood? {
        guard Self.isEnabled, !prefix.isEmpty, let hit = cache[prefix] else { return nil }
        return hit
    }

    /// A letter landed: extend the word. Anything else that types ends it.
    func typed(_ key: Key) {
        switch key {
        case .character(let text):
            let lower = text.lowercased()
            if lower.count == 1, let c = lower.first, c.isASCII, c.isLetter || c == "'" {
                prefix += lower
                if prefix.count >= WordList.maxWordLength { prefix = "" }
            } else {
                prefix = ""
            }
        case .delete:
            if !prefix.isEmpty { prefix.removeLast() }
        case .shift:
            return
        default:
            prefix = ""
        }
        prepare()
    }

    /// A held delete removes more than one character; the mirror is no longer known.
    func reset() {
        prefix = ""
    }

    private func prepare() {
        guard Self.isEnabled, !prefix.isEmpty, cache[prefix] == nil, !pending.contains(prefix) else { return }
        let wanted = prefix
        pending.insert(wanted)
        Self.queue.async {
            let words = WordList.shared
            let table = words.flatMap { NextLetterModel.likelihood(after: wanted, in: $0) }
            let loaded = words != nil
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.store(table, for: wanted, loaded: loaded) }
            }
        }
    }

    private func store(_ table: NextLetterLikelihood?, for prefix: String, loaded: Bool) {
        pending.remove(prefix)
        guard loaded else { return }
        cache[prefix] = .some(table)
        order.append(prefix)
        if order.count > Self.cacheLimit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}
