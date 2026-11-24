// by zayd/cold @ zayd.wtf

import SwiftUI

/// Declaration order is the order of both the keys and the swipe destinations.
enum HomeMode: String, CaseIterable {
    case transcribe, meeting

    var title: LocalizedStringKey {
        switch self {
        case .transcribe: "Transcribe"
        case .meeting: "Meeting"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .transcribe: "Dictation"
        case .meeting: "Record a meeting and get a transcript"
        }
    }
}

/// Only the switch observes frame-by-frame travel. Home commits page ownership at rest.
@Observable final class HomePageTravel {
    var position: CGFloat?
}

/// Home navigation. An ongoing recording is marked on its key while another page is open.
struct HomeModeSwitch: View {
    @Binding var mode: HomeMode
    @ScaledMetric(relativeTo: .footnote) private var keyWidth: CGFloat = 80
    let travel: HomePageTravel
    var meetingRecording = false
    var dictationRecording = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeMode.allCases, id: \.self) { value in
                segment(value)
            }
        }
        .foregroundStyle(Zone.muted(scheme))
        .background { movingKey.foregroundStyle(Zone.ink(scheme)) }
        .overlay {
            HStack(spacing: 0) {
                ForEach(HomeMode.allCases, id: \.self) { value in
                    keyLabel(value)
                }
            }
            .foregroundStyle(Zone.onInk(scheme))
            .mask { movingKey }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // The 32-point track sits inside two full-height tap targets.
        .padding(.horizontal, 2)
        .background {
            Zone.cardShape.fill(Zone.card(scheme)).sunShadow(scale: 0.6)
                .padding(.vertical, 6)
        }
        .overlay {
            if contrast == .increased {
                Zone.cardShape.strokeBorder(Zone.rule(scheme), lineWidth: 1)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var movingKey: some View {
        GeometryReader { bounds in
            let width = bounds.size.width / CGFloat(HomeMode.allCases.count)
            let position = travel.position ?? CGFloat(HomeMode.allCases.firstIndex(of: mode) ?? 0)
            HStack(spacing: 0) {
                Color.clear.frame(width: position * width)
                RoundedRectangle(cornerRadius: Zone.cardRadius - 2, style: .continuous)
                    .frame(width: width)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 8)
        .transaction { $0.animation = nil }
    }

    private func keyLabel(_ value: HomeMode) -> some View {
        let recording = (value == .meeting && meetingRecording) || (value == .transcribe && dictationRecording)
        return HStack(spacing: 4) {
            if recording && mode != value {
                Circle().fill(Zone.accentTone(scheme)).frame(width: 7, height: 7)
                    .accessibilityLabel("Recording")
            }
            Text(value.title)
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 6)
        .frame(width: keyWidth)
        .frame(minHeight: 44)
    }

    private func segment(_ value: HomeMode) -> some View {
        let selected = mode == value
        return Button {
            if !selected { Haptics.tap() }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { mode = value }
        } label: {
            keyLabel(value).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(value.hint)
        .accessibilityIdentifier("home.mode." + value.rawValue)
    }
}
