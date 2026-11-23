// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Dynamic Island: pick a look, see it drawn, then try it in the real island.
struct IslandSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @State private var previewing = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(IslandLook.allCases) { look in
                    Button {
                        withAnimation(Zone.motion) { settings.islandLook = look }
                        coordinator.refreshIsland()
                    } label: {
                        IslandLookRow(look: look, selected: settings.islandLook == look)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.islandLook == look ? .isSelected : [])
                }
            } header: {
                Text("Look")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Button {
                    previewing = true
                    Task {
                        await coordinator.previewIsland()
                        previewing = false
                    }
                } label: {
                    HStack {
                        Text(previewing ? "Playing in the island…" : "Try it in the Dynamic Island")
                        Spacer()
                        if previewing { ProgressView() }
                    }
                }
                .disabled(previewing || coordinator.activity.isBusy)
            } footer: {
                Text("Runs a 12-second demo in your Dynamic Island. Swipe to the Home Screen to watch it, or hold the island to expand. Nothing is recorded.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Buttons", isOn: $settings.islandControls)
                    .onChange(of: settings.islandControls) { coordinator.refreshIsland() }
            } footer: {
                SettingsNote("Hold the island to open it.", points: [
                    "**While you dictate:** Pause on the left, Stop on the right. Stop is on the Lock Screen too.",
                    "**While Zone waits:** Dictate records and copies your words, so you can paste them with any keyboard. Note saves a voice note.",
                    "**Zone stays closed.** The buttons work without opening the app.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Show Zone during standby", isOn: $settings.islandWhileReady)
                    .onChange(of: settings.islandWhileReady) { coordinator.refreshIsland() }
            } footer: {
                SettingsNote("Keeps the island compact while the mic waits for keyboard dictation.", points: [
                    "**On:** shows a small Zone dot and countdown ring.",
                    "**Off:** shows Apple's wide orange mic pill instead.",
                    "**Audio is only captured** while you actively dictate.",
                ])
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Dynamic Island")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

/// One look: its name, what it does, and a drawing of its compact island.
private struct IslandLookRow: View {
    let look: IslandLook
    let selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // One column width for every sketch, so the text lines up even beside the ghost's
            // shorter island.
            IslandSketch(look: look).frame(width: 124, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(look.title).font(.body.weight(.semibold))
                Text(look.summary).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Zone.accent : .secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A drawing of the compact island for a look, animated with a pretend voice. It is a
/// sketch for choosing, not the island itself: the real one lives in the widget extension.
struct IslandSketch: View {
    let look: IslandLook

    private var tint: Color { look == .recorder ? Color(red: 1, green: 0.27, blue: 0.23) : Zone.accent }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 0) {
                leading(t).frame(width: 34, alignment: .leading)
                Spacer(minLength: 0)
                // The camera, where the island's middle always is.
                Circle().fill(Color(white: 0.09)).frame(width: 10, height: 10)
                Spacer(minLength: 0)
                trailing(t).frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(width: look == .ghost ? 104 : 124, height: 30)
            .background(Capsule().fill(.black))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func leading(_ t: TimeInterval) -> some View {
        if look == .ghost {
            Circle().fill(tint).frame(width: 7, height: 7)
        } else {
            HStack(spacing: 1.35) {
                ForEach(0..<13, id: \.self) { i in
                    Capsule().fill(tint).frame(width: 1.4, height: 2 + 14 * Self.voice(i, t))
                }
            }
            .frame(height: 16)
        }
    }

    @ViewBuilder private func trailing(_ t: TimeInterval) -> some View {
        switch look {
        case .ghost: Color.clear.frame(width: 7, height: 7)
        case .caption:
            Text("\(12 + Int(t * 1.6) % 40)").font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tint)
        default:
            Text(String(format: "0:%02d", Int(t) % 60)).font(.system(size: 12, weight: look == .recorder ? .regular : .medium))
                .monospacedDigit().foregroundStyle(tint)
        }
    }

    /// Speech-like: syllables move across the bars with pauses between words.
    static func voice(_ bar: Int, _ t: TimeInterval) -> Double {
        let phase = t * 2.6 - Double(bar) * 0.42
        let syllable = max(0, sin(phase * 2.3)) * (0.55 + 0.45 * sin(phase * 0.7 + 1.3))
        let word = max(0, sin(t * 0.9 + Double(bar) * 0.05))
        return min(1, syllable * (0.35 + 0.65 * word))
    }
}
