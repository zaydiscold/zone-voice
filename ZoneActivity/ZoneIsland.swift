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
            // Every region draws in the palette's ink, so `.secondary` is a step down from it
            // and a Blackout island has no white text.
            DynamicIslandExpandedRegion(.leading) { ExpandedLeading(kit: kit).foregroundStyle(kit.ink) }
            DynamicIslandExpandedRegion(.trailing) { ExpandedTrailing(kit: kit).foregroundStyle(kit.ink) }
            DynamicIslandExpandedRegion(.bottom) { ExpandedBottom(kit: kit).foregroundStyle(kit.ink) }
        } compactLeading: {
            Group { if kit.alive { AliveCompactLeading(kit: kit) } else { CompactLeading(kit: kit) } }
                .foregroundStyle(kit.ink)
        } compactTrailing: {
            // A creature that spans the camera has its other half here, not a clock.
            Group {
                if kit.alive, kit.spansCamera { AliveCompactTrailing(kit: kit) } else { CompactTrailing(kit: kit) }
            }
            .foregroundStyle(kit.ink)
        } minimal: {
            Group {
                if kit.portrait {
                    IslandSprite(look: kit.look, mood: kit.mood, tint: kit.tint, height: 21, size: .side)
                        .accessibilityElement(children: .ignore).accessibilityLabel(kit.spokenState)
                } else if kit.look.spins {
                    IslandRelic(look: kit.look, mood: kit.mood, tint: kit.tint, height: 16,
                                clock: kit.clock, activitySnapshotsOnly: true)
                        .accessibilityElement(children: .ignore).accessibilityLabel(kit.spokenState)
                } else if kit.alive {
                    AliveMinimal(kit: kit).frame(width: 21, height: 21)
                } else { MinimalView(kit: kit) }
            }
                .foregroundStyle(kit.ink)
        }
        // The island's edge is the recording light: the accent only while the microphone is
        // recording, a quiet grey while Zone only waits. Waiting and listening must never look
        // alike (the most common complaint about keyboard dictation islands).
        // Blackout has no grey edge at rest: the island is a plain black pill until it records.
        .keylineTint(kit.live ? kit.tint : (kit.look == .blackout ? Color.black : Color.white.opacity(0.3)))
    }
}

// MARK: - The state every region reads

/// Standby's times as spans that count by themselves: `Text(.currentDate, format:)` (iOS 18) is
/// redrawn by the system, in the island and on the Lock Screen, with no update from Zone. The
/// strings are iOS's own (checked on macOS 26 with the same styles, November 20): "29 minutes",
/// "1 hour"; seconds appear only inside the first or last minute ("40 seconds"), which is where a
/// minutes-only span read "0 minutes".
enum IslandTimeText {
    /// "40 seconds", "29 minutes", "1 hour" between now and `date`, either side of it.
    static func span(_ date: Date) -> Text {
        Text(.currentDate, format: .offset(to: date, allowedFields: [.hour, .minute, .second], maxFieldCount: 1, sign: .never))
    }

    // One style for every span, so the island's corner and the Lock Screen agree: `.reference`
    // rounds ("in 5 minutes" at 4:40) where `.offset` truncates ("4 minutes"), and the two sat
    // side by side disagreeing on the simulator.

    // Where these sit, they get a bounded frame and one line, never `fixedSize` or a wrapping
    // paragraph: a self-updating text has no fixed width, and unbounded it emptied the whole
    // region of the expanded island on the iOS 26.2 simulator, buttons included (November 20).
}

extension IslandKit {
    init(_ context: ZoneIsland.Context) {
        self.init(state: context.state, stale: context.isStale)
    }
}

