// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation

/// How long a copy is kept. Kept copies (`ClipboardEntry.pinned`) stay until they are let go.
public enum ClipboardRetention: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month

    /// A month: the copy someone forgot to paste is usually missed within days, and a clipboard
    /// holds more private text than a dictation does, so nothing stays for good unless it is kept.
    public static let `default`: ClipboardRetention = .month

    public var maxAge: TimeInterval {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    public var label: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
}

/// How a copy reached Zone. A string-backed struct, so a later build can add a route without
/// breaking this one's reading of the file.
public struct ClipboardRoute: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The keyboard read the clipboard when it came up, or while it was up.
    public static let keyboard = ClipboardRoute(rawValue: "keyboard")
    /// Pasted with Zone's Paste key, or saved from the panel's paste button.
    public static let pasteKey = ClipboardRoute(rawValue: "pasteKey")
    /// The app read the clipboard when it came to the front.
    public static let app = ClipboardRoute(rawValue: "app")
    /// The Save to Zone Clipboard shortcut.
    public static let shortcut = ClipboardRoute(rawValue: "shortcut")
    /// The paste button on the Clipboard screen.
    public static let saved = ClipboardRoute(rawValue: "saved")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One copy Zone kept. `savedAt` is when Zone saw it, which is the closest thing to "when it was
/// copied" iOS lets anyone know.
public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var imageType: String?
    public var imageDigest: Data?
    public var imageBytes: Int?
    public var savedAt: Date
    public var route: ClipboardRoute
    /// Kept: outside the age and count limits until it is let go.
    public var pinned: Bool

    public init(id: UUID = UUID(), text: String, savedAt: Date, route: ClipboardRoute, pinned: Bool = false) {
        self.id = id
        self.text = text
        self.savedAt = savedAt
        self.route = route
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey { case id, text, savedAt, route, pinned, imageType, imageBytes, imageDigest }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        imageType = try values.decodeIfPresent(String.self, forKey: .imageType)
        imageDigest = try values.decodeIfPresent(Data.self, forKey: .imageDigest)
        imageBytes = try values.decodeIfPresent(Int.self, forKey: .imageBytes)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        savedAt = try values.decode(Date.self, forKey: .savedAt)
        route = (try? values.decodeIfPresent(ClipboardRoute.self, forKey: .route)) ?? .keyboard
        pinned = (try? values.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
    }

    /// The address when the whole copy is one web link, so a row can offer Open.
    public var link: URL? { ClipboardPolicy.link(in: text) }
}

/// What kind of field the keyboard is typing into, as far as a copy is concerned.
public enum ClipboardField: Equatable, Sendable {
    case ordinary
    /// A user name or email field. A fresh copy here may be a password on its way to the next
    /// field, so nothing is read while the keyboard is in it; an ordinary field later may keep it.
    case signIn
    /// A password, verification code or card field. A fresh copy here is taken to be one of
    /// those: it is never read, here or anywhere after.
    case secret
}

/// Why a copy was not kept. Counted, never stored with the text.
public enum ClipboardSkip: String, Codable, CaseIterable, Sendable {
    /// Zone put it on the clipboard itself (a dictation or a note already in the library).
    case own
    /// The app that copied it marked it concealed or temporary (password managers do).
    case concealed
    /// The keyboard was in a password, code or card field.
    case privateField
    /// Only digits, the length of a verification code or a PIN.
    case code
    /// A payment card number.
    case card
    /// One unbroken word with capitals, small letters and digits: the shape of a password.
    case password
    /// An access key or token of a known kind, or a private key.
    case key
    /// Longer than `ClipboardPolicy.maxBytes`.
    case tooLong
    /// Nothing but spaces.
    case empty

    /// The ones Settings calls "passwords and codes" and lets the person keep instead.
    public var isSecretGuess: Bool {
        switch self {
        case .code, .card, .password, .key: return true
        case .own, .concealed, .privateField, .tooLong, .empty: return false
        }
    }
}

/// The rules for what Zone keeps. Two looks: one at what the clipboard says about itself, before
/// anything is read, and one at the text.
public enum ClipboardPolicy {
    /// One copy at most. A whole copy is kept or none of it: half of one, pasted later, is worse
    /// than none. An individual copy can use the full shared text budget.
    public static let maxBytes = maxTotalBytes
    /// Unpinned copies kept at most; the oldest go first.
    public static let maxEntries = 200
    /// All kept text together. The keyboard decodes the whole file, and has little memory.
    public static let maxTotalBytes = 1_500_000

