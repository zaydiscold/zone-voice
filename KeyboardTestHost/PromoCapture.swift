// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

/// Used only by the keyboard QA app when recording its production views.
enum PromoCapture {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--promo")
    static let paper = UIColor(red: 42/255, green: 42/255, blue: 42/255, alpha: 1)
    static let ink = UIColor(red: 241/255, green: 233/255, blue: 210/255, alpha: 1)
}

/// Observes UIKit's delivered touches. It stays possible until the finger lifts,
/// so other recognizers and the grid keep ownership of the gesture.
final class PromoTouchIndicator: UIGestureRecognizer {
    private let dot = CALayer()
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let point = touches.first?.location(in: view) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        dot.removeAllAnimations()
        dot.bounds = CGRect(x: 0, y: 0, width: 19, height: 19)
        dot.cornerRadius = 9.5
        dot.borderWidth = 2
        dot.borderColor = UIColor.white.cgColor
        dot.backgroundColor = UIColor(KeyboardTheme.accent).withAlphaComponent(0.58).cgColor
        dot.position = point
        dot.opacity = 1
        dot.zPosition = 1000
        view.layer.addSublayer(dot)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let point = touches.first?.location(in: view) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = point
        CATransaction.commit()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        dot.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.26
        dot.add(fade, forKey: "release")
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        dot.removeFromSuperlayer()
        state = .failed
    }
}

struct PromoSuggestionRow: View {
    let model: KeyboardModel
    let theme: KeyboardTheme

    var body: some View {
        Group {
            if model.emojiSuggestions.isEmpty {
                SuggestionBar(suggestions: model.suggestions, theme: theme, onChoose: model.choose)
            } else {
                EmojiSuggestionBar(model: model, theme: theme)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 44)
        .background(theme.background)
    }
}
