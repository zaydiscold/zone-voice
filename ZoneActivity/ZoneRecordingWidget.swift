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
        return switch state.phase {
        case .ready: "Zone standby"
        case .recording: state.noteMode ? "Recording note" : "Dictating"
        case .processing: "Transcribing"
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
        return switch state.phase {
        case .ready: "Ready"
        case .recording: state.noteMode ? "Note" : "Dictating"
        case .processing: "Transcribing"
        case .paused: "Paused"
        }
    }
    static func detail(_ state: RecordingActivityAttributes.ContentState, stale: Bool) -> String {
        if held(state) { return "Back by itself when the other audio ends" }
        if stale { return "Open Zone to check your recording" }
        if let title = state.meetingTitle { return state.meetingNote ?? title }
        return switch state.phase {
        case .ready: "Mic ready · not saving audio"
        case .recording: "Press again to stop"
        case .processing: "Finishing transcript"
        case .paused: "Resumes after call or alarm. Tap to open Zone."
        }
    }
}

struct RecordingActivityView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    @Environment(\.activityFamily) private var family

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
                Image(systemName: glyph).font(.title3.weight(.semibold)).foregroundStyle(kit.tint)
                Text(RecordingWords.title(context.state, stale: context.isStale)).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if recording { Text(context.state.startedAt, style: .timer).monospacedDigit().font(.headline) }
            }
            .padding(.horizontal, 12)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        default:
            HStack(spacing: 10) {
                if recording, kit.look != .ghost {
                    IslandWave(levels: IslandLevels.last(IslandLevels.compactBars, of: context.state.levels),
                               color: kit.live ? kit.tint : .secondary, barWidth: 2, gap: 1.6, height: 22)
                } else if let interval = kit.countdown {
                    ReadyRing(interval: interval, color: kit.tint, size: 18)
                } else {
                    Image(systemName: glyph).font(.subheadline).foregroundStyle(kit.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecordingWords.title(context.state, stale: context.isStale)).font(.subheadline.weight(.medium))
                    if context.state.phase != .ready || context.isStale || kit.held {
                        Text(RecordingWords.detail(context.state, stale: context.isStale))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else if let session = context.state.session {
                        // What this session has done, so the card is worth keeping on the Lock
                        // Screen: clearing it also takes Zone's dot out of the island.
                        Text(session.lockScreenLine ?? "On since \(IslandSession.clock(session.since))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if recording {
                    ElapsedText(kit: kit, size: 13, weight: .medium, maxWidth: 56)
                    // Stop works from a locked phone: ending a recording never needs a passcode.
                    // Starting one does not appear here, only in the island of an unlocked phone.
                    if kit.canStop {
                        if kit.canPause { PauseButton(kit: kit, size: 30) }
                        IslandButton(.stop, label: "Stop recording") { StopRing(color: kit.tint, size: 30) }
                    }
                } else if kit.ready, let until = context.state.readyUntil {
                    // When the session ends, as a time: no ticking clock on a card that is not
                    // recording. The ring beside the title shows what is left.
                    Text("Off \(Text(until, style: .time))")
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, context.state.phase == .ready ? 6 : 8)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        }
    }
}

// MARK: - Voice note widget

struct CarWidgetEntry: TimelineEntry {
    let date: Date
    let state: CarWidgetState
    /// Zone has not refreshed a recording or processing claim for `CarWidgetState.staleAfter`.
    let stale: Bool
}

struct CarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarWidgetEntry {
        CarWidgetEntry(date: Date(), state: .idle, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarWidgetEntry) -> Void) {
        completion(CarWidgetEntry(date: Date(), state: context.isPreview ? .idle : CarWidgetState.read(), stale: false))
    }

    /// One entry for what Zone last said, and while it claims to be recording or saving, a
    /// second entry that turns the card into "Zone stopped" if the app's 10 s heartbeat never
    /// pushes it forward. The app reloads the timeline on every phase change and heartbeat.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CarWidgetEntry>) -> Void) {
        let state = CarWidgetState.read()
        let now = Date()
        var entries = [CarWidgetEntry(date: now, state: state, stale: false)]
        if state.phase != .idle {
            let staleAt = max(now.addingTimeInterval(1), state.staleAt)
            entries.append(CarWidgetEntry(date: staleAt, state: state, stale: true))
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
    let entry: CarWidgetEntry

    private var title: String {
        if entry.stale { return "Zone stopped" }
        switch entry.state.phase {
        case .idle: return "Voice note"
        case .recording: return "Recording"
        case .processing: return "Saving"
        }
    }
    private var glyph: String {
        if entry.stale { return "exclamationmark.triangle" }
        switch entry.state.phase {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .processing: return "waveform"
        }
    }

    var body: some View {
        Button(intent: DictateNoteIntent()) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: glyph)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(entry.state.phase == .recording && !entry.stale ? .red : .orange)
                    .frame(height: 36)
                Spacer(minLength: 0)
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Group {
                    if entry.stale {
                        Text("Open Zone to check")
                    } else if entry.state.phase == .recording, let since = entry.state.startedAt {
                        Text(since, style: .timer).monospacedDigit()
                    } else if entry.state.phase == .processing {
                        Text("Keeping your words")
                    } else {
                        Text("Tap to start")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.state.phase == .recording ? "Finish voice note" : "Start voice note")
        .containerBackground(for: .widget) { Color.black }
    }
}
