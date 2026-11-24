// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import UIKit
import ZoneCore

enum ShiftState: Equatable {
    case off
    /// Next letter is uppercase, then back to off.
    case on
    /// Caps lock.
    case locked

    var isActive: Bool { self != .off }
}

/// Typing state for the key grid and the suggestion row. The mic flow lives in `MicController`.
///
/// Keys give their click and haptic on touch-down and type on release, like the system keyboard,
/// except delete, which deletes on touch-down and repeats while held. Autocorrect only ever
/// touches the word the user keyed in this keyboard (`keyedWord`), never dictated or pasted text.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var layer: KeyboardLayer = .letters
    private(set) var shift: ShiftState = .off
    private(set) var needsGlobe = false
    private(set) var returnLabel = "return"
    private(set) var fieldKeys: [String] = []
    /// False while the field is empty and has no use for return; the key is drawn dimmed.
    private(set) var returnEnabled = true
    /// The host's explicit light or dark request; nil means follow the system style.
    private(set) var explicitDark: Bool?
    /// The system style from the controller's traits. SwiftUI's colorScheme in the hosting view
    /// went stale when the style flipped with the keyboard up (simulator, 2026-11-02), so the
    /// strip reads this instead, the same source the key grid uses.
    private(set) var systemDark = false
    /// Hosts fill keyboardAppearance from the style at the moment the field focused, and Messages
    /// keeps reporting it after the system flips light and dark (logged on the simulator
    /// 2026-11-02: style dark, appearance still light). When the style flips under a field and the
    /// reported appearance matched the old style, it was a copy, not a choice, and is ignored until
    /// the next field. An app that pins dark against a light system keeps its dark keyboard.
    @ObservationIgnored private var appearanceOutdated = false
    @ObservationIgnored private var lastSystemDark: Bool?
    private(set) var hasFullAccess = false
    /// Slots for the suggestion row; empty when no keyed word sits at the cursor or autocorrect is off.
    private(set) var suggestions: [Suggestion] = []
    private(set) var emojiSuggestions: [EmojiSearchIndex.Match] = []
    @ObservationIgnored private var emojiCode: (code: EmojiShortcode, session: String)?
    @ObservationIgnored private var spacedEmojiWord: String?
    private struct EmojiUndo {
        let code: EmojiShortcode
        let session: String
        let emoji: String
        let literal: String
        let replaced: String
        var predictionWord: String? = nil
    }

    @ObservationIgnored private var emojiUndo: EmojiUndo?
    @ObservationIgnored private var emojiUndoDeadline: TimeInterval?
    @ObservationIgnored private var emojiPending: (emoji: String?, closed: Bool, deadline: TimeInterval)?
    @ObservationIgnored private var writingEmoji = false
    private var dictationOwnsStrip = false
    @ObservationIgnored private var emojiShownQuery: String?
    @ObservationIgnored private var loadingEmojiSearch = false
    private(set) var preferences = KeyboardPreferences()
    /// Bumped when the accent changes while the keyboard is up, so the SwiftUI strip makes a new
    /// `KeyboardTheme` (its colors are statics SwiftUI cannot observe). `KeyboardRootView` reads
    /// it in `body`; nothing else depends on its value.
    private(set) var appearanceVersion = 0
    /// The emoji panel has the keys' place (`EmojiPanelView`).
    private(set) var showsEmoji = false
    /// Where the keys sit: full width, or narrowed toward one thumb (`OneHandedLayout`). Always full
    /// while Settings has the one-handed keyboard off.
    private(set) var hand: KeyboardHand = .full
    /// The keyboard's own memory of `hand`, across apps and relaunches. Tests give it their own suite.
    @ObservationIgnored var handMemory = LocalKeyboardHand()

    @ObservationIgnored private var lastPrefersNumbers: Bool?
    /// When the coalesced host reconciliation should run (`Date` seconds); nil when none is due.
    @ObservationIgnored private var reconcileDeadline: TimeInterval?
    /// One delayed block is in flight at a time; it reschedules itself while keys keep coming,
    /// instead of a Task created and cancelled on every key.
    @ObservationIgnored private var reconcileScheduled = false
    @ObservationIgnored private var localContextTail: String?
    @ObservationIgnored private var fieldSession: String?
    @ObservationIgnored private var manualShiftPending = false
    @ObservationIgnored private var suggestionWord: String?
    @ObservationIgnored private var suggestionSession: String?
    /// While the row holds whole next words: the end of the text they follow, and the words in
    /// dictionary casing. A tap writes one only where the field still ends that way.
    @ObservationIgnored private var predictionTail: String?
    @ObservationIgnored private var predictedWords: [String] = []
    /// A whole word the person selected: the row offers its alternatives, and a tap replaces
    /// exactly that selection. Cleared as soon as the selection or the field is anything else.
    @ObservationIgnored private var selectedWordTarget: (word: String, session: String)?
    @ObservationIgnored private var correctionLearning = SelectedWordCorrection()
    /// Backspacing over the last dictated word and typing it right (`DictatedWordCorrection`).
    @ObservationIgnored private var dictatedCorrection = DictatedWordCorrection()
    /// A word was replaced by hand (original, replacement), whether or not it was learned: the
    /// unsure-word check counts the fix (`MicController.wordCorrectedByHand`).
    @ObservationIgnored var onWordCorrected: ((String, String) -> Void)?
    @ObservationIgnored private var vocabularyWords: [String]?
    @ObservationIgnored private var learnsFromCorrections = false
    @ObservationIgnored private var selectionRefreshRequested = false
    static let vocabularyQueue = DispatchQueue(label: "wtf.zayd.zone.vocabulary", qos: .utility)
    /// Suggestions/host reconciliation can wait briefly; inserting a key never waits for them.
    static let advisoryDelay: TimeInterval = 0.075
    @ObservationIgnored private weak var proxy: TextProxyActions?
    /// Key clicks and haptics; the mic controller shares it for its own taps.
    @ObservationIgnored let feedback: KeyFeedback
    @ObservationIgnored private var lastShiftTap: Date?
    @ObservationIgnored private var deleteRepeatTask: Task<Void, Never>?
    @ObservationIgnored private var corrector: Autocorrector?
    /// The letters right above the space bar as drawn, kept until the shared corrector has loaded.
    @ObservationIgnored private var spaceBarLetters: Set<Character>?
    /// Characters keyed since the last separator, as inserted. Autocorrect and suggestions apply only
    /// while this matches the word before the cursor.
    @ObservationIgnored private var keyedWord = "" {
        didSet {
            if keyedWord.isEmpty {
                keyedTouches = []
                keyedRawTouches = []
            }
        }
    }
    /// Where each letter of `keyedWord` landed on its key, for autocorrect's touch evidence. Kept
    /// only while it lines up letter for letter; anything else drops the evidence, not the word.
    @ObservationIgnored private var keyedTouches: [KeyTouch] = []
    /// The same taps before the learned touch offsets moved them, kept in step with
    /// `keyedTouches`: what `TouchAdaptationStore` learns from.
    @ObservationIgnored private var keyedRawTouches: [KeyTouch] = []
    /// The last committed word's taps, taught to `TouchAdaptationStore` once the next word starts,
    /// so a correction undone by delete never teaches.
    @ObservationIgnored private var pendingTouchLesson: (typed: String, committed: String, touches: [KeyTouch], recognized: Bool, session: String?)?
    /// The word's first letter came from sentence-start auto-shift, not a deliberate capital.
    @ObservationIgnored private var keyedWordAutoCapitalized = false
    /// The last autocorrection, so the next delete can put the typed word back.
    @ObservationIgnored private var lastCorrection: AppliedCorrection?
    /// A smart-punctuation rewrite that replaced typed characters (two hyphens, three periods, a
    /// corrected apostrophe): the next delete puts the plain characters back.
    @ObservationIgnored private var lastSmartRewrite: (applied: String, plain: String, session: String?)?
    /// A word whose correction delete just undid. It is learned only if the user then keeps it with
    /// a separator; deleting it to retype by hand must not teach the keyboard a typo.
    @ObservationIgnored private var keptAfterRevert: String? {
        didSet { undoneName = nil }
    }
    /// The last word of a name whose casing delete just undid ("Micro Center" back to "micro
    /// center"). Its next separator leaves the words as typed instead of writing the name again.
    /// Any other edit that ends the undone state (`keptAfterRevert` changing) forgets it.
    @ObservationIgnored private var undoneName: String?
    /// When the last plain space was typed, for the double-space period.
    @ObservationIgnored private var lastSpaceAt: Date?
    /// Set by the SwiftUI root so `openURL` can serve as a fallback for `extensionContext.open`.
    @ObservationIgnored var openURLFallback: ((URL) -> Void)?

    @ObservationIgnored private var swipeEngine: SwipeEngine?
    @ObservationIgnored private var splitSwipeEngine: SwipeEngine?
    /// The decoder that made the committed word owns later choices and corrections,
    /// even if the keyboard folds between swiping and choosing the alternative.
    @ObservationIgnored private weak var lastSwipeEngine: SwipeEngine?
    @ObservationIgnored var swipeUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var awaitingEcho: SwipeCommit?
    @ObservationIgnored private var swipeEchoDeadline: TimeInterval = 0
    @ObservationIgnored private var swipeCommit: SwipeCommit?
    @ObservationIgnored private var swipeCorrection = SelectedWordCorrection()
    /// A whole word removed at this insertion point, available for the next trace only.
    @ObservationIgnored private var swipeRetry: SwipeCommit?
    @ObservationIgnored private var deletedSwipe: SwipeCommit?
    @ObservationIgnored private var swipeReplacementLeading = ""
    @ObservationIgnored private var swipeReplacementStarted = false

    private func cancelSwipeCorrection() {
        swipeCorrection.cancel()
        deletedSwipe = nil
        swipeReplacementLeading = ""
        swipeReplacementStarted = false
    }

    /// Learn a completed, user-authored replacement only while its original anchors still match.
    private func finishSwipeCorrection() -> Bool {
        defer { cancelSwipeCorrection() }
        guard preferences.swipeLearningEnabled, let original = deletedSwipe, let proxy,
              proxy.selectedText()?.isEmpty != false, let context = swipeContext(),
              let word = swipeCorrection.finish(before: context.before, after: context.after,
                                                session: proxy.currentInputSession()),
              SwipeLearning.key(word) != nil,
              // "thats" typed over a swipe means "that's": let the separator add the apostrophe.
              corrector?.isBareContraction(word) != true else { return false }
        lastSwipeEngine?.corrected(original.word, to: word, after: original.previousWord)
        // Preserve this deliberate spelling at the boundary, before the worker has saved it.
        return true
    }
    @ObservationIgnored private var swipeAlternatives: [String] = []
    @ObservationIgnored private var swipeGeneration = 0
    @ObservationIgnored private var swipePending = false
    @ObservationIgnored private var swipePendingContext: (session: String, before: String, after: String, preceding: SwipeCommit?)?
    @ObservationIgnored private var swipeContextEpoch = 0
    @ObservationIgnored private var deleteHeld = false
    @ObservationIgnored private var deleteHoldID = 0
    @ObservationIgnored private var swipeInputs: [() -> Void] = []
    private(set) var hasSwipeAlternatives = false

    struct SwipeInputToken: Equatable {
        let session: String?
        let epoch: Int
    }
    var swipeInputToken: SwipeInputToken {
        SwipeInputToken(session: proxy?.currentInputSession(), epoch: swipeContextEpoch)
    }

    private func swipeContext() -> (before: String, after: String)? {
        guard let proxy else { return nil }
        let before = proxy.contextBefore(), after = proxy.contextAfter()
        if !proxy.fieldHasText() { return (before ?? "", after ?? "") }
        // UIKit reports nil at a document boundary, including after the cursor at the
        // end of nonempty UITextView text. One known side distinguishes that from a
        // nonempty host hiding both sides; snapshots still compare both normalized sides.
        guard before != nil || after != nil else { return nil }
        return (before ?? "", after ?? "")
    }

    /// Where a swiped word would land: the text around the insertion point and the selection it
    /// would replace. Nil when the host hides both.
    private func swipeTarget(following preceding: SwipeCommit?, admitted: Bool = false) -> (before: String, after: String, selection: String)? {
        guard let proxy else { return nil }
        if let preceding, waitingForSwipeEcho(preceding, admitted: admitted) {
            return (preceding.before + preceding.leading + preceding.word, preceding.after, "")
        }
        let selection = proxy.selectedText() ?? ""
        if let context = swipeContext() { return (context.before, context.after, selection) }
        // An address bar opens with its whole text selected and reports nothing on either side.
        // The word replaces the selection, as a tapped letter would.
        return selection.isEmpty ? nil : ("", "", selection)
    }

    var canSwipe: Bool {
        preferences.swipeTypingEnabled && layer == .letters && !showsEmoji && emojiCode == nil
            && (proxy?.allowsSwipeTyping ?? false) && !UIAccessibility.isVoiceOverRunning
    }

    /// Do not capture a gesture that cannot safely produce input in this host field.
    /// Checked at touch-down only, so ordinary grid redraws do not query the host proxy.
    var canBeginSwipe: Bool {
        canSwipe && proxy?.currentInputSession() != nil && swipeTarget(following: swipeCommit) != nil
    }

    private func configureSwipe() {
        guard preferences.swipeTypingEnabled else {
            cancelSwipeInput()
            // A decoder built in an earlier appearance is shared process-wide; swipe off frees it.
            SwipeEngine.releaseShared()
            swipeEngine = nil
            splitSwipeEngine = nil
            return
        }
        if swipeEngine == nil { swipeEngine = SwipeEngine() }
        configure(swipeEngine)
        configure(splitSwipeEngine)
    }

    private func configure(_ engine: SwipeEngine?) {
        engine?.configure(learns: preferences.swipeLearningEnabled,
            reset: preferences.swipeLearningReset,
            personalWords: (vocabularyWords ?? []) + (systemLexicon?.swipeWords(keptLowercase: SpellingStore.learnedWords) ?? [])
                + BuiltInVocabulary.names + SpellingStore.swipeableLearnedWords.reversed())
    }

    private func clearSwipeCommit() {
        swipeCommit = nil
        swipeAlternatives = []
        hasSwipeAlternatives = false
    }

    private func cancelSwipeInput() {
        cancelSwipeCorrection()
        awaitingEcho = nil
        swipeGeneration += 1
        swipeRetry = nil
        swipeContextEpoch += 1
        swipePending = false
        swipePendingContext = nil
        swipeInputs.removeAll()
        clearSwipeCommit()
    }

    private func ownsSwipe(_ commit: SwipeCommit) -> Bool {
        guard let proxy, let context = swipeContext() else { return false }
        let owns = commit.owns(session: proxy.currentInputSession(), before: context.before,
                               after: context.after, selection: proxy.selectedText())
        if owns, awaitingEcho == commit { awaitingEcho = nil }
        return owns
    }

    func handleSwipe(_ points: [SwipePoint], layout: SwipeLayout, token: SwipeInputToken? = nil, split: Bool = false) {
        if let token, token != swipeInputToken { return }
        if swipePending {
            swipeInputs.append { [weak self] in self?.handleSwipe(points, layout: layout, token: token, split: split) }
            return
        }
        if split, canSwipe, splitSwipeEngine == nil {
            splitSwipeEngine = SwipeEngine(split: true)
            configure(splitSwipeEngine)
        }
        let preceding = swipeCommit
        let delayed = preceding.flatMap { waitingForSwipeEcho($0) ? $0 : nil }
        guard canSwipe, let proxy, let engine = split ? splitSwipeEngine : swipeEngine,
              let session = proxy.currentInputSession(), let target = swipeTarget(following: delayed, admitted: true) else { return }
        let before = target.before, after = target.after
        let retryOf = swipeRetry.flatMap {
            $0.session == session && $0.before == before && $0.after == after && target.selection.isEmpty ? $0.word : nil
        }
        swipeRetry = nil
        cancelSwipeCorrection()
        clearSwipeCommit()
        keyedWord = ""
        lastCorrection = nil
        keptAfterRevert = nil
        correctionLearning.cancel()
        dictatedCorrection.cancel()
        flushTouchLesson()
        let previous = SwipeSpacing.previousWord(before: before)
        let leading = SwipeSpacing.needsLeadingSpace(before: before) ? " " : ""
        let capitalization = preferences.autoCapitalizationEnabled ? proxy.capitalization : .none
        let capitalize = shift.isActive || (!leading.isEmpty && capitalization.capitalizesNext(after: before + leading))
        let locked = shift == .locked || capitalization == .allCharacters
        let lowercases = preservesLowercaseCorrections
        // "Sarah" then a swiped "brown": a contact's surname takes its capital after a first name or title.
        let surnames = ContactSurnames.follows(before + leading) ? swipeSurnames : []
        swipeGeneration += 1
        let generation = swipeGeneration
        swipePending = true
        swipePendingContext = (session, before, after, delayed)
        engine.decode(points, layout: layout, previous: previous, retryOf: retryOf) { [weak self] candidates in
            guard let self, self.swipeGeneration == generation else { return }
            self.swipePending = false
            self.swipePendingContext = nil
            guard self.canSwipe, let proxy = self.proxy, proxy.currentInputSession() == session,
                  let live = self.swipeTarget(following: delayed, admitted: true), live == target else {
                // A host can move the cursor/field before delivering its callback. Pending
                // actions belong to the original insertion point, never the destination.
                self.cancelSwipeInput()
                self.afterEdit()
                return
            }
            if !candidates.isEmpty {
                var words = candidates.map { c -> String in
                    let word = lowercases ? c.word.lowercased() : c.word
                    if locked { return word.uppercased() }
                    if capitalize || surnames.contains(word) { return word.prefix(1).uppercased() + word.dropFirst() }
                    return word
                }
                self.markOwnEdit()
                // "micro" then a swiped "center": the pair is the name Micro Center (`PhraseCasing`).
                // The earlier words are rewritten in place; the swipe owns only its own word.
                var commitBefore = before, commitLeading = leading
                if !locked, !lowercases, self.preferences.autocorrectEnabled,
                   delayed.map({ self.waitingForSwipeEcho($0, admitted: true) }) != true,
                   let named = PhraseCasing.name(before: before + leading, word: words[0]),
                   named.prefixLength >= leading.count, named.prefixLength - leading.count <= before.count,
                   let last = named.name.split(separator: " ").last {
                    let rewritten = before.count - (named.prefixLength - leading.count)
                    for _ in 0..<(named.prefixLength - leading.count) { proxy.deleteBackward() }
                    words[0] = String(last)
                    commitBefore = String(before.prefix(rewritten)) + named.name.dropLast(last.count)
                    commitLeading = ""
                    proxy.insert(named.name)
                } else {
                    proxy.insert(leading + words[0])
                }
                self.localContextTail = String((commitBefore + commitLeading + words[0]).suffix(64))
                self.lastSwipeEngine = engine
                self.swipeCommit = SwipeCommit(session: session, before: commitBefore, after: after,
                    leading: commitLeading, word: words[0], previousWord: previous)
                self.awaitingEcho = self.swipeCommit.flatMap { self.ownsSwipe($0) ? nil : $0 }
                self.swipeEchoDeadline = self.swipeUptime() + Self.echoWindow
                self.swipeAlternatives = words
                self.hasSwipeAlternatives = true
                self.suggestions = words.map { Suggestion(text: $0, kind: .completion, autoApplies: false) }
                self.lastSpaceAt = nil
                if self.shift == .on { self.shift = .off }
                self.manualShiftPending = false
                self.afterEdit()
            }
            // Preserve fast tap/swipe ordering while the CPU worker finishes.
            while !self.swipePending && !self.swipeInputs.isEmpty { self.swipeInputs.removeFirst()() }
        }
    }

    /// Some hosts echo the text from immediately before a swipe, or briefly expose no
    /// left context. Keep the space for an insertion only. Replacing and deleting a word
    /// always require the proxy to show that exact word at the cursor.
    private func waitingForSwipeEcho(_ commit: SwipeCommit, admitted: Bool = false) -> Bool {
        guard awaitingEcho == commit, let proxy else { return false }
        if ownsSwipe(commit) { return false }
        guard admitted || swipeUptime() < swipeEchoDeadline else { return false }
        let reported = proxy.contextBefore() ?? ""
        guard reported.isEmpty || reported == commit.before else { return false }
        return proxy.currentInputSession() == commit.session && proxy.allowsSwipeTyping
            && proxy.fieldHasText() && proxy.selectedText()?.isEmpty != false
            && (proxy.contextAfter() ?? "") == commit.after
    }

    /// Settle the owed space before a real edit; modifier taps leave the swipe available.
    private func settleSwipe(before text: String) {
        defer { clearSwipeCommit() }
        guard let commit = swipeCommit, SwipeSpacing.paysPendingSpace(before: text),
              ownsSwipe(commit) || waitingForSwipeEcho(commit),
              !SwipeSpacing.isInsideToken(commit.before + commit.leading + commit.word), let proxy else { return }
        proxy.insert(" ")
        recordLocalInsertion(" ")
    }

    private func chooseSwipe(_ suggestion: Suggestion) -> Bool {
        guard var commit = swipeCommit else { return false }
        guard swipeAlternatives.contains(suggestion.text), ownsSwipe(commit), let proxy else {
            clearSwipeCommit(); return true
        }
        markOwnEdit()
        for _ in commit.word { proxy.deleteBackward() }
        proxy.insert(suggestion.text)
        let original = commit.word
        commit.word = suggestion.text
        swipeCommit = commit
        localContextTail = String((commit.before + commit.leading + commit.word).suffix(64))
        if original.lowercased() == suggestion.text.lowercased() {
            lastSwipeEngine?.chose(suggestion.text, after: commit.previousWord)
        } else {
            lastSwipeEngine?.corrected(original, to: suggestion.text, after: commit.previousWord)
        }
        feedback.keyDown()
        afterEdit()
        return true
    }

    static let doubleSpaceWindow: TimeInterval = 1.2
    static let deleteRepeatDelay: Duration = .milliseconds(450)
    static let deleteRepeatInterval: Duration = .milliseconds(80)
    /// After this many single deletions a held delete removes whole words, as on iOS.
    static let deleteWordsAfter = 20
    static let deleteWordInterval: Duration = .milliseconds(200)

    @ObservationIgnored private let systemLexiconStore: SystemLexiconStore?

    @ObservationIgnored private let vocabularyStore: @Sendable () -> PersonalVocabulary?

    init(proxy: TextProxyActions?, systemLexiconStore: SystemLexiconStore? = .shared,
         vocabulary: @escaping @Sendable () -> PersonalVocabulary? = { .shared }) {
        self.vocabularyStore = vocabulary
        self.proxy = proxy
        self.systemLexiconStore = systemLexiconStore
        self.feedback = KeyFeedback(proxy: proxy)
    }

    /// Supply only what the read-only Settings grid draws. It needs no host or decoder.
    func displayPreview(_ preferences: KeyboardPreferences) {
        self.preferences = preferences
        hasFullAccess = true
        shift = preferences.autoCapitalizationEnabled ? .on : .off
    }

    var rows: [[Key]] {
        KeyboardLayout.rows(for: layer, shifted: shift.isActive, needsGlobe: needsGlobe,
                            pasteKey: preferences.showsPasteKey,
                            emojiKey: preferences.showsEmojiKey, fieldKeys: fieldKeys)
    }

    /// Re-reads host traits. Call when the keyboard appears and when the text field changes.
    func refreshTraits(reconcileImmediately: Bool = true) {
        guard let proxy else { return }
        proxy.reloadFieldTraits()
        let session = proxy.currentInputSession()
        if session != fieldSession {
            cursorToken = nil
            cancelSwipeInput()
            pendingTouchLesson = nil
            resetEmojiCode()
            fieldSession = session
            appearanceOutdated = false
            correctionLearning.cancel()
            dictatedCorrection.cancel()
            selectionRefreshRequested = false
            manualShiftPending = false
            pendingOwnEdits = 0
            keyedWord = ""
            lastCorrection = nil
            keptAfterRevert = nil
            lastSpaceAt = nil
            localContextTail = nil
            suggestionWord = nil
            suggestionSession = nil
            if !suggestions.isEmpty { suggestions = [] }
            // A fresh field: Messages and others report nil context before the first edit, and
            // there nil means an empty field, so the first letter shows as a capital. But a host
            // can also hand a field that already holds text a new identity in the middle of a
            // sentence (Messages rebuilding its compose field) and report nil context with it:
            // a field with text in it is not a sentence start, or the next word gets a capital
            // ("Think mine is The best").
            if layer == .letters, shift != .locked {
                let context = proxy.contextBefore() ?? (proxy.fieldHasText() ? nil : "")
                set(\.shift, preferences.autoCapitalizationEnabled && context.map { proxy.capitalization.capitalizesNext(after: $0) } == true ? .on : .off)
            }
        }
        // An @Observable property notifies on every set, equal or not, and the key grid reads
        // several of these: assign only real changes so a host callback does not redraw the keys.
        set(\.needsGlobe, proxy.needsGlobeKey)
        set(\.returnLabel, proxy.returnKeyLabel)
        set(\.fieldKeys, proxy.fieldKeys)
        set(\.explicitDark, appearanceOutdated ? nil : proxy.explicitDarkAppearance)
        // Follow the field's keyboard type when it changes, without fighting a manual switch.
        let prefersNumbers = proxy.prefersNumbers
        if prefersNumbers != lastPrefersNumbers {
            lastPrefersNumbers = prefersNumbers
            set(\.layer, prefersNumbers ? .numbers : .letters)
        }
        if reconcileImmediately { reconcileContext() } else { afterEdit() }
    }

    /// Called from the host's textDidChange. The keyboard's own edits already refreshed the shift
    /// state and suggestions; a host that reports them back on the same turn is not handled twice.
    func hostTextDidChange() {
        guard !writingEmoji else { return }
        if let token = cursorToken, ownsCursor(token) {
            hostChangedDuringCursor(token)
            return
        }
        // Only an echo of our own edit in the same field is skipped; a Return that moved the host
        // to another field still refreshes the layout and traits.
        if let commit = swipeCommit, waitingForSwipeEcho(commit) {
            afterEdit()
            return
        }
        if consumeOwnEditEcho() { return }
        resetEmojiCode()
        pendingTouchLesson = nil
        // Some hosts (including Messages) report selection changes only through textDidChange.
        // Inspect selection on this external host notification, coalesced with context work;
        // ordinary key actions themselves never read selectedText or create a candidate.
        cancelSwipeInput()
        selectionRefreshRequested = true
        #if DEBUG
        KeyboardLog.typing.info("host text callback requests selection inspection")
        #endif
        refreshTraits(reconcileImmediately: false)
    }

    func hostSelectionDidChange() {
        guard !writingEmoji else { return }
        if let token = cursorToken, ownsCursor(token) {
            hostChangedDuringCursor(token)
            return
        }
        #if DEBUG
        KeyboardLog.typing.info("selection callback pendingOwnEdits=\(self.pendingOwnEdits, privacy: .public)")
        #endif
        if let last = swipeCommit ?? swipePendingContext?.preceding, !ownsSwipe(last) {
            cancelSwipeInput()
        }
        if consumeOwnEditEcho() { return }
        resetEmojiCode()
        cancelSwipeInput()
        pendingTouchLesson = nil
        lastSmartRewrite = nil
        selectionRefreshRequested = true
        afterEdit()
    }

    /// `dark` is nil while the trait is still unspecified, which must not count as a flip.
    func setSystemDark(_ dark: Bool?) {
        guard let dark else { return }
        if let lastSystemDark, lastSystemDark != dark, proxy?.explicitDarkAppearance == lastSystemDark {
            appearanceOutdated = true
        }
        lastSystemDark = dark
        set(\.systemDark, dark)
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<KeyboardModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Host callbacks still expected for the keyboard's own edits. A next-runloop flag missed
    /// echoes that arrive a turn or more later (each one then cost a trait refresh, a selection
    /// read and a context read); each key action adds its expected echoes (`echoesPerDelete` for a delete), and a callback in the same field
    /// within `echoWindow` of the last own edit consumes one and is skipped. A host that sends no
    /// echo, or several, is put right by the window: past it the count is dropped.
    @ObservationIgnored private var pendingOwnEdits = 0
    @ObservationIgnored private var lastOwnEditAt: TimeInterval = 0
    @ObservationIgnored private var ownEditSession: String?
    static let echoWindow: TimeInterval = 0.5
    /// Messages in the simulator answers each held-delete step with two textDidChange calls;
    /// inserts are counted as one, so a host that echoes once never leaves spare skips behind.
    static let echoesPerDelete = 2
    static let maxPendingOwnEdits = 16

    private func markOwnEdit(echoes: Int = 1) {
        pendingOwnEdits = min(pendingOwnEdits + echoes, Self.maxPendingOwnEdits)
        lastOwnEditAt = Date().timeIntervalSinceReferenceDate
        ownEditSession = proxy?.currentInputSession()
    }

    /// True when a host callback is the echo of one of our own edits.
    private func consumeOwnEditEcho() -> Bool {
        // Hosts may emit more than one callback for a single insertion or replacement.
        // Fresh ownership, rather than an estimated callback count, preserves swipe state.
        let pendingStillOwned = swipePendingContext.map { snapshot in
            if let preceding = snapshot.preceding, waitingForSwipeEcho(preceding, admitted: true) { return true }
            guard let proxy, let live = swipeContext() else { return false }
            return proxy.currentInputSession() == snapshot.session
                && live.before == snapshot.before && live.after == snapshot.after
                && proxy.selectedText()?.isEmpty != false
        } ?? false
        let retryStillOwned = swipeRetry.map { retry in
            guard let proxy, let context = swipeContext() else { return false }
            return proxy.currentInputSession() == retry.session && proxy.selectedText()?.isEmpty != false
                && context.before == retry.before && context.after == retry.after
        } ?? false
        if pendingStillOwned || retryStillOwned || swipeCommit.map({ ownsSwipe($0) }) == true {
            pendingOwnEdits = max(0, pendingOwnEdits - 1)
            selectionRefreshRequested = true
            afterEdit()
            return true
        }
        guard pendingOwnEdits > 0 else { return false }
        guard Date().timeIntervalSinceReferenceDate - lastOwnEditAt < Self.echoWindow,
              proxy?.currentInputSession() == ownEditSession else {
            pendingOwnEdits = 0
            return false
        }
        // Swipe ownership and a gesture in progress must be invalidated before lift, even
        // when a cursor change arrives inside the own-edit echo window.
        if let target = emojiCode, let proxy {
            let before = proxy.contextBefore(), after = proxy.contextAfter(), selection = proxy.selectedText()
            let literal = target.code.literal + (emojiPending?.closed == true ? ":" : "")
            if proxy.currentInputSession() == target.session,
               target.code.couldBeEcho(of: literal, before: before, after: after, selection: selection) {
                pendingOwnEdits -= 1
                afterEdit()
                return true
            }
            pendingOwnEdits = 0
            return false
        }
        if let undo = emojiUndo, let proxy, proxy.currentInputSession() == undo.session {
            let before = proxy.contextBefore(), after = proxy.contextAfter(), selection = proxy.selectedText()
            if undo.code.owns(undo.emoji, before: before, after: after, selection: selection)
                || undo.code.couldBeEcho(of: undo.replaced, before: before, after: after, selection: selection) {
                pendingOwnEdits -= 1
                afterEdit()
                return true
            }
            pendingOwnEdits = 0
            return false
        }
        if preferences.swipeTypingEnabled, let proxy, let expected = localContextTail {
            let before = proxy.contextBefore()
            let mismatches = before.map { current in
                let suffix = String(current.suffix(64))
                if expected.isEmpty || suffix.isEmpty { return expected != suffix }
                // Hosts expose different context windows; compare only available characters.
                return !expected.hasSuffix(suffix) && !suffix.hasSuffix(expected)
            } ?? false
            if proxy.selectedText()?.isEmpty == false || mismatches {
                pendingOwnEdits = 0
                return false
            }
        }
        pendingOwnEdits -= 1
        // A real host change (a cursor tap, autofill, Send clearing the field) can hide behind an
        // expected echo, so one coalesced check still runs once typing pauses: no host read per
        // key, but the field is never left stale.
        selectionRefreshRequested = true
        afterEdit()
        return true
    }

    private(set) var pasteAccessHint: UUID?
    static let pasteAccessMessage = "Turn on Full Access to paste."

    func explainPasteAccess() {
        guard !hasFullAccess else { return }
        UIAccessibility.post(notification: .announcement, argument: Self.pasteAccessMessage)
        guard !dictationOwnsStrip else { return }
        let token = UUID()
        pasteAccessHint = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.pasteAccessHint == token { self?.pasteAccessHint = nil }
        }
    }

    /// Full Access can invoke TCC IPC. Refresh only on appearance, not host text echoes or touches.
    func refreshFullAccess(reloadVocabulary: Bool = true) {
        let granted = proxy?.hasOpenAccess ?? false
        let changed = granted != hasFullAccess
        set(\.hasFullAccess, granted)
        feedback.hasFullAccess = granted
        guard changed else { return }
        SpellingStore.refreshSharedLearning(fullAccess: granted, store: vocabularyStore)
        if granted {
            pasteAccessHint = nil
            persistSystemLexicon()
            // Permission can become reliable only in viewDidAppear, after apply ran.
            if reloadVocabulary { refreshPersonalWordProtection() }
        } else {
            vocabularyReadPending = false
            vocabularyGeneration += 1
            correctionLearning.cancel()
            dictatedCorrection.cancel()
            learnsFromCorrections = false
            vocabularyWords = []
            corrector?.setPersonalWords([])
        }
    }

    /// The accent changed after the strip was drawn (`KeyboardViewController.viewDidAppear`).
    func accentDidChange() {
        appearanceVersion &+= 1
    }

    /// The app's switches, read from the shared store each time the keyboard appears.
    func apply(_ preferences: KeyboardPreferences) {
        if self.preferences.swipeLearningReset != preferences.swipeLearningReset { cancelSwipeInput() }
        self.preferences = preferences
        configureSwipe()
        if !preferences.showsEmojiKey { set(\.showsEmoji, false) }
        set(\.hand, handMemory.resolve(preferences))
        if !preferences.autocorrectEnabled || !preferences.showSuggestions {
            suggestionWord = nil
            suggestionSession = nil
            if !suggestions.isEmpty { suggestions = [] }
        }
        refreshPersonalWordProtection()
        feedback.hapticsEnabled = preferences.hapticsEnabled
        if preferences.autocorrectEnabled, corrector == nil {
            SpellingStore.load { [weak self] corrector in
                guard let self else { return }
                self.corrector = corrector
                SpellingStore.keptSlipsChanged = { [weak self] in self?.configureSwipe() }
                if let letters = self.spaceBarLetters { corrector?.spaceBarLetters = letters }
                if let lexicon = self.systemLexicon {
                    corrector?.setSystemLexicon(names: lexicon.names, replacements: lexicon.replacements)
                }
                // The appearance read sets the current corrector when it finishes. If it
                // already finished, install its words on the newly loaded corrector now.
                if let words = self.vocabularyWords { corrector?.setPersonalWords(words) }
                self.afterEdit()
            }
        } else if preferences.autocorrectEnabled {
            SpellingStore.retryMissingContext()
        }
        afterEdit()
    }

    /// The letter keys over the space bar in the drawn letter layout
    /// (`KeyGridGeometry.keys(above:)`), so autocorrect reads exactly those as slipped spaces.
    func setSpaceBarLetters(_ letters: Set<Character>) {
        guard letters != spaceBarLetters else { return }
        spaceBarLetters = letters
        corrector?.spaceBarLetters = letters
    }

    /// Canonical terms and text replacements from `requestSupplementaryLexicon`, kept until the
    /// shared corrector has loaded.
    @ObservationIgnored private var systemLexicon: SystemLexiconSnapshot?
    @ObservationIgnored private var swipeSurnames: Set<String> = []

    /// The system's supplementary lexicon (`UILexicon` entries as input and document text): an
    /// Apple does not label each entry's source; case-only pairs are canonical terms too.
    func applySystemLexicon(_ entries: [(input: String, text: String)]) {
        let snapshot = SystemLexiconSnapshot(entries: entries)
        systemLexicon = snapshot
        swipeSurnames = snapshot.surnames
        configureSwipe()
        corrector?.setSystemLexicon(names: snapshot.names, replacements: snapshot.replacements)
        persistSystemLexicon()
        KeyboardLog.typing.info("system lexicon: \(snapshot.names.count, privacy: .public) names, \(snapshot.replacements.count, privacy: .public) replacements")
    }

    private func persistSystemLexicon() {
        guard hasFullAccess, let snapshot = systemLexicon, let store = systemLexiconStore else { return }
        Self.vocabularyQueue.async {
            do {
                try store.save(snapshot)
                KeyboardLog.typing.info("system lexicon synced: \(snapshot.names.count, privacy: .public) terms")
            }
            catch { KeyboardLog.typing.error("system lexicon could not sync to the app") }
        }
    }

    /// Internal so `viewDidAppear` can read the words again once access has settled.
    func refreshPersonalWordProtection() {
        SpellingStore.refreshSharedLearning(fullAccess: hasFullAccess, store: vocabularyStore)
        guard hasFullAccess else {
            vocabularyReadPending = false
            vocabularyGeneration += 1
            correctionLearning.cancel()
            dictatedCorrection.cancel()
            vocabularyWords = []
            learnsFromCorrections = false
            corrector?.setPersonalWords([])
            return
        }
        // One appearance/load snapshot, decoded on the vocabulary queue: the dictionary has no
        // size cap and a coordinated read on the main thread delayed the keyboard appearing.
        // The same serial queue runs the correction writer, so a read never passes a write;
        // until it lands the corrector keeps the words it already had.
        // An appearance asks two or three times in a row; they share the read already on its way.
        // What a shared request is owed is decided when that read lands (`refreshAskedDuringRead`).
        if vocabularyReadPending {
            refreshAskedDuringRead = true
            return
        }
        vocabularyReadPending = true
        refreshAskedDuringRead = false
        vocabularyGeneration += 1
        let generation = vocabularyGeneration
        Self.vocabularyQueue.async { [weak self, vocabularyStore] in
            let vocabulary = vocabularyStore()
            // Taken before the read, so a write that lands during it shows as a change afterwards.
            let stamp = vocabulary.flatMap(Self.vocabularyStamp)
            // A read that fails (container not reachable yet, coordination error) is not an empty
            // dictionary: keep the words already loaded instead of unprotecting every one of them.
            guard let vocabulary, let document = try? vocabulary.document() else {
                DispatchQueue.main.async {
                    guard let self, self.vocabularyGeneration == generation else { return }
                    self.vocabularyReadPending = false
                    if self.refreshAskedDuringRead { self.refreshPersonalWordProtection() }
                }
                KeyboardLog.typing.error("personal words unreadable; keeping the loaded ones")
                return
            }
            let words = document.appliedWords
            let learns = document.learnsFromCorrections
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.vocabularyGeneration == generation, self.hasFullAccess else { return }
                    self.vocabularyReadPending = false
                    self.vocabularyWords = words
                    self.configureSwipe()
                    self.learnsFromCorrections = learns
                    self.corrector?.setPersonalWords(words)
                    // Someone asked while this read was on its way. It may have read the file
                    // before a change they knew of (words restored from a backup, a word added in
                    // Zone), so look at the file again, and decode it again only if it changed.
                    if self.refreshAskedDuringRead {
                        self.refreshAskedDuringRead = false
                        self.rereadVocabularyIfChanged(since: stamp, generation: generation)
                    }
                }
            }
        }
    }

    /// The dictionary file as it was at one moment: enough to tell that it was written since,
    /// without reading it. Every save replaces the file, so its number and date both move.
    private struct VocabularyStamp: Equatable, Sendable {
        var path: String
        var file: Int?
        var modified: Date?
        var size: Int?
    }

    private nonisolated static func vocabularyStamp(_ vocabulary: PersonalVocabulary) -> VocabularyStamp? {
        let url = vocabulary.storeURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return VocabularyStamp(path: url.path, file: (attributes[.systemFileNumber] as? NSNumber)?.intValue,
                               modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue)
    }

    private func rereadVocabularyIfChanged(since stamp: VocabularyStamp?, generation: Int) {
        Self.vocabularyQueue.async { [weak self, vocabularyStore] in
            guard vocabularyStore().flatMap(Self.vocabularyStamp) != stamp else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.vocabularyGeneration == generation, !self.vocabularyReadPending else { return }
                    self.refreshPersonalWordProtection()
                }
            }
        }
    }

    @ObservationIgnored private var vocabularyReadPending = false
    /// A refresh was asked for while a read was already on its way.
    @ObservationIgnored private var refreshAskedDuringRead = false
    @ObservationIgnored private(set) var vocabularyGeneration = 0

    func keyboardWillDisappear() {
        resetEmojiCode()
        cursorToken = nil
        cancelSwipeInput()
        swipeEngine = nil
        endDeleteRepeat()
        // Disappearance does not prove the user accepted the last correction.
        pendingTouchLesson = nil
        reconcileDeadline = nil
        pendingOwnEdits = 0
        feedback.release()
        correctionLearning.cancel()
        dictatedCorrection.cancel()
        selectionRefreshRequested = false
        manualShiftPending = false
        keyedWord = ""
        lastCorrection = nil
        keptAfterRevert = nil
        lastSpaceAt = nil
        suggestions = []
        // The next appearance opens on the keys, the way the field expects to be typed in.
        showsEmoji = false
    }

    /// The word list has loaded. Tests wait on it; typing never does.
    var isCorrectorReady: Bool { corrector != nil }

    private var autocorrectActive: Bool {
        preferences.autocorrectEnabled && corrector != nil && (proxy?.allowsAutocorrection ?? false)
    }

    // MARK: Space-bar cursor

    struct CursorToken: Equatable {
        let id = UUID()
        let session: String
    }
    var movingCursor: Bool { cursorToken != nil }
    private var cursorToken: CursorToken? {
        didSet { if cursorToken == nil { cursorContext = nil } }
    }
    /// The text around the caret as this drag last knew it, advanced locally after each step so
    /// an ordinary step costs one host call (the move) and no reads. Nil means read it again.
    private struct CursorContext {
        var before: String?
        var after: String?

        @MainActor init(_ proxy: TextProxyActions) {
            before = proxy.contextBefore()
            after = proxy.contextAfter()
        }

        /// Whether the cached side holds every character this step crosses. A host's context is
        /// a window, so a long drag runs off its edge and has to read the next window.
        func covers(_ steps: Int) -> Bool {
            guard let side = steps < 0 ? before : after else { return false }
            return side.count >= min(steps.magnitude, UInt(SpacebarCursorGesture.maximumSteps))
        }

        /// Whether `host`, just read, shows the caret where this context has it. Each side must
        /// continue the other's (a host's window can be wider or narrower than what the drag has
        /// walked through), and they must share real text, so a cleared field or the start of
        /// another paragraph does not pass for this place.
        func matches(_ host: CursorContext) -> Bool {
            let mine = (before ?? "", after ?? ""), theirs = (host.before ?? "", host.after ?? "")
            guard theirs.0.hasSuffix(mine.0) || mine.0.hasSuffix(theirs.0),
                  theirs.1.hasPrefix(mine.1) || mine.1.hasPrefix(theirs.1) else { return false }
            let shared = min(mine.0.count, theirs.0.count) + min(mine.1.count, theirs.1.count)
            return shared >= min(12, mine.0.count + mine.1.count)
        }

        func moved(_ steps: Int) -> Self {
            var result = self
            let count = Int(steps.magnitude)
            if steps < 0, let before {
                let moved = String(before.suffix(count))
                result.before = String(before.dropLast(moved.count))
                result.after = moved + (after ?? "")
            } else if steps > 0, let after {
                let moved = String(after.prefix(count))
                result.before = (before ?? "") + moved
                result.after = String(after.dropFirst(moved.count))
            }
            return result
        }
    }
    @ObservationIgnored private var cursorContext: CursorContext? {
        didSet { if cursorContext == nil { cursorTrail.removeAll() } }
    }
    /// Where the caret was before each move the host may not have reported back yet, oldest
    /// first. A host callback showing one of these is an echo of the drag's own move.
    @ObservationIgnored private var cursorTrail: [CursorContext] = []
    @ObservationIgnored private var cursorDetent = CursorLineDetent()
    /// The column a run of up/down moves keeps returning to; any sideways move forgets it.
    @ObservationIgnored private var cursorGoalColumn: Int?

    /// A drag belongs to the field it started in for as long as the finger is down, as on
    /// Apple's keyboard. Host callbacks during it (our own echoes, a web view catching up,
    /// autofill) only make the cached context stale; leaving the field ends the drag.
    private func ownsCursor(_ token: CursorToken) -> Bool {
        guard cursorToken == token else { return false }
        if proxy?.currentInputSession() == token.session { return true }
        cursorToken = nil
        pendingOwnEdits = 0
        cancelSwipeInput()
        selectionRefreshRequested = true
        refreshTraits(reconcileImmediately: false)
        return false
    }

    /// A host callback while the finger is down. Hosts answer a move late (a web view by tens of
    /// milliseconds), and a fast drag has sent more moves by then, so the text the host reports
    /// is where the caret was a few moves ago. The drag's own context is ahead of that: keep it
    /// while the host is only catching up, and read again only when the host shows text the drag
    /// did not produce (autofill, a replacement, a tap elsewhere).
    private func hostChangedDuringCursor(_ token: CursorToken) {
        defer { schedulePendingColumn(token) }
        guard let proxy, let context = cursorContext else { return }
        let host = CursorContext(proxy)
        if context.matches(host) {
            cursorTrail.removeAll()
            cursorContext = host
        } else if let index = cursorTrail.lastIndex(where: { $0.matches(host) }) {
            cursorTrail.removeFirst(index)
        } else {
            cursorContext = nil
        }
    }

    /// Records the caret's place before a move, so the host's late report of it is recognized.
    private func rememberCursorPlace(_ context: CursorContext) {
        cursorTrail.append(context)
        if cursorTrail.count > 24 { cursorTrail.removeFirst(cursorTrail.count - 24) }
    }

    /// Queue behind any word already being decoded. Moving the cursor must not discard it,
    /// or pay its phantom space at the new insertion point.
    func beginCursorControl() -> CursorToken? {
        resetEmojiCode()
        guard let session = proxy?.currentInputSession() else { return nil }
        let token = CursorToken(session: session)
        performCursorInput { [weak self] in
            guard let self, self.proxy?.currentInputSession() == token.session else { return }
            self.cursorToken = token
            self.cursorContext = nil
            self.cursorDetent = CursorLineDetent()
            self.cursorGoalColumn = nil
            self.pendingColumn = nil
            self.swipeContextEpoch += 1
            self.clearSwipeCommit()
            self.cancelSwipeCorrection()
            self.endDeleteRepeat()
            self.pendingOwnEdits = 0
            self.pendingTouchLesson = nil
            self.correctionLearning.cancel()
            self.dictatedCorrection.cancel()
            self.selectionRefreshRequested = false
            self.keyedWord = ""
            self.lastCorrection = nil
            self.keptAfterRevert = nil
            self.lastSpaceAt = nil
            self.lastShiftTap = nil
            self.manualShiftPending = false
            self.localContextTail = nil
            self.suggestionWord = nil
            self.suggestionSession = nil
            self.suggestions = []
            self.reconcileDeadline = nil
        }
        return token
    }

    /// `resisting` holds the caret at line breaks for a drag; a discrete step (VoiceOver's
    /// "Move cursor backward") crosses them at once.
    func moveCursor(_ steps: Int, resisting: Bool = true, token: CursorToken) {
        guard steps != 0 else { return }
        performCursorInput { [weak self] in
            guard let self, self.ownsCursor(token), let proxy = self.proxy else { return }
            self.applyPendingColumn(proxy)
            var context = self.cursorContext
            if context?.covers(steps) != true { context = CursorContext(proxy) }
            guard let context else { return }
            self.cursorGoalColumn = nil
            // Line breaks resist: a fast drag stops at the end of a line, a push carries on.
            let side = steps < 0 ? context.before : context.after
            let walk: (characters: Int, breaks: Int)
            if resisting {
                walk = self.cursorDetent.walk(steps, through: side)
            } else if let side {
                let crossed = steps < 0 ? side.suffix(-steps) : side.prefix(steps)
                walk = (steps < 0 ? -crossed.count : crossed.count, 0)
            } else {
                walk = (steps, 0)
            }
            guard walk.characters != 0 else { self.cursorContext = context; return }
            // Hidden context (nil) still moves by plain characters: a frozen trackpad is worse
            // than a rare step into a composed emoji, and UIKit clamps at the document's ends.
            let offset = side == nil
                ? max(-SpacebarCursorGesture.maximumSteps, min(SpacebarCursorGesture.maximumSteps, walk.characters))
                : CursorTextOffset.utf16(steps: walk.characters, before: context.before, after: context.after)
            guard offset != 0 else { self.cursorContext = context; return }
            self.cursorContext = context
            if side != nil { self.rememberCursorPlace(context) }
            proxy.adjustTextPosition(byCharacterOffset: offset)
            guard self.cursorToken == token else { return }
            if walk.breaks > 0 { self.feedback.impact(.light) }
            // Ours is more current than anything the host reported during the call. A context
            // from a hidden side is unknown, so read it again next step.
            self.cursorContext = side == nil ? nil : context.moved(walk.characters)
            // No typing-echo credit: a selection change is not a keystroke or a touch lesson.
            self.localContextTail = nil
        }
    }

    /// Up (negative) or down by lines. Line breaks are exact; soft wraps are estimated as
    /// `wrapWidth` characters, since a keyboard cannot see the host's layout. Real UIKit shows
    /// only the current paragraph, so entering a neighbouring one hops across its line break,
    /// reads it, then places the column.
    func moveCursorLines(_ lines: Int, wrapWidth: Int, token: CursorToken) {
        guard lines != 0 else { return }
        performCursorInput { [weak self] in
            guard let self, self.ownsCursor(token), let proxy = self.proxy else { return }
            self.cursorDetent.reset()
            self.applyPendingColumn(proxy)
            // A sideways drag walks the cached text toward its edge, and lines are placed from
            // the whole paragraph. When the host has caught up, take its fuller view.
            if let context = self.cursorContext {
                let host = CursorContext(proxy)
                if context.matches(host) { self.cursorTrail.removeAll(); self.cursorContext = host }
            }
            let direction = lines < 0 ? -1 : 1
            for _ in 0..<min(abs(lines), 20) {
                let context = self.cursorContext ?? CursorContext(proxy)
                let goal = self.cursorGoalColumn ?? CursorLines.column(before: context.before, wrapWidth: wrapWidth)
                self.cursorGoalColumn = goal
                switch CursorLines.step(direction, goalColumn: goal, before: context.before,
                                        after: context.after, wrapWidth: wrapWidth) {
                case .none:
                    return
                case .move(let n):
                    guard self.adjustCursor(characters: n, context: context, proxy: proxy, token: token) else { return }
                case .hop(let n):
                    // The known part of this paragraph, then the line break itself.
                    let known = n < 0 ? String((context.before ?? "").suffix(-n - 1)).utf16.count
                        : String((context.after ?? "").prefix(n - 1)).utf16.count
                    proxy.adjustTextPosition(byCharacterOffset: n < 0 ? -(known + 1) : known + 1)
                    guard self.cursorToken == token else { return }
                    self.cursorContext = nil
                    self.pendingColumn = (direction, goal, wrapWidth, context.before, context.after)
                    self.applyPendingColumn(proxy)
                    // A host still showing the old paragraph finishes shortly (callback or poll).
                    if self.pendingColumn != nil { self.schedulePendingColumn(token); return }
                }
            }
            self.feedback.impact(.light)
            self.localContextTail = nil
        }
    }

    /// The column placement owed after a paragraph hop, kept until the host shows the new
    /// paragraph: tried on each host callback, the next move and the lift. A host that never
    /// updates (a hop clamped at the document's edge) leaves the caret at the line break.
    @ObservationIgnored private var pendingColumn: (direction: Int, goal: Int, width: Int, staleBefore: String?, staleAfter: String?)?

    /// Never move the caret from inside a host callback: UIKit is mid-notification there, and
    /// re-entering it crashed the in-process host (doesNotRecognizeSelector in
    /// _UIInputViewControllerOutput, Nov 8). Apply on the next main-queue turn instead.
    /// UITextView applies a keyboard's move a moment later and does not report it back, so a
    /// hop also polls briefly (every 16 ms, about 0.4 s) while the finger is down.
    private func schedulePendingColumn(_ token: CursorToken, attempt: Int = 0) {
        guard pendingColumn != nil, attempt < 25 else { return }
        if attempt == 0 { guard !pendingColumnScheduled else { return }; pendingColumnScheduled = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.016)) { [weak self] in
            guard let self else { return }
            guard self.cursorToken == token, let proxy = self.proxy else { self.pendingColumnScheduled = false; return }
            self.performCursorInput { [weak self] in
                guard let self, self.cursorToken == token else { return }
                self.applyPendingColumn(proxy)
            }
            if self.pendingColumn == nil { self.pendingColumnScheduled = false; return }
            self.schedulePendingColumn(token, attempt: attempt + 1)
        }
    }
    @ObservationIgnored private var pendingColumnScheduled = false

    private func applyPendingColumn(_ proxy: TextProxyActions) {
        guard let pending = pendingColumn else { return }
        let fresh = CursorContext(proxy)
        // A host that has not applied the hop yet still reports the context from before it.
        guard fresh.before != pending.staleBefore || fresh.after != pending.staleAfter else { return }
        // UIKit also reports a transient state mid-move, the caret still at the old paragraph's
        // edge (seen Nov 8: before nil, after "five six" right after hopping up from "five six|").
        // Wait until the caret has left the paragraph it hopped from.
        let paragraph = String((pending.staleBefore ?? "").reversed().prefix(while: { !$0.isNewline }).reversed())
            + String((pending.staleAfter ?? "").prefix(while: { !$0.isNewline }))
        if !paragraph.isEmpty {
            if pending.direction < 0, (fresh.after ?? "").hasPrefix(paragraph) { return }
            if pending.direction > 0, (fresh.before ?? "").hasSuffix(paragraph) { return }
        }
        let fix = CursorLines.columnFix(pending.direction, goalColumn: pending.goal,
                                        before: fresh.before, after: fresh.after, wrapWidth: pending.width)
        pendingColumn = nil
        cursorContext = fresh
        if fix != 0, let token = cursorToken { _ = adjustCursor(characters: fix, context: fresh, proxy: proxy, token: token) }
    }

    /// Moves by whole characters through known context; false if the drag ended meanwhile.
    private func adjustCursor(characters n: Int, context: CursorContext, proxy: TextProxyActions, token: CursorToken) -> Bool {
        let offset = n < 0 ? -String((context.before ?? "").suffix(-n)).utf16.count
            : String((context.after ?? "").prefix(n)).utf16.count
        guard offset != 0 else { return true }
        cursorContext = context
        rememberCursorPlace(context)
        proxy.adjustTextPosition(byCharacterOffset: offset)
        guard cursorToken == token else { return false }
        cursorContext = context.moved(n)
        return true
    }

    func endCursorControl(_ token: CursorToken) {
        performCursorInput { [weak self] in
            guard let self, self.ownsCursor(token) else { return }
            if let proxy = self.proxy { self.applyPendingColumn(proxy) }
            self.pendingColumn = nil
            self.cursorToken = nil
            guard let proxy = self.proxy, proxy.currentInputSession() == token.session else { return }
            let before = proxy.contextBefore()
            self.localContextTail = before.map { String($0.suffix(64)) }
            self.applyAutoShift(before: before)
            self.afterEdit()
        }
    }

    private func performCursorInput(_ action: @escaping () -> Void) {
        if swipePending { swipeInputs.append(action) } else { action() }
    }

    // MARK: Key handling

    /// Touch-down: click and haptic for every key, and the first deletion for delete.
    func keyDown(_ key: Key) {
        proxy?.userTouchedKeyboard()
        switch key {
        case .globe, .mic:
            return
        case .delete:
            feedback.keyDown()
            deleteHeld = true
            deleteHoldID += 1
            let hold = deleteHoldID
            if swipePending {
                swipeInputs.append { [weak self] in
                    guard let self else { return }
                    self.pressDelete()
                    if !self.deleteHeld || self.deleteHoldID != hold { self.deleteRepeatTask?.cancel(); self.deleteRepeatTask = nil }
                }
            } else { pressDelete() }
        default:
            feedback.keyDown()
        }
    }

    /// Release inside the key: the key's action. Delete already acted on touch-down.
    /// - Parameters:
    ///   - touch: where a letter's tap landed on its key (see `KeyTouch`), if known, after the
    ///     learned touch offsets.
    ///   - raw: the same tap before the learned offsets, for learning them.
    func handleTap(_ key: Key, touch: KeyTouch? = nil, raw: KeyTouch? = nil, trainOffsets: Bool = true) {
        if swipePending {
            swipeInputs.append { [weak self] in self?.handleTap(key, touch: touch, raw: raw, trainOffsets: trainOffsets) }
            return
        }
        KeyTrace.measure("key") { perform(key, touch: touch, raw: raw, trainOffsets: trainOffsets) }
    }

    private func perform(_ key: Key, touch: KeyTouch?, raw: KeyTouch? = nil, trainOffsets: Bool = true) {
        guard let proxy else { return }
        swipeRetry = nil
        markOwnEdit()
        lastSmartRewrite = nil
        switch key {
        case .shift, .switchLayer:
            break
        default:
            if emojiUndoDeadline != nil { _ = restoreEmojiIfOwned(waitForEcho: false) }
            emojiUndo = nil
            if emojiPending != nil {
                refreshEmojiCode()
                if emojiPending != nil { resetEmojiCode() }
                emojiUndo = nil
            }
        }
        if case .character = key { spacedEmojiWord = nil }
        switch key {
        case .character(let drawn):
            // Keys capture their character when drawn; two taps inside one frame after shift changes
            // would type the stale case ("EH"), so the shift state at the moment of the tap decides.
            let keyed = layer == .letters ? (shift.isActive ? drawn.uppercased() : drawn.lowercased()) : drawn
            settleSwipe(before: keyed)
            if typeEmojiCode(keyed, proxy: proxy) {
                if shift == .on { shift = .off }
                manualShiftPending = false
                applyAutoShift(before: localContextTail)
                afterEdit()
                return
            }
            let smart = smartChange(typing: keyed)
            // A quote that only changes shape takes the ordinary path with the curly character.
            let text = smart.flatMap { $0.deleteCount == 0 ? $0.insert : nil } ?? keyed
            if let smart, smart.deleteCount > 0 {
                applySmartRewrite(smart)
            } else if TypingEdits.correctingSeparators.contains(text) {
                commitSeparator(text)
            } else {
                if swipeCorrection.isTracking {
                    if !swipeReplacementStarted, let original = deletedSwipe,
                       proxy.currentInputSession() != original.session || swipeContext()?.before != original.before
                        || swipeContext()?.after != original.after || proxy.selectedText()?.isEmpty == false {
                        cancelSwipeCorrection()
                    }
                    if !swipeReplacementLeading.isEmpty {
                        proxy.insert(swipeReplacementLeading)
                        recordLocalInsertion(swipeReplacementLeading)
                        swipeReplacementLeading = ""
                    }
                    swipeReplacementStarted = true
                    swipeCorrection.insert(text, session: proxy.currentInputSession())
                }
                proxy.insert(text)
                recordLocalInsertion(text)
                if correctionLearning.isTracking {
                    correctionLearning.insert(text, session: proxy.currentInputSession())
                }
                lastCorrection = nil
                keptAfterRevert = nil
                lastSpaceAt = nil
                if text.first.map(Self.isWordCharacter) == true {
                    if keyedWord.isEmpty {
                        keyedWordAutoCapitalized = shift == .on && !manualShiftPending
                        // A new word: the last one stood, so its taps can teach.
                        flushTouchLesson()
                    }
                    let lined = keyedTouches.count == keyedWord.utf8.count
                    keyedWord += text
                    if lined, text.utf8.count == 1 {
                        keyedTouches.append(touch ?? .center)
                        if trainOffsets, keyedRawTouches.count == keyedTouches.count - 1 {
                            keyedRawTouches.append(raw ?? touch ?? .center)
                        }
                    }
                } else {
                    keyedWord = ""
                }
            }
            if shift == .on { shift = .off }
            manualShiftPending = false
            // iOS returns to letters after an apostrophe typed from the number layer ("don't").
            if keyed == "'", layer != .letters, !proxy.prefersNumbers { layer = .letters }
            applyAutoShift(before: localContextTail)
            afterEdit()
        case .space:
            let completed = swipeCommit?.word ?? keyedWord
            resetEmojiCode()
            spacedEmojiWord = completed.isEmpty ? nil : completed
            settleSwipe(before: " ")
            let now = Date()
            if let smart = smartChange(typing: " "), smart.deleteCount > 0 {
                applySmartRewrite(smart)
                lastSpaceAt = now
            } else if autocorrectActive, let last = lastSpaceAt, now.timeIntervalSince(last) < Self.doubleSpaceWindow,
               let edit = TypingEdits.doubleSpacePeriod(before: proxy.contextBefore()) {
                apply(edit)
                lastSpaceAt = nil
                lastCorrection = nil
                keyedWord = ""
            } else {
                commitSeparator(" ")
                lastSpaceAt = now
            }
            // And to letters after a space, unless the field asked for numbers.
            if layer != .letters, !proxy.prefersNumbers { layer = .letters }
            applyAutoShift(before: localContextTail)
            afterEdit()
        case .newline:
            resetEmojiCode()
            settleSwipe(before: "\n")
            if let smart = smartChange(typing: "\n"), smart.deleteCount > 0 { applySmartRewrite(smart) }
            else { commitSeparator("\n") }
            applyAutoShift(before: localContextTail)
            afterEdit()
        case .delete:
            break
        case .shift:
            toggleShift()
        case .switchLayer(let target, _):
            layer = target
            if target == .letters { applyAutoShift(before: proxy.contextBefore()) }
        case .globe:
            resetEmojiCode()
            proxy.advanceToNextInputMode()
        case .paste:
            // The system paste control owns this action on both faces.
            break
        case .emoji:
            resetEmojiCode()
            showsEmoji = true
        case .mic:
            break
        }
    }

    /// Moves the keys (the hold-123 picker, the side panel's buttons, VoiceOver). Does nothing while
    /// Settings has the one-handed keyboard off, so no gesture can turn it on by accident.
    func chooseHand(_ hand: KeyboardHand) {
        guard preferences.oneHandedEnabled, hand != self.hand else { return }
        handMemory.choose(hand)
        self.hand = hand
        KeyboardLog.typing.info("one-handed: \(hand.rawValue, privacy: .public)")
    }

    /// A tap on a suggestion slot. The typed literal is kept and remembered; anything else replaces it.
    func choose(_ suggestion: Suggestion) {
        if case let .emoji(anchor, word, spaced, session) = suggestion.kind {
            guard suggestions.contains(suggestion), let proxy, allowsEmojiCode(proxy), preferences.emojiPredictions,
                  preferences.showSuggestions, proxy.allowsAutocorrection, proxy.currentInputSession() == session else { return }
            guard spaced ? spacedEmojiWord == word : (swipeCommit?.word ?? keyedWord) == word else { return }
            let source = spaced ? word + " " : word
            let before = proxy.contextBefore(), after = proxy.contextAfter()
            guard anchor.owns(source, before: before, after: after, selection: proxy.selectedText()),
                  proxy.currentInputSession() == session else { return }
            let undoAnchor: EmojiShortcode
            if spaced {
                guard let appendAnchor = EmojiShortcode(before: before, after: after, selection: nil, hasText: true) else { return }
                undoAnchor = appendAnchor
            } else {
                undoAnchor = anchor
            }
            proxy.userTouchedKeyboard()
            feedback.keyDown()
            resetEmojiCode()
            clearSwipeCommit()
            cancelSwipeCorrection()
            correctionLearning.cancel()
            dictatedCorrection.cancel()
            keyedWord = ""
            lastCorrection = nil
            keptAfterRevert = nil
            lastSpaceAt = nil
            pendingTouchLesson = nil
            writeEmojiEdit(deleteCount: spaced ? 0 : word.count, insert: suggestion.text)
            emojiUndo = EmojiUndo(code: undoAnchor, session: session, emoji: suggestion.text,
                                  literal: spaced ? "" : word, replaced: spaced ? "" : word, predictionWord: word)
            EmojiStore.use(suggestion.text)
            afterEdit()
            return
        }
        resetEmojiCode()
        if chooseSwipe(suggestion) { return }
        cancelSwipeCorrection()
        if let target = selectedWordTarget {
            selectedWordTarget = nil
            // Inserting replaces the selection, so the only check needed is that the selection
            // is still that word in that field.
            guard let proxy, suggestion.kind != .literal, proxy.currentInputSession() == target.session,
                  proxy.selectedText() == target.word else {
                if !suggestions.isEmpty { suggestions = [] }
                return
            }
            markOwnEdit()
            correctionLearning.cancel() // A tapped suggestion is not a spelling the person authored.
            dictatedCorrection.cancel()
            feedback.keyDown()
            proxy.insert(suggestion.text)
            recordLocalInsertion(suggestion.text)
            keyedWord = ""
            lastCorrection = nil
            keptAfterRevert = nil
            if !suggestions.isEmpty { suggestions = [] }
            afterEdit()
            return
        }
        if suggestion.kind == .prediction {
            choosePrediction(suggestion)
            return
        }
        guard let proxy, let source = suggestionWord,
              proxy.currentInputSession() == suggestionSession else { return }
        let before = proxy.contextBefore(), after = proxy.contextAfter()
        guard let current = Autocorrector.composingWord(before: before, after: after),
              current == source,
              let edit = TypingEdits.choose(suggestion.text, before: before, after: after) else { return }
        markOwnEdit()
        correctionLearning.cancel() // A prediction is not a user-authored replacement spelling.
        dictatedCorrection.cancel()
        feedback.keyDown()
        if suggestion.kind == .literal, SpellingStore.learn(current) { configureSwipe() }
        // The everyday word taken over a kept slip ("baby" over a kept "bsby"): the slip goes.
        if suggestion.kind == .correction, SpellingStore.forgetKeptSlip(current, replacedBy: suggestion.text) { configureSwipe() }
        apply(edit)
        keyedWord = ""
        lastCorrection = nil
        keptAfterRevert = nil
        lastSpaceAt = edit.insert.hasSuffix(" ") ? Date() : nil
        if shift == .on { shift = .off }
        manualShiftPending = false
        applyAutoShift(before: localContextTail)
        afterEdit()
    }

    // MARK: Delete

    private func pressDelete() {
        guard let proxy else { return }
        swipeRetry = nil
        markOwnEdit(echoes: Self.echoesPerDelete)
        if emojiUndo != nil, restoreEmojiIfOwned(waitForEcho: true) {
            startDeleteRepeat()
            return
        }
        if emojiPending != nil { resetEmojiCode() }
        if let target = emojiCode {
            var code = target.code
            if code.removeLast() { emojiCode = (code, target.session) }
            else { resetEmojiCode() }
            if !emojiSuggestions.isEmpty { emojiSuggestions = [] }
            // The picker is now empty, so no query is on screen. Without this, `:fi`, Delete, `i`
            // matched the remembered "fi" and `refreshEmojiCode` left the picker closed.
            emojiShownQuery = nil
        }
        if let commit = swipeCommit, ownsSwipe(commit) {
            cancelSwipeCorrection()
            swipeRetry = commit
            if preferences.swipeLearningEnabled {
                deletedSwipe = commit
                swipeReplacementLeading = commit.leading
                swipeCorrection.select(commit.word, before: commit.before + commit.leading,
                                       after: commit.after, session: commit.session)
            }
            for _ in 0..<commit.deleteCount { proxy.deleteBackward() }
            localContextTail = String(commit.before.suffix(64))
            clearSwipeCommit()
            keyedWord = ""
            lastCorrection = nil
            lastSpaceAt = nil
            applyAutoShift(before: localContextTail)
            afterEdit()
            startDeleteRepeat()
            return
        }
        clearSwipeCommit()
        if swipeCorrection.isTracking {
            // Backspacing before a replacement starts removes its anchor, not a correction.
            if keyedWord.isEmpty { cancelSwipeCorrection() }
            else { swipeCorrection.delete(session: proxy.currentInputSession()) }
        }
        if correctionLearning.isTracking {
            correctionLearning.delete(session: proxy.currentInputSession())
        }
        if dictatedCorrection.isTracking {
            dictatedCorrection.delete(session: proxy.currentInputSession())
        }
        lastSpaceAt = nil
        // Deleting back into the last word (or undoing its correction) means it did not stand.
        pendingTouchLesson = nil
        let smart = lastSmartRewrite
        lastSmartRewrite = nil
        if let smart, proxy.currentInputSession() == smart.session,
           (localContextTail ?? proxy.contextBefore())?.hasSuffix(smart.applied) == true {
            apply(TypingEdits.Edit(deleteCount: smart.applied.count, insert: smart.plain))
            keyedWord = ""
            keptAfterRevert = nil
        } else if let correction = lastCorrection, let edit = TypingEdits.revert(correction, before: proxy.contextBefore()) {
            apply(edit)
            if correction.typed.contains(" "), let last = correction.typed.split(separator: " ").last {
                // A name covers earlier words too; only the last one is still being typed. If the
                // name also fixed a typo in it ("micro centwr"), that typo is kept like any undo.
                keyedWord = String(last)
                let fixedLetters = correction.replacement.split(separator: " ").last?.lowercased() != last.lowercased()
                keptAfterRevert = fixedLetters ? keyedWord : nil
                undoneName = keyedWord
            } else {
                keyedWord = correction.typed
                keptAfterRevert = correction.typed
            }
            KeyboardLog.typing.info("autocorrection undone by delete")
        } else {
            proxy.deleteBackward()
            if localContextTail?.isEmpty == false { localContextTail?.removeLast() }
            if !keyedWord.isEmpty {
                let lined = keyedTouches.count == keyedWord.utf8.count
                keyedWord.removeLast()
                if lined, !keyedTouches.isEmpty { keyedTouches.removeLast() }
                if lined, !keyedRawTouches.isEmpty { keyedRawTouches.removeLast() }
            }
            keptAfterRevert = nil
        }
        lastCorrection = nil
        applyAutoShift(before: localContextTail)
        afterEdit()
        startDeleteRepeat()
    }

    /// Repeats while held: characters first, then whole words after a couple of seconds. The task
    /// stops on release, on gesture cancellation, and when the keyboard disappears.
    private func startDeleteRepeat() {
        deleteRepeatTask?.cancel()
        deleteRepeatTask = Task { [weak self] in
            try? await Task.sleep(for: Self.deleteRepeatDelay)
            var repeats = 0
            while !Task.isCancelled {
                guard let self, let proxy = self.proxy else { return }
                self.resetEmojiCode()
                self.swipeRetry = nil
                self.correctionLearning.cancel()
                self.cancelSwipeCorrection()
                // Each repeat is our own edit: without this every echo of a held delete ran a
                // trait refresh and a selection inspection (three host reads) per character.
                self.markOwnEdit(echoes: Self.echoesPerDelete)
                if repeats < Self.deleteWordsAfter {
                    proxy.deleteBackward()
                    repeats += 1
                    try? await Task.sleep(for: Self.deleteRepeatInterval)
                } else {
                    let count = TypingEdits.wordDeletionCount(before: proxy.contextBefore())
                    for _ in 0..<count { proxy.deleteBackward() }
                    try? await Task.sleep(for: Self.deleteWordInterval)
                }
                self.keyedWord = ""
                self.localContextTail = nil
            }
        }
    }

    func endDeleteRepeat() {
        deleteHeld = false
        guard deleteRepeatTask != nil else { return }
        deleteRepeatTask?.cancel()
        deleteRepeatTask = nil
        afterEdit()
    }

    // MARK: Smart punctuation

    /// What smart punctuation does with this key, or nil to type it as it is. Off unless the
    /// person turned it on, and wherever the field says no.
    private func smartChange(typing text: String) -> SmartPunctuation.Change? {
        guard preferences.smartPunctuation, let proxy, text.count == 1, let character = text.first else { return nil }
        let quotes = proxy.allowsSmartQuotes, dashes = proxy.allowsSmartDashes
        guard quotes || dashes,
              let context = localContextTail ?? proxy.contextBefore() ?? (proxy.fieldHasText() ? nil : "") else { return nil }
        guard let change = SmartPunctuation.edit(typing: character, before: context, quotes: quotes, dashes: dashes) else { return nil }
        // A rewrite deletes typed characters; while a replacement is being tracked for learning,
        // the tracker must see exactly what was keyed.
        if change.deleteCount > 0, swipeCorrection.isTracking || correctionLearning.isTracking { return nil }
        return change
    }

    private func applySmartRewrite(_ change: SmartPunctuation.Change) {
        guard let proxy else { return }
        apply(TypingEdits.Edit(deleteCount: change.deleteCount, insert: change.insert))
        lastSmartRewrite = (change.insert, change.plain, proxy.currentInputSession())
        lastCorrection = nil
        keptAfterRevert = nil
        lastSpaceAt = nil
        // The word in progress was rewritten, so it is no longer the word that was keyed.
        keyedWord = ""
    }

    // MARK: Autocorrect

    /// `word`, ending `before`, follows `@` or `#`: a handle or a tag, which is a name, not a
    /// misspelling. Swipe already leaves these alone (`SwipeSpacing`).
    static func isTag(_ word: String, before: String?) -> Bool {
        guard !word.isEmpty, let before, before.hasSuffix(word) else { return false }
        let mark = before.dropLast(word.count).last
        return mark == "@" || mark == "#"
    }

    private func commitSeparator(_ separator: String) {
        guard let proxy else { return }
        finishLearningCorrection()
        let deliberateSwipeReplacement = finishSwipeCorrection()
        guard !deliberateSwipeReplacement, autocorrectActive, !keyedWord.isEmpty else {
            proxy.insert(separator)
            recordLocalInsertion(separator)
            lastCorrection = nil
            keptAfterRevert = nil
            keyedWord = ""
            if separator != " " { lastSpaceAt = nil }
            return
        }
        let typed = TypingEdits.normalized(keyedWord)
        let touches = keyedTouches.count == keyedWord.utf8.count ? keyedTouches : nil
        let rawTouches = keyedRawTouches.count == keyedWord.utf8.count ? keyedRawTouches : nil
        let reverted = keptAfterRevert.map { $0 == keyedWord } ?? false
        let nameUndone = undoneName == keyedWord
        undoneName = nil
        // Most words stay as typed. Decide from the keyed word alone first, so a plain space
        // costs no round trip to the host; only a replacement, a word the keyboard does not
        // know (the word before it may settle what was meant) or learning a word whose
        // correction was undone reads and validates the text at the cursor.
        let quick = corrector?.evaluate(typed, autoCapitalized: keyedWordAutoCapitalized, touches: touches, preserveLowercase: preservesLowercaseCorrections)
        // A word that can finish a name of ordinary words ("micro center") reads the words before it.
        let mayFinishName = !preservesLowercaseCorrections && !nameUndone && PhraseCasing.mayEndName(typed)
        guard reverted || quick?.replacement != nil || quick?.dependsOnPrevious == true || mayFinishName else {
            keptAfterRevert = nil
            proxy.insert(separator)
            recordLocalInsertion(separator)
            lastCorrection = nil
            if let rawTouches { pendingTouchLesson = (typed, typed, rawTouches, corrector?.recognizes(typed) == true, proxy.currentInputSession()) }
            keyedWord = ""
            if separator != " " { lastSpaceAt = nil }
            return
        }
        // Read once each, and validate fresh context before any destructive replacement.
        let before = proxy.contextBefore()
        let after = proxy.contextAfter()
        // Learned only if the reverted word is still the one at the cursor: a cursor moved elsewhere
        // leaves keyedWord stale, and a space typed there must not teach the typo.
        if reverted, let kept = keptAfterRevert,
           Autocorrector.composingWord(before: before, after: after) == TypingEdits.normalized(kept) {
            if SpellingStore.learn(kept) { configureSwipe() }
        }
        keptAfterRevert = nil
        // Checked only here, where a replacement was coming: a plain space costs no host read.
        if Self.isTag(keyedWord, before: before) {
            proxy.insert(separator)
            recordLocalInsertion(separator)
            lastCorrection = nil
            keyedWord = ""
            if separator != " " { lastSpaceAt = nil }
            return
        }
        let edit = TypingEdits.separator(
            separator,
            typedWord: keyedWord,
            before: before,
            after: after,
            corrector: autocorrectActive ? corrector : nil,
            autoCapitalized: keyedWordAutoCapitalized,
            touches: touches, preserveLowercase: preservesLowercaseCorrections, writesNames: !nameUndone)
        apply(edit)
        lastCorrection = edit.correction
        // A name's correction also covers the words before this one; the taps are this word's.
        let committed = edit.correction.map { correction in
            correction.typed == typed ? correction.replacement : correction.replacement.split(separator: " ").last.map(String.init) ?? typed
        } ?? typed
        if let rawTouches { pendingTouchLesson = (typed, committed, rawTouches, corrector?.recognizes(committed) == true, proxy.currentInputSession()) }
        keyedWord = ""
        if separator != " " { lastSpaceAt = nil }
        if edit.correction != nil {
            KeyboardLog.typing.info("autocorrected a word on \(separator == " " ? "space" : "punctuation", privacy: .public)")
        }
    }

    /// Teaches the last committed word's taps to the learned touch offsets.
    private func flushTouchLesson() {
        guard let lesson = pendingTouchLesson else { return }
        pendingTouchLesson = nil
        guard let session = lesson.session, let proxy, proxy.currentInputSession() == session,
              proxy.allowsAutocorrection else { return }
        TouchAdaptationStore.learn(typed: lesson.typed, committed: lesson.committed, touches: lesson.touches, recognized: lesson.recognized)
    }

    /// A dictated word retyped as a name, a new word or in other capitals is learned; one ordinary
    /// word swapped for another ("went" for "go") is rewording, not a mishearing.
    static func isLearnableDictationFix(_ learned: DictatedWordCorrection.Learned) -> Bool {
        let written = learned.written
        guard learned.heard.lowercased() != written.lowercased() else { return written != written.lowercased() }
        guard written == written.lowercased(), let entry = WordList.shared?.lookup(written) else { return true }
        return entry.display != entry.display.lowercased()
    }

    private func finishLearningCorrection() {
        #if DEBUG
        KeyboardLog.typing.info("selection finish tracking=\(self.correctionLearning.isTracking, privacy: .public)")
        #endif
        guard let proxy else { return }
        var heard: String?
        let word: String
        let original: String
        // Whether the word's first capital came from the keyboard and not the person.
        var autoCapitalized = keyedWordAutoCapitalized
        if correctionLearning.isTracking {
            dictatedCorrection.cancel()
            let selected = correctionLearning.original ?? ""
            guard let typed = correctionLearning.finish(before: proxy.contextBefore(), after: proxy.contextAfter(),
                                                        session: proxy.currentInputSession()) else { return }
            word = typed
            original = selected
            onWordCorrected?(original, word)
        } else if dictatedCorrection.isTracking {
            guard let learned = dictatedCorrection.finish(contextBefore: proxy.contextBefore(), session: proxy.currentInputSession()) else { return }
            onWordCorrected?(learned.heard, learned.written)
            guard Self.isLearnableDictationFix(learned) else { return }
            word = learned.written
            heard = learned.heard
            original = learned.heard
            // Backspacing part of the word keeps dictation's first letter: that capital was not typed.
            if keyedWord != word { autoCapitalized = true }
        } else {
            return
        }
        #if DEBUG
        KeyboardLog.typing.info("selection correction validated")
        #endif
        // Retyping a selected "thata" as "thats" means "that's": typing never has an apostrophe
        // key on the letter layer. Saving "thats" would protect the typo from the separator that
        // is about to fix it, and every later "thats" with it.
        if corrector?.isBareContraction(word) == true { return }
        // Retyping "teh" as "The" at the start of a sentence fixes a typo; it does not make "The"
        // a personal word. Saved, it would capitalize every "the" dictated afterwards.
        if corrector?.isEverydayWord(word) == true { return }
        // A slip of the keys made while fixing a word ("definitly" over "defiantly") is not a word
        // to keep: saved, it is never corrected again and pulls dictation toward it. The separator
        // that follows fixes it as it would any typed word.
        if corrector?.isSlip(word, replacing: original, autoCapitalized: autoCapitalized) == true {
            KeyboardLog.typing.info("hand correction read as a slip, not learned")
            return
        }
        // The separator must not autocorrect the deliberately authored replacement before
        // its asynchronous vocabulary write finishes. This protection is not a permanent learn.
        if let vocabularyWords { corrector?.setPersonalWords(PersonalVocabulary.normalized([word] + vocabularyWords)) }
        Self.vocabularyQueue.async { [weak self, vocabularyStore] in
            do {
                guard let vocabulary = vocabularyStore() else { return }
                try vocabulary.learnCorrection(word, heard: heard)
                let words = try vocabulary.document().appliedWords
                DispatchQueue.main.async {
                    guard self?.hasFullAccess == true else { return }
                    self?.vocabularyWords = words
                    self?.corrector?.setPersonalWords(words)
                    // Swipe knows the new word at once, as typing does.
                    self?.configureSwipe()
                }
            } catch { KeyboardLog.typing.error("Could not save a corrected spelling") }
        }
    }

    /// `before` is the context read once for this edit; the text after the cursor is read only when
    /// a keyed word could be at the cursor, because each read is a round trip to the host.
    private func refreshSuggestions(before: String?) {
        if emojiCode != nil {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        if let commit = swipeCommit, ownsSwipe(commit) {
            let words = swipeAlternatives.map { Suggestion(text: $0, kind: .completion, autoApplies: false) }
            suggestions = withEmoji(words, word: commit.word, before: before, spaced: false)
            return
        }
        clearSwipeCommit()
        var next: [Suggestion] = []
        suggestionWord = nil
        suggestionSession = nil
        if let target = selectedWordTarget {
            guard preferences.showSuggestions, autocorrectActive, let corrector, let proxy,
                  proxy.currentInputSession() == target.session, proxy.selectedText() == target.word else {
                selectedWordTarget = nil
                if !suggestions.isEmpty { suggestions = [] }
                return
            }
            // Nothing here is armed: a selected word changes only when a suggestion is tapped.
            next = corrector.evaluate(target.word, preserveLowercase: preservesLowercaseCorrections).suggestions
                .filter { $0.kind != .literal }
                .map { Suggestion(text: $0.text, kind: $0.kind, autoApplies: false) }
            if next != suggestions { suggestions = next }
            return
        }
        if preferences.showSuggestions, autocorrectActive, let corrector, let proxy, !keyedWord.isEmpty,
           let word = Autocorrector.composingWord(before: before, after: proxy.contextAfter()),
           word == keyedWord.replacingOccurrences(of: "\u{2019}", with: "'") {
            let touches = keyedTouches.count == keyedWord.utf8.count ? keyedTouches : nil
            next = corrector.evaluate(word, autoCapitalized: keyedWordAutoCapitalized, touches: touches, preserveLowercase: preservesLowercaseCorrections,
                                      previous: Autocorrector.previousWord(before: before, composing: word)).suggestions
            suggestionWord = word
            suggestionSession = proxy.currentInputSession()
            // Until a reverted word is kept or learned, nothing in the row is armed to replace it.
            if keptAfterRevert == keyedWord {
                next = next.map { Suggestion(text: $0.text, kind: $0.kind, autoApplies: false) }
            }
        }
        predictionTail = nil
        predictedWords = []
        if next.isEmpty, let predicted = predictions(before: before) {
            predictionTail = predicted.tail
            predictedWords = predicted.words
            suggestionSession = proxy?.currentInputSession()
            next = casedPredictions()
        }
        if !keyedWord.isEmpty {
            next = withEmoji(next, word: keyedWord, before: before, spaced: false)
        } else if let spacedEmojiWord {
            next = withEmoji(next, word: spacedEmojiWord, before: before, spaced: true)
        }
        if next != suggestions { suggestions = next }
    }

    /// An exact word owns its emoji only at the caret where it was offered.
    private func withEmoji(_ words: [Suggestion], word: String, before: String?, spaced: Bool) -> [Suggestion] {
        guard preferences.emojiPredictions, preferences.showSuggestions,
              let proxy, proxy.allowsAutocorrection, allowsEmojiCode(proxy), let before, let session = proxy.currentInputSession(),
              EmojiSearchIndex.mayPredict(word) else { return words }
        let source = spaced ? word + " " : word
        guard before.hasSuffix(source),
              let anchor = EmojiShortcode(before: String(before.dropLast(source.count)), after: proxy.contextAfter(),
                                          selection: proxy.selectedText(), hasText: true) else { return words }
        guard let index = EmojiStore.search else { loadEmojiSearchIfNeeded(); return words }
        guard let hit = index.prediction(word, history: EmojiStore.history) else { return words }
        var candidates = words
        let emoji = Suggestion(text: shownEmoji(hit), kind: .emoji(anchor: anchor, word: word, spaced: spaced, session: session))
        candidates.insert(emoji, at: min(1, candidates.count))
        return candidates
    }

    // MARK: Next-word predictions

    /// How much of the text before the cursor a tapped prediction checks is still there.
    static let predictionTailLength = 24

    /// Whole next words for the row, between words: after a word and one space, at the end of
    /// the text or of its line, in a field that takes autocorrection. Nothing at a sentence
    /// start, after a number or a name the list lacks, in the middle of text, or where the host
    /// hides the text before the cursor, so the row there stays as it was.
    private func predictions(before: String?) -> (tail: String, words: [String])? {
        guard preferences.showSuggestions, autocorrectActive, keyedWord.isEmpty, selectedWordTarget == nil,
              let corrector, let proxy, let before, before.last == " ",
              let previous = SwipeSpacing.previousWord(before: before) else { return nil }
        if let after = proxy.contextAfter(), let next = after.first, !next.isNewline { return nil }
        let words = corrector.predictions(after: previous).map(\.text)
        guard !words.isEmpty else { return nil }
        return (String(before.suffix(Self.predictionTailLength)), words)
    }

    /// The predicted words as Shift would write them now: a capital with Shift on, all capitals
    /// with it locked, and lowercase where the field or the person keeps corrections lowercase.
    private func casedPredictions() -> [Suggestion] {
        predictedWords.map { word in
            let text: String
            switch shift {
            case .locked: text = word.uppercased()
            case .on: text = word.prefix(1).uppercased() + word.dropFirst()
            case .off: text = preservesLowercaseCorrections ? word.lowercased() : word
            }
            return Suggestion(text: text, kind: .prediction)
        }
    }

    /// Writes a tapped prediction and a space, then offers what follows it at once, so a
    /// sentence can be tapped out word after word without waiting for the host to answer.
    private func choosePrediction(_ suggestion: Suggestion) {
        let tail = predictionTail
        predictionTail = nil
        guard let proxy, let corrector, let tail, keyedWord.isEmpty, proxy.currentInputSession() == suggestionSession,
              let before = proxy.contextBefore(), before.hasSuffix(tail) else {
            // The text moved under the row: these words belonged somewhere else.
            predictedWords = []
            if !suggestions.isEmpty { suggestions = [] }
            afterEdit()
            return
        }
        markOwnEdit()
        correctionLearning.cancel() // A prediction is not a spelling the person authored.
        dictatedCorrection.cancel()
        feedback.keyDown()
        flushTouchLesson() // The word before stood.
        let text = suggestion.text + " "
        proxy.insert(text)
        recordLocalInsertion(text)
        lastCorrection = nil
        keptAfterRevert = nil
        lastSpaceAt = Date()
        if shift == .on { shift = .off }
        manualShiftPending = false
        applyAutoShift(before: localContextTail)
        predictedWords = corrector.predictions(after: suggestion.text).map(\.text)
        if !predictedWords.isEmpty {
            predictionTail = String((before + text).suffix(Self.predictionTailLength))
        }
        let next = casedPredictions()
        if next != suggestions { suggestions = next }
        afterEdit()
    }

    private func apply(_ edit: TypingEdits.Edit) {
        guard let proxy else { return }
        for _ in 0..<edit.deleteCount {
            proxy.deleteBackward()
            if localContextTail?.isEmpty == false { localContextTail?.removeLast() }
        }
        if !edit.insert.isEmpty { proxy.insert(edit.insert); recordLocalInsertion(edit.insert) }
    }

    /// The host's input session, for work that finishes after the tap that started it.
    var currentSession: String? { proxy?.currentInputSession() }

    /// The compact face's Paste key: inserts the clipboard as the keyboard's own edit, ending
    /// any word in progress so autocorrect never rewrites pasted text.
    /// Clipboard history's part in every paste: bound at the tap, told the text after it is in
    /// the field (`PasteSaving`).
    @ObservationIgnored var pasteSaving: PasteSaving?

    func insertPasted(_ text: String) {
        if swipePending { swipeInputs.append { [weak self] in self?.insertPasted(text) }; return }
        cancelSwipeCorrection()
        settleSwipe(before: text)
        guard let proxy else { return }
        resetEmojiCode()
        pendingTouchLesson = nil
        markOwnEdit()
        keyedWord = ""
        lastCorrection = nil
        proxy.insert(text)
        recordLocalInsertion(text)
        afterEdit()
    }

    /// The emoji panel's ABC key.
    func closeEmoji() {
        set(\.showsEmoji, false)
        if layer == .letters { applyAutoShift(before: localContextTail ?? proxy?.contextBefore()) }
    }

    /// Click and haptic for a touch in the emoji panel, as for a key.
    func emojiPanelKeyDown() {
        proxy?.userTouchedKeyboard()
        feedback.keyDown()
    }

    /// An emoji from the panel. Like a paste, it ends any word in progress, so autocorrect never
    /// rewrites across it.
    func insertEmoji(_ text: String) {
        resetEmojiCode()
        if swipePending { swipeInputs.append { [weak self] in self?.insertEmoji(text) }; return }
        cancelSwipeCorrection()
        settleSwipe(before: text)
        guard let proxy else { return }
        pendingTouchLesson = nil
        markOwnEdit()
        finishLearningCorrection()
        keyedWord = ""
        lastCorrection = nil
        keptAfterRevert = nil
        lastSpaceAt = nil
        proxy.insert(text)
        recordLocalInsertion(text)
        afterEdit()
    }

    private func recordLocalInsertion(_ text: String) {
        // A short local suffix is enough for immediate sentence casing, without a host IPC read.
        localContextTail = String(((localContextTail ?? "") + text).suffix(64))
    }

    /// Document context can cross the process boundary. Do not put those reads between a key's
    /// touch-up and the next touch-down/highlight. Coalesce advisory work after a typing burst;
    /// separator/suggestion replacements still validate fresh context synchronously.
    private func afterEdit() {
        reconcileDeadline = Date().timeIntervalSinceReferenceDate + Self.advisoryDelay
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        scheduleReconcile(after: Self.advisoryDelay)
    }

    private func scheduleReconcile(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.reconcileTimerFired() }
        }
    }

    /// The one in-flight block: runs the reconciliation once typing has paused for
    /// `advisoryDelay`, or waits out the rest of a deadline a later key pushed back.
    private func reconcileTimerFired() {
        guard let deadline = reconcileDeadline else {
            reconcileScheduled = false
            return
        }
        let remaining = deadline - Date().timeIntervalSinceReferenceDate
        if remaining > 0.002 {
            scheduleReconcile(after: remaining)
            return
        }
        reconcileScheduled = false
        reconcileContext()
    }

    private func reconcileContext() {
        reconcileDeadline = nil
        guard cursorToken == nil else { return }
        if let commit = swipeCommit, waitingForSwipeEcho(commit) {
            afterEdit()
            return
        }
        KeyTrace.measure("reconcile") {
            let before = proxy?.contextBefore()
            if let before, let expected = localContextTail, !expected.isEmpty,
               !before.hasSuffix(expected), !expected.hasSuffix(before) {
                cancelSwipeInput()
            }
            if let before, emojiCode == nil { localContextTail = String(before.suffix(64)) }
            // The caret moved somewhere the host will not describe: the remembered tail belongs
            // to the old place, and unknown is the honest answer.
            else if selectionRefreshRequested, proxy?.fieldHasText() == true { localContextTail = nil }
            if selectionRefreshRequested, let proxy {
                selectionRefreshRequested = false
                let selection = proxy.selectedText()
                let after = proxy.contextAfter()
                #if DEBUG
                KeyboardLog.typing.info("selection inspect count=\(selection?.count ?? -1, privacy: .public) beforeKnown=\(before != nil, privacy: .public) afterKnown=\(after != nil, privacy: .public) sessionKnown=\(proxy.currentInputSession() != nil, privacy: .public) allowed=\(proxy.allowsAutocorrection, privacy: .public)")
                #endif
                if let selected = selection, !selected.isEmpty {
                    cancelSwipeInput()
                    keyedWord = ""
                    lastCorrection = nil
                    keptAfterRevert = nil
                    correctionLearning.cancel()
                    dictatedCorrection.cancel()
                    selectedWordTarget = Self.selectedWord(selected, before: before, after: after)
                        .flatMap { word in proxy.currentInputSession().map { (word, $0) } }
                    // Respect sensitive field restrictions and the explicit learning switch.
                    if proxy.allowsAutocorrection, learnsFromCorrections {
                        correctionLearning.select(selected, before: before, after: after,
                                                  session: proxy.currentInputSession(), emptyContextMayBeNil: true)
                        #if DEBUG
                        KeyboardLog.typing.info("selection tracker armed=\(self.correctionLearning.isTracking, privacy: .public)")
                        #endif
                    }
                } else {
                    selectedWordTarget = nil
                    if correctionLearning.isTracking {
                        correctionLearning.reconcile(before: before, after: after,
                                                     session: proxy.currentInputSession())
                    }
                }
            }
            // A host may echo an older edit. Do not relatch Shift while our new word is absent.
            if emojiCode == nil, keyedWord.isEmpty || before?.hasSuffix(keyedWord) == true {
                applyAutoShift(before: before)
            }
            if emojiUndoDeadline != nil { _ = restoreEmojiIfOwned(waitForEcho: true) }
            refreshEmojiCode()
            refreshSuggestions(before: before)
            if let proxy { set(\.returnEnabled, !proxy.dimsReturnWhenEmpty || proxy.fieldHasText()) }
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "\u{2019}"
    }

    /// The selection when it is one whole word: letters and apostrophes, bounded by something
    /// that is not a word character. UIKit reports nil at the edge of a selection that touches
    /// the start or end of the text, so nil is an edge here, as it is for the learning tracker.
    static func selectedWord(_ selection: String, before: String?, after: String?) -> String? {
        guard (1...32).contains(selection.count), selection.allSatisfy(isWordCharacter),
              selection.contains(where: \.isLetter),
              before?.last.map({ !isWordCharacter($0) }) ?? true,
              after?.first.map({ !isWordCharacter($0) }) ?? true else { return nil }
        return selection
    }

    private var preservesLowercaseCorrections: Bool {
        !preferences.autoCapitalizationEnabled || (proxy?.fieldNeverCapitalizes ?? false)
    }

    // MARK: Shift

    /// How a dictation's first letter is cased, read at the moment it is inserted: the way Shift
    /// shows it. The compact face uses the same Shift state, updated from the field's traits.
    var dictationOpening: DictationOpening {
        // A locked Shift is a deliberate choice, so it wins even with Follow Shift off.
        if shift == .locked { return .capsLock }
        guard preferences.dictationFollowsShift, let proxy else { return .automatic }
        // Number/symbol layers do not draw Shift or refresh its automatic state. A deliberate
        // Shift choice still wins there; otherwise use the current field instead of stale keys.
        if layer != .letters, !manualShiftPending, shift != .locked {
            return !preferences.autoCapitalizationEnabled || proxy.fieldNeverCapitalizes ? .lowercase : .automatic
        }
        // Dictation inserts its own space after punctuation. Typing waits for the space key.
        if shift == .off, !manualShiftPending, preferences.autoCapitalizationEnabled,
           proxy.capitalization == .sentences, let before = proxy.contextBefore(),
           let last = before.last, !last.isWhitespace, SentenceBoundary.startsSentence(after: before) {
            return .automatic
        }
        // Use the state that draws the keys. Recomputing from document context here can disagree
        // when the host temporarily returns nil, turning a visibly lowercase Shift into a capital.
        return shift.isActive ? .capital : .lowercase
    }

    /// A dictation landed: it used a one-shot Shift as a typed letter would, and the next Shift
    /// follows the text it left.
    func dictationInserted(_ text: String) {
        resetEmojiCode()
        dictatedCorrection.begin(inserted: text, contextBefore: proxy?.contextBefore(), session: proxy?.currentInputSession())
        cancelSwipeInput()
        pendingTouchLesson = nil
        // Dictated text ends any word in progress, as a paste does. A stale keyed word made the
        // next typed word fail its context check, so it went uncorrected.
        correctionLearning.cancel()
        keyedWord = ""
        lastCorrection = nil
        keptAfterRevert = nil
        lastSpaceAt = nil
        localContextTail = nil
        if shift == .on { shift = .off }
        manualShiftPending = false
        applyAutoShift(before: proxy?.contextBefore())
    }

    /// The mic took a dictation back out (Undo, "Scratch that"). Shift follows the text that is
    /// left, as it does after a delete key: an emptied field or a finished sentence gets its
    /// capital again.
    func dictationRemoved() {
        resetEmojiCode()
        dictatedCorrection.cancel()
        cancelSwipeInput()
        keyedWord = ""
        lastCorrection = nil
        localContextTail = nil
        manualShiftPending = false
        applyAutoShift(before: proxy?.contextBefore())
    }

    #if DEBUG && targetEnvironment(simulator)
    /// What a double tap on Shift leaves behind, for the simulator fixture.
    func lockShift() {
        manualShiftPending = true
        lastShiftTap = nil
        shift = .locked
    }
    #endif

    private func toggleShift() {
        manualShiftPending = true
        let now = Date()
        defer { recasePredictions() }
        if let last = lastShiftTap, now.timeIntervalSince(last) < 0.3 {
            shift = .locked
            lastShiftTap = nil
            return
        }
        lastShiftTap = now
        switch shift {
        case .off: shift = .on
        case .on, .locked: shift = .off
        }
    }

    /// The row's predictions follow Shift the moment it is tapped, as the keys do.
    private func recasePredictions() {
        guard predictionTail != nil, suggestions.contains(where: { $0.kind == .prediction }) else { return }
        var next = casedPredictions()
        if let spacedEmojiWord {
            next = withEmoji(next, word: spacedEmojiWord, before: localContextTail, spaced: true)
        }
        if next != suggestions { suggestions = next }
    }

    /// Shift on at the start of a sentence when the field auto-capitalizes sentences.
    private func applyAutoShift(before: String?) {
        guard let proxy, !manualShiftPending, shift != .locked, layer == .letters else { return }
        let capitalization = proxy.capitalization
        guard preferences.autoCapitalizationEnabled, capitalization != .none else {
            set(\.shift, .off)
            return
        }
        // Unknown context is not an empty field. Some hosts temporarily return nil after an
        // edit; treating that as sentence-start relatches Shift after every typed letter. But a
        // field that holds no text at all (cleared with a held delete in Messages, which then
        // reports nil) is a sentence start, as on the system keyboard.
        guard let before = before ?? (proxy.fieldHasText() ? nil : "") else { return }
        set(\.shift, capitalization.capitalizesNext(after: before) ? .on : .off)
    }

    nonisolated static func startsSentence(after context: String) -> Bool {
        SentenceBoundary.startsSentenceWhileTyping(after: context)
    }
}


