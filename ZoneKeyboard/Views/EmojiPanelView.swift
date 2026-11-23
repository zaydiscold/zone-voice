// by zayd/cold @ zayd.wtf

import Observation
import UIKit
import ZoneCore

/// Emoji in place of the keys, opened by the emoji key left of space (Settings > Keyboard >
/// Emoji key). A keyboard extension cannot switch to Apple's emoji keyboard (it can only go to
/// the next keyboard or show the keyboard list), so Zone draws its own, laid out like Apple's:
/// the category name at the top, columns that scroll sideways, and a bottom row of ABC, the
/// category tabs and delete. Hold an emoji with skin tones to pick one; the choice is
/// remembered, as on iOS.
///
/// UIKit, like `KeyGridView` and for the same reason: about 1,900 cells in reused views, and
/// touches that never walk SwiftUI hit testing.
@MainActor
final class EmojiPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let model: KeyboardModel
    private let mic: MicController

    /// Apple's tab symbols, by category name. Recents first.
    static let recentsName = "Frequently Used"
    private static let symbols: [String: String] = [
        recentsName: "clock",
        "Smileys & People": "face.smiling",
        "Animals & Nature": "pawprint",
        "Food & Drink": "fork.knife",
        "Activity": "soccerball",
        "Travel & Places": "car",
        "Objects": "lightbulb",
        "Symbols": "heart",
        "Flags": "flag",
    ]
    static let toneNames = ["Light Skin Tone", "Medium-Light Skin Tone", "Medium Skin Tone", "Medium-Dark Skin Tone", "Dark Skin Tone"]

    private struct Section {
        let name: String
        /// What each cell shows and types; for an emoji with tones, the remembered tone.
        var items: [String]
        /// The catalog emoji behind each cell (nil for a recent the catalog no longer has).
        var emoji: [Emoji?]
    }

    private var sections: [Section] = []
    private let layout = UICollectionViewFlowLayout()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let titleLabel = UILabel()
    /// Where stickers, Memoji and Genmoji are: Apple's emoji keyboard. A keyboard extension can
    /// show the keyboard list but cannot open Apple's sticker drawer itself, so the panel says
    /// how to get there instead of pretending to.
    private let stickerHint = UILabel()
    /// The system's globe, for phones where iOS asks the keyboard to draw it (no globe under
    /// the keyboard). Without it the panel would hide the only way to another keyboard.
    private let globeButton = UIButton(type: .system)
    private weak var controller: UIInputViewController?
    private let abcKey = EmojiPanelKey()
    private let deleteKey = EmojiRepeatKey()
    private var tabs: [UIButton] = []
    private let toneView = EmojiToneView()
    /// Where each section starts in the scroll content, refreshed after layout.
    private var sectionStarts: [CGFloat] = []
    /// The tab last tapped wins until the user scrolls by hand: near the end of the content a
    /// short section (Flags) can never reach the left edge to claim the highlight.
    private var pinnedSection: Int?
    private var currentSection = -1
    private var shownVisible: Bool?
    private var isDark = false
    /// The style the colors were last set for; nil until the first pass.
    private var appliedDark: Bool?
    private var keyFill = UIColor.white
    private var pressedFill = UIColor.white
    private var textColor = UIColor.black
    private var secondaryColor = UIColor.gray
    private var emojiFontSize: CGFloat = 28
    private var lastLayoutSize: CGSize = .zero

    static let barHeight: CGFloat = 40
    static let titleHeight: CGFloat = 20
    static let sideInset = KeyboardRootView.sideInset

    init(model: KeyboardModel, mic: MicController, controller: UIInputViewController?) {
        self.model = model
        self.mic = mic
        self.controller = controller
        super.init(frame: .zero)
        // Not clear, as for the key grid: the remote host drops touches on transparent pixels.
        backgroundColor = UIColor.black.withAlphaComponent(0.001)
        clipsToBounds = false
        alpha = 0
        isHidden = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)

        stickerHint.textAlignment = .right
        stickerHint.adjustsFontSizeToFitWidth = true
        stickerHint.minimumScaleFactor = 0.75
        stickerHint.isAccessibilityElement = true
        stickerHint.accessibilityLabel = "Stickers, Memoji and Genmoji are in Apple's emoji keyboard. Hold the globe key and choose Emoji."
        addSubview(stickerHint)

        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        grid.dataSource = self
        grid.delegate = self
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseID)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        grid.addGestureRecognizer(hold)
        addSubview(grid)

        abcKey.setTitle("ABC", for: .normal)
        abcKey.titleLabel?.font = .systemFont(ofSize: 16)
        abcKey.accessibilityLabel = "Letters"
        abcKey.addTarget(self, action: #selector(keyDown), for: .touchDown)
        abcKey.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(abcKey)

        // As in the key grid: the system globe with handleInputModeList, as App Review 4.4.1 asks.
        var globe = UIButton.Configuration.plain()
        globe.image = UIImage(systemName: "globe")
        globe.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17)
        globeButton.configuration = globe
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.layer.cornerRadius = KeyboardTheme.cornerRadius
        globeButton.layer.cornerCurve = .continuous
        globeButton.isHidden = true
        if let controller {
            globeButton.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        addSubview(globeButton)

        deleteKey.onDown = { [weak self] in self?.model.keyDown(.delete) }
        deleteKey.onUp = { [weak self] in
            self?.model.endDeleteRepeat()
            self?.mic.userTypedKey()
        }
        addSubview(deleteKey)

        toneView.isHidden = true
        toneView.onChoose = { [weak self] text in self?.type(text) }
        addSubview(toneView)

        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EmojiPanelView, _) in view.applyTheme() }
        observe()
        syncVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model state

    /// Re-arms after every change: Observation reports once per registration.
    private func observe() {
        withObservationTracking {
            _ = model.showsEmoji
            _ = model.explicitDark
            _ = model.needsGlobe
            _ = mic.mode
            _ = mic.showsHistory
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.syncVisibility(animated: true)
                self.applyTheme()
                self.setNeedsLayout()
            }
        }
    }

    private var shouldShow: Bool { model.showsEmoji && mic.mode == .type && !mic.showsHistory }

    private func syncVisibility(animated: Bool) {
        let visible = shouldShow
        guard visible != shownVisible else { return }
        shownVisible = visible
        isUserInteractionEnabled = visible
        if visible {
            isHidden = false
            applyTheme()
            EmojiStore.load { [weak self] in self?.reload(openAtStart: true) }
        } else {
            hideTones()
            deleteKey.cancel()
        }
        let apply = { self.alpha = visible ? 1 : 0 }
        let done = { (_: Bool) in if self.shownVisible == false { self.isHidden = true } }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: apply, completion: done)
        } else {
            apply()
            done(true)
        }
    }

    private func applyTheme() {
        let dark = model.explicitDark ?? (traitCollection.userInterfaceStyle == .dark)
        guard dark != appliedDark else { return }
        appliedDark = dark
        isDark = dark
        let theme = KeyboardTheme(isDark: dark)
        keyFill = UIColor(theme.key)
        pressedFill = UIColor(theme.pressedKey)
        textColor = UIColor(theme.text)
        secondaryColor = UIColor(theme.secondaryText)
        titleLabel.textColor = secondaryColor
        stickerHint.attributedText = Self.hintText(color: secondaryColor)
        globeButton.tintColor = textColor
        globeButton.backgroundColor = keyFill
        abcKey.setTitleColor(textColor, for: .normal)
        abcKey.apply(fill: keyFill, pressed: pressedFill)
        deleteKey.apply(fill: keyFill, pressed: pressedFill, tint: textColor)
        toneView.apply(fill: keyFill, pressed: pressedFill, isDark: dark)
        updateTabColors()
    }

    // MARK: Content

    /// Recents are a snapshot from when the panel opened, so nothing moves under the finger.
    private func reload(openAtStart: Bool) {
        guard let catalog = EmojiStore.catalog else { return }
        let history = EmojiStore.history
        let recents = history.recents(in: EmojiStore.baseIndex)
        var built = [Section(name: Self.recentsName, items: recents,
                             emoji: recents.map { EmojiStore.baseIndex[$0].flatMap { EmojiStore.byBase[$0] } })]
        for category in catalog.categories {
            built.append(Section(name: category.name, items: category.emoji.map(history.shown), emoji: category.emoji))
        }
        let names = built.map(\.name)
        sections = built
        if tabs.map(\.accessibilityLabel) != names { rebuildTabs(names) }
        grid.reloadData()
        if openAtStart {
            pinnedSection = nil
            setNeedsLayout()
            layoutIfNeeded()
            grid.layoutIfNeeded()
            measureSections()
            grid.contentOffset = .zero
            showSection(recents.isEmpty ? 1 : 0)
        }
    }

    /// Only the tone a cell shows changed; offsets and recents stay where they are.
    private func refreshShownTones() {
        let history = EmojiStore.history
        for s in sections.indices where s > 0 {
            sections[s].items = sections[s].emoji.map { $0.map(history.shown) ?? "" }
        }
        let visible = grid.indexPathsForVisibleItems.filter { $0.section > 0 }
        UIView.performWithoutAnimation { grid.reloadItems(at: visible) }
    }

    private func rebuildTabs(_ names: [String]) {
        tabs.forEach { $0.removeFromSuperview() }
        tabs = names.enumerated().map { index, name in
            let button = UIButton(type: .custom)
            let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            button.setImage(UIImage(systemName: Self.symbols[name] ?? "circle", withConfiguration: config), for: .normal)
            button.accessibilityLabel = name
            button.tag = index
            button.addTarget(self, action: #selector(keyDown), for: .touchDown)
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            addSubview(button)
            return button
        }
        currentSection = -1
        updateTabColors()
        setNeedsLayout()
    }

    private func updateTabColors() {
        for (index, tab) in tabs.enumerated() {
            let selected = index == currentSection
            tab.tintColor = selected ? textColor : secondaryColor
            tab.backgroundColor = selected ? pressedFill.withAlphaComponent(isDark ? 0.9 : 1) : .clear
            tab.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let inset = Self.sideInset
        let barY = bounds.height - Self.barHeight
        let gridHeight = max(barY - Self.titleHeight - 2, 1)
        let rows: CGFloat = gridHeight / 5 >= 29 ? 5 : 4
        let cellHeight = floor(gridHeight / rows)
        let cellWidth = floor((bounds.width - 2 * inset) / 8.5)
        emojiFontSize = floor(min(cellHeight, cellWidth) * 0.76)
        let titleWidth = min(titleLabel.intrinsicContentSize.width, (bounds.width - 2 * inset - 12) * 0.45)
        titleLabel.frame = CGRect(x: inset + 6, y: 2, width: titleWidth, height: Self.titleHeight)
        let hintX = titleLabel.frame.maxX + 8
        stickerHint.frame = CGRect(x: hintX, y: 2, width: bounds.width - inset - 6 - hintX, height: Self.titleHeight)
        let gridFrame = CGRect(x: 0, y: Self.titleHeight + 2, width: bounds.width, height: cellHeight * rows)
        if grid.frame != gridFrame || layout.itemSize != CGSize(width: cellWidth, height: cellHeight) {
            grid.frame = gridFrame
            grid.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            layout.itemSize = CGSize(width: cellWidth, height: cellHeight)
            layout.invalidateLayout()
        }

        // The bottom row: ABC and delete as keys at the grid's key height, the tabs between.
        let keyHeight: CGFloat = 34
        let keyWidth = floor((bounds.width - 2 * inset) / 10 * 1.29)
        let keyY = barY + (Self.barHeight - keyHeight) / 2
        abcKey.frame = CGRect(x: inset, y: keyY, width: keyWidth, height: keyHeight)
        deleteKey.frame = CGRect(x: bounds.width - inset - keyWidth, y: keyY, width: keyWidth, height: keyHeight)
        var leadingEdge = abcKey.frame.maxX
        if model.needsGlobe {
            globeButton.frame = CGRect(x: leadingEdge + 4, y: keyY, width: 38, height: keyHeight)
            globeButton.isHidden = false
            leadingEdge = globeButton.frame.maxX
        } else {
            globeButton.isHidden = true
        }
        let tabsMinX = leadingEdge + 4, tabsMaxX = deleteKey.frame.minX - 4
        let tabWidth = tabs.isEmpty ? 0 : (tabsMaxX - tabsMinX) / CGFloat(tabs.count)
        for (index, tab) in tabs.enumerated() {
            let side = min(tabWidth, keyHeight)
            tab.frame = CGRect(x: tabsMinX + CGFloat(index) * tabWidth + (tabWidth - side) / 2, y: keyY, width: side, height: keyHeight)
            tab.layer.cornerRadius = KeyboardTheme.cornerRadius
            tab.layer.cornerCurve = .continuous
        }
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            hideTones()
            grid.layoutIfNeeded()
            measureSections()
        }
    }

    /// "Stickers & Genmoji: hold (globe), pick Emoji", with the globe drawn as the symbol.
    private static func hintText(color: UIColor) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = NSMutableAttributedString(string: "Stickers & Genmoji: hold ", attributes: attributes)
        if let globe = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: globe)))
        } else {
            text.append(NSAttributedString(string: "globe", attributes: attributes))
        }
        text.append(NSAttributedString(string: ", pick Emoji", attributes: attributes))
        return text
    }

    private func measureSections() {
        sectionStarts = sections.indices.map { section in
            guard !sections[section].items.isEmpty,
                  let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: section)) else {
                // An empty section (no recents yet) starts where the next one does.
                return section + 1 < sections.count ? (layout.layoutAttributesForItem(at: IndexPath(item: 0, section: section + 1))?.frame.minX ?? 0) : 0
            }
            return first.frame.minX
        }
    }

    // MARK: Sections

    private var maxOffset: CGFloat {
        max(grid.contentSize.width + grid.contentInset.right - grid.bounds.width, -grid.contentInset.left)
    }

    private func sectionAtOffset() -> Int {
        if let pinnedSection { return pinnedSection }
        let x = grid.contentOffset.x + grid.contentInset.left + 1
        if grid.contentOffset.x >= maxOffset - 1 { return sections.count - 1 }
        var found = 0
        for (index, start) in sectionStarts.enumerated() where start <= x && !sections[index].items.isEmpty {
            found = index
        }
        return found
    }

    private func showSection(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        if index != currentSection {
            currentSection = index
            updateTabColors()
        }
        let name = sections[index].name
        guard titleLabel.accessibilityLabel != name else { return }
        titleLabel.text = name.uppercased()
        titleLabel.accessibilityLabel = name
        // The sticker hint takes the room the category name leaves.
        setNeedsLayout()
    }

    @objc private func tabTapped(_ sender: UIButton) {
        let index = sender.tag
        guard sectionStarts.indices.contains(index) else { return }
        hideTones()
        let target = min(sectionStarts[index] - grid.contentInset.left, maxOffset)
        grid.setContentOffset(CGPoint(x: max(target, -grid.contentInset.left), y: 0), animated: false)
        pinnedSection = index
        showSection(index)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pinnedSection = nil
        hideTones()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !sectionStarts.isEmpty else { return }
        showSection(sectionAtOffset())
    }

    // MARK: Typing

    @objc private func keyDown() {
        model.emojiPanelKeyDown()
    }

    @objc private func closeTapped() {
        hideTones()
        model.closeEmoji()
    }

    private func type(_ text: String) {
        guard !text.isEmpty else { return }
        hideTones()
        let before = EmojiStore.history.tones
        model.insertEmoji(text)
        mic.userTypedKey()
        EmojiStore.use(text)
        if EmojiStore.history.tones != before { refreshShownTones() }
    }

    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        model.emojiPanelKeyDown()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let text = item(at: indexPath) else { return }
        type(text)
    }

    private func item(at indexPath: IndexPath) -> String? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    // MARK: Skin tones

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: grid)
            guard let indexPath = grid.indexPathForItem(at: point),
                  let emoji = sections[indexPath.section].emoji[indexPath.item],
                  !emoji.tones.isEmpty,
                  let cell = grid.cellForItem(at: indexPath) else {
                // No tones: a held emoji types on release, as a tap would.
                return
            }
            // Lit on the tone the cell shows until the finger moves.
            showTones(for: emoji, shown: item(at: indexPath) ?? emoji.text, over: cell.convert(cell.bounds, to: self))
        case .changed:
            toneView.track(gesture.location(in: toneView))
        case .ended:
            if !toneView.isHidden {
                // Released on a tone types it; released elsewhere leaves the row open to tap.
                if let chosen = toneView.release(at: gesture.location(in: toneView)) { type(chosen) }
            } else if let indexPath = grid.indexPathForItem(at: gesture.location(in: grid)),
                      let text = item(at: indexPath) {
                type(text)
            }
        case .cancelled, .failed:
            hideTones()
        default:
            break
        }
    }

    private func showTones(for emoji: Emoji, shown: String, over cell: CGRect) {
        let options = [emoji.text] + emoji.tones.map(\.text)
        let side = max(layout.itemSize.width, 40)
        let size = CGSize(width: side * CGFloat(options.count) + 8, height: side + 8)
        // Above the held emoji, reaching into the strip if it must; clamped to the sides.
        let topLimit = -max(frame.minY, 0)
        var origin = CGPoint(x: cell.midX - size.width / 2, y: cell.minY - size.height - 4)
        origin.x = min(max(origin.x, Self.sideInset), bounds.width - Self.sideInset - size.width)
        origin.y = max(origin.y, topLimit)
        toneView.frame = CGRect(origin: origin, size: size)
        toneView.show(options, names: ["Default Skin Tone"] + Self.toneNames, selected: options.firstIndex(of: shown) ?? 0,
                      fontSize: emojiFontSize)
        toneView.isHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: toneView)
    }

    private func hideTones() {
        guard !toneView.isHidden else { return }
        toneView.isHidden = true
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    // MARK: Touches

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !toneView.isHidden, toneView.frame.contains(point) { return true }
        return bounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        // An open tone row takes the next touch: a tone, or anywhere else to close it.
        if !toneView.isHidden {
            return toneView.frame.contains(point) ? toneView : self
        }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        hideTones()
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseID, for: indexPath) as! EmojiCell
        let emoji = sections[indexPath.section].emoji[indexPath.item]
        cell.configure(item(at: indexPath) ?? "", fontSize: emojiFontSize, pressed: pressedFill,
                       tones: emoji.map { [$0.text] + $0.tones.map(\.text) } ?? [])
        cell.onChooseTone = { [weak self] text in self?.type(text) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        insetForSectionAt section: Int) -> UIEdgeInsets {
        // A gap between categories, none around an empty Frequently Used.
        guard !sections[section].items.isEmpty, section < sections.count - 1 else { return .zero }
        return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
    }
}

