// by zayd/cold @ zayd.wtf

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Zone's Dynamic Island, in four looks (`IslandLook`). Measurements for the recorder look and
/// the compact waveform come from islandcn (github.com/opencoredev/islandcn), which fitted them
/// to frame-by-frame recordings of Apple's own voice recorder island.
///
/// Owning the island is also what keeps it small: with the microphone held in the background
/// and no activity of Zone's, iOS draws its own wide microphone pill instead.
enum ZoneIsland {
    typealias Context = ActivityViewContext<RecordingActivityAttributes>

    static func make(_ context: Context) -> DynamicIsland {
        let kit = IslandKit(context)
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) { ExpandedLeading(kit: kit) }
            DynamicIslandExpandedRegion(.trailing) { ExpandedTrailing(kit: kit) }
            DynamicIslandExpandedRegion(.bottom) { ExpandedBottom(kit: kit) }
        } compactLeading: {
            CompactLeading(kit: kit)
        } compactTrailing: {
            CompactTrailing(kit: kit)
        } minimal: {
            MinimalView(kit: kit)
        }
        // The island's edge is the recording light: the accent only while the microphone is
        // recording, a quiet grey while Zone only waits. Waiting and listening must never look
        // alike (the most common complaint about keyboard dictation islands).
        .keylineTint(kit.live ? kit.tint : Color.white.opacity(0.3))
    }
}

// MARK: - The state every region reads

struct IslandKit {
    let state: RecordingActivityAttributes.ContentState
    let stale: Bool
    let look: IslandLook

    init(_ context: ZoneIsland.Context) {
        state = context.state
        stale = context.isStale
        look = context.state.look ?? .halo
    }

    /// The accent, or the recorder's red. Zone's own palette keeps red for errors: recording
    /// is drawn in the accent everywhere except the look that copies Apple's recorder.
    /// The Recorder look is red only while it records: red is what recording looks like
    /// everywhere on iPhone, so its standby dot and ring are a quiet white instead.
    var tint: Color {
        guard look == .recorder else { return IslandColor(hex: state.accentHex ?? IslandColor.violet).color }
        return phase == .ready ? IslandColor.standbyWhite : IslandColor.recorderRed
    }
    var phase: RecordingActivityAttributes.ContentState.Phase { state.phase }
    var recording: Bool { phase == .recording && !stale }
    /// Standby while an interruption has the microphone. Drawn the same fresh or stale: it never
    /// claims to record, so it has no "stopped" to warn about.
    var held: Bool { phase == .ready && state.standbyHeld == true }
    var ready: Bool { phase == .ready && !stale && !held }
    var levels: [UInt8]? { state.levels }
    /// Buttons are on (Settings > Dynamic Island > Buttons) and this is a dictation or a note.
    /// A meeting has its own recorder and its own stop; a stale card has nobody to answer.
    var showsControls: Bool { state.controls != false && state.meetingTitle == nil && !stale }
    /// Paused by the person, with the time recorded so far. An interruption's hold is
    /// `phase == .paused` and has no buttons: only iOS can give the microphone back.
    var userPaused: Bool { recording && state.userPausedAt != nil }
    /// Recording and not paused: the waveform moves and the clock runs.
    var live: Bool { recording && !userPaused }
    /// Stop is drawn for every dictation and note when buttons are on. With buttons off it
    /// stays, as before, on a recording its own control started, which has no other stop.
    var canStop: Bool { recording && state.meetingTitle == nil && (showsControls || state.controlOwned == true) }
    var canPause: Bool { recording && showsControls }
    /// Dictate and Note start in the microphone session that standby keeps running.
    var canStart: Bool { ready && showsControls }
    /// Standby's Turn off: the same intent as the Toggle Zone control, which iOS runs in the Zone
    /// app in the background. It ends the microphone session, and with it this card.
    var turnOffIntent: SetZoneStandbyIntent {
        var intent = SetZoneStandbyIntent()
        intent.value = false
        return intent
    }
    /// Standby a moment after a recording finished.
    var done: Bool { ready && state.justFinished == true }
    var countdown: ClosedRange<Date>? {
        guard ready, let since = state.readySince, let until = state.readyUntil, until > since else { return nil }
        return since...until
    }
}

