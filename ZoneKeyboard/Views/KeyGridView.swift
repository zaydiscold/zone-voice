// by zayd/cold @ zayd.wtf

import Observation
import SwiftUI
import UIKit
import ZoneCore

/// The typing keys, drawn and touched in one UIKit view.
///
/// Replaces about forty SwiftUI key views, each hosting its own UIControl. The phone profile had
/// a quarter of main-thread samples in the hosting view's hit testing and a full-grid re-render
/// on every shift change. Here each key is two plain CALayers (the cap and a pre-rendered label),
/// a touch goes straight to this view, and the key it belongs to comes from `KeyGridGeometry`:
/// the nearest key to the touch moved 3 pt up, so gaps, edges and row boundaries never drop a
/// letter. A shift change swaps label bitmaps; it never rebuilds the grid.
///
/// Touches are tracked one by one for two-thumb typing. When a new key goes down, any key still
/// held is committed first, so letters always land in the order they were pressed, the way the
/// system keyboard rolls over; the rest commit on release.
///
/// The globe stays the system's `UIButton` with `handleInputModeList(from:with:)`, as App Review
/// 4.4.1 requires; this view routes the globe's whole touch region to it.
@MainActor
final class KeyGridView: UIView {
    private let model: KeyboardModel
    private let mic: MicController
    private weak var controller: UIInputViewController?

    /// One drawn key: the cap layer, its label layer, and what is showing.
    private struct Slot {
        var key: Key
        let cap: CALayer
        let label: CALayer
        var cornerMark: CAShapeLayer?
        var spec: KeyGlyphSpec?
    }

    private final class Press {
        let order: Int
        let began = ProcessInfo.processInfo.systemUptime
        var position: KeyGridGeometry.Position
        var key: Key
        /// The raw point that decided the key (the touch-down, or where a slide changed letters):
        /// release tolerance is judged from it, and learned touch offsets learn from it.
        var point: CGPoint
        /// `point` moved by the learned touch offsets: what chose the key, and autocorrect's
        /// touch evidence.
        var aimed: CGPoint
        /// The touch is still within release tolerance of the key.
        var near = true
        /// Already acted on (rolled over by a later key); the release does nothing more.
        var committed = false
        var cursorGesture: SpacebarCursorGesture?
        var cursorToken: KeyboardModel.CursorToken?
        var cursorHold: DispatchWorkItem?
        /// The hold that opens the one-handed picker on 123 or emoji, while it is pending.
        var handHold: DispatchWorkItem?
        /// The picker is open for this press: its release chooses a layout and types nothing.
        var picksHand = false
        /// Where the finger was when the picker opened, until it slides away from there. The
        /// finger then sits over whichever item is above 123 (the left one, at the keyboard's left
        /// edge), so following it at once would move the keys on a hold and lift.
        var pickerAnchorX: CGFloat?
        /// The finger's latest horizontal position, wherever it has moved.
        var latestX: CGFloat
        /// Hold space to talk (Beta) owns this press: it never types, moves the cursor or rolls
        /// over, and its release stops the dictation.
        var talking = false
        var balloon: KeyBalloonLayer?
        var swipePoints: [SwipePoint] = []
        var swipeLayout: SwipeLayout?
        var swipePitch: CGFloat = 1
        var swipeToken: KeyboardModel.SwipeInputToken?
        var swipeTravel: Float = 0
        var isSwipe = false
        var swipeStarted: TimeInterval = 0

        init(order: Int, position: KeyGridGeometry.Position, key: Key, point: CGPoint, aimed: CGPoint) {
            self.order = order
            self.position = position
            self.key = key
            self.point = point
            self.aimed = aimed
            self.latestX = point.x
        }
    }

    private var geometry: KeyGridGeometry?
    private var shownGridRows: [KeyGridRow] = []
    private var slots: [[Slot]] = []
    private var spareSlots: [Slot] = []
    private var presses: [ObjectIdentifier: Press] = [:]
    private var finishedTouches: [ObjectIdentifier: TimeInterval] = [:]
    private var nextPressOrder = 0
    private var cursorActive = false
    /// A held space bar is talking (`SpaceTalk`). Like cursor control, it owns the grid.
    private var talkActive = false
    /// Cursor control or a talking hold: other fingers type nothing until it ends.
    private var spaceOwnsGrid: Bool { cursorActive || talkActive }
    private var shownTalkPhase = SpaceTalk.Phase.none
    private var balloonPool: [KeyBalloonLayer] = []
    private let keysLayer = CALayer()
    private let swipeTrail = SwipeTrailLayer()
    private var lastLetterTap: TimeInterval?
    private lazy var touchCapture = SwipeTouchCapture(owner: self)
    private let globeButton = UIButton(type: .system)
    /// Apple's paste button, sitting where the Paste key is drawn. A tap on the system's own
    /// control is the permission to read the clipboard; a key Zone draws makes iOS ask
    /// "Allow Paste" on every tap. Rebuilt when the theme flips: its colors are fixed at creation.
    private var pasteControl: UIPasteControl?
    private lazy var pasteTarget = PasteTarget(
        session: { [weak self] in self?.model.currentSession },
        saving: PasteSaving(tap: { [weak self] in self?.model.pasteSaving?.tap() },
                            image: { [weak self] in self?.model.pasteSaving?.image?($0, $1, $2) },
                            keep: { [weak self] in self?.model.pasteSaving?.keep($0, $1, $2) })) { [weak self] text in
        self?.model.insertPasted(text)
        self?.mic.userTypedKey()
    }
    private var accessibilityKeys: [KeyAccessibilityElement] = []
    private let prediction = KeyGridPrediction()
    private var handPicker: HandPickerLayer?
    /// Points outside the grid, left and right, whose touches still belong to the edge keys. In
    /// one-handed mode the side toward the panel gets a margin, so a thumb that overshoots "q" or
    /// "p" types it instead of pressing the panel's buttons (`KeyboardViewController.layoutColumn`).
    var edgeSlop: (left: CGFloat, right: CGFloat) = (0, 0)
    /// How long 123 or emoji is held before the one-handed picker opens. Apple's globe menu opens at
    /// about half a second; a little less, as the hold is on a key people also tap quickly.
    static let handHoldDuration: TimeInterval = 0.42
    /// How far the finger slides sideways before the picker follows it.
    static let pickerSlide: CGFloat = 10

    private var isDark = false
    private var keyFill = UIColor.white
    private var pressedFill = UIColor.white
    private var shownVisible: Bool?

    #if DEBUG
    private static var touchLogBudget = 400
    #endif