/// One emoji. VoiceOver reads the emoji's name from the character itself; tones are custom
/// actions, since VoiceOver users cannot hold and slide.
private final class EmojiCell: UICollectionViewCell {
    static let reuseID = "emoji"
    private let label = UILabel()
    var onChooseTone: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = false
        contentView.addSubview(label)
        contentView.layer.cornerRadius = KeyboardTheme.cornerRadius
        contentView.layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var pressedFill = UIColor.clear

    func configure(_ text: String, fontSize: CGFloat, pressed: UIColor, tones: [String]) {
        label.text = text
        if label.font.pointSize != fontSize { label.font = .systemFont(ofSize: fontSize) }
        pressedFill = pressed
        accessibilityLabel = text
        accessibilityCustomActions = tones.count == 6 ? zip(tones, ["Default Skin Tone"] + EmojiPanelView.toneNames).map { tone, name in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.onChooseTone?(tone)
                return true
            }
        } : nil
        updatePressed()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    override var isHighlighted: Bool {
        didSet { updatePressed() }
    }

    private func updatePressed() {
        contentView.backgroundColor = isHighlighted ? pressedFill : .clear
    }
}

/// The skin tone row over a held emoji. Follows the finger while held; once released it stays
/// open for a tap.
private final class EmojiToneView: UIView {
    var onChoose: ((String) -> Void)?
    private var options: [String] = []
    private var labels: [UILabel] = []
    private var highlighted: Int?
    private var pressedFill = UIColor.lightGray

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityViewIsModal = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(fill: UIColor, pressed: UIColor, isDark: Bool) {
        backgroundColor = fill
        pressedFill = pressed
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.5 : 0.25
        refresh()
    }

