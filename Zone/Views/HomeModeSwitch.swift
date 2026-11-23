// by zayd/cold @ zayd.wtf

import SwiftUI

/// Home's two spaces.
enum HomeMode: String, CaseIterable {
    case transcribe, meeting, cleanup
}

/// Home navigation. The meeting indicator remains visible while another page is open.
struct HomeModeSwitch: View {
    @Binding var mode: HomeMode
    var recording = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var fill

    var body: some View {
        HStack(spacing: 0) {
            segment(.transcribe) { Text("Transcribe") }
            segment(.meeting) {
                HStack(spacing: 6) {
                    if recording && mode != .meeting {
                        Circle().fill(Zone.accentGraphic).frame(width: 7, height: 7)
                            .accessibilityLabel("Recording")
                    }
                    Text("Meeting")
                }
            }
            segment(.cleanup) { Text("Cleanup") }
        }
        .padding(3)
        .background(Zone.card(scheme), in: Capsule())
        .overlay(Capsule().strokeBorder(Zone.rule(scheme), lineWidth: 1))
        // Like the system's tab bars and segmented controls, the switch stops growing at the
        // largest standard size; past it the labels would push History and Settings off screen.
        // VoiceOver and Large Content still read every segment.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
    }

    private func segment<Label: View>(_ value: HomeMode, @ViewBuilder label: () -> Label) -> some View {
        let selected = mode == value
        return Button {
            guard !selected else { return }
            Haptics.tap()
            withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.35)) { mode = value }
        } label: {
            label()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Zone.onInk(scheme) : Zone.muted(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                // Equal thirds: the switch runs from the page's margin to the icons, like every
                // other block on Home, instead of ending wherever its labels do.
                .frame(maxWidth: .infinity, minHeight: 38)
                .background {
                    if selected {
                        Capsule().fill(Zone.ink(scheme)).matchedGeometryEffect(id: "fill", in: fill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(value == .meeting ? "Record a meeting and get a transcript" : value == .cleanup ? "Review a cleaned version of your words" : "Dictation")
    }
}
