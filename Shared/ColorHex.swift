// by zayd/cold @ zayd.wtf

import SwiftUI

extension Color {
    /// An sRGB color from a 0xRRGGBB literal, for the app's palette and the keyboard's theme.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
