// by zayd/cold @ zayd.wtf

import Foundation

/// Settings the app owns that the keyboard must honor. Written by the app into the shared store
/// whenever they change; the keyboard reads them on every appearance. When it cannot read the
/// record (no Full Access, or a read before the system settled it) it keeps the last record it read
/// (`LastKeyboardPreferences`), and only a keyboard that never read one uses these defaults.
/// How the voice is drawn while recording. Wave, Mirrored and Bars are meters. Scope is Hex's
/// braided dot oscilloscope. The rest are drawn graphics (`VoiceArtEngine`): the voice writes,
/// grows or plays something instead of being measured.
public enum MeterStyle: String, Codable, CaseIterable, Sendable {
    case wave, mirrored, bars, scope, ink, glyphs, branch, inkblot, lanes, stars
    public var label: String {
        switch self {
        case .wave: "Wave"
        case .mirrored: "Mirrored"
        case .bars: "Bars"
        case .scope: "Scope"
        case .ink: "Ink"
        case .glyphs: "Glyphs"
        case .branch: "Branch"
        case .inkblot: "Inkblot"
        case .lanes: "Lanes"
        case .stars: "Stars"
        }
    }

    /// Drawn by `VoiceArtEngine`.
    public var isDrawn: Bool {
        switch self {
        case .ink, .glyphs, .branch, .inkblot, .lanes, .stars: true
        case .wave, .mirrored, .bars, .scope: false
        }
    }
}

public struct KeyboardPreferences: Codable, Equatable, Sendable {
    /// Correct a keyed word on a separator when a conservative candidate is available.
    public var autocorrectEnabled: Bool
    /// Automatically capitalize sentence starts and dictionary corrections. Manual Shift still works.
    public var autoCapitalizationEnabled: Bool
    /// Suggestion controls are optional independently of automatic corrections.
    public var showSuggestions: Bool
    /// Light haptics on key taps (needs Full Access on a device) and on dictation events.
    public var hapticsEnabled: Bool
    public var meterStyle: MeterStyle
    /// A Paste key beside a narrower Return in the compact dictation face.
    public var showsPasteKey: Bool
    /// An emoji key left of space that opens the keyboard's own emoji panel.
    public var showsEmojiKey: Bool
    /// Hide the standalone Zone home mark. App navigation remains in the keyboard key's menu.
    public var hideHomeButton: Bool
    /// A dictation starts the way Shift shows: lowercase when Shift is off (a field without
    /// auto-capitalization, or Shift turned off by hand), a capital when it is on.
    public var dictationFollowsShift: Bool
    /// Optional English glide input, disabled until explicitly enabled.
    public var swipeTypingEnabled: Bool
    public var swipeLearningEnabled: Bool
    public var swipeLearningReset: String
    /// Experimental: a spoken "at Kevin" is written "@kevin", a handle for tagging someone.
    public var handleRecognition: Bool
    /// Beta, off by default: "scratch that" and "no wait" remove words (`SpokenRepair`).
    public var spokenCorrections: Bool
    /// Beta, off by default: a dictation with Shift locked leaves out commas, periods and
    /// apostrophes as well as being written in capitals.
    public var capsLockDropsPunctuation: Bool
    /// A said "smiley face" is written ":)" in the texting styles (`SpokenEmoticons`).
    public var spokenEmoticons: Bool
    /// Experimental: first through ninth written 1st to 9th where they rank something (`SpokenOrdinals`).
    public var smallOrdinals: Bool
    /// Beta, off by default: California Mode removes the filler "like" from dictation.
    public var californiaMode: CaliforniaMode
    /// Beta, off by default: after a dictation the strip shows up to three words the speech
    /// engine was least sure of, each one tap from a fix (`DoubtfulWords`).
    public var checksDoubtfulWords: Bool
    /// Off by default: curly quotes, long dashes and the ellipsis as they are typed (`SmartPunctuation`).
    public var smartPunctuation: Bool
    /// What holding space does: move the cursor (the default) or, in Beta, talk (`SpaceTalk`).
    public var spaceHold: SpaceHold

