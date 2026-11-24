// by zayd/cold @ zayd.wtf

import UIKit
import Observation
import ZoneCore

/// The visible keyboard checks for an available copy and saves its contents after an
/// explicit paste or when automatic capture is enabled.
@MainActor @Observable final class ClipboardController {
    enum Panel: Equatable {
        case needsFullAccess
        case loading
        case timedOut
        /// The shared container is out of reach.
        case unreachable
        case loaded([ClipboardEntry])
    }

    enum Tab: String { case dictations, clipboard }

    /// How many copies the panel lists.
    nonisolated static let panelLimit = 40
    static let pollSeconds: TimeInterval = 1

    private(set) var panel: Panel?
    /// A native Paste tap can save the current copy from the Recent panel.
    private(set) var hasUnsavedCopy = false
    private var lastSelectedTab: Tab
    var tab: Tab {
        get { isEnabled ? lastSelectedTab : .dictations }
        set {
            lastSelectedTab = newValue
            defaults.set(newValue.rawValue, forKey: Self.tabKey)
        }
    }

    typealias PanelRead = (ClipboardHistory, @escaping @MainActor ([ClipboardEntry]) -> Void) -> Void
    @ObservationIgnored private let readPanel: PanelRead
    @ObservationIgnored private let history: ClipboardHistory?
    @ObservationIgnored private let capture: ClipboardCapture?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: () -> ClipboardCapture.Settings
    @ObservationIgnored private let field: () -> ClipboardField
    @ObservationIgnored private let hasOpenAccess: () -> Bool
    @ObservationIgnored private var panelGeneration = 0
    @ObservationIgnored private var panelTimer: Task<Void, Never>?
    var panelWait: Duration = .seconds(5)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var boardObserver: NSObjectProtocol?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var watchedSettings: ClipboardCapture.Settings?
    private static let tabKey = "zone.keyboard.historyTab"

    init(source: ClipboardSource, history: ClipboardHistory?, seen: ClipboardSeenStore?,
         readPanel: @escaping PanelRead = ClipboardController.readRecent,
         defaults: UserDefaults = .standard,
         settings: @escaping () -> ClipboardCapture.Settings,
         field: @escaping () -> ClipboardField,
         hasOpenAccess: @escaping () -> Bool) {
        self.readPanel = readPanel
        self.history = history
        self.defaults = defaults
        self.settings = settings
        self.field = field
        self.hasOpenAccess = hasOpenAccess
        lastSelectedTab = Tab(rawValue: defaults.string(forKey: Self.tabKey) ?? "") ?? .dictations
        if let history, let seen {
            capture = ClipboardCapture(source: source, history: history, seen: seen)
        } else {
            capture = nil
        }
    }

    deinit {
        if let boardObserver { NotificationCenter.default.removeObserver(boardObserver) }
    }

    /// Whether the panel shows the Clipboard tab at all.
    var isEnabled: Bool { settings().enabled }

    var historyTitle: String { isEnabled ? "History" : "Recent dictations" }

    var panelAnnouncement: String {
        guard isEnabled else { return historyTitle }
        return tab == .clipboard ? "History, Clipboard" : "History, Dictations"
    }

    // MARK: Capture

    /// The host's document is live for this appearance: look once now, then once a second.
    func keyboardBecameLive() {
        visible = true
        refreshSettings()
    }

