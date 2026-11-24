// by zayd/cold @ zayd.wtf

import SwiftUI
import WidgetKit
import AppIntents
#if !ZONE_ACTIVITY_EXTENSION
import ZoneCore
#endif

struct IslandKit {
    let state: RecordingActivityAttributes.ContentState
    let stale: Bool
    let look: IslandLook
    var clock: IslandClock = .gates

    init(state: RecordingActivityAttributes.ContentState, stale: Bool = false) {
        var state = state
        if !IslandLook.developmentGallery { state.gallery = nil }
        self.state = state
        self.stale = stale
        let savedLook = state.look ?? .halo
        let savedPalette = state.palette ?? .accent
        if state.gallery == true {
            look = .restored(savedLook, palette: savedPalette)
        } else {
            look = IslandLook.classic.contains(savedLook) && savedPalette == .accent ? savedLook : .halo
        }
    }

    /// Recorder keeps its shipped colors unless the gallery is open.
    var tint: Color {
        if state.gallery != true, look == .recorder {
            return phase == .ready ? IslandColor.standbyWhite : IslandColor.recorderRed
        }
        return Color(hex: (state.accentChoice.flatMap(AccentChoice.init(rawValue:)) ?? LastAccentChoice.current).darkHex)
    }

    var meetingWave: CompactMeetingWave? {
        guard live, state.meetingTitle != nil, let name = state.meetingWaveStyle else { return nil }
        return CompactMeetingWave(style: MeetingWaveStyle(preference: name), levels: levels, tint: tint)
    }

    var detailInk: AnyShapeStyle {
        look == .blackout ? AnyShapeStyle(tint.opacity(0.78)) : AnyShapeStyle(.secondary)
    }

    /// Full Black uses the app accent for text as well as controls.
    var ink: Color { look == .blackout ? tint : .white }
    /// Light on the eyes of the pets.
    var glint: Color { .white.opacity(0.9) }
    /// The Stream look's two words, or nil for both before the first one.
    var stream: (previous: String?, newest: String?) { IslandStream.words(state.tail) }
    /// Stream has words to show: a live dictation or note with at least one recognized word.
    var streams: Bool { look == .stream && live && state.meetingTitle == nil && stream.newest != nil && quiet == nil }
    /// Finish when quiet is counting: the recording ends at the range's end unless a voice
    /// comes back. The compact island then says "Quiet" beside a ring that drains to that end.
    var quiet: ClosedRange<Date>? { live && !state.noteMode && state.meetingTitle == nil ? state.quiet : nil }
    /// The recorder's grey dots where the recording has not reached.
    var pendingDot: Color { IslandColor.pendingDot }
    var phase: RecordingActivityAttributes.ContentState.Phase { state.phase }
    var recording: Bool { phase == .recording && !stale }
    /// Standby while an interruption has the microphone. Drawn the same fresh or stale: it never
    /// claims to record, so it has no "stopped" to warn about.
    var held: Bool { phase == .ready && state.standbyHeld == true }
    var ready: Bool { phase == .ready && !stale && !held }
    var levels: [UInt8]? { state.levels }
    /// Standby's times as running spans ("Off in 15 min") rather than clock times ("Off 6:10").
    var liveTimes: Bool { state.times == .live }
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
    /// A living look is drawing this card. A meeting keeps the plain presentation: its recorder
    /// is a different thing from dictation, and a glance should tell them apart.
    var alive: Bool { look.isAlive && state.meetingTitle == nil }
    var portrait: Bool { state.gallery == true && state.meetingTitle == nil && !look.spins }
    var spansCamera: Bool { !portrait && look.spansCamera }
    var mood: IslandMood { IslandMood(state: state, stale: stale) }
    /// What VoiceOver says for a creature, which has no words of its own.
    var spokenState: String {
        if held { return "Zone paused" }
        if stale { return "Zone stopped" }
        switch phase {
        case .starting: return "Opening microphone"
        case .ready: return done ? "Saved" : "Zone ready"
        case .recording: return userPaused ? "Zone paused" : (quiet != nil ? "Quiet. Zone finishes soon" : "Zone recording")
        case .paused: return "Zone paused"
        case .processing: return "Zone recognizing"
        }
    }
    var countdown: ClosedRange<Date>? {
        guard ready, let since = state.readySince, let until = state.readyUntil, until > since else { return nil }
        return since...until
    }
}

enum IslandColor {
    /// Apple's recorder red on the black island.
    static let recorderRed = Color(red: 1, green: 0.27, blue: 0.23)
    /// The Recorder look's standby: the island's own white, a step back.
    static let standbyWhite = Color.white.opacity(0.72)
    /// The recorder's grey "not reached yet" dots: rgba(235, 235, 245, 0.42).
    static let pendingDot = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.42)
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

/// A system countdown inside a bounded ring.
struct ReadyRing: View {
    let interval: ClosedRange<Date>
    let color: Color
    var size: CGFloat = 14
    /// The same ring counts down a quiet recording's end (`IslandKit.quiet`).
    var label = "Zone is ready"

    var accentOnly = false

    var body: some View {
        ProgressView(timerInterval: interval, countsDown: true) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.circular)
        .tint(accentOnly ? .white : color)
        .colorMultiply(accentOnly ? color : .white)
        .frame(width: size, height: size)
        .accessibilityLabel(label)
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

/// One word of the Stream look. The newest sits right of the camera in the tint; the one before
/// it sits left, dimmer, so speech reads across the island in the order it was said. Each word
/// changes about once a second and cross-fades, so the island never jitters with the recognizer.
struct StreamWord: View {
    let text: String
    let color: Color
    let newest: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: newest ? .semibold : .medium, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            // Long words keep their end when they are the newest: that is where the eye is.
            .truncationMode(.head)
            .frame(maxWidth: 58, alignment: newest ? .leading : .trailing)
            .contentTransition(.opacity)
            // Words on screen over any app: hidden on a locked phone, like the caption.
            .privacySensitive()
            .accessibilityHidden(true)
    }
}

