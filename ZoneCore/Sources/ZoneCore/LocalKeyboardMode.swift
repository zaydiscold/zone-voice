// by zayd/cold @ zayd.wtf

import Foundation

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
