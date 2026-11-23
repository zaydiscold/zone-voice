// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// A compact typing strip and collapsed dictation face. The Z opens the dictation styles in the
/// row beside it and stays in place to close them; holding the microphone opens the same row, which
/// is how a keyboard with the Z hidden picks a style. The keyboard key controls the rows (hold it
/// for Open Zone), Recent dictations sits on the right beside the microphone, and active dictation
/// controls never cover typed keys.
struct StatusBarView: View {
    let model: KeyboardModel
    let mic: MicController
    let theme: KeyboardTheme
    let openApp: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosingStyle = false
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
            if mic.mode == .dictate { collapsedPanel } else { typeStrip }
        }
        .onChange(of: mic.state) { _, _ in choosingStyle = false }
        .onChange(of: mic.mode) { _, _ in choosingStyle = false }
    }

    @ViewBuilder
    private var brandKey: some View {
        if !model.preferences.hideHomeButton {
            // The Z opens the styles in this row and stays where it is, lit, so the same tap
            // closes them. It used to open a UIKit menu, which a keyboard can only draw over its
            // own top row: the menu covered the Z (seen on the simulator, November 16), so the
            // button seemed to vanish the moment it was pressed. Open Zone lives on a hold of the
            // keyboard key beside it.
            Button {
                guard mic.state.allowsStyleChoice else { return }
                choosingStyle.toggle()
            } label: {
                // 28 pt wide: the 15 pt Z sits about 13 pt from the glass edge, matching the mic's
                // inset on the right, and the keyboard key follows at the strip's own spacing. At
                // 40 pt the bare Z floated in a gap three times wider than the gaps between keys.
                ZoneHomeMark(theme: theme)
                    .frame(width: 28, height: StripKey.height)
                    .background {
                        if choosingStyle {
                            RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
                                .fill(theme.latchedKey)
                        }
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Text style")
            .accessibilityValue(mic.style.label)
            .accessibilityHint(choosingStyle ? "Closes the styles" : "Shows the styles for the next dictation")
            .accessibilityAddTraits(choosingStyle ? .isSelected : [])
            .accessibilityAction(named: Text("Open Zone"), openApp)
            .accessibilityIdentifier("keyboard.home")
        }
    }

    /// The bare Z is drawn inside its 28 pt slot, so it clears the glass's rounded corner from
    /// the grid's own inset. With it hidden, the keyboard key's full face is the first thing in
    /// the corner and gets the same clearance as the trailing edge.
    private var leadingInset: CGFloat {
        model.preferences.hideHomeButton ? StripKey.cornerClearance : KeyboardRootView.sideInset
    }

    private var typeStrip: some View {
        HStack(spacing: 6) {
            brandKey
            if choosingStyle, mic.state.allowsStyleChoice {
                // The four styles need nearly the whole row, so they take the keyboard key's place
                // too; the Z beside them closes the row, and with the Z hidden a close key does.
                inlineStyles(closable: model.preferences.hideHomeButton)
            } else {
                // Navigation must not disappear when suggestions or Undo arrive.
                modeKey
                if mic.showsSurface || mic.state == .requesting {
                    activeControls
                } else {
                    // Suggestions come and go with every word. Only the middle of the row swaps:
                    // the keys on either side keep their place in the view tree, so they are not
                    // torn down and rebuilt twice per typed word.
                    if showsSuggestions {
                        SuggestionBar(suggestions: model.suggestions, theme: theme) { suggestion in
                            model.choose(suggestion)
                            mic.userTypedKey()
                        }
                        .layoutPriority(-1)
                    } else {
                        leading
                        Spacer(minLength: 2)
                    }
                    // Recent dictations on the right, beside the mic, outside the part of the
                    // row that suggestions swap.
                    if showsRecentKey { recentButton }
                    trailing
                }
            }
        }
        .padding(.leading, leadingInset)
        // The keyboard's glass has rounded top corners; the trailing control needs room to clear it.
        .padding(.trailing, StripKey.cornerClearance)
        .frame(height: KeyboardRootView.stripHeight)
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                brandKey
                modeKey
                topRowExtras
                Spacer(minLength: 0)
                // The corner swaps at once: a crossfade left the corner's key ghosting under the X.
                Group {
                    if pendingContent != nil {
                        pendingActions
                    } else if isCapturing {
                        HStack(spacing: 6) {
                            clockLabel
                            cancelKey
                        }
                    } else {
                        // Above Delete and Return, in the same key-wide column. The style's name
                        // used to sit here; the Z and a hold of the mic open the styles instead.
                        recentButton
                    }
                }
                .transaction { $0.animation = nil }
            }
            // 4 pt above the 36 pt controls (they sit 4 pt down inside their 44 pt touch frames).
            .frame(height: 44, alignment: .top)
            HStack(alignment: .top, spacing: 8) {
                lowerArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 36 pt keys in 41 pt touch frames: the same 6 to 7 pt between X, Delete and Return.
                VStack(spacing: 2) {
                    deleteKey
                    returnKey
                }
            }
            .frame(height: Self.lowerHeight)
        }
        .padding(.leading, leadingInset)
        // The keyboard's glass has rounded top corners; the trailing control needs room to clear it.
        .padding(.trailing, StripKey.cornerClearance)
        .frame(height: KeyboardViewController.dictateHeight, alignment: .top)
    }

    /// The collapsed face below its top row: two 36 pt keys in the right column, and the capture
    /// keys and voice beside them.
    static let lowerHeight: CGFloat = 84
    private static let columnTouch: CGFloat = 41

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
            historyButton(symbol: "arrow.uturn.backward", title: "Undo", label: "Undo dictation") { mic.tapUndo() }
        case .undone:
            historyButton(symbol: "arrow.uturn.forward", title: "Redo", label: "Redo dictation") { mic.tapRedo() }
        default:
            EmptyView()
        }
        if model.preferences.showsPasteKey, !isCapturing, pendingContent == nil {
            // Apple's own paste button: a tap on it is the permission, so iOS does not ask
            // "Allow Paste" the way it does for a direct clipboard read.
            PasteControlKey(theme: theme, session: { [weak model] in model?.currentSession }) { text in
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
        if choosingStyle, mic.state.allowsStyleChoice {
            inlineStyles(closable: true)
        } else if let pending = pendingContent {
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
    /// while recording; at rest the line breathes, and while recognizing it shimmers.
    @ViewBuilder
    private var voiceLine: some View {
        switch mic.state {
        case .error, .needsFullAccess, .inApp:
            leading.frame(maxWidth: .infinity, alignment: .leading)
        default:
            if model.preferences.meterStyle.isDrawn || model.preferences.meterStyle == .scope, !isProcessing {
                // The drawn graphics and Scope: live while recording, held still and dimmed at rest.
                MicArt(mic: mic, theme: theme, style: model.preferences.meterStyle, live: isRecording)
                    .opacity(isRecording ? (mic.isPaused ? 0.4 : 1) : 0.45)
                    .frame(maxWidth: .infinity).frame(height: 48)
            } else if isRecording, model.preferences.meterStyle == .wave {
                MicWave(mic: mic, theme: theme)
                    .frame(maxWidth: .infinity).frame(height: 64)
            } else if isRecording, model.preferences.meterStyle == .bars {
                MicSwell(mic: mic, theme: theme)
                    .opacity(mic.isPaused ? 0.4 : 1)
                    .frame(maxWidth: .infinity).frame(height: 48)
            } else if isRecording {
                MicBars(mic: mic, theme: theme, barCount: 24)
                    .opacity(mic.isPaused ? 0.4 : 1)
                    .frame(maxWidth: .infinity).frame(height: 48)
            } else if isProcessing {
                ShimmerLine(color: theme.accentGraphicUIColor, leftToRight: true)
                    .frame(maxWidth: .infinity).frame(height: 20)
            } else if model.preferences.meterStyle == .wave {
                // At rest the line breathes: the recognizing shimmer, slowed and dimmed.
                ShimmerLine(color: theme.accentGraphicUIColor, leftToRight: true, period: 3.2)
                    .opacity(0.55)
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
            Image(systemName: "delete.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: StripKey.width, height: StripKey.height)
                .frame(height: Self.columnTouch)
                .contentShape(Rectangle())
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
            Image(systemName: "return.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: StripKey.width, height: StripKey.height)
                .frame(height: Self.columnTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel(model.returnLabel == "return" ? "Return" : model.returnLabel.capitalized)
    }

    /// The one ink key, and the only key that changes what it does: the mic at rest, Stop
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
                        ProcessingRing(color: UIColor(theme.onInk), lineWidth: 2)
                            .frame(width: hero ? 22 : 18, height: hero ? 22 : 18)
                    } else {
                        Image(systemName: recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: hero ? 19 : 17, weight: .semibold))
                            .foregroundStyle(recording ? KeyboardTheme.live : theme.onInk)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: width, height: height)
                .frame(height: touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(InkKeyStyle(theme: theme, latched: recording, height: height, onPressChange: micPressChanged))
            .disabled(isProcessing)
            .accessibilityLabel(recording ? "Done" : isProcessing ? (mic.state == .requesting ? "Starting" : "Recognizing") : "Dictate")
            .accessibilityHint(recording ? "Stops listening and adds the words" : mic.state.allowsStyleChoice ? "Hold to choose a style" : "")
            .accessibilityActions {
                if mic.state.allowsStyleChoice {
                    Button("Choose style") { choosingStyle = true }
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
            choosingStyle = true
        }
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
        let height = hero ? StripKey.heroHeight : StripKey.height
        return Button { mic.tapPause() } label: {
            Image(systemName: mic.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: hero ? 17 : 15, weight: .semibold))
                .foregroundStyle(mic.isPaused ? theme.accentInk : theme.text)
                .frame(width: hero ? StripKey.heroWidth : StripKey.width, height: height)
                .frame(height: hero ? StripKey.heroTouch : StripKey.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: mic.isPaused, height: height))
        .accessibilityLabel(mic.isPaused ? "Resume recording" : "Pause recording")
    }

    @ViewBuilder
    private var clockLabel: some View {
        if case .recording(let since) = mic.state {
            Group {
                if mic.isPaused {
                    Text("Paused").font(.subheadline.weight(.medium)).foregroundStyle(theme.accentInk)
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
        case .recording(let since):
            // The same voice graphic as the compact face, given the whole middle of the strip.
            cancelKey
            // Clock, then the wave, with the same 8 pt on both sides of the wave.
            HStack(spacing: 8) {
                Group {
                    if mic.isPaused {
                        Text("Paused").foregroundStyle(theme.accentInk)
                    } else if mic.hearsNothing {
                        Text("Quiet").foregroundStyle(KeyboardTheme.live)
                    } else {
                        ListeningClock(since: since, font: .caption.monospacedDigit().weight(.medium), color: theme.secondaryText)
                    }
                }
                .font(.caption.weight(.medium))
                .fixedSize()
                switch model.preferences.meterStyle {
                case .wave:
                    MicWave(mic: mic, theme: theme)
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
            pauseKey(hero: false)
            inkKey(hero: false)
        case .transcribing, .requesting:
            cancelKey
            Text(mic.state == .requesting ? "Starting" : "Transcribing")
                .font(.subheadline.weight(.medium)).foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
            // The ring spins on the ink key itself, so the slot never empties between Stop and the mic.
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
                .foregroundStyle(primary ? theme.onInk : theme.text)
                .padding(.horizontal, 12).frame(height: 36)
                .background(primary ? theme.ink : theme.key, in: Capsule())
                .frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    /// The styles as a row of keys, the current one filled with ink. A UIKit menu drew over the
    /// strip and the Z with it, and the collapsed face has no room above for one at all. Choosing a
    /// style closes the row; `closable` adds a close key where no Z sits beside the row.
    private func inlineStyles(closable: Bool) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(TextStyle.allCases, id: \.self) { choice in
                        Button {
                            mic.chooseStyle(choice)
                            choosingStyle = false
                        } label: {
                            Text(choice.label)
                                .font(.subheadline.weight(.medium))
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .frame(height: 36)
                                .foregroundStyle(choice == mic.style ? theme.onInk : theme.text)
                                .background(choice == mic.style ? theme.ink : theme.key, in: Capsule())
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(choice.label) style")
                        .accessibilityAddTraits(choice == mic.style ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("keyboard.styles")
            if closable {
                CancelCircleView(theme: theme) { choosingStyle = false }
                    .accessibilityLabel("Close styles")
            }
        }
    }

    /// Suggestions only while typing: never over a dictation in flight, an Undo, or an error.
    private var showsSuggestions: Bool {
        guard (model.preferences.showSuggestions || model.hasSwipeAlternatives), !model.suggestions.isEmpty else { return false }
        switch mic.state {
        case .idle: return true
        default: return false
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch mic.state {
        case .needsFullAccess:
            Button(action: openApp) {
                message("Allow Full Access to dictate", detail: "Settings → Apps → Zone → Keyboards")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Zone, which shows how")
        case .error(let text):
            // The first sentence is the problem, the rest what to do; one line each so neither truncates.
            let parts = Self.splitFirstSentence(text)
            message(parts.title, detail: parts.detail, tone: KeyboardTheme.live)
        case .inApp:
            message("Finish in Zone, then come back", detail: nil)
        case .inserted:
            // The moment text lands: Undo, and any words Zone may have misheard. While one's
            // alternatives are open they take Undo's room too.
            if !hasDoubts {
                historyButton(symbol: "arrow.uturn.backward", title: "Undo", label: "Undo dictation") { mic.tapUndo() }
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
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel("Undo dictation")
    }

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
                .foregroundStyle(mic.history == nil ? theme.text : theme.accentInk)
                .frame(width: StripKey.width, height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: mic.history != nil))
        .accessibilityLabel(mic.history == nil ? "Recent dictations" : "Close recent dictations")
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
        ModeKeyView(mode: mic.mode, theme: theme) { mic.toggleMode() }
            .contextMenu {
                Button(action: openApp) { Label("Open Zone", systemImage: "house") }
            }
            .accessibilityHint("Tap to show or hide the letters. Hold for Open Zone.")
            .accessibilityAction(named: Text("Open Zone"), openApp)
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

/// The keyboard key on both faces. On the type face it shows the rows folding down; on the
/// dictate face it shows a keyboard, the thing a tap brings back. Key fill, key corners, 44 pt
/// wide to match the shift column it sits above.
struct ModeKeyView: View {
    let mode: KeyboardMode
    let theme: KeyboardTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode == .type ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(mode == .dictate ? theme.accentInk : theme.text)
                .frame(width: 45, height: 36)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        // Latched while the keys are folded away: the switchboard key stays pressed in until
        // a second tap releases it.
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: mode == .dictate))
        .accessibilityLabel(mode == .type ? "Hide keys" : "Show keys")
        .accessibilityHint(mode == .type ? "Shrinks the keyboard to the dictation surface" : "Brings the key rows back")
    }
}


/// The strip's X key in the key fill: closes the inline style row. Same key as Cancel.
struct CancelCircleView: View {
    let theme: KeyboardTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: StripKey.width, height: StripKey.height)
                .frame(height: StripKey.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(SwitchKeyStyle(theme: theme, latched: false))
        .accessibilityLabel("Close")
    }
}


/// The running clock while listening.
struct ListeningClock: View {
    let since: Date
    let font: Font
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(since)
            Text(elapsed.clockLabel)
                .font(font.monospacedDigit())
                .foregroundStyle(color)
                .accessibilityLabel("Recording for \(elapsed.clockLabel)")
        }
    }
}

/// One key language for the strip: a rounded key in the key fill casting a hard shadow from
/// where the sun really is (zayd.wtf's sundial shadow, computed once when the keyboard
/// appears). Pressing slides the key into its shadow; a latched key stays pressed in with an
/// inner shadow until released, like a switchboard key. Only real on/off controls latch.
struct SwitchKeyStyle: ButtonStyle {
    let theme: KeyboardTheme
    let latched: Bool
    /// The visible key inside the label's taller touch frame.
    var height: CGFloat = StripKey.height

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StripKeyFace(theme: theme, pressed: configuration.isPressed, latched: latched, height: height))
            .sensoryFeedback(trigger: latched) { _, isLatched in isLatched ? .impact(flexibility: .rigid, intensity: 0.7) : .impact(flexibility: .soft, intensity: 0.5) }
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

/// The raised key itself, for buttons and for keys that track their own press (Delete repeats
/// while held): the key fill, the latch edge, and the sun shadow it slides into when pressed.
struct StripKeyFace: ViewModifier {
    let theme: KeyboardTheme
    let pressed: Bool
    let latched: Bool
    var height: CGFloat = StripKey.height
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let sun = KeyboardSun.current
        let down = pressed || latched
        let depth = pressed ? 1.0 : (latched ? 0.6 : 0)
        let shape = RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(latched ? theme.latchedKey : theme.key)
                    .frame(height: height)
                    .overlay {
                        if latched {
                            shape.strokeBorder(Color.black.opacity(theme.isDark ? 0.45 : 0.16), lineWidth: 1)
                                .frame(height: height)
                        }
                    }
                    .shadow(color: .black.opacity(down ? 0 : sun.alpha * (theme.isDark ? 0.6 : 0.25)), radius: 0,
                            x: sun.dx, y: sun.dy)
            }
            .offset(x: reduceMotion ? 0 : sun.dx * depth, y: reduceMotion ? 0 : sun.dy * depth)
            .animation(reduceMotion ? nil : (pressed ? .spring(duration: 0.16, bounce: 0)
                                             : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)),
                       value: pressed)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: latched)
    }
}

/// The sun or moon shadow for strip keys, read once per keyboard appearance: no location, no
/// timer. Strip keys sit a few points apart, so they keep a shorter shadow than the app's cards.
enum KeyboardSun {
    static var current = cast()
    static func refresh() { current = cast() }
    private static func cast() -> SunShadow { SunShadow.at(minLength: 1, maxLength: 2.5) }
}

extension View {
    /// The raised-key shadow alone, for shapes that are not buttons (the style key's fill).
    func sunCast(theme: KeyboardTheme) -> some View {
        let sun = KeyboardSun.current
        return shadow(color: .black.opacity(sun.alpha * (theme.isDark ? 0.6 : 0.25)), radius: 0, x: sun.dx, y: sun.dy)
    }
}

/// The strip's one key size. Every control on the typing strip, the collapsed face's top row
/// and its right column (X, Delete, Return) is 36 pt tall. The collapsed face's capture keys,
/// the mic or Stop and Pause, are 56 pt squares centered beside that column. No control is a
/// circle: everything shares the key rows' 8 pt corners.
enum StripKey {
    static let height: CGFloat = 36
    static let touch: CGFloat = 44
    static let heroHeight: CGFloat = 56
    static let heroTouch: CGFloat = 64
    /// Icon keys: the keyboard key, Recent dictations, Pause, Cancel, the mic.
    static let width: CGFloat = 44
    /// The collapsed face's mic, Stop and Pause.
    static let heroWidth: CGFloat = 56
    /// Room a key face needs to clear the keyboard glass's rounded top corner.
    static let cornerClearance: CGFloat = 12
}

/// The ink key: the same raised key as `SwitchKeyStyle`, filled with ink. It latches while a
/// recording is on (pressed into its shadow with an inner edge), so the mic key reads as a
/// switch that was thrown and the Stop glyph on it says what the next tap does.
struct InkKeyStyle: ButtonStyle {
    let theme: KeyboardTheme
    let latched: Bool
    let height: CGFloat
    /// Press and release, for the mic's hold (the styles).
    var onPressChange: ((Bool) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let sun = KeyboardSun.current
        let down = configuration.isPressed || latched
        let depth = configuration.isPressed ? 1.0 : (latched ? 0.6 : 0)
        let shape = RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
        configuration.label
            .background {
                shape
                    .fill(theme.ink)
                    .frame(height: height)
                    .overlay {
                        if latched {
                            shape.strokeBorder(theme.onInk.opacity(0.35), lineWidth: 1.5)
                                .frame(height: height)
                        }
                    }
                    .shadow(color: .black.opacity(down ? 0 : sun.alpha * (theme.isDark ? 0.6 : 0.25)), radius: 0,
                            x: sun.dx, y: sun.dy)
            }
            .offset(x: reduceMotion ? 0 : sun.dx * depth, y: reduceMotion ? 0 : sun.dy * depth)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : (configuration.isPressed ? .spring(duration: 0.16, bounce: 0)
                                             : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)),
                       value: configuration.isPressed)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: latched)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange?(pressed) }
    }
}

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// The only views that read the 20 Hz level stream. The strip around them (wordmark, keys,
/// style menu, suggestions) no longer rebuilds on every level tick.
struct MicWave: View {
    let mic: MicController
    let theme: KeyboardTheme
    var body: some View {
        FlowingWave(levels: mic.isPaused ? [] : mic.levels, color: theme.accentGraphicUIColor,
                    ink: theme.accentInkUIColor)
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
                 ink: UIColor(theme.text), accent: theme.accentGraphicUIColor)
            .accessibilityHidden(true)
    }
}

struct MicSwell: View {
    let mic: MicController
    let theme: KeyboardTheme
    var live = true
    var body: some View {
        // Only the sampled signal, like `MicBars`: paused or at rest every bar is a stub.
        SignalLevelMeter(levels: live && !mic.isPaused ? mic.levels : [], color: theme.accentGraphicUIColor,
                         shape: .swell)
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
        SignalLevelMeter(levels: live && !mic.isPaused ? Array(mic.levels.suffix(barCount)) : [], barCount: barCount,
                         color: theme.accentGraphicUIColor)
            .accessibilityHidden(true)
    }
}
