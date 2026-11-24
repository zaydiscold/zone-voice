// by zayd/cold @ zayd.wtf

import Foundation

/// The one accent color, chosen in Settings and read by the app and the keyboard from the App
/// Group on iPhone, and mirrored to Watch through WatchConnectivity.
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

    public var lightHex: UInt32 {
        switch self {
        case .violet: return 0x7149E8
        case .ice: return 0x007D9D
        case .ember: return 0xD14200
        case .mint: return 0x0E8657
        case .rose: return 0xC44068
        }
    }

    public var darkHex: UInt32 {
        switch self {
        case .violet: return 0xC48AFF
        case .ice: return 0xA5D6E4
        case .ember: return 0xFFA341
        case .mint: return 0x8CE6BE
        case .rose: return 0xF6ACBE
        }
    }

    /// Broad colored controls share a fill and ink pair. Outlines and text still use the
    /// surface-specific graphic accent so they stay readable on light paper.
    public func controlFillHex(isDark: Bool) -> UInt32 {
        switch (self, isDark) {
        case (.ice, false): 0x8EE8FF
        case (.ice, true): 0x9BC9D5
        case (.ember, false): 0xFF9A6B
        case (.violet, true): 0xAA73FF
        default: isDark ? darkHex : lightHex
        }
    }

    public func controlInkHex(isDark: Bool) -> UInt32 {
        isDark || self == .ice || self == .ember ? foregroundHex : 0xFFFFFF
    }

    /// Label ink on dark-mode accent fills.
    public var foregroundHex: UInt32 { 0x262626 }

    public static let defaultChoice: Self = .violet

    public static let defaultsKey = "zone.settings.accent"

    private static let shared = UserDefaults(suiteName: AppGroup.identifier)

    public static var current: AccentChoice {
        get { stored ?? defaultChoice }
        set { shared?.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The choice in the App Group, nil when it gave nothing back (never chosen, or unreadable).
    public static var stored: AccentChoice? {
        shared?.string(forKey: defaultsKey).flatMap(AccentChoice.init(rawValue:))
    }
}

/// The last choice read by an extension, kept in its own container so an empty App Group
/// read can preserve the person's color while access is settling.
public struct LastAccentChoice {
    // Preserve the key shipped by the keyboard. Each extension has its own defaults domain.
    static let key = "zone.keyboard.lastAccent"

    public static var current: AccentChoice { Self().resolve(stored: AccentChoice.stored) }
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func resolve(stored: AccentChoice?) -> AccentChoice {
        let last = defaults.string(forKey: Self.key).flatMap(AccentChoice.init(rawValue:))
        guard let stored else { return last ?? AccentChoice.defaultChoice }
        if stored != last { defaults.set(stored.rawValue, forKey: Self.key) }
        return stored
    }
}
