// by zayd/cold @ zayd.wtf

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The extension carries two things: the recording Live Activity (Lock Screen, Dynamic
/// Island, Apple Watch Smart Stack and, with the small family, the CarPlay Dashboard) and
/// the voice-note widget (Home Screen, StandBy and the CarPlay widget stacks). Neither needs
/// a CarPlay entitlement: Apple's CarPlay guide (October 2026) states that widgets and Live
/// Activities from any app appear in CarPlay.
@main
struct ZoneWidgets: WidgetBundle {
    var body: some Widget {
        ZoneRecordingWidget()
        ZoneCarWidget()
        ZoneNoteControl()
        ZoneDictateControl()
        ZoneStandbyControl()
        ZoneIslandControl()
    }
}

// MARK: - Live Activity

struct ZoneRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingActivityView(context: context)
                .widgetURL(URL(string: context.state.meetingTitle == nil ? "zone://recording" : "zone://meeting"))
        } dynamicIsland: { context in
            ZoneIsland.make(context)
        }
        // The small family is what the CarPlay Dashboard and the Watch Smart Stack draw. Without
        // it CarPlay falls back to the Dynamic Island's compact views. Buttons on a Live Activity
        // do nothing in CarPlay (ActivityKit docs), so this stays a status card; the widget
        // below is the control.
        .supplementalActivityFamilies([.small])
    }
}

/// Zone stopped refreshing the activity (killed, crashed): never claim it is still recording.
enum RecordingWords {
    /// Standby while an interruption has the microphone. Checked before stale: a held standby
    /// claims no recording, so it never reads as "stopped".
    static func held(_ state: RecordingActivityAttributes.ContentState) -> Bool {
        state.phase == .ready && state.standbyHeld == true
    }
    static func title(_ state: RecordingActivityAttributes.ContentState, stale: Bool) -> String {
        if held(state) { return "Zone is paused" }
        if stale { return "Zone stopped" }
        if state.meetingTitle != nil {
            return switch state.phase {
            case .processing: "Meeting saved"
            case .paused: state.meetingHeld == true ? "Meeting interrupted" : "Meeting paused"
            default: "Recording a meeting"
            }
        }
        if state.phase == .recording, state.userPausedAt != nil { return "Paused" }
        if state.phase == .recording, !state.noteMode, state.quiet != nil { return "Quiet. Finishing soon" }
        return switch state.phase {
        case .starting: state.noteMode ? "Starting note" : "Starting dictation"
        case .ready: "Zone standby"
        case .recording: state.noteMode ? "Recording note" : "Dictating"
        case .processing: state.modelLoading == true ? "Loading speech model" : "Transcribing"
        case .paused: "Paused"
        }
    }
    /// The island's title: it sits left of the camera, where about 11 characters fit.
    static func short(_ state: RecordingActivityAttributes.ContentState, stale: Bool) -> String {
        if held(state) { return "Paused" }
        if stale { return "Stopped" }
        if state.meetingTitle != nil {
            return switch state.phase {
            case .processing: "Saved"
            case .paused: state.meetingHeld == true ? "Held" : "Paused"
            default: "Meeting"
            }
        }
        if state.phase == .recording, state.userPausedAt != nil { return "Paused" }
        if state.phase == .recording, !state.noteMode, state.quiet != nil { return "Quiet" }
        return switch state.phase {
        case .starting: "Starting"
        case .ready: "Ready"
        case .recording: state.noteMode ? "Note" : "Dictating"
        case .processing: state.modelLoading == true ? "Loading speech model" : "Transcribing"
        case .paused: "Paused"
        }
    }
    static func detail(_ state: RecordingActivityAttributes.ContentState, stale: Bool) -> String {
        if held(state) { return "Back by itself when the other audio ends" }
        if stale { return "Open Zone to check your recording" }
        if let title = state.meetingTitle { return state.meetingNote ?? title }
        return switch state.phase {
        case .starting: "Opening microphone"
        case .ready: "Mic ready · not saving audio"
        case .recording: state.recordingHint
        case .processing: state.modelLoading == true ? "Saving your audio" : "Finishing transcript"
        case .paused: "Resumes after call or alarm. Tap to open Zone."
        }
    }
}