    public init(autocorrectEnabled: Bool = true, hapticsEnabled: Bool = true, showSuggestions: Bool = true,
                meterStyle: MeterStyle = .wave, showsPasteKey: Bool = false, showsEmojiKey: Bool = false,
                dictationFollowsShift: Bool = true, handleRecognition: Bool = true, swipeTypingEnabled: Bool = false,
                swipeLearningEnabled: Bool = true, swipeLearningReset: String = "", autoCapitalizationEnabled: Bool = true,
                hideHomeButton: Bool = false, spokenCorrections: Bool = false,
                capsLockDropsPunctuation: Bool = false, spokenEmoticons: Bool = true,
                smallOrdinals: Bool = false, californiaMode: CaliforniaMode = .off, checksDoubtfulWords: Bool = false,
                smartPunctuation: Bool = false, spaceHold: SpaceHold = .moveCursor) {
        self.autocorrectEnabled = autocorrectEnabled
        self.autoCapitalizationEnabled = autoCapitalizationEnabled
        self.hapticsEnabled = hapticsEnabled
        self.showSuggestions = showSuggestions
        self.meterStyle = meterStyle
        self.showsPasteKey = showsPasteKey
        self.showsEmojiKey = showsEmojiKey
        self.hideHomeButton = hideHomeButton
        self.dictationFollowsShift = dictationFollowsShift
        self.swipeTypingEnabled = swipeTypingEnabled
        self.swipeLearningEnabled = swipeLearningEnabled
        self.swipeLearningReset = swipeLearningReset
        self.handleRecognition = handleRecognition
        self.spokenCorrections = spokenCorrections
        self.capsLockDropsPunctuation = capsLockDropsPunctuation
        self.spokenEmoticons = spokenEmoticons
        self.smallOrdinals = smallOrdinals
        self.californiaMode = californiaMode
        self.checksDoubtfulWords = checksDoubtfulWords
        self.smartPunctuation = smartPunctuation
        self.spaceHold = spaceHold
    }
    private enum CodingKeys: String, CodingKey {
        case autoCapitalizationEnabled, autocorrectEnabled, hapticsEnabled, showSuggestions, meterStyle, showsPasteKey, showsEmojiKey,
             dictationFollowsShift, handleRecognition, swipeTypingEnabled, swipeLearningEnabled, swipeLearningReset, hideHomeButton,
             spokenCorrections, capsLockDropsPunctuation, spokenEmoticons, smallOrdinals, californiaMode, checksDoubtfulWords,
             smartPunctuation, spaceHold
    }

    public init(from decoder: Decoder) throws {
        // Field by field: one value this build cannot read (a meter style added later, a wrong
        // type) falls back alone instead of failing the record, which reset every switch,
        // autocorrect included, to its default.
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoCapitalizationEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .autoCapitalizationEnabled)) ?? true
        autocorrectEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .autocorrectEnabled)) ?? true
        hapticsEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled)) ?? true
        showSuggestions = (try? values.decodeIfPresent(Bool.self, forKey: .showSuggestions)) ?? true
        meterStyle = (try? values.decodeIfPresent(MeterStyle.self, forKey: .meterStyle)) ?? .wave
        showsPasteKey = (try? values.decodeIfPresent(Bool.self, forKey: .showsPasteKey)) ?? false
        showsEmojiKey = (try? values.decodeIfPresent(Bool.self, forKey: .showsEmojiKey)) ?? false
        hideHomeButton = (try? values.decodeIfPresent(Bool.self, forKey: .hideHomeButton)) ?? false
        dictationFollowsShift = (try? values.decodeIfPresent(Bool.self, forKey: .dictationFollowsShift)) ?? true
        swipeTypingEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .swipeTypingEnabled)) ?? false
        swipeLearningEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .swipeLearningEnabled)) ?? true
        swipeLearningReset = (try? values.decodeIfPresent(String.self, forKey: .swipeLearningReset)) ?? ""
        handleRecognition = (try? values.decodeIfPresent(Bool.self, forKey: .handleRecognition)) ?? true
        spokenCorrections = (try? values.decodeIfPresent(Bool.self, forKey: .spokenCorrections)) ?? false
        capsLockDropsPunctuation = (try? values.decodeIfPresent(Bool.self, forKey: .capsLockDropsPunctuation)) ?? false
        spokenEmoticons = (try? values.decodeIfPresent(Bool.self, forKey: .spokenEmoticons)) ?? true
        smallOrdinals = (try? values.decodeIfPresent(Bool.self, forKey: .smallOrdinals)) ?? false
        californiaMode = (try? values.decodeIfPresent(CaliforniaMode.self, forKey: .californiaMode)) ?? .off
        checksDoubtfulWords = (try? values.decodeIfPresent(Bool.self, forKey: .checksDoubtfulWords)) ?? false
        smartPunctuation = (try? values.decodeIfPresent(Bool.self, forKey: .smartPunctuation)) ?? false
        spaceHold = (try? values.decodeIfPresent(SpaceHold.self, forKey: .spaceHold)) ?? .moveCursor
    }
}

/// The keyboard's own copy of the last `KeyboardPreferences` it read from the App Group, kept in
/// the keyboard's container. When the shared record cannot be read, the keyboard keeps what the
/// app last said instead of falling back to the defaults, which turn swipe, Paste and
/// suggestions off while the app still shows them on.
public struct LastKeyboardPreferences {
    static let key = "zone.keyboard.lastPreferences"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The app's record when there is one (remembered for next time), else the last one read,
    /// else the defaults.
    public func resolve(stored: KeyboardPreferences?) -> KeyboardPreferences {
        let last = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(KeyboardPreferences.self, from: $0) }
        guard let stored else { return last ?? KeyboardPreferences() }
        if stored != last, let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.key)
        }
        return stored
    }
}

/// Which face the keyboard shows: the full key rows, or the compact dictation surface that is
/// about a quarter of the screen. Toggled from the keyboard itself and remembered here so the
/// next appearance opens the way it was left.
public enum KeyboardMode: String, Codable, Equatable, Sendable, CaseIterable {
    case type
    case dictate

    public var toggled: KeyboardMode { self == .type ? .dictate : .type }
}