    init(model: KeyboardModel, mic: MicController, controller: UIInputViewController?) {
        self.model = model
        self.mic = mic
        self.controller = controller
        super.init(frame: .zero)
        // Not clear: the keyboard's remote host drops touches on fully transparent pixels before
        // they reach the extension (seen in the simulator 2026-11-01: taps in the gaps between
        // caps never arrived). A nonempty fill puts the whole grid, gaps and margins, in the hit
        // region so nearest-key assignment can see every touch.
        backgroundColor = UIColor.black.withAlphaComponent(0.001)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        clipsToBounds = false
        keysLayer.actions = KeyBalloonLayer.noActions
        layer.addSublayer(keysLayer)
        layer.addSublayer(swipeTrail)
        addGestureRecognizer(touchCapture)
        // This captures ordinary key releases too. Native keyboard hosts can withhold a
        // space's UIView touch-up; disabling capture also breaks taps/cursor control.
        // canBeginSwipe independently gates promotion of a letter trace to swipe input.

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "globe")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17)
        globeButton.configuration = config
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.layer.cornerRadius = KeyboardTheme.cornerRadius
        globeButton.layer.cornerCurve = .continuous
        globeButton.isHidden = true
        if let controller {
            globeButton.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        addSubview(globeButton)

        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: KeyGridView, _) in
            view.sync()
        }
        observe()
        syncVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model state

    /// Re-arms after every change: Observation reports once per registration.
    private func observe() {
        withObservationTracking {
            _ = model.layer
            _ = model.shift
            _ = model.needsGlobe
            _ = model.returnLabel
            _ = model.returnEnabled
            _ = model.fieldKeys
            _ = model.preferences.swipeTypingEnabled
            _ = model.preferences.showsPasteKey
            _ = model.preferences.showsEmojiKey
            _ = model.preferences.oneHandedEnabled
            _ = model.hand
            _ = model.preferences.spaceHold
            _ = model.showsEmoji
            _ = model.hasFullAccess
            _ = model.explicitDark
            _ = mic.mode
            _ = mic.panelSection
            _ = mic.showsHistory
            _ = mic.spaceTalkPhase
        } onChange: { [weak self] in
            // Called before the value changes; read it on the next turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.syncVisibility(animated: true)
                self.sync()
                self.followTalkPhase()
            }
        }
    }

    /// The type face shows the keys unless the history or emoji panel has their place.
    private var shouldShow: Bool { mic.mode == .type && mic.panelSection == nil && !mic.showsHistory && !model.showsEmoji }

    private func syncVisibility(animated: Bool) {
        let visible = shouldShow
        guard visible != shownVisible else { return }
        shownVisible = visible
        isUserInteractionEnabled = visible
        if !visible { cancelAllPresses() }
        if visible { setNeedsLayout() }
        let apply = { self.alpha = visible ? 1 : 0 }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Hidden on the dictate face, where the view is squeezed by the shorter keyboard; the keys
        // keep their last layout until the type face returns.
        guard shownVisible == true, bounds.width > 0, bounds.height > 0 else { return }
        if geometry?.size != bounds.size || geometry?.metrics != metrics { sync() }
    }

    /// The whole keyboard's width. In one-handed mode the grid is narrower than the keyboard, but
    /// rows keep the full keyboard's height (narrowing costs accuracy more than shortening), and
    /// the cursor's line estimate is about the host's text, not the keys.
    var previewBoardWidth: CGFloat?
    var fullWidth: CGFloat { previewBoardWidth ?? max(superview?.bounds.width ?? 0, bounds.width) }

    var duo: DuoKeyboard = .ordinary
    var windowInset: CGFloat = 0
    var splitKeys = false
    private var shownSplit = false
    private var metrics: KeyGridMetrics {
        var value = duo.metrics(width: fullWidth, windowInset: windowInset)
        if splitKeys { value.keySpacing = 10.7 }
        return value
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            cancelAllPresses()
            prediction.reset()
        }
    }

    private var scale: CGFloat {
        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : (window?.screen.scale ?? 3)
    }

    nonisolated static func pixelRound(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Brings the drawn keys up to the model. A new layer, globe or size lays the grid out again;
    /// anything else (shift, the return label, light and dark) only swaps labels and fills.
    func sync() {
        guard shownVisible == true, bounds.width > 0, bounds.height > 0 else { return }
        let dark = model.explicitDark ?? (traitCollection.userInterfaceStyle == .dark)
        let themeChanged = dark != isDark || slots.isEmpty
        if themeChanged {
            isDark = dark
            let theme = KeyboardTheme(isDark: dark)
            keyFill = UIColor(theme.key)
            pressedFill = UIColor(theme.pressedKey)
            globeButton.tintColor = UIColor(theme.text)
            globeButton.backgroundColor = keyFill
            pasteControl?.removeFromSuperview()
            pasteControl = nil
        }
        let ordinary = KeyGridLayout.drawnRows(model.rows)
        let split = splitKeys ? KeyGridLayout.split(ordinary) : nil
        let rows = split?.rows ?? ordinary
        var gridRows = KeyGridLayout.gridRows(rows, layer: model.layer)
        if split != nil { gridRows[1].duplicatesCenter = !ordinary[1].count.isMultiple(of: 2) }
        if shownSplit != splitKeys || gridRows != shownGridRows || geometry?.size != bounds.size || geometry?.metrics != metrics {
            shownSplit = splitKeys
            layOut(rows: rows, gridRows: gridRows, cuts: split?.cuts)
        } else {
            var nativeKeysChanged = false
            for (r, row) in rows.enumerated() {
                for (i, key) in row.enumerated() {
                    let usesNativeControl = usesNativeFace(key)
                    if usesNativeControl != slots[r][i].cap.isHidden {
                        nativeKeysChanged = true
                        slots[r][i].cap.isHidden = usesNativeControl
                    }
                    slots[r][i].key = key
                    applyGlyph(row: r, index: i, force: themeChanged)
                    if themeChanged { applyFill(row: r, index: i) }
                }
            }
            if nativeKeysChanged { cancelAllPresses() }
            if themeChanged || nativeKeysChanged {
                syncNativeKeys()
            } else {
                refreshAccessibilityLabels()
            }
        }
    }

    /// Tells autocorrect which letters sit over the space bar in this layout: x to n beside 123
    /// and globe or emoji, z to n beside 123 alone, c to n beside 123, globe and emoji.
    private func reportSpaceBarLetters(rows: [[Key]], geometry: KeyGridGeometry) {
        guard model.layer == .letters,
              let r = rows.lastIndex(where: { $0.contains(.space) }),
              !rows[r].isEmpty else { return }
        let spaces = rows[r].indices.filter { rows[r][$0] == .space }
        let letters = spaces.flatMap { geometry.keys(above: .init(row: r, index: $0)) }.compactMap { position -> Character? in
            guard case .character(let text) = rows[position.row][position.index], text.count == 1 else { return nil }
            return text.lowercased().first
        }
        model.setSpaceBarLetters(Set(letters))
    }

    private func layOut(rows: [[Key]], gridRows: [KeyGridRow], cuts: [Int]?) {
        cancelAllPresses()
        let geometry = KeyGridGeometry(size: bounds.size, rows: gridRows, metrics: metrics, splitAt: cuts)
        self.geometry = geometry
        shownGridRows = gridRows
        reportSpaceBarLetters(rows: rows, geometry: geometry)
        keysLayer.frame = bounds
        // Reuse layers across layer switches: 30 to 40 keys, no allocation after the first.
        spareSlots += slots.flatMap { $0 }
        slots = []
        for (r, row) in rows.enumerated() {
            var drawn: [Slot] = []
            for (i, key) in row.enumerated() {
                var slot = spareSlots.popLast() ?? makeSlot(key: key)
                if key == .space, slot.cornerMark == nil {
                    // The system space cap has a condensed mark, 16 by 29 pixels at 3x.
                    let mark = CAShapeLayer()
                    let path = UIBezierPath()
                    for (i, point) in [(0,0), (16,0), (16,3), (3,26), (16,26), (16,29),
                                       (0,29), (0,26), (13,3), (0,3)].enumerated() {
                        let p = CGPoint(x: CGFloat(point.0) / 3, y: CGFloat(point.1) / 3)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.close()
                    mark.path = path.cgPath
                    mark.actions = KeyBalloonLayer.noActions
                    mark.opacity = 0.20
                    slot.cap.addSublayer(mark)
                    slot.cornerMark = mark
                }
                slot.cornerMark?.isHidden = key != .space
                slot.key = key
                slot.spec = nil
                let cap = geometry.caps[r][i]
                slot.cap.frame = cap
                slot.cap.isHidden = usesNativeFace(key)
                drawn.append(slot)
            }
            slots.append(drawn)
        }
        for slot in spareSlots { slot.cap.isHidden = true }
        for (r, row) in slots.enumerated() {
            for i in row.indices {
                applyFill(row: r, index: i)
                applyGlyph(row: r, index: i, force: true)
            }
        }
        syncNativeKeys()
    }

    /// The native controls follow both layout and appearance. A restyle can replace Paste
    /// without changing a single cap frame, and Globe and Emoji can trade equal-width slots.
    private func usesNativeFace(_ key: Key) -> Bool {
        key == .globe || (key == .paste && model.hasFullAccess)
    }

    private func syncNativeKeys() {
        if let globe = slots.last?.first(where: { $0.key == .globe }) {
            globeButton.frame = globe.cap.frame
            globeButton.isHidden = false
        } else {
            globeButton.isHidden = true
        }
        if model.hasFullAccess, let paste = slots.last?.first(where: { $0.key == .paste }) {
            var frame = paste.cap.frame
            // At the 27.5 pt landscape cap height UIKit shows a blank blue tile.
            // Give its native Paste glyph the row pitch, inside the keyboard edges.
            if duo == .coverLandscape {
                frame.size.height = metrics.rowPitch
                frame.origin.y = bounds.maxY - frame.height
            }
            if let pasteControl {
                pasteControl.frame = frame
            } else {
                let control = KeyboardPasteControl(theme: KeyboardTheme(isDark: isDark), target: pasteTarget, surface: "grid")
                control.gridOwnsPoint = { [weak self, weak control] point in
                    guard let self, let control else { return false }
                    return self.hitTest(control.convert(point, to: self), with: nil) === control
                }
                control.frame = frame
                addSubview(control)
                pasteControl = control
            }
        } else {
            pasteControl?.removeFromSuperview()
            pasteControl = nil
        }
        rebuildAccessibility()
    }

    private func makeSlot(key: Key) -> Slot {
        let cap = CALayer()
        cap.actions = KeyBalloonLayer.noActions
        cap.cornerRadius = KeyboardTheme.cornerRadius
        cap.cornerCurve = .continuous
        let label = CALayer()
        label.actions = KeyBalloonLayer.noActions
        cap.addSublayer(label)
        keysLayer.addSublayer(cap)
        return Slot(key: key, cap: cap, label: label, cornerMark: nil, spec: nil)
    }

    private func applyFill(row: Int, index: Int) {
        slots[row][index].cap.backgroundColor = keyFill.cgColor
    }

    private func glyphSpec(for key: Key, capWidth: CGFloat) -> KeyGlyphSpec? {
        let fit = max(capWidth - 8, 1)
        if spaceOwnsGrid { return nil }
        switch key {
        case .character(let text): return .text(text, size: 22, lift: 1, maxWidth: fit)
        case .space: return nil
        case .delete: return .symbol("delete.left")
        case .shift:
            switch model.shift {
            case .off: return .symbol("shift")
            case .on: return .symbol("shift.fill")
            case .locked: return .symbol("capslock.fill")
            }
        // iOS 26 draws the default return as a symbol and the others (go, send, search) as words.
        case .newline:
            let label = model.returnLabel
            return label == "return" ? .symbol("return.left") : .text(label, size: 18, lift: 1, maxWidth: fit)
        case .switchLayer(_, let label): return .text(label, size: 18, lift: 1, maxWidth: fit)
        case .emoji: return .symbol("face.smiling")
        case .paste: return model.hasFullAccess ? nil : .symbol("document.on.clipboard")
        case .globe, .mic: return nil
        }
    }

    private func applyGlyph(row: Int, index: Int, force: Bool) {
        let slot = slots[row][index]
        let cap = slot.cap.bounds
        if slot.key == .space, let corner = slot.cornerMark {
            corner.contentsScale = scale
            corner.fillColor = (isDark ? UIColor.white : .black).cgColor
            // Round in window space. Fractional key widths otherwise spread a 16 px mark across 17 pixels.
            let edge = convert(CGPoint(x: slot.cap.frame.maxX, y: slot.cap.frame.maxY), to: nil)
            let alignedX = cap.maxX + Self.pixelRound(edge.x, scale) - edge.x
            let alignedY = cap.maxY + Self.pixelRound(edge.y, scale) - edge.y
            corner.frame = CGRect(x: alignedX - 32.0 / 3, y: alignedY - 47.0 / 3,
                                  width: 16.0 / 3, height: 29.0 / 3)
        }
        let spec = glyphSpec(for: slot.key, capWidth: cap.width)
        // Slots are reused across rebuilds, so every key sets this, not only return.
        let opacity: Float = slot.key == .newline && !model.returnEnabled ? 0.35 : 1
        if slot.label.opacity != opacity { slot.label.opacity = opacity }
        guard force || spec != slot.spec else { return }
        slots[row][index].spec = spec
        guard let spec, let glyph = KeyGlyphs.glyph(spec, isDark: isDark, scale: scale) else {
            slot.label.contents = nil
            return
        }
        let s = scale
        slot.label.contentsScale = s
        slot.label.contents = glyph.image
        slot.label.frame = CGRect(x: Self.pixelRound(cap.midX - glyph.size.width / 2, s),
                                  y: Self.pixelRound(cap.midY - spec.lift - glyph.size.height / 2, s),
                                  width: glyph.size.width, height: glyph.size.height)
    }

    // MARK: Touches

    /// Points above the grid that still belong to the top row: the strip's empty bottom margin
    /// plus a sliver of its controls, as Apple's keyboard gives its top row the space above it.
    /// A thumb that overshoots "w" or "e" types the letter instead of flipping the face (seen on
    /// the SE simulator 2026-11-02).
    static let topOvershoot: CGFloat = 6

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.x >= bounds.minX - edgeSlop.left && point.x < bounds.maxX + edgeSlop.right
            && point.y >= bounds.minY - Self.topOvershoot && point.y < bounds.maxY
            && (!splitKeys || geometry?.key(at: point) != nil)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard mic.panelSection == nil, isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if !spaceOwnsGrid, !globeButton.isHidden, let position = geometry?.key(at: point), key(at: position) == .globe {
            return globeButton
        }
        if !spaceOwnsGrid, let pasteControl, let position = geometry?.key(at: point), key(at: position) == .paste {
            return pasteControl
        }
        return self
    }

    private func key(at position: KeyGridGeometry.Position) -> Key? {
        guard slots.indices.contains(position.row), slots[position.row].indices.contains(position.index) else { return nil }
        return slots[position.row][position.index].key
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Native input hosts sometimes bypass the recognizer for quick taps. Always accept
        // view delivery; captureBegan deduplicates touches already seen by the recognizer.
        captureBegan(touches, event: event)
    }

    fileprivate func captureBegan(_ touches: Set<UITouch>, event: UIEvent?) {
        // Additional fingers cannot roll over a cursor gesture or a talking hold into a space or another key.
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let id = ObjectIdentifier(touch)
            if let ended = finishedTouches[id], touch.timestamp <= ended { continue }
            if spaceOwnsGrid { rememberFinished(id, at: touch.timestamp); continue }
            guard presses[id] == nil else { continue }
            // A second finger in the gap must not roll over a still-held key.
            if splitKeys, geometry?.key(at: touch.location(in: self)) == nil { continue }
            KeyTrace.touch(timestamp: touch.timestamp, down: true)
            // Roll over: whatever is still held lands first, in the order it went down. This may
            // switch the layer or the shift, so the new touch is judged on the updated keys.
            let held = presses.values.filter { !$0.committed }.sorted { $0.order < $1.order }
            if !held.isEmpty {
                for press in held {
                    // A second finger closes an open picker without choosing: it was not a choice.
                    if press.picksHand { finish(press, tap: false); continue }
                    if press.isSwipe { submitSwipe(press) } else { commit(press) }
                }
                sync()
            }
            guard let geometry else { continue }
            let point = touch.location(in: self)
            let aimed = adapted(point, geometry: geometry)
            guard let position = geometry.key(at: aimed, likelihood: likelihood()), let key = key(at: position),
                  !usesNativeFace(key), key != .mic else { continue }
            #if DEBUG
            logTouch(point, position: position, geometry: geometry)
            #endif
            let press = Press(order: nextPressOrder, position: position, key: key, point: point, aimed: aimed)
            if model.canBeginSwipe, case .character(let text) = key, text.first?.isLetter == true,
               let layout = makeSwipeLayout(geometry, start: point) {
                let pitch = geometry.unitWidth + geometry.metrics.keySpacing
                press.swipeLayout = layout
                press.swipeToken = model.swipeInputToken
                press.swipePitch = pitch
                press.swipeStarted = touch.timestamp
                press.swipePoints = [SwipePoint(x: Float(point.x / pitch), y: Float(point.y / pitch), t: 0)]
            }
            nextPressOrder += 1
            presses[ObjectIdentifier(touch)] = press
            showPressed(press)
            KeyTrace.measure("feedback") { model.keyDown(key) }
            if key == .delete { prediction.typed(.delete) }
            if key == .space { armCursor(press) }
            if opensHandPicker(key, row: position.row) { armHandPicker(press) }
        }
    }

    /// Dynamic hit targets: on the letters layer, each letter's chance of coming next after the
    /// word typed so far, and the space bar's chance that the word ends here. Nil (pure nearest
    /// key) at the start of a word, on other layers, before the table for this prefix is ready,
    /// or with the feature off.
    private func likelihood() -> ((KeyGridGeometry.Position) -> Double?)? {
        guard model.layer == .letters, let table = prediction.current else { return nil }
        return { [unowned self] position in
            switch self.key(at: position) {
            case .character(let text): return table.nextKeyProbability(of: text)
            case .space: return table.nextKeyProbability(of: " ")
            default: return nil
            }
        }
    }

    /// Learned touch offsets (`TouchAdaptationStore`): on the letters layer, the touch moved to
    /// where this person aims, interpolated between key centers and clamped by the geometry.
    /// Other layers, and a store with nothing learned, keep the raw point.
    private func adapted(_ point: CGPoint, geometry: KeyGridGeometry) -> CGPoint {
        let table = TouchAdaptationStore.offsets
        guard duo == .ordinary, model.layer == .letters, table.count == 26 else { return point }
        let pitch = geometry.unitWidth + geometry.metrics.keySpacing, rowPitch = geometry.metrics.rowPitch
        return geometry.adjusted(point) { [unowned self] position in
            guard case .character(let text) = self.key(at: position), text.utf8.count == 1,
                  let byte = text.utf8.first, case let folded = byte | 0x20, folded >= 0x61, folded <= 0x7A else { return nil }
            let offset = table[Int(folded - 0x61)]
            return CGVector(dx: CGFloat(offset.dx) * pitch, dy: CGFloat(offset.dy) * rowPitch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        captureMoved(touches, event: event)
    }

    fileprivate func captureMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        for touch in touches {
            guard let press = presses[ObjectIdentifier(touch)], !press.committed else { continue }
            captureSwipe(press, touch: touch, event: event)
            if !press.committed && !press.isSwipe { track(press, to: touch.location(in: self), time: touch.timestamp) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        captureEnded(touches, event: event)
    }

    fileprivate func captureEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        let ended = touches.compactMap { touch -> (UITouch, Press)? in
            rememberFinished(ObjectIdentifier(touch), at: touch.timestamp)
            guard let press = presses.removeValue(forKey: ObjectIdentifier(touch)) else { return nil }
            return (touch, press)
        }.sorted { $0.1.order < $1.1.order }
        for (touch, press) in ended {
            KeyTrace.touch(timestamp: touch.timestamp, down: false)
            guard !press.committed else { continue }
            captureSwipe(press, touch: touch, event: event)
            if !press.committed && !press.isSwipe { track(press, to: touch.location(in: self), time: touch.timestamp) }
            if press.isSwipe { submitSwipe(press) } else { commit(press) }
        }
        // The press changed the model (shift off after a letter, a new layer); draw it in this
        // same frame rather than waiting for the observation hop.
        if !ended.isEmpty { sync() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        captureCancelled(Set(touches.filter { !touchCapture.isTracking($0) }), event: event)
    }

    fileprivate func captureCancelled(_ touches: Set<UITouch>, event: UIEvent?) {
        guard !touches.isEmpty else { return }
        for touch in touches {
            rememberFinished(ObjectIdentifier(touch), at: touch.timestamp)
            guard let press = presses.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            if press.isSwipe { swipeTrail.clear() }
            finish(press, tap: false)
        }
    }

    private func submitSwipe(_ press: Press) {
        guard !press.committed, let layout = press.swipeLayout else { return }
        swipeTrail.endStroke()
        let points = press.swipePoints
        finish(press, tap: false)
        model.handleSwipe(points, layout: layout, token: press.swipeToken, split: splitKeys)
        prediction.reset()
        mic.userTypedKey()
    }

    private func makeSwipeLayout(_ geometry: KeyGridGeometry, start: CGPoint) -> SwipeLayout? {
        let pitch = geometry.unitWidth + geometry.metrics.keySpacing
        guard pitch > 0 else { return nil }
        var centers: [Character: SwipePoint] = [:]
        for (r, row) in slots.enumerated() {
            for (i, slot) in row.enumerated() {
                guard case .character(let text) = slot.key, text.count == 1,
                      let letter = text.lowercased().first, letter.isASCII, letter.isLetter else { continue }
                let cap = geometry.caps[r][i]
                if centers[letter] != nil, !geometry.sameHalf(start, CGPoint(x: cap.midX, y: cap.midY)) { continue }
                centers[letter] = SwipePoint(x: Float(cap.midX / pitch), y: Float(cap.midY / pitch))
            }
        }
        guard centers.count == 26 else { return nil }
        return SwipeLayout(centers: centers, rowPitch: Float(geometry.metrics.rowPitch / pitch))
    }

    private func captureSwipe(_ press: Press, touch: UITouch, event: UIEvent?) {
        if splitKeys, case .character = press.key, let geometry {
            // A touch leaving its cluster cannot become a tap on a duplicate, or
            // submit a long interpolated stroke across the unused glass.
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                let p = sample.location(in: self)
                if !geometry.sameHalf(press.point, p) || geometry.key(at: p) == nil {
                    finish(press, tap: false)
                    swipeTrail.clear()
                    return
                }
            }
        }
        guard press.swipeLayout != nil, model.canSwipe else { return }
        let color = KeyboardTheme(isDark: isDark).accentToneUIColor
        let style = model.preferences.swipeTrailStyle
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = sample.location(in: self)
            let point = SwipePoint(x: Float(p.x / press.swipePitch), y: Float(p.y / press.swipePitch),
                                   t: Float(sample.timestamp - press.swipeStarted))
            if let last = press.swipePoints.last {
                guard point.t >= last.t else { continue }
                if point.t == last.t, point.x == last.x, point.y == last.y { continue }
                let dx = point.x - last.x, dy = point.y - last.y
                press.swipeTravel += (dx * dx + dy * dy).squareRoot()
            }
            // Keep a bounded path while preserving the entire gesture and its final endpoint.
            if press.swipePoints.count >= 512 {
                press.swipePoints = press.swipePoints.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
            }
            press.swipePoints.append(point)
            if press.isSwipe {
                swipeTrail.append(p, color: color, style: style, now: sample.timestamp)
            }
        }
        if !press.isSwipe, SwipeGate().isSwipe(travel: press.swipeTravel,
            duration: touch.timestamp - press.swipeStarted,
            sinceLastTap: lastLetterTap.map { press.swipeStarted - $0 }) {
            press.isSwipe = true
            swipeTrail.clear()
            clearPressed(press)
            // Show the lead-in once the movement qualifies. Later samples go straight to the trail.
            for p in press.swipePoints {
                swipeTrail.append(CGPoint(x: CGFloat(p.x) * press.swipePitch,
                                          y: CGFloat(p.y) * press.swipePitch), color: color,
                                  style: style, now: press.swipeStarted + Double(p.t))
            }
        }
    }

    /// Follows a moving touch. A letter slid onto another letter becomes that letter (the system
    /// keyboard's balloon follows the finger); any other key just stops counting once the touch
    /// leaves its release tolerance, and comes back if the touch does.
    private func track(_ press: Press, to point: CGPoint, time: TimeInterval? = nil) {
        press.latestX = point.x
        if press.picksHand, let handPicker {
            if let anchor = press.pickerAnchorX {
                guard abs(point.x - anchor) >= Self.pickerSlide else { return }
                press.pickerAnchorX = nil
            }
            if handPicker.select(handPicker.choice(atX: point.x)) { model.feedback.impact(.light) }
            return
        }
        // A talking hold ignores where the finger wanders; only lifting it matters.
        if press.talking { return }
        if var gesture = press.cursorGesture {
            let wasActive = gesture.isActive
            let motion = gesture.motion(x: point.x, y: point.y, time: time)
            press.cursorGesture = gesture
            // A sideways slide on space starts cursor control without waiting for the hold.
            if gesture.isActive, !wasActive, press.cursorToken == nil { activateCursor(press) }
            if let token = press.cursorToken {
                model.moveCursorLines(motion.lines, wrapWidth: CursorLines.estimatedWrapWidth(points: fullWidth), token: token)
                model.moveCursor(motion.steps, token: token)
                return
            }
            // Armed but never activated (a failed begin): the press must not type on release.
            if gesture.isActive { press.near = false; return }
        }
        guard let geometry else { return }
        if geometry.isNear(point, to: press.position) {
            if !press.near { press.near = true; showPressed(press) }
            return
        }
        let aimed = adapted(point, geometry: geometry)
        if case .character = press.key, let target = geometry.key(at: aimed, likelihood: likelihood()),
           let key = key(at: target), case .character = key {
            press.position = target
            press.key = key
            press.point = point
            press.aimed = aimed
            press.near = true
            showPressed(press)
            return
        }
        if press.near {
            press.near = false
            clearPressed(press)
        }
    }

    /// Types the press's key if the touch is still on it, then releases it.
    private func commit(_ press: Press) {
        if press.picksHand, let choice = handPicker?.selection {
            finish(press, tap: false)
            model.chooseHand(choice)
            return
        }
        finish(press, tap: press.near)
    }

    private func finish(_ press: Press, tap: Bool) {
        guard !press.committed else { return }
        press.committed = true
        press.cursorHold?.cancel()
        press.cursorHold = nil
        press.handHold?.cancel()
        press.handHold = nil
        if press.picksHand {
            handPicker?.hide()
            clearPressed(press)
            return
        }
        if press.talking {
            clearPressed(press)
            setTalkLook(false)
            mic.spaceHoldEnded()
            return
        }
        if let token = press.cursorToken {
            clearPressed(press)
            model.endCursorControl(token)
            setCursorLook(false)
            prediction.reset()
            return
        }
        // The trail keeps fading after lift without retaining decode samples.
        clearPressed(press)
        // A held delete stops repeating exactly once, whether released, rolled over or cancelled.
        if press.key == .delete {
            model.endDeleteRepeat()
            // Held past the repeat delay, it removed an unknown amount; forget the word.
            if ProcessInfo.processInfo.systemUptime - press.began > 0.4 { prediction.reset() }
        }
        if tap {
            if case .character(let text) = press.key, text.first?.isLetter == true {
                lastLetterTap = ProcessInfo.processInfo.systemUptime
            }
            perform(press.key, touch: geometry?.touchOffset(press.aimed, on: press.position),
                    raw: geometry?.touchOffset(press.point, on: press.position))
            if press.key != .delete { prediction.typed(press.key) }
        }
    }

    private func perform(_ key: Key, touch: KeyTouch? = nil, raw: KeyTouch? = nil) {
        switch key {
        case .delete:
            // Delete acted on touch-down and repeated while held; the release only counts as typing.
            mic.userTypedKey()
        case .shift, .switchLayer, .emoji:
            model.handleTap(key)
        case .paste:
            model.explainPasteAccess()
        case .globe, .mic:
            break
        case .character, .space, .newline:
            model.handleTap(key, touch: touch, raw: raw, trainOffsets: duo == .ordinary)
            mic.userTypedKey()
        }
    }

    /// Suppress a delayed duplicate begin after UIView has already ended the touch. UITouch
    /// objects can be reused, so a later timestamp is a new press, not permanently blacklisted.
    private func rememberFinished(_ id: ObjectIdentifier, at time: TimeInterval) {
        finishedTouches[id] = max(finishedTouches[id] ?? time, time)
        if finishedTouches.count > 32, let oldest = finishedTouches.min(by: { $0.value < $1.value }) {
            finishedTouches.removeValue(forKey: oldest.key)
        }
    }

    private func cancelAllPresses() {
        swipeTrail.clear()
        for id in presses.keys { rememberFinished(id, at: ProcessInfo.processInfo.systemUptime) }
        let held = presses.values.sorted { $0.order < $1.order }
        presses.removeAll()
        for press in held { finish(press, tap: false) }
    }

    // MARK: Space-bar cursor

    /// Arms the space bar's hold: the cursor, or with Hold space set to Talk, a dictation. A
    /// sideways slide before the hold moves the cursor in both (`track`).
    private func armCursor(_ press: Press) {
        press.cursorGesture = SpacebarCursorGesture(x: press.point.x, y: press.point.y)
        let work = DispatchWorkItem { [weak self, weak press] in
            guard let self, let press, press.near, let gesture = press.cursorGesture,
                  gesture.canActivate, !gesture.isActive else { return }
            if self.model.preferences.spaceHold == .talk, self.beginTalk(press) { return }
            guard press.cursorGesture?.activate() == true else { return }
            self.activateCursor(press)
        }
        press.cursorHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SpacebarCursorGesture.holdDuration, execute: work)
    }

    /// Hold and slide both land here once the gesture is active. No check that the text is
    /// unchanged since touch-down: a host echo of the space just typed would silently refuse
    /// the hold. `beginCursorControl` queues behind a pending swipe and binds the live field.
    private func activateCursor(_ press: Press) {
        press.cursorHold?.cancel()
        press.cursorHold = nil
        guard !press.committed, press.cursorToken == nil,
              presses.values.contains(where: { $0 === press }),
              let token = model.beginCursorControl() else { return }
        press.cursorToken = token
        clearPressed(press)
        prediction.reset()
        lastLetterTap = nil
        mic.userTypedKey()
        setCursorLook(true)
        model.feedback.impact(.light)
    }

    private func setCursorLook(_ active: Bool) {
        cursorActive = active
        applySpaceOwnedLook()
    }

    // MARK: Hold space to talk (Beta)

    /// The hold reached `SpaceTalk.holdDuration` with Talk chosen. False when there is nothing to
    /// talk with (no Full Access, a dictation already under way); the hold then moves the cursor.
    private func beginTalk(_ press: Press) -> Bool {
        guard !press.committed, !press.talking, presses.values.contains(where: { $0 === press }) else { return false }
        guard mic.spaceHoldBegan() else { return false }
        press.cursorHold?.cancel()
        press.cursorHold = nil
        press.talking = true
        clearPressed(press)
        prediction.reset()
        lastLetterTap = nil
        // A hold the strip only explains (Zone not ready) keeps its press, so letting go types
        // nothing, but leaves the keys as they are.
        shownTalkPhase = mic.spaceTalkPhase
        if shownTalkPhase != .none { setTalkLook(true) }
        return true
    }

    private func setTalkLook(_ active: Bool) {
        talkActive = active
        if !active { shownTalkPhase = .none }
        applySpaceOwnedLook()
    }

    /// A dictation that ended with the finger still down (Stop or Cancel in the strip, an error)
    /// hands the keys back at once; the held press still types nothing when it lifts.
    private func followTalkPhase() {
        guard talkActive, mic.spaceTalkPhase != shownTalkPhase else { return }
        guard mic.spaceTalkPhase != .none else { setTalkLook(false); return }
        shownTalkPhase = mic.spaceTalkPhase
        refreshAccessibilityLabels()
    }

    private func applySpaceOwnedLook() {
        for (r, row) in slots.enumerated() {
            for i in row.indices { applyGlyph(row: r, index: i, force: true) }
        }
        globeButton.alpha = spaceOwnsGrid ? 0.35 : 1
        refreshAccessibilityLabels()
    }

    // MARK: One-handed picker

    /// The keys that open the picker, as Apple's globe and emoji keys do: the layer switch on the
    /// bottom row, and the emoji key. Only once Settings turns the mode on, and only on a keyboard
    /// the mode fits (an iPhone in portrait).
    private func opensHandPicker(_ key: Key, row: Int) -> Bool {
        guard duo.allowsOneHand, model.preferences.oneHandedEnabled, OneHandedLayout.isAvailable(width: fullWidth) else { return false }
        switch key {
        case .switchLayer: return row == slots.count - 1
        case .emoji: return true
        default: return false
        }
    }

    private func armHandPicker(_ press: Press) {
        let work = DispatchWorkItem { [weak self, weak press] in
            guard let self, let press, press.near, !press.committed,
                  self.presses.values.contains(where: { $0 === press }) else { return }
            self.openHandPicker(press)
        }
        press.handHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handHoldDuration, execute: work)
    }

    private func openHandPicker(_ press: Press) {
        guard let cap = geometry?.cap(press.position) else { return }
        press.handHold = nil
        press.picksHand = true
        press.pickerAnchorX = press.latestX
        let picker = handPicker ?? {
            let made = HandPickerLayer()
            made.isHidden = true
            layer.addSublayer(made)
            handPicker = made
            return made
        }()
        // Above the balloons and the trail.
        layer.insertSublayer(picker, at: UInt32(layer.sublayers?.count ?? 0))
        picker.show(over: cap, in: bounds, current: model.hand, fill: keyFill, isDark: isDark, scale: scale)
        model.feedback.impact(.medium)
        UIAccessibility.post(notification: .announcement, argument: "Choose where the keys sit")
    }

    #if DEBUG
    /// For tests: the picker's frame and choice while it is open.
    var handPickerState: (frame: CGRect, selection: KeyboardHand)? {
        guard let handPicker, !handPicker.isHidden else { return nil }
        return (handPicker.frame, handPicker.selection)
    }
    #endif

    // MARK: Pressed look

    /// Characters above the bottom row pop a balloon; every other key darkens its fill.
    private func showsBalloon(_ press: Press) -> Bool {
        guard case .character = press.key else { return false }
        return press.position.row < slots.count - 1
    }

    private func showPressed(_ press: Press) {
        clearPressed(press)
        guard let geometry, let cap = geometry.cap(press.position) else { return }
        if showsBalloon(press) {
            let balloon = press.balloon ?? takeBalloon()
            press.balloon = balloon
            var spec: KeyGlyphSpec?
            if case .character(let text) = press.key { spec = .text(text, size: KeyBalloonLayer.glyphSize) }
            let glyph = spec.flatMap { KeyGlyphs.glyph($0, isDark: isDark, scale: scale) }
            balloon.frame = bounds
            // The system clips anything above the keyboard's own view.
            balloon.show(over: cap, glyph: glyph, fill: keyFill, isDark: isDark, minY: -max(frame.minY, 0), width: bounds.width, scale: scale)
        } else {
            slots[press.position.row][press.position.index].cap.backgroundColor = pressedFill.cgColor
        }
    }

    private func clearPressed(_ press: Press) {
        if let balloon = press.balloon {
            balloon.hide()
            balloonPool.append(balloon)
            press.balloon = nil
        }
        let p = press.position
        if slots.indices.contains(p.row), slots[p.row].indices.contains(p.index) {
            // Another finger may still hold the same key.
            let stillHeld = presses.values.contains { $0 !== press && !$0.committed && $0.near && $0.position == p && !showsBalloon($0) }
            if !stillHeld { slots[p.row][p.index].cap.backgroundColor = keyFill.cgColor }
        }
    }

    private func takeBalloon() -> KeyBalloonLayer {
        if let balloon = balloonPool.popLast() { return balloon }
        let balloon = KeyBalloonLayer()
        balloon.isHidden = true
        layer.addSublayer(balloon)
        return balloon
    }

    #if DEBUG
    /// Where on its key each touch landed, for tuning the bias on the phone. Positions and
    /// offsets only, never characters.
    private func logTouch(_ point: CGPoint, position: KeyGridGeometry.Position, geometry: KeyGridGeometry) {
        guard Self.touchLogBudget > 0, let cap = geometry.cap(position) else { return }
        Self.touchLogBudget -= 1
        let dx = point.x - cap.midX, dy = point.y - cap.midY
        let inside = cap.contains(point)
        KeyboardLog.typing.info("keygrid touch row=\(position.row, privacy: .public) key=\(position.index, privacy: .public) dx=\(String(format: "%.1f", dx), privacy: .public) dy=\(String(format: "%.1f", dy), privacy: .public) insideCap=\(inside, privacy: .public)")
    }
    #endif

    // MARK: Accessibility

    private func rebuildAccessibility() {
        var elements: [Any] = []
        accessibilityKeys = []
        for (r, row) in slots.enumerated() {
            for (i, slot) in row.enumerated() {
                if slot.key == .globe {
                    elements.append(globeButton)
                    continue
                }
                if slot.key == .paste, let pasteControl {
                    elements.append(pasteControl)
                    continue
                }
                let element = KeyAccessibilityElement(accessibilityContainer: self)
                element.position = KeyGridGeometry.Position(row: r, index: i)
                element.accessibilityFrameInContainerSpace = slot.cap.frame
                element.onActivate = { [weak self] position in self?.activate(position) }
                accessibilityKeys.append(element)
                elements.append(element)
            }
        }
        accessibilityElements = elements
        refreshAccessibilityLabels()
    }

    private func refreshAccessibilityLabels() {
        for element in accessibilityKeys {
            guard let key = key(at: element.position) else { continue }
            element.accessibilityLabel = Self.accessibilityName(for: key, returnLabel: model.returnLabel)
            element.accessibilityValue = key == .space && cursorActive ? "Cursor control"
                : key == .space && talkActive ? (shownTalkPhase == .listening ? "Listening" : "Starting") : nil
            element.accessibilityHint = key == .space ? (model.preferences.spaceHold == .talk
                ? "Touch and hold to talk, and let go to insert. Slide sideways to move the cursor."
                : "Touch and hold, then slide to move the cursor. Slide up or down to change lines.") : nil
            let moves: [(name: String, steps: Int, lines: Int)] = [
                ("Move cursor backward", -1, 0), ("Move cursor forward", 1, 0),
                ("Move cursor up a line", 0, -1), ("Move cursor down a line", 0, 1)]
            element.accessibilityCustomActions = key == .space ? moves.map { move in
                UIAccessibilityCustomAction(name: move.name) { [weak self] _ in
                    guard let self, let token = self.model.beginCursorControl() else { return false }
                    self.prediction.reset()
                    self.model.moveCursorLines(move.lines, wrapWidth: CursorLines.estimatedWrapWidth(points: self.fullWidth), token: token)
                    self.model.moveCursor(move.steps, resisting: false, token: token)
                    self.model.endCursorControl(token)
                    self.mic.userTypedKey()
                    return true
                }
            } : nil
            element.accessibilityTraits = key == .shift && model.shift.isActive ? [.button, .selected] : .button
            if opensHandPicker(key, row: element.position.row) {
                element.accessibilityCustomActions = HandPickerLayer.choices.filter { $0 != model.hand }.map { hand in
                    UIAccessibilityCustomAction(name: hand.label) { [weak self] _ in
                        self?.model.chooseHand(hand)
                        return true
                    }
                }
            }
        }
    }

    /// VoiceOver's Activate: a full press with no touch to track.
    private func activate(_ position: KeyGridGeometry.Position) {
        guard let key = key(at: position) else { return }
        model.keyDown(key)
        if key == .delete { model.endDeleteRepeat() }
        perform(key)
        prediction.typed(key)
        sync()
    }

    static func accessibilityName(for key: Key, returnLabel: String) -> String {
        switch key {
        case .character(let text): return text
        case .shift: return "Shift"
        case .delete: return "Delete"
        case .space: return "Space"
        case .newline: return returnLabel
        case .switchLayer(_, let label): return label == "ABC" ? "Letters" : label == "123" ? "Numbers" : "Symbols"
        case .globe: return "Next keyboard"
        case .paste: return "Paste"
        case .emoji: return "Emoji"
        case .mic: return "Dictate"
        }
    }
}