struct CompactLeading: View {
    let kit: IslandKit
    var body: some View {
        Group {
            if kit.streams {
                // The word before the newest, on its way out past the camera.
                StreamWord(text: kit.stream.previous ?? "", color: kit.ink.opacity(0.55), newest: false)
            } else if kit.portrait, !kit.stale, !kit.held, kit.quiet == nil, !kit.userPaused {
                IslandSprite(look: kit.look, mood: kit.mood, tint: kit.tint, height: 22)
                    .accessibilityLabel(kit.spokenState)
            } else if kit.held {
                HeldDot(color: kit.tint, size: kit.look == .ghost ? 5 : 6)
            } else if kit.stale {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kit.detailInk)
                    .accessibilityLabel("Zone stopped")
            } else {
                switch kit.phase {
                case .ready where kit.done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(kit.tint)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Saved")
                case .starting:
                    Dot(color: kit.tint.opacity(0.6), size: 6).accessibilityLabel("Opening microphone")
                case .ready:
                    Dot(color: kit.tint.opacity(kit.look == .ghost ? 0.7 : 1), size: kit.look == .ghost ? 5 : 6)
                        .accessibilityLabel("Zone ready")
                case .recording:
                    if kit.userPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(kit.detailInk)
                            .accessibilityLabel("Zone paused")
                    } else if kit.look == .ghost {
                        Dot(color: kit.tint, size: 8, recording: true).accessibilityLabel("Zone recording")
                    } else if let quiet = kit.quiet {
                        // No voice for a moment: the bars would be flat, so the ring that drains
                        // until the recording finishes takes their place.
                        ReadyRing(interval: quiet, color: kit.tint, size: 13, label: "Quiet. Zone finishes soon", accentOnly: kit.look == .blackout)
                    } else if let wave = kit.meetingWave {
                        ZStack { wave }
                            .frame(width: 17, height: 16)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Zone recording")
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
            if kit.streams {
                StreamWord(text: kit.stream.newest ?? "", color: kit.tint, newest: true)
            } else if kit.stale || kit.look == .ghost || kit.held {
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
                case .starting:
                    Color.clear.frame(width: 6, height: 6)
                case .ready:
                    if let interval = kit.countdown {
                        ReadyRing(interval: interval, color: kit.tint, size: 13, accentOnly: kit.look == .blackout)
                    } else {
                        Color.clear.frame(width: 6, height: 6)
                    }
                case .recording:
                    if kit.userPaused || kit.state.waitingForSamples == true {
                        ElapsedText(kit: kit, size: 14, weight: .medium, maxWidth: 44)
                    } else if kit.quiet != nil {
                        Text("Quiet").font(.system(size: 13, weight: .medium)).foregroundStyle(kit.tint)
                            .lineLimit(1).fixedSize()
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
                    Text("Paused").font(.system(size: 13, weight: .medium)).foregroundStyle(kit.detailInk)
                case .processing:
                    ProgressView().progressViewStyle(.circular).tint(kit.tint).frame(width: 13, height: 13)
                }
            }
        }
        .padding(.trailing, 2)
    }
}

struct AliveCompactLeading: View {
    let kit: IslandKit
    var body: some View {
        Group {
            if kit.portrait {
                IslandSprite(look: kit.look, mood: kit.mood, tint: kit.tint, height: 23)
            } else {
                switch kit.look {
                case .void: VoidEye(mood: kit.mood, tint: kit.tint, blinks: kit.clock == .gates, glint: kit.glint)
                case .nocturne: BatWing(mood: kit.mood, tint: kit.tint)
                case .pulse: PulseFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 38, height: 16), clock: kit.clock)
                case .drift: DriftFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 36, height: 19))
                case .loop: LoopFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 32, height: 15))
                case .sprout: SproutFigure(mood: kit.mood, tint: kit.tint, size: CGSize(width: 17, height: 22))
                default: IslandFigure(look: kit.look, mood: kit.mood, tint: kit.tint, height: 21, clock: kit.clock)
                }
            }
        }
        // Snug to the camera, where a half creature has to meet its other half.
        .padding(.leading, kit.spansCamera ? 6 : 2)
        .padding(.trailing, kit.spansCamera ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel(kit.spokenState)
    }
}

struct AliveCompactTrailing: View {
    let kit: IslandKit
    var body: some View {
        Group {
            if kit.look == .void {
                VoidEye(mood: kit.mood, tint: kit.tint, right: true, blinks: kit.clock == .gates, glint: kit.glint)
            } else {
                BatWing(mood: kit.mood, tint: kit.tint, right: true)
            }
        }
        .padding(.trailing, 6)
        .padding(.leading, 1)
        .accessibilityHidden(true)
    }
}

struct ElapsedText: View {
    let kit: IslandKit
    var size: CGFloat
    var weight: Font.Weight = .medium
    var maxWidth: CGFloat = 64

    var body: some View {
        Group {
            if kit.state.waitingForSamples == true {
                Text("0:00")
            } else if let paused = kit.state.userPausedAt, kit.recording {
                Text(Self.clock(paused)).foregroundStyle(kit.detailInk)
            } else {
                Text(kit.state.startedAt, style: .timer).foregroundStyle(kit.recording ? kit.tint : (kit.look == .blackout ? kit.tint.opacity(0.78) : .secondary))
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
