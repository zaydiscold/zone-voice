// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

/// Lets the system play the standard key click for this input view.
final class ClickableInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
    var foldChanged: ((CGRect?) -> Void)?

    override func updateConstraints() {
        #if ZONE_DUO_REGIONS
        if #available(iOS 27.1, *) {
            foldChanged?(reservedRegions(kind: .division).first?.frame)
        }
        #endif
        super.updateConstraints()
    }
}

final class KeyboardViewController: UIInputViewController {
    private let store = UserDefaultsSharedStore()
    private var keyboardVisibleForSettings = false
    private var model: KeyboardModel?
    private var mic: MicController?
    private var clipboard: ClipboardController?
    private var hosting: UIHostingController<KeyboardRootView>?
    private var keyGrid: KeyGridView?
    private var emojiPanel: EmojiPanelView?
    private var heightConstraint: NSLayoutConstraint?
    /// Where everything the keyboard draws sits: the full width, or the one-handed column.
    private let column = UILayoutGuide()
    private var contentLeading: NSLayoutConstraint?
    private var emojiLeading: NSLayoutConstraint?
    private var columnBottom: NSLayoutConstraint?
    private var division: CGRect?
    private let splitButton = UIButton(type: .system)

    private var prefersSplit = DuoKeyboard.prefersSplit
    private var duo: DuoKeyboard = .ordinary
    private var windowInset: CGFloat = 0
    // The size-injected host uses the shipping controller without substituting its views.
    var displayGeometry: (UIView) -> (isDuo: Bool, size: CGSize, origin: CGFloat) = { input in
        guard let screen = input.window?.screen else { return (false, .zero, 0) }
        return (DuoKeyboard.isCurrentDevice, screen.bounds.size, input.convert(input.bounds, to: screen.coordinateSpace).minX)
    }

    private var columnLeading: NSLayoutConstraint?
    private var columnTrailing: NSLayoutConstraint?
    /// The column's place last laid out, so a change can cross-fade once instead of every pass.
    private var shownColumn: (x: CGFloat, width: CGFloat)?
    private var shownColumnInput: CGFloat = 0
    private let oneHandedPanel = OneHandedPanel()
    private var observations: [DarwinObservation] = []
    private var lexiconRequestGeneration = 0

    /// Type face: 40 pt strip + four rows with their spacing and padding. Rows shrink on narrow
    /// hosts (compact phones, split layouts) so the keyboard never exceeds what the system expects.
    /// Dictate face: the compact surface, about a quarter of the screen with the system's own row.
    private func keyboardHeight(for width: CGFloat) -> CGFloat {
        if mic?.displayMode == .dictate { return Self.dictateHeight }
        // Exactly the strip plus the key rows (KeyGridMetrics: three pitches and one key, then
        // the bottom inset) and a 4 pt breath under the strip. The old formula left 7 pt of
        // slack that collected above the first row.
        let metrics = duo.metrics(width: width, windowInset: windowInset)
        return KeyboardRootView.stripHeight + 4 + 3 * metrics.rowPitch + metrics.keyHeight + metrics.bottomInset
    }

    /// The collapsed face: the 44 pt top row and the 84 pt area below it
    /// (`StatusBarView.lowerHeight`); the system globe dock is additional.
    static let dictateHeight: CGFloat = 44 + StatusBarView.lowerHeight

    /// True inside `viewWillAppear`, while the stored face is restored: that change must not
    /// animate. See `setHeight(_:)`.
    private var isAppearing = false