/// One key for VoiceOver: label, button trait, and Activate that types it.
private final class KeyAccessibilityElement: UIAccessibilityElement {
    var position = KeyGridGeometry.Position(row: 0, index: 0)
    var onActivate: ((KeyGridGeometry.Position) -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?(position)
        return true
    }
}

/// Receives edge touches at gesture-recognizer time rather than the delayed UIView delivery.
/// Globe touches keep using Apple's own button. Multi-touch tap rollover stays in KeyGridView.
@MainActor
private final class SwipeTouchCapture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var owner: KeyGridView?
    private var active = Set<ObjectIdentifier>()
    init(owner: KeyGridView) {
        self.owner = owner
        super.init(target: nil, action: nil)
        delegate = self
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    /// A recognizer cancels UIView delivery when it takes ownership. Ignore that synthetic
    /// cancellation; regular begin/move/end are idempotent in the shared capture methods.
    func isTracking(_ touch: UITouch) -> Bool { active.contains(ObjectIdentifier(touch)) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === owner
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { active.insert(ObjectIdentifier(t)) }
        owner?.captureBegan(touches, event: event)
        state = state == .possible ? .began : .changed
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        owner?.captureMoved(touches, event: event)
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        owner?.captureEnded(touches, event: event)
        for t in touches { active.remove(ObjectIdentifier(t)) }
        state = active.isEmpty ? .ended : .changed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        owner?.captureCancelled(touches, event: event)
        for t in touches { active.remove(ObjectIdentifier(t)) }
        if active.isEmpty { state = .cancelled }
    }
    override func reset() { active.removeAll(); super.reset() }
}


