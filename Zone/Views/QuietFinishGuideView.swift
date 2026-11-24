// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The walkthrough for Finish when quiet: a pretend dictation plays in a drawn strip (talk, a
/// short pause, talk, then quiet until it finishes), with the three things to know beneath it.
/// Opens by itself the first time the setting is turned on, and again from "How it works".
struct QuietFinishGuideView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set once the walkthrough has been shown, so turning the setting on again does not reopen it.
    static let seenKey = "zone.quietFinish.guideSeen"

    var body: some View {
        let wait = SilenceFinish.waitLabel(settings.finishWhenQuietWait)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Finish when quiet").font(.zoneTitle)
                Text("Stop talking and Zone types for you. No tap needed.")
                    .foregroundStyle(.secondary)
            }

            QuietFinishSketch(wait: settings.finishWhenQuietWait, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 14) {
                step(1, "Talk as usual.", "Zone waits for your voice. Speaking again restarts the timer.")
                step(2, "Go quiet for \(wait).", settings.finishWhenQuietWait > 5
                     ? "The last 5 seconds count down, on the keyboard and in Zone."
                     : "It counts down, on the keyboard and in Zone.")
                step(3, "Your words go in.", "The same as tapping ✓. You can still tap it sooner.")
            }

            Text("Zone waits for your first word, so a slow start never ends a dictation. In a loud room it may not hear the quiet; tap ✓ as usual.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Got it") { dismiss() }
                .buttonStyle(ZonePrimaryButtonStyle())
        }
        .padding(24)
        .background(Zone.paper(scheme).ignoresSafeArea())
        .onAppear { UserDefaults.standard.set(true, forKey: Self.seenKey) }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .frame(width: 24, height: 24)
                .background(Circle().fill(Zone.card(scheme)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A drawn dictation that talks, pauses briefly, talks, then goes quiet and finishes. The quiet
/// part plays at the real wait up to five seconds; longer waits are shortened to five so the
/// loop stays quick, and the label says the real wait.
private struct QuietFinishSketch: View {
    let wait: TimeInterval
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var scheme

    /// Seconds into the loop: talk 0-3, pause 3-4.2, talk 4.2-6.5, quiet from 6.5 for
    /// `quietLength`, then 2.5 s typed.
    private static let quietStart: TimeInterval = 6.5
    private var firstPauseEnd: TimeInterval { 3 + min(1.2, wait / 2) }
    private var quietLength: TimeInterval { min(wait, 5) }
    private var loop: TimeInterval { Self.quietStart + quietLength + 2.5 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? Self.quietStart + quietLength / 2 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: loop)
            let quiet = t - Self.quietStart
            let typed = quiet >= quietLength
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    bars(t)
                    Spacer(minLength: 0)
                    if typed {
                        Label("Typed", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).labelStyle(ZoneCueLabelStyle(scheme: scheme))
                    } else if quiet >= 0 {
                        ring(progress: quiet / quietLength)
                    }
                }
                .frame(height: 34)
                Text(caption(t, quiet: quiet, typed: typed))
                    .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Zone.cardShape.fill(Zone.card(scheme)))
            .overlay(Zone.cardShape.strokeBorder(Zone.rule(scheme)))
        }
        .accessibilityElement()
        .accessibilityLabel("Example: you talk, stop for \(SilenceFinish.waitLabel(wait)), and Zone types your words.")
    }

    private func caption(_ t: TimeInterval, quiet: TimeInterval, typed: Bool) -> String {
        if typed { return "Done. Your words are in the text box." }
        if quiet >= 0 {
            let left = max(1, Int((quietLength - quiet).rounded(.up)))
            return wait > quietLength ? "Quiet. Finishing in \(left)… (after \(SilenceFinish.waitLabel(wait)) for real)"
                                      : "Quiet. Finishing in \(left)…"
        }
        if t >= 3 && t < firstPauseEnd { return "A pause to think. The wait starts over when you talk." }
        return "Talking…"
    }

    private func bars(_ t: TimeInterval) -> some View {
        let talking = (t < 3) || (t >= firstPauseEnd && t < Self.quietStart)
        return HStack(spacing: 2.5) {
            ForEach(0..<28, id: \.self) { i in
                Capsule().fill(.primary)
                    .frame(width: 3, height: talking ? 4 + 26 * IslandSketch.voice(i, t) : 3)
            }
        }
        .animation(.easeOut(duration: 0.15), value: talking)
    }

    private func ring(progress: Double) -> some View {
        ZStack {
            Circle().stroke(Zone.rule(scheme), lineWidth: 3)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 26, height: 26)
    }
}
