// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

@main
struct ZoneApp: App {
    /// Receives iOS's relaunch for finished model downloads (ModelDownloader).
    @UIApplicationDelegateAdaptor(ZoneAppDelegate.self) private var appDelegate
    /// Zone itself, built once the phone has been unlocked since it started (`AppLaunch`).
    @State private var launch = AppLaunch()

    var body: some Scene {
        WindowGroup {
            Group {
                if let graph = launch.graph {
                    AppRoot(graph: graph)
                } else {
                    WaitingForUnlockView { launch.force(trigger: "onScreen") }
                }
            }
            .onOpenURL { url in launch.force(trigger: "url").open(url) }
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
            .task { await BakeoffAutorun.runIfRequested(coordinator: graph.coordinator) }
            #if DEBUG
            .task { await IslandPreviewAutorun.runIfRequested(coordinator: graph.coordinator, settings: graph.settings) }
            .task { await LinkDebug.runIfRequested(link: graph.link, notes: graph.coordinator.notes, meetings: graph.meetings) }
            .task { await WhatsNewDebug.runIfRequested() }
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
            await coordinator.previewIsland()
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
#endif