private extension KeyboardModel {
    func resetEmojiCode() {
        spacedEmojiWord = nil
        emojiCode = nil
        emojiUndo = nil
        emojiUndoDeadline = nil
        emojiPending = nil
        emojiShownQuery = nil
        if !emojiSuggestions.isEmpty { emojiSuggestions = [] }
    }

    func allowsEmojiCode(_ proxy: TextProxyActions) -> Bool {
        proxy.allowsEmojiShortcodes && !showsEmoji && !dictationOwnsStrip
    }

    /// Only the opening colon reads the host on the typing path. Subsequent taps have the same
    /// latency as ordinary letters, and lookups run after the burst of keystrokes.
    func typeEmojiCode(_ key: String, proxy: TextProxyActions) -> Bool {
        if var target = emojiCode {
            if key == ":" {
                if target.code.isSearchable, allowsEmojiCode(proxy),
                   proxy.currentInputSession() == target.session {
                    let index = EmojiStore.search
                    let emoji = index?.exact(target.code.query)
                    if let emoji, replaceEmojiCode(emoji, closed: false, restoreClosingColon: true) { return true }
                    if index == nil || emoji != nil { queueEmojiReplacement(emoji, closed: true) }
                    else { resetEmojiCode() }
                    proxy.insert(key)
                    recordLocalInsertion(key)
                    return true
                }
            } else if target.code.append(key) {
                emojiCode = target
                if target.code.isSearchable { loadEmojiSearchIfNeeded() }
                proxy.insert(key)
                recordLocalInsertion(key)
                return true
            }
            resetEmojiCode()
        }
        guard key == ":", allowsEmojiCode(proxy), let session = proxy.currentInputSession(),
              let code = EmojiShortcode(before: proxy.contextBefore(), after: proxy.contextAfter(),
                                       selection: proxy.selectedText(), hasText: proxy.fieldHasText())
        else { return false }
        flushTouchLesson()
        cancelSwipeCorrection()
        correctionLearning.cancel()
        dictatedCorrection.cancel()
        keyedWord = ""
        lastSpaceAt = nil
        lastCorrection = nil
        keptAfterRevert = nil
        selectedWordTarget = nil
        emojiCode = (code, session)
        if !suggestions.isEmpty { suggestions = [] }
        proxy.insert(key)
        recordLocalInsertion(key)
        return true
    }