    /// The toggle changed the face: move the height constraint on the input view and let the
    /// system animate the host's content inset with it.
    private func animateHeightChange() {
        guard let input = inputView else { return }
        let width = inputView?.bounds.width ?? view.bounds.width
        let target = keyboardHeight(for: width)
        KeyboardLog.mic.info("mode \(String(describing: self.mic?.mode), privacy: .public): height \(target, privacy: .public)")
        setHeight(target)
        input.setNeedsLayout()
        view.setNeedsLayout()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, delay: 0, options: [.curveEaseInOut]) {
            input.superview?.layoutIfNeeded()
            input.layoutIfNeeded()
        }
    }

    // The system reads `hasDictationKey` before the view loads; set later, the dock keeps its mic.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        updateDictationKey()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateDictationKey()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let input = ClickableInputView(frame: .zero, inputViewStyle: .keyboard)
        input.allowsSelfSizing = true
        inputView = input
        input.addLayoutGuide(column)
        let leading = column.leadingAnchor.constraint(equalTo: input.leadingAnchor)
        let trailing = column.trailingAnchor.constraint(equalTo: input.trailingAnchor)
        let top = column.topAnchor.constraint(equalTo: input.topAnchor)
        let bottom = column.bottomAnchor.constraint(equalTo: input.bottomAnchor)
        columnBottom = bottom
        input.foldChanged = { [weak self, weak input] frame in
            guard self?.division != frame else { return }
            self?.division = frame
            input?.setNeedsLayout()
        }
        NSLayoutConstraint.activate([
            leading, trailing,
            top, bottom,
        ])
        columnLeading = leading
        columnTrailing = trailing

        let model = KeyboardModel(proxy: self)
        let mic = MicController(store: store, proxy: self, feedback: model.feedback)
        self.model = model
        self.mic = mic
        mic.dictationOpening = { [weak model] in model?.dictationOpening ?? .automatic }
        mic.onTypingStripOwnershipChanged = { [weak model] owns in model?.setDictationOwnsStrip(owns) }
        mic.onDictationInserted = { [weak model] text in model?.dictationInserted(text) }
        mic.onDictationRemoved = { [weak model] in model?.dictationRemoved() }
        mic.captureHost = { [weak self] in self?.view }
        model.onWordCorrected = { [weak mic] original, replacement in
            mic?.wordCorrectedByHand(original: original, replacement: replacement)
        }
        #if DEBUG && targetEnvironment(simulator)
        mic.lockShift = { [weak model] in model?.lockShift() }
        #endif
        mic.onModeChanged = { [weak self] _ in
            // Stop held Delete before the outgoing key grid begins its opacity transition.
            self?.model?.endDeleteRepeat()
            // Restoring the stored face on appearance is not a toggle: viewWillAppear sets that
            // height once, without animation.
            guard self?.isAppearing == false else { return }
            self?.animateHeightChange()
        }

        // Clipboard history (off unless the app's switch is on): the preferences and the field are
        // read when a look happens, never kept.
        let clipboard = ClipboardController(
            source: SystemClipboard(), history: ClipboardHistory.shared, seen: SharedClipboardSeenStore(),
            settings: { [weak model] in
                let preferences = model?.preferences ?? KeyboardPreferences()
                return .init(enabled: preferences.clipboardHistoryEnabled, skipsSecrets: preferences.clipboardSkipsSecrets, automatic: preferences.clipboardAutomatic)
            },
            field: { [weak self] in self?.gate.traits.clipboardField ?? .secret },
            hasOpenAccess: { [weak self] in self?.hasOpenAccess ?? false })
        self.clipboard = clipboard
        gate.onClipboardFieldChange = { [weak clipboard] in clipboard?.check() }
        model.pasteSaving = clipboard.saving

        let root = KeyboardRootView(model: model, mic: mic, clipboard: clipboard)
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        // iOS 27 gives the keyboard's input view a top safe-area inset (about 17 pt, measured
        // against Apple's keyboard on a device) that SwiftUI pads by default, pushing the
        // strip down on both faces. The layout here already accounts for every point.
        hosting.safeAreaRegions = []
        addChild(hosting)
        input.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        let contentLeading = hosting.view.leadingAnchor.constraint(equalTo: column.leadingAnchor)
        self.contentLeading = contentLeading
        NSLayoutConstraint.activate([
            contentLeading,
            hosting.view.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: column.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        self.hosting = hosting

        // The typing keys sit over the SwiftUI root, below the strip, so a touch on a key never
        // walks the hosting view's hit testing.
        let grid = KeyGridView(model: model, mic: mic, controller: self)
        input.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            grid.topAnchor.constraint(equalTo: column.topAnchor, constant: KeyboardRootView.stripHeight),
            grid.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        keyGrid = grid

        // The emoji panel takes the same place as the keys when the emoji key opens it.
        let emoji = EmojiPanelView(model: model, mic: mic, controller: self)
        input.addSubview(emoji)
        emoji.translatesAutoresizingMaskIntoConstraints = false
        let emojiLeading = emoji.leadingAnchor.constraint(equalTo: column.leadingAnchor)
        self.emojiLeading = emojiLeading
        NSLayoutConstraint.activate([
            emojiLeading,
            emoji.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            emoji.topAnchor.constraint(equalTo: column.topAnchor, constant: KeyboardRootView.stripHeight),
            emoji.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        emojiPanel = emoji

        splitButton.addTarget(self, action: #selector(toggleSplit), for: .touchUpInside)
        splitButton.isHidden = true
        splitButton.accessibilityIdentifier = "keyboard.duo.split"
        input.addSubview(splitButton)

        // The one-handed side panel sits under the keys, so the keys' edge margin
        // (`KeyGridView.edgeSlop`) wins a touch the two share.
        oneHandedPanel.isHidden = true
        oneHandedPanel.onChoose = { [weak model] hand in model?.chooseHand(hand) }
        input.insertSubview(oneHandedPanel, belowSubview: grid)
        observeHand()

        // The host can flip light and dark while the keyboard stays up; re-read the traits then.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _) in
            // Before the document is live, going live re-reads both.
            guard controller.gate.isLive else { return }
            controller.model?.setSystemDark(controller.systemStyleIsDark)
            controller.model?.refreshTraits()
        }
        // The stored face's height before the system first measures the input view.
        setHeight(keyboardHeight(for: input.bounds.width))

        observations = [
            DarwinNotifier.observe(.statusChanged) { [weak self] in self?.mic?.handleStatusChanged() },
            DarwinNotifier.observe(.quickSettingsPublished) { [weak self] in
                self?.refreshPendingSettings()
            },
            DarwinNotifier.observe(.resultReady) { [weak self] in self?.mic?.handleResultReady() },
            DarwinNotifier.observe(.sessionChanged) { [weak self] in self?.mic?.handleSessionChanged() },
        ]
    }

    /// With Full Access the strip's mic dictates, so the system's own dictation mic in the dock
    /// is hidden: two mics side by side sent new users to Apple's. Without Full Access ours cannot
    /// record, and Apple's stays as the way to dictate. The system reads the flag before the view
    /// loads, when `hasFullAccess` still reads false, so init uses the value seen last time and each
    /// appearance refreshes it once on screen (a change in Settings shows from the next appearance).
    private static let fullAccessSeenKey = "zone.keyboard.fullAccessSeen"

    private func updateDictationKey() {
        hasDictationKey = UserDefaults.standard.bool(forKey: Self.fullAccessSeenKey)
    }

    /// Called once the keyboard is on screen: before that `hasFullAccess` can still read false.
    /// The personal words are read by the caller right after, so this does not read them too.
    private func rememberFullAccess() {
        let granted = hasFullAccess
        KeyboardLog.mic.info("full access at appear: \(granted, privacy: .public)")
        if UserDefaults.standard.bool(forKey: Self.fullAccessSeenKey) != granted {
            UserDefaults.standard.set(granted, forKey: Self.fullAccessSeenKey)
        }
        hasDictationKey = granted
        model?.refreshFullAccess(reloadVocabulary: false)
    }

    // MARK: When the text proxy may be read

    /// When the host's document may be read, the trait snapshot and the dropped-input log. See
    /// `TextProxyGate` for the crash it guards against and the rules.
    private lazy var gate: TextProxyGate = {
        let gate = TextProxyGate(
            readTraits: { [weak self] in
                guard let self else { return FieldTraits() }
                return FieldTraits(reading: self.textDocumentProxy, needsGlobeKey: self.needsInputModeSwitchKey)
            },
            readSession: { [weak self] in
                guard let self else { return nil }
                return ZoneTextProxyIdentity.documentIdentifier(of: self.textDocumentProxy)?.uuidString
            })
        gate.viewState = { [weak self] in
            guard let view = self?.viewIfLoaded else { return (false, true) }
            return (view.window != nil, view.isHidden)
        }
        // The host's input session for this appearance exists: read everything the appearance
        // skipped, once.
        gate.onLive = { [weak self] _ in
            guard let self else { return }
            self.model?.setSystemDark(self.systemStyleIsDark)
            self.model?.refreshTraits()
            self.mic?.keyboardDidAppear()
            // Offer a new copy inside Recent when clipboard history is on.
            self.clipboard?.keyboardBecameLive()
            // Once per appearance: how close this process runs to its limit.
            KeyboardMemory.logAppearance()
        }
        return gate
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) {
            try? KeyboardCapture.finishAudioErase(in: group, temporary: FileManager.default.temporaryDirectory) {
                LocalDictationHost.shared.cancel()
            }
        }
        Task.detached(priority: .utility) { SharedMiniModel.sweepRecordings() }
        keyboardVisibleForSettings = true
        refreshPendingSettings()
        gate.willAppear()
        // Before any work of its own: the app needs the head start, not the keyboard.
        DarwinNotifier.post(.keyboardShown)
        KeyboardSun.refresh()
        // A reappearing controller keeps its strip, which must draw the new accent too.
        if KeyboardTheme.refreshAccent() { model?.accentDidChange() }
        // The app's switches change while the keyboard is away, so they are read on every appearance
        // and again in `viewDidAppear`. Neither reads the text proxy; host traits wait for the
        // document to go live.
        model?.refreshFullAccess(reloadVocabulary: false)
        model?.apply(readPreferences(at: "willAppear"))
        refreshSystemLexicon()
        // The stored face first, then one height for this appearance. This used to set the old
        // face's height and then animate to the stored one inside the system's own slide-in, so the
        // host saw two heights for one appearance. On iOS 27 the glass above the strip also varied
        // between appearances (18 pt in one device screenshot, 1 pt in the next); this removes
        // the one cause of that inside the keyboard.
        isAppearing = true
        mic?.restoreStoredMode()
        isAppearing = false
        let width = inputView?.bounds.width ?? view.bounds.width
        setHeight(keyboardHeight(for: width))
    }

    /// Refresh on every appearance, including when Contacts changed while this controller lived.
    private func refreshSystemLexicon() {
        lexiconRequestGeneration += 1
        let generation = lexiconRequestGeneration
        requestSupplementaryLexicon { [weak self] lexicon in
            let entries = lexicon.entries.map { (input: $0.userInput, text: $0.documentText) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.lexiconRequestGeneration == generation else { return }
                    self.model?.applySystemLexicon(entries)
                }
            }
        }
    }

    /// The one place the input view's height is set.
    private func setHeight(_ target: CGFloat) {
        guard let input = inputView else { return }
        if let heightConstraint {
            if heightConstraint.constant != target { heightConstraint.constant = target }
        } else {
            let constraint = input.heightAnchor.constraint(equalToConstant: target)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The system's edge gestures on the keyboard window hold touches back before delivery
        // (seen in the phone profile as sendDelayedTouches). Keys must get them at once.
        for recognizer in view.window?.gestureRecognizers ?? [] {
            recognizer.delaysTouchesBegan = false
        }
        rememberFullAccess()
        // Read the app's switches again now that the keyboard is on screen. A fresh keyboard
        // process can read before the system has settled its access (as with `hasFullAccess`), and
        // the first appearance after a relaunch then kept the defaults: swipe, Paste and
        // suggestions off while the app showed them on, until the next appearance (2026-11-08).
        let preferences = readPreferences(at: "didAppear")
        if preferences != model?.preferences {
            model?.apply(preferences)
        } else {
            // `apply` reads the personal words; without it, read them again here, because the
            // read started in `viewWillAppear` can have found the container out of reach and a
            // fresh keyboard then autocorrected the person's own names for the whole appearance.
            model?.refreshPersonalWordProtection()
        }
        // The accent has the same early-read window as the switches. Neither reads the proxy.
        if KeyboardTheme.refreshAccent() { model?.accentDidChange() }
        // Not live here: the 2026-11-08 crash read the proxy inside this call, while the host's
        // document state was still being replaced. Live on the host's first callback, a touch,
        // or `TextProxyGate.didAppearFallback` later, whichever comes first.
        gate.didAppear { [weak self] in
            // Going live can run the mic's checks before Full Access reads true (a host callback
            // often arrives before `viewDidAppear`). Give the mic the settled answer.
            self?.mic?.accessSettled()
            self?.clipboard?.keyboardBecameLive()
            self?.handOffSystemFieldIfNeeded()
        }
    }

    private func refreshPendingSettings() {
        guard keyboardVisibleForSettings, let mic else { return }
        Task { [weak self] in
            await mic.preferenceReader.refresh()
            guard let self, self.keyboardVisibleForSettings, let model = self.model else { return }
            let preferences = mic.readPreferences()
            if model.preferences != preferences { model.apply(preferences) }
            self.clipboard?.refreshSettings()
        }
    }

    /// The app's switches from the shared store, or the last ones read when it gave nothing back.
    private func readPreferences(at moment: String) -> KeyboardPreferences {
        let preferences = KeyboardSettingReader.shared.current()
        KeyboardLog.typing.info("preferences at \(moment, privacy: .public): swipe \(preferences.swipeTypingEnabled, privacy: .public), paste \(preferences.showsPasteKey, privacy: .public), suggestions \(preferences.showSuggestions, privacy: .public)")
        return preferences
    }

    // UIKit sends these once it has applied the host's document state, so each one proves the
    // proxy is live. The first of them in an appearance often comes before `viewDidAppear`.

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        gate.hostCallback(.textWillChange)
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        gate.hostCallback(.selectionWillChange)
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        // Going live re-reads everything this callback would.
        let becameLive = gate.hostCallback(.selectionDidChange)
        guard gate.isLive, !becameLive else { return }
        model?.hostSelectionDidChange()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        let becameLive = gate.hostCallback(.textDidChange)
        guard gate.isLive else { return }
        if becameLive { handOffSystemFieldIfNeeded(); return }
        KeyTrace.measure("textDidChange") {
            model?.hostTextDidChange()
            mic?.hostTextChanged()
            handOffSystemFieldIfNeeded()
        }
    }

    /// Email and verification code fields go to the next keyboard in the user's list (normally
    /// the system one), as Wispr Flow does for email: addresses want the system's @ and . keys and
    /// its autofill, and a code from Messages is only ever offered there. Each field is handed off
    /// once, so switching back to Zone in that field sticks. Kept per process, because switching back
    /// creates a new controller.
    private static var handedOffSessions: Set<String> = []

    private func handOffSystemFieldIfNeeded() {
        guard gate.isLive, gate.traits.handsOffToSystemKeyboard else { return }
        let session = currentInputSession() ?? "unknown"
        guard !Self.handedOffSessions.contains(session) else { return }
        Self.handedOffSessions.insert(session)
        KeyboardLog.typing.info("\(self.gate.traits.isCodeField ? "code" : "email", privacy: .public) field: handing off to the next keyboard")
        advanceToNextInputMode()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyboardVisibleForSettings = false
        // The field is going away: from here reads answer from the last live ones (`TextProxyGate`).
        gate.willDisappear()
        model?.keyboardWillDisappear()
        mic?.keyboardWillDisappear()
        clipboard?.keyboardWillDisappear()
        TouchAdaptationStore.save()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        gate.didDisappear()
        if #available(iOS 26, *) { ZoneModelSpeech.shared.keyboardDidDisappear() }
    }

    /// The host makes a new controller for nearly every appearance, and UIKit keeps each old
    /// controller's input view alive after the controller is gone (an association inside UIKit
    /// holds it). That view held the whole keyboard: model, key grid, SwiftUI graph, emoji panel.
    /// With the model's own cycle (`KeyboardRootView`'s open-URL closure), every appearance's
    /// keyboard stayed alive: on the iOS 26.2 simulator the footprint grew 0.8 to 1.6 MB per
    /// appearance, the climb the phone's jetsam reports showed. Emptying the input view leaves
    /// UIKit an empty view to keep.
    deinit {
        // `inputView` would load the view of a controller that never appeared.
        guard isViewLoaded, let input = inputView else { return }
        let release = { input.subviews.forEach { $0.removeFromSuperview() } }
        if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        KeyboardMemory.handleWarning(emojiPanelOpen: model?.showsEmoji == true)
    }

    // MARK: One-handed column

    /// Re-arms after every change, as Observation reports once per registration.
    private func observeHand() {
        guard let model else { return }
        withObservationTracking {
            _ = model.hand
            _ = model.preferences.oneHandedWidth
            _ = model.explicitDark
            _ = model.systemDark
            _ = model.appearanceVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeHand()
                self.layoutColumn(animated: true)
            }
        }
    }

    #if ZONE_DUO_SNAPSHOT
    func setSnapshotStyle(_ style: UIUserInterfaceStyle, split: Bool) {
        overrideUserInterfaceStyle = style
        model?.setSystemDark(style == .dark)
        prefersSplit = split
        model?.refreshFullAccess(reloadVocabulary: false)
        model?.apply(KeyboardPreferences(showsPasteKey: true))
    }
    #endif

    @objc private func toggleSplit() {
        prefersSplit.toggle()
        DuoKeyboard.prefersSplit = prefersSplit
        layoutColumn(animated: false)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutColumn(animated: false)
    }

    /// Narrows everything the keyboard draws toward one thumb, or gives it the full width back,
    /// and puts the side panel in the space left over. Runs on every layout pass (rotation, a new
    /// width) and when the hand or the width setting changes; it touches the views only when the
    /// column moved.
    private func layoutColumn(animated: Bool) {
        guard let input = inputView, let model, let keyGrid else { return }
        let width = input.bounds.width
        guard width > 0 else { return }
        let (isDuo, size, origin) = displayGeometry(input)
        duo = DuoKeyboard(isDuo: isDuo, screen: size)
        windowInset = max(0, origin)
        let fold = division.flatMap { $0.intersects(input.bounds) ? $0 : nil }
        let across = fold.flatMap { $0.width > $0.height ? $0 : nil }
        // Tabletop normally has the entire input view below the fold. If a host
        // spans a horizontal division, reserve space from that division down
        // and ask for the normal key height above it. Keep the caps bottom-aligned.
        let reservedBottom = across.map { max(0, input.bounds.maxY - $0.minY) } ?? 0
        columnBottom?.constant = -reservedBottom
        let metrics = duo.metrics(width: width, windowInset: windowInset)
        let safe = duo == .ordinary ? UIEdgeInsets.zero : input.safeAreaInsets
        let position = DuoKeyPlacement(pose: duo, width: width, center: size.width / 2 - origin,
                                      side: metrics.sideInset, safeLeft: safe.left, safeRight: safe.right,
                                      division: across == nil ? fold : nil, prefersSplit: prefersSplit)
        let available = width - position.leading - position.trailing
        let target = duo.allowsOneHand ? OneHandedLayout.column(width: available, fraction: model.preferences.oneHandedWidth, hand: model.hand) : nil
        let gridChanged = keyGrid.duo != duo || keyGrid.windowInset != windowInset || keyGrid.splitKeys != position.split
        keyGrid.duo = duo
        keyGrid.windowInset = windowInset
        keyGrid.splitKeys = position.split
        setHeight(keyboardHeight(for: width) + reservedBottom)
        // All panels use one uninterrupted thumb area. Keep the same SwiftUI tree
        // across folds so an open picker, dictation or history selection survives.
        let rightColumn = position.split ? available / 2 + max(20, (fold?.width ?? 0) / 2) : 0
        let toggleWidth: CGFloat = 74
        contentLeading?.constant = position.offersSplit && !position.split ? metrics.sideInset + toggleWidth : rightColumn
        emojiLeading?.constant = rightColumn
        splitButton.frame = CGRect(x: position.leading + metrics.sideInset, y: 0,
                                   width: toggleWidth, height: KeyboardRootView.stripHeight)
        let title = position.split ? "Full" : "Split"
        let theme = KeyboardTheme(isDark: model.explicitDark ?? model.systemDark)
        let label = NSAttributedString(string: title, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: theme.isDark ? theme.accentToneUIColor : UIColor(theme.text),
            .underlineStyle: theme.isDark ? 0 : NSUnderlineStyle.single.rawValue,
            .underlineColor: theme.accentToneUIColor
        ])
        if splitButton.currentAttributedTitle != label { splitButton.setAttributedTitle(label, for: .normal) }
        splitButton.accessibilityLabel = position.split ? "Full keyboard" : "Split keyboard"
        splitButton.isHidden = !position.offersSplit || position.forced
        let lead = position.leading + (target?.x ?? 0)
        let trail = width - lead - (target?.width ?? available)
        if gridChanged { keyGrid.sync() }
        let isDark = model.explicitDark ?? model.systemDark
        if let side = model.hand.side {
            oneHandedPanel.configure(side: side.other, isDark: isDark)
        }
        let moved = target?.x != shownColumn?.x || target?.width != shownColumn?.width || width != shownColumnInput || columnLeading?.constant != lead || columnTrailing?.constant != -trail
        guard moved else { return }
        let wasOneHanded = shownColumn != nil
        shownColumn = target
        shownColumnInput = width
        let apply = {
            let x = target?.x ?? 0
            self.columnLeading?.constant = lead
            self.columnTrailing?.constant = -trail
            keyGrid.edgeSlop = target == nil ? (0, 0) : x > 0 ? (Self.panelEdgeSlop, 0) : (0, Self.panelEdgeSlop)
            self.placePanel()
            self.oneHandedPanel.isHidden = target == nil
            input.layoutIfNeeded()
        }
        KeyboardLog.typing.info("one-handed column: \(target.map { "x \($0.x) width \($0.width)" } ?? "full", privacy: .public) of \(width, privacy: .public)")
        // A quick cross-fade, not a slide: the keys are laid out again at their new size, so
        // animating the frame would stretch them. Only a change the person made animates.
        if animated, view.window != nil, wasOneHanded || target != nil {
            UIView.transition(with: input, duration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.2,
                              options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    /// Points of the side panel next to the keys that still type the edge key: a hurried tap at "q"
    /// or "p" can land just past it, and on the full keyboard the screen edge stops it. 10 pt keeps
    /// that a letter and leaves the panel's buttons at least 26 pt of their own (36 pt minimum panel).
    static let panelEdgeSlop: CGFloat = 10

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        placePanel()
    }

    /// The panel fills the keyboard's height beside the column, whatever the face's height is now.
    private func placePanel() {
        guard let input = inputView, let shownColumn else { return }
        let width = input.bounds.width
        let x = shownColumn.x > 0 ? 0 : shownColumn.width
        let frame = CGRect(x: x, y: 0, width: width - shownColumn.width, height: input.bounds.height)
        if oneHandedPanel.frame != frame { oneHandedPanel.frame = frame }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        setHeight(keyboardHeight(for: size.width))
    }
}

