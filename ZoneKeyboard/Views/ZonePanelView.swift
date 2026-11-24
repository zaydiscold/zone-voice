// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct ZonePanelView: View {
    let mic: MicController
    let model: KeyboardModel
    let theme: KeyboardTheme
    let section: MicController.PanelSection
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var focus: MicController.PanelSection?

    private enum ScrollAnchor: Hashable { case top, keyboard }

    @State private var showControls = false
    @State private var chooser: QuickSetting.Key?
    @State private var saveError: String?

    @State private var saveID: UUID?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6),
              count: typeSize.isAccessibilitySize ? 2 : 4)
    }

    var body: some View {
        GeometryReader { bounds in
            menu(narrow: bounds.size.width < 320)
        }
    }

    private func menu(narrow: Bool) -> some View {
        ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: 0) {
                if let saveError {
                    Text(saveError).font(.caption).padding(.horizontal, 10)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 3 : 2) {
                        if let chooser {
                            choices(for: chooser)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 3), spacing: 6) {
                                tile("Home", icon: nil, compact: true) { mic.openDestination(.home) }
                                    .accessibilityFocused($focus, equals: .home)
                                tile("Notes", icon: "note.text", compact: true) { mic.openDestination(.notes) }
                                tile("Settings", icon: "testtube.2", compact: true) { mic.openDestination(.settings) }
                            }
                            if typeSize.isAccessibilitySize {
                                HStack(spacing: 6) {
                                    tile("Text style", icon: "textformat", selected: !showControls, compact: true) { showControls = false }
                                        .accessibilityIdentifier("keyboard.stylesTab")
                                    tile("Mic & keys", icon: "slider.horizontal.3", selected: showControls, compact: true) { showControls = true }
                                        .accessibilityIdentifier("keyboard.controlsTab")
                                }
                            }
                            if !typeSize.isAccessibilitySize || !showControls {
                                LazyVGrid(columns: columns, spacing: 6) {
                                    ForEach(TextStyle.allCases, id: \.self) { style in
                                        tile(style.label, icon: symbol(for: style), selected: mic.style == style, showsIcon: !narrow) {
                                            mic.choosePanelStyle(style)
                                        }
                                        .disabled(!mic.state.allowsStyleChoice)
                                        .accessibilityLabel("\(style.label) style")
                                        .accessibilityHint("Also rewrites the dictation just made")
                                    }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Text style")
                                .accessibilityFocused($focus, equals: .styles)
                                .id(MicController.PanelSection.styles)
                            }
                            if !typeSize.isAccessibilitySize || showControls {
                                LazyVGrid(columns: columns, spacing: 4) {
                                    quickTiles(narrow: narrow)
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Dictation controls")
                                .id(ScrollAnchor.keyboard)
                                if typeSize.isAccessibilitySize { groupHeading("Layout") }
                                LazyVGrid(columns: columns, spacing: 4) {
                                    let compact = mic.mode == .dictate
                                    tile(compact ? "Show keys" : "Fold keys", icon: compact ? "keyboard" : "keyboard.chevron.compact.down", compact: true, showsIcon: !narrow) {
                                        mic.toggleMode()
                                    }
                                    if model.preferences.oneHandedEnabled {
                                        ForEach(KeyboardHand.allCases, id: \.self) { hand in
                                            tile(hand.side?.label ?? "Full", icon: hand.symbolName, selected: model.hand == hand, compact: true, showsIcon: !narrow) {
                                                model.chooseHand(hand)
                                            }
                                            .accessibilityLabel(hand.label)
                                        }
                                    }
                                }
                            }

                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .id(ScrollAnchor.top)
                }
                .accessibilityIdentifier("keyboard.zonePanel")
            }
            .onChange(of: chooser) { previous, current in
                guard previous != current else { return }
                reader.scrollTo(current == nil && !typeSize.isAccessibilitySize ? ScrollAnchor.keyboard : .top, anchor: .top)
            }
            .onDisappear { resetChooser() }
            .accessibilityAction(.escape) { mic.panelSection = nil }
            .onChange(of: section, initial: true) { _, start in
                resetChooser()
                if start == .styles { showControls = false }
                if start == .styles && !typeSize.isAccessibilitySize { Task { @MainActor in reader.scrollTo(start, anchor: .top) } }
                focus = start
            }
        }
        .foregroundStyle(theme.text)
    }

    private func groupHeading(_ name: String) -> some View {
        Text(name).font(.caption.weight(.semibold)).dynamicTypeSize(...DynamicTypeSize.xxxLarge).foregroundStyle(theme.secondaryText)
            .padding(.top, 4).accessibilityAddTraits(.isHeader)
    }

    private var preferences: KeyboardPreferences { model.preferences }

    private func choose(_ value: QuickSetting) {
        guard saveID == nil else { return }
        let id = UUID()
        saveID = id
        Task {
            let error = await mic.submitQuickSetting(value)
            if error == nil { model.apply(mic.readPreferences()) }
            guard saveID == id else { return }
            saveID = nil
            saveError = error
            if let error {
                UIAccessibility.post(notification: .announcement, argument: error)
            } else {
                chooser = nil
            }
        }
    }

    private func resetChooser() {
        chooser = nil
        saveError = nil
        saveID = nil
    }

    @ViewBuilder private func quickTiles(narrow: Bool) -> some View {
        let quiet = preferences.finishWhenQuiet ? "\(Int(preferences.quietWait)) s" : "Off"
        tile(narrow ? "Quiet" : "Auto-stop", icon: "timer", value: quiet, showsIcon: !narrow) { chooser = .quiet }
            .accessibilityIdentifier("keyboard.quickQuiet")
            .accessibilityLabel("Finish when quiet")
            .accessibilityValue(quiet)
        tile("Sounds", icon: preferences.soundsEnabled ? "speaker.wave.2" : "speaker.slash",
             value: preferences.soundsEnabled ? "On" : "Off", showsIcon: !narrow) {
            choose(.sounds(!preferences.soundsEnabled))
        }
        .accessibilityIdentifier("keyboard.quickSounds")
        .accessibilityLabel("Sounds")
        .accessibilityValue(preferences.soundsEnabled ? "On" : "Off")
        let graphicLabel = narrow && preferences.meterStyle == .lanes ? "Hero" : preferences.meterStyle.label
        tile("Meter", icon: nil, value: graphicLabel, graphic: preferences.meterStyle, showsIcon: !narrow) {
            chooser = .graphic
        }
        .accessibilityIdentifier("keyboard.quickGraphic")
        .accessibilityLabel("Voice graphic")
        .accessibilityValue(preferences.meterStyle.label)
        let cursor = preferences.spaceHold == .moveCursor
        tile("Space", icon: cursor ? "cursorarrow" : "mic", value: cursor ? "Cursor" : "Talk", showsIcon: !narrow) {
            choose(.hold(cursor ? .talk : .moveCursor))
        }
        .accessibilityIdentifier("keyboard.quickHold")
        .accessibilityLabel("Hold space")
        .accessibilityValue(preferences.spaceHold.label)
    }

    private func choices(for key: QuickSetting.Key) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key == .quiet ? "Finish when quiet" : "Voice graphic")
                .font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 6) {
                tile("Back", icon: "chevron.left") { resetChooser() }
                if key == .quiet {
                    tile("Off", icon: "timer", selected: !preferences.finishWhenQuiet) {
                        choose(.quiet(enabled: false, wait: preferences.quietWait))
                    }
                    ForEach(SilenceFinish.waitChoices(including: preferences.quietWait), id: \.self) { wait in
                        tile("\(Int(wait)) s", icon: "timer",
                             selected: preferences.finishWhenQuiet && preferences.quietWait == wait) {
                            choose(.quiet(enabled: true, wait: wait))
                        }
                    }
                } else {
                    ForEach(MeterStyle.allCases, id: \.self) { style in
                        tile(style.label, icon: "waveform", selected: preferences.meterStyle == style,
                             graphic: style) {
                            choose(.graphic(style))
                        }
                    }
                }
            }
        }
    }

    private func symbol(for style: TextStyle) -> String {
        switch style {
        case .casual: "bubble.left"
        case .veryCasual: "textformat.abc"
        case .formal: "doc.text"
        case .excited: "exclamationmark"
        }
    }

    private func tile(_ title: String, icon: String?, selected: Bool = false, value: String? = nil, graphic: MeterStyle? = nil,
                      compact: Bool = false, showsIcon: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let horizontal = compact || (value != nil && !typeSize.isAccessibilitySize)
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 3)) : AnyLayout(VStackLayout(spacing: 1))
            VStack(spacing: 1) {
                layout {
                    if showsIcon {
                        Group {
                            if let graphic {
                                Image(uiImage: PanelThumbnail.image(for: graphic))
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                            } else if let icon { Image(systemName: icon) } else { ZoneHomeMark(theme: theme) }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    }
                    Text(title).font(.caption.weight(.medium))
                }
                if let value { Text(value).font(.caption2).foregroundStyle(theme.secondaryText) }
            }
            .multilineTextAlignment(.center)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(selected ? theme.onInk : theme.text)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 48 : (value == nil ? 44 : 48), alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: KeyboardTheme.cornerRadius, style: .continuous)
                    .fill(selected ? theme.ink : theme.key)
                    .sunCast(theme: theme)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One transparent mask for each style. SwiftUI supplies the foreground ink at draw time.