    func show(_ options: [String], names: [String], selected: Int, fontSize: CGFloat) {
        self.options = options
        labels.forEach { $0.removeFromSuperview() }
        let side = (bounds.width - 8) / CGFloat(max(options.count, 1))
        labels = options.enumerated().map { index, text in
            let label = UILabel(frame: CGRect(x: 4 + CGFloat(index) * side, y: 4, width: side, height: bounds.height - 8))
            label.text = text
            label.font = .systemFont(ofSize: fontSize)
            label.textAlignment = .center
            label.layer.cornerRadius = 8
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            label.isAccessibilityElement = true
            label.accessibilityLabel = "\(text), \(names[index])"
            label.accessibilityTraits = .keyboardKey
            addSubview(label)
            return label
        }
        accessibilityElements = labels
        highlighted = selected
        refresh()
    }

    /// The tone under a held finger; outside the row, the last one stays lit.
    func track(_ point: CGPoint) {
        guard let index = index(at: point, slack: 30) else { return }
        if index != highlighted {
            highlighted = index
            refresh()
        }
    }

    /// The tone to type when the finger lifts here, or nil to keep the row open. Lifting where
    /// the hold began, on the emoji under the row, leaves the row open, as on iOS.
    func release(at point: CGPoint) -> String? {
        guard let index = index(at: point, slack: 6) else { return nil }
        return options[index]
    }