    /// The app can publish new preferences while this keyboard stays on screen.
    func refreshSettings() {
        guard visible else { return }
        let current = settings()
        guard current.enabled, hasOpenAccess(), capture != nil else {
            watchedSettings = nil
            if let boardObserver { NotificationCenter.default.removeObserver(boardObserver) }
            boardObserver = nil
            capture?.cancelFieldCheck()
            capture?.cancelAutomaticRead()
            if hasUnsavedCopy { hasUnsavedCopy = false }
            timer?.invalidate()
            timer = nil
            return
        }
        guard current != watchedSettings || timer == nil else { return }
        watchedSettings = current
        if boardObserver == nil {
            boardObserver = NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.visible == true { self?.check() } }
            }
        }
        check()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] timer in
            // On the main run loop. A controller let go without a disappearance ends its timer here.
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.check()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One last look on the way out, then no more. If the keyboard is leaving a password, code or
    /// card field, the shared guard stays active until the worker has marked the boundary
    /// count. The look uses availability flags and the last field traits without reading text.
    func keyboardWillDisappear() {
        visible = false
        watchedSettings = nil
        if let boardObserver { NotificationCenter.default.removeObserver(boardObserver) }
        boardObserver = nil
        capture?.cancelAutomaticRead()
        check(leaving: true)
        timer?.invalidate()
        timer = nil
    }

    /// One look at the clipboard. Does nothing without Full Access: iOS gives the keyboard no
    /// clipboard then.
    func check(leaving: Bool = false) {
        guard let capture else { return }
        let current = settings()
        guard hasOpenAccess(), current.enabled else {
            capture.cancelFieldCheck()
            capture.cancelAutomaticRead()
            if hasUnsavedCopy { hasUnsavedCopy = false }
            return
        }
        capture.check(current, field: field(), leaving: leaving) { [weak self] outcome in
            guard let self else { return }
            self.settle(outcome)
            if outcome == .waitingForTap, visible, !leaving, current.automatic {
                self.capture?.captureAutomatically(route: .keyboard, eligibility: { [weak self] in
                    guard let self, self.visible, self.hasOpenAccess(), (self.field() == .ordinary || !self.settings().skipsSecrets) else { return nil }
                    return self.settings()
                }, done: { [weak self] in self?.settle($0) })
            }
        }
    }

    /// A paste button was tapped: the token binds this paste to the board's change now. Nil
    /// (nothing will be kept) without Full Access, with history off or out of reach. Reads the
    /// change count only.
    func pasteTapped() -> ClipboardPasteToken? {
        guard let capture, hasOpenAccess(), settings().enabled else { return nil }
        return capture.notePasteTap()
    }

    /// Text that came through Zone's Paste key or the panel's paste button. iOS asked nothing:
    /// the tap on its own button was the permission. `token` is the one `pasteTapped()` gave
    /// this paste's tap; without one, the tap and the text are taken to arrive together.
    func pasted(_ text: String, types: [String] = [], token: ClipboardPasteToken? = nil) {
        guard let capture, hasOpenAccess() else { return }
        let token = token ?? capture.notePasteTap()
        let outcome = capture.keepPasted(text, settings: settings(), field: field(), types: types, token: token)
        settle(outcome)
        guard panel != nil else { return }
        switch outcome {
        case .changedSinceLook: pasteNotice = "The clipboard changed. Tap Paste again."
        case .failed: pasteNotice = "Zone could not save this copy. Unlock your iPhone and try again."
        case .skipped(.own), .alreadySaved: pasteNotice = "Already in Zone."
        case .skipped(.tooLong): pasteNotice = "This copy is too long to save."
        case .skipped(.empty), .notText: pasteNotice = "There is no text to save."
        case .skipped, .heldBack: pasteNotice = "Your clipboard settings skipped this copy."
        case .saved: pasteNotice = "Saved."
        default: break
        }
    }

    /// What a paste control hands clipboard history.
    var pasteNotice: String?
    func thumbnailURL(_ entry: ClipboardEntry) -> URL? { history?.imageURL(entry.id, thumbnail: true) }
    func copyImage(_ entry: ClipboardEntry) {
        pasteNotice = history?.copyImage(entry) == true ? "Touch and hold in the app, then tap Paste." : "Open Zone and check that this image is still in History."
    }

    var saving: PasteSaving {
        PasteSaving(tap: { [weak self] in self?.pasteTapped() },
                    image: { [weak self] image, types, token in
                        guard let self else { return }
                        pasteNotice = "To insert the image, touch and hold in the app, then tap Paste."
                        guard let token, let capture, hasOpenAccess() else { return }
                        guard let image else {
                            pasteNotice = "Zone could not save this image. Use Paste in the app to insert the original."
                            return
                        }
                        let outcome = capture.keepPasted("", image: image, settings: settings(), field: field(), types: types, token: token)
                        settle(outcome)
                        switch outcome {
                        case .saved, .alreadySaved:
                            if panel != nil { pasteNotice = nil }
                        case .failed: pasteNotice = "Image could not be saved. Check available storage."
                        case .changedSinceLook: pasteNotice = "The clipboard changed. Tap Paste again."
                        case .skipped(.own): pasteNotice = "This image is already in Zone."
                        case .skipped, .heldBack: pasteNotice = "The clipboard filter skipped this image."
                        default: break
                        }
                    },
                    keep: { [weak self] in self?.pasted($0, types: $1, token: $2) })
    }

    private func settle(_ outcome: ClipboardCapture.Outcome) {
        switch outcome {
        case .saved, .alreadySaved:
            if panel != nil { loadPanel() }
        default:
            break
        }
        let waiting = capture?.hasUnsavedCopy ?? false
        if hasUnsavedCopy != waiting { hasUnsavedCopy = waiting }
        if case .saved(let entry) = outcome {
            KeyboardLog.typing.info("clipboard: kept a copy of \(entry.text.utf8.count, privacy: .public) bytes")
        } else if case .skipped(let reason) = outcome {
            KeyboardLog.typing.info("clipboard: not kept (\(reason.rawValue, privacy: .public))")
        } else if outcome == .changedSinceLook {
            KeyboardLog.typing.info("clipboard: pasted, not kept (the board changed since the last look)")
        }
    }

    // MARK: Panel

    /// Opening the panel refreshes its entries and preserves the selected tab.
    func panelOpened() {
        loadPanel()
    }

    func panelClosed() {
        panelTimer?.cancel()
        panelGeneration &+= 1
        panel = nil
    }

    func loadPanel() {
        panelTimer?.cancel()
        panelGeneration &+= 1
        let generation = panelGeneration
        guard isEnabled else { panel = nil; return }
        guard hasOpenAccess() else { panel = .needsFullAccess; return }
        guard let history else { panel = .unreachable; return }
        if panel == nil || panel == .timedOut { panel = .loading }
        if panel == .loading {
            panelTimer = Task { [weak self, panelWait] in
                try? await Task.sleep(for: panelWait)
                guard let self, !Task.isCancelled, panelGeneration == generation else { return }
                panelGeneration &+= 1
                panel = .timedOut
            }
        }
        // A file read and a decode: off the main thread, so the keys never wait on it.
        readPanel(history) { [weak self] entries in
            guard let self, self.panelGeneration == generation else { return }
            self.panelTimer?.cancel()
            self.panel = .loaded(entries)
        }
    }

    nonisolated static func readRecent(_ history: ClipboardHistory, completion: @escaping @MainActor ([ClipboardEntry]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = history.recent(limit: Self.panelLimit)
            DispatchQueue.main.async {
                completion(entries)
            }
        }
    }
}