enum IslandColor {
    static let violet: UInt32 = 0x9B7DFF
    /// Apple's recorder red on the black island.
    static let recorderRed = Color(red: 1, green: 0.27, blue: 0.23)
    /// The Recorder look's standby: the island's own white, a step back.
    static let standbyWhite = Color.white.opacity(0.72)
    /// The recorder's grey "not reached yet" dots: rgba(235, 235, 245, 0.42).
    static let pendingDot = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.42)

    case custom(UInt32)
    init(hex: UInt32) { self = .custom(hex) }
    var color: Color {
        guard case .custom(let hex) = self else { return .purple }
        return Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Pieces

/// Bars growing from a centre line, like the recorder's. Heights come from the app's level
/// history; with no history yet the bars rest at the floor.
struct IslandWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [UInt8]
    let color: Color
    var barWidth: CGFloat = 1.4
    var gap: CGFloat = 1.35
    var height: CGFloat = 22
    var floor: CGFloat = 2

    var body: some View {
        HStack(alignment: .center, spacing: gap) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: floor + (height - floor) * IslandLevels.unit(level))
            }
        }
        .frame(height: height)
        // Updates come about once a second at best, and iOS may space them further. Gliding
        // between snapshots makes a late one read as calm speech, not a frozen meter. Live
        // Activities honor an animation of up to two seconds on an update.
        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: levels)
        .accessibilityHidden(true)
    }
}

/// The recorder's expanded strip: 15 bars where the recording has reached, then grey dots.
struct RecorderStrip: View {
    let levels: [UInt8]?
    let color: Color
    let live: Bool
    /// Beside a pause button the recorder draws 13 bars and 6 dots, so the tallest bars stay
    /// left of the camera (islandcn's `barsBesidePause`).
    var bars = IslandLevels.expandedBars
    var dots = 11

    var body: some View {
        HStack(spacing: 5.3 - 2.7) {
            IslandWave(levels: IslandLevels.last(bars, of: levels),
                       color: live ? color : .secondary,
                       barWidth: 2.9, gap: 5.3 - 2.9, height: 40, floor: 4)
            ForEach(0..<dots, id: \.self) { _ in
                Circle().fill(IslandColor.pendingDot).frame(width: 2.7, height: 2.7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The recorder's stop button: a red rounded square inside a thin white ring, 49 pt.
struct StopRing: View {
    let color: Color
    var size: CGFloat = 49
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white, lineWidth: 3)
            RoundedRectangle(cornerRadius: size * 6.5 / 49, style: .continuous)
                .fill(color)
                .frame(width: size * 25 / 49, height: size * 25 / 49)
        }
        .frame(width: size, height: size)
    }
}

/// Standby's countdown: a ring that empties until the microphone session ends. iOS animates
/// a timer-interval progress view by itself, so this costs no updates.
struct ReadyRing: View {
    let interval: ClosedRange<Date>
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        ProgressView(timerInterval: interval, countsDown: true) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.circular)
        .tint(color)
        .frame(width: size, height: size)
        .accessibilityLabel("Zone is ready")
    }
}

struct Dot: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    let color: Color
    var size: CGFloat = 6
    /// Recording, not waiting. With Differentiate Without Color on, the recording dot becomes a
    /// square, as iOS turns its own orange microphone dot into one: state must never rest on
    /// hue alone.
    var recording = false
    var body: some View {
        if recording && withoutColor {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: size, height: size)
        } else {
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}

/// Standby in the expanded island: the compact island's dot, inside a ring.
struct ReadyMark: View {
    let color: Color
    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1.6).frame(width: 15, height: 15)
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .accessibilityHidden(true)
    }
}

/// Standby's dot, emptied: Zone is still here, the microphone is not. Shape, not only color,
/// tells it from the ready dot (Bartram et al.: color alone is the weakest peripheral cue).
struct HeldDot: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View {
        Circle().strokeBorder(color.opacity(0.75), lineWidth: 1.4)
            .frame(width: size, height: size)
            .accessibilityLabel("Zone paused")
    }
}

