// by zayd/cold @ zayd.wtf

import Foundation

public struct NumberPreferences: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case style, digits, words

        public var label: String {
            switch self {
            case .style: "Follow text style"
            case .digits: "Always digits"
            case .words: "Words under ten"
            }
        }
    }

    public var mode: Mode
    public var styles: Set<TextStyle>

    public init(mode: Mode = .style, styles: Set<TextStyle> = [.casual, .formal, .excited]) {
        self.mode = mode
        self.styles = styles
    }

    func small(in style: TextStyle) -> SpokenNumbers.Small {
        if mode != .style, styles.contains(style) {
            switch mode {
            case .digits: return .alwaysDigits
            case .words: return .words
            case .style: break
            }
        }
        return style.writesSmallNumbersAsDigits ? .digits : .asSaid
    }
}
