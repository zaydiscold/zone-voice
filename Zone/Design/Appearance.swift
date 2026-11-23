// by zayd/cold @ zayd.wtf

import SwiftUI

/// Dark is the default. Light and Match iPhone are real and tested.
enum Appearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match iPhone"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