struct RecordingActivityView: View {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.isLuminanceReduced) private var dimmed
    let context: ActivityViewContext<RecordingActivityAttributes>
    @Environment(\.activityFamily) private var family

    private var tint: Color {
        (mode == .fullColor ? kit.tint : Color.primary).opacity(dimmed ? 0.65 : 1)
    }
    private var ink: Color { mode == .fullColor ? kit.ink : .primary }
    private var kit: IslandKit { IslandKit(context) }
    private var glyph: String {
        if kit.held { return "mic.slash" }
        return switch context.state.phase {
        case .ready: "circle.circle"
        case .paused: "pause.fill"
        case .processing where context.state.meetingTitle != nil: "checkmark"
        default: "waveform"
        }
    }
    private var recording: Bool { context.state.phase == .recording && !context.isStale }

    var body: some View {
        switch family {
        case .small:
            // CarPlay Dashboard and the Watch: one line, glanceable from the driver's seat.
            HStack(spacing: 8) {
                Image(systemName: glyph).font(.title3.weight(.semibold)).foregroundStyle(tint).widgetAccentable()
                Text(RecordingWords.title(context.state, stale: context.isStale)).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if recording && context.state.waitingForSamples == true { Text("0:00").monospacedDigit().font(.headline) }
                else if recording { Text(context.state.startedAt, style: .timer).monospacedDigit().font(.headline) }
            }
            .padding(.horizontal, 12)
            .foregroundStyle(ink)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(ink)
        default:
            HStack(spacing: 10) {
                if kit.look.isAlive || kit.portrait, context.state.meetingTitle == nil {
                    if kit.look.spins {
                        // The Lock Screen archives its entire card under a tighter size budget.
                        // Draw the same pose from each regular speech update.
                        IslandRelic(look: kit.look, mood: kit.mood, tint: tint, height: 24,
                                    clock: .gates, activitySnapshotsOnly: true)
                    } else {
                        IslandFigure(look: kit.look, mood: kit.mood, tint: tint, height: 24, clock: .gates, glint: kit.glint)
                    }
                } else if let wave = kit.meetingWave, kit.look != .ghost {
                    CompactMeetingWave(style: wave.style, levels: wave.levels, tint: tint).frame(width: 46, height: 22)
                } else if recording, kit.look != .ghost {
                    IslandWave(levels: IslandLevels.last(IslandLevels.compactBars, of: context.state.levels),
                               color: kit.live ? tint : (kit.look == .blackout ? tint.opacity(0.78) : .secondary), barWidth: 2, gap: 1.6, height: 22)
                } else if let interval = kit.countdown {
                    ReadyRing(interval: interval, color: tint, size: 18, accentOnly: kit.look == .blackout)
                } else {
                    Image(systemName: glyph).font(.subheadline).foregroundStyle(tint).widgetAccentable()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecordingWords.title(context.state, stale: context.isStale)).font(.subheadline.weight(.medium))
                    if !context.isStale, let reason = context.state.pressNotice {
                        Text(reason).font(.caption2).lineLimit(2)
                    } else if context.state.phase != .ready || context.isStale || kit.held {
                        Text(RecordingWords.detail(context.state, stale: context.isStale))
                            .font(.caption2).foregroundStyle(kit.detailInk).lineLimit(1)
                    } else if let session = context.state.session {
                        // What this session has done, so the card is worth keeping on the Lock
                        // Screen: clearing it also takes Zone's dot out of the island.
                        Group {
                            if let line = session.lockScreenLine {
                                Text(line).minimumScaleFactor(0.8)
                            } else if kit.liveTimes {
                                // The span in its own bounded text (see `IslandTimeText`).
                                HStack(spacing: 3) {
                                    Text("On for")
                                    IslandTimeText.span(session.since).frame(maxWidth: 120, alignment: .leading)
                                }
                            } else {
                                Text("On since \(IslandSession.clock(session.since))")
                            }
                        }
                            .font(.caption2).foregroundStyle(kit.detailInk).lineLimit(1)
                    }
                }
                .layoutPriority(kit.ready && context.state.session?.lockScreenLine != nil ? 1 : 0)
                Spacer(minLength: 0)
                if recording {
                    ElapsedText(kit: kit, size: 13, weight: .medium, maxWidth: 56)
                    // Stop works from a locked phone: ending a recording never needs a passcode.
                    // Starting one does not appear here, only in the island of an unlocked phone.
                    if kit.canStop {
                        if kit.canPause { PauseButton(kit: kit, size: 30) }
                        IslandButton(.stop, label: "Stop recording") { StopRing(color: tint, size: 30, ring: ink) }
                    }
                } else if kit.ready, let until = context.state.readyUntil {
                    // When the session ends, as a time: no ticking clock on a card that is not
                    // recording. The ring beside the title shows what is left.
                    if kit.liveTimes {
                        // "Off in 15 minutes", bounded: a self-updating text never gets fixedSize.
                        HStack(spacing: 3) {
                            Text("Off in")
                            IslandTimeText.span(until).frame(maxWidth: 110, alignment: .leading)
                        }
                        .font(.caption).foregroundStyle(kit.detailInk).lineLimit(1)
                        .frame(maxWidth: 140, alignment: .trailing)
                    } else {
                        Text("Off \(Text(until, style: .time))")
                            .monospacedDigit().font(.caption).foregroundStyle(kit.detailInk)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, context.state.phase == .ready ? 6 : 8)
            .background {
                if kit.look == .blackout {
                    // The system tint is glass on the Lock Screen. Fill its insets
                    // with solid black too. The system clips the card's corners.
                    Color.black.padding(-32)
                }
            }
            .foregroundStyle(ink)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(ink)
        }
    }
}

