// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit

struct ShortcutHelpLink: View {
    @State private var showing = false

    var body: some View {
        Button("Action Button guide") { showing = true }
            .buttonStyle(ZoneLinkButtonStyle())
            .sheet(isPresented: $showing) {
                NavigationStack {
                    ShortcutHelpView().toolbar {
                        ZoneBarItem(.confirmationAction) { Button("Done") { showing = false } }
                    }
                }
            }
    }
}

enum SetupDevice {
    static var hasActionButton: Bool {
        var info = utsname()
        uname(&info)
        let hardware: String = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let model: String = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware
        guard model.hasPrefix("iPhone"), let family = Int(model.dropFirst(6).prefix(while: { $0.isNumber })) else { return false }
        return family >= 16
    }
}

struct ShortcutHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if SetupDevice.hasActionButton {
                    Text("Settings > Action Button > Controls > Zone > Voice note")
                        .font(.zoneTitle)
                        .accessibilityAddTraits(.isHeader)
                    ActionButtonSettingsSketch()
                    Text("Swipe to Controls, tap Choose a Control, then search for Zone.")
                        .foregroundStyle(.secondary)
                } else {
                    otherControls
                    Text("Back Tap").font(.zoneTitle)
                    Text("Save Voice note in Shortcuts. In Settings, open Accessibility, Touch, then Back Tap. Pick Double Tap and choose your shortcut.")
                }
                if SetupDevice.hasActionButton {
                    DisclosureGroup("Control Center and Lock Screen") { controlsHelp }
                }
                DisclosureGroup("All Zone controls") {
                    row("Voice note", "Press once to record, then again to save.", symbol: "mic.fill")
                    row("Dictate and copy", "Copy your words", symbol: "doc.on.clipboard")
                    row("Toggle Zone", "Turn microphone standby on or off", symbol: "waveform")
                    row("Bring back Zone's island", "Put Zone back in the Dynamic Island.", symbol: "capsule.inset.filled")
                }
                DisclosureGroup("Siri and Shortcuts") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Say “Voice note in Zone” or find Zone in Shortcuts.")
                        ForEach(["Get last dictation", "Get last dictation finish time", "Start meeting", "Stop meeting", "Meeting controls",
                                 "Save to Zone Clipboard", "Send to Computer"], id: \.self) { name in
                            Text(name)
                        }
                    }
                }

            }.padding(24)
        }
        .navigationTitle(SetupDevice.hasActionButton ? "Action Button and Shortcuts" : "Shortcuts and Back Tap")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var otherControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Control Center and Lock Screen").font(.headline)
            controlsHelp
        }
    }

    private var controlsHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In Control Center, tap +, then Add a Control. Search Zone.")
            Text("On the Lock Screen, hold, tap Customize, then replace a control.")
        }
    }

    private func row(_ title: String, _ detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline)
            }
        } icon: { Image(systemName: symbol) }
        .accessibilityElement(children: .combine)
    }
}

/// A small part of the Settings pager. The available pages vary by iPhone.
private struct ActionButtonSettingsSketch: View {
    @Environment(\.colorScheme) private var scheme

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            tile("Controls", symbol: "switch.2", chosen: true)
            tile("Shortcut", symbol: "square.2.layers.3d", chosen: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Choose Controls. Skip Shortcut.")
        .accessibilityIdentifier("guide.sketch")
    }

    private func tile(_ title: String, symbol: String, chosen: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle)
            Text(title).font(.headline).strikethrough(!chosen)
            Image(systemName: chosen ? "checkmark.circle.fill" : "xmark.circle")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .foregroundStyle(chosen ? Zone.ink(scheme) : Color.secondary)
        .background(Zone.card(scheme), in: Zone.cardShape)
        .overlay(Zone.cardShape.strokeBorder(chosen ? Zone.ink(scheme) : Zone.rule(scheme), lineWidth: chosen ? 2 : 1))
    }
}