// MARK: - Compact

struct CompactLeading: View {
    let kit: IslandKit
    var body: some View {
        Group {
            if kit.held {
                HeldDot(color: kit.tint, size: kit.look == .ghost ? 5 : 6)
            } else if kit.stale {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Zone stopped")
            } else {
                switch kit.phase {
                case .ready where kit.done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(kit.tint)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Saved")
                case .ready:
                    Dot(color: kit.tint.opacity(kit.look == .ghost ? 0.7 : 1), size: kit.look == .ghost ? 5 : 6)
                        .accessibilityLabel("Zone ready")
                case .recording:
                    if kit.userPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Zone paused")
                    } else if kit.look == .ghost {
                        Dot(color: kit.tint, size: 8, recording: true).accessibilityLabel("Zone recording")
                    } else {
                        IslandWave(levels: IslandLevels.last(IslandLevels.compactBars, of: kit.levels), color: kit.tint)
                            .accessibilityElement()
                            .accessibilityLabel("Zone recording")
                    }
                case .paused:
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(kit.tint)
                        .accessibilityLabel("Zone paused")
                case .processing:
                    // Still, not a moving waveform: after Stop nothing may look like listening
                    // (Ma et al., arXiv 2610.09284: people miss that listening has ended).
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(kit.tint)
                        .accessibilityLabel("Zone recognizing")
                }
            }
        }
        .padding(.leading, 2)
    }
}

struct CompactTrailing: View {
    let kit: IslandKit
    var body: some View {
        Group {
            if kit.stale || kit.look == .ghost || kit.held {
                // Balanced, empty wing: the ghost is one dot, nothing more; a held standby has
                // no countdown to show.
                Color.clear.frame(width: 6, height: 6)
            } else {
                switch kit.phase {
                case .ready where kit.done && kit.look != .ghost:
                    if let words = kit.state.words, words > 0 {
                        Text("\(words)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(kit.tint)
                            .accessibilityLabel("\(words) words")
                    } else {
                        Color.clear.frame(width: 6, height: 6)
                    }
                case .ready:
                    if let interval = kit.countdown {
                        ReadyRing(interval: interval, color: kit.tint, size: 13)
                    } else {
                        Color.clear.frame(width: 6, height: 6)
                    }
                case .recording:
                    if kit.userPaused {
                        ElapsedText(kit: kit, size: 14, weight: .medium, maxWidth: 44)
                    } else if kit.look == .caption, let words = kit.state.words, words > 0 {
                        Text("\(words)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(kit.tint)
                            .contentTransition(.numericText())
                            .accessibilityLabel("\(words) words")
                    } else {
                        Text(kit.state.startedAt, style: .timer)
                            .font(.system(size: 14, weight: kit.look == .recorder ? .regular : .medium))
                            .monospacedDigit()
                            .foregroundStyle(kit.tint)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 44)
                    }
                case .paused:
                    Text("Paused").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                case .processing:
                    ProgressView().progressViewStyle(.circular).tint(kit.tint).frame(width: 13, height: 13)
                }
            }
        }
        .padding(.trailing, 2)
    }
}

struct MinimalView: View {
    let kit: IslandKit
    var body: some View {
        if kit.held {
            HeldDot(color: kit.tint, size: 6)
        } else if kit.stale {
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        } else if kit.recording && kit.look != .ghost {
            IslandWave(levels: IslandLevels.last(5, of: kit.levels), color: kit.tint, barWidth: 2, gap: 2, height: 16)
        } else if let interval = kit.countdown, kit.look != .ghost {
            ReadyRing(interval: interval, color: kit.tint, size: 16)
        } else {
            Dot(color: kit.tint, size: kit.recording ? 8 : 6, recording: kit.recording)
        }
    }
}

// MARK: - Expanded

struct ExpandedLeading: View {
    let kit: IslandKit
    var body: some View {
        if kit.look == .recorder && (kit.recording || kit.phase == .paused) {
            HStack(spacing: 10) {
                if kit.canPause { PauseButton(kit: kit) }
                RecorderStrip(levels: kit.levels, color: kit.tint, live: kit.live,
                              bars: kit.canPause ? 13 : IslandLevels.expandedBars, dots: kit.canPause ? 6 : 11)
            }
            .padding(.leading, kit.canPause ? 0 : 6)
            .frame(maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(kit.tint.opacity(0.18))
                    if kit.ready {
                        // Standby wears the compact island's dot inside a ring: Zone, waiting. A
                        // microphone beside iOS's orange dot would read as listening.
                        ReadyMark(color: kit.tint)
                    } else {
                        Image(systemName: glyph)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(kit.tint)
                    }
                }
                .frame(width: 32, height: 32)
                Text(RecordingWords.short(kit.state, stale: kit.stale))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.leading, 4)
        }
    }