    /// The type Zone adds to its own copies (`Clipboard.copy`), so the keyboard knows them without
    /// reading them.
    public static let ownType = "wtf.zayd.zone.own-copy"

    /// What password managers and other apps put beside a copy that should not be recorded
    /// (nspasteboard.org; Universal Clipboard carries them over from a Mac).
    public static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]

    /// Decided from the clipboard's types and the field, so a copy that should not be kept is
    /// never read at all.
    public static func skipBeforeReading(types: [String], field: ClipboardField, skipsSecrets: Bool = false) -> ClipboardSkip? {
        guard skipsSecrets else { return nil }
        if types.contains(ownType) { return .own }
        if types.contains(where: concealedTypes.contains) { return .concealed }
        if field == .secret { return .privateField }
        return nil
    }

    /// Decided from the text. With `skipsSecrets` off, only the size and emptiness rules apply.
    public static func skipAfterReading(_ text: String, skipsSecrets: Bool) -> ClipboardSkip? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if text.utf8.count > maxBytes { return .tooLong }
        guard skipsSecrets else { return nil }
        if isCode(trimmed) { return .code }
        if isCardNumber(trimmed) { return .card }
        if isKnownKey(trimmed) { return .key }
        if isPasswordShaped(trimmed) { return .password }
        return nil
    }

    /// Four to eight digits and nothing else: a verification code or a PIN far more often than
    /// anything worth finding again.
    static func isCode(_ text: String) -> Bool {
        guard (4...10).contains(text.count) else { return false }
        return text.range(of: #"^(?:[0-9]{4,8}|[0-9]{3}[ -][0-9]{3}|[A-Z]-[0-9]{4,8})$"#,
                          options: .regularExpression) != nil
    }

    /// Thirteen to nineteen digits, spaces and hyphens allowed between them, that pass the check
    /// every payment card number passes (Luhn).
    static func isCardNumber(_ text: String) -> Bool {
        guard text.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }) else { return false }
        let digits = text.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    private static let keyPrefixes = ["sk-", "sk_live_", "sk_test_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_",
                                      "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxs-", "AKIA", "ASIA", "AIza",
                                      "ya29.", "hf_", "npm_", "shpat_", "SG."]

    /// A private key block, a token with a prefix only tokens have, or a signed web token.
    static func isKnownKey(_ text: String) -> Bool {
        if text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") { return true }
        guard !text.contains(where: \.isWhitespace) else { return false }
        if text.count >= 20, keyPrefixes.contains(where: text.hasPrefix) { return true }
        // header.payload.signature, each base64url, the header always starting "eyJ".
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 3, text.hasPrefix("eyJ"), text.count >= 40,
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }) {
            return true
        }
        return false
    }

    /// Common password shapes and strings of four to eight lowercase words without short
    /// connecting words. A list of ordinary words can have exactly the same shape.
    static func isPasswordShaped(_ text: String) -> Bool {
        guard (8...96).contains(text.count) else { return false }
        if text.contains(where: \.isWhitespace) {
            let words = text.components(separatedBy: " ")
            return (4...8).contains(words.count) && words.allSatisfy { word in
                word.count >= 4 && word.allSatisfy { $0.isASCII && $0.isLowercase }
                    && !["with", "from", "that", "this", "have", "your", "when", "will", "were", "then", "they", "please"].contains(word)
            }
        }
        guard link(in: text) == nil, !looksLikeAddress(text), text.contains(where: \.isLowercase) else { return false }
        let digit = text.contains(where: \.isNumber)
        if digit && text.contains(where: \.isUppercase) { return true }
        if digit && text.count >= 10 && text.allSatisfy({ $0.isLetter || $0.isNumber }) { return true }
        let symbols = text.filter { "!@$%^&*?".contains($0) }
        return !symbols.isEmpty && (digit || symbols.count >= 2)
    }

    /// An email address, a file path, or a host with a path: unbroken, with capitals and digits,
    /// and not a secret.
    private static func looksLikeAddress(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") { return true }
        if text.contains("@"), text.range(of: #"^[^@\s]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}$"#,
                                          options: .regularExpression) != nil { return true }
        let host = text.prefix { $0 != "/" }
        if text.contains("/"), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") { return true }
        return false
    }

    /// The link, when the whole text is one web link.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// What two copies are compared by: the text without the spaces and line ends around it.
    static func key(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What `ClipboardHistory.add` did.
public enum ClipboardAddResult: Equatable, Sendable {
    /// New in the list.
    case saved(ClipboardEntry)
    /// Already in the list; it moved to the top.
    case alreadySaved(ClipboardEntry)
    case skipped(ClipboardSkip)
    /// The file could not be read or written now (the phone is locked, or storage failed).
    case failed
}

/// The copies Zone kept, newest first, in the App Group so the keyboard and the app share them.
///
/// Text only, one small JSON file. It is excluded from the iPhone's backups, is not part of a
/// Zone backup (those are built from notes, History and meetings only), is never sent to a paired
/// computer unless the person sends one copy themselves, and is encrypted with the passcode
/// whenever the phone is locked (`.completeFileProtection`): a clipboard holds more private text
/// than a dictation does.
public final class ClipboardHistory: @unchecked Sendable {
    public let directory: URL
    private let fileURL: URL
    private let lock = NSLock()

    /// Posted in this process after the file changed.
    public static let didChange = Notification.Name("ZoneClipboardDidChange")

    /// The history in the App Group container, or nil when the container is out of reach (the
    /// keyboard without Full Access).
    public static let shared: ClipboardHistory? = {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) else {
            return nil
        }
        return ClipboardHistory(directory: container.appendingPathComponent("Library/Application Support/Clipboard", isDirectory: true))
    }()

    public init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("clipboard.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    // MARK: Reading

    /// Newest first; kept copies are in their place by time like the rest.
    public func entries(now: Date = Date()) -> [ClipboardEntry] {
        let file = read()
        return Self.pruned(file.entries, retention: file.retention, now: now)
    }

    public func recent(limit: Int, now: Date = Date()) -> [ClipboardEntry] {
        Array(entries(now: now).prefix(limit))
    }

    /// Case- and diacritic-insensitive, newest first.
    public func search(_ query: String, now: Date = Date()) -> [ClipboardEntry] {
        Self.matches(query, copies: entries(now: now)).copies
    }

    public static func matches(_ query: String, copies: [ClipboardEntry]) -> (copies: [ClipboardEntry], marks: [UUID: [Range<Int>]]) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (copies, [:]) }
        let index = LibrarySearch(documents: copies.map { .init(id: $0.id, text: $0.text, date: $0.savedAt) })
        let byID = Dictionary(copies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hits = index.search(query).hits
        return (hits.compactMap { byID[$0.id] }, Dictionary(hits.map { ($0.id, $0.ranges) }, uniquingKeysWith: { first, _ in first }))
    }

    public var retention: ClipboardRetention { read().retention }

    /// How many copies were not kept, by reason, since the list was last cleared.
    public var skips: [ClipboardSkip: Int] {
        skipCounts(read())
    }

    public var lastWrite: Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func snapshot(now: Date = Date()) -> (copies: [ClipboardEntry], retention: ClipboardRetention, skips: [ClipboardSkip: Int]) {
        let file = read()
        return (Self.pruned(file.entries, retention: file.retention, now: now), file.retention, skipCounts(file))
    }

    private func skipCounts(_ file: File) -> [ClipboardSkip: Int] {
        var counts: [ClipboardSkip: Int] = [:]
        for (raw, count) in file.skips {
            if let reason = ClipboardSkip(rawValue: raw) { counts[reason] = count }
        }
        return counts
    }

    // MARK: Changing

    /// Keeps a copy, unless the rules say not to. The same text as a kept copy moves that copy to
    /// the top instead of being listed twice.
    @discardableResult
    public func add(_ text: String, route: ClipboardRoute, skipsSecrets: Bool = false, now: Date = Date(),
                    canStore: @Sendable () -> Bool = { true }) -> ClipboardAddResult {
        if let reason = ClipboardPolicy.skipAfterReading(text, skipsSecrets: skipsSecrets) {
            // Nothing to count for a copy that was only spaces.
            if reason != .empty { noteSkip(reason, canStore: canStore) }
            return .skipped(reason)
        }
        var result = ClipboardAddResult.failed
        let key = ClipboardPolicy.key(for: text)
        let saved = coordinate(canStore: canStore) { file in
            file.entries = Self.pruned(file.entries, retention: file.retention, now: now)
            if let index = file.entries.firstIndex(where: { $0.imageType == nil && ClipboardPolicy.key(for: $0.text) == key }) {
                var entry = file.entries.remove(at: index)
                // Already the newest: seeing it again is not news, and the time it was saved stands.
                if index > 0 { entry.savedAt = now }
                file.entries.insert(entry, at: 0)
                result = .alreadySaved(entry)
            } else {
                let entry = ClipboardEntry(text: text, savedAt: now, route: route)
                file.entries.insert(entry, at: 0)
                result = .saved(entry)
            }
            file.entries = Self.pruned(file.entries, retention: file.retention, now: now)
        }
        return saved ? result : .failed
    }

    public static let imageBudget = 32 * 1024 * 1024

    public func imageURL(_ id: UUID, thumbnail: Bool = false) -> URL {
        directory.appendingPathComponent(id.uuidString + (thumbnail ? ".thumb" : ".image"))
    }

    @discardableResult
    public func addImage(_ image: ClipboardImage, route: ClipboardRoute, now: Date = Date(),
                         canStore: @Sendable () -> Bool = { true }) -> ClipboardAddResult {
        var entry = ClipboardEntry(text: "Image", savedAt: now, route: route)
        let digest = Data(SHA256.hash(data: image.data))
        entry.imageDigest = digest
        entry.imageType = image.type
        entry.imageBytes = image.data.count + image.thumbnail.count
        let full = imageURL(entry.id)
        let thumb = imageURL(entry.id, thumbnail: true)
        var duplicate: ClipboardEntry?
        var inserted = false
        let saved = coordinate(canStore: canStore) { file in
            file.entries = Self.pruned(file.entries, retention: file.retention, now: now)
            if let index = file.entries.firstIndex(where: { candidate in
                guard candidate.imageType != nil else { return false }
                if let existing = candidate.imageDigest { return existing == digest }
                return (try? Data(contentsOf: imageURL(candidate.id))) == image.data
            }) {
                var existing = file.entries.remove(at: index)
                existing.savedAt = now
                existing.imageDigest = digest
                file.entries.insert(existing, at: 0)
                duplicate = existing
                return
            }
            let entries = Self.pruned([entry] + file.entries, retention: file.retention, now: now)
            guard entries.contains(where: { $0.id == entry.id }) else { return }
            do {
                try image.data.write(to: full, options: Self.writeOptions)
                try image.thumbnail.write(to: thumb, options: Self.writeOptions)
                file.entries = entries
                inserted = true
            } catch {}
        }
        if saved, let duplicate { return .alreadySaved(duplicate) }
        guard saved && inserted else {
            try? FileManager.default.removeItem(at: full)
            try? FileManager.default.removeItem(at: thumb)
            return .failed
        }
        return .saved(entry)
    }

    /// Counts a copy that was not kept. No text is stored with it.
    public func noteSkip(_ reason: ClipboardSkip, canStore: @Sendable () -> Bool = { true }) {
        coordinate(canStore: canStore) { file in file.skips[reason.rawValue, default: 0] += 1 }
    }

    @discardableResult
    public func setPinned(id: UUID, _ pinned: Bool, now: Date = Date()) -> Bool {
        var accepted = false
        let written = coordinate { file in
            guard let index = file.entries.firstIndex(where: { $0.id == id }) else { return }
            if pinned && !file.entries[index].pinned {
                let pins = file.entries.filter(\.pinned) + [file.entries[index]]
                guard pins.count <= ClipboardPolicy.maxEntries,
                      pins.reduce(0, { $0 + $1.text.utf8.count }) <= ClipboardPolicy.maxTotalBytes,
                      pins.reduce(0, { $0 + ($1.imageBytes ?? 0) }) <= Self.imageBudget else { return }
            }
            accepted = true
            file.entries[index].pinned = pinned
            file.entries = Self.pruned(file.entries, retention: file.retention, now: now)
        }
        return written && accepted
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        coordinate { file in file.entries.removeAll { $0.id == id } }
    }

    /// Everything, kept copies included, and the tally of what was not kept.
    @discardableResult
    public func deleteAll() -> Bool {
        coordinate(requireImageCleanup: true) { file in
            file.entries = []
            file.skips = [:]
        }
    }

    @discardableResult
    public func setRetention(_ retention: ClipboardRetention, now: Date = Date()) -> Bool {
        coordinate { file in
            file.retention = retention
            file.entries = Self.pruned(file.entries, retention: retention, now: now)
        }
    }

    /// Removes what has aged out. Reads already hide it; this takes it off the disk.
    public func purgeExpired(now: Date = Date()) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        coordinate { file in file.entries = Self.pruned(file.entries, retention: file.retention, now: now) }
    }

    /// Age, then count, then total size. Kept copies pass all three.
    static func pruned(_ entries: [ClipboardEntry], retention: ClipboardRetention, now: Date) -> [ClipboardEntry] {
        var kept: [ClipboardEntry] = []
        // Pins have their own allowance. The file is in insertion order, which
        // survives clock changes and gives the newest copy first choice of space.
        var imageBytes = 0
        var count = 0
        var bytes = 0
        for entry in entries {
            if entry.pinned { kept.append(entry); continue }
            guard now.timeIntervalSince(entry.savedAt) <= retention.maxAge else { continue }
            guard count < ClipboardPolicy.maxEntries else { continue }
            let size = entry.text.utf8.count
            guard bytes + size <= ClipboardPolicy.maxTotalBytes else { continue }
            let imageSize = entry.imageBytes ?? 0
            guard imageBytes + imageSize <= Self.imageBudget else { continue }
            imageBytes += imageSize
            count += 1
            bytes += size
            kept.append(entry)
        }
        return kept
    }

    // MARK: File

    struct File: Codable, Equatable {
        var retention: ClipboardRetention = .default
        var entries: [ClipboardEntry] = []
        var skips: [String: Int] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey { case retention, entries, skips }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            retention = (try? values.decodeIfPresent(ClipboardRetention.self, forKey: .retention)) ?? .default
            // One entry this build cannot read is dropped alone, not the list with it.
            var list = (try? values.nestedUnkeyedContainer(forKey: .entries))
            var read: [ClipboardEntry] = []
            while var container = list, !container.isAtEnd {
                if let entry = try? container.decode(ClipboardEntry.self) { read.append(entry) }
                else if (try? container.decode(Discarded.self)) == nil { break }
                list = container
            }
            entries = read
            skips = (try? values.decodeIfPresent([String: Int].self, forKey: .skips)) ?? [:]
        }

        /// Any JSON value, read only to step past it.
        private struct Discarded: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }

    private enum Stored {
        case missing
        case decoded(File)
        /// There, and not readable now: the phone is locked, or the bytes are not a list.
        case unreadable
    }

    private func load(at url: URL) -> Stored {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let file = try? JSONDecoder.clipboard.decode(File.self, from: data) else { return .unreadable }
        return .decoded(file)
    }

    private func read() -> File {
        var result = File()
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &error) { url in
            if case .decoded(let file) = load(at: url) { result = file }
        }
        return result
    }

    @discardableResult
    private func coordinate(requireImageCleanup: Bool = false, canStore: @Sendable () -> Bool = { true }, _ change: (inout File) -> Void) -> Bool {
        lock.lock()
        var error: NSError?
        var saved = false
        var changed = false
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forMerging, error: &error) { url in
            guard canStore() else { return }
            var file = File()
            var original: File?
            switch load(at: url) {
            case .missing: break
            case .decoded(let stored):
                file = stored
                original = stored
            case .unreadable:
                // Starting from nothing would replace the list with just this change.
                return
            }
            guard canStore() else { return }
            change(&file)
            // Reconcile under the same cross-process write lock as the index. This also
            // removes files left by a process that ended before it could commit the index.
            func removeUnusedImages() -> Bool {
                let live = Set(file.entries.compactMap { $0.imageType == nil ? nil : $0.id })
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
                var removed = true
                for url in files where ["image", "thumb"].contains(url.pathExtension) {
                    if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !live.contains(id) {
                        do { try FileManager.default.removeItem(at: url) } catch { removed = false }
                    }
                }
                return removed
            }
            if let original, file == original {
                let removed = removeUnusedImages()
                saved = !requireImageCleanup || removed
                return
            }
            do {
                let encoded = try JSONEncoder.clipboard.encode(file)
                guard canStore() else { return }
                try encoded.write(to: url, options: Self.writeOptions)
                let removed = removeUnusedImages()
                saved = !requireImageCleanup || removed
                changed = true
            } catch {}
        }
        lock.unlock()
        if saved && changed && error == nil {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        return saved && error == nil
    }

    /// Unreadable while the phone is locked. The keyboard only shows on an unlocked phone, apart
    /// from a reply on the Lock Screen, where nothing is captured.
    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}

private extension JSONEncoder {
    static let clipboard: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()
}

private extension JSONDecoder {
    static let clipboard: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
