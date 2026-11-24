// by zayd/cold @ zayd.wtf

import SwiftUI
import UserNotifications

/// Settings > Dynamic Island > Tell me if it ends. iOS ends Zone's island after eight hours, and
/// from the background Zone cannot make it again; with the microphone still on, iOS draws its
/// orange dot instead. This says so with a notification. A card the person clears is different:
/// that turns Zone off (`IslandUpkeep.Response.turnOff`), and the footer says so.
///
/// Zone has quiet (provisional) permission without asking, which lands in Notification Center
/// only. The button here asks for banners, or opens iOS Settings once they were refused.
struct IslandLostNoticeSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: UNAuthorizationStatus?

    @AppStorage(ZoneNoticePermission.explainedKey) private var explained = false
    @State private var showingExplanation = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Tell me if it ends", isOn: $settings.islandLostNotice)
                .accessibilityIdentifier("island.lostNotice")
            if settings.islandLostNotice, let permission {
                switch permission {
                case .authorized, .ephemeral:
                    EmptyView()
                case .denied:
                    LabeledContent("Notifications", value: "Off for Zone")
                    Button("Open iOS Settings") { open(UIApplication.openNotificationSettingsURLString) }
                default:
                    LabeledContent("Notifications", value: "Quiet")
                    Button("Show as banners") {
                        if explained { Task { await askForBanners() } }
                        else { showingExplanation = true }
                    }
                }
            }
        } footer: {
            SettingsNote("Island reminder", "", detail: lasts, points: [
                "**If it still ends** with the mic on, iOS shows its orange dot. A notification says so: tap it to bring Zone back, or turn Zone off from it.",
                "**Bring back Zone's island** in Control Center or Shortcuts does it without opening Zone.",
                "**Clearing Zone from the Lock Screen** turns Zone off, mic included. A notification says so; open Zone to turn it back on.",
            ])
        }
        .listRowBackground(Zone.card(scheme))
        .alert("Recording and standby alerts", isPresented: $showingExplanation) {
            Button("Continue") { explained = true; Task { await askForBanners() } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(ZoneNoticePermission.message)
        }
        .task(id: scenePhase) { await readPermission() }
    }

    /// iOS 26 starts Zone's relay card on schedule; before it, the island lasts what one card does.
    private var lasts: String {
        if #available(iOS 26.0, *) {
            return "The island can stay up to 16 hours after you last open Zone."
        }
        return "iOS ends an island after 8 hours. Zone starts a fresh one each time you open it."
    }

    private func readPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// From quiet (or never asked), asking for alerts shows iOS's prompt.
    private func askForBanners() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await readPermission()
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }
}
