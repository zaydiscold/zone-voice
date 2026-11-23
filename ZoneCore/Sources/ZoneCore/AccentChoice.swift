// by zayd/cold @ zayd.wtf

import Foundation

/// The one accent color, chosen in Settings and read by the app and the keyboard from the App
/// Group, so a change recolors both. `hex` is the bright tone for dark surfaces and fills;
/// `textHexOnLight` is a deeper tone of the same hue that keeps 4.5:1 on Zone's cream paper.
public enum AccentChoice: String, CaseIterable, Sendable {
    case violet, ice, ember, mint, rose

    public var label: String {
        switch self {
        case .violet: return "Violet"
        case .ice: return "Ice"
        case .ember: return "Ember"
        case .mint: return "Mint"
        case .rose: return "Rose"
        }
    }

    public var hex: UInt32 {
        switch self {
        case .violet: return 0x9B7DFF
        case .ice: return 0x8EE8FF   // frost: pale, luminous cyan
        case .ember: return 0xFF9A6B  // rich pastel coral-orange
        case .mint: return 0xA9DEC4
        case .rose: return 0xF2B8CF
        }
    }

    public var textHexOnLight: UInt32 {
        switch self {
        case .violet: return 0x6A4BDB
        case .ice: return 0x0A6B84
        case .ember: return 0xA6461E
        case .mint: return 0x32644D
        case .rose: return 0x923D61
        }
    }

    /// The accent as a shape on a light surface (the live wave, the level bars, the swipe trail):
    /// the same hue, saturated and lowered until it holds 3:1 against the light keyboard backdrop
    /// (#D1D3D9) and Zone's cream paper. The pale `hex` reads 1.1 to 2.4:1 there, a tint and not a
    /// color; `textHexOnLight` is tuned for text and goes dull on a filled shape.
    public var graphicHexOnLight: UInt32 {
        switch self {
        case .violet: return 0x7A52FF
        case .ice: return 0x007D9D
        case .ember: return 0xD14200
        case .mint: return 0x16844E
        case .rose: return 0xDB246D
        }
    }

    /// Dark ink stays readable on every pastel fill, in both appearances.
    public var foregroundHex: UInt32 { 0x262626 }

    public static let defaultsKey = "zone.settings.accent"

    private static let shared = UserDefaults(suiteName: ZoneContract.appGroup)

    public static var current: AccentChoice {
        get { stored ?? .violet }
        set { shared?.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The choice in the App Group, nil when it gave nothing back (never chosen, or unreadable).
    public static var stored: AccentChoice? {
        shared?.string(forKey: defaultsKey).flatMap(AccentChoice.init(rawValue:))
    }
}

/// The keyboard's own copy of the last accent it read, in the keyboard's container. A fresh
/// keyboard process whose first App Group read comes back empty keeps the color the person chose
/// instead of drawing violet for that appearance (the same fault as `LastKeyboardPreferences`).
public struct LastAccentChoice {
    static let key = "zone.keyboard.lastAccent"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func resolve(stored: AccentChoice?) -> AccentChoice {
        let last = defaults.string(forKey: Self.key).flatMap(AccentChoice.init(rawValue:))
        guard let stored else { return last ?? .violet }
        if stored != last { defaults.set(stored.rawValue, forKey: Self.key) }
        return stored
    }
}

/// The keyboard's face (keys or the compact dictation surface), kept in the keyboard's own
/// container. Only the keyboard reads or writes it, and the App Group is out of reach without Full
/// Access and can read empty in a fresh process, which opened the keys and then jumped to the
/// compact face. The App Group copy is still written, and read once for a keyboard that has no
/// local value yet.
public struct LocalKeyboardMode {
    static let key = "zone.keyboard.mode"
    private let defaults: UserDefaults
    private let store: SharedStore

    public init(store: SharedStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public var mode: KeyboardMode {
        get { defaults.string(forKey: Self.key).flatMap(KeyboardMode.init(rawValue:)) ?? store.keyboardMode }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
            store.keyboardMode = newValue
        }
    }
}
