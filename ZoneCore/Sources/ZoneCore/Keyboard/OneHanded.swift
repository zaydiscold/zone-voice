// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// The thumb the one-handed keyboard is set up for, chosen in Settings.
public enum OneHandedSide: String, Codable, Sendable, CaseIterable {
    case left, right

    public var other: OneHandedSide { self == .left ? .right : .left }
    public var label: String { self == .left ? "Left" : "Right" }
}

/// Where the keyboard's keys sit right now: full width, or pushed toward one thumb. Chosen on the
/// keyboard itself (hold 123, or the arrows in the side panel) once Settings turns the mode on.
public enum KeyboardHand: String, Codable, Sendable, CaseIterable {
    case left, full, right

    public init(_ side: OneHandedSide) { self = side == .left ? .left : .right }

    public var side: OneHandedSide? {
        switch self {
        case .left: return .left
        case .right: return .right
        case .full: return nil
        }
    }

    /// The SF Symbol for this layout: the keyboard's picker, its side panel and the Settings preview.
    public var symbolName: String {
        switch self {
        case .left: return "keyboard.onehanded.left"
        case .full: return "keyboard"
        case .right: return "keyboard.onehanded.right"
        }
    }

    /// VoiceOver names, also the picker's.
    public var label: String {
        switch self {
        case .left: return "Keys on the left"
        case .full: return "Full width"
        case .right: return "Keys on the right"
        }
    }
}

/// The geometry of the one-handed keyboard.
///
/// The keys keep QWERTY and their full row height and are narrowed toward one edge. Measured and
/// read on 2026-11-19 (docs/research/2026-11-19-one-handed-keyboard.md):
/// - Apple's one-handed keyboard is 320 pt wide on a 402 pt phone (80 percent), keys at a 32 pt
///   pitch, row height unchanged. It has one fixed width; Zone's is adjustable.
/// - Narrowing hurts accuracy more than shortening (Kim et al. 2012), so rows keep their height.
/// - Curved one-thumb layouts lost to a narrowed QWERTY on errors and ratings in two of three
///   controlled studies, and Microsoft retired its Word Flow arc.
public enum OneHandedLayout {
    /// The keys' share of the keyboard's width by default: Apple's 320 pt on a 402 pt phone.
    public static let defaultWidth: Double = 0.80
    /// What Settings offers. Below 70 percent a letter key is under 4.6 mm on a 393 pt phone;
    /// above 90 percent the panel is too thin to hold its two buttons.
    public static let widthRange: ClosedRange<Double> = 0.70...0.90
    /// Phones narrower than this (an SE with Display Zoom, 320 pt) keep the full keyboard: a column
    /// there would make letters under 4 mm wide.
    public static let minimumWidth: CGFloat = 360
    /// Anything this wide is landscape or an iPad, where Apple does not offer the mode either.
    public static let maximumWidth: CGFloat = 500
    /// The side panel is never thinner than this, so its two buttons stay at least 44 pt targets.
    public static let minimumPanel: CGFloat = 36

    /// Whether a keyboard this wide can go one-handed at all.
    public static func isAvailable(width: CGFloat) -> Bool {
        width >= minimumWidth && width < maximumWidth
    }

    /// A width setting brought into range; anything unreadable is the default.
    public static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultWidth }
        return min(max(fraction, widthRange.lowerBound), widthRange.upperBound)
    }

    /// The keys' column inside a keyboard `width` points wide: its left edge and width, rounded to
    /// whole points. Nil when the keyboard stays full width (the hand is full, or the keyboard is
    /// too narrow or too wide for the mode).
    public static func column(width: CGFloat, fraction: Double, hand: KeyboardHand) -> (x: CGFloat, width: CGFloat)? {
        guard let side = hand.side, isAvailable(width: width) else { return nil }
        let keys = min((width * CGFloat(clamped(fraction))).rounded(), width - minimumPanel)
        return (side == .left ? 0 : width - keys, keys)
    }
}

/// The keyboard's own memory of where the keys sit, kept in the keyboard's container like
/// `LocalKeyboardMode`: the App Group cannot be written without Full Access, and the choice must
/// survive every app switch and relaunch (Apple's own setting resetting itself is a long-standing
/// complaint on Apple's forums).
///
/// Settings decides whether the mode exists and which thumb it starts on; the keyboard decides
/// the rest. When the Settings switch or side changes, the keyboard adopts it once and then keeps
/// whatever the person chooses on the keyboard.
public struct LocalKeyboardHand {
    static let handKey = "zone.keyboard.hand"
    static let seenKey = "zone.keyboard.handSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The hand for these preferences. Always full while Settings has the mode off.
    public func resolve(_ preferences: KeyboardPreferences) -> KeyboardHand {
        let signature = preferences.oneHandedEnabled ? preferences.oneHandedSide.rawValue : "off"
        if defaults.string(forKey: Self.seenKey) != signature {
            defaults.set(signature, forKey: Self.seenKey)
            let adopted: KeyboardHand = preferences.oneHandedEnabled ? KeyboardHand(preferences.oneHandedSide) : .full
            defaults.set(adopted.rawValue, forKey: Self.handKey)
            return adopted
        }
        guard preferences.oneHandedEnabled else { return .full }
        return defaults.string(forKey: Self.handKey).flatMap(KeyboardHand.init(rawValue:))
            ?? KeyboardHand(preferences.oneHandedSide)
    }

    /// A choice made on the keyboard.
    public func choose(_ hand: KeyboardHand) {
        defaults.set(hand.rawValue, forKey: Self.handKey)
    }
}
