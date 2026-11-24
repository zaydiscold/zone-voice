// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Dynamic Island. The switch at the top decides whether Zone is in the island at
/// all, so everything else (look, color, buttons) only shows while it is on.
struct IslandSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @State private var previewing = false
    @State private var previewError: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Zone in the Dynamic Island", isOn: $settings.islandWhileReady.animation(Zone.motion))
                    .onChange(of: settings.islandWhileReady) { coordinator.refreshIsland() }
                    .accessibilityIdentifier("island.master")
            } footer: {
                SettingsNote("Dynamic Island", "", detail: settings.islandWhileReady
                             ? "A dot shows standby. The indicator changes when you record."
                             : "iOS shows its wide orange mic pill during standby. When you dictate, Zone shows a dot with Stop.", points: [
                    "**Buttons:** Hold the island for Note and Dictate during standby, or Pause and Stop while recording.",
                    "**Note** saves a voice note. **Dictate** copies your words without opening Zone.",
                    "**Times:** Clock shows start and end times. Live counts time on standby and time left.",
                    "Zone captures audio only while you record.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            if settings.islandWhileReady {
                Section {
                    NavigationLink {
                        IslandLooksGalleryView()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Island look")
                                Text(settings.islandStyle.look.title)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            selectedPreview
                        }
                    }
                    .accessibilityIdentifier("island.gallery")
                }
                .listRowBackground(Zone.card(scheme))
                Section {
                    Button {
                        previewing = true
                        Task {
                            do {
                                previewError = nil
                                try await coordinator.previewIsland()
                            } catch {
                                previewError = error.localizedDescription
                            }
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
                    Text(previewError ?? "Watch a silent 12-second preview on the Home Screen. Hold the island to expand it.")
                }
                .listRowBackground(Zone.card(scheme))

                Section {
                    Toggle("Buttons", isOn: $settings.islandControls)
                        .onChange(of: settings.islandControls) { coordinator.refreshIsland() }
                }
                .listRowBackground(Zone.card(scheme))

                Section {
                    Picker("Times", selection: $settings.islandTimes) {
                        ForEach(IslandTimes.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.islandTimes) { coordinator.refreshIsland() }
                    .accessibilityIdentifier("island.times")
                } header: {
                    Text("Times")
                }
                .listRowBackground(Zone.card(scheme))

                IslandLostNoticeSection()
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Dynamic Island")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var selectedPreview: some View {
        IslandLookPreview(look: settings.islandStyle.look, accent: settings.accent,
                          words: settings.wordsDictated, garden: settings.islandGarden, still: !AppSettings.showsIslandGallery)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dynamic Island preview")
            .accessibilityValue(previewDescription)
    }

    private var previewDescription: String {
        let look = settings.islandStyle.look
        let color = !AppSettings.showsIslandGallery && look == .recorder ? "Recorder red" : settings.accent.label
        return "\(look.title), \(color)"
    }
}

private struct IslandLooksGalleryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section("Island look") {
                ForEach(AppSettings.showsIslandGallery ? IslandLook.allCases.filter { !$0.isPet } : IslandLook.classic) { look in lookRow(look) }
            }
            .listRowBackground(Zone.card(scheme))
            if AppSettings.showsIslandGallery {
                Section("Companions") {
                    ForEach(IslandLook.allCases.filter(\.isPet)) { look in lookRow(look) }
                }
                .listRowBackground(Zone.card(scheme))
            }
            if settings.islandStyle.look.isPet {
                Section("Your companion") {
                    let words = settings.wordsDictated
                    let stage = settings.islandGarden.stage(words: words)
                    let look = settings.islandStyle.look
                    Text("\(look.title) · \(petStageName(stage, look: look))")
                    let garden = settings.islandGarden
                    Text("\(garden.sessionsToday()) dictations today · \(garden.activeDays) active days")
                    Text(["A copper pin arrives after three dictations.", "Copper pin earned. Speak on three days and record a 20-second take to earn a scarf.", "Silk scarf earned. Reach seven active days and 20 dictations to earn a star.", "Star earned. All three keepsakes are yours."][Int(garden.accessory)])
                        .font(.footnote)
                    Text(IslandPetGrowth.hasWordBox(words) ? "First box open · Wren is yours." :
                            "\((IslandPetGrowth.firstBox - words).formatted()) words until your first box.")
                        .font(.footnote)
                }
                .listRowBackground(Zone.card(scheme))
            }
        }
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            coordinator.refreshStats()
        }
        .navigationTitle("Island looks")
        .navigationBarTitleDisplayMode(.inline)
        .zoneBackButton()
        .zoneScreen()
    }

    /// One look in the gallery. Its own function so the Form stays quick to type-check.
    private func lookRow(_ look: IslandLook) -> some View {
        let locked = look == .wren && !IslandPetGrowth.hasWordBox(settings.wordsDictated)
        let selected = settings.islandStyle.look == look
        return Button {
            settings.islandLook = look
            settings.islandPalette = .accent
            coordinator.refreshIsland()
        } label: {
            HStack(spacing: 12) {
                IslandLookPreview(look: look, accent: settings.accent, words: settings.wordsDictated, garden: settings.islandGarden)
                VStack(alignment: .leading, spacing: 3) {
                    Text(look.title).font(.headline)
                    Text(locked ? "First box opens at 1,000 words." : look.summary)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected || locked {
                    Image(systemName: locked ? "lock.fill" : "checkmark")
                        .foregroundStyle(Zone.accentStroke(scheme))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("island.look.\(look.rawValue)")
    }

    private func petStageName(_ stage: IslandPetGrowth.Stage, look: IslandLook) -> String {
        if look == .hare && stage.index <= 1 { return stage.index == 0 ? "Newborn" : "Kit" }
        return stage.name
    }
}

/// Both sides use the widget's compact views. Only the sample audio and clock are local.
struct IslandLookPreview: View {
    let look: IslandLook
    let accent: AccentChoice
    let words: Int
    var garden = IslandGardenProgress()
    var still = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var snapshot: UIImage?

    private struct SnapshotKey: Equatable {
        let look: IslandLook
        let accent: AccentChoice
        let words: Int
        let garden: IslandGardenProgress
        let scale: CGFloat
        let gallery: Bool
    }

    var body: some View {
        if still || reduceMotion {
            let key = SnapshotKey(look: look, accent: accent, words: words, garden: garden, scale: displayScale,
                                  gallery: AppSettings.showsIslandGallery)
            Color.clear
                .frame(width: 116, height: 34)
                .overlay { if let snapshot { Image(uiImage: snapshot) } }
                .task(id: key) { updateSnapshot(scale: key.scale) }
                .accessibilityHidden(true)
        } else if look.spins {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tick in
                frame(time: max(0, tick.date.timeIntervalSince(start)))
            }
            .accessibilityHidden(true)
        } else {
            TimelineView(.periodic(from: start, by: 0.25)) { timeline in
                frame(time: max(0, timeline.date.timeIntervalSince(start)))
            }
            .accessibilityHidden(true)
        }
    }

    private func updateSnapshot(scale: CGFloat) {
        let renderer = ImageRenderer(content: frame(time: 5))
        renderer.scale = scale
        snapshot = renderer.uiImage
    }

    private func frame(time: Double) -> some View {
        let beat = Int(time)
        let kit = sample(time: time, beat: beat)
        return HStack(spacing: 0) {
            if kit.alive { AliveCompactLeading(kit: kit) } else { CompactLeading(kit: kit) }
            Spacer(minLength: 14)
            if kit.alive && kit.spansCamera {
                AliveCompactTrailing(kit: kit)
            } else {
                CompactTrailing(kit: kit)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 116, height: 34)
        .foregroundStyle(kit.ink)
        .background(.black, in: Capsule())
    }

    private func sample(time: Double, beat: Int) -> IslandKit {
        var state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: false, startedAt: (still || reduceMotion) ? Date.now.addingTimeInterval(-time) : start)
        state.look = look
        state.gallery = AppSettings.showsIslandGallery
        state.accentChoice = accent.rawValue
        state.beat = UInt16(truncatingIfNeeded: Int(time * 4))
        state.levels = (0..<16).map { UInt8(15 * IslandSketch.voice($0, Double(beat))) }
        state.words = 15 + beat
        state.tail = ["a quiet", "quiet morning", "morning by", "by the", "the lake"][beat % 5]
        state.petStage = UInt8(garden.stage(words: words).index)
        state.dailyEnergy = garden.dailyEnergy()
        state.accessory = garden.accessory
        state.nightGarden = !((7..<19).contains(Calendar.current.component(.hour, from: .now)))
        var kit = IslandKit(state: state)
        kit.clock = .timeline(time)
        return kit
    }
}

enum IslandSketch {
    /// Speech-like: syllables move across the bars with pauses between words.
    static func voice(_ bar: Int, _ t: TimeInterval) -> Double {
        let phase = t * 2.6 - Double(bar) * 0.42
        let syllable = max(0, sin(phase * 2.3)) * (0.55 + 0.45 * sin(phase * 0.7 + 1.3))
        let word = max(0, sin(t * 0.9 + Double(bar) * 0.05))
        return min(1, syllable * (0.35 + 0.65 * word))
    }
}
