// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit

/// The menu that opens when Zone's Home Screen icon is held. The items themselves are declared
/// in Info.plist (`UIApplicationShortcutItems`) so they are there from the moment Zone is
/// installed, before its first launch. This file only routes a chosen item to the app.
enum QuickAction: String {
    case voiceNote = "wtf.zayd.zone.quick.note"
    case dictate = "wtf.zayd.zone.quick.dictate"
    case meeting = "wtf.zayd.zone.quick.meeting"
    case share = "wtf.zayd.zone.quick.share"

    /// Posted on the main thread when an item is chosen while Zone is already running.
    static let requested = Notification.Name("wtf.zayd.zone.quickAction")

    /// A cold launch delivers the item before the root view subscribes, so it waits here too.
    @MainActor private static var pending: QuickAction?

    @MainActor static func receive(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type) else { return false }
        // A quick action drives Zone (a note, a meeting, the share sheet), so What's New waits
        // for a visit the person begins by tapping the icon, like every other way in.
        AppEntry.noteAutomation("quickAction:\(action.rawValue.split(separator: ".").last ?? "")")
        pending = action
        NotificationCenter.default.post(name: requested, object: nil)
        return true
    }

    @MainActor static func takePending() -> QuickAction? {
        defer { pending = nil }
        return pending
    }
}

/// Hands Home Screen quick actions to `QuickAction`. SwiftUI has no modifier for them, so the
/// app delegate names this scene delegate for Zone's one window scene.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let item = options.shortcutItem else { return }
        MainActor.assumeIsolated { _ = QuickAction.receive(item) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(MainActor.assumeIsolated { QuickAction.receive(shortcutItem) })
    }
}

/// Runs a quick action from the root view, where the dictation, note, meeting and share
/// presentations all live.
struct QuickActionHandler: ViewModifier {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(AppSettings.self) private var settings
    @Environment(LinkCoordinator.self) private var link
    @State private var sharingZone = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: QuickAction.requested)) { _ in runPending() }
            .onAppear { runPending() }
            .background(ShareSheet(isPresented: $sharingZone, items: [ShareInviteItem(sendsToComputer: link.isPaired)]) { completed, activity in
                if completed, ShareSheet.reachesSomeone(activity) { settings.recordShare() }
            })
    }

    private static var sceneIsActive: Bool {
        UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }

    private func runPending() {
        guard let action = QuickAction.takePending() else { return }
        switch action {
        case .voiceNote:
            coordinator.beginNoteDictation()
        case .dictate:
            coordinator.beginShortcutDictation()
        case .meeting:
            // Home opens on the Meeting space, so a refusal (no microphone, a dictation still
            // running) is shown where the meeting would have been.
            UserDefaults.standard.set(HomeMode.meeting.rawValue, forKey: "zone.home.mode")
            Task { await meetings.startRecording() }
        case .share:
            // On a cold launch the sheet has no window to present from until the scene is
            // active and Home has drawn, and a request made before then is dropped. Wait for it.
            Task {
                for _ in 0..<40 where !Self.sceneIsActive {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .milliseconds(400))
                sharingZone = true
            }
        }
    }
}

extension ZoneAppDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = QuickActionSceneDelegate.self }
        return configuration
    }
}
