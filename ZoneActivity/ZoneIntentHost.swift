// by zayd/cold @ zayd.wtf

import AppIntents
import Foundation

/// The widget extension's half of `Shared/ZoneIntents.swift`. The intents are
/// `AudioRecordingIntent`s, so iOS performs them in the Zone app, never here; this exists so
/// the shared declarations compile, and answers honestly if it is ever reached.
enum ZoneIntentHost {
    @MainActor
    static func perform(_ intent: some AppIntent, noteMode: Bool, desiredState: Bool? = nil) async throws {
        throw Unavailable()
    }

    @MainActor
    static func setStandby(_ intent: some AppIntent, on: Bool) async throws {
        throw Unavailable()
    }

    @MainActor
    static func island(_ action: IslandAction) async throws {
        throw Unavailable()
    }

    @MainActor
    static func showIsland() async throws {
        throw Unavailable()
    }

    struct Unavailable: LocalizedError, CustomLocalizedStringResourceConvertible {
        var errorDescription: String? { "Open Zone to record." }
        var localizedStringResource: LocalizedStringResource { "Open Zone to record." }
    }
}
