// by zayd/cold @ zayd.wtf

import CoreText
import Foundation
import ZoneCore

/// The emoji panel's catalog and history, one per keyboard process. The catalog is parsed off the
/// main thread the first time the panel opens, without the emoji this iOS cannot draw. Recents
/// and chosen skin tones live in the extension's own defaults, which work without Full Access.
@MainActor
enum EmojiStore {
    private(set) static var catalog: EmojiCatalog?
    /// Every offered emoji or tone to its base emoji.
    private(set) static var baseIndex: [String: String] = [:]
    /// Base emoji text to the emoji, for the tones of a recent.
    private(set) static var byBase: [String: Emoji] = [:]
    private(set) static var history = loadHistory()
    private static var isLoading = false
    private static var waiters: [() -> Void] = []
    private static let historyKey = "zone.keyboard.emojiHistory"

    /// Calls `completion` on the main thread once the catalog is ready (or failed to load).
    static func load(_ completion: @escaping () -> Void) {
        if catalog != nil {
            completion()
            return
        }
        waiters.append(completion)
        guard !isLoading else { return }
        isLoading = true
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = EmojiCatalog.loadBundled()?.drawable(Self.draws)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isLoading = false
                    catalog = loaded
                    if let loaded {
                        baseIndex = loaded.baseIndex()
                        byBase = Dictionary(loaded.categories.flatMap { $0.emoji.map { ($0.text, $0) } }) { first, _ in first }
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        KeyboardLog.typing.info("emoji catalog loaded: \(byBase.count) emoji in \(ms) ms")
                    } else {
                        KeyboardLog.typing.error("emoji catalog missing from the bundle")
                    }
                    let pending = waiters
                    waiters = []
                    pending.forEach { $0() }
                }
            }
        }
    }

    /// Drops the parsed catalog and its indexes, which `load` rebuilds when the panel next opens.
    /// Only while the panel is closed: an open panel reads `baseIndex` to remember skin tones.
    /// Recents stay. Returns true when something was dropped.
    @discardableResult
    static func purge() -> Bool {
        guard catalog != nil, !isLoading else { return false }
        catalog = nil
        baseIndex = [:]
        byBase = [:]
        return true
    }

    /// Remembers a typed emoji and, for one with skin tones, the tone.
    static func use(_ text: String) {
        let base = baseIndex[text]
        history.use(text, base: base.flatMap { byBase[$0]?.tones.isEmpty == false ? $0 : nil })
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private static func loadHistory() -> EmojiHistory {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let history = try? JSONDecoder().decode(EmojiHistory.self, from: data) else { return EmojiHistory() }
        return history
    }

    private static let probeSize: CGFloat = 32

    /// Whether this system's emoji font draws `text` as one emoji. An emoji newer than the font
    /// falls apart into its pieces (two or more emoji wide) or a missing-glyph box. Glyph counts
    /// cannot decide it: a kiss with a heart is two glyphs one emoji wide.
    nonisolated static func draws(_ text: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, probeSize, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String],
                  CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID(),
                  CTFontCopyPostScriptName(value as! CTFont) as String == "AppleColorEmoji" else { return false }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            if glyphs.contains(0) { return false }
        }
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return width > 0 && width < probeSize * 1.5
    }
}