// MARK: - Voice note widget

struct CarWidgetEntry: TimelineEntry {
    let date: Date
    let state: CarWidgetState
    /// Zone has not refreshed a recording or processing claim for `CarWidgetState.staleAfter`.
    let stale: Bool
    let accent: AccentChoice
}

struct CarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarWidgetEntry {
        CarWidgetEntry(date: Date(), state: .idle, stale: false, accent: .defaultChoice)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarWidgetEntry) -> Void) {
        completion(CarWidgetEntry(date: Date(), state: context.isPreview ? .idle : CarWidgetState.read(),
                                  stale: false, accent: LastAccentChoice.current))
    }

    /// One entry for what Zone last said, and while it claims to be recording or saving, a
    /// second entry that turns the card into "Zone stopped" if the app's 10 s heartbeat never
    /// pushes it forward. The app reloads the timeline on every phase change and heartbeat.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CarWidgetEntry>) -> Void) {
        let state = CarWidgetState.read()
        let now = Date()
        let accent = LastAccentChoice.current
        var entries = [CarWidgetEntry(date: now, state: state, stale: false, accent: accent)]
        if state.phase != .idle {
            let staleAt = max(now.addingTimeInterval(1), state.staleAt)
            entries.append(CarWidgetEntry(date: staleAt, state: state, stale: true, accent: accent))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct ZoneCarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CarWidgetState.widgetKind, provider: CarWidgetProvider()) { entry in
            CarWidgetView(entry: entry)
        }
        .configurationDisplayName("Voice note")
        .description("One tap starts a Zone voice note, another finishes it. Also in StandBy and CarPlay.")
        .supportedFamilies([.systemSmall])
    }
}

/// The whole card is the button: nothing to aim for on a dashboard. The intent is an
/// `AudioRecordingIntent`, so iOS performs it in the Zone app, which starts or finishes the
/// note exactly as the Action Button does. The card reads its state back from the App Group.
struct CarWidgetView: View {
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.isLuminanceReduced) private var dimmed
    let entry: CarWidgetEntry

    /// The card is the Voice note control in another shape: its tap is a note press, so it shows
    /// what the note control shows. A dictation (the keyboard's, or Dictate and copy) reads as
    /// busy, never as a stop the tap cannot perform.
    private var shows: CarWidgetState.ControlShows { entry.state.controlShows(noteMode: true, now: entry.date) }

    private var title: String {
        if entry.stale { return "Zone stopped" }
        return shows.title(off: "Voice note")
    }
    private var glyph: String {
        if entry.stale { return "exclamationmark.triangle" }
        return shows == .saving ? "waveform" : shows.glyph(off: "mic.fill")
    }
    private var running: Bool {
        switch shows {
        case .recording, .busy(_, saving: false): true
        default: false
        }
    }
    private var saving: Bool {
        switch shows {
        case .saving, .busy(_, saving: true): true
        default: false
        }
    }
    private var accessibilityLabel: String {
        switch shows {
        case .recording: "Finish voice note"
        case .busy: "Zone is busy: \(title)"
        default: "Start voice note"
        }
    }

    var body: some View {
        Button(intent: DictateNoteIntent()) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: glyph)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(mode == .fullColor ? (entry.stale ? Color.orange : Color(hex: entry.accent.darkHex)) : Color.primary)
                    .widgetAccentable()
                    .opacity(dimmed ? 0.65 : 1)
                    .frame(height: 36)
                Spacer(minLength: 0)
                Text(title).font(.headline).foregroundStyle(mode == .fullColor ? Color.white : .primary).lineLimit(1)
                Group {
                    if entry.stale {
                        Text("Open Zone to check")
                    } else if running, let since = entry.state.startedAt {
                        Text(since, style: .timer).monospacedDigit()
                    } else if running {
                        // Recording while the speech model loads: no first sample, so no clock yet.
                        Text("Listening")
                    } else if saving {
                        Text("Keeping your words")
                    } else {
                        Text("Tap to start")
                    }
                }
                .font(.caption)
                .foregroundStyle(mode == .fullColor ? Color.white.opacity(0.7) : .secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .containerBackground(for: .widget) { Color.black }
    }
}