    private var glyph: String {
        if kit.held { return "mic.slash" }
        if kit.stale { return "exclamationmark" }
        return switch kit.phase {
        case .ready: "mic"
        case .recording: kit.state.noteMode ? "note.text" : "waveform"
        case .paused: "pause.fill"
        case .processing: "text.bubble"
        }
    }
}

struct ExpandedTrailing: View {
    let kit: IslandKit
    var body: some View {
        if kit.look == .recorder && (kit.recording || kit.phase == .paused) {
            HStack(spacing: 10) {
                ElapsedText(kit: kit, size: 22, weight: .regular, maxWidth: 76)
                if kit.canStop {
                    IslandButton(.stop, label: "Stop recording") { StopRing(color: kit.tint) }
                }
            }
            .frame(maxHeight: .infinity)
        } else if kit.recording {
            // Stop and Pause sit in the bottom row, at the island's corners, where a thumb
            // finds them; up here is only the clock.
            ElapsedText(kit: kit, size: 17, weight: .medium, maxWidth: 64)
                .padding(.trailing, 6)
        } else if kit.ready || kit.held {
            HStack(spacing: 10) {
                if kit.ready, let until = kit.state.readyUntil {
                    // When it turns off, as a time: a ticking clock is what recording and calls
                    // look like, and a countdown frustrates more than it informs (Tan and Nov,
                    // arXiv 2602.04138). The compact ring still shows what is left.
                    // Hours and minutes only: "Off 12:03 PM" runs under the camera. Standby ends
                    // within hours, so the half of the day is never in doubt.
                    Text("Off \(until.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Button(intent: kit.turnOffIntent) { TurnOffButton(color: kit.tint) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Turn Zone off")
            }
            .padding(.trailing, 4)
        }
    }
}

/// The recording's clock. Running, iOS counts it up by itself. Paused by the person, it shows
/// the time recorded so far and stands still: a timer text cannot stop, so the paused time
/// comes from the app.
struct ElapsedText: View {
    let kit: IslandKit
    var size: CGFloat
    var weight: Font.Weight = .medium
    var maxWidth: CGFloat = 64

    var body: some View {
        Group {
            if let paused = kit.state.userPausedAt, kit.recording {
                Text(Self.clock(paused)).foregroundStyle(.secondary)
            } else {
                Text(kit.state.startedAt, style: .timer).foregroundStyle(kit.recording ? kit.tint : .secondary)
            }
        }
        .font(.system(size: size, weight: weight))
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: maxWidth, alignment: .trailing)
        // Pause and Stop change this. Until Zone answers (a second or two), iOS shows it as
        // pending, so a tap never looks ignored.
        .invalidatableContent()
    }

    /// "0:07", "12:40", "1:02:09", as the timer text writes them.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, sec) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// One of the card's buttons. The drawing may be smaller, but the target is never under
/// 44 pt, Apple's minimum: the island sits at the far end of a thumb's reach.
struct IslandButton<Label: View>: View {
    let action: IslandAction
    let label: String
    var target: CGFloat = 44
    @ViewBuilder var content: () -> Label

    init(_ action: IslandAction, label: String, target: CGFloat = 44, @ViewBuilder content: @escaping () -> Label) {
        self.action = action
        self.label = label
        self.target = target
        self.content = content
    }

