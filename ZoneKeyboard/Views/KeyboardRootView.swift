// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Two faces. Type: the status strip handles recording and processing above usable keys.
/// Dictate: a two-level signal and recovery panel at the controller's shorter height. The keyboard key on either face flips between
/// them. The background is left clear so the input view's own keyboard backdrop shows, which
/// removes the seam above the system's globe row.
struct KeyboardRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: KeyboardModel
    let mic: MicController
    weak var controller: UIInputViewController?

    @Environment(\.openURL) private var openURL

    /// 36 pt controls with 4 pt above and below. iOS draws about 17 pt of keyboard glass above
    /// the extension's window that no keyboard can use (measured on device 2026-11-01: the
    /// window starts at y 0 with zero insets), so the strip spends nothing more on top space.
    static let stripHeight: CGFloat = 40
    /// The key grid's side inset; the strip aligns its edge controls to the same line so the
    /// strip and the rows read as one block.
    static let sideInset: CGFloat = 6.5

    var body: some View {
        // The field's explicit light or dark request wins; otherwise the system style.
        let isDark = model.explicitDark ?? model.systemDark
        // Read so an accent change after the strip was drawn runs this body again; the new
        // theme carries the new accent and every view handed it redraws.
        let _ = model.appearanceVersion
        let theme = KeyboardTheme(isDark: isDark)
        Group {
            if mic.mode == .dictate {
                StatusBarView(model: model, mic: mic, theme: theme) { openZone() }
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    StatusBarView(model: model, mic: mic, theme: theme) { openZone() }
                    if mic.showsHistory {
                        HistoryPanelView(mic: mic, theme: theme)
                            .transition(.opacity)
                    } else {
                        keyGridSpace
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, isDark ? .dark : .light)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mic.showsSurface)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mic.showsHistory)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: mic.mode)
        .onAppear {
            // The action alone: naming the `openURL` property captures this whole view, model
            // included, and the model storing that closure kept every model alive.
            let action = openURL
            model.openURLFallback = { url in action(url) }
        }
    }

    private func openZone() {
        (controller as? KeyboardViewController)?.openZone()
    }

    /// The key rows' place. The keys themselves are `KeyGridView`, a UIKit view the controller
    /// lays over this one, so touches reach them without SwiftUI hit testing and a shift change
    /// does not re-render the grid. It shows and hides itself with the face and the history panel.
    private var keyGridSpace: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}