struct RecorderStrip: View {
    let levels: [UInt8]?
    let color: Color
    let live: Bool
    var pending: Color = IslandColor.pendingDot
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
                Circle().fill(pending).frame(width: 2.7, height: 2.7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The recorder's stop button: a red rounded square inside a thin white ring, 49 pt. The ring
/// takes the palette's ink, so Blackout's is grey.
struct StopRing: View {
    let color: Color
    var size: CGFloat = 49
    var ring: Color = .white
    var body: some View {
        ZStack {
            Circle().strokeBorder(ring, lineWidth: 3)
            RoundedRectangle(cornerRadius: size * 6.5 / 49, style: .continuous)
                .fill(color)
                .frame(width: size * 25 / 49, height: size * 25 / 49)
        }
        .frame(width: size, height: size)
    }
}

struct MinimalView: View {
    let kit: IslandKit
    var body: some View {
        if kit.held {
            HeldDot(color: kit.tint, size: 6)
        } else if kit.stale {
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(kit.detailInk)
        } else if let quiet = kit.quiet, kit.look != .ghost {
            ReadyRing(interval: quiet, color: kit.tint, size: 16, label: "Quiet. Zone finishes soon", accentOnly: kit.look == .blackout)
        } else if kit.live, kit.state.meetingTitle != nil {
            MinimalMeetingClock(start: kit.state.startedAt)
                .foregroundStyle(kit.tint)
        } else if kit.phase == .paused, kit.state.meetingTitle != nil {
            Image(systemName: "pause.fill").font(.caption2).foregroundStyle(kit.detailInk)
        } else if kit.recording && kit.look != .ghost {
            IslandWave(levels: IslandLevels.last(5, of: kit.levels), color: kit.tint, barWidth: 2, gap: 2, height: 16)
        } else if let interval = kit.countdown, kit.look != .ghost {
            ReadyRing(interval: interval, color: kit.tint, size: 16, accentOnly: kit.look == .blackout)
        } else {
            Dot(color: kit.tint, size: kit.recording ? 8 : 6, recording: kit.recording)
        }
    }
}

/// A meeting's sample-based anchor excludes pauses. Both clock faces and the mask run in
/// SpringBoard, so the change of units does not depend on Zone sending an update at the hour.
private struct MinimalMeetingClock: View {
    let start: Date
    private var hour: Date { start.addingTimeInterval(3600) }

    var body: some View {
        ZStack {
            // The system can render a timer tick before it redraws its mask. Hold the
            // final second to avoid flashing "60:00" while the old face exits.
            Text(timerInterval: start...hour.addingTimeInterval(-1), countsDown: false, showsHours: false)
                .mask(hourMask(countsDown: false))
            Text(.durationOffset(to: start), format: .time(pattern: .hourMinute(
                padHourToLength: 1, roundSeconds: .towardZero)))
                .mask(hourMask(countsDown: true))
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .lineLimit(1).minimumScaleFactor(0.80)
        .frame(width: 30, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meeting duration")
        .accessibilityValue(Text(start, style: .timer))
    }

    /// The last digit is 0 or 1. The existing widget font paints only the zero.
    /// Counting up shows the short clock until the hour, counting down shows the long one after.
    private func hourMask(countsDown: Bool) -> some View {
        GeometryReader { box in
            Text(timerInterval: hour.addingTimeInterval(-1)...hour, countsDown: countsDown, showsHours: false)
                .font(.custom(IslandGate.Period.ten.rawValue, fixedSize: 4))
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .multilineTextAlignment(.trailing)
                .frame(width: 16, height: 4, alignment: .trailing)
                .offset(x: -12)
                .frame(width: 4, height: 4, alignment: .leading)
                .clipped()
                // Sample the middle pixel. Sampling the whole glyph can include a sliver
                // of its neighbor after WidgetKit rounds a fractional glyph position.
                .frame(width: 1, height: 1)
                .clipped()
                .scaleEffect(x: box.size.width, y: box.size.height, anchor: .topLeading)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The living looks

/// Beside another activity the island gives Zone about 28 pt: one eye, or the whole small figure.
struct AliveMinimal: View {
    let kit: IslandKit
    var body: some View {
        Group {
            switch kit.look {
            case .void: VoidEye(mood: kit.mood, tint: kit.tint, size: CGSize(width: 19, height: 13), blinks: true, glint: kit.glint)
            case .nocturne: BatFigure(mood: kit.mood, tint: kit.tint, height: 9)
            case .pulse: BeatingHeart(tint: kit.tint, size: 15, quick: kit.live || kit.phase == .processing,
                                      quiet: kit.held || kit.stale || kit.userPaused || kit.phase == .paused)
            case .drift: DriftFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 22, height: 18), count: 2)
            case .loop: LoopFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 26, height: 13))
            case .sprout: SproutFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 16, height: 20))
            default: IslandFigure(look: kit.look, mood: kit.mood, tint: kit.tint, height: 19, clock: kit.clock)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(kit.spokenState)
    }
}

/// The creature at full size, between Pause and Stop in the open island.
struct AliveStage: View {
    let kit: IslandKit
    var body: some View {
        Group {
            if kit.portrait {
                HStack(spacing: 8) {
                    IslandSprite(look: kit.look, mood: kit.mood, tint: kit.tint, height: 36, size: .stage)
                    if kit.look == .sprout || kit.look == .drift, kit.mood.garden > 0 {
                        ForEach(0..<min(3, kit.mood.garden), id: \.self) { _ in
                            IslandSprite(look: kit.look, mood: kit.mood, tint: kit.tint, height: 16)
                        }
                    } else {
                        IslandWave(levels: IslandLevels.last(10, of: kit.levels), color: kit.tint,
                                   barWidth: 2, gap: 2, height: 19)
                    }
                }
            } else {
                switch kit.look {
                case .void:
                    IslandFigure(look: .void, mood: kit.mood, tint: kit.tint, height: 30, clock: .gates, glint: kit.glint)
                case .nocturne:
                    BatFigure(mood: kit.mood, tint: kit.tint, height: 26)
                case .pulse:
                    PulseFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 150, height: 34), heart: 22)
                case .drift:
                    DriftFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 150, height: 38), count: 6)
                case .loop:
                    LoopFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 118, height: 30))
                case .sprout:
                    GardenRow(mood: kit.mood, tint: kit.tint, height: 40)
                default:
                    HStack(spacing: 10) {
                        IslandFigure(look: kit.look, mood: kit.mood, tint: kit.tint, height: 30, clock: kit.clock)
                        // What the pet hears, beside it.
                        IslandWave(levels: IslandLevels.last(12, of: kit.levels), color: kit.live ? kit.tint : (kit.look == .blackout ? kit.tint.opacity(0.78) : .secondary),
                                   barWidth: 2.4, gap: 2.4, height: 22, floor: 2)
                    }
                }
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Expanded

struct ExpandedLeading: View {
    let kit: IslandKit
    var body: some View {
        if kit.state.gallery != true && kit.look == .recorder && (kit.recording || kit.phase == .paused) {
            HStack(spacing: 10) {
                if kit.canPause { PauseButton(kit: kit) }
                RecorderStrip(levels: kit.levels, color: kit.tint, live: kit.live, pending: kit.pendingDot,
                              bars: kit.canPause ? 13 : IslandLevels.expandedBars, dots: kit.canPause ? 6 : 11)
            }
            .padding(.leading, kit.canPause ? 0 : 6)
            .frame(maxHeight: .infinity)
        } else if kit.state.gallery == true {
            Text(RecordingWords.short(kit.state, stale: kit.stale))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 8)
        } else {
            HStack(spacing: 8) {
                if kit.alive {
                    IslandFigure(look: kit.look, mood: kit.mood, tint: kit.tint, height: kit.look == .void ? 17 : 22,
                                 clock: .gates, glint: kit.glint)
                        .frame(minWidth: 32, minHeight: 32)
                } else {
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
                }
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
        case .starting, .ready: "mic"
        case .recording: kit.state.noteMode ? "note.text" : "waveform"
        case .paused: "pause.fill"
        case .processing: "text.bubble"
        }
    }
}

struct ExpandedTrailing: View {
    let kit: IslandKit
    var body: some View {
        if kit.state.gallery != true && kit.look == .recorder && (kit.recording || kit.phase == .paused) {
            HStack(spacing: 10) {
                ElapsedText(kit: kit, size: 22, weight: .regular, maxWidth: 76)
                if kit.canStop {
                    IslandButton(.stop, label: "Stop recording") { StopRing(color: kit.tint, ring: kit.ink) }
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
                    // Settings > Dynamic Island > Times can make it a span instead: "Off in 15 min".
                    if kit.liveTimes {
                        // Only the span fits beside Turn off under the camera: "15 minutes". A
                        // self-updating text has no fixed width, so it gets a frame, never
                        // fixedSize: unbounded, it emptied the whole region on the simulator.
                        IslandTimeText.span(until)
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(kit.detailInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80, alignment: .trailing)
                    } else {
                        Text("Off \(until.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(kit.detailInk)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Button(intent: kit.turnOffIntent) { TurnOffButton(color: kit.tint) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Turn Zone off")
            }
            .padding(.trailing, 4)
        }
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
                Circle().fill(kit.ink.opacity(0.16))
                Image(systemName: kit.userPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(kit.ink)
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
    let ink: Color
    let primary: Bool

    var body: some View {
        IslandButton(action, label: title) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(ink)
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
        if kit.state.gallery != true && kit.look == .recorder && (kit.recording || kit.phase == .paused) {
            if let reason = kit.state.pressNotice { notice(reason) }
        } else if kit.recording {
            // Pause at the left corner, Stop at the right, what Zone hears between them.
            HStack(spacing: 8) {
                if kit.canPause { PauseButton(kit: kit) }
                Group {
                    if let reason = kit.state.pressNotice { notice(reason) }
                    else if let wave = kit.meetingWave, kit.look != .ghost { wave.frame(height: 30) }
                    else { recordingContent }
                }.frame(maxWidth: .infinity)
                if kit.canStop {
                    IslandButton(.stop, label: "Stop recording") { StopRing(color: kit.tint, size: 36, ring: kit.ink) }
                }
            }
            .padding(.top, 2)
        } else if kit.canStart {
            VStack(spacing: 6) {
                if kit.state.gallery == true { startButtons }
                if kit.state.gallery == true, kit.alive {
                    HStack(spacing: 8) {
                        IslandFigure(look: kit.look, mood: kit.mood, tint: kit.tint, height: 19, clock: .gates)
                        detailLine
                    }
                } else if kit.alive, kit.look == .sprout, kit.mood.garden > 0 {
                    // The session so far, as flowers: one for each recording kept.
                    GardenRow(mood: kit.mood, tint: kit.tint, height: 22)
                }
                if let reason = kit.state.pressNotice { notice(reason) }
                else if !(kit.state.gallery == true && kit.alive), kit.done || kit.state.session != nil { detailLine }
                if kit.state.gallery != true { startButtons }
            }
            .padding(.top, 2)
        } else if let reason = kit.state.pressNotice {
            notice(reason)
        } else {
            detailLine
        }
    }

    private func notice(_ reason: String) -> some View {
        Text(reason).font(.footnote).lineLimit(2)
    }

    private var startButtons: some View {
        HStack(spacing: 8) {
            StartPill(action: .dictate, title: "Dictate", symbol: "mic.fill", tint: kit.tint,
                      ink: Color(hex: AccentChoice.defaultChoice.foregroundHex), primary: true)
            StartPill(action: .note, title: "Note", symbol: "note.text", tint: kit.tint, ink: kit.ink, primary: false)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var recordingContent: some View {
        switch kit.look {
        case .caption, .stream:
            CaptionView(text: kit.state.tail, tint: kit.tint, ink: kit.ink)
        case .halo, .blackout, .recorder:
            // As many bars as fit between the buttons; the newest is always at the right.
            IslandWave(levels: IslandLevels.last(kit.showsControls ? 30 : 40, of: kit.levels),
                       color: kit.live ? kit.tint : (kit.look == .blackout ? kit.tint.opacity(0.78) : .secondary),
                       barWidth: 3, gap: 3, height: 30, floor: 3)
        case .ghost:
            detailLine
        case .void, .mote, .hare, .wren, .sprout, .loop, .nocturne, .pulse, .drift, .rose, .synth, .cube, .sword:
            AliveStage(kit: kit)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            if kit.ready, kit.liveTimes, !kit.done, !kit.held, let session = kit.state.session {
                // Live times: the words, then the span in its own one-line text with a bounded
                // width. A self-updating span inside a wrapping line emptied the region.
                HStack(spacing: 4) {
                    Text(session.tally.map { "\($0) · on for" } ?? "Audio is not saved · on for")
                        .lineLimit(1)
                    IslandTimeText.span(session.since)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                }
                .font(.system(size: 13))
                .foregroundStyle(kit.detailInk)
            } else {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(kit.detailInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private var detail: String {
        if kit.held { return RecordingWords.detail(kit.state, stale: false) }
        if kit.done {
            if let words = kit.state.words, words > 0 {
                return "Recorded \(words) \(words == 1 ? "word" : "words")."
            }
            return "Finished."
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
    var ink: Color = .white
    var body: some View {
        Group {
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(ink)
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