    func queueEmojiReplacement(_ emoji: String?, closed: Bool) {
        emojiPending = (emoji, closed, ProcessInfo.processInfo.systemUptime + 0.35)
        if !emojiSuggestions.isEmpty { emojiSuggestions = [] }
        afterEdit()
    }

    func loadEmojiSearchIfNeeded() {
        guard EmojiStore.search == nil, !loadingEmojiSearch else { return }
        loadingEmojiSearch = true
        EmojiStore.loadSearch { [weak self] in
            guard let self else { return }
            self.loadingEmojiSearch = false
            if EmojiStore.search == nil { self.resetEmojiCode() }
            else { self.afterEdit() }
        }
    }

    func refreshEmojiCode() {
        guard let target = emojiCode, target.code.isSearchable, let proxy else { return }
        guard allowsEmojiCode(proxy), proxy.currentInputSession() == target.session else {
            resetEmojiCode()
            return
        }
        guard let search = EmojiStore.search else {
            loadEmojiSearchIfNeeded()
            return
        }
        if let pending = emojiPending {
            let base = pending.emoji ?? search.exact(target.code.query)
            if let base, replaceEmojiCode(base, closed: pending.closed, restoreClosingColon: pending.closed) { return }
            if base != nil, ProcessInfo.processInfo.systemUptime < pending.deadline {
                afterEdit()
            } else {
                resetEmojiCode()
            }
            return
        }
        // Keep showing matches while a web editor catches up. The destructive path below
        // always rechecks live text, selection, and field identity.
        guard target.code.query != emojiShownQuery else { return }
        emojiShownQuery = target.code.query
        let hits = search.matches(target.code.query, history: EmojiStore.history)
        if emojiSuggestions != hits { emojiSuggestions = hits }
    }

