// by zayd/cold @ zayd.wtf

import Foundation
import Observation
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
        static let notesFirst = "zone.settings.notesFirst"
        static let soundSet = "zone.settings.soundSet"
        static let meterStyle = "zone.settings.meterStyle"
        static let pasteKey = "zone.settings.pasteKey"
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
        static let spokenEmoticons = "zone.settings.spokenEmoticons"
        static let smallOrdinals = "zone.settings.smallOrdinals"
        static let californiaMode = "zone.settings.californiaMode"
        static let smartPunctuation = "zone.settings.smartPunctuation"
        static let spaceHold = "zone.settings.spaceHold"
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
        static let longestDate = "zone.stats.longestDate"
        static let longestBackfilled = "zone.stats.longestBackfilled"
        static let milestoneAcknowledged = "zone.milestone.acknowledged"
    }

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
        didSet { defaults.set(finishWhenQuiet, forKey: Key.finishWhenQuiet) }
    }
    var finishWhenQuietWait: TimeInterval {
        didSet { defaults.set(finishWhenQuietWait, forKey: Key.finishWhenQuietWait) }
    }
    /// Haptics in the app and on the keyboard's keys (the keyboard also needs Full Access).
    var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Key.haptics)
            publishKeyboardPreferences()
        }
    }
    /// Automatic corrections in the keyboard.
    var autocorrectEnabled: Bool {
        didSet {
            defaults.set(autocorrectEnabled, forKey: Key.autocorrect)
            publishKeyboardPreferences()
        }
    }
    var swipeTypingEnabled: Bool {
        didSet { defaults.set(swipeTypingEnabled, forKey: Key.swipeTyping); publishKeyboardPreferences() }
    }
    var swipeLearningEnabled: Bool {
        didSet { defaults.set(swipeLearningEnabled, forKey: Key.swipeLearning); publishKeyboardPreferences() }
    }
    var swipeLearningReset: String {
        didSet { defaults.set(swipeLearningReset, forKey: Key.swipeReset); publishKeyboardPreferences() }
    }
    func resetSwipeLearning() { swipeLearningReset = UUID().uuidString }

    var autoCapitalizationEnabled: Bool {
        didSet {
            defaults.set(autoCapitalizationEnabled, forKey: Key.autoCapitalization)
            publishKeyboardPreferences()
        }
    }
    var showSuggestions: Bool {
        didSet {
            defaults.set(showSuggestions, forKey: Key.showSuggestions)
            publishKeyboardPreferences()
        }
    }
    /// A keyboard dictation starts lowercase when Shift shows lowercase, and with a capital when
    /// it shows one, instead of always taking the speech model's capital.
    var dictationFollowsShift: Bool {
        didSet {
            defaults.set(dictationFollowsShift, forKey: Key.dictationFollowsShift)
            publishKeyboardPreferences()
        }
    }
    /// Experimental: a spoken "at Kevin" is written "@kevin", a handle for tagging someone.
    var handleRecognition: Bool {
        didSet {
            defaults.set(handleRecognition, forKey: Key.handleRecognition)
            publishKeyboardPreferences()
        }
    }
    /// Beta, off by default: "scratch that" and "no wait" take back words while dictating.
    var spokenCorrections: Bool {
        didSet {
            defaults.set(spokenCorrections, forKey: Key.spokenCorrections)
            publishKeyboardPreferences()
        }
    }
    /// Beta, off by default: a caps-lock dictation also leaves out commas, periods and apostrophes.
    var capsLockDropsPunctuation: Bool {
        didSet {
            defaults.set(capsLockDropsPunctuation, forKey: Key.capsLockDropsPunctuation)
            publishKeyboardPreferences()
        }
    }
    /// Beta, off by default: the keyboard offers the dictated words the engine was least sure of.
    var checksDoubtfulWords: Bool {
        didSet {
            defaults.set(checksDoubtfulWords, forKey: Key.checksDoubtfulWords)
            publishKeyboardPreferences()
        }
    }
    /// On by default: a said "smiley face" is ":)" in casual and very casual.
    var spokenEmoticons: Bool {
        didSet {
            defaults.set(spokenEmoticons, forKey: Key.spokenEmoticons)
            publishKeyboardPreferences()
        }
    }
    /// Experimental, off by default: "second place" is "2nd place" in every style.
    var smallOrdinals: Bool {
        didSet {
            defaults.set(smallOrdinals, forKey: Key.smallOrdinals)
            publishKeyboardPreferences()
        }
    }
    /// Beta, off by default: California Mode takes the filler "like" out of dictation, lightly or
    /// aggressively.
    var californiaMode: CaliforniaMode {
        didSet {
            defaults.set(californiaMode.rawValue, forKey: Key.californiaMode)
            publishKeyboardPreferences()
        }
    }
    /// Off by default: curly quotes, long dashes and the ellipsis as they are typed.
    var smartPunctuation: Bool {
        didSet {
            defaults.set(smartPunctuation, forKey: Key.smartPunctuation)
            publishKeyboardPreferences()
        }
    }
    /// What holding space does on the keyboard: move the cursor (the default), or talk (Beta).
    var spaceHold: SpaceHold {
        didSet {
            defaults.set(spaceHold.rawValue, forKey: Key.spaceHold)
            publishKeyboardPreferences()
        }
    }
    /// The accent color for the app and the keyboard, stored in the App Group.
    var accent: AccentChoice {
        didSet {
            AccentChoice.current = accent
            AccentStore.shared.choice = accent
        }
    }
    /// A Paste key: between space and a narrower Return on the full keyboard, and in the top row of
    /// the compact face.
    var showsPasteKey: Bool {
        didSet {
            defaults.set(showsPasteKey, forKey: Key.pasteKey)
            publishKeyboardPreferences()
        }
    }
    /// An emoji key left of space that opens the keyboard's own emoji panel.
    var showsEmojiKey: Bool {
        didSet {
            defaults.set(showsEmojiKey, forKey: Key.emojiKey)
            publishKeyboardPreferences()
        }
    }
    var hideHomeButton: Bool {
        didSet {
            defaults.set(hideHomeButton, forKey: Key.hideHomeButton)
            publishKeyboardPreferences()
        }
    }
    /// The voice graphic: the keyboard's while recording, and the app composer's (Wave or Bars).
    var meterStyle: MeterStyle {
        didSet {
            defaults.set(meterStyle.rawValue, forKey: Key.meterStyle)
            publishKeyboardPreferences()
        }
    }
    /// The start and stop cues around a dictation.
    var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.sounds) }
    }
    /// Which pair of cues plays (scripts/make-sounds.py writes every set).
    var soundSet: DictationSounds.Set {
        didSet { defaults.set(soundSet.rawValue, forKey: Key.soundSet) }
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
    /// Keep a small Zone island while the microphone waits for the keyboard. Without it iOS
    /// shows its own, much wider microphone pill for as long as Zone is ready.
    var islandWhileReady: Bool {
        didSet { defaults.set(islandWhileReady, forKey: Key.islandWhileReady) }
    }
    /// Stop, Pause, Dictate and Note buttons on the island and the Lock Screen card.
    var islandControls: Bool {
        didSet { defaults.set(islandControls, forKey: Key.islandControls) }
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

    /// `sessionTimeout` of 0 means a session that only ends when the user ends it.
    /// Running totals, kept on the phone only.
    private(set) var wordsDictated: Int
    /// Times the share card actually went out (the share sheet reported completion). Installs
    /// from a share cannot be attributed without a server, so this counts what Zone can see.
    private(set) var sharesCompleted: Int

    /// Settings > Your data: start the word count, speed, share totals and longest dictation over.
    func resetStats() {
        wordsDictated = 0
        secondsDictated = 0
        wordsTimed = 0
        speakingSeconds = 0
        sharesCompleted = 0
        longestDictation = nil
        for key in [Key.wordsDictated, Key.secondsDictated, Key.wordsTimed, Key.speakingSeconds,
                    Key.sharesCompleted, Key.firstShare, Key.longestSeconds, Key.longestWords, Key.longestDate] {
            defaults.removeObject(forKey: key)
        }
        // A reset stays reset: the history backfill must never bring the old record back, even
        // one that had not run yet.
        defaults.set(true, forKey: Key.longestBackfilled)
    }

    /// The longest single dictation, the personal record on Home. Nil until one has words.
    private(set) var longestDictation: LongestDictation?

    /// True until the one-time history backfill has run, so launch reads history only once ever.
    var needsLongestBackfill: Bool { !defaults.bool(forKey: Key.longestBackfilled) }

    /// Dictations from before the record existed: keep whichever is longer, the history's or
    /// what was recorded since, and never look again. Takes the result, not the records, so the
    /// caller can work it out off the main actor and hand over one small value.
    func backfillLongest(historyLongest: LongestDictation?) {
        guard needsLongestBackfill else { return }
        if let found = historyLongest {
            storeLongest(DictationStats.longest(longestDictation, after: found.seconds, words: found.words, at: found.date))
        }
        defaults.set(true, forKey: Key.longestBackfilled)
    }

    func backfillLongest(from records: [TranscriptRecord]) {
        backfillLongest(historyLongest: DictationStats.longest(in: records))
    }

    private func storeLongest(_ record: LongestDictation?) {
        guard record != longestDictation else { return }
        longestDictation = record
        guard let record else { return }
        defaults.set(record.seconds, forKey: Key.longestSeconds)
        defaults.set(record.words, forKey: Key.longestWords)
        defaults.set(record.date, forKey: Key.longestDate)
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
    /// Whole recordings, pauses included: what dictating cost, for the time saved.
    private(set) var secondsDictated: Double
    /// Words from dictations whose speaking time was measured, and that time (`SpeakingTime`).
    /// Dictations from before 1.0.5 have no speaking time, so they stay out of these two.
    private(set) var wordsTimed: Int
    private(set) var speakingSeconds: Double

    /// Speaking speed, as Wispr Flow measures it: words over time spent speaking. Until a minute
    /// of speech has been measured, the older words over whole recordings, so an update never
    /// blanks the number.
    var wordsPerMinute: Int {
        if speakingSeconds >= 60 { return DictationStats.wordsPerMinute(words: wordsTimed, speakingSeconds: speakingSeconds) }
        return DictationStats.wordsPerMinute(words: wordsDictated, speakingSeconds: secondsDictated)
    }

    func record(words: Int, seconds: Double, speakingSeconds speaking: Double? = nil, at date: Date = Date()) {
        wordsDictated += words
        secondsDictated += seconds
        defaults.set(wordsDictated, forKey: Key.wordsDictated)
        defaults.set(secondsDictated, forKey: Key.secondsDictated)
        storeLongest(DictationStats.longest(longestDictation, after: seconds, words: words, at: date))
        guard let speaking, speaking > 0 else { return }
        wordsTimed += words
        speakingSeconds += speaking
        defaults.set(wordsTimed, forKey: Key.wordsTimed)
        defaults.set(speakingSeconds, forKey: Key.speakingSeconds)
    }

    var inactivityPolicy: InactivityPolicy { InactivityPolicy(timeout: sessionTimeout == 0 ? .infinity : sessionTimeout) }

    init(defaults: UserDefaults = .standard, store: SharedStore = UserDefaultsSharedStore(), vocabulary: PersonalVocabulary? = .shared,
         systemLexicon: SystemLexiconStore? = .shared) {
        self.defaults = defaults
        self.store = store
        self.vocabulary = vocabulary
        self.systemLexicon = systemLexicon
        let storedTimeout = defaults.double(forKey: Key.sessionTimeout)
        sessionTimeout = defaults.object(forKey: Key.sessionTimeout) == nil ? InactivityPolicy().timeout : storedTimeout
        hiddenKeyboardGrace = defaults.object(forKey: Key.hiddenKeyboardGrace) as? Double ?? DictationLimits.defaultHiddenKeyboardGrace
        finishWhenQuiet = defaults.bool(forKey: Key.finishWhenQuiet)
        let storedQuietWait = defaults.object(forKey: Key.finishWhenQuietWait) as? Double ?? SilenceFinish.defaultWait
        finishWhenQuietWait = SilenceFinish.waitChoices.contains(storedQuietWait) ? storedQuietWait : SilenceFinish.defaultWait
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
        spokenEmoticons = defaults.object(forKey: Key.spokenEmoticons) as? Bool ?? true
        smallOrdinals = defaults.bool(forKey: Key.smallOrdinals)
        californiaMode = CaliforniaMode(rawValue: defaults.string(forKey: Key.californiaMode) ?? "") ?? .off
        smartPunctuation = defaults.bool(forKey: Key.smartPunctuation)
        spaceHold = SpaceHold(rawValue: defaults.string(forKey: Key.spaceHold) ?? "") ?? .moveCursor
        soundsEnabled = defaults.object(forKey: Key.sounds) as? Bool ?? true
        accent = AccentChoice.current
        showsPasteKey = defaults.bool(forKey: Key.pasteKey)
        showsEmojiKey = defaults.bool(forKey: Key.emojiKey)
        hideHomeButton = defaults.object(forKey: Key.hideHomeButton) as? Bool ?? false
        meterStyle = MeterStyle(rawValue: defaults.string(forKey: Key.meterStyle) ?? "") ?? .wave
        soundSet = DictationSounds.Set(rawValue: defaults.string(forKey: Key.soundSet) ?? "") ?? .chime
        defaultTextStyle = defaults.string(forKey: Key.defaultStyle).flatMap(TextStyle.init(rawValue:)) ?? .casual
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingDone)
        usesTypedTextAsHints = defaults.object(forKey: Key.typedHints) as? Bool ?? true
        startsSessionOnOpen = defaults.object(forKey: Key.autoArm) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        islandLook = IslandLook(rawValue: defaults.string(forKey: Key.islandLook) ?? "") ?? .halo
        islandWhileReady = defaults.object(forKey: Key.islandWhileReady) as? Bool ?? true
        islandControls = defaults.object(forKey: Key.islandControls) as? Bool ?? true
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
        wordsDictated = defaults.integer(forKey: Key.wordsDictated)
        milestoneAcknowledged = defaults.integer(forKey: Key.milestoneAcknowledged)
        sharesCompleted = defaults.integer(forKey: Key.sharesCompleted)
        secondsDictated = defaults.double(forKey: Key.secondsDictated)
        wordsTimed = defaults.integer(forKey: Key.wordsTimed)
        speakingSeconds = defaults.double(forKey: Key.speakingSeconds)
        if let date = defaults.object(forKey: Key.longestDate) as? Date {
            longestDictation = LongestDictation(seconds: defaults.double(forKey: Key.longestSeconds),
                                                words: defaults.integer(forKey: Key.longestWords), date: date)
        }
        // The keyboard reads these on every appearance; keep the store in step from first launch.
        publishKeyboardPreferences()
        store.defaultTextStyle = defaultTextStyle
    }

    private func publishKeyboardPreferences() {
        store.keyboardPreferences = KeyboardPreferences(autocorrectEnabled: autocorrectEnabled, hapticsEnabled: hapticsEnabled, showSuggestions: showSuggestions, meterStyle: meterStyle, showsPasteKey: showsPasteKey,
            showsEmojiKey: showsEmojiKey, dictationFollowsShift: dictationFollowsShift, handleRecognition: handleRecognition,
            swipeTypingEnabled: swipeTypingEnabled, swipeLearningEnabled: swipeLearningEnabled, swipeLearningReset: swipeLearningReset, autoCapitalizationEnabled: autoCapitalizationEnabled,
            hideHomeButton: hideHomeButton, spokenCorrections: spokenCorrections,
            capsLockDropsPunctuation: capsLockDropsPunctuation, spokenEmoticons: spokenEmoticons,
            smallOrdinals: smallOrdinals, californiaMode: californiaMode, checksDoubtfulWords: checksDoubtfulWords,
            smartPunctuation: smartPunctuation, spaceHold: spaceHold)
    }
}
