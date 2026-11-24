// by zayd/cold @ zayd.wtf

import SwiftUI

enum MicLightStyle: String, CaseIterable {
    case glow, clear, off

    var label: String {
        switch self {
        case .glow: "Glow"
        case .clear: "Clear edge"
        case .off: "Off"
        }
    }
}

struct MicLight: View {
    enum Surface {
        case standby, composer(CGFloat), listening

        var radius: CGFloat {
            switch self {
            case .standby: Zone.cardRadius
            case .composer(let radius): radius
            case .listening: 26
            }
        }
    }

    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let surface: Surface
    var previewLevel: Float? = nil

    var body: some View {
        if scenePhase == .active, settings.micLightStyle != .off, let state {
            let accent = Zone.accentTone(scheme)
            let companion = Zone.accentTone(scheme == .dark ? .light : .dark)
            let peak = accent.mix(with: Zone.ink(scheme), by: contrast == .increased ? 0.70 : 0.35)
            let glass = settings.micLightStyle == .glow && !reduceTransparency
            let configuration = RimConfiguration(state: state, radius: surface.radius, glow: glass, still: reduceMotion || state == .paused,
                                                 subtle: isComposer && state == .ready, accent: UIColor(accent).cgColor,
                                                 companion: UIColor(companion).cgColor, peak: UIColor(peak).cgColor)
            MeteredRim(configuration: configuration, previewLevel: previewLevel)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var isComposer: Bool {
        if case .composer = surface { return true }
        return false
    }

    private var state: MicRim.State? {
        if previewLevel != nil { return .listening }
        switch coordinator.activity {
        case .recording: return coordinator.showsPaused ? .paused : .listening
        case .transcribing: return .writing
        default:
            if coordinator.isPreparingMicrophone { return .starting }
            return coordinator.isArmed ? .ready : nil
        }
    }
}

private struct RimConfiguration {
    let state: MicRim.State
    let radius: CGFloat
    let glow, still, subtle: Bool
    let accent, companion, peak: CGColor
}

private struct MeteredRim: View {
    @Environment(DictationCoordinator.self) private var coordinator
    let configuration: RimConfiguration
    let previewLevel: Float?

    var body: some View {
        RimHost(configuration: configuration, level: level)
    }

    private var level: Float {
        guard configuration.state == .listening, !configuration.still else { return 0 }
        if let previewLevel { return previewLevel }
        let history = coordinator.recentLevels
        let latest = history.last ?? 0
        return latest * 0.72 + (history.dropLast().last ?? latest) * 0.28
    }
}

private struct RimHost: UIViewRepresentable {
    let configuration: RimConfiguration
    let level: Float

    final class Host: UIView {
        let rim = MicRim()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(rim.layer)
        }
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            rim.layout(bounds: bounds, scale: traitCollection.displayScale,
                       maximumFPS: window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
    }

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ view: Host, context: Context) {
        view.rim.configure(state: configuration.state, level: level, radius: configuration.radius, glow: configuration.glow,
                           still: configuration.still, subtle: configuration.subtle, accent: configuration.accent,
                           companion: configuration.companion, peak: configuration.peak)
        if view.rim.needsLayout { view.setNeedsLayout() }
    }
}
