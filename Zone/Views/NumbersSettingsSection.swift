// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct NumbersSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SettingsPicker("Number format", value: settings.numbers.mode.label, selection: $settings.numbers.mode) {
                    ForEach(NumberPreferences.Mode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(example)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("numbers.example")
                ForEach([TextStyle.formal, .excited, .casual, .veryCasual], id: \.self) { style in
                    Toggle(style == .veryCasual ? "Also in Very casual" : style.label, isOn: Binding {
                        settings.numbers.styles.contains(style)
                    } set: { enabled in
                        if enabled { settings.numbers.styles.insert(style) }
                        else { settings.numbers.styles.remove(style) }
                    })
                    .accessibilityIdentifier("numbers." + style.rawValue)
                }
                Toggle("1st, 2nd, 3rd as numbers", isOn: $settings.smallOrdinals)
            } footer: {
                SettingsNote("Ordinal numbers", "", detail: "Turn on to write 1st through 9th as digits. 10th and up are always digits. Phrases like “wait a second” stay words.")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Numbers")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var example: String {
        let style = settings.defaultTextStyle
        let sample = "Seven of my twelve friends came"
        return style.apply(sample, numbers: settings.numbers, autoCapitalization: settings.autoCapitalizationEnabled)
    }
}
