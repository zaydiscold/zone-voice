// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

@main
struct ZoneApp: App {
    /// Receives iOS's relaunch for finished model downloads (ModelDownloader).
    @UIApplicationDelegateAdaptor(ZoneAppDelegate.self) private var appDelegate
    /// Zone itself, built once the phone has been unlocked since it started (`AppLaunch`).
    @State private var launch = AppLaunch()

    #if DEBUG
    init() {
        // Set the preview/test start page once, before Home mounts.
        if let raw = UserDefaults.standard.string(forKey: "zoneHomeMode"),
           HomeMode(rawValue: raw) != nil || raw == "cleanup" {
            // Seed a real writable preference, including the value saved by older builds.
            UserDefaults.standard.set(raw, forKey: "zone.home.mode")
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                if let graph = launch.graph {
                    AppRoot(graph: graph)
                } else {
                    WaitingForUnlockView { launch.onScreen(trigger: "onScreen") }
                }
            }
            .onOpenURL { url in
                guard !LinkPairingLink.isPairingURL(url) else {
                    AppEntry.noteAutomation("pairURL")
                    return
                }
                launch.open(url)
            }
        }
    }
}

/// The app's screens with everything they read from the environment.
private struct AppRoot: View {
    let graph: AppGraph

    var body: some View {
        RootView()
            .environment(graph.settings)
            .environment(graph.coordinator)
            .environment(graph.meetings)
            .environment(graph.link)
            .environment(graph.whatsNew)
            .modifier(ClipboardWatch(settings: graph.settings))
            .modifier(FieldEmojiPicker())
            .task { await BakeoffAutorun.runIfRequested(coordinator: graph.coordinator) }
            // Frees the retired Cleanup model's 372 MB, off the main thread.
            .task { await Task.detached(priority: .utility) { RetiredCleanup.sweep() }.value }
            #if DEBUG
            .task { await IslandPreviewAutorun.runIfRequested(coordinator: graph.coordinator, settings: graph.settings) }
            .task { NoteSeeds.runIfRequested(notes: graph.coordinator.notes) }
            .task { await LinkDebug.runIfRequested(link: graph.link, notes: graph.coordinator.notes, meetings: graph.meetings) }
            .task { await WhatsNewDebug.runIfRequested() }
            .task { await ClipboardDebug.runIfRequested() }
            #endif
    }
}

#if DEBUG
/// `-ZoneIslandPreview <look>` plays the island preview in a loop, for simulator screenshots
/// of every look and phase without a microphone.
enum IslandPreviewAutorun {
    @MainActor static func runIfRequested(coordinator: DictationCoordinator, settings: AppSettings) async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-ZoneIslandPreview") else { return }
        if i + 1 < args.count, let look = IslandLook(rawValue: args[i + 1]) { settings.islandLook = look }
        // `-ZoneIslandPalette blackout` restores the look from an old saved color.
        if let c = args.firstIndex(of: "-ZoneIslandPalette"), c + 1 < args.count,
           let palette = IslandPalette(rawValue: args[c + 1]) {
            settings.islandWhileReady = true
            settings.islandPalette = palette
        }
        // A real standby arming on open would replace the held card with its own.
        settings.startsSessionOnOpen = false
        coordinator.endSession(reason: .user)
        if let p = args.firstIndex(of: "-ZoneIslandPhase"), p + 1 < args.count, args[p + 1] == "held" {
            // Standby while an interruption has the microphone.
            await coordinator.holdIslandPreview(phase: .ready)
            coordinator.holdIslandPreviewAsInterrupted()
            return
        }
        if let p = args.firstIndex(of: "-ZoneIslandPhase"), p + 1 < args.count,
           let phase = RecordingActivityAttributes.ContentState.Phase(rawValue: args[p + 1]) {
            await coordinator.holdIslandPreview(phase: phase, userPaused: args.contains("-ZoneIslandUserPaused"),
                                                justFinished: args.contains("-ZoneIslandDone"))
            return
        }
        while !Task.isCancelled {
            try? await coordinator.previewIsland()
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
#endif