    var body: some View {
        Button(intent: ZoneIslandIntent(action)) {
            content()
                .frame(minWidth: target, minHeight: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Pause while recording, Resume while paused: a quiet grey circle, so Stop still leads.
struct PauseButton: View {
    let kit: IslandKit
    var size: CGFloat = 36
    var body: some View {
        IslandButton(.pause, label: kit.userPaused ? "Resume recording" : "Pause recording") {
            ZStack {
                Circle().fill(Color.white.opacity(0.16))
                Image(systemName: kit.userPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .invalidatableContent()
            }
            .frame(width: size, height: size)
        }
    }
}

/// Standby's Dictate and Note. Dictate is filled: it is the one most people want.
struct StartPill: View {
    let action: IslandAction
    let title: String
    let symbol: String
    let tint: Color
    let primary: Bool

    var body: some View {
        IslandButton(action, label: title) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(primary ? Color.black : tint)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule().fill(primary ? tint : tint.opacity(0.18)))
            .invalidatableContent()
        }
    }
}

/// Standby's Turn off: a power symbol on a tinted circle, the size of the leading glyph.
struct TurnOffButton: View {
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Image(systemName: "power")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 32, height: 32)
    }
}

struct ExpandedBottom: View {
    let kit: IslandKit
    var body: some View {
        if kit.look == .recorder && (kit.recording || kit.phase == .paused) {
            EmptyView()
        } else if kit.recording {
            // Pause at the left corner, Stop at the right, what Zone hears between them.
            HStack(spacing: 8) {
                if kit.canPause { PauseButton(kit: kit) }
                recordingContent.frame(maxWidth: .infinity)
                if kit.canStop {
                    IslandButton(.stop, label: "Stop recording") { StopRing(color: kit.tint, size: 36) }
                }
            }
            .padding(.top, 2)
        } else if kit.canStart {
            VStack(spacing: 6) {
                if kit.done || kit.state.session != nil { detailLine }
                HStack(spacing: 8) {
                    StartPill(action: .dictate, title: "Dictate", symbol: "mic.fill", tint: kit.tint, primary: true)
                    StartPill(action: .note, title: "Note", symbol: "note.text", tint: kit.tint, primary: false)
                }
                .padding(.horizontal, 4)
            }
            .padding(.top, 2)
        } else {
            detailLine
        }
    }

    @ViewBuilder private var recordingContent: some View {
        switch kit.look {
        case .caption:
            CaptionView(text: kit.state.tail, tint: kit.tint)
        case .halo, .recorder:
            // As many bars as fit between the buttons; the newest is always at the right.
            IslandWave(levels: IslandLevels.last(kit.showsControls ? 30 : 40, of: kit.levels),
                       color: kit.live ? kit.tint : .secondary,
                       barWidth: 3, gap: 3, height: 30, floor: 3)
        case .ghost:
            detailLine
        }
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private var detail: String {
        if kit.held { return RecordingWords.detail(kit.state, stale: false) }
        if kit.done {
            if let words = kit.state.words, words > 0 {
                return kit.state.session?.keptLine(words: words) ?? "Kept \(words) words."
            }
            return "Kept."
        }
        if kit.ready, let session = kit.state.session { return session.islandLine() }
        if kit.ready, let words = kit.state.words, words > 0 {
            return "Last dictation: \(words) words. Tap the mic on the keyboard to go again."
        }
        if kit.ready { return "Tap the mic on the Zone keyboard to dictate. Audio is not saved." }
        if kit.userPaused { return "Paused. Nothing is being recorded." }
        if kit.canStop { return "Tap the square to finish" }
        return RecordingWords.detail(kit.state, stale: kit.stale)
    }
}

/// The caption look: the last words Zone heard, oldest fading out at the leading edge.
struct CaptionView: View {
    let text: String?
    let tint: Color
    var body: some View {
        Group {
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Only the oldest words fade: the gradient runs from the top-left corner,
                    // so a second line starts at full strength.
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                                 .init(color: .black, location: 0.5)],
                                         startPoint: .topLeading, endPoint: UnitPoint(x: 0.45, y: 0.6)))
                    .privacySensitive()
                    .contentTransition(.opacity)
            } else {
                Text("Listening…")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(tint.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}
