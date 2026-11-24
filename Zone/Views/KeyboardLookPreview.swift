// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct KeyboardLookPreview: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @AppStorage(DuoKeyboard.splitPreferenceKey, store: UserDefaults(suiteName: AppGroup.identifier)) private var split = false

    @StateObject private var keyboard = PreviewKeyboard()

    var displaySize: CGSize?
    var isDuo = DuoKeyboard.isCurrentDevice

    var body: some View {
        let screen = displaySize ?? UIScreen.main.bounds.size
        let width = screen.width
        let pose = DuoKeyboard(isDuo: isDuo, screen: screen)
        let metrics = pose.metrics(width: width, windowInset: 0)
        let height = StripKey.typingStripHeight + 4 + 3 * metrics.rowPitch + metrics.keyHeight + metrics.bottomInset
        let position = DuoKeyPlacement(pose: pose, width: width, center: width / 2, side: metrics.sideInset,
                                       safeLeft: 0, safeRight: 0, division: nil, prefersSplit: split)
        let theme = KeyboardTheme(isDark: scheme == .dark, accentStamp: settings.accent)
        let preferences = settings.keyboardPreferences
        let hand = preferences.oneHandedEnabled ? KeyboardHand(preferences.oneHandedSide) : .full
        let column = pose.allowsOneHand ? OneHandedLayout.column(width: width, fraction: preferences.oneHandedWidth, hand: hand) : nil
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    StatusBarView(model: keyboard.model, mic: keyboard.mic, theme: theme,
                                  historyTitle: preferences.clipboardHistoryEnabled ? "History" : "Recent dictations")
                    PreviewGrid(keyboard: keyboard, pose: pose, split: position.split, boardWidth: width)
                }
                .frame(width: column?.width ?? width)
                .offset(x: column?.x ?? 0)
                if let column, let side = hand.side {
                    PreviewHandPanel(side: side.other, dark: theme.isDark)
                        .frame(width: width - column.width)
                        .offset(x: column.x == 0 ? column.width : 0)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .background(theme.background)
            .scaleEffect(proxy.size.width / width, anchor: .topLeading)
        }
        .onChange(of: preferences, initial: true) { _, value in keyboard.model.displayPreview(value) }
        .aspectRatio(width / height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard preview")
        .accessibilityValue("\(settings.accent.label), \(hand.label)")
        .accessibilityIdentifier("appearance.keyboardPreview")
    }
}

@MainActor
private final class PreviewKeyboard: ObservableObject {
    let model = KeyboardModel(proxy: nil, systemLexiconStore: nil, vocabulary: { nil })
    let mic: MicController

    init() {
        mic = MicController(store: InMemorySharedStore(), proxy: nil, feedback: model.feedback)
    }
}

private struct PreviewGrid: UIViewRepresentable {
    let keyboard: PreviewKeyboard
    let pose: DuoKeyboard
    let split: Bool
    let boardWidth: CGFloat

    func makeUIView(context: Context) -> KeyGridView {
        KeyGridView(model: keyboard.model, mic: keyboard.mic, controller: nil)
    }

    func updateUIView(_ grid: KeyGridView, context: Context) {
        grid.previewBoardWidth = boardWidth
        grid.duo = pose
        grid.splitKeys = split
        grid.sync()
    }
}

private struct PreviewHandPanel: UIViewRepresentable {
    let side: OneHandedSide
    let dark: Bool

    func makeUIView(context: Context) -> OneHandedPanel { OneHandedPanel() }

    func updateUIView(_ panel: OneHandedPanel, context: Context) {
        panel.configure(side: side, isDark: dark)
    }
}