@MainActor
enum PanelThumbnail {
    private static var cache: [MeterStyle: UIImage] = [:]

    static func image(for style: MeterStyle) -> UIImage {
        if let cached = cache[style] { return cached }
        let size = CGSize(width: 40, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            if let engine = VoiceArtEngine(style: style, seed: 17) {
                let ink = ArtColor(1, 1, 1)
                engine.feed(level: 0.8)
                engine.advance(by: 0.25, size: size)
                engine.draw(in: context, size: size, palette: .init(ink: ink, accent: ink, isDark: true))
                return
            }
            context.setLineWidth(1.5)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setFillColor(UIColor.white.cgColor)
            for i in 0..<40 {
                let x = CGFloat(i)
                let y = 8 + 5 * sin(x * 0.35) * sin(x * .pi / 40)
                switch style {
                case .scope where i.isMultiple(of: 2):
                    context.fillEllipse(in: CGRect(x: x, y: y - 1, width: 1.5, height: 1.5))
                case .wave:
                    if i == 0 { context.move(to: CGPoint(x: x, y: y)) }
                    else { context.addLine(to: CGPoint(x: x, y: y)) }
                case .mirrored, .bars:
                    if i.isMultiple(of: 4) {
                        let height = 2 + 11 * abs(sin(x * 0.17))
                        context.fill(CGRect(x: x, y: style == .bars ? 15 - height : 8 - height / 2,
                                            width: 2, height: height))
                    }
                default: break
                }
            }
            context.strokePath()
        }
        cache[style] = image
        return image
    }
}