/// A short history of real touches. Spacing the control points gives dense samples at a
/// tight corner room to bend, while the last point always follows the finger.
struct SwipeTrailGeometry {
    struct Sample {
        var point: CGPoint
        var time: CFTimeInterval

        func mixed(with other: Self, fraction: CGFloat) -> Self {
            Sample(point: CGPoint(x: point.x + (other.point.x - point.x) * fraction,
                                  y: point.y + (other.point.y - point.y) * fraction),
                   time: time + (other.time - time) * fraction)
        }
    }

    static let capacity = 96
    private(set) var samples: [Sample] = []

    mutating func append(_ point: CGPoint, at time: CFTimeInterval, lifetime: CFTimeInterval) {
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { return }
        if let last = samples.last {
            guard time >= last.time else { return }
            if time - last.time >= lifetime { samples.removeAll(keepingCapacity: true) }
            else if point == last.point { return }
        }
        if samples.count >= 2 {
            let anchor = samples[samples.count - 2].point
            let tip = samples[samples.count - 1].point
            let dx = tip.x - anchor.x, dy = tip.y - anchor.y
            if hypot(dx, dy) < 10, dx * (point.x - tip.x) + dy * (point.y - tip.y) > 0 {
                samples.removeLast()
            }
        }
        if samples.count == Self.capacity { samples.removeFirst() }
        samples.append(Sample(point: point, time: time))
    }

