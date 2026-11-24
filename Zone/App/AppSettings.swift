// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import UIKit
import WidgetKit
import ZoneCore

/// User preferences for the app process. The few the keyboard must honor (autocorrect, haptics,
/// the default text style) are mirrored into the shared store whenever they change.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let sessionTimeout = "zone.settings.sessionTimeout"
        static let hiddenKeyboardGrace = "zone.settings.hiddenKeyboardGrace"
        static let finishWhenQuiet = "zone.settings.finishWhenQuiet"
        static let finishWhenQuietWait = "zone.settings.finishWhenQuietWait"
        static let haptics = "zone.settings.haptics"
        static let onboardingDone = "zone.settings.onboardingDone"
        static let typedHints = "zone.settings.typedHints"
        static let autoArm = "zone.settings.autoArm"
        static let appearance = "zone.settings.appearance"
        static let islandLook = "zone.settings.islandLook"
        static let islandWhileReady = "zone.settings.islandWhileReady"
        static let islandControls = "zone.settings.islandControls"
        static let islandTimes = "zone.settings.islandTimes"
        static let islandPalette = "zone.settings.islandPalette"
        static let islandLostNotice = "zone.settings.islandLostNotice"
        static let notesFirst = "zone.settings.notesFirst"
        static let soundSet = "zone.settings.soundSet"
        static let meterStyle = "zone.settings.meterStyle"
        static let micLightStyle = "zone.settings.micLightStyle"
        static let pasteKey = "zone.settings.pasteKey"
        static let emojiPredictions = "zone.settings.emojiPredictions"
        static let clipboardHistory = "zone.settings.clipboardHistory"
        static let clipboardAutomatic = "zone.settings.clipboardAutomatic"
        static let clipboardSkipsSecrets = "zone.settings.clipboardSkipsSecrets"
        static let emojiKey = "zone.settings.emojiKey"
        static let hideHomeButton = "zone.settings.hideHomeButton"
        static let personalWords = "zone.settings.personalWords"
        static let vocabularyMigrated = "zone.settings.vocabularyMigrated"
        static let autoCapitalization = "zone.settings.autoCapitalization"
        static let autocorrect = "zone.settings.autocorrect"
        static let swipeTyping = "zone.settings.swipeTyping"
        static let swipeLearning = "zone.settings.swipeLearning"
        static let swipeReset = "zone.settings.swipeReset"
        static let showSuggestions = "zone.settings.showSuggestions"
        static let dictationFollowsShift = "zone.settings.dictationFollowsShift"
        static let handleRecognition = "zone.settings.handleRecognition"
        static let spokenCorrections = "zone.settings.spokenCorrections"
        static let capsLockDropsPunctuation = "zone.settings.capsLockDropsPunctuation"
        static let checksDoubtfulWords = "zone.settings.checksDoubtfulWords"
        static let dictatesInKeyboard = "zone.settings.dictatesInKeyboard"
        static let neverAppleSpeech = "zone.settings.neverAppleSpeech"
        static let spokenEmoticons = "zone.settings.spokenEmoticons"
        static let fasterDictation = "zone.settings.fasterDictation"
        static let numbers = "zone.settings.numbers"
        static let smallOrdinals = "zone.settings.smallOrdinals"
        static let californiaMode = "zone.settings.californiaMode"
        static let smartPunctuation = "zone.settings.smartPunctuation"
        static let swipeTrailStyle = "zone.settings.swipeTrailStyle"
        static let oneHanded = "zone.settings.oneHanded"
        static let oneHandedSide = "zone.settings.oneHandedSide"
        static let oneHandedWidth = "zone.settings.oneHandedWidth"
        static let spaceHold = "zone.settings.spaceHold"
        static let spaceBar = "zone.settings.spaceBar"
        static let sounds = "zone.settings.sounds"
        static let defaultStyle = "zone.settings.defaultStyle"
        static let wordsDictated = "zone.stats.words"
        static let sharesCompleted = "zone.stats.sharesCompleted"
        static let firstShare = "zone.stats.firstShare"
        static let secondsDictated = "zone.stats.seconds"
        static let wordsTimed = "zone.stats.timedWords"
        static let speakingSeconds = "zone.stats.speakingSeconds"
        static let longestSeconds = "zone.stats.longestSeconds"
        static let longestWords = "zone.stats.longestWords"
        static let cachedTotals = "zone.stats.cachedTotals"
        static let cachedWords = "zone.stats.cachedWords"
        static let cachedSeconds = "zone.stats.cachedSeconds"
        static let statsMigrated = "zone.stats.migrated"
        static let receiptLongest = "zone.stats.receiptLongest"
        static let minutesSaved = "zone.stats.minutesSaved"
        static let longestDate = "zone.stats.longestDate"
        static let milestoneAcknowledged = "zone.milestone.acknowledged"
    }

    @ObservationIgnored private var reconcilingQuickSettings = false
    @ObservationIgnored private var quickSettingStamps: [String: QuickSettingRequest.Stamp]
    @ObservationIgnored private var quickSettingObservation: DarwinObservation?
    // The winning values and their IDs are one recoverable app-owned commit. Older IDs
    // past the receipt window remain covered by the per-setting timestamp watermark.
    struct QuickSettingLedger: Codable {
        var winners: [String: QuickSettingRequest] = [:]
        var appliedIDs: [UUID] = []
        var generation: QuickSettingRequest.Stamp?
        var resetStamps: [String: QuickSettingRequest.Stamp]?
    }
    @ObservationIgnored private(set) var quickSettingLedger: QuickSettingLedger
    private static let ledgerKey = "zone.settings.quickSettingLedger"
    @ObservationIgnored private var pendingPublication: Task<Void, Never>?

    private let defaults: UserDefaults
    private let store: SharedStore
    @ObservationIgnored private let vocabulary: PersonalVocabulary?

    var sessionTimeout: TimeInterval {
        didSet { defaults.set(sessionTimeout, forKey: Key.sessionTimeout) }
    }
    /// How long a keyboard dictation keeps recording with the keyboard out of sight; 0 is until
    /// stopped. Separate from `sessionTimeout`, which is how long the idle mic stays ready.
    var hiddenKeyboardGrace: TimeInterval {
        didSet { defaults.set(hiddenKeyboardGrace, forKey: Key.hiddenKeyboardGrace) }
    }
    /// Finish a dictation by itself once it has been quiet for `finishWhenQuietWait`. Off unless
    /// the person turns it on: a pause to think is part of dictating (`SilenceFinish`).
    var finishWhenQuiet: Bool {
        didSet {
            defaults.set(finishWhenQuiet, forKey: Key.finishWhenQuiet)
            quickSettingEdited(.quiet)
        }
    }
    private var savedQuietWait: TimeInterval
    var finishWhenQuietWait: TimeInterval {
        get { savedQuietWait }
        set {
            savedQuietWait = SilenceFinish.nearestChoice(newValue)
            defaults.set(savedQuietWait, forKey: Key.finishWhenQuietWait)
            quickSettingEdited(.quiet)
        }
    }
    /// Haptics in the app and on the keyboard's keys (the keyboard also needs Full Access).
    var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Key.haptics)
            publishSnapshot()
        }
    }
    /// Automatic corrections in the keyboard.
    var autocorrectEnabled: Bool {
        didSet {
            defaults.set(autocorrectEnabled, forKey: Key.autocorrect)
            publishSnapshot()
        }
    }
    var swipeTypingEnabled: Bool {
        didSet { defaults.set(swipeTypingEnabled, forKey: Key.swipeTyping); publishSnapshot() }
    }
    var swipeLearningEnabled: Bool {
        didSet { defaults.set(swipeLearningEnabled, forKey: Key.swipeLearning); publishSnapshot() }
    }
    var swipeLearningReset: String {
        didSet { defaults.set(swipeLearningReset, forKey: Key.swipeReset); publishSnapshot() }
    }
    func resetSwipeLearning() { swipeLearningReset = UUID().uuidString }

    var autoCapitalizationEnabled: Bool {
        didSet {
            defaults.set(autoCapitalizationEnabled, forKey: Key.autoCapitalization)
            publishSnapshot()
        }
    }
    var showSuggestions: Bool {
        didSet {
            defaults.set(showSuggestions, forKey: Key.showSuggestions)
            publishSnapshot()
        }
    }
    /// A keyboard dictation starts lowercase when Shift shows lowercase, and with a capital when
    /// it shows one, instead of always taking the speech model's capital.
    var dictationFollowsShift: Bool {
        didSet {
            defaults.set(dictationFollowsShift, forKey: Key.dictationFollowsShift)
            publishSnapshot()
        }
    }
    /// Smart @ (Settings > Say “at” to tag names): a spoken "at Kevin" is written "@kevin", a handle for tagging someone.
    var handleRecognition: Bool {
        didSet {
            defaults.set(handleRecognition, forKey: Key.handleRecognition)
            publishSnapshot()
        }
    }
    /// Beta, off by default: "scratch that" and "no wait" take back words while dictating.
    var spokenCorrections: Bool {
        didSet {
            defaults.set(spokenCorrections, forKey: Key.spokenCorrections)
            publishSnapshot()
        }
    }
    /// Beta, off by default: a caps-lock dictation also leaves out commas, periods and apostrophes.
    var capsLockDropsPunctuation: Bool {
        didSet {
            defaults.set(capsLockDropsPunctuation, forKey: Key.capsLockDropsPunctuation)
            publishSnapshot()
        }
    }
    /// Beta, off by default: the keyboard offers the dictated words the engine was least sure of.
    var checksDoubtfulWords: Bool {
        didSet {
            defaults.set(checksDoubtfulWords, forKey: Key.checksDoubtfulWords)
            publishSnapshot()
        }
    }
    @MainActor
    func refreshKeyboardSpeechInForeground(downloadRequested: Bool = false) async {
        guard hasCompletedOnboarding, dictatesInKeyboard else { return }
        await KeyboardSpeechAssets.refresh(store: store, downloadRequested: downloadRequested) {
            KeyboardSpeechAssets.shouldFetch(setupDone: self.hasCompletedOnboarding, enabled: self.dictatesInKeyboard,
                                             fullAccess: self.store.keyboardPresence?.hasFullAccess == true,
                                             active: UIApplication.shared.applicationState == .active,
                                             unlocked: UIApplication.shared.isProtectedDataAvailable)
        }
    }

    /// On by default. With standby off, record in the keyboard using Zone's speech model, with
    /// Apple's model as a fallback.
    var dictatesInKeyboard: Bool {
        didSet {
            defaults.set(dictatesInKeyboard, forKey: Key.dictatesInKeyboard)
            publishSnapshot()
            // Reading availability needs no download. Installing the fallback has its own button.
            if dictatesInKeyboard { Task { @MainActor in await refreshKeyboardSpeechInForeground() } }
            else if oldValue { Task { await WorkerCacheClient.clear() } }
        }
    }
    /// Off by default. On, a recording the keyboard makes by itself is never handed to the
    /// iPhone's own speech model: where Zone's model cannot hear it there, the mic opens Zone.
    var neverAppleSpeech: Bool {
        didSet {
            defaults.set(neverAppleSpeech, forKey: Key.neverAppleSpeech)
            publishKeyboardPreferences()
        }
    }
    /// On by default: a said "smiley face" is ":)" in casual and very casual.
    var spokenEmoticons: Bool {
        didSet {
            defaults.set(spokenEmoticons, forKey: Key.spokenEmoticons)
            publishSnapshot()
        }
    }
    var fasterDictation: Bool { didSet { defaults.set(fasterDictation, forKey: Key.fasterDictation) } }

    /// Settings > Dictation options, off by default: "second place" is "2nd place" in every style.
    var numbers: NumberPreferences {
        didSet {
            defaults.set(try? JSONEncoder().encode(numbers), forKey: Key.numbers)
            publishKeyboardPreferences()
        }
    }

    var smallOrdinals: Bool {
        didSet {
            defaults.set(smallOrdinals, forKey: Key.smallOrdinals)
            publishSnapshot()
        }
    }
    /// Beta, off by default: California Mode takes the filler "like" out of dictation, lightly or
    /// aggressively.
    var californiaMode: CaliforniaMode {
        didSet {
            defaults.set(californiaMode.rawValue, forKey: Key.californiaMode)
            publishSnapshot()
        }
    }
    /// Off by default: curly quotes, long dashes and the ellipsis as they are typed.
    var smartPunctuation: Bool {
        didSet {
            defaults.set(smartPunctuation, forKey: Key.smartPunctuation)
            publishSnapshot()
        }
    }
    /// Accent by default; Rainbow Road turns the trail's hue as the finger travels.
    var swipeTrailStyle: SwipeTrailStyle {
        didSet {
            defaults.set(swipeTrailStyle.rawValue, forKey: Key.swipeTrailStyle)
            publishSnapshot()
        }
    }
    /// What holding space does on the keyboard: move the cursor (the default), or talk (Beta).
    var spaceHold: SpaceHold {
        didSet {
            defaults.set(spaceHold.rawValue, forKey: Key.spaceHold)
            quickSettingEdited(.hold)
        }
    }
    /// What the space bar shows on the keyboard: a line (the default), a voice mark, the word, or nothing.
    var spaceBar: SpaceBarLabel {
        didSet {
            defaults.set(spaceBar.rawValue, forKey: Key.spaceBar)
            publishSnapshot()
        }
    }
    /// The accent shared with extensions through the App Group and mirrored to the Watch.
    var accent: AccentChoice {
        didSet {
            guard accent != oldValue else { return }
            AccentChoice.current = accent
            AccentStore.shared.choice = accent
            PhoneNoteBridge.shared.publishAccent(accent)
            WidgetCenter.shared.reloadTimelines(ofKind: CarWidgetState.widgetKind)
            if #available(iOS 18.0, *) {
                for kind in [CarWidgetState.noteControlKind, CarWidgetState.dictateControlKind,
                             StandbyControlState.controlKind, StandbyControlState.islandControlKind] {
                    ControlCenter.shared.reloadControls(ofKind: kind)
                }
            }
        }
    }
    /// A Paste key: between space and a narrower Return on the full keyboard, and in the top row of
    /// the compact face.
    var showsPasteKey: Bool {
        didSet {
            defaults.set(showsPasteKey, forKey: Key.pasteKey)
            publishSnapshot()
        }
    }
    /// Enables clipboard history and its manual save routes.
    var clipboardHistoryEnabled: Bool {
        didSet {
            if !clipboardHistoryEnabled { clipboardAutomatic = false }
            defaults.set(clipboardHistoryEnabled, forKey: Key.clipboardHistory)
            publishSnapshot()
        }
    }
    /// Separate consent for reading the current clipboard while Zone is visible.
    var clipboardAutomatic: Bool {
        didSet {
            defaults.set(clipboardAutomatic, forKey: Key.clipboardAutomatic)
            publishSnapshot()
        }
    }
    var clipboardSkipsSecrets: Bool {
        didSet {
            defaults.set(clipboardSkipsSecrets, forKey: Key.clipboardSkipsSecrets)
            publishSnapshot()
        }
    }
    /// Off by default: the keys can be narrowed toward one thumb. Hold 123 on the keyboard to
    /// choose left, full width or right.
    var oneHandedEnabled: Bool {
        didSet {
            defaults.set(oneHandedEnabled, forKey: Key.oneHanded)
            publishSnapshot()
        }
    }
    /// The thumb the keys start toward when the mode is turned on or this changes.
    var oneHandedSide: OneHandedSide {
        didSet {
            defaults.set(oneHandedSide.rawValue, forKey: Key.oneHandedSide)
            publishSnapshot()
        }
    }
    /// The keys' share of the keyboard's width in one-handed mode.
    var oneHandedWidth: Double {
        didSet {
            let clamped = OneHandedLayout.clamped(oneHandedWidth)
            if clamped != oneHandedWidth { oneHandedWidth = clamped; return }
            defaults.set(oneHandedWidth, forKey: Key.oneHandedWidth)
            publishSnapshot()
        }
    }
    var emojiPredictions: Bool {
        didSet {
            defaults.set(emojiPredictions, forKey: Key.emojiPredictions)
            publishSnapshot()
        }
    }
    /// An emoji key left of space that opens the keyboard's own emoji panel.
    var showsEmojiKey: Bool {
        didSet {
            defaults.set(showsEmojiKey, forKey: Key.emojiKey)
            publishSnapshot()
        }
    }
    var hideHomeButton: Bool {
        didSet {
            defaults.set(hideHomeButton, forKey: Key.hideHomeButton)
            publishSnapshot()
        }
    }
    /// The voice graphic: the keyboard's while recording, and the app composer's (Wave or Bars).
    var meterStyle: MeterStyle {
        didSet {
            defaults.set(meterStyle.rawValue, forKey: Key.meterStyle)
            quickSettingEdited(.graphic)
        }
    }
    var micLightStyle: MicLightStyle {
        didSet { defaults.set(micLightStyle.rawValue, forKey: Key.micLightStyle) }
    }
    /// The start and stop cues around a dictation.
    var soundsEnabled: Bool {
        didSet {
            defaults.set(soundsEnabled, forKey: Key.sounds)
            quickSettingEdited(.sounds)
        }
    }
    /// Which pair of cues plays (scripts/make-sounds.py writes every set).
    var soundSet: DictationSounds.Set {
        didSet {
            defaults.set(soundSet.rawValue, forKey: Key.soundSet)
            publishSnapshot()
        }
    }
    /// The style dictations use. The keyboard's Z changes it too, and the latest choice wins
    /// (`TextStylePolicy`); `adoptKeyboardStyle()` folds a keyboard pick in here.
    var defaultTextStyle: TextStyle {
        didSet {
            defaults.set(defaultTextStyle.rawValue, forKey: Key.defaultStyle)
            store.chooseDefaultTextStyle(defaultTextStyle)
        }
    }

    /// The keyboard picked a style while the app was away: it becomes the setting, so Settings shows
    /// the style the next dictation uses and picking there always takes effect.
    func adoptKeyboardStyle() {
        guard let picked = store.pendingKeyboardTextStyle else { return }
        defaultTextStyle = picked
    }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingDone) }
    }
    /// Feed the text already in the field to the recognizer as vocabulary hints.
    var usesTypedTextAsHints: Bool {
        didSet { defaults.set(usesTypedTextAsHints, forKey: Key.typedHints) }
    }
    /// Opening Zone starts a session by itself, so one visit makes the mic key work in place.
    var startsSessionOnOpen: Bool {
        didSet { defaults.set(startsSessionOnOpen, forKey: Key.autoArm) }
    }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    /// How Zone draws itself in the Dynamic Island (Settings > Dynamic Island).
    var islandLook: IslandLook {
        didSet { defaults.set(islandLook.rawValue, forKey: Key.islandLook) }
    }
    /// Zone in the Dynamic Island, the switch at the top of Settings > Dynamic Island. On (the
    /// default) Zone keeps a small island while the microphone waits for the keyboard. Off, iOS
    /// shows its own, much wider microphone pill for as long as Zone is ready, and the island
    /// Zone must still show while recording is the plain one (`islandStyle`).
    var islandWhileReady: Bool {
        didSet { defaults.set(islandWhileReady, forKey: Key.islandWhileReady) }
    }
    /// Stop, Pause, Dictate and Note buttons on the island and the Lock Screen card.
    var islandControls: Bool {
        didSet { defaults.set(islandControls, forKey: Key.islandControls) }
    }
    /// Standby's start and end on the island and Lock Screen: clock times or running spans.
    var islandTimes: IslandTimes {
        didSet { defaults.set(islandTimes.rawValue, forKey: Key.islandTimes) }
    }

    /// Old beta color key, kept to restore the saved look.
    var islandPalette: IslandPalette {
        didSet { defaults.set(islandPalette.rawValue, forKey: Key.islandPalette) }
    }

    static let showsIslandGallery = IslandLook.developmentGallery

    /// What the island actually draws. The switch at the top governs the rest: with Zone out
    /// of the island, a recording (which iOS still requires an island for) is the plain Ghost
    /// dot in the accent, with its buttons, whatever the hidden choices below it say.
    var islandStyle: (look: IslandLook, palette: IslandPalette, controls: Bool) {
        guard islandWhileReady else { return (.ghost, .accent, true) }
        if Self.showsIslandGallery { return (.restored(islandLook, palette: islandPalette), .accent, islandControls) }
        // Only these looks could have been chosen in 1.0.5, which had no color picker.
        let legacy = IslandLook.classic.contains(islandLook) && islandPalette == .accent
        return (legacy ? islandLook : .halo, .accent, islandControls)
    }
    /// A notification when iOS ends Zone's island while the microphone is still on in the
    /// background, where Zone cannot make it again (`IslandLostNotice`).
    var islandLostNotice: Bool {
        didSet { defaults.set(islandLostNotice, forKey: Key.islandLostNotice) }
    }

    var notesFirst: Bool {
        didSet { defaults.set(notesFirst, forKey: Key.notesFirst) }
    }

    /// Explicit terms and deliberately corrected selections; never uploaded or replacement rules.
    private(set) var personalWords: [String]
    private(set) var learnsFromCorrections = true
    /// Lowercased personal words Zone learned from a correction, for My Words to show apart.
    private(set) var learnedWords: Set<String> = []
    /// The personal words dictation writes and hints, by the same rule as the keyboard
    /// (`PersonalVocabulary.applied`). `personalWords` stays the full list My words edits.
    var appliedPersonalWords: [String] { PersonalVocabulary.applied(personalWords, learned: learnedWords) }

    /// Learned mishearings: what dictation wrote, lowercased, to what the person retyped
    /// (`PersonalVocabulary.Document.misheard`).
    @ObservationIgnored private(set) var misheard: [String: String] = [:]

    @discardableResult func refreshPersonalWords() -> [String] {
        vocabularyReads += 1
        try? migrateLegacyVocabulary()
        if let document = try? vocabulary?.document() {
            personalWords = document.words
            misheard = document.misheard
            learnsFromCorrections = document.learnsFromCorrections
            learnedWords = Set(document.learned)
        }
        return personalWords
    }

    /// Handles for "at cold" (`PersonalVocabulary.handles`), shared with the keyboard.
    private(set) var handles: [String] = []

    @discardableResult func refreshHandles() -> [String] {
        vocabularyReads += 1
        if let document = try? vocabulary?.document() { handles = document.handles }
        return handles
    }

    func addHandle(_ handle: String) throws {
        guard let vocabulary else { throw CocoaError(.fileNoSuchFile) }
        vocabularyReads += 1
        handles = try vocabulary.addHandles([handle])
    }

    func removeHandles(_ removed: [String]) throws {
        guard let vocabulary else { throw CocoaError(.fileNoSuchFile) }
        vocabularyReads += 1
        handles = try vocabulary.removeHandles(removed)
    }

    func renameHandle(_ handle: String, to name: String) throws {
        guard let vocabulary else { throw CocoaError(.fileNoSuchFile) }
        handles = try vocabulary.renameHandle(handle, to: name)
    }

    @ObservationIgnored private let systemLexicon: SystemLexiconStore?

    /// Imported terms never appear in or overwrite the person's editable My Words list.
    /// Read fresh from disk, which also updates the cache dictation start uses.
    var systemSpeechWords: [String] {
        vocabularyReads += 1
        let words = (try? systemLexicon?.snapshot().speechWords) ?? []
        cachedSystemSpeechWords = words
        return words
    }

    /// Reads the vocabulary and the imported terms from disk, on the calling thread.
    func speechHintWords() -> [String] {
        refreshPersonalWords()
        return PersonalVocabulary.normalized(BuiltInVocabulary.withAll(appliedPersonalWords)
            + SystemLexiconSnapshot.recognizerHints(from: systemSpeechWords))
    }

    // MARK: Vocabulary cache

    /// Imported terms as last read. With `personalWords` this is what dictation start uses:
    /// reading both files there (an NSFileCoordinator round trip each) put disk reads on the
    /// main thread at every start. `refreshVocabularyCache()` rereads them off the main thread
    /// at launch, on return to the foreground and after each dictation starts, so a word the
    /// keyboard learns is in use from the next dictation.
    @ObservationIgnored private(set) var cachedSystemSpeechWords: [String] = []
    /// Counts reads and writes of the vocabulary fields, so a background read that a newer
    /// save or read overtook is dropped instead of restoring older words.
    @ObservationIgnored private var vocabularyReads = 0

    /// The recognizer's hint words from memory only.
    func cachedSpeechHintWords() -> [String] {
        PersonalVocabulary.normalized(BuiltInVocabulary.withAll(appliedPersonalWords)
            + SystemLexiconSnapshot.recognizerHints(from: cachedSystemSpeechWords))
    }

    func refreshVocabularyCache() async {
        vocabularyReads += 1
        let read = vocabularyReads
        let vocabulary = self.vocabulary, lexicon = self.systemLexicon
        let (document, systemWords) = await Task.detached(priority: .utility) {
            (try? vocabulary?.document(), (try? lexicon?.snapshot().speechWords) ?? [])
        }.value
        guard read == vocabularyReads else { return }
        if let document {
            personalWords = document.words
            misheard = document.misheard
            learnsFromCorrections = document.learnsFromCorrections
            learnedWords = Set(document.learned)
            handles = document.handles
        }
        cachedSystemSpeechWords = systemWords
    }

    func exportWordList() async throws -> String {
        guard let vocabulary else { throw CocoaError(.fileReadNoPermission) }
        return try await Task.detached(priority: .userInitiated) {
            WordListCSV.write(try vocabulary.document())
        }.value
    }

    func importWordList(_ text: String) async throws {
        guard let vocabulary else { throw CocoaError(.fileWriteNoPermission) }
        try await Task.detached(priority: .userInitiated) {
            try vocabulary.restore(WordListCSV.read(text))
        }.value
        await refreshVocabularyCache()
    }

    func savePersonalWords(_ words: [String], replacing original: [String]) throws {
        guard let vocabulary else { throw CocoaError(.fileNoSuchFile) }
        try migrateLegacyVocabulary()
        vocabularyReads += 1
        personalWords = try vocabulary.save(words, replacing: original)
        misheard = (try? vocabulary.document().misheard) ?? misheard
        learnedWords = Set((try? vocabulary.document().learned) ?? [])
        defaults.removeObject(forKey: Key.personalWords)
    }

    private func migrateLegacyVocabulary() throws {
        guard !defaults.bool(forKey: Key.vocabularyMigrated), let vocabulary else { return }
        try vocabulary.add(defaults.stringArray(forKey: Key.personalWords) ?? [])
        defaults.set(true, forKey: Key.vocabularyMigrated)
        defaults.removeObject(forKey: Key.personalWords)
    }

    func setLearningFromCorrections(_ enabled: Bool) throws {
        guard let vocabulary else { throw CocoaError(.fileNoSuchFile) }
        try vocabulary.setLearningEnabled(enabled)
        vocabularyReads += 1
        learnsFromCorrections = enabled
    }

    var legacyWords: Int { defaults.bool(forKey: Key.statsMigrated) ? 0 : defaults.integer(forKey: Key.wordsDictated) }
    var legacySeconds: Double { defaults.bool(forKey: Key.statsMigrated) ? 0 : defaults.double(forKey: Key.secondsDictated) }
    var transferTotals: DictationTotals? {
        guard defaults.bool(forKey: Key.statsMigrated) else { return nil }
        if let data = defaults.data(forKey: Key.cachedTotals),
           let cached = try? JSONDecoder().decode(DictationTotals.self, from: data) { return cached }
        // Older builds saved the rounded estimate but neither of its two inputs.
        guard [Key.cachedWords, Key.cachedSeconds, Key.receiptLongest, Key.minutesSaved]
            .contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        var cached = DictationTotals()
        cached.words = wordsDictated
        cached.seconds = secondsDictated
        cached.longest = longestDictation
        cached.legacySavedMinutes = estimatedMinutesSaved
        return cached
    }
    private var measured: DictationTotals?
    private(set) var islandGarden = IslandGardenProgress()
    func applyGarden(_ garden: IslandGardenProgress) {
        var updated = garden
        let previous = defaults.integer(forKey: "zone.island.accessory")
        let earned = max(previous, Int(garden.accessory))
        if earned > previous { defaults.set(earned, forKey: "zone.island.accessory") }
        updated.earnedAccessory = UInt8(clamping: min(3, earned))
        if islandGarden != updated { islandGarden = updated }
    }
    private(set) var wordsDictated: Int
    private(set) var secondsDictated: Double
    private(set) var longestDictation: LongestDictation?
    var wordsPerMinute: Int { DictationStats.wordsPerMinute(words: wordsDictated, recordingSeconds: secondsDictated) }
    private(set) var estimatedMinutesSaved: Int
    func applyStats(_ totals: DictationTotals) {
        guard measured != totals else { return }
        measured = totals
        defaults.set(try? JSONEncoder().encode(totals), forKey: Key.cachedTotals)
        let minutes = totals.minutesSaved
        if estimatedMinutesSaved != minutes {
            estimatedMinutesSaved = minutes
            defaults.set(minutes, forKey: Key.minutesSaved)
        }
        if longestDictation != totals.longest {
            longestDictation = totals.longest
            defaults.set(totals.longest.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.receiptLongest)
        }
        // Only a successfully read or committed archive reaches applyStats. This second
        // marker travels with defaults even if a phone transfer omits the History directory.
        if !defaults.bool(forKey: Key.statsMigrated) { defaults.set(true, forKey: Key.statsMigrated) }
        if wordsDictated != totals.words || defaults.object(forKey: Key.cachedWords) == nil {
            wordsDictated = totals.words
            defaults.set(totals.words, forKey: Key.cachedWords)
        }
        if secondsDictated != totals.seconds || defaults.object(forKey: Key.cachedSeconds) == nil {
            secondsDictated = totals.seconds
            defaults.set(totals.seconds, forKey: Key.cachedSeconds)
        }
    }

    private(set) var sharesCompleted: Int

    func didResetStats() {
        islandGarden = IslandGardenProgress()
        defaults.removeObject(forKey: "zone.island.accessory")
        measured = .init()
        estimatedMinutesSaved = 0
        longestDictation = nil
        wordsDictated = 0
        secondsDictated = 0
        defaults.set(true, forKey: Key.statsMigrated)
        sharesCompleted = 0
        for key in [Key.cachedTotals, Key.cachedWords, Key.cachedSeconds, Key.minutesSaved, Key.receiptLongest, Key.wordsDictated, Key.secondsDictated, Key.wordsTimed, Key.speakingSeconds,
                    Key.sharesCompleted, Key.firstShare, Key.longestSeconds, Key.longestWords, Key.longestDate] {
            defaults.removeObject(forKey: key)
        }
    }

    /// The highest word milestone whose note came up on Home. Recorded the moment it appears,
    /// so a note never comes back, and not a statistic: starting the count over leaves it alone.
    private(set) var milestoneAcknowledged: Int

    /// The milestone note Home owes, if any (`WordMilestones`).
    var pendingMilestone: MilestoneNote? {
        WordMilestones.pending(words: wordsDictated, acknowledged: milestoneAcknowledged)
    }

    func acknowledgeMilestone(_ mark: Int) {
        guard mark > milestoneAcknowledged else { return }
        milestoneAcknowledged = mark
        defaults.set(mark, forKey: Key.milestoneAcknowledged)
    }

    /// When the first share went out, for "over N weeks" on Home.
    var firstShareAt: Date? { defaults.object(forKey: Key.firstShare) as? Date }

    func recordShare() {
        if firstShareAt == nil { defaults.set(Date(), forKey: Key.firstShare) }
        sharesCompleted += 1
        defaults.set(sharesCompleted, forKey: Key.sharesCompleted)
    }
    var inactivityPolicy: InactivityPolicy { InactivityPolicy(timeout: sessionTimeout == 0 ? .infinity : sessionTimeout) }

    init(defaults: UserDefaults = .standard, store: SharedStore = UserDefaultsSharedStore(), vocabulary: PersonalVocabulary? = .shared,
         systemLexicon: SystemLexiconStore? = .shared) {
        var ledger = defaults.data(forKey: Self.ledgerKey).flatMap {
            try? JSONDecoder().decode(QuickSettingLedger.self, from: $0)
        } ?? QuickSettingLedger()
        let published = store.keyboardPreferences
        let priorStamps = published.quickSettingStamps
        let freshLedger = defaults.data(forKey: Self.ledgerKey) == nil
        if ledger.generation == nil {
            ledger.generation = .init(after: published.quickSettingGeneration)
            if freshLedger && (published.quickSettingGeneration != nil || !priorStamps.isEmpty) {
                ledger.resetStamps = Dictionary(uniqueKeysWithValues: QuickSetting.Key.allCases.map {
                    ($0.rawValue, QuickSettingRequest.Stamp(after: priorStamps[$0.rawValue]))
                })
            }
        }
        self.quickSettingLedger = ledger
        self.quickSettingStamps = ledger.resetStamps ?? [:]
        self.defaults = defaults
        self.store = store
        self.vocabulary = vocabulary
        self.systemLexicon = systemLexicon
        let storedTimeout = defaults.double(forKey: Key.sessionTimeout)
        sessionTimeout = defaults.object(forKey: Key.sessionTimeout) == nil ? InactivityPolicy().timeout : storedTimeout
        hiddenKeyboardGrace = defaults.object(forKey: Key.hiddenKeyboardGrace) as? Double ?? DictationLimits.defaultHiddenKeyboardGrace
        finishWhenQuiet = defaults.bool(forKey: Key.finishWhenQuiet)
        // `double(forKey:)` also reads the wait given as text, as a launch argument gives it
        // (`-zone.settings.finishWhenQuietWait 30`); unreadable text is 0, which becomes the default.
        let storedQuietWait = defaults.object(forKey: Key.finishWhenQuietWait) == nil
            ? SilenceFinish.defaultWait : defaults.double(forKey: Key.finishWhenQuietWait)
        savedQuietWait = SilenceFinish.nearestChoice(storedQuietWait)
        swipeTypingEnabled = defaults.bool(forKey: Key.swipeTyping)
        swipeLearningEnabled = defaults.object(forKey: Key.swipeLearning) as? Bool ?? true
        swipeLearningReset = defaults.string(forKey: Key.swipeReset) ?? ""
        showSuggestions = defaults.object(forKey: Key.showSuggestions) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
        autoCapitalizationEnabled = defaults.object(forKey: Key.autoCapitalization) as? Bool ?? true
        autocorrectEnabled = defaults.object(forKey: Key.autocorrect) as? Bool ?? true
        dictationFollowsShift = defaults.object(forKey: Key.dictationFollowsShift) as? Bool ?? true
        handleRecognition = defaults.object(forKey: Key.handleRecognition) as? Bool ?? true
        spokenCorrections = defaults.bool(forKey: Key.spokenCorrections)
        capsLockDropsPunctuation = defaults.bool(forKey: Key.capsLockDropsPunctuation)
        checksDoubtfulWords = defaults.bool(forKey: Key.checksDoubtfulWords)
        dictatesInKeyboard = defaults.object(forKey: Key.dictatesInKeyboard) as? Bool ?? true
        neverAppleSpeech = defaults.bool(forKey: Key.neverAppleSpeech)
        spokenEmoticons = defaults.object(forKey: Key.spokenEmoticons) as? Bool ?? true
        fasterDictation = defaults.bool(forKey: Key.fasterDictation)
        numbers = defaults.data(forKey: Key.numbers).flatMap { try? JSONDecoder().decode(NumberPreferences.self, from: $0) } ?? .init()
        smallOrdinals = defaults.bool(forKey: Key.smallOrdinals)
        californiaMode = CaliforniaMode(rawValue: defaults.string(forKey: Key.californiaMode) ?? "") ?? .off
        smartPunctuation = defaults.bool(forKey: Key.smartPunctuation)
        swipeTrailStyle = SwipeTrailStyle(rawValue: defaults.string(forKey: Key.swipeTrailStyle) ?? "") ?? .accent
        spaceHold = SpaceHold(rawValue: defaults.string(forKey: Key.spaceHold) ?? "") ?? .moveCursor
        spaceBar = SpaceBarLabel(rawValue: defaults.string(forKey: Key.spaceBar) ?? "") ?? .default
        soundsEnabled = defaults.object(forKey: Key.sounds) as? Bool ?? true
        accent = AccentChoice.current
        showsPasteKey = defaults.bool(forKey: Key.pasteKey)
        emojiPredictions = defaults.object(forKey: Key.emojiPredictions) as? Bool ?? true
        clipboardAutomatic = defaults.bool(forKey: Key.clipboardAutomatic)
        clipboardHistoryEnabled = defaults.bool(forKey: Key.clipboardHistory)
        clipboardSkipsSecrets = defaults.object(forKey: Key.clipboardSkipsSecrets) as? Bool ?? false
        showsEmojiKey = defaults.bool(forKey: Key.emojiKey)
        oneHandedEnabled = defaults.bool(forKey: Key.oneHanded)
        oneHandedSide = OneHandedSide(rawValue: defaults.string(forKey: Key.oneHandedSide) ?? "") ?? .right
        oneHandedWidth = OneHandedLayout.clamped(defaults.object(forKey: Key.oneHandedWidth) as? Double ?? OneHandedLayout.defaultWidth)
        hideHomeButton = defaults.object(forKey: Key.hideHomeButton) as? Bool ?? false
        meterStyle = MeterStyle(rawValue: defaults.string(forKey: Key.meterStyle) ?? "") ?? .wave
        micLightStyle = defaults.string(forKey: Key.micLightStyle).flatMap(MicLightStyle.init(rawValue:)) ?? .glow
        soundSet = DictationSounds.Set(rawValue: defaults.string(forKey: Key.soundSet) ?? "") ?? .wood
        defaultTextStyle = defaults.string(forKey: Key.defaultStyle).flatMap(TextStyle.init(rawValue:)) ?? .casual
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingDone)
        usesTypedTextAsHints = defaults.object(forKey: Key.typedHints) as? Bool ?? true
        startsSessionOnOpen = defaults.object(forKey: Key.autoArm) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        islandLook = IslandLook(rawValue: defaults.string(forKey: Key.islandLook) ?? "") ?? .halo
        islandWhileReady = defaults.object(forKey: Key.islandWhileReady) as? Bool ?? true
        islandControls = defaults.object(forKey: Key.islandControls) as? Bool ?? true
        islandTimes = IslandTimes(rawValue: defaults.string(forKey: Key.islandTimes) ?? "") ?? .clock
        islandPalette = IslandPalette(rawValue: defaults.string(forKey: Key.islandPalette) ?? "") ?? .accent
        islandLostNotice = defaults.object(forKey: Key.islandLostNotice) as? Bool ?? true
        notesFirst = defaults.object(forKey: Key.notesFirst) as? Bool ?? true
        let legacyWords = defaults.stringArray(forKey: Key.personalWords) ?? []
        personalWords = legacyWords
        if let vocabulary {
            // Only mark migration after an atomic successful merge. Removed words must not
            // return from the legacy defaults on subsequent app launches.
            if !defaults.bool(forKey: Key.vocabularyMigrated),
               (try? vocabulary.add(legacyWords)) != nil {
                defaults.set(true, forKey: Key.vocabularyMigrated)
                defaults.removeObject(forKey: Key.personalWords)
            }
            if let document = try? vocabulary.document() {
                personalWords = defaults.bool(forKey: Key.vocabularyMigrated)
                    ? document.words : PersonalVocabulary.normalized(document.words + legacyWords)
                if defaults.bool(forKey: Key.vocabularyMigrated) {
                    defaults.removeObject(forKey: Key.personalWords)
                }
                learnsFromCorrections = document.learnsFromCorrections
            learnedWords = Set(document.learned)
            }
        }
        estimatedMinutesSaved = defaults.integer(forKey: Key.minutesSaved)
        longestDictation = defaults.data(forKey: Key.receiptLongest).flatMap { try? JSONDecoder().decode(LongestDictation.self, from: $0) }
        // Pre-release receipt builds reused the migration inputs as live counters.
        // Their display-only keys identify transferred defaults from those builds.
        if defaults.object(forKey: Key.receiptLongest) != nil || defaults.object(forKey: Key.minutesSaved) != nil {
            defaults.set(true, forKey: Key.statsMigrated)
        }
        wordsDictated = defaults.integer(forKey: defaults.object(forKey: Key.cachedWords) == nil ? Key.wordsDictated : Key.cachedWords)
        secondsDictated = defaults.double(forKey: defaults.object(forKey: Key.cachedSeconds) == nil ? Key.secondsDictated : Key.cachedSeconds)
        milestoneAcknowledged = defaults.integer(forKey: Key.milestoneAcknowledged)
        sharesCompleted = defaults.integer(forKey: Key.sharesCompleted)
        reconcilingQuickSettings = true
        let pending = (try? store.quickSettingInbox?.read()) ?? []
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        for winner in quickSettingLedger.winners.values {
            let key = winner.value.key
            let argumentKeys: [String] = switch key {
            case .quiet: [Key.finishWhenQuiet, Key.finishWhenQuietWait]
            case .sounds: [Key.sounds]
            case .graphic: [Key.meterStyle]
            case .hold: [Key.spaceHold]
            }
            quickSettingStamps[key.rawValue] = max(winner.stamp, priorStamps[key.rawValue] ?? winner.stamp)
            // A consumed ID still on disk with no corresponding publication indicates
            // the previous drain stopped between the private commit and publication.
            if pending.contains(winner), winner.isNewer(than: priorStamps),
               !argumentKeys.contains(where: { arguments[$0] != nil }) {
                applyQuickSetting(winner.value)
            }
        }
        reconcilingQuickSettings = false
        if freshLedger || published.quickSettingGeneration == nil { _ = saveQuickSettingLedger() }
        if let inbox = store.quickSettingInbox {
            quickSettingObservation = DarwinNotifier.observe(.quickSettingChanged) { [weak self] in
                self?.schedulePublication(inbox)
            }
        }
        // The keyboard reads these on every appearance; keep the store in step from first launch.
        publishKeyboardPreferences(pending: pending)
        store.defaultTextStyle = defaultTextStyle
    }

    private func schedulePublication(_ inbox: QuickSettingInbox) {
        pendingPublication?.cancel()
        pendingPublication = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return }
            let pending = await Task.detached { (try? inbox.read()) ?? [] }.value
            guard !Task.isCancelled else { return }
            self?.publishKeyboardPreferences(pending: pending)
        }
    }

    private func quickSettingEdited(_ key: QuickSetting.Key) {
        guard !reconcilingQuickSettings else { return }
        let value: QuickSetting
        switch key {
        case .quiet: value = .quiet(enabled: finishWhenQuiet, wait: finishWhenQuietWait)
        case .sounds: value = .sounds(soundsEnabled)
        case .graphic: value = .graphic(meterStyle)
        case .hold: value = .hold(spaceHold)
        }
        let pending = (try? store.quickSettingInbox?.read()) ?? []
        let pendingStamp = pending.filter { $0.value.key == key }.map(\.stamp).max()
        let previous = [pendingStamp, quickSettingStamps[key.rawValue]].compactMap { $0 }.max()
        rememberWinner(QuickSettingRequest(value, after: previous, generation: quickSettingLedger.generation))
        _ = saveQuickSettingLedger()
        publishKeyboardPreferences(pending: pending)
    }

    private func rememberWinner(_ request: QuickSettingRequest) {
        let key = request.value.key.rawValue
        quickSettingStamps[key] = request.stamp
        quickSettingLedger.winners[key] = request
    }

    private func saveQuickSettingLedger() -> Bool {
        guard let data = try? JSONEncoder().encode(quickSettingLedger) else { return false }
        defaults.set(data, forKey: Self.ledgerKey)
        return true
    }

    private func applyQuickSetting(_ value: QuickSetting) {
        switch value {
        case let .quiet(enabled, wait):
            finishWhenQuiet = enabled
            finishWhenQuietWait = SilenceFinish.nearestChoice(wait)
        case let .sounds(enabled): soundsEnabled = enabled
        case let .graphic(style): meterStyle = style
        case let .hold(action): spaceHold = action
        }
    }

    func publishKeyboardPreferences() {
        publishKeyboardPreferences(pending: (try? store.quickSettingInbox?.read()) ?? [])
    }

    func drainBeforeRecording() async {
        guard let inbox = store.quickSettingInbox else { return }
        let pending = await Task.detached { (try? inbox.read()) ?? [] }.value
        publishKeyboardPreferences(pending: pending)
    }

    func publishKeyboardPreferences(pending: [QuickSettingRequest]) {
        reconcilingQuickSettings = true
        defer { reconcilingQuickSettings = false }
        let inbox = store.quickSettingInbox
        let previousIDs = Set(quickSettingLedger.appliedIDs)
        for request in pending where request.isNewer(than: quickSettingStamps) {
            guard request.generation == nil || request.generation == quickSettingLedger.generation,
                  !previousIDs.contains(request.stamp.id) else { continue }
            applyQuickSetting(request.value)
            rememberWinner(request)
            quickSettingLedger.appliedIDs.append(request.stamp.id)
        }
        if quickSettingLedger.appliedIDs.count > 128 {
            quickSettingLedger.appliedIDs = Array(quickSettingLedger.appliedIDs.suffix(128))
        }
        // Flush the private commit before destroying its recovery records.
        let durable = !pending.isEmpty && saveQuickSettingLedger() && defaults.synchronize()
        let snapshot = publishSnapshot()
        if durable, store.confirmKeyboardPreferences(snapshot) {
            inbox?.prune(pending)
        }
    }

    @discardableResult
    private func publishSnapshot() -> KeyboardPreferences {
        let snapshot = keyboardPreferences
        store.keyboardPreferences = snapshot
        return snapshot
    }

    var keyboardPreferences: KeyboardPreferences {
        var snapshot = KeyboardPreferences(autocorrectEnabled: autocorrectEnabled, hapticsEnabled: hapticsEnabled, showSuggestions: showSuggestions, meterStyle: meterStyle, showsPasteKey: showsPasteKey,
            showsEmojiKey: showsEmojiKey, emojiPredictions: emojiPredictions, dictationFollowsShift: dictationFollowsShift, handleRecognition: handleRecognition,
            swipeTypingEnabled: swipeTypingEnabled, swipeLearningEnabled: swipeLearningEnabled, swipeLearningReset: swipeLearningReset, autoCapitalizationEnabled: autoCapitalizationEnabled,
            hideHomeButton: hideHomeButton, spokenCorrections: spokenCorrections,
            capsLockDropsPunctuation: capsLockDropsPunctuation, spokenEmoticons: spokenEmoticons,
            smallOrdinals: smallOrdinals, numbers: numbers, californiaMode: californiaMode, checksDoubtfulWords: checksDoubtfulWords,
            smartPunctuation: smartPunctuation, spaceHold: spaceHold, spaceBar: spaceBar,
            oneHandedEnabled: oneHandedEnabled, oneHandedSide: oneHandedSide, oneHandedWidth: oneHandedWidth,
            clipboardHistoryEnabled: clipboardHistoryEnabled, clipboardSkipsSecrets: clipboardSkipsSecrets, clipboardAutomatic: clipboardAutomatic,
            dictatesInKeyboard: dictatesInKeyboard, neverAppleSpeech: neverAppleSpeech)
        snapshot.swipeTrailStyle = swipeTrailStyle
        snapshot.soundSet = soundSet.rawValue
        snapshot.soundsEnabled = soundsEnabled
        snapshot.finishWhenQuiet = finishWhenQuiet
        snapshot.quietWait = finishWhenQuietWait
        snapshot.quickSettingStamps = quickSettingStamps
        snapshot.quickSettingGeneration = quickSettingLedger.generation
        return snapshot
    }
}