    /// A delayed proxy may still show the old token on the first Delete. Wait for it to
    /// acknowledge the replacement within the same field before changing the text again.
    func restoreEmojiIfOwned(waitForEcho: Bool) -> Bool {
        defer { if emojiUndoDeadline == nil { emojiUndo = nil } }
        guard let undo = emojiUndo, let proxy, allowsEmojiCode(proxy),
              proxy.currentInputSession() == undo.session else {
            emojiUndoDeadline = nil
            return false
        }
        let before = proxy.contextBefore(), after = proxy.contextAfter(), selection = proxy.selectedText()
        if undo.code.owns(undo.emoji, before: before, after: after, selection: selection),
           proxy.currentInputSession() == undo.session {
            emojiUndoDeadline = nil
            writeEmojiEdit(deleteCount: undo.emoji.count, insert: undo.literal)
            if let word = undo.predictionWord {
                if undo.literal.isEmpty { spacedEmojiWord = word } else { keyedWord = word }
            } else if undo.literal == undo.code.literal {
                emojiCode = (undo.code, undo.session)
            }
            afterEdit()
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if waitForEcho, now < (emojiUndoDeadline ?? .infinity),
           undo.code.couldBeEcho(of: undo.replaced, before: before, after: after, selection: selection) {
            emojiUndoDeadline = emojiUndoDeadline ?? (now + 0.35)
            afterEdit()
            return true
        }
        emojiUndoDeadline = nil
        return false
    }

    func writeEmojiEdit(deleteCount: Int, insert: String) {
        markOwnEdit(echoes: deleteCount * Self.echoesPerDelete + 1)
        writingEmoji = true
        defer { writingEmoji = false }
        apply(TypingEdits.Edit(deleteCount: deleteCount, insert: insert))
    }

    @discardableResult
    func replaceEmojiCode(_ base: String, closed: Bool, restoreClosingColon: Bool) -> Bool {
        guard let target = emojiCode, let proxy, allowsEmojiCode(proxy),
              proxy.currentInputSession() == target.session, let emoji = EmojiStore.byBase[base] else { return false }
        let source = target.code.literal + (closed ? ":" : "")
        guard target.code.owns(source, before: proxy.contextBefore(), after: proxy.contextAfter(),
                              selection: proxy.selectedText()), proxy.currentInputSession() == target.session else { return false }
        let text = EmojiStore.history.shown(emoji)
        writeEmojiEdit(deleteCount: source.count, insert: text)
        resetEmojiCode()
        emojiUndo = EmojiUndo(code: target.code, session: target.session, emoji: text,
                             literal: target.code.literal + (restoreClosingColon ? ":" : ""), replaced: source)
        EmojiStore.use(text)
        afterEdit()
        return true
    }
}

extension KeyboardModel {
    func setDictationOwnsStrip(_ owns: Bool) {
        guard dictationOwnsStrip != owns else { return }
        dictationOwnsStrip = owns
        if owns {
            pasteAccessHint = nil
            resetEmojiCode()
        }
    }

    func dismissEmojiPickerForStyles() {
        if emojiCode != nil { resetEmojiCode() }
    }

    func stripContent(hasUnsureWords: Bool, allowsWordSuggestions: Bool = true) -> KeyboardStripContent {
        KeyboardStripContent.resolve(
            dictationOwnsStrip: dictationOwnsStrip,
            emojiPickerOpen: !showsEmoji && !emojiSuggestions.isEmpty,
            hasUnsureWords: hasUnsureWords,
            suggestions: allowsWordSuggestions && (preferences.showSuggestions || hasSwipeAlternatives) ? suggestions : []
        )
    }

    func shownEmoji(_ match: EmojiSearchIndex.Match) -> String {
        EmojiStore.byBase[match.emoji].map { EmojiStore.history.shown($0) } ?? match.emoji
    }

    func chooseEmojiSuggestion(_ match: EmojiSearchIndex.Match) {
        guard emojiShownQuery == emojiCode?.code.query, emojiSuggestions.contains(match), let proxy else { return }
        proxy.userTouchedKeyboard()
        feedback.keyDown()
        if !replaceEmojiCode(match.emoji, closed: false, restoreClosingColon: false) {
            queueEmojiReplacement(match.emoji, closed: false)
        }
    }
}