    /// Sweep discs along the rounded centerline. The common tangents meet each disc at
    /// the same angle on both edges, even when one sample is much older than its neighbor.
    func outline(at now: CFTimeInterval, lifetime: CFTimeInterval, width: CGFloat) -> CGPath? {
        guard samples.count > 1, let tip = samples.last, now - tip.time < lifetime,
              let live = samples.firstIndex(where: { now - $0.time < lifetime }) else { return nil }
        let start = max(0, live - 1)
        let path = CGMutablePath()
        var pen = samples[start]
        func radius(_ sample: Sample) -> CGFloat {
            width / 2 * max(0, min(1, 1 - (now - sample.time) / lifetime))
        }
        func draw(to end: Sample) {
            var begin = pen
            pen = end
            let cutoff = now - lifetime
            guard end.time > cutoff else { return }
            if begin.time < cutoff {
                begin = begin.mixed(with: end, fraction: (cutoff - begin.time) / (end.time - begin.time))
            }
            let a = radius(begin), b = radius(end)
            let dx = end.point.x - begin.point.x, dy = end.point.y - begin.point.y
            let distance = hypot(dx, dy)
            if distance <= b - a {
                path.move(to: CGPoint(x: end.point.x + b, y: end.point.y))
                path.addArc(center: end.point, radius: b, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            } else {
                let angle = atan2(dy, dx), spread = acos((a - b) / distance)
                let lower = angle - spread, upper = angle + spread
                path.move(to: CGPoint(x: begin.point.x + a * cos(lower), y: begin.point.y + a * sin(lower)))
                path.addArc(center: end.point, radius: b, startAngle: lower, endAngle: upper, clockwise: false)
                if a > 0 {
                    path.addArc(center: begin.point, radius: a, startAngle: upper, endAngle: lower, clockwise: false)
                }
            }
            path.closeSubpath()
        }
        for index in (start + 1)..<samples.count {
            let control = samples[index - 1]
            let end = control.mixed(with: samples[index], fraction: 0.5)
            let begin = pen
            // The first half segment is straight. At a reversal, round the cap at
            // the actual fingertip instead of cutting back inside the corner.
            if index == start + 1 {
                draw(to: end)
                continue
            }
            let incoming = CGVector(dx: control.point.x - begin.point.x, dy: control.point.y - begin.point.y)
            let outgoing = CGVector(dx: end.point.x - control.point.x, dy: end.point.y - control.point.y)
            if incoming.dx * outgoing.dx + incoming.dy * outgoing.dy
                < -0.5 * hypot(incoming.dx, incoming.dy) * hypot(outgoing.dx, outgoing.dy) {
                draw(to: control)
                draw(to: end)
                continue
            }
            // Bound the gap between a chord and the true curve to 0.04 pt. A fixed
            // number of chords showed flat sides on sparse, fast reversals.
            let bend = hypot(begin.point.x - 2 * control.point.x + end.point.x,
                             begin.point.y - 2 * control.point.y + end.point.y)
            let steps = Int(min(64, max(1, ceil(sqrt(bend / 0.16)))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                draw(to: begin.mixed(with: control, fraction: t)
                    .mixed(with: control.mixed(with: end, fraction: t), fraction: t))
            }
        }
        draw(to: tip)
        return path
    }
}

/// Draws Rainbow Road: colored centerline pieces, clipped to the trail's outline. It sizes
/// itself to the outline's bounds each frame so only the few points under the trail redraw.
final class RainbowRibbonLayer: CALayer {
    struct Stroke {
        var from: CGPoint
        var to: CGPoint
        var color: CGColor
    }

    private var outline: CGPath?
    private var strokes: [Stroke] = []

    override init() {
        super.init()
        contentsScale = UITraitCollection.current.displayScale
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(path: CGPath?, strokes: [Stroke]) {
        outline = path
        self.strokes = strokes
        guard let path, !path.isEmpty else {
            contents = nil
            frame = .zero
            return
        }
        let box = path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).integral
        if frame != box { frame = box }
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        guard let outline else { return }
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.addPath(outline)
        context.clip()
        // Square caps: each piece runs on under the next, so antialiased ends leave no hairline,
        // and the straight overlap of two near-identical hues shows no band (round caps did).
        context.setLineCap(.square)
        // Wider than the head, so the clip and not the stroke decides the edge.
        let width = SwipeTrailLayer.headWidth * 1.5
        context.setLineWidth(width)
        for stroke in strokes {
            context.setStrokeColor(stroke.color)
            context.move(to: stroke.from)
            context.addLine(to: stroke.to)
            context.strokePath()
        }
        // The round head reaches past the last piece; fill it in the fingertip's color.
        if let head = strokes.last {
            context.setFillColor(head.color)
            context.fillEllipse(in: CGRect(origin: head.to, size: .zero).insetBy(dx: -width, dy: -width))
        }
    }
}

@MainActor
final class SwipeTrailLayer: CALayer {
    static let lifetime: CFTimeInterval = 0.24
    static let groupOpacity: Float = 0.62
    static let headWidth: CGFloat = 8
    /// Rainbow Road: finger travel, in points, for one full turn of the hue wheel.
    static let rainbowWavelength: CGFloat = 260
    private let ribbon = CAShapeLayer()
    private let rainbow = RainbowRibbonLayer()
    private var geometry = SwipeTrailGeometry()
    private var trailStyle = SwipeTrailStyle.accent
    /// Total finger travel, kept across gestures so each swipe picks the rainbow up where the
    /// last one left it instead of always starting on the same color.
    private(set) var travel: CGFloat = 0
    private var lastPoint: CGPoint?
    private var clock: CADisplayLink?
    private var releasedAt: CFTimeInterval?
    private var visibleLifetime = lifetime

    override init() {
        super.init()
        actions = KeyBalloonLayer.noActions
        ribbon.actions = KeyBalloonLayer.noActions
        opacity = Self.groupOpacity
        addSublayer(ribbon)
        rainbow.actions = KeyBalloonLayer.noActions
        rainbow.isHidden = true
        addSublayer(rainbow)
    }

    /// The Rainbow Road color after `travel` points of finger movement.
    static func rainbowColor(travel: CGFloat) -> UIColor {
        let turn = travel / rainbowWavelength
        return UIColor(hue: turn - turn.rounded(.down), saturation: 0.8, brightness: 1, alpha: 1)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() {
        clock?.invalidate()
        clock = nil
        releasedAt = nil
        geometry = SwipeTrailGeometry()
        lastPoint = nil
        ribbon.path = nil
        rainbow.update(path: nil, strokes: [])
    }

    func append(_ point: CGPoint, color: UIColor, style: SwipeTrailStyle = .accent,
                now: CFTimeInterval = CACurrentMediaTime()) {
        visibleLifetime = UIAccessibility.isReduceMotionEnabled ? 0.12 : Self.lifetime
        if point.x.isFinite, point.y.isFinite {
            if let lastPoint { travel += hypot(point.x - lastPoint.x, point.y - lastPoint.y) }
            lastPoint = point
            // Wrap whole turns so the value never grows large enough to lose precision.
            if travel > 1_000_000 { travel.formTruncatingRemainder(dividingBy: Self.rainbowWavelength) }
        }
        geometry.append(point, at: now, lifetime: visibleLifetime)
        trailStyle = style
        ribbon.fillColor = color.cgColor
        ribbon.isHidden = style == .rainbowRoad
        rainbow.isHidden = style != .rainbowRoad
        guard let tip = geometry.samples.last else { return }
        draw(at: tip.time)
    }

    private func draw(at time: CFTimeInterval) {
        if let path = geometry.outline(at: time, lifetime: visibleLifetime, width: Self.headWidth) {
            ribbon.path = path
        } else if let tip = geometry.samples.last, ribbon.path != nil {
            // A sampling gap has no connecting stroke, just the disc under the fingertip.
            let radius = Self.headWidth / 2 * max(0, 1 - (time - tip.time) / visibleLifetime)
            let bounds = CGRect(origin: tip.point, size: .zero).insetBy(dx: -radius, dy: -radius)
            ribbon.path = CGPath(ellipseIn: bounds, transform: nil)
        }
        if trailStyle == .rainbowRoad { rainbow.update(path: ribbon.path, strokes: rainbowStrokes()) }
    }

    /// The centerline in short pieces, each colored by the travel at its midpoint, counted back
    /// from the fingertip. The ribbon's outline clips them, so the taper and round head stay
    /// exactly the accent trail's and the color follows the path around every bend.
    private func rainbowStrokes() -> [RainbowRibbonLayer.Stroke] {
        let samples = geometry.samples
        guard let tip = samples.last else { return [] }
        if samples.count == 1 {
            return [.init(from: tip.point, to: tip.point, color: Self.rainbowColor(travel: travel).cgColor)]
        }
        var strokes: [RainbowRibbonLayer.Stroke] = []
        strokes.reserveCapacity(samples.count)
        var along = travel
        for index in stride(from: samples.count - 1, to: 0, by: -1) {
            let end = samples[index].point, begin = samples[index - 1].point
            let length = hypot(end.x - begin.x, end.y - begin.y)
            // Pieces of at most 2 pt turn the hue under 1% each, so no band shows between them.
            let pieces = max(1, Int((length / 2).rounded(.up)))
            for piece in 0..<pieces {
                let t0 = CGFloat(piece) / CGFloat(pieces), t1 = CGFloat(piece + 1) / CGFloat(pieces)
                let from = CGPoint(x: end.x + (begin.x - end.x) * t0, y: end.y + (begin.y - end.y) * t0)
                let to = CGPoint(x: end.x + (begin.x - end.x) * t1, y: end.y + (begin.y - end.y) * t1)
                strokes.append(.init(from: from, to: to,
                                     color: Self.rainbowColor(travel: along - length * (t0 + t1) / 2).cgColor))
            }
            along -= length
        }
        // Drawn tail first, so the fingertip's color is always on top where pieces overlap.
        return strokes.reversed()
    }

    func endStroke() {
        guard ribbon.path != nil, clock == nil else { return }
        releasedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(refresh))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        clock = link
    }

    @objc private func refresh() {
        guard let releasedAt, let tip = geometry.samples.last else { return }
        let now = tip.time + (CACurrentMediaTime() - releasedAt)
        if now - tip.time < visibleLifetime {
            draw(at: now)
        } else {
            clear()
        }
    }
}
