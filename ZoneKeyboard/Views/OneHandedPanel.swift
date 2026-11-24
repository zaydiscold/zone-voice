// by zayd/cold @ zayd.wtf

import UIKit
import ZoneCore

/// The strip beside the keys in one-handed mode. Two targets, each half its height so they are
/// easy to hit without looking: the top moves the keys to the other side, the bottom brings the
/// full keyboard back with the outward chevron Apple's own one-handed keyboard uses. The keys own
/// a margin into this strip (`KeyGridView.edgeSlop`), so an overshooting thumb types, not switches.
@MainActor
final class OneHandedPanel: UIView {
    private let flip = UIButton(type: .system)
    private let expand = UIButton(type: .system)
    /// The side the panel is on, which is the side the keys are not on.
    private(set) var side: OneHandedSide = .left
    var onChoose: ((KeyboardHand) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Not clear: the keyboard's remote host drops touches on fully transparent pixels.
        backgroundColor = UIColor.black.withAlphaComponent(0.001)
        for button in [flip, expand] {
            var config = UIButton.Configuration.plain()
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            config.background.cornerRadius = KeyboardTheme.cornerRadius
            button.configuration = config
            addSubview(button)
        }
        flip.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // The keys go where the panel is.
            self.onChoose?(KeyboardHand(self.side))
        }, for: .touchUpInside)
        expand.addAction(UIAction { [weak self] _ in self?.onChoose?(.full) }, for: .touchUpInside)
        flip.accessibilityIdentifier = "oneHanded.flip"
        expand.accessibilityIdentifier = "oneHanded.expand"
        expand.accessibilityLabel = KeyboardHand.full.label
        configure(side: .left, isDark: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(side: OneHandedSide, isDark: Bool) {
        self.side = side
        let color = UIColor(KeyboardTheme(isDark: isDark).text).withAlphaComponent(0.72)
        flip.configuration?.image = UIImage(systemName: KeyboardHand(side).symbolName)
        flip.accessibilityLabel = side == .left ? "Move keys to the left" : "Move keys to the right"
        expand.configuration?.image = UIImage(systemName: side == .left ? "chevron.compact.left" : "chevron.compact.right")
        expand.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        for button in [flip, expand] { button.tintColor = color }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let half = (bounds.height / 2).rounded(.down)
        flip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: half)
        expand.frame = CGRect(x: 0, y: half, width: bounds.width, height: bounds.height - half)
    }
}