    private func index(at point: CGPoint, slack: CGFloat) -> Int? {
        guard !options.isEmpty, point.y > -slack, point.y < bounds.height + slack,
              point.x >= 0, point.x < bounds.width else { return nil }
        let side = (bounds.width - 8) / CGFloat(options.count)
        return min(max(Int((point.x - 4) / side), 0), options.count - 1)
    }

    private func refresh() {
        for (index, label) in labels.enumerated() {
            label.backgroundColor = index == highlighted ? pressedFill : .clear
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        track(point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        track(point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), let text = release(at: point) else { return }
        onChoose?(text)
    }

    /// VoiceOver's two-finger scrub closes the row.
    override func accessibilityPerformEscape() -> Bool {
        isHidden = true
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        return true
    }
}

/// ABC in the emoji panel: a key cap that darkens while pressed.
private final class EmojiPanelKey: UIButton {
    private var fill = UIColor.white
    private var pressed = UIColor.lightGray

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = KeyboardTheme.cornerRadius
        layer.cornerCurve = .continuous
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(fill: UIColor, pressed: UIColor) {
        self.fill = fill
        self.pressed = pressed
        backgroundColor = isHighlighted ? pressed : fill
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? pressed : fill }
    }
}

/// Delete in the emoji panel: deletes on touch-down and repeats while held, through the same
/// model calls as the key grid's delete.
private final class EmojiRepeatKey: UIView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private let icon = UIImageView(image: UIImage(systemName: "delete.left",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)))
    private var fill = UIColor.white
    private var pressed = UIColor.lightGray
    private var isDown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = KeyboardTheme.cornerRadius
        layer.cornerCurve = .continuous
        icon.contentMode = .center
        addSubview(icon)
        isAccessibilityElement = true
        accessibilityLabel = "Delete"
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(fill: UIColor, pressed: UIColor, tint: UIColor) {
        self.fill = fill
        self.pressed = pressed
        icon.tintColor = tint
        backgroundColor = isDown ? pressed : fill
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isDown else { return }
        isDown = true
        backgroundColor = pressed
        onDown?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }

    /// Stops a held delete exactly once: released, cancelled, or the panel closing under it.
    func cancel() {
        guard isDown else { return }
        isDown = false
        backgroundColor = fill
        onUp?()
    }

    override func accessibilityActivate() -> Bool {
        onDown?()
        onUp?()
        return true
    }
}
