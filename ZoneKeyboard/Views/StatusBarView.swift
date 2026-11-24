// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct StatusBarView: View {
    let model: KeyboardModel
    let mic: MicController
    let theme: KeyboardTheme
    let historyTitle: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingDiscard = false
    /// Waits out a press on the microphone; past `micHoldDelay` it opens the styles instead.
    @State private var micHold: Task<Void, Never>?
    /// The press in progress already opened the styles, so its release must not start a dictation.
    @State private var micHoldOpenedStyles = false

    /// As long as the system keyboard's hold for accents: long enough that a slow tap still
    /// dictates, short enough that holding for the styles does not feel like waiting.
    static let micHoldDelay: Duration = .milliseconds(450)

    var body: some View {
        Group {
            if mic.displayMode == .dictate { collapsedPanel } else { typeStrip.dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
        }
    }

    @ViewBuilder
    private var brandKey: some View {
        if !model.preferences.hideHomeButton {
            Button {
                if mic.panelSection != nil { mic.panelSection = nil } else { openPanel(.home) }
            } label: {
                ZoneHomeMark(theme: theme)
                    .frame(width: StripKey.height, height: StripKey.height)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SwitchKeyStyle(theme: theme, latched: mic.panelSection != nil, faceWidth: StripKey.height))
            .padding(.horizontal, -4)
            .disabled(!mic.state.allowsPanel)
            .accessibilityLabel("Zone menu")
            .accessibilityHint(mic.panelSection == nil ? "Shows the Zone menu" : "Closes the Zone menu")
            .accessibilityAddTraits(mic.panelSection == nil ? [] : .isSelected)
            .accessibilityIdentifier("keyboard.home")
        }
    }

    /// The first thing in the corner is a full key face, the Z or (with it hidden) the keyboard
    /// key, so it gets the same clearance from the glass's rounded corner as the trailing edge.
    private var leadingInset: CGFloat { StripKey.cornerClearance }

    private var holdHint: String? {
        model.movingCursor ? "Slide to move cursor" : SpaceTalk.spaceLabel(mic.spaceTalkPhase)
    }

    private var typeStrip: some View {
        let content = model.stripContent(hasUnsureWords: hasDoubts, allowsWordSuggestions: mic.state == .idle)
        return HStack(spacing: 6) {
            if let holdHint, mic.state == .idle {
                brandKey
                Text(holdHint).font(.footnote).lineLimit(1).frame(maxWidth: .infinity)
                modeKey
            } else if content == .dictation {
                if mic.showsSurface || mic.state == .requesting {
                    activeControls
                } else {
                    brandKey
                    leading
                    Spacer(minLength: 2)
                    trailing
                }
            } else {
                brandKey
                if model.preferences.hideHomeButton, mic.panelSection != nil {
                    Button { mic.panelSection = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
                    .accessibilityLabel("Close Zone menu")
                }
                modeKey
                if mic.state == .idle, model.pasteAccessHint != nil {
                    Text(KeyboardModel.pasteAccessMessage)
                        .font(.footnote)
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity)
                } else {
                    switch content {
                    case .emojiPicker:
                        EmojiSuggestionBar(model: model, theme: theme) { mic.userTypedKey() }
                            .layoutPriority(-1)
                    case .typingSuggestions, .nextWords:
                        SuggestionBar(suggestions: model.suggestions, theme: theme) { suggestion in
                            model.choose(suggestion)
                            mic.userTypedKey()
                        }
                        .layoutPriority(-1)
                    case .unsureWord, .controls, .dictation:
                        leading
                        Spacer(minLength: 2)
                    }
                }
                if showsRecentKey || content == .emojiPicker { recentButton }
                trailing
            }
        }
        .padding(.leading, leadingInset)
        // The keyboard's glass has rounded top corners; the trailing control needs room to clear it.
        .padding(.trailing, StripKey.cornerClearance)
        .frame(height: StripKey.typingStripHeight)
        // Suggestions swap at once, as on the system keyboard: a crossfade at each word's first
        // letter and at each space kept the row animating through a typing burst.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mic.state)
    }


    private var isInserted: Bool {
        switch mic.state { case .inserted, .undone: return true; default: return false }
    }

    /// Exactly 44 + 84 points; the system owns the globe dock below. The way it was before the
    /// center layout: one big voice line through the middle, the capture keys on the left.
    /// Top row: the Z, the keyboard key, then Undo or Paste; on the right the clock and the one
    /// contextual corner (Recent dictations at rest, Cancel from the moment a recording starts
    /// until the words land, Dismiss and Insert when they need a decision).
    /// Below: the mic at the left edge, which turns into Stop in place with Pause beside it, and
    /// the voice drawn left to right. Under the corner, Delete over Return, so X, Delete and
    /// Return stack in one key-wide column on the right edge.
    private var collapsedPanel: some View {
        FoldedKeyboardFace {
            brandKey
            if pendingContent != nil || !isCapturing { modeKey }
            topRowExtras
            Spacer(minLength: 0)
            // The corner swaps at once: a crossfade left the corner's key ghosting under the X.
            Group {
                if pendingContent != nil {
                    pendingActions
                } else if isCapturing {
                    HStack(spacing: 6) {
                        clockLabel
                        modeKey
                        cancelKey
                    }
                } else {
                    // Above Delete and Return, in the same key-wide column. The style's name
                    // used to sit here; the Z and a hold of the mic open the styles instead.
                    recentButton
                }
            }
            .transaction { $0.animation = nil }
        } lower: {
            lowerArea
        } column: {
            deleteKey
            returnKey
        }
    }

    /// The collapsed face below its top row: two 36 pt keys in the right column, and the capture
    /// keys and voice beside them.
    static let lowerHeight = StripKey.foldedLowerHeight

    private var isProcessing: Bool { mic.state == .transcribing || mic.state == .requesting }

    private var isCapturing: Bool {
        switch mic.state {
        case .recording, .transcribing, .requesting: return true
        default: return false
        }
    }

    private var isRecording: Bool {
        if case .recording = mic.state { return true }
        return false
    }

    /// Undo or Redo right after an insert, and Paste when it is on in Settings.
    @ViewBuilder
    private var topRowExtras: some View {
        switch mic.state {
        case .inserted:
            historyButton(symbol: "arrow.uturn.backward", title: "Undo", label: undoLabel) { mic.tapUndo() }
        case .undone:
            historyButton(symbol: "arrow.uturn.forward", title: "Redo", label: "Redo dictation") { mic.tapRedo() }
        default:
            EmptyView()
        }
        if model.preferences.showsPasteKey, !isCapturing, pendingContent == nil {
            // Apple's own paste button: a tap on it is the permission, so iOS does not ask
            // "Allow Paste" the way it does for a direct clipboard read.
            PasteControlKey(theme: theme, session: { [weak model] in model?.currentSession }, saving: model.pasteSaving) { text in
                model.insertPasted(text)
                mic.userTypedKey()
            }
            .id(theme.isDark)
            .frame(width: StripKey.width, height: StripKey.height)
            .frame(height: StripKey.touch)
        }
    }

    /// Left of the right column: the style picker, a dictation waiting for a decision, a message,
    /// or the capture keys with the voice.
    @ViewBuilder
    private var lowerArea: some View {
        if let pending = pendingContent {
            VStack(alignment: .leading, spacing: 3) {
                Text(pending.result.text).font(.subheadline).foregroundStyle(theme.text).lineLimit(3)
                Text(pending.caption).font(.caption2).foregroundStyle(theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pending.result.text). \(pending.caption)")
        } else {
            HStack(spacing: 8) {
                // Stop takes the mic's place; Pause sits right beside it while recording.
                HStack(spacing: 6) {
                    inkKey(hero: true)
                    if isRecording { pauseKey(hero: true) }
                }
                // After an insert with unsure words, they sit where the voice was drawn.
                if hasDoubts { DoubtRow(mic: mic, theme: theme) } else { voiceLine }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// One voice line, left to right from the capture keys. Wave and Bars show the live voice
    /// while recording. Wave stays mounted so both lips can close when recording ends.
    @ViewBuilder
    private var voiceLine: some View {
        switch mic.state {
        case _ where mic.pressMessage != nil:
            Text(mic.pressMessage ?? "").font(.footnote).foregroundStyle(theme.text)
        case .error, .needsFullAccess, .inApp:
            leading.frame(maxWidth: .infinity, alignment: .leading)
        default:
            if model.preferences.meterStyle == .wave {
                MicWave(mic: mic, theme: theme, live: isRecording)
                    .opacity(mic.isPaused ? 0.4 : (isRecording || isProcessing ? 1 : 0.45))
                    .frame(maxWidth: .infinity).frame(height: 64)
            } else if isRecording {
                FoldedMicGraphic(mic: mic, theme: theme, style: model.preferences.meterStyle)
            } else if model.preferences.meterStyle.isDrawn || model.preferences.meterStyle == .scope, !isProcessing {
                // The drawn graphics and Scope: live while recording, held still and dimmed at rest.
                MicArt(mic: mic, theme: theme, style: model.preferences.meterStyle, live: false)
                    .opacity(0.45)
                    .frame(maxWidth: .infinity).frame(height: 48)
            } else if isProcessing {
                ShimmerLine(color: theme.accentToneUIColor, leftToRight: true)
                    .frame(maxWidth: .infinity).frame(height: 20)
            } else if model.preferences.meterStyle == .bars {
                // At rest the row lies as stubs, dimmed like the other resting graphics.
                MicSwell(mic: mic, theme: theme, live: false)
                    .opacity(0.45)
                    .frame(maxWidth: .infinity).frame(height: 40)
            } else {
                MicBars(mic: mic, theme: theme, barCount: 24, live: false)
                    .opacity(0.45)
                    .frame(maxWidth: .infinity).frame(height: 40)
            }
        }
    }

    /// Delete without the key rows. Held, it repeats like the key row's Delete: characters, then
    /// whole words. The press itself deletes (a long-press gesture never saw touches in the
    /// keyboard's hosting view; Buttons do), so the action only serves VoiceOver.
    private var deleteKey: some View {
        Button {
            guard UIAccessibility.isVoiceOverRunning else { return }
            model.keyDown(.delete)
            model.endDeleteRepeat()
        } label: {
            FoldedColumnLabel(symbol: "delete.left", theme: theme)
        }
        .buttonStyle(RepeatKeyStyle(theme: theme) { pressed in
            // The key row's Delete: the first deletion on touch-down, repeats until release.
            if pressed {
                model.keyDown(.delete)
            } else {
                model.endDeleteRepeat()
                mic.userTypedKey()
            }
        })
        .accessibilityLabel("Delete")
    }

    /// Return without the key rows: submits or breaks the line in the host, like the return key.
    private var returnKey: some View {
        Button {
            model.handleTap(.newline)
            mic.userTypedKey()
        } label: {
            FoldedColumnLabel(symbol: "return.left", theme: theme)
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel(model.returnLabel == "return" ? "Return" : model.returnLabel.capitalized)
    }

    /// The primary key, and the only key that changes what it does: the mic at rest, Stop
    /// while recording, a ring while Zone starts or recognizes. Same shape, size and place in
    /// every state, so the key that starts a dictation is the key that ends it, like a switch
    /// thrown and thrown back, and the rest of the strip never has to move around it.
    /// `hero` is the collapsed face's larger bottom-row size.
    @ViewBuilder
    private func inkKey(hero: Bool) -> some View {
        if case .needsFullAccess = mic.state {
            EmptyView()
        } else {
            let recording: Bool = { if case .recording = mic.state { return true }; return false }()
            let width = hero ? StripKey.heroWidth : StripKey.width
            let height = hero ? StripKey.heroHeight : StripKey.height
            let touch = hero ? StripKey.heroTouch : StripKey.touch
            Button {
                micTapped(recording: recording)
            } label: {
                ZStack {
                    if isProcessing {
                        ProcessingRing(color: UIColor(theme.controlInk), lineWidth: 2)
                            .frame(width: hero ? 22 : 18, height: hero ? 22 : 18)
                    } else {
                        CaptureKeySymbol(recording: recording, hero: hero, theme: theme)
                    }
                }
                .frame(width: width, height: height)
                .frame(height: touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(AccentKeyStyle(theme: theme, latched: recording, height: height, onPressChange: micPressChanged))
            .accessibilityLabel(recording ? "Stop" : isProcessing ? (mic.state == .requesting ? RecordingRefusal.starting : RecordingRefusal.writing) : "Dictate")
            .accessibilityHint(recording ? "Stops listening and adds the words" : mic.state.allowsStyleChoice ? "Hold to choose a style" : "")
            .accessibilityActions {
                if mic.state.allowsStyleChoice {
                    Button("Choose style") { openPanel(.styles) }
                }
            }
        }
    }

    /// A press on the mic that is still down after `micHoldDelay` opens the styles, with a
    /// firmer tap than a key's, and its release then does nothing. A long-press gesture never saw
    /// touches in the keyboard's hosting view (see Delete), so this reads the button's own pressed
    /// state, which does.
    private func micPressChanged(_ pressed: Bool) {
        micHold?.cancel()
        micHold = nil
        guard pressed else { return }
        micHoldOpenedStyles = false
        guard mic.state.allowsStyleChoice else { return }
        micHold = Task { @MainActor in
            try? await Task.sleep(for: Self.micHoldDelay)
            guard !Task.isCancelled, mic.state.allowsStyleChoice else { return }
            micHoldOpenedStyles = true
            model.feedback.impact(.medium)
            openPanel(.styles)
        }
    }

    private func openPanel(_ section: MicController.PanelSection) {
        model.dismissEmojiPickerForStyles()
        if model.showsEmoji { model.closeEmoji() }
        mic.showPanel(section)
    }

    /// The mic's tap: dictate, unless this press was a hold that opened the styles.
    private func micTapped(recording: Bool) {
        if micHoldOpenedStyles {
            micHoldOpenedStyles = false
            return
        }
        if recording { mic.tapStop() } else { mic.tapMic() }
    }

    /// Pause, always joined to Stop's left, the same key size as its neighbors. Latched while
    /// paused, with the glyph turned into Play.
    private func pauseKey(hero: Bool) -> some View {
        PauseKey(theme: theme, hero: hero, isPaused: mic.isPaused) { mic.tapPause() }
    }

    @ViewBuilder
    private var clockLabel: some View {
        if case .recording(let since) = mic.state {
            Group {
                if mic.isPaused {
                    Text("Paused").font(.subheadline.weight(.medium)).keyboardAccentBadge(theme)
                } else if let seconds = mic.quietFinishIn {
                    QuietFinishCountdown(seconds: seconds, font: .subheadline.weight(.medium), color: theme.controlInk).keyboardAccentBadge(theme)
                } else if mic.hearsNothing {
                    Text("Quiet").font(.subheadline.weight(.medium)).foregroundStyle(KeyboardTheme.live)
                } else {
                    ListeningClock(since: since, font: .subheadline.monospacedDigit(), color: theme.text)
                }
            }
            .padding(.trailing, 4)
        }
    }

    /// Cancel throws the words away, so every recording asks for a second tap: the first turns
    /// the key into "Discard?" for three seconds. A short recording is no less painful to lose.
    private var cancelKey: some View {
        Button {
            if case .recording = mic.state, !confirmingDiscard {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.2)) { confirmingDiscard = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { confirmingDiscard = false }
                }
            } else {
                confirmingDiscard = false
                mic.tapCancel()
            }
        } label: {
            Group {
                if confirmingDiscard {
                    // One line at its full width on every phone; the wave beside it gives up the room.
                    Text("Discard?").font(.subheadline.weight(.semibold)).foregroundStyle(KeyboardTheme.live)
                        .lineLimit(1)
                        .fixedSize()
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .padding(.horizontal, 10)
                } else {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 44)
                }
            }
            .frame(height: 36)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .layoutPriority(1)
        .accessibilityLabel(confirmingDiscard ? "Tap again to discard the recording" : "Cancel dictation")
        .onChange(of: mic.state) { _, _ in confirmingDiscard = false }
    }

    private var pendingContent: (result: DictationResult, caption: String)? {
        switch mic.state {
        case .pendingInsert(let result, let reason): return (result, reason)
        case .recovery(let result): return (result, "This may already be in your text")
        default: return nil
        }
    }

    private var pendingActions: some View {
        HStack(spacing: 6) {
            actionButton("Dismiss", primary: false) { mic.tapDismissPending() }
            actionButton("Insert", primary: true) { mic.tapInsert() }
                .accessibilityLabel("Insert dictation")
                .accessibilityHint("Adds the text at the cursor. Nothing is sent.")
        }
    }

    /// Recording/processing stays in this strip. Key rows remain live below it.
    @ViewBuilder
    private var activeControls: some View {
        switch mic.state {
        case .transcribing where model.preferences.meterStyle != .wave,
             .requesting where model.preferences.meterStyle != .wave:
            cancelKey
            modeKey
            Text(holdHint ?? mic.pressMessage ?? (mic.state == .requesting ? "Starting" : "Transcribing"))
                .font(.subheadline.weight(.medium)).foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
            inkKey(hero: false)
        case .recording, .transcribing, .requesting:
            // The same voice graphic as the compact face, given the whole middle of the strip.
            cancelKey
            modeKey
            // Clock, then the wave, with the same 8 pt on both sides of the wave.
            HStack(spacing: 8) {
                Group {
                    if let holdHint {
                        Text(holdHint).foregroundStyle(theme.secondaryText)
                    } else if !isRecording {
                        Text(mic.pressMessage ?? (mic.state == .requesting ? "Starting" : "Transcribing")).foregroundStyle(theme.secondaryText)
                    } else if mic.isPaused {
                        Text("Paused").keyboardAccentBadge(theme)
                    } else if let seconds = mic.quietFinishIn {
                        QuietFinishCountdown(seconds: seconds, font: .caption.weight(.medium), color: theme.controlInk).keyboardAccentBadge(theme)
                    } else if mic.hearsNothing {
                        Text("Quiet").foregroundStyle(KeyboardTheme.live)
                    } else if case .recording(let since) = mic.state {
                        ListeningClock(since: since, font: .caption.monospacedDigit().weight(.medium), color: theme.secondaryText)
                    }
                }
                .font(.caption.weight(.medium))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                switch model.preferences.meterStyle {
                case .wave:
                    MicWave(mic: mic, theme: theme, live: isRecording)
                case .bars:
                    MicSwell(mic: mic, theme: theme)
                        .opacity(mic.isPaused ? 0.4 : 1)
                case .mirrored:
                    MicBars(mic: mic, theme: theme, barCount: 18)
                        .opacity(mic.isPaused ? 0.4 : 1)
                case .scope, .ink, .glyphs, .branch, .inkblot, .lanes, .stars:
                    MicArt(mic: mic, theme: theme, style: model.preferences.meterStyle)
                        .opacity(mic.isPaused ? 0.4 : 1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            // The strip spaces its controls 6 pt apart; 2 more here makes the wave's right side
            // match the 8 pt between the clock and the wave.
            .padding(.trailing, 2)
            .accessibilityElement(children: .combine)
            // Pause joined to Stop at the trailing end, where the mic was: the same key, thrown.
            if isRecording { pauseKey(hero: false) }
            inkKey(hero: false)
        case .pendingInsert(let result, let reason):
            pendingControls(result, caption: reason)
        case .recovery(let result):
            pendingControls(result, caption: "This may already be in your text")
        default:
            EmptyView()
        }
    }

    private func pendingControls(_ result: DictationResult, caption: String) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.text).font(.caption).foregroundStyle(theme.text).lineLimit(1)
                Text(caption).font(.caption2).foregroundStyle(theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.text). \(caption)")
            actionButton("Dismiss", primary: false) { mic.tapDismissPending() }
            actionButton("Insert", primary: true) { mic.tapInsert() }
                .accessibilityLabel("Insert dictation")
                .accessibilityHint("Adds the text at the cursor. Nothing is sent.")
        }
    }

    private func actionButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .foregroundStyle(primary ? theme.controlInk : theme.text)
                .padding(.horizontal, 12)
                .frame(height: StripKey.touch).contentShape(Rectangle())
        }
        .buttonStyle(StripTextKeyStyle(theme: theme, ink: primary))
    }

    @ViewBuilder
    private var leading: some View {
        switch mic.state {
        case .needsFullAccess:
            Button(action: { mic.openDestination(.home) }) {
                message("Allow Full Access to dictate", detail: "Settings > Apps > Zone > Keyboards > Allow Full Access")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Zone, which shows how")
        case .error(let text):
            // The first sentence is the problem, the rest what to do; one line each so neither truncates.
            let parts = Self.splitFirstSentence(Self.errorText(text))
            message(parts.title, detail: parts.detail, tone: KeyboardTheme.live)
        case .inApp:
            HStack {
                ProgressView().controlSize(.small)
                message("Waiting for Zone", detail: "Open Zone to finish, then come back.")
            }
        case .inserted:
            // The moment text lands: Undo, and any words Zone may have misheard. While one's
            // alternatives are open they take Undo's room too.
            if !hasDoubts {
                historyButton(symbol: "arrow.uturn.backward", title: "Undo", label: undoLabel) { mic.tapUndo() }
            } else {
                if mic.doubtReview == nil { undoIcon }
                DoubtRow(mic: mic, theme: theme).layoutPriority(-1)
            }
        case .undone:
            historyButton(symbol: "arrow.uturn.forward", title: "Redo", label: "Redo dictation") { mic.tapRedo() }
        default:
            Color.clear.frame(width: 1)
        }
    }

    /// Recent dictations sits beside the mic at rest and after an insert or undo, and stays there
    /// while suggestions show: it is the rescue for a dictation that never landed, and after one
    /// the next-word row used to fill the strip and hide it exactly when it was needed (Teams,
    /// 2026-11-19). It steps aside only for unsure words and for a message that needs the width.
    private var showsRecentKey: Bool {
        guard !hasDoubts else { return false }
        switch mic.state {
        case .idle, .inserted, .undone: return true
        default: return false
        }
    }

    /// Undo as its arrow alone, so three unsure words fit beside it.
    private var undoIcon: some View {
        Button { mic.tapUndo() } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false, faceWidth: StripKey.height))
        .padding(.horizontal, -4)
        .accessibilityLabel(undoLabel)
    }

    /// Right after a style rewrite, Undo puts the earlier wording back.
    private var undoLabel: String { mic.undoRevertsRestyle ? "Undo style change" : "Undo dictation" }

    /// Unsure words from the insert on screen (Beta), or one of them open.
    private var hasDoubts: Bool {
        guard case .inserted = mic.state else { return false }
        return !mic.doubts.isEmpty || mic.doubtReview != nil
    }

    /// Opens or closes the recent-dictations panel.
    private var recentButton: some View {
        Button {
            if mic.history == nil {
                // History is deliberately expanded; ordinary dictation stays a tiny strip.
                if mic.mode == .dictate { mic.toggleMode() }
                mic.showHistory()
            } else { mic.hideHistory() }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(mic.history == nil ? theme.text : theme.accentStroke)
                .frame(width: StripKey.width, height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: mic.history != nil))
        .accessibilityLabel(mic.history == nil ? historyTitle : "Close " + historyTitle.lowercased())
        .accessibilityIdentifier("keyboard.recent")
    }

    static func splitFirstSentence(_ text: String) -> (title: String, detail: String?) {
        guard let range = text.range(of: ". ") else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    /// The keyboard key: folds the rows away into the dictate face. Drawn as a key, in the key
    /// fill, on the shift column, so it reads as part of the keyboard rather than as a logo.
    @ViewBuilder
    private var modeKey: some View {
        let key = ModeKeyView(mode: mic.mode, theme: theme) { mic.toggleMode() }
        if isCapturing || pendingContent != nil {
            key
        } else {
            key.contextMenu {
                Button { mic.openDestination(.home) } label: { Label("Open Zone", systemImage: "house") }
            }
            .accessibilityHint("Tap to show or hide the letters. Hold for Open Zone.")
            .accessibilityAction(named: Text("Open Zone")) { mic.openDestination(.home) }
        }
    }

    /// The recording controller also uses some of these strings to recognize its state.
    /// Give the strip its own instructions without changing those transitions.
    private static func errorText(_ text: String) -> String {
        switch text {
        case "Dictation failed.": "Zone could not finish dictation. Tap the mic to try again."
        case "Nothing to scratch.": "There is no previous dictation here to remove."
        case "Edited, so kept.": "You edited the last dictation. Zone left your changes in place."
        case "Text changed, so the fix is off.": "The words at the cursor changed. Select the word again to correct it."
        case "Can't reach the Zone app yet. Close this app and reopen it.": "The keyboard could not reach Zone. Unlock your iPhone, open Zone, then return here."
        default: text
        }
    }

    private func message(_ title: String, detail: String?, tone: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(tone ?? theme.text)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(theme.secondaryText)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        switch mic.state {
        case .needsFullAccess:
            EmptyView()
        case .idle, .error, .inserted, .undone, .inApp:
            inkKey(hero: false)
        case .requesting, .recording, .transcribing, .pendingInsert, .recovery:
            // Requesting, recording and recognizing draw their own row (`activeControls`).
            EmptyView()
        }
    }

    /// Undo or Redo as a word, not a bare arrow: an arrow next to the keyboard key read as decoration.
    private func historyButton(symbol: String, title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The same key on both faces: the collapsed face's top row has the room for the word.
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .foregroundStyle(theme.text)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel(label)
    }
}

/// The only views that read the 20 Hz level stream. The strip around them (wordmark, keys,
/// style menu, suggestions) no longer rebuilds on every level tick.
struct MicWave: View {
    let mic: MicController
    let theme: KeyboardTheme
    let live: Bool
    var body: some View {
        FlowingWave(levels: mic.levels, color: theme.otherAccentToneUIColor, edgeColor: theme.accentToneUIColor, live: live && mic.isVisible && !mic.isPaused)
            .opacity(mic.isPaused ? 0.4 : 1)
            .accessibilityHidden(true)
    }
}

/// The Bars voice graphic (`VoiceBars`): thin solid bars across the row, tallest in the middle.
struct MicArt: View {
    let mic: MicController
    let theme: KeyboardTheme
    let style: MeterStyle
    var live = true
    var body: some View {
        VoiceArt(style: style, level: live && !mic.isPaused ? (mic.levels.last ?? 0) : 0, live: live && !mic.isPaused,
                 ink: UIColor(theme.text), accent: theme.accentToneUIColor, isDark: theme.isDark)
            .accessibilityHidden(true)
    }
}

struct MicSwell: View {
    let mic: MicController
    let theme: KeyboardTheme
    var live = true
    var body: some View {
        // Only the sampled signal, like `MicBars`: paused or at rest every bar is a stub.
        FlowingWave(levels: mic.levels, color: theme.otherAccentToneUIColor, edgeColor: theme.accentToneUIColor, style: .bars, live: live && !mic.isPaused)
            .accessibilityHidden(true)
    }
}

struct MicBars: View {
    let mic: MicController
    let theme: KeyboardTheme
    let barCount: Int
    var live = true
    var body: some View {
        // Only the sampled signal: no independent timer or synthetic motion at silence.
        // Graphic tone: the pale accents vanished against a light keyboard.
        FlowingWave(levels: Array(mic.levels.suffix(barCount)), color: theme.otherAccentToneUIColor, edgeColor: theme.accentToneUIColor,
                    style: .mirrored, live: live && !mic.isPaused)
            .accessibilityHidden(true)
    }
}

private struct FoldedMicGraphic: View {
    let mic: MicController
    let theme: KeyboardTheme
    let style: MeterStyle

    var body: some View {
        FoldedVoiceGraphic(style: style, levels: mic.isPaused ? [] : mic.levels,
                           live: !mic.isPaused, theme: theme)
            .opacity(mic.isPaused ? 0.4 : 1)
    }
}

/// Finish when quiet counting down in place of the clock: the same words as the app's
/// "Quiet. Finishing in 3…", so a short wait never ends a keyboard dictation without warning.
struct QuietFinishCountdown: View {
    let seconds: Int
    let font: Font
    let color: Color

    var body: some View {
        Text("Finishing in \(seconds)")
            .font(font.monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: seconds)
            .accessibilityLabel("Quiet. Finishing in \(seconds) seconds")
    }
}

/// A strip key that acts on press and release rather than on tap: Delete, which repeats while held.
struct RepeatKeyStyle: ButtonStyle {
    let theme: KeyboardTheme
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StripKeyFace(theme: theme, pressed: configuration.isPressed, latched: false))
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

/// A worded strip key (a style, Insert, Dismiss): the same raised key and sun shadow as the
/// icon keys, filled with ink when it is the chosen or primary one. Flat capsules here looked
/// like a stock iOS control beside the keys around them.
struct StripTextKeyStyle: ButtonStyle {
    let theme: KeyboardTheme
    let ink: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if ink {
            AccentKeyStyle(theme: theme, latched: false, height: StripKey.height).makeBody(configuration: configuration)
        } else {
            SwitchKeyStyle(theme: theme, latched: false).makeBody(configuration: configuration)
        }
    }
}