// MARK: - TextProxyActions

extension KeyboardViewController: TextProxyActions {
    /// A touch reaches the keys only once the keyboard is on screen and interactive, by which time
    /// the host's document state is in place: the earliest proof in an appearance where the user
    /// types before the document went live.
    func userTouchedKeyboard() {
        gate.touched()
    }

    func insert(_ text: String) {
        guard gate.canWrite(.insert) else { return }
        textDocumentProxy.insertText(text)
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        guard gate.canWrite(.adjustTextPosition) else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    func deleteBackward() {
        guard gate.canWrite(.deleteBackward) else { return }
        textDocumentProxy.deleteBackward()
    }

    // Context is never cached: an old field's text must not be taken for this one's. Nil is what a
    // host reports when it does not say, which every caller already handles.

    func contextBefore() -> String? {
        guard gate.isLive else { return nil }
        KeyTrace.countContextRead()
        return textDocumentProxy.documentContextBeforeInput
    }

    func selectedText() -> String? {
        guard gate.isLive else { return nil }
        return textDocumentProxy.selectedText
    }

    func contextAfter() -> String? {
        guard gate.isLive else { return nil }
        KeyTrace.countContextRead()
        return textDocumentProxy.documentContextAfterInput
    }

    /// True while not live, the answer that changes nothing: an empty field would force a capital.
    func fieldHasText() -> Bool {
        guard gate.isLive else { return true }
        KeyTrace.countContextRead()
        return textDocumentProxy.hasText
    }

    // The field's traits answer from one snapshot per field (`TextProxyGate`), read again when
    // the model refreshes traits for a host change or the document identifier changes.

    func reloadFieldTraits() { gate.reloadTraitsIfStale() }
    var allowsAutocorrection: Bool { gate.traits.allowsAutocorrection }
    var allowsEmojiShortcodes: Bool { gate.traits.allowsEmojiShortcodes }
    var allowsSwipeTyping: Bool { gate.traits.allowsSwipeTyping }
    var allowsSmartQuotes: Bool { gate.traits.allowsSmartQuotes }
    var allowsSmartDashes: Bool { gate.traits.allowsSmartDashes }
    var returnKeyLabel: String { gate.traits.returnKeyLabel }
    var prefersNumbers: Bool { gate.traits.prefersNumbers }
    var fieldKeys: [String] { gate.traits.fieldKeys }
    var capitalization: FieldCapitalization { gate.traits.capitalization }
    var isSearchField: Bool { gate.traits.isSearchField }
    var dimsReturnWhenEmpty: Bool { gate.traits.dimsReturnWhenEmpty }
    var autocapitalizesSentences: Bool { gate.traits.autocapitalizesSentences }
    var fieldNeverCapitalizes: Bool { gate.traits.fieldNeverCapitalizes }
    var explicitDarkAppearance: Bool? { gate.traits.explicitDarkAppearance }
    /// `needsInputModeSwitchKey` reads the same document state as the proxy, so it is part of
    /// the snapshot.
    var needsGlobeKey: Bool { gate.traits.needsGlobeKey }

    /// The last live session while not live, so an appearance is not mistaken for a new field
    /// before the real answer arrives (going live reads it and reconciles).
    func currentInputSession() -> String? { gate.session() }

    /// The system style, nil while the trait is still unspecified.
    var systemStyleIsDark: Bool? {
        switch traitCollection.userInterfaceStyle {
        case .dark: return true
        case .light: return false
        default: return nil
        }
    }

    /// On a device this is the real Full Access switch. The Simulator neither enforces Full
    /// Access nor reliably lets automation flip the switch. Debug walkthroughs can exercise
    /// the declined path before the keyboard appears.
    var hasOpenAccess: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return !UserDefaults.standard.bool(forKey: "ZoneSimulateNoFullAccess")
        #elseif targetEnvironment(simulator)
        return true
        #else
        return hasFullAccess
        #endif
    }

    func playClick() {
        UIDevice.current.playInputClick()
    }

    func open(_ url: URL) {
        guard let context = extensionContext else {
            model?.openURLFallback?(url)
            return
        }
        context.open(url) { [weak self] opened in
            // The phone's journal has taps after which Zone never launched, or launched seconds
            // late; this says whether iOS accepted the open at all.
            KeyboardLog.journal?.log("keyboardOpenedApp", recording: ZoneContract.requestID(from: url),
                                     ["opened": String(opened)])
            guard !opened else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // Zone already has this tap (it is recording it): a second open would only
                // bring Zone to the front again once the person is back in their app.
                if ZoneContract.Destination(url: url) != nil, self.mic?.state.allowsPanel != true { return }
                let id = ZoneContract.requestID(from: url)
                guard ColdStart.secondOpenStillNeeded(status: self.store.status, requestID: id) else {
                    KeyboardLog.journal?.log("keyboardOpenSkipped", recording: id, ["reason": "alreadyRecording"])
                    return
                }
                self.model?.openURLFallback?(url)
            }
        }
    }
}
